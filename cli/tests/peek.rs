//! End to end against a real haunt core. Copy into haunt's `cli/tests/` and run
//! `cargo test -p haunt-cli --features plugins --test peek` (see README).
#![cfg(feature = "plugins")]

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use haunt_core::plugin_panel::{PanelNodeKind, PanelPlacement};
use haunt_core::plugin_store::{PluginSet, Store, attach};
use haunt_core::plugins::{HostRequest, PluginHost};
use haunt_core::{Core, SurfaceEnv};

const ID: &str = "dev.haunt.peek";

fn repo() -> PathBuf {
    std::env::var_os("HAUNT_PLUGINS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../haunt-plugins"))
        .join("haunt-peek")
}

fn send(sock: &mut UnixStream, env: &SurfaceEnv, rest: &str) {
    let line = format!(r#"{{"v":1,"agent":"claude","surface_id":"{}","nonce":"{}","session_id":"s1","cwd":"/tmp/web",{rest}}}"#, env.surface_id, env.nonce);
    sock.write_all(format!("{line}\n").as_bytes()).unwrap();
}

/// The card's (title, lines) when shown, `None` when closed.
fn cards(set: &Mutex<PluginSet>) -> Vec<Option<(String, Vec<String>)>> {
    set.lock().unwrap().take_requests().into_iter().filter_map(|r| match r {
        HostRequest::ShowPanel { plugin_id, panel, .. } if plugin_id == ID => {
            assert_eq!((panel.id.as_str(), panel.placement), ("peek", PanelPlacement::Card));
            let lines = panel.nodes.iter().map(|n| match &n.kind {
                PanelNodeKind::Text { text, mono: true, .. } => text.clone(),
                k => panic!("{k:?}"),
            });
            Some(Some((panel.title, lines.collect())))
        }
        HostRequest::ClosePanel { plugin_id, id } if plugin_id == ID && id == "peek" => Some(None),
        _ => None,
    }).collect()
}

fn until(what: &str, f: impl Fn() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < Duration::from_secs(5), "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn holding_option_over_a_row_shows_that_tabs_screen_until_let_go() {
    let dir = repo();
    if !dir.join("haunt-plugin.toml").is_file() {
        eprintln!("skipped: haunt-peek not found; set HAUNT_PLUGINS_DIR");
        return;
    }
    let home = PathBuf::from(format!("/tmp/haunt-fp-peek-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    // Built into this run's own folder, never into the plugin's checkout, then installed from a copy
    // of its manifest pointing at that wasm.
    let build = home.with_extension("build");
    let status = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
        .args(["build", "--release", "--target", "wasm32-wasip2"])
        .current_dir(&dir)
        .env("CARGO_TARGET_DIR", build.join("target"))
        .status()
        .unwrap();
    assert!(status.success());
    let manifest = std::fs::read_to_string(dir.join("haunt-plugin.toml")).unwrap();
    let entry = manifest.lines().find_map(|l| l.strip_prefix("entry = \"")?.strip_suffix('"')).expect("an entry");
    let built = build.join("target").join(entry.strip_prefix("target/").expect("entry under target/"));
    let src = build.join("plugin");
    std::fs::create_dir_all(&src).unwrap();
    std::fs::copy(&built, src.join("plugin.wasm")).unwrap();
    std::fs::write(src.join("haunt-plugin.toml"), manifest.replace(&format!("entry = \"{entry}\""), "entry = \"plugin.wasm\"")).unwrap();
    let o = Command::new(env!("CARGO_BIN_EXE_haunt")).args(["plugin", "install", src.to_str().unwrap(), "--yes"]).env("HAUNT_HOME", &home).output().unwrap();
    assert!(o.status.success(), "{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));

    let core = Core::new(&home);
    core.start().unwrap();
    let (web, quiet) = (core.register_surface("/tmp").unwrap(), core.register_surface("/tmp").unwrap());
    let screen = Arc::new(Mutex::new(Vec::new()));
    let reads = screen.clone();
    core.handle().set_screen_reader(Some(Arc::new(move |s: &str, n: u32| {
        reads.lock().unwrap().push((s.to_owned(), n));
        Some(vec!["$ npm test session".into(), " PASS  session.test.ts\u{1b}]52;c;cm0gLXJmIH4=\u{7}".into(), " RUNS  refresh.test.ts".into(), String::new()])
    })));
    let set = Store::open(&home).unwrap().load_all(&PluginHost::new().unwrap(), Some(&core.handle())).unwrap();
    assert!(set.errors().is_empty(), "{:?}", set.errors());
    let set = Arc::new(Mutex::new(set));
    attach(&core, &set);
    assert_eq!(set.lock().unwrap().hover_holder().as_deref(), Some(ID));

    let mut sock = UnixStream::connect(&web.socket_path).unwrap();
    send(&mut sock, &web, r#""event":"prompt_submit""#);
    let titled = || {
        set.lock().unwrap().hover_hold(ID, true, &web.surface_id).unwrap();
        let c = cards(&set);
        let logs = set.lock().unwrap().take_logs();
        assert!(!c.is_empty(), "no card: {logs:?}");
        set.lock().unwrap().hover_hold(ID, false, &web.surface_id).unwrap();
        assert_eq!(cards(&set), [None]);
        matches!(c.as_slice(), [Some((t, _))] if t == "web")
    };
    until("the prompt to name the agent", titled);
    screen.lock().unwrap().clear();

    set.lock().unwrap().hover_hold(ID, true, &web.surface_id).unwrap();
    let shown = cards(&set);
    let [Some((title, lines))] = shown.as_slice() else { panic!("{shown:?}") };
    assert_eq!(title, "web", "titled with the agent's name");
    assert_eq!(lines[0], "$ npm test session");
    assert!(lines[1].starts_with(" PASS  session.test.ts") && !lines[1].contains('\u{1b}') && !lines[1].contains('\u{7}'), "{lines:?}");
    assert_eq!(screen.lock().unwrap().as_slice(), [(web.surface_id.clone(), 8)]);

    set.lock().unwrap().hover_hold(ID, false, &web.surface_id).unwrap();
    assert_eq!(cards(&set), [None]);

    set.lock().unwrap().hover_hold(ID, true, &quiet.surface_id).unwrap();
    let shown = cards(&set);
    assert!(matches!(shown.as_slice(), [Some((t, _))] if t == "terminal"), "a tab without an agent: {shown:?}");

    std::fs::remove_dir_all(&home).unwrap();
    std::fs::remove_dir_all(&build).unwrap();
}
