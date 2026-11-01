//! `haunt plugin …`: install, list, remove, approve. Operates on `~/.haunt` directly.

use std::io::{BufRead, IsTerminal, Write};
use std::path::Path;

use haunt_core::plugin_store::{Installed, Prompt, Store, default_home};
use haunt_core::plugins::PluginHost;

const USAGE: &str = "usage:
  haunt plugin install <path> [--yes]
  haunt plugin list
  haunt plugin remove <id>
  haunt plugin approve <id> [--yes]";

pub fn run(args: &[String]) -> u8 {
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
    match res {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("haunt plugin: {e}");
            1
        }
    }
}

fn open() -> Result<Store, String> {
    Store::open(&default_home()).map_err(|e| e.to_string())
}

fn host() -> Result<PluginHost, String> {
    PluginHost::new().map_err(|e| e.to_string())
}

fn show(p: &Prompt) {
    let red = std::io::stdout().is_terminal();
    if let Some(old) = &p.replaces {
        println!("replaces {} installed from {old}", p.id);
    }
    match (&p.update_from, p.changed_on_disk) {
        (Some(from), _) => println!("{} ({}) {from} -> {} asks for new capabilities:", p.name, p.id, p.version),
        (None, true) => println!("{} ({}) {} changed on disk since it was approved. It:", p.name, p.id, p.version),
        (None, false) => println!("{} ({}) {}:", p.name, p.id, p.version),
    }
    for (line, danger) in &p.lines {
        if *danger && red {
            println!("  - \x1b[31m{line}\x1b[0m");
        } else {
            println!("  - {line}");
        }
    }
    if p.update_from.is_none() {
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
