//! The real hook script delivering to the real socket.

use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use haunt_core::Core;

fn hook(kind: &str, input: &str, env: &haunt_core::SurfaceEnv, nonce: &str) -> std::process::Output {
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../hooks/scripts/haunt-hook.sh");
    let mut child = Command::new(script)
        .arg(kind)
        .env("HAUNT", "1")
        .env("HAUNT_SOCK", &env.socket_path)
        .env("HAUNT_SURFACE_ID", &env.surface_id)
        .env("HAUNT_HOOK_NONCE", nonce)
        .env("HAUNT_HOOK_TTY", "/nonexistent/tty")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("run hook");
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn hook_over_socket_drives_a_verified_permission() {
    if Command::new("jq").arg("--version").output().is_err() {
        eprintln!("skipped: jq not installed");
        return;
    }
    let dir = format!("/tmp/haunt-hook-e2e-{}", std::process::id());
    let _ = std::fs::remove_dir_all(&dir);
    let core = Core::new(&dir);
    core.start().unwrap();
    let env = core.register_surface("/w").unwrap();
    let (tx, rx) = mpsc::channel();
    let tx = Mutex::new(tx);
    core.set_listener(Arc::new(move || {
        let _ = tx.lock().unwrap().send(());
    }));
    let wait = || rx.recv_timeout(Duration::from_secs(5)).expect("core changed");

    let perm = r#"{"session_id":"s1","cwd":"/w","tool_name":"Bash","tool_input":{"command":"git push"}}"#;
    let out = hook("permission_request", perm, &env, "wrong");
    assert!(out.stdout.is_empty(), "socket path, not OSC");
    wait();
    let row = core.snapshot().groups[0].rows[0].clone();
    assert!(row.needs_you && row.pending.is_none(), "wrong nonce is status-only");
    assert!((0..8).all(|key| core.answer_permission(&env.surface_id, key, true).is_none()));

    hook("permission_request", perm, &env, &env.nonce);
    wait();
    let row = core.snapshot().groups[0].rows[0].clone();
    assert_eq!(row.meta, "/w · Approve: git push?");
    let key = row.pending.expect("verified request").key;
    assert_eq!(core.answer_permission(&env.surface_id, key, true), Some(b"1".to_vec()));
    assert_eq!(core.decisions("git push", 5)[0].outcome, haunt_core::Outcome::AllowedInHaunt);

    drop(core);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn hook_keeps_a_hidden_newline_visible_and_unanswerable() {
    if Command::new("jq").arg("--version").output().is_err() {
        eprintln!("skipped: jq not installed");
        return;
    }
    let dir = format!("/tmp/haunt-hook-nl-{}", std::process::id());
    let _ = std::fs::remove_dir_all(&dir);
    let core = Core::new(&dir);
    core.start().unwrap();
    let env = core.register_surface("/w").unwrap();
    let (tx, rx) = mpsc::channel();
    let tx = Mutex::new(tx);
    core.set_listener(Arc::new(move || {
        let _ = tx.lock().unwrap().send(());
    }));

    let perm = r#"{"session_id":"s1","cwd":"/w","tool_name":"Bash","tool_input":{"command":"ls #\nrm -rf ~/x"}}"#;
    hook("permission_request", perm, &env, &env.nonce);
    rx.recv_timeout(Duration::from_secs(5)).expect("core changed");
    let row = core.snapshot().groups[0].rows[0].clone();
    let p = row.pending.expect("verified request");
    assert_eq!((p.preview.as_str(), p.suspicious), ("ls #⏎rm -rf ~/x", true));
    assert_eq!(core.answer_permission(&env.surface_id, p.key, true), None);

    drop(core);
    let _ = std::fs::remove_dir_all(&dir);
}
