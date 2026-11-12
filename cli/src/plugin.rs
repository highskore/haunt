//! `haunt plugin …`: new, install, list, remove, approve. Operates on `~/.haunt` directly.

use std::io::{BufRead, IsTerminal, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use haunt_core::plugin_manifest::{escape_hidden, valid_id};
use haunt_core::model::default_home;
use haunt_core::plugin_store::{Installed, Prompt, Store};
use haunt_core::plugins::PluginHost;

const USAGE: &str = "usage:
  haunt plugin new <name> [--dir <path>] [--id <reverse-dns id>]
  haunt plugin install <path> [--yes]
  haunt plugin list
  haunt plugin remove <id>
  haunt plugin approve <id> [--yes]";

pub fn run(args: &[String]) -> u8 {
    if args.first().is_some_and(|a| a == "new") {
        return finish(new(&args[1..]));
    }
    let yes = args.iter().any(|a| a == "--yes" || a == "-y");
    let pos: Vec<&str> = args.iter().map(String::as_str).filter(|a| !a.starts_with('-')).collect();
    let res = match pos.as_slice() {
        ["install", path] => install(Path::new(path), yes),
        ["list"] => list(),
        ["remove", id] => open().and_then(|s| s.remove(id).map_err(|e| e.to_string())).map(|_| println!("removed {id}")),
        ["approve", id] => approve(id, yes),
        _ => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    finish(res)
}

fn finish(res: Result<(), String>) -> u8 {
    match res {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("haunt plugin: {e}");
            1
        }
    }
}

/// Snapshot of the haunt-plugin-template repo; the WIT comes from this checkout so it matches the host.
const TEMPLATE: &[(&str, &str)] = &[
    (".gitignore", include_str!("../template/.gitignore")),
    ("Cargo.lock", include_str!("../template/Cargo.lock")),
    ("Cargo.toml", include_str!("../template/Cargo.toml")),
    ("LICENSE", include_str!("../template/LICENSE")),
    ("README.md", include_str!("../template/README.md")),
    ("build.sh", include_str!("../template/build.sh")),
    ("haunt-plugin.toml", include_str!("../template/haunt-plugin.toml")),
    ("rust-toolchain.toml", include_str!("../template/rust-toolchain.toml")),
    ("src/lib.rs", include_str!("../template/src/lib.rs")),
    ("tests/manifest.rs", include_str!("../template/tests/manifest.rs")),
    ("wit/haunt-plugin.wit", include_str!("../../wit/haunt-plugin.wit")),
];

fn new(args: &[String]) -> Result<(), String> {
    let (mut name, mut dir, mut id) = (None, None, None);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--dir" => dir = Some(PathBuf::from(it.next().ok_or(USAGE)?)),
            "--id" => id = Some(it.next().ok_or(USAGE)?.clone()),
            s if !s.starts_with('-') && name.is_none() => name = Some(s),
            _ => return Err(USAGE.into()),
        }
    }
    let name = name.ok_or(USAGE)?;
    let slug = name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    if name.is_empty() || name.starts_with('-') || !slug {
        return Err(format!("name {name:?} must be lowercase letters, digits and '-'"));
    }
    let id = id.unwrap_or_else(|| format!("dev.haunt.{name}"));
    if !valid_id(&id) {
        return Err(format!("id {id:?} must be reverse-DNS: lowercase letters, digits and '-', dot separated"));
    }
    let dir = dir.unwrap_or_else(|| PathBuf::from(name));
    if dir.exists() && !dir.read_dir().is_ok_and(|mut d| d.next().is_none()) {
        return Err(format!("{} is not an empty folder", dir.display()));
    }
    let fill = |t: &str| t.replace("{{id}}", &id).replace("{{name}}", name).replace("{{description}}", "A Haunt plugin.");
    for (path, text) in TEMPLATE {
        let dest = dir.join(path);
        let parent = dest.parent().unwrap_or(&dir);
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        std::fs::write(&dest, fill(text)).map_err(|e| format!("{}: {e}", dest.display()))?;
    }
    std::fs::set_permissions(dir.join("build.sh"), std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
    match Command::new("git").args(["init", "-q"]).current_dir(&dir).status() {
        Ok(s) if s.success() => {}
        _ => eprintln!("haunt plugin: git init failed in {}; the files are written", dir.display()),
    }
    println!("created {id} in {}", dir.display());
    println!("next: cd {} && cargo build --release --target wasm32-wasip2 && haunt plugin install .", dir.display());
    Ok(())
}

fn open() -> Result<Store, String> {
    Store::open(&default_home()).map_err(|e| e.to_string())
}

fn host() -> Result<PluginHost, String> {
    PluginHost::new().map_err(|e| e.to_string())
}

fn show(p: &Prompt) {
    // Manifest text is checked when parsed; escaping here still keeps a terminal from acting on it.
    let e = escape_hidden;
    let red = std::io::stdout().is_terminal();
    if let Some(old) = &p.replaces {
        println!("replaces {} installed from {}", e(&p.id), e(old));
    }
    let (name, id, version) = (e(&p.name), e(&p.id), e(&p.version));
    match (&p.update_from, p.changed_on_disk) {
        (Some(from), _) => println!("{name} ({id}) {} -> {version} asks for new capabilities:", e(from)),
        (None, true) => println!("{name} ({id}) {version} changed on disk since it was approved. It:"),
        (None, false) => println!("{name} ({id}) {version}:"),
    }
    for (line, danger) in &p.lines {
        let line = e(line);
        if *danger && red {
            println!("  - \x1b[31m{line}\x1b[0m");
        } else {
            println!("  - {line}");
        }
    }
    if p.update_from.is_none() && !p.always.is_empty() {
        println!("  - {}", p.always);
    }
}

/// Shows the prompt; `--yes` approves, otherwise only a typed y/yes does.
fn asker(yes: bool) -> impl FnMut(&Prompt) -> bool {
    move |p| {
        show(p);
        if yes {
            println!("approved (--yes)");
            return true;
        }
        print!("Approve? [y/N] ");
        let _ = std::io::stdout().flush();
        let mut answer = String::new();
        if std::io::stdin().lock().read_line(&mut answer).is_err() {
            return false;
        }
        matches!(answer.trim().to_lowercase().as_str(), "y" | "yes")
    }
}

fn install(path: &Path, yes: bool) -> Result<(), String> {
    let store = open()?;
    let res = store.install(path, &host()?, &mut asker(yes)).map_err(|e| e.to_string())?;
    match res {
        Installed::New => println!("installed into {}", store.plugins_dir().display()),
        Installed::Replaced { old_source } => println!("replaced the plugin from {old_source}"),
        Installed::Updated { prompted: false } => println!("updated; no new capabilities"),
        Installed::Updated { prompted: true } => println!("updated"),
    }
    Ok(())
}

fn approve(id: &str, yes: bool) -> Result<(), String> {
    open()?.approve(id, &host()?, &mut asker(yes)).map_err(|e| e.to_string())?;
    println!("approved {id}");
    Ok(())
}

fn list() -> Result<(), String> {
    let all = open()?.list().map_err(|e| e.to_string())?;
    if all.is_empty() {
        println!("no plugins installed");
    }
    for l in all {
        let e = &l.entry;
        let status = l.problem.as_deref().map_or("ok".to_owned(), |p| format!("disabled: {p}"));
        println!("{} {}  {}  [{status}]", e.id, e.version, e.source);
        for (line, _) in e.granted.describe() {
            println!("    {line}");
        }
    }
    Ok(())
}
