//! Phase 2 gate: `haunt plugin install ./examples/hello` end to end.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::OnceLock;
use std::time::Instant;

use haunt_core::plugin_store::Store;
use haunt_core::plugins::PluginHost;

fn hello_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../examples/hello").canonicalize().unwrap()
}

/// Builds the example with the spike's toolchain (wasm32-wasip2, wit-bindgen) once per run.
fn hello() -> PathBuf {
    static BUILT: OnceLock<PathBuf> = OnceLock::new();
    BUILT
        .get_or_init(|| {
            let dir = hello_dir();
            let status = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
                .args(["build", "--release", "--target", "wasm32-wasip2"])
                .current_dir(&dir)
                .env_remove("CARGO_TARGET_DIR")
                .status()
                .unwrap();
            assert!(status.success(), "hello plugin build failed");
            dir
        })
        .clone()
}

fn home(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("haunt-cli-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

fn haunt(home: &Path, args: &[&str], stdin: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_haunt"))
        .args(args)
        .env("HAUNT_HOME", home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    child.wait_with_output().unwrap()
}

fn text(o: &Output) -> String {
    format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr))
}

#[test]
fn install_hello_prompts_then_core_reports_its_palette_item() {
    let src = hello();
    let home = home("gate");
    let src_arg = src.to_str().unwrap();

    let declined = haunt(&home, &["plugin", "install", src_arg], "n\n");
    let out = text(&declined);
    assert_eq!(declined.status.code(), Some(1), "{out}");
    assert!(out.contains("can see agent events (agent.task, agent.tool)"), "{out}");
    assert!(out.contains("palette"), "{out}");
    assert!(out.contains("Approve? [y/N]"), "{out}");
    assert!(text(&haunt(&home, &["plugin", "list"], "")).contains("no plugins installed"));

    let ok = haunt(&home, &["plugin", "install", src_arg], "y\n");
    assert!(ok.status.success(), "{}", text(&ok));
    let again = haunt(&home, &["plugin", "install", src_arg, "--yes"], "");
    assert!(text(&again).contains("no new capabilities"), "{}", text(&again));
    let listed = text(&haunt(&home, &["plugin", "list"], ""));
    assert!(listed.contains("dev.haunt.hello 0.1.0") && listed.contains("[ok]"), "{listed}");

    let host = PluginHost::new().unwrap();
    let store = Store::open(&home).unwrap();
    let t = Instant::now();
    let mut set = store.load_all(&host).unwrap();
    eprintln!("load_all (cached compile + instantiate + init): {:.2} ms", t.elapsed().as_secs_f64() * 1e3);
    assert!(set.errors().is_empty(), "{:?}", set.errors());
    let items = set.palette_items(None, "");
    assert_eq!(items.len(), 1, "{items:?}");
    assert_eq!((items[0].plugin_id.as_str(), items[0].id.as_str(), items[0].title.as_str()), ("dev.haunt.hello", "say-hello", "Say hello"));
    assert_eq!(items[0].default_key.as_deref(), Some("cmd+shift+h"));
    assert!(set.palette_items(None, "nothing like it").is_empty());

    set.invoke("dev.haunt.hello", "say-hello").unwrap();
    assert!(set.take_logs().iter().any(|(id, l)| id == "dev.haunt.hello" && l == "info hello: say-hello"));

    assert!(haunt(&home, &["plugin", "remove", "dev.haunt.hello"], "").status.success());
    assert!(text(&haunt(&home, &["plugin", "list"], "")).contains("no plugins installed"));
    std::fs::remove_dir_all(home).unwrap();
}

#[test]
fn tampered_installed_wasm_refuses_to_load() {
    let src = hello();
    let home = home("tamper");
    assert!(haunt(&home, &["plugin", "install", src.to_str().unwrap(), "--yes"], "").status.success());

    let wasm = home.join("plugins/dev.haunt.hello/plugin.wasm");
    let mut bytes = std::fs::read(&wasm).unwrap();
    let mid = bytes.len() / 2;
    bytes[mid] ^= 0x01;
    std::fs::write(&wasm, bytes).unwrap();

    let mut set = Store::open(&home).unwrap().load_all(&PluginHost::new().unwrap()).unwrap();
    assert!(set.ids().is_empty());
    assert!(set.errors()[0].contains("plugin.wasm does not match the lockfile"), "{:?}", set.errors());
    assert!(set.palette_items(None, "").is_empty());
    assert!(text(&haunt(&home, &["plugin", "list"], "")).contains("disabled: dev.haunt.hello: plugin.wasm does not match"));
    std::fs::remove_dir_all(home).unwrap();
}

#[test]
fn manifest_asking_for_terminal_read_is_rejected() {
    let src = hello();
    let home = home("termread");
    let bad = home.join("src");
    std::fs::create_dir_all(&bad).unwrap();
    std::fs::copy(src.join("target/wasm32-wasip2/release/hello_plugin.wasm"), bad.join("plugin.wasm")).unwrap();
    let manifest = std::fs::read_to_string(src.join("haunt-plugin.toml"))
        .unwrap()
        .replace("target/wasm32-wasip2/release/hello_plugin.wasm", "plugin.wasm")
        .replace("[capabilities]", "[capabilities]\nterminal_read = true");
    std::fs::write(bad.join("haunt-plugin.toml"), manifest).unwrap();

    let o = haunt(&home, &["plugin", "install", bad.to_str().unwrap(), "--yes"], "");
    assert_eq!(o.status.code(), Some(1));
    assert!(text(&o).contains("capability terminal_read is not supported"), "{}", text(&o));
    assert!(!home.join("plugins/dev.haunt.hello").exists());
    std::fs::remove_dir_all(home).unwrap();
}
