//! The debug/CLI socket `<config_dir>/ctl`: one NDJSON request per line, one response line each.
//! Separate from the hook socket so hook floods and rate limits never touch it.

use std::fs;
use std::io::{BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use crate::intake::{IntakeError, Line, bind_private, peer_allowed, read_line, uid};

pub const CTL_NAME: &str = "ctl";
const MAX_LINE: usize = 64 * 1024;
const MAX_CONNS: usize = 8;
const LINE_TIMEOUT: Duration = Duration::from_secs(5);
const CONN_TIMEOUT: Duration = Duration::from_secs(10);

/// Each request line must arrive whole within `line`, and a connection lasts at most `conn`, so a
/// peer trickling bytes can't hold the `MAX_CONNS` slots.
#[derive(Clone, Copy)]
struct Deadlines {
    line: Duration,
    conn: Duration,
}

/// Maps one request line to one response line (without the newline).
pub type Handler = Arc<dyn Fn(&str) -> String + Send + Sync>;

pub struct Ctl {
    path: PathBuf,
    stop: Arc<AtomicBool>,
}

impl Ctl {
    pub fn bind(dir: &Path, handler: Handler) -> Result<Self, IntakeError> {
        Self::bind_with(dir, handler, Deadlines { line: LINE_TIMEOUT, conn: CONN_TIMEOUT })
    }

    fn bind_with(dir: &Path, handler: Handler, limits: Deadlines) -> Result<Self, IntakeError> {
        let (listener, path) = bind_private(dir, CTL_NAME)?;
        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        std::thread::Builder::new().name("haunt-ctl".into()).spawn(move || accept_loop(listener, handler, s, limits))?;
        Ok(Self { path, stop })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for Ctl {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = UnixStream::connect(&self.path);
        let _ = fs::remove_file(&self.path);
    }
}

fn accept_loop(listener: UnixListener, handler: Handler, stop: Arc<AtomicBool>, limits: Deadlines) {
    let me = uid();
    let conns = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        if stop.load(Ordering::SeqCst) {
            return;
        }
        let Ok(stream) = stream else { continue };
        if !peer_allowed(&stream, me) {
            continue;
        }
        if conns.fetch_add(1, Ordering::SeqCst) >= MAX_CONNS {
            conns.fetch_sub(1, Ordering::SeqCst);
            continue;
        }
        let (h, c) = (handler.clone(), conns.clone());
        let spawned = std::thread::Builder::new().name("haunt-ctl-conn".into()).spawn(move || {
            serve(stream, &h, limits);
            c.fetch_sub(1, Ordering::SeqCst);
        });
        if spawned.is_err() {
            conns.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

fn serve(stream: UnixStream, handler: &Handler, limits: Deadlines) {
    let end = Instant::now() + limits.conn;
    let Ok(mut out) = stream.try_clone() else { return };
    let mut r = BufReader::new(stream);
    let mut line = Vec::new();
    loop {
        line.clear();
        match read_line(&mut r, MAX_LINE, end.min(Instant::now() + limits.line), &mut line) {
            Line::End => return,
            Line::TooLong(_) => {
                let _ = writeln!(out, "{}", error(&format!("line over {MAX_LINE} bytes")));
                return;
            }
            Line::Done => {}
        }
        let text = String::from_utf8_lossy(&line);
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        if writeln!(out, "{}", handler(text)).is_err() {
            return;
        }
    }
}

pub fn error(reason: &str) -> String {
    serde_json::json!({ "ok": false, "error": reason }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    #[test]
    fn answers_line_by_line_on_a_private_socket() {
        let d = PathBuf::from(format!("/tmp/hc-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        let ctl = Ctl::bind(&d, Arc::new(|l: &str| format!("got {l}"))).unwrap();
        assert_eq!(fs::symlink_metadata(ctl.path()).unwrap().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(&d).unwrap().permissions().mode() & 0o777, 0o700);
        let mut s = UnixStream::connect(ctl.path()).unwrap();
        s.write_all(b"a\n\nb\n").unwrap();
        s.shutdown(std::net::Shutdown::Write).unwrap();
        let mut got = String::new();
        s.read_to_string(&mut got).unwrap();
        assert_eq!(got, "got a\ngot b\n");
        drop(ctl);
        assert!(!d.join(CTL_NAME).exists());
        fs::remove_dir_all(d).unwrap();
    }

    fn closed_within(s: &mut UnixStream, limit: Duration) -> bool {
        let t = Instant::now();
        s.set_read_timeout(Some(limit * 2)).unwrap();
        let mut buf = Vec::new();
        let _ = s.read_to_end(&mut buf);
        t.elapsed() < limit
    }

    #[test]
    fn slow_peers_are_cut_off_by_line_and_connection_deadlines() {
        let d = PathBuf::from(format!("/tmp/hc-slow-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        let limits = Deadlines { line: Duration::from_millis(300), conn: Duration::from_millis(800) };
        let ctl = Ctl::bind_with(&d, Arc::new(|l: &str| format!("got {l}")), limits).unwrap();

        let mut trickle = UnixStream::connect(ctl.path()).unwrap();
        let mut w = trickle.try_clone().unwrap();
        let th = std::thread::spawn(move || {
            for _ in 0..20 {
                if w.write_all(b"x").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        });
        assert!(closed_within(&mut trickle, Duration::from_millis(1000)), "a line that never ends is cut at its deadline");
        th.join().unwrap();

        let mut steady = UnixStream::connect(ctl.path()).unwrap();
        let mut w = steady.try_clone().unwrap();
        let th = std::thread::spawn(move || {
            for _ in 0..20 {
                if w.write_all(b"a\n").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(200));
            }
        });
        assert!(closed_within(&mut steady, Duration::from_millis(1500)), "whole lines still stop at the connection deadline");
        th.join().unwrap();
        drop(ctl);
        fs::remove_dir_all(d).unwrap();
    }
}
