//! `haunt setup`: installs or removes agent adapters through their install.sh, after showing the exact change.

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::{Map, Value};

const USAGE: &str = "usage:
  haunt setup                          ask which agents to set up
  haunt setup <claude|codex>... [--yes] [--dry-run]
  haunt setup none                     just the terminal: record the choice, change nothing
  haunt setup --remove <claude|codex>... [--yes] [--dry-run]";

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
}

pub fn run(args: &[String]) -> u8 {
    let mut o = Opts { agents: vec![], none: false, remove: false, yes: false, dry: false };
    for a in args {
        match a.as_str() {
            "--yes" | "-y" => o.yes = true,
            "--dry-run" => o.dry = true,
            "--remove" => o.remove = true,
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
    if (o.none && (o.remove || !o.agents.is_empty())) || (o.remove && o.agents.is_empty()) {
        return usage();
    }
    if !o.none && o.agents.is_empty() {
        if o.yes {
            eprintln!("haunt setup: --yes needs the agents to set up, e.g. haunt setup claude --yes");
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
    }
    match setup(&o) {
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

fn setup(o: &Opts) -> Result<(), String> {
    let state = state_path();
    if o.none {
        println!("Just the terminal: no agent config changes. Haunt records the choice in {}.", state.display());
        if !o.dry {
            record(&state, &[], false)?;
        }
        return Ok(());
    }
    let mut plans = vec![];
    for &ag in &o.agents {
        let dir = adapter_dir(ag)?;
        let preview = script(&dir, if o.remove { &["--remove", "--dry-run"] } else { &["--dry-run"] })?;
        plans.push((ag, dir, preview));
    }
    for (ag, dir, preview) in &plans {
        let what = match (ag, o.remove) {
            (Agent::Claude, false) => format!("Set up Claude Code with the adapter in {}. This runs:", dir.display()),
            (Agent::Claude, true) => "Remove Claude Code's adapter. This runs:".to_owned(),
            (Agent::Codex, false) => format!("Set up Codex with the adapter in {}. This changes its config:", dir.display()),
            (Agent::Codex, true) => "Remove Codex's adapter. This changes its config:".to_owned(),
        };
        println!("{what}");
        for line in preview.lines() {
            println!("  {line}");
        }
        println!();
    }
    let ids: Vec<&str> = o.agents.iter().map(|a| a.id()).collect();
    let (verb, prep) = if o.remove { ("removes", "from") } else { ("records", "in") };
    println!("Then Haunt {verb} {} {prep} {}.", ids.join(" and "), state.display());
    if o.dry {
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
    let mut done = vec![];
    let mut failed = None;
    for (ag, dir, _) in &plans {
        let flag = if o.remove { "--remove" } else { "--apply" };
        let ok = Command::new(dir.join("install.sh")).arg(flag).status().is_ok_and(|s| s.success());
        if !ok {
            failed = Some(format!("{} {flag} failed for {}", dir.join("install.sh").display(), ag.name()));
            break;
        }
        done.push(*ag);
    }
    if !done.is_empty() {
        record(&state, &done, o.remove)?;
        let ids: Vec<&str> = done.iter().map(|a| a.id()).collect();
        let (verb, prep) = if o.remove { ("removed", "from") } else { ("recorded", "in") };
        println!("{verb} {} {prep} {}", ids.join(" and "), state.display());
    }
    failed.map_or(Ok(()), Err)
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

/// `$HAUNT_<AGENT>_ADAPTER`, else the copy bundled in haunt.app, else `../haunt-plugins/<repo>` beside this checkout.
fn adapter_dir(ag: Agent) -> Result<PathBuf, String> {
    let (env, bundled, repo, marker) = ag.adapter();
    let candidates: Vec<PathBuf> = match std::env::var_os(env) {
        Some(p) => vec![PathBuf::from(p)],
        None => {
            let mut c = vec![];
            // The CLI sits in haunt.app/Contents/Helpers.
            if let Some(contents) = std::env::current_exe().ok().and_then(|e| e.parent()?.parent().map(Path::to_owned)) {
                c.push(contents.join("Resources/adapters").join(bundled));
            }
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

fn find_on_path(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(name)).find(|p| p.is_file())
}

/// state.json beside the app's config: `$HAUNT_CONFIG_DIR`, else `$HAUNT_HOME`, else `~/.haunt`.
fn state_path() -> PathBuf {
    let dir = std::env::var_os("HAUNT_CONFIG_DIR").map_or_else(haunt_core::plugin_store::default_home, PathBuf::from);
    dir.join("state.json")
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
