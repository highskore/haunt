//! The debug/CLI socket `<config_dir>/ctl`: one NDJSON request per line, one response line each.
//! Separate from the hook socket so hook floods and rate limits never touch it.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use crate::intake::{IntakeError, bind_private};
use crate::serve::{self, Input, Server};

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
    server: Server,
}

impl Ctl {
    pub fn bind(dir: &Path, handler: Handler) -> Result<Self, IntakeError> {
        Self::bind_with(dir, handler, Deadlines { line: LINE_TIMEOUT, conn: CONN_TIMEOUT })
    }

    fn bind_with(dir: &Path, handler: Handler, limits: Deadlines) -> Result<Self, IntakeError> {
        let (listener, path) = bind_private(dir, CTL_NAME)?;
        let limits = serve::Limits { max_line: MAX_LINE, max_conns: MAX_CONNS, line_timeout: limits.line, conn_timeout: limits.conn };
        let serve = Box::new(move |input: Input<'_>, out: &mut Vec<u8>| {
            let reply = match input {
                Input::TooLong(_) => error(&format!("line over {MAX_LINE} bytes")),
                Input::Line(line) => match String::from_utf8_lossy(line).trim() {
                    "" => return true,
                    text => handler(text),
                },
            };
            out.extend_from_slice(reply.as_bytes());
            out.push(b'\n');
            matches!(input, Input::Line(_))
        });
        Ok(Self { server: Server::spawn("haunt-ctl", listener, path, limits, serve)? })
    }

    pub fn path(&self) -> &Path {
        self.server.path()
    }
}

pub fn error(reason: &str) -> String {
    serde_json::json!({ "ok": false, "error": reason }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::{Read, Write};
    use std::os::unix::net::UnixStream;
    use std::time::Instant;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    use crate::testdir::TempDir;

    #[test]
    fn answers_line_by_line_on_a_private_socket() {
        let d = TempDir::new("hc");
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
    }

    #[test]
    fn a_peer_that_never_reads_its_replies_does_not_stall_others() {
        let d = TempDir::new("hc-stuck");
        let ctl = Ctl::bind(&d, Arc::new(|l: &str| l.repeat(64 * 1024))).unwrap();
        let mut stuck = UnixStream::connect(ctl.path()).unwrap();
        stuck.write_all(&b"x\n".repeat(1000)).unwrap();
        let mut other = UnixStream::connect(ctl.path()).unwrap();
        other.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        other.write_all(b"y\n").unwrap();
        let mut got = vec![0; 64 * 1024 + 1];
        other.read_exact(&mut got).unwrap();
        assert!(got[..64 * 1024].iter().all(|&b| b == b'y') && got[64 * 1024] == b'\n');
        drop(stuck);
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
        let d = TempDir::new("hc-slow");
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
    }
}
