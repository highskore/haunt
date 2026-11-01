use std::process::Command;

fn haunt(ctl: &str, args: &[&str]) -> (bool, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_haunt")).args(args).env("HAUNT_CTL", ctl).output().unwrap();
    (out.status.success(), String::from_utf8(out.stdout).unwrap(), String::from_utf8(out.stderr).unwrap())
}

#[test]
fn dump_and_decisions_over_ctl() {
    let dir = format!("/tmp/haunt-cli-{}", std::process::id());
    let _ = std::fs::remove_dir_all(&dir);
    let core = haunt_core::Core::new(&dir);
    core.start().unwrap();
    let env = core.register_surface("/w").unwrap();
    let ctl = format!("{dir}/ctl");

    let (ok, out, _) = haunt(&ctl, &["dump"]);
    assert!(ok);
    let v: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(v["snapshot"]["groups"][0]["rows"][0]["surface_id"], env.surface_id);
    assert_eq!(v["pending"], serde_json::json!([]));

    let (ok, out, _) = haunt(&ctl, &["decisions", "push"]);
    assert!(ok && out.is_empty());
    let (ok, _, err) = haunt(&ctl, &["frobnicate"]);
    assert!(!ok && err.contains("usage"));

    drop(core);
    let (ok, _, err) = haunt(&ctl, &["dump"]);
    assert!(!ok && err.contains("is haunt running"));
    let _ = std::fs::remove_dir_all(&dir);
}
