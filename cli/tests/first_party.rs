//! The first-party decision-log and allowlist plugins, installed with the CLI and fed by a real core.
#![cfg(feature = "plugins")]

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use haunt_core::plugin_store::{Store, attach};
use haunt_core::plugins::{Mark, PluginHost};
use haunt_core::{Core, SurfaceEnv};

const WASM: &str = "target/wasm32-wasip2/release/haunt_plugin.wasm";

/// `$HAUNT_PLUGINS_DIR/<name>`, by default from a haunt-plugins checkout next to this repo.
fn repo(name: &str) -> PathBuf {
    std::env::var_os("HAUNT_PLUGINS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../haunt-plugins"))
        .join(name)
}

fn build(dir: &Path) {
    let status = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
        .args(["build", "--release", "--target", "wasm32-wasip2"])
        .current_dir(dir)
        .env_remove("CARGO_TARGET_DIR")
        .status()
        .unwrap();
    assert!(status.success(), "{} failed to build", dir.display());
}

fn install(home: &Path, dir: &Path) {
    let o = Command::new(env!("CARGO_BIN_EXE_haunt"))
        .args(["plugin", "install", dir.to_str().unwrap(), "--yes"])
        .env("HAUNT_HOME", home)
        .output()
        .unwrap();
    assert!(o.status.success(), "{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
}

fn until(what: &str, f: impl Fn() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < Duration::from_secs(5), "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn send(sock: &mut UnixStream, env: &SurfaceEnv, body: &str) {
    let line = format!(r#"{{"v":1,"surface_id":"{}","nonce":"{}",{body}}}"#, env.surface_id, env.nonce);
    sock.write_all(format!("{line}\n").as_bytes()).unwrap();
}

#[test]
fn log_mode_and_suggestions_come_from_the_plugins() {
    let (log_repo, allow_repo) = (repo("haunt-decision-log"), repo("haunt-allowlist"));
    if !log_repo.join("haunt-plugin.toml").is_file() || !allow_repo.join("haunt-plugin.toml").is_file() {
        eprintln!("skipped: haunt-decision-log or haunt-allowlist not found next to this repo; set HAUNT_PLUGINS_DIR");
        return;
    }
    let tmp = PathBuf::from(format!("/tmp/haunt-fp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).unwrap();
    let tmp = tmp.canonicalize().unwrap();
    let (home, project) = (tmp.join("home"), tmp.join("project"));
    std::fs::create_dir_all(&project).unwrap();
    for dir in [&log_repo, &allow_repo] {
        build(dir);
        assert!(dir.join(WASM).is_file());
        install(&home, dir);
    }

    let core = Core::new(&home);
    core.start().unwrap();
    let set = Store::open(&home).unwrap().load_all(&PluginHost::new().unwrap(), Some(&core.handle())).unwrap();
    assert!(set.errors().is_empty(), "{:?}", set.errors());
    let set = Arc::new(Mutex::new(set));
    attach(&core, &set);

    let modes: Vec<_> = set.lock().unwrap().palette_items(None, "").into_iter().filter(|i| i.is_mode).collect();
    assert_eq!((modes.len(), modes[0].id.as_str(), modes[0].plugin_id.as_str()), (1, "log", "dev.haunt.decision-log"));

    let env = core.register_surface(project.to_str().unwrap()).unwrap();
    let p = project.display();
    let perm = format!(r#""event":"permission_seen","cwd":"{p}","tool_name":"Bash","tool_input":{{"command":"cargo test"}}"#);
    let ran = format!(r#""event":"tool_ran","cwd":"{p}","tool_name":"Bash","tool_input":{{"command":"cargo test"}}"#);
    let pending = || core.snapshot().groups.iter().flat_map(|g| &g.rows).find_map(|r| r.pending.clone());
    let decided = |n| core.decisions("", 100).len() == n;
    // One connection is served by one thread, line by line, so once a request shows up the
    // plugins have seen every tool event before it.
    let mut sock = UnixStream::connect(&env.socket_path).unwrap();
    for i in 1..=3 {
        send(&mut sock, &env, &perm);
        until("the request", || pending().is_some());
        assert!(core.allow_suggestions().is_empty(), "no suggestion after {} approvals", i - 1);
        assert_eq!(core.answer_permission(&env.surface_id, pending().unwrap().key, true), Some(b"1".to_vec()));
        assert!(decided(i));
        send(&mut sock, &env, &ran);
    }
    until("the allowlist plugin to propose", || !core.allow_suggestions().is_empty());
    let s = core.allow_suggestions();
    assert_eq!(s.len(), 1);
    assert_eq!((s[0].rule.as_str(), s[0].approvals, s[0].plugin_id.as_str()), ("Bash(cargo test)", 3, "dev.haunt.allowlist"));
    assert!(!project.join(".claude").exists(), "a proposal writes nothing");

    let rows = set.lock().unwrap().palette_items(Some("log"), "cargo");
    assert_eq!(rows.len(), 3, "{rows:?}");
    assert_eq!(rows[0].title, "You approved cargo test");
    assert_eq!(rows[0].subtitle.as_deref(), Some("project"));
    assert_eq!((rows[0].mark, rows[0].surface_id.as_deref()), (Some(Mark::Open), Some(env.surface_id.as_str())));
    assert!(rows[0].at_ms.is_some_and(|t| t > 0));
    assert!(set.lock().unwrap().palette_items(Some("log"), "no such thing").is_empty());

    core.accept_allow_suggestion(project.to_str().unwrap(), "cargo test").unwrap();
    let written = std::fs::read_to_string(project.join(".claude/settings.local.json")).unwrap();
    assert!(written.contains("\"Bash(cargo test)\""), "{written}");
    assert!(core.allow_suggestions().is_empty());

    drop(core);
    std::fs::remove_dir_all(&tmp).unwrap();
}

#[test]
fn the_tabs_plugin_arranges_but_never_buries_a_row_that_needs_you() {
    let dir = repo("haunt-tabs");
    if !dir.join("haunt-plugin.toml").is_file() {
        eprintln!("skipped: haunt-tabs not found next to this repo; set HAUNT_PLUGINS_DIR");
        return;
    }
    let home = PathBuf::from(format!("/tmp/haunt-fp-tabs-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    build(&dir);
    install(&home, &dir);

    let core = Core::new(&home);
    core.start().unwrap();
    let envs: Vec<_> = ["/a", "/b", "/c"].iter().map(|cwd| core.register_surface(cwd).unwrap()).collect();
    let set = Store::open(&home).unwrap().load_all(&PluginHost::new().unwrap(), Some(&core.handle())).unwrap();
    assert!(set.errors().is_empty(), "{:?}", set.errors());
    let set = Arc::new(Mutex::new(set));
    attach(&core, &set);
    let layout = || core.snapshot().groups.iter().map(|g| (g.id.clone(), g.rows.iter().map(|r| r.name.clone()).collect::<Vec<_>>())).collect::<Vec<_>>();
    let names = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert_eq!(layout(), [("idle".to_owned(), names(&["c", "b", "a"]))], "Haunt's own order until the user arranges");

    let (a, b, c) = (&envs[0].surface_id, &envs[1].surface_id, &envs[2].surface_id);
    let menu = set.lock().unwrap().row_menu(c);
    assert!(menu.iter().any(|m| m.id == "pin" && !m.checked && m.plugin_id == "dev.haunt.tabs"), "{menu:?}");
    assert!(menu.iter().any(|m| m.id == "color:blue" && m.parent.as_deref() == Some("color-menu")));
    set.lock().unwrap().invoke_row_item("dev.haunt.tabs", "pin", c).unwrap();
    set.lock().unwrap().invoke_row_item("dev.haunt.tabs", "color:blue", a).unwrap();
    set.lock().unwrap().row_moved(a, "idle", Some(b));
    assert_eq!(layout(), [("pinned".to_owned(), names(&["c"])), ("idle".to_owned(), names(&["a", "b"]))]);
    let snap = core.snapshot();
    assert_eq!((snap.groups[1].rows[0].color, snap.groups[1].rows[1].color), (Some(haunt_core::TabColor::Blue), None));
    assert!(set.lock().unwrap().row_menu(c).iter().any(|m| m.id == "pin" && m.checked));

    let mut sock = UnixStream::connect(&envs[2].socket_path).unwrap();
    send(&mut sock, &envs[2], r#""event":"permission_seen","tool_name":"Bash","tool_input":{"command":"ls"}"#);
    until("the pinned tab to need you", || layout()[0].0 == "needs-you");
    assert_eq!(layout(), [("needs-you".to_owned(), names(&["c"])), ("idle".to_owned(), names(&["a", "b"]))], "a pin can't hold it back");
    set.lock().unwrap().row_moved(c, "idle", None);
    assert_eq!(layout()[0], ("needs-you".to_owned(), names(&["c"])), "nor can a drag");

    drop(core);
    let _ = std::fs::remove_dir_all(&home);
}
