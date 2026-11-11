//! The first-party plugins, installed with the CLI and fed by a real core.
#![cfg(feature = "plugins")]

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use haunt_core::plugin_store::{Store, attach};
use haunt_core::plugin_settings::PluginConfig;
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
    let call = |event: &str, i: usize| format!(r#""event":"{event}","cwd":"{p}","tool_name":"Bash","tool_use_id":"t{i}","tool_input":{{"command":"cargo test"}}"#);
    let pending = || core.snapshot().groups.iter().flat_map(|g| &g.rows).find_map(|r| r.pending.clone());
    let decided = |n| core.decisions("", 100).len() == n;
    // The plugins get the events in order, on their own thread, so the test waits for them.
    let mut sock = UnixStream::connect(&env.socket_path).unwrap();
    for i in 1..=3 {
        send(&mut sock, &env, &call("tool_start", i));
        send(&mut sock, &env, &perm);
        until("the request", || pending().is_some());
        assert!(core.allow_suggestions().is_empty(), "no suggestion after {} approvals", i - 1);
        assert_eq!(core.answer_permission(&env.surface_id, pending().unwrap().key, true), Some(b"1".to_vec()));
        assert!(decided(i));
        send(&mut sock, &env, &call("tool_ran", i));
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
    let dir = repo("haunt-tabs-plus");
    if !dir.join("haunt-plugin.toml").is_file() {
        eprintln!("skipped: haunt-tabs-plus not found next to this repo; set HAUNT_PLUGINS_DIR");
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
    assert!(menu.iter().any(|m| m.id == "pin" && !m.checked && m.plugin_id == "dev.haunt.tabs-plus"), "{menu:?}");
    assert!(menu.iter().any(|m| m.id == "color:blue" && m.parent.as_deref() == Some("color-menu")));
    set.lock().unwrap().invoke_row_item("dev.haunt.tabs-plus", "pin", c).unwrap();
    set.lock().unwrap().invoke_row_item("dev.haunt.tabs-plus", "color:blue", a).unwrap();
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

#[test]
fn a_user_command_types_into_the_selected_tab_through_the_gate() {
    let dir = repo("haunt-commands");
    if !dir.join("haunt-plugin.toml").is_file() {
        eprintln!("skipped: haunt-commands not found next to this repo; set HAUNT_PLUGINS_DIR");
        return;
    }
    let home = PathBuf::from(format!("/tmp/haunt-fp-commands-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    build(&dir);
    install(&home, &dir);

    let core = Core::new(&home);
    core.start().unwrap();
    let (a, b) = (core.register_surface("/a").unwrap(), core.register_surface("/b").unwrap());
    core.select_surface(&a.surface_id);
    let config = |cmds: &str| PluginConfig::parse(&format!("[plugins.\"dev.haunt.commands\"]\ncommands = [{cmds}]\nshell = \"/bin/sh\"\n"));
    let deploy = r#"{ id = "deploy", name = "Deploy staging", text = "make deploy ENV=staging", enter = true }"#;
    let mut set = Store::open(&home).unwrap().load_all_with(&PluginHost::new().unwrap(), Some(&core.handle()), &config(deploy)).unwrap();
    assert!(set.errors().is_empty(), "{:?}", set.errors());
    assert_eq!(set.settings_problems().len(), 1, "the undeclared key: {:?}", set.settings_problems());
    let items = set.palette_items(None, "");
    assert_eq!(items.iter().map(|i| (i.plugin_id.as_str(), i.id.as_str(), i.title.as_str())).collect::<Vec<_>>(), [("dev.haunt.commands", "deploy", "Deploy staging")]);

    set.invoke("dev.haunt.commands", "deploy", true).unwrap();
    let reqs = set.take_requests();
    assert_eq!(reqs.len(), 1, "{reqs:?}");
    let w = core.gate_plugin_request(&reqs[0]).unwrap();
    assert_eq!((w.surface_id.as_str(), w.bytes.as_slice(), w.enter), (a.surface_id.as_str(), b"make deploy ENV=staging".as_slice(), true));

    set.invoke("dev.haunt.commands", "deploy", true).unwrap();
    core.select_surface(&b.surface_id);
    let reqs = set.take_requests();
    assert_eq!(core.gate_plugin_request(&reqs[0]), None, "the tab it was run in is no longer selected");

    set.invoke("dev.haunt.commands", "deploy", false).unwrap();
    assert!(set.take_requests().is_empty(), "nothing while the agents view or review hides the terminal");

    assert!(!set.set_config(&PluginConfig::parse("[plugins\n")), "a config.toml that doesn't parse changes nothing");
    assert!(set.settings_problems()[0].contains("keeping the previous plugin settings"), "{:?}", set.settings_problems());
    set.invoke("dev.haunt.commands", "deploy", true).unwrap();
    assert_eq!(core.gate_plugin_request(&set.take_requests()[0]).unwrap().bytes, b"make deploy ENV=staging", "the command survived it");
    assert!(set.set_config(&config(deploy)), "the good file after a broken one is applied again");
    assert_eq!(set.settings_problems().len(), 1, "the undeclared key, not the parse error: {:?}", set.settings_problems());
    assert!(!set.settings_problems()[0].contains("keeping the previous plugin settings"));
    assert_eq!(set.palette_items(None, "").len(), 1, "same settings, so the command stays");
    assert!(!set.set_config(&config(deploy)), "an unchanged [plugins] calls no plugin");

    assert!(set.set_config(&config(r#"{ id = "st", name = "Git status", text = "git status" }"#)));
    let ids: Vec<_> = set.palette_items(None, "").into_iter().map(|i| i.id).collect();
    assert_eq!(ids, ["st"], "a reload registers the new command and drops the removed one");
    set.invoke("dev.haunt.commands", "st", true).unwrap();
    let w = core.gate_plugin_request(&set.take_requests()[0]).unwrap();
    assert_eq!((w.surface_id.as_str(), w.bytes.as_slice(), w.enter), (b.surface_id.as_str(), b"git status".as_slice(), false));
    set.invoke("dev.haunt.commands", "deploy", true).unwrap();
    assert!(set.take_requests().is_empty(), "a removed command types nothing");

    let huge = format!(r#"{{ id = "big", name = "Big", text = "{}" }}"#, "x".repeat(4000));
    let many = vec![huge; 70].join(", ");
    assert!(set.set_config(&config(&many)));
    assert!(set.settings_problems().iter().any(|p| p.contains("keeping the previous ones")), "{:?}", set.settings_problems());
    assert!(set.palette_items(None, "").iter().any(|i| i.id == "st"), "over the cap keeps the previous settings");

    drop(core);
    let _ = std::fs::remove_dir_all(&home);
}
