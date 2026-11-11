//! Phase 2 gate: `haunt plugin new` scaffolds a plugin that builds and installs end to end.
#![cfg(feature = "plugins")]

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::OnceLock;
use std::time::Instant;

use haunt_core::plugin_store::Store;
use haunt_core::plugin_theme::ThemeToken;
use haunt_core::plugins::PluginHost;

const WASM: &str = "target/wasm32-wasip2/release/haunt_plugin.wasm";

/// Scaffolds `dev.haunt.hello` from the embedded template and builds it for wasm32-wasip2, once per run.
fn hello() -> PathBuf {
    static BUILT: OnceLock<PathBuf> = OnceLock::new();
    BUILT
        .get_or_init(|| {
            let parent = home("scaffold");
            std::fs::create_dir_all(&parent).unwrap();
            let dir = parent.canonicalize().unwrap().join("hello");
            let o = haunt(&parent, &["plugin", "new", "hello", "--id", "dev.haunt.hello", "--dir", dir.to_str().unwrap()], "");
            assert!(o.status.success(), "{}", text(&o));
            let status = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()))
                .args(["build", "--release", "--target", "wasm32-wasip2"])
                .current_dir(&dir)
                .env_remove("CARGO_TARGET_DIR")
                .status()
                .unwrap();
            assert!(status.success(), "scaffolded plugin build failed");
            // Keep only the wasm so each run leaves kilobytes in the temp dir, not a full target/.
            let wasm = std::fs::read(dir.join(WASM)).unwrap();
            std::fs::remove_dir_all(dir.join("target")).unwrap();
            std::fs::create_dir_all(dir.join(WASM).parent().unwrap()).unwrap();
            std::fs::write(dir.join(WASM), wasm).unwrap();
            dir
        })
        .clone()
}

#[test]
fn scaffold_fills_placeholders_and_inits_git() {
    let dir = hello();
    for f in ["haunt-plugin.toml", "Cargo.toml", "README.md", "src/lib.rs", "wit/haunt-plugin.wit"] {
        assert!(!std::fs::read_to_string(dir.join(f)).unwrap().contains("{{"), "{f} still has a placeholder");
    }
    let manifest = std::fs::read_to_string(dir.join("haunt-plugin.toml")).unwrap();
    assert!(manifest.contains("id = \"dev.haunt.hello\"") && manifest.contains("name = \"hello\""), "{manifest}");
    assert!(manifest.contains(&format!("entry = \"{WASM}\"")), "{manifest}");
    assert!(dir.join(WASM).is_file());
    assert_eq!(
        std::fs::read_to_string(dir.join("wit/haunt-plugin.wit")).unwrap(),
        std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../wit/haunt-plugin.wit")).unwrap()
    );
    assert!(dir.join(".git").is_dir());
    assert_eq!(std::fs::metadata(dir.join("build.sh")).unwrap().permissions().mode() & 0o111, 0o111);
}

#[test]
fn new_refuses_bad_ids_and_non_empty_folders() {
    let home = home("new-refuse");
    std::fs::create_dir_all(&home).unwrap();
    let dir = home.join("p");
    let dir_arg = dir.to_str().unwrap();
    for args in [
        vec!["plugin", "new", "p", "--dir", dir_arg, "--id", "Dev.Haunt"],
        vec!["plugin", "new", "p", "--dir", dir_arg, "--id", "single"],
        vec!["plugin", "new", "p", "--dir", dir_arg, "--id", "../evil"],
        vec!["plugin", "new", "Bad Name", "--dir", dir_arg],
    ] {
        let o = haunt(&home, &args, "");
        assert_eq!(o.status.code(), Some(1), "{args:?}: {}", text(&o));
        assert!(!dir.exists(), "{args:?}");
    }

    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("keep.txt"), "mine").unwrap();
    let o = haunt(&home, &["plugin", "new", "p", "--dir", dir_arg], "");
    assert_eq!(o.status.code(), Some(1));
    assert!(text(&o).contains("is not an empty folder"), "{}", text(&o));
    assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);

    std::fs::remove_file(dir.join("keep.txt")).unwrap();
    assert!(haunt(&home, &["plugin", "new", "p", "--dir", dir_arg], "").status.success());
    assert!(std::fs::read_to_string(dir.join("haunt-plugin.toml")).unwrap().contains("id = \"dev.haunt.p\""));
    std::fs::remove_dir_all(home).unwrap();
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
    let mut set = store.load_all(&host, None).unwrap();
    eprintln!("load_all (cached compile + instantiate + init): {:.2} ms", t.elapsed().as_secs_f64() * 1e3);
    assert!(set.errors().is_empty(), "{:?}", set.errors());
    let items = set.palette_items(None, "");
    assert_eq!(items.len(), 1, "{items:?}");
    assert_eq!((items[0].plugin_id.as_str(), items[0].id.as_str(), items[0].title.as_str()), ("dev.haunt.hello", "say-hello", "Say hello"));
    assert_eq!(items[0].default_key.as_deref(), Some("cmd+shift+h"));
    assert!(set.palette_items(None, "nothing like it").is_empty());

    set.invoke("dev.haunt.hello", "say-hello", true).unwrap();
    assert!(set.take_logs().iter().any(|(id, l)| id == "dev.haunt.hello" && l == "info hello: say-hello"));
    set.set_theme("glass", vec![ThemeToken { name: "color.hairline".into(), value: "#ffffff40".into() }]).unwrap();
    assert!(set.take_logs().iter().any(|(id, l)| id == "dev.haunt.hello" && l == "info theme: glass"));
    assert!(set.set_theme("Glass!", Vec::new()).is_err());

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

    let mut set = Store::open(&home).unwrap().load_all(&PluginHost::new().unwrap(), None).unwrap();
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
    std::fs::copy(src.join(WASM), bad.join("plugin.wasm")).unwrap();
    let manifest = std::fs::read_to_string(src.join("haunt-plugin.toml"))
        .unwrap()
        .replace(WASM, "plugin.wasm")
        .replace("[capabilities]", "[capabilities]\nterminal_read = true");
    std::fs::write(bad.join("haunt-plugin.toml"), manifest).unwrap();

    let o = haunt(&home, &["plugin", "install", bad.to_str().unwrap(), "--yes"], "");
    assert_eq!(o.status.code(), Some(1));
    assert!(text(&o).contains("capability terminal_read is not supported"), "{}", text(&o));
    assert!(!home.join("plugins/dev.haunt.hello").exists());
    std::fs::remove_dir_all(home).unwrap();
}

#[test]
fn same_id_from_another_path_prompts_as_a_replacement() {
    let src = hello();
    let home = home("takeover");
    assert!(haunt(&home, &["plugin", "install", src.to_str().unwrap(), "--yes"], "").status.success());

    let other = home.join("other");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::copy(src.join(WASM), other.join("plugin.wasm")).unwrap();
    let manifest = std::fs::read_to_string(src.join("haunt-plugin.toml"))
        .unwrap()
        .replace(WASM, "plugin.wasm");
    std::fs::write(other.join("haunt-plugin.toml"), manifest).unwrap();

    let o = haunt(&home, &["plugin", "install", other.to_str().unwrap()], "n\n");
    let out = text(&o);
    assert_eq!(o.status.code(), Some(1), "{out}");
    assert!(out.contains(&format!("replaces dev.haunt.hello installed from {}", src.display())), "{out}");
    assert!(out.contains("can see agent events"), "{out}");
    assert!(text(&haunt(&home, &["plugin", "list"], "")).contains(src.to_str().unwrap()));
    std::fs::remove_dir_all(home).unwrap();
}
