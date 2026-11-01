//! Unix-socket intake for hook events: newline-delimited JSON, one v1 body per line plus
//! `surface_id`. Only events whose nonce matches the surface's are `verified`; the rest are
//! status-only and must never feed history, decisions, the allowlist or pty answers.

use std::collections::HashMap;
use std::fs::{self, DirBuilder};
use std::io::{BufRead, BufReader, ErrorKind};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::event::{AgentEvent, parse_body};

pub const SOCKET_NAME: &str = "sock";
// macOS `sun_path` is 104 bytes including the terminator.
const MAX_PATH: usize = 103;

#[derive(Debug, Clone)]
pub struct Limits {
    pub max_line: usize,
    pub per_sec: f64,
    pub burst: f64,
    pub max_conns: usize,
    /// Each line, counted from when the previous one ended, must arrive whole within this.
    pub line_timeout: Duration,
    /// A connection is closed after this, however steadily it trickles bytes.
    pub conn_timeout: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_line: 64 * 1024,
            per_sec: 50.0,
            burst: 200.0,
            max_conns: 32,
            line_timeout: Duration::from_secs(2),
            conn_timeout: Duration::from_secs(10),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Delivery {
    /// Empty when the line had no usable `surface_id`.
    pub surface_id: String,
    pub verified: bool,
    pub bytes: u64,
    pub event: Option<AgentEvent>,
    pub error: Option<String>,
    /// Lines from this surface dropped by the rate limit since its last delivery.
    pub dropped_before: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum IntakeError {
    #[error("socket dir {0} is unsafe: {1}")]
    UnsafeDir(PathBuf, &'static str),
    #[error("{0} exists and is not a socket")]
    NotASocket(PathBuf),
    #[error("{0}: {1}")]
    UnsafeSocket(PathBuf, String),
    #[error("{0} is in use by another haunt")]
    InUse(PathBuf),
    #[error("socket path too long: {0}")]
    PathTooLong(PathBuf),
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

pub type Sink = Arc<dyn Fn(Delivery) + Send + Sync>;

struct Bucket {
    tokens: f64,
    at: Instant,
    dropped: u32,
}

struct Shared {
    nonces: Mutex<HashMap<String, String>>,
    /// Per (surface, verified): a flood of unverified lines can't use up the verified budget.
    buckets: Mutex<HashMap<(String, bool), Bucket>>,
    limits: Limits,
    sink: Sink,
    conns: AtomicUsize,
    stop: AtomicBool,
}

pub struct Intake {
    path: PathBuf,
    shared: Arc<Shared>,
}

impl Intake {
    /// Binds `<dir>/sock` (0600) in a 0700 dir we own, and serves it on a background thread.
    pub fn bind(dir: &Path, limits: Limits, sink: Sink) -> Result<Self, IntakeError> {
        let (listener, path) = bind_private(dir, SOCKET_NAME)?;
        let shared = Arc::new(Shared {
            nonces: Mutex::new(HashMap::new()),
            buckets: Mutex::new(HashMap::new()),
            limits,
            sink,
            conns: AtomicUsize::new(0),
            stop: AtomicBool::new(false),
        });
        let s = shared.clone();
        std::thread::Builder::new().name("haunt-intake".into()).spawn(move || accept_loop(listener, s))?;
        Ok(Self { path, shared })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn register_surface(&self, surface_id: &str, nonce: &str) {
        self.shared.nonces.lock().unwrap().insert(surface_id.to_owned(), nonce.to_owned());
    }

    pub fn unregister_surface(&self, surface_id: &str) {
        self.shared.nonces.lock().unwrap().remove(surface_id);
        self.shared.buckets.lock().unwrap().retain(|(id, _), _| id != surface_id);
    }
}

impl Drop for Intake {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::SeqCst);
        // Wake the accept loop so it sees `stop`.
        let _ = UnixStream::connect(&self.path);
        let _ = fs::remove_file(&self.path);
    }
}

/// Binds `<dir>/<name>` (0600) in a 0700 dir we own, replacing only a stale socket of ours.
pub(crate) fn bind_private(dir: &Path, name: &str) -> Result<(UnixListener, PathBuf), IntakeError> {
    let me = uid();
    secure_dir(dir, me)?;
    let path = dir.join(name);
    if path.as_os_str().len() > MAX_PATH {
        return Err(IntakeError::PathTooLong(path));
    }
    remove_stale(&path, me)?;
    let listener = UnixListener::bind(&path)?;
    // The 0700 dir already keeps others out; 0600 is the second wall.
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    check_socket(&path, me)?;
    Ok((listener, path))
}

pub fn uid() -> u32 {
    // SAFETY: getuid has no preconditions and cannot fail.
    unsafe { libc::getuid() }
}

/// Removes a leftover socket of ours; refuses anything else, and a socket that still answers.
fn remove_stale(path: &Path, me: u32) -> Result<(), IntakeError> {
    match fs::symlink_metadata(path) {
        Ok(m) if !m.file_type().is_socket() => Err(IntakeError::NotASocket(path.to_owned())),
        Ok(m) if m.uid() != me => Err(IntakeError::UnsafeSocket(path.to_owned(), format!("owned by uid {}", m.uid()))),
        Ok(_) if UnixStream::connect(path).is_ok() => Err(IntakeError::InUse(path.to_owned())),
        Ok(_) => Ok(fs::remove_file(path)?),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

fn check_socket(path: &Path, me: u32) -> Result<(), IntakeError> {
    let m = fs::symlink_metadata(path)?;
    let bad = |why: String| Err(IntakeError::UnsafeSocket(path.to_owned(), why));
    if m.uid() != me {
        return bad(format!("owned by uid {}", m.uid()));
    }
    if m.mode() & 0o777 != 0o600 {
        return bad(format!("mode {:o}", m.mode() & 0o777));
    }
    Ok(())
}

fn secure_dir(dir: &Path, me: u32) -> Result<(), IntakeError> {
    let unsafe_dir = |why| IntakeError::UnsafeDir(dir.to_owned(), why);
    DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let meta = fs::symlink_metadata(dir)?;
    if !meta.is_dir() {
        return Err(unsafe_dir("not a directory"));
    }
    if meta.uid() != me {
        return Err(unsafe_dir("not owned by the current user"));
    }
    if meta.mode() & 0o077 != 0 {
        // Ours, so tightening is safe; an older haunt build created it 0755.
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

pub(crate) fn peer_allowed(stream: &UnixStream, me: u32) -> bool {
    peer_uid(stream) == Some(me)
}

fn peer_uid(stream: &UnixStream) -> Option<u32> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: the fd is a live socket owned by `stream`; uid and gid are valid out-pointers.
    let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    (rc == 0).then_some(uid)
}

fn accept_loop(listener: UnixListener, s: Arc<Shared>) {
    let me = uid();
    for stream in listener.incoming() {
        if s.stop.load(Ordering::SeqCst) {
            return;
        }
        let Ok(stream) = stream else { continue };
        if !peer_allowed(&stream, me) {
            continue;
        }
        if s.conns.fetch_add(1, Ordering::SeqCst) >= s.limits.max_conns {
            s.conns.fetch_sub(1, Ordering::SeqCst);
            continue;
        }
        let s2 = s.clone();
        let spawned = std::thread::Builder::new().name("haunt-intake-conn".into()).spawn(move || {
            serve(stream, &s2);
            s2.conns.fetch_sub(1, Ordering::SeqCst);
        });
        if spawned.is_err() {
            s.conns.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

fn serve(stream: UnixStream, s: &Shared) {
    // Hooks write a few lines and hang up. Deadlines, not idle timeouts, so a peer trickling a byte
    // at a time can't hold one of the `max_conns` slots and starve the hooks.
    let end = Instant::now() + s.limits.conn_timeout;
    let mut r = BufReader::new(stream);
    let mut line = Vec::new();
    loop {
        line.clear();
        let deadline = end.min(Instant::now() + s.limits.line_timeout);
        match read_line(&mut r, s.limits.max_line, deadline, &mut line) {
            Line::End => return,
            Line::TooLong(n) => (s.sink)(reject(String::new(), n, format!("line over {} bytes", s.limits.max_line))),
            Line::Done => {
                while matches!(line.last(), Some(b'\n' | b'\r')) {
                    line.pop();
                }
                if !line.is_empty() {
                    handle_line(&line, s);
                }
            }
        }
    }
}

enum Line {
    Done,
    /// Over `max` bytes; it was read to its newline and dropped.
    TooLong(usize),
    /// EOF, an error or the deadline: stop serving.
    End,
}

/// Reads one line into `out`; all of it must arrive before `deadline`. A last line without a
/// newline counts at EOF.
fn read_line(r: &mut BufReader<UnixStream>, max: usize, deadline: Instant, out: &mut Vec<u8>) -> Line {
    let mut seen = 0;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Line::End;
        }
        // macOS refuses (EINVAL) once the peer has hung up, and then reads never block anyway.
        let _ = r.get_ref().set_read_timeout(Some(left));
        let buf = match r.fill_buf() {
            Ok([]) if seen > 0 && seen <= max => return Line::Done,
            Ok([]) | Err(_) => return Line::End,
            Ok(b) => b,
        };
        let newline = buf.iter().position(|&b| b == b'\n');
        let take = newline.map_or(buf.len(), |i| i + 1);
        if seen + take <= max + 1 {
            out.extend_from_slice(&buf[..take]);
        }
        seen += take;
        r.consume(take);
        if newline.is_some() {
            return if seen > max + 1 { Line::TooLong(seen) } else { Line::Done };
        }
    }
}

fn reject(surface_id: String, bytes: usize, error: String) -> Delivery {
    Delivery { surface_id, verified: false, bytes: bytes as u64, event: None, error: Some(error), dropped_before: 0 }
}

fn handle_line(line: &[u8], s: &Shared) {
    let Ok(text) = std::str::from_utf8(line) else {
        return (s.sink)(reject(String::new(), line.len(), "not utf-8".into()));
    };
    let surface_id = surface_of(text);
    // Unknown ids get no bucket, so random ids cannot grow the map.
    if !s.nonces.lock().unwrap().contains_key(&surface_id) {
        return;
    }
    let mut d = decode(text, &s.nonces.lock().unwrap());
    let Some(dropped_before) = take_token(s, &surface_id, d.verified) else { return };
    d.dropped_before = dropped_before;
    (s.sink)(d);
}

fn surface_of(text: &str) -> String {
    serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|v| v.get("surface_id").and_then(|x| x.as_str()).map(str::to_owned))
        .filter(|id| !id.is_empty() && id.len() <= 64)
        .unwrap_or_default()
}

/// Parses one line and checks its nonce against `nonces` (surface id to nonce).
pub(crate) fn decode(text: &str, nonces: &HashMap<String, String>) -> Delivery {
    let surface_id = surface_of(text);
    match parse_body(text) {
        Ok(event) => {
            let verified = match (&event.nonce, nonces.get(&surface_id)) {
                (Some(got), Some(want)) => !surface_id.is_empty() && ct_eq(got.as_bytes(), want.as_bytes()),
                _ => false,
            };
            Delivery { surface_id, verified, bytes: text.len() as u64, event: Some(event), error: None, dropped_before: 0 }
        }
        Err(e) => reject(surface_id, text.len(), e.to_string()),
    }
}

/// Token bucket per surface and verified-ness; None means drop. Returns the drop count to report on success.
fn take_token(s: &Shared, surface_id: &str, verified: bool) -> Option<u32> {
    let now = Instant::now();
    let mut buckets = s.buckets.lock().unwrap();
    let b = buckets
        .entry((surface_id.to_owned(), verified))
        .or_insert(Bucket { tokens: s.limits.burst, at: now, dropped: 0 });
    b.tokens = (b.tokens + now.duration_since(b.at).as_secs_f64() * s.limits.per_sec).min(s.limits.burst);
    b.at = now;
    if b.tokens < 1.0 {
        b.dropped = b.dropped.saturating_add(1);
        return None;
    }
    b.tokens -= 1.0;
    Some(std::mem::take(&mut b.dropped))
}

fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::mpsc;

    fn dir(tag: &str) -> PathBuf {
        // Short path: sun_path is limited to 104 bytes on macOS.
        PathBuf::from(format!("/tmp/hi-{tag}-{}", std::process::id()))
    }

    fn start(tag: &str, limits: Limits) -> (Intake, mpsc::Receiver<Delivery>, PathBuf) {
        let d = dir(tag);
        let _ = fs::remove_dir_all(&d);
        let (tx, rx) = mpsc::channel();
        let tx = Mutex::new(tx);
        let intake = Intake::bind(&d, limits, Arc::new(move |x| tx.lock().unwrap().send(x).unwrap())).unwrap();
        (intake, rx, d)
    }

    fn send(path: &Path, data: &[u8]) {
        let mut s = UnixStream::connect(path).unwrap();
        s.write_all(data).unwrap();
    }

    fn recv(rx: &mpsc::Receiver<Delivery>) -> Delivery {
        rx.recv_timeout(Duration::from_secs(5)).expect("delivery")
    }

    const EV: &str = r#""v":1,"agent":"claude","event":"task_created","task_id":"1","task_subject":"x""#;

    #[test]
    fn verifies_nonce_per_surface() {
        let (intake, rx, d) = start("nonce", Limits::default());
        intake.register_surface("s1", "n1");
        intake.register_surface("other", "n2");
        send(intake.path(), format!("{{{EV},\"surface_id\":\"s1\",\"nonce\":\"n1\"}}\n").as_bytes());
        let ok = recv(&rx);
        assert!(ok.verified && ok.event.is_some(), "{ok:?}");
        send(intake.path(), format!("{{{EV},\"surface_id\":\"s1\",\"nonce\":\"bad\"}}\n").as_bytes());
        assert!(!recv(&rx).verified);
        send(intake.path(), format!("{{{EV},\"surface_id\":\"s1\"}}\n").as_bytes());
        assert!(!recv(&rx).verified);
        send(intake.path(), format!("{{{EV},\"surface_id\":\"other\",\"nonce\":\"n1\"}}\n").as_bytes());
        assert!(!recv(&rx).verified, "a nonce is only good for its own surface");
        drop(intake);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn unknown_surfaces_are_dropped() {
        let (intake, rx, d) = start("ghost", Limits::default());
        intake.register_surface("s1", "n1");
        send(intake.path(), format!("{{{EV},\"surface_id\":\"ghost\",\"nonce\":\"n1\"}}\n{{{EV},\"surface_id\":\"s1\"}}\n").as_bytes());
        assert_eq!(recv(&rx).surface_id, "s1");
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
        drop(intake);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn socket_and_dir_are_private() {
        let d = dir("perm");
        let _ = fs::remove_dir_all(&d);
        fs::create_dir(&d).unwrap();
        fs::set_permissions(&d, fs::Permissions::from_mode(0o755)).unwrap();
        let intake = Intake::bind(&d, Limits::default(), Arc::new(|_| {})).unwrap();
        assert_eq!(fs::metadata(&d).unwrap().mode() & 0o777, 0o700);
        assert_eq!(fs::symlink_metadata(intake.path()).unwrap().mode() & 0o777, 0o600);
        drop(intake);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn oversize_line_is_rejected_and_stream_continues() {
        let limits = Limits { max_line: 1024, ..Limits::default() };
        let (intake, rx, d) = start("big", limits);
        intake.register_surface("s1", "n1");
        let big = format!("{{{EV},\"pad\":\"{}\"}}\n", "x".repeat(4000));
        let small = format!("{{{EV},\"surface_id\":\"s1\"}}\n");
        send(intake.path(), format!("{big}{small}").as_bytes());
        assert!(recv(&rx).error.unwrap().contains("over 1024"));
        assert!(recv(&rx).event.is_some());
        drop(intake);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn floods_are_rate_limited_per_surface() {
        let limits = Limits { per_sec: 0.001, burst: 5.0, ..Limits::default() };
        let (intake, rx, d) = start("rate", limits);
        intake.register_surface("s1", "n1");
        intake.register_surface("s2", "n2");
        let line = format!("{{{EV},\"surface_id\":\"s1\"}}\n");
        send(intake.path(), line.repeat(20).as_bytes());
        send(intake.path(), format!("{{{EV},\"surface_id\":\"s2\"}}\n").as_bytes());
        let got: Vec<_> = (0..6).map(|_| recv(&rx)).collect();
        assert_eq!(got.iter().filter(|x| x.surface_id == "s1").count(), 5);
        assert_eq!(got.iter().filter(|x| x.surface_id == "s2").count(), 1, "other surfaces unaffected");
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
        drop(intake);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn an_unverified_flood_does_not_starve_verified_events() {
        let limits = Limits { per_sec: 0.001, burst: 5.0, ..Limits::default() };
        let (intake, rx, d) = start("starve", limits);
        intake.register_surface("s1", "n1");
        let forged = format!("{{{EV},\"surface_id\":\"s1\",\"nonce\":\"guess\"}}\n");
        send(intake.path(), forged.repeat(50).as_bytes());
        send(intake.path(), format!("{{{EV},\"surface_id\":\"s1\",\"nonce\":\"n1\"}}\n").as_bytes());
        let got: Vec<_> = (0..6).map(|_| recv(&rx)).collect();
        assert_eq!(got.iter().filter(|x| !x.verified).count(), 5);
        assert_eq!(got.iter().filter(|x| x.verified).count(), 1, "the real event still arrives");
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
        drop(intake);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn slow_connections_are_cut_off_and_cannot_hold_every_slot() {
        let limits = Limits { max_conns: 2, line_timeout: Duration::from_millis(300), conn_timeout: Duration::from_millis(800), ..Limits::default() };
        let (intake, rx, d) = start("loris", limits);
        intake.register_surface("s1", "n1");
        let line = format!("{{{EV},\"surface_id\":\"s1\"}}\n");
        // One trickles a byte per 100 ms (inside the line timeout, never finishing a line); one
        // sends whole lines slowly (inside the line timeout, but past the connection deadline).
        let trickle = UnixStream::connect(intake.path()).unwrap();
        let steady = UnixStream::connect(intake.path()).unwrap();
        let t = Instant::now();
        let (a, b, l) = (trickle.try_clone().unwrap(), steady.try_clone().unwrap(), line.clone());
        let th = std::thread::spawn(move || {
            let (mut a, mut b) = (a, b);
            for i in 0..30 {
                if a.write_all(b"x").is_err() && b.write_all(l.as_bytes()).is_err() {
                    break;
                }
                if i % 2 == 0 {
                    let _ = b.write_all(l.as_bytes());
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        });
        let mut steady_lines = 0;
        while rx.recv_timeout(Duration::from_millis(1500)).is_ok() {
            steady_lines += 1;
        }
        assert!(steady_lines >= 2, "the steady peer was served at first");
        assert!(t.elapsed() < Duration::from_secs(3), "both cut off by their deadlines: {:?}", t.elapsed());
        send(intake.path(), line.as_bytes());
        assert!(recv(&rx).event.is_some(), "a real hook gets a slot again");
        drop((trickle, steady));
        th.join().unwrap();
        drop(intake);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn refuses_non_socket_in_the_way() {
        let d = dir("block");
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        fs::write(d.join(SOCKET_NAME), b"").unwrap();
        assert!(matches!(Intake::bind(&d, Limits::default(), Arc::new(|_| {})), Err(IntakeError::NotASocket(_))));
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn refuses_dir_or_socket_of_another_uid() {
        let d = dir("uid");
        let _ = fs::remove_dir_all(&d);
        assert!(matches!(secure_dir(&d, uid() + 1), Err(IntakeError::UnsafeDir(..))));
        let intake = Intake::bind(&d, Limits::default(), Arc::new(|_| {})).unwrap();
        assert!(matches!(check_socket(intake.path(), uid() + 1), Err(IntakeError::UnsafeSocket(..))));
        assert!(matches!(remove_stale(intake.path(), uid() + 1), Err(IntakeError::UnsafeSocket(..))));
        drop(intake);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn refuses_symlinked_dir() {
        let real = dir("real");
        let link = dir("link");
        let _ = fs::remove_dir_all(&real);
        let _ = fs::remove_file(&link);
        fs::create_dir(&real).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(matches!(Intake::bind(&link, Limits::default(), Arc::new(|_| {})), Err(IntakeError::UnsafeDir(..))));
        fs::remove_file(&link).unwrap();
        fs::remove_dir_all(real).unwrap();
    }

    #[test]
    fn peer_of_another_uid_is_refused() {
        let (a, _b) = UnixStream::pair().unwrap();
        assert!(peer_allowed(&a, uid()));
        assert!(!peer_allowed(&a, uid() + 1));
    }

    #[test]
    fn replaces_a_stale_socket_but_not_a_live_one() {
        let d = dir("stale");
        let _ = fs::remove_dir_all(&d);
        secure_dir(&d, uid()).unwrap();
        drop(UnixListener::bind(d.join(SOCKET_NAME)).unwrap());
        let intake = Intake::bind(&d, Limits::default(), Arc::new(|_| {})).expect("stale socket replaced");
        assert!(matches!(Intake::bind(&d, Limits::default(), Arc::new(|_| {})), Err(IntakeError::InUse(_))));
        drop(intake);
        fs::remove_dir_all(d).unwrap();
    }
}
