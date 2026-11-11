//! `haunt setup`: installs or removes agent adapters through their install.sh, after showing the exact change.

use std::io::{BufRead, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::{Map, Value};

#[cfg(feature = "plugins")]
use crate::bundled;
use sha2::{Digest, Sha256};

const USAGE: &str = "usage:
  haunt setup                          ask which agents (and bundled plugins) to set up
  haunt setup <claude|codex>... [--yes] [--dry-run] [--expect <sha256>]
  haunt setup none                     just the terminal: record the choice, change nothing
  haunt setup --remove <claude|codex>... [--yes] [--dry-run] [--expect <sha256>]
  haunt setup [...] --plugins <names|all|none> [--remove-plugins <names>]
  haunt setup --list-plugins            the bundled plugins, as JSON

Plugin names are comma-separated short names, the id without dev.haunt. (allowlist, commands, decision-log,
tabs-plus), or plugin ids; each must be one the app bundles.
--dry-run ends with `preview sha256 <hex>`; --expect <hex> applies only if the change still hashes to that.";

#[derive(Clone, Copy, PartialEq)]
enum Agent {
    Claude,
    Codex,
}

impl Agent {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }

    fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
        }
    }

    /// The env override, the folder name under `adapters/` in the app bundle, the repo name, and a file only it has.
    fn adapter(self) -> (&'static str, &'static str, &'static str, &'static str) {
        match self {
            Self::Claude => ("HAUNT_CLAUDE_ADAPTER", "claude", "haunt-claude", ".claude-plugin/plugin.json"),
            Self::Codex => ("HAUNT_CODEX_ADAPTER", "codex", "haunt-codex", "bin/haunt-codex-hook"),
        }
    }
}

struct Opts {
    agents: Vec<Agent>,
    none: bool,
    remove: bool,
    yes: bool,
    dry: bool,
    expect: Option<String>,
    /// Plugin ids to install; None when `--plugins` wasn't given (and wasn't asked).
    #[cfg(feature = "plugins")]
    plugins: Option<Vec<String>>,
    #[cfg(feature = "plugins")]
    remove_plugins: Vec<String>,
}

#[cfg(not(feature = "plugins"))]
const NO_PLUGINS: &str = "haunt setup: this build has no plugin support (the `plugins` feature)";

pub fn run(args: &[String]) -> u8 {
    let mut o = Opts {
        agents: vec![],
        none: false,
        remove: false,
        yes: false,
        dry: false,
        expect: None,
        #[cfg(feature = "plugins")]
        plugins: None,
        #[cfg(feature = "plugins")]
        remove_plugins: vec![],
    };
    #[cfg(feature = "plugins")]
    let bundled = bundled::list();
    #[cfg(feature = "plugins")]
    if args == ["--list-plugins"] {
        println!("{}", bundled::list_json(&haunt_dir(), &bundled));
        return 0;
    }
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--yes" | "-y" => o.yes = true,
            "--dry-run" => o.dry = true,
            "--remove" => o.remove = true,
            "--expect" => {
                let Some(v) = it.next() else { return usage() };
                o.expect = Some(v.to_lowercase());
            }
            #[cfg(feature = "plugins")]
            "--plugins" | "--remove-plugins" => {
                let Some(v) = it.next() else { return usage() };
                let installing = a == "--plugins";
                let installed = if installing { vec![] } else { bundled::installed_bundled(&haunt_dir()) };
                match bundled::resolve(v, installing, &bundled, &installed) {
                    Ok(ids) if installing => o.plugins.get_or_insert_with(Vec::new).extend(ids),
                    Ok(ids) => o.remove_plugins.extend(ids),
                    Err(e) => {
                        eprintln!("haunt setup: {e}");
                        return 2;
                    }
                }
            }
            #[cfg(not(feature = "plugins"))]
            "--plugins" | "--remove-plugins" | "--list-plugins" => {
                eprintln!("{NO_PLUGINS}");
                return 2;
            }
            "none" => o.none = true,
            s if s.starts_with('-') => return usage(),
            s => match Agent::parse(s) {
                Some(ag) if !o.agents.contains(&ag) => o.agents.push(ag),
                Some(_) => {}
                None => {
                    eprintln!("haunt setup: unknown agent {s:?}; choose claude, codex or none");
                    return 2;
                }
            },
        }
    }
    #[cfg(feature = "plugins")]
    let plugin_flags = o.plugins.is_some() || !o.remove_plugins.is_empty();
    #[cfg(not(feature = "plugins"))]
    let plugin_flags = false;
    if (o.none && (o.remove || !o.agents.is_empty())) || (o.remove && o.agents.is_empty()) {
        return usage();
    }
    if !o.none && o.agents.is_empty() && !plugin_flags {
        if o.yes {
            eprintln!("haunt setup: --yes needs what to set up, e.g. haunt setup claude --yes");
            return 2;
        }
        match choose() {
            Some(c) if c.is_empty() => o.none = true,
            Some(c) => o.agents = c,
            None => {
                eprintln!("haunt setup: nothing chosen");
                return 1;
            }
        }
        #[cfg(feature = "plugins")]
        if !bundled.is_empty() {
            match choose_plugins(&bundled) {
                Ok(ids) => o.plugins = Some(ids),
                Err(e) => {
                    eprintln!("haunt setup: {e}");
                    return 1;
                }
            }
        }
    }
    #[cfg(not(feature = "plugins"))]
    let bundled = ();
    match setup(&o, &bundled) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("haunt setup: {e}");
            1
        }
    }
}

fn usage() -> u8 {
    eprintln!("{USAGE}");
    2
}

fn ask(prompt: &str) -> Option<String> {
    print!("{prompt}");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    match std::io::stdin().lock().read_line(&mut line) {
        Ok(n) if n > 0 => Some(line.trim().to_lowercase()),
        _ => None,
    }
}

/// The interactive menu; an empty list means just the terminal.
fn choose() -> Option<Vec<Agent>> {
    println!("Which agents should Haunt set up?");
    println!("  1  Claude Code");
    println!("  2  Codex");
    println!("  3  Claude Code and Codex");
    println!("  4  None, just the terminal");
    match ask("Choose 1-4: ")?.as_str() {
        "1" => Some(vec![Agent::Claude]),
        "2" => Some(vec![Agent::Codex]),
        "3" => Some(vec![Agent::Claude, Agent::Codex]),
        "4" => Some(vec![]),
        _ => None,
    }
}

/// Asked only when the app bundles plugins; Enter, or the end of input, picks none.
#[cfg(feature = "plugins")]
fn choose_plugins(bundled: &[bundled::Bundled]) -> Result<Vec<String>, String> {
    println!("Which bundled plugins should Haunt install?");
    for (i, b) in bundled.iter().enumerate() {
        match b.description.as_str() {
            "" => println!("  {}  {}", i + 1, b.name),
            d => println!("  {}  {}: {d}", i + 1, b.name),
        }
    }
    let answer = ask(&format!("Choose any of 1-{}, comma-separated, or Enter for none: ", bundled.len())).unwrap_or_default();
    let mut ids = vec![];
    for n in answer.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let b = n.parse::<usize>().ok().and_then(|i| bundled.get(i.checked_sub(1)?));
        let b = b.ok_or_else(|| format!("invalid choice {n:?}; choose numbers from 1-{}", bundled.len()))?;
        if !ids.contains(&b.id) {
            ids.push(b.id.clone());
        }
    }
    Ok(ids)
}

#[cfg(feature = "plugins")]
type Bundled = [bundled::Bundled];
#[cfg(not(feature = "plugins"))]
type Bundled = ();

fn setup(o: &Opts, bundled: &Bundled) -> Result<(), String> {
    let home = haunt_dir();
    let state = home.join("state.json");
    let mut plan = String::new();
    // Installs run from a content-addressed copy under ~/.haunt, so moving or rebuilding haunt.app can't break them.
    // Removal works by name (Claude) or by markers (Codex), so it runs from wherever the adapter is now.
    let mut plans = vec![];
    for &ag in &o.agents {
        let src = adapter_dir(ag)?;
        let dir = if o.remove { src.clone() } else { stage(ag, &src, &home)? };
        let preview = script(&dir, if o.remove { &["--remove", "--dry-run"] } else { &["--dry-run"] })?;
        plans.push((ag, src, dir, preview));
    }
    if o.none {
        plan += &format!("Just the terminal: no agent config changes. Haunt records the choice in {}.\n", state.display());
    }
    for (ag, src, dir, preview) in &plans {
        let from = format!("the adapter from {}, copied to {}", src.display(), dir.display());
        let what = match (ag, o.remove) {
            (Agent::Claude, false) => format!("Set up Claude Code with {from}. This runs:"),
            (Agent::Claude, true) => "Remove Claude Code's adapter. This runs:".to_owned(),
            (Agent::Codex, false) => format!("Set up Codex with {from}. This changes its config:"),
            (Agent::Codex, true) => "Remove Codex's adapter. This changes its config:".to_owned(),
        };
        plan += &what;
        plan.push('\n');
        for line in preview.lines() {
            plan += &format!("  {line}\n");
        }
        plan.push('\n');
    }
    #[cfg(feature = "plugins")]
    let (plugins, plugin_steps) = {
        let wanted: Vec<(&String, bool)> =
            o.plugins.iter().flatten().map(|id| (id, true)).chain(o.remove_plugins.iter().map(|id| (id, false))).collect();
        let plugins = if wanted.is_empty() { None } else { Some(bundled::Plugins::open(&home)?) };
        let mut steps = vec![];
        for (id, install) in wanted {
            let step = plugins.as_ref().expect("opened for any wanted plugin").plan(id, install, bundled)?;
            if o.none && steps.is_empty() {
                plan.push('\n');
            }
            plan += &step.text;
            plan.push('\n');
            steps.push(step);
        }
        (plugins, steps)
    };
    #[cfg(not(feature = "plugins"))]
    let _ = bundled;
    if !o.agents.is_empty() {
        let ids: Vec<&str> = o.agents.iter().map(|a| a.id()).collect();
        let (verb, prep) = if o.remove { ("removes", "from") } else { ("records", "in") };
        plan += &format!("Then Haunt {verb} {} {prep} {}.\n", ids.join(" and "), state.display());
    }
    if plan.is_empty() {
        plan = "No plugins chosen; nothing to do.\n".into();
    }
    print!("{plan}");
    let sha = hex(&Sha256::digest(plan.as_bytes()));
    if o.dry {
        println!("preview sha256 {sha}");
        return Ok(());
    }
    if let Some(want) = &o.expect
        && *want != sha
    {
        return Err(format!("the change above differs from the preview you approved ({want}); nothing changed"));
    }
    #[cfg(feature = "plugins")]
    let plugin_changes = plugin_steps.iter().any(|s| !matches!(s.action, bundled::Action::Nothing));
    #[cfg(not(feature = "plugins"))]
    let plugin_changes = false;
    // Just the terminal changes nothing, so it needs no yes; neither does a plan with nothing in it.
    if o.agents.is_empty() && !plugin_changes {
        if o.none {
            record(&state, &[], false)?;
        }
        return Ok(());
    }
    if o.agents.contains(&Agent::Claude) && find_on_path("claude").is_none() {
        return Err("claude is not on PATH; install Claude Code first".into());
    }
    if o.yes {
        println!("applying (--yes)");
    } else if !matches!(ask("Apply? [y/N] ").as_deref(), Some("y" | "yes")) {
        println!("nothing changed");
        return Ok(());
    }
    // Every step in order, so a failure can say what ran and what didn't.
    let verb = if o.remove { "remove" } else { "set up" };
    #[cfg_attr(not(feature = "plugins"), allow(unused_mut))]
    let mut todo: Vec<String> = plans.iter().map(|(ag, ..)| format!("{verb} {}", ag.name())).collect();
    #[cfg(feature = "plugins")]
    for s in plugin_steps.iter().filter(|s| !matches!(s.action, bundled::Action::Nothing)) {
        todo.push(format!("{} {}", if matches!(s.action, bundled::Action::Remove) { "remove" } else { "install" }, s.id));
    }
    let failed = |ran: usize, e: String| {
        let list = |l: &[String]| if l.is_empty() { "nothing".to_owned() } else { l.join(", ") };
        format!("{e}\n  done: {}\n  not done: {}", list(&todo[..ran]), list(&todo[ran + 1..]))
    };
    let mut done = vec![];
    let mut agent_failed = None;
    for (ag, _, dir, _) in &plans {
        let flag = if o.remove { "--remove" } else { "--apply" };
        let ok = Command::new(dir.join("install.sh")).arg(flag).status().is_ok_and(|s| s.success());
        if !ok {
            agent_failed = Some(format!("{} {flag} failed for {}", dir.join("install.sh").display(), ag.name()));
            break;
        }
        prune(&home, *ag, (!o.remove).then_some(dir.as_path()));
        done.push(*ag);
    }
    // The agents that did change are recorded even when a later one failed.
    if !done.is_empty() || o.none {
        record(&state, &done, o.remove)?;
    }
    if !done.is_empty() {
        let ids: Vec<&str> = done.iter().map(|a| a.id()).collect();
        let (verb, prep) = if o.remove { ("removed", "from") } else { ("recorded", "in") };
        println!("{verb} {} {prep} {}", ids.join(" and "), state.display());
    }
    if let Some(e) = agent_failed {
        return Err(failed(done.len(), e));
    }
    #[cfg(feature = "plugins")]
    for (i, s) in plugin_steps.iter().filter(|s| !matches!(s.action, bundled::Action::Nothing)).enumerate() {
        plugins.as_ref().expect("opened for any plugin step").apply(s).map_err(|e| failed(plans.len() + i, e))?;
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Runs install.sh and returns its stdout; it only prints in dry-run mode.
fn script(dir: &Path, args: &[&str]) -> Result<String, String> {
    let sh = dir.join("install.sh");
    let out = Command::new(&sh).args(args).output().map_err(|e| format!("{}: {e}", sh.display()))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_owned());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// `$HAUNT_<AGENT>_ADAPTER`, else the copy bundled in haunt.app, else (debug builds) `../haunt-plugins/<repo>`.
fn adapter_dir(ag: Agent) -> Result<PathBuf, String> {
    let (env, bundled, repo, marker) = ag.adapter();
    let candidates: Vec<PathBuf> = match std::env::var_os(env) {
        Some(p) => vec![PathBuf::from(p)],
        None => {
            let mut c = vec![];
            // The CLI sits in haunt.app/Contents/Helpers; resolved, so a symlink on PATH still finds the bundle.
            let exe = std::env::current_exe().and_then(std::fs::canonicalize).ok();
            if let Some(contents) = exe.and_then(|e| e.parent()?.parent().map(Path::to_owned)) {
                c.push(contents.join("Resources/adapters").join(bundled));
            }
            #[cfg(debug_assertions)]
            c.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../haunt-plugins").join(repo));
            c
        }
    };
    candidates
        .iter()
        .find(|d| d.join(marker).is_file() && d.join("install.sh").is_file())
        .map(|d| d.canonicalize().unwrap_or_else(|_| d.clone()))
        .ok_or_else(|| {
            let tried: Vec<String> = candidates.iter().map(|d| d.display().to_string()).collect();
            format!("the {} adapter is not at {}; clone {repo} there or set {env}", ag.name(), tried.join(" or "))
        })
}

/// Copies the adapter to `<haunt>/adapters/<agent>/<content hash>`, once; installs then point there.
fn stage(ag: Agent, src: &Path, home: &Path) -> Result<PathBuf, String> {
    if src.components().any(|c| c.as_os_str() == "AppTranslocation") {
        return Err(format!(
            "haunt.app is running from a temporary, translocated copy ({}). Move haunt.app to /Applications, open it from there, then set up again.",
            src.display()
        ));
    }
    let mut files = vec![];
    walk(src, Path::new(""), &mut files).map_err(|e| format!("{}: {e}", src.display()))?;
    files.sort();
    let mut h = Sha256::new();
    for rel in &files {
        let p = src.join(rel);
        let bytes = std::fs::read(&p).map_err(|e| format!("{}: {e}", p.display()))?;
        let exec = std::fs::metadata(&p).map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false);
        h.update(rel.to_string_lossy().as_bytes());
        h.update([0, exec as u8]);
        h.update((bytes.len() as u64).to_le_bytes());
        h.update(&bytes);
    }
    let rev = &hex(&h.finalize())[..16];
    let parent = home.join("adapters").join(ag.id());
    let dest = parent.join(rev);
    if dest.join("install.sh").is_file() {
        return Ok(dest);
    }
    let tmp = parent.join(format!(".{rev}.{}", std::process::id()));
    let copy = || -> std::io::Result<()> {
        let _ = std::fs::remove_dir_all(&tmp);
        for rel in &files {
            let to = tmp.join(rel);
            std::fs::create_dir_all(to.parent().unwrap_or(&tmp))?;
            std::fs::copy(src.join(rel), &to)?;
        }
        std::fs::rename(&tmp, &dest)
    };
    copy().map_err(|e| {
        let _ = std::fs::remove_dir_all(&tmp);
        format!("copying the {} adapter to {}: {e}", ag.name(), dest.display())
    })?;
    Ok(dest)
}

/// Every file under `dir`, relative to it, leaving out .git.
fn walk(root: &Path, rel: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for e in std::fs::read_dir(root.join(rel))? {
        let e = e?;
        let r = rel.join(e.file_name());
        let meta = std::fs::metadata(e.path())?;
        if meta.is_dir() {
            if e.file_name() != ".git" {
                walk(root, &r, out)?;
            }
        } else {
            out.push(r);
        }
    }
    Ok(())
}

/// Drops an agent's staged copies other than `keep`, once nothing points at them any more.
fn prune(home: &Path, ag: Agent, keep: Option<&Path>) {
    let parent = home.join("adapters").join(ag.id());
    let Ok(entries) = std::fs::read_dir(&parent) else { return };
    for e in entries.flatten() {
        if keep.is_none_or(|k| e.path() != k) {
            let _ = std::fs::remove_dir_all(e.path());
        }
    }
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(name)).find(|p| p.is_file())
}

/// Beside the app's config: `$HAUNT_CONFIG_DIR`, else `$HAUNT_HOME`, else `~/.haunt`.
fn haunt_dir() -> PathBuf {
    std::env::var_os("HAUNT_CONFIG_DIR").map_or_else(haunt_core::model::default_home, PathBuf::from)
}

/// Adds (or removes) agents in state.json's `agents`, keeping the app's other keys. The key's presence means setup ran.
fn record(path: &Path, agents: &[Agent], remove: bool) -> Result<(), String> {
    let mut obj = match std::fs::read(path) {
        Ok(b) => match serde_json::from_slice::<Value>(&b) {
            Ok(Value::Object(m)) => m,
            _ => return Err(format!("{} is not a JSON object; fix or delete it", path.display())),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Map::new(),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let mut list: Vec<String> = obj
        .get("agents")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
        .unwrap_or_default();
    for ag in agents {
        list.retain(|a| a != ag.id());
        if !remove {
            list.push(ag.id().to_owned());
        }
    }
    list.sort();
    obj.insert("agents".into(), list.into());
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let tmp = dir.join(format!(".state.json.{}", std::process::id()));
    std::fs::write(&tmp, Value::Object(obj).to_string()).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}
