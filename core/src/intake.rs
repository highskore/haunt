//! Unix-socket intake for hook events: newline-delimited JSON, one v1 body per line plus
//! `surface_id`. Only events whose nonce matches the surface's are `verified`; the rest are
//! status-only and must never feed history, decisions, the allowlist or pty answers.

use std::collections::HashMap;
use std::fs::{self, DirBuilder};
use std::io::ErrorKind;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use crate::event::{AgentEvent, parse_line};
use crate::serve::{self, Input, Server};
use crate::sync::{lock, read};

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
/// Surface id to nonce. The core owns it; the intake reads it to verify lines.
pub type Nonces = Arc<RwLock<HashMap<String, String>>>;

struct Bucket {
    tokens: f64,
    at: Instant,
    dropped: u32,
}

struct Shared {
    nonces: Nonces,
    /// Per (surface, verified): a flood of unverified lines can't use up the verified budget.
    buckets: Mutex<HashMap<String, [Bucket; 2]>>,
    limits: Limits,
    sink: Sink,
}

pub struct Intake {
    server: Server,
    shared: Arc<Shared>,
}

impl Intake {
    /// Binds `<dir>/sock` (0600) in a 0700 dir we own, and serves it on a background thread.
    pub fn bind(dir: &Path, limits: Limits, nonces: Nonces, sink: Sink) -> Result<Self, IntakeError> {
        let (listener, path) = bind_private(dir, SOCKET_NAME)?;
        let serve_limits = serve::Limits {
            max_line: limits.max_line,
            max_conns: limits.max_conns,
            line_timeout: limits.line_timeout,
            conn_timeout: limits.conn_timeout,
        };
        let shared = Arc::new(Shared { nonces, buckets: Mutex::new(HashMap::new()), limits, sink });
        let s = shared.clone();
        let handler = Box::new(move |input: Input<'_>, _: &mut Vec<u8>| {
            match input {
                Input::Line(line) => handle_line(line, &s),
                Input::TooLong(n) => reject_unsorted(&s, n, format!("line over {} bytes", s.limits.max_line)),
            }
            true
        });
        let server = Server::spawn("haunt-intake", listener, path, serve_limits, handler)?;
        Ok(Self { server, shared })
    }

    pub fn path(&self) -> &Path {
        self.server.path()
    }

    /// Drops the surface's rate-limit state; its nonce leaves `Nonces` with it.
    pub fn forget_surface(&self, surface_id: &str) {
        lock(&self.shared.buckets).remove(surface_id);
    }
}

#[cfg(test)]
impl Intake {
    pub(crate) fn register_surface(&self, surface_id: &str, nonce: &str) {
        self.shared.nonces.write().unwrap().insert(surface_id.to_owned(), nonce.to_owned());
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

#[cfg(target_os = "linux")]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: the fd is a live socket owned by `stream`; cred and len are valid out-pointers of that size.
    let rc = unsafe { libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, (&raw mut cred).cast(), &mut len) };
    (rc == 0 && len as usize == size_of::<libc::ucred>()).then_some(cred.uid)
}

#[cfg(not(target_os = "linux"))]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: the fd is a live socket owned by `stream`; uid and gid are valid out-pointers.
    let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    (rc == 0).then_some(uid)
}

fn reject(surface_id: String, bytes: usize, error: String) -> Delivery {
    Delivery { surface_id, verified: false, bytes: bytes as u64, event: None, error: Some(error), dropped_before: 0 }
}

fn handle_line(line: &[u8], s: &Shared) {
    let Ok(text) = std::str::from_utf8(line) else {
        return reject_unsorted(s, line.len(), "not utf-8".into());
    };
    // Unknown ids get no bucket, so random ids cannot grow the map.
    let Some(mut d) = decode(text, &s.nonces) else { return };
    let Some(dropped_before) = take_token(s, &d.surface_id, d.verified) else { return };
    d.dropped_before = dropped_before;
    (s.sink)(d);
}

/// A line no surface can be read from; these share one unverified bucket, under an id no surface has.
fn reject_unsorted(s: &Shared, bytes: usize, reason: String) {
    if take_token(s, "", false).is_some() {
        (s.sink)(reject(String::new(), bytes, reason));
    }
}

/// Parses one line and checks its nonce; None when its surface isn't registered.
pub(crate) fn decode(text: &str, nonces: &Nonces) -> Option<Delivery> {
    let (surface_id, event) = parse_line(text);
    let verified = {
        let nonces = read(nonces);
        let want = nonces.get(&surface_id)?;
        let got = event.as_ref().ok().and_then(|e| e.nonce.as_deref());
        got.is_some_and(|got| ct_eq(got.as_bytes(), want.as_bytes()))
    };
    Some(match event {
        Ok(event) => Delivery { surface_id, verified, bytes: text.len() as u64, event: Some(event), error: None, dropped_before: 0 },
        Err(e) => reject(surface_id, text.len(), e.to_string()),
    })
}

/// Token bucket per surface and verified-ness; None means drop. Returns the drop count to report on success.
fn take_token(s: &Shared, surface_id: &str, verified: bool) -> Option<u32> {
    let now = Instant::now();
    let mut buckets = lock(&s.buckets);
    if !buckets.contains_key(surface_id) {
        let fresh = || Bucket { tokens: s.limits.burst, at: now, dropped: 0 };
        buckets.insert(surface_id.to_owned(), [fresh(), fresh()]);
    }
    let b = &mut buckets.get_mut(surface_id).expect("inserted above")[verified as usize];
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

    use crate::testdir::TempDir;

    fn dir(tag: &str) -> TempDir {
        TempDir::new(tag)
    }

    fn start(tag: &str, limits: Limits) -> (Intake, mpsc::Receiver<Delivery>, TempDir) {
        let d = dir(tag);
        let (tx, rx) = mpsc::channel();
        let tx = Mutex::new(tx);
        let intake = Intake::bind(&d, limits, Nonces::default(), Arc::new(move |x| tx.lock().unwrap().send(x).unwrap())).unwrap();
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
        let (intake, rx, _d) = start("nonce", Limits::default());
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
    }

    #[test]
    fn unknown_surfaces_are_dropped() {
        let (intake, rx, _d) = start("ghost", Limits::default());
        intake.register_surface("s1", "n1");
        send(intake.path(), format!("{{{EV},\"surface_id\":\"ghost\",\"nonce\":\"n1\"}}\n{{{EV},\"surface_id\":\"s1\"}}\n").as_bytes());
        assert_eq!(recv(&rx).surface_id, "s1");
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
        drop(intake);
    }

    #[test]
    fn socket_and_dir_are_private() {
        let d = dir("perm");
        fs::create_dir(&d).unwrap();
        fs::set_permissions(&d, fs::Permissions::from_mode(0o755)).unwrap();
        let intake = Intake::bind(&d, Limits::default(), Nonces::default(), Arc::new(|_| {})).unwrap();
        assert_eq!(fs::metadata(&d).unwrap().mode() & 0o777, 0o700);
        assert_eq!(fs::symlink_metadata(intake.path()).unwrap().mode() & 0o777, 0o600);
        drop(intake);
    }

    #[test]
    fn oversize_line_is_rejected_and_stream_continues() {
        let limits = Limits { max_line: 1024, ..Limits::default() };
        let (intake, rx, _d) = start("big", limits);
        intake.register_surface("s1", "n1");
        let big = format!("{{{EV},\"pad\":\"{}\"}}\n", "x".repeat(4000));
        let small = format!("{{{EV},\"surface_id\":\"s1\"}}\n");
        send(intake.path(), format!("{big}{small}").as_bytes());
        assert!(recv(&rx).error.unwrap().contains("over 1024"));
        assert!(recv(&rx).event.is_some());
        drop(intake);
    }

    #[test]
    fn floods_are_rate_limited_per_surface() {
        let limits = Limits { per_sec: 0.001, burst: 5.0, ..Limits::default() };
        let (intake, rx, _d) = start("rate", limits);
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
    }

    #[test]
    fn unreadable_lines_are_rate_limited_too() {
        let limits = Limits { per_sec: 0.001, burst: 5.0, max_line: 1024, ..Limits::default() };
        let (intake, rx, _d) = start("rate-bad", limits);
        intake.register_surface("s1", "n1");
        let mut flood = format!("{}\n", "x".repeat(2000)).repeat(10).into_bytes();
        flood.extend(b"\xff\xfe\n".repeat(10));
        send(intake.path(), &flood);
        send(intake.path(), format!("{{{EV},\"surface_id\":\"s1\"}}\n").as_bytes());
        let got: Vec<_> = (0..6).map(|_| recv(&rx)).collect();
        assert_eq!(got.iter().filter(|x| x.error.is_some()).count(), 5);
        assert_eq!(got.iter().filter(|x| x.event.is_some()).count(), 1, "a surface's own budget is untouched");
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
        drop(intake);
    }

    #[test]
    fn an_unverified_flood_does_not_starve_verified_events() {
        let limits = Limits { per_sec: 0.001, burst: 5.0, ..Limits::default() };
        let (intake, rx, _d) = start("starve", limits);
        intake.register_surface("s1", "n1");
        let forged = format!("{{{EV},\"surface_id\":\"s1\",\"nonce\":\"guess\"}}\n");
        send(intake.path(), forged.repeat(50).as_bytes());
        send(intake.path(), format!("{{{EV},\"surface_id\":\"s1\",\"nonce\":\"n1\"}}\n").as_bytes());
        let got: Vec<_> = (0..6).map(|_| recv(&rx)).collect();
        assert_eq!(got.iter().filter(|x| !x.verified).count(), 5);
        assert_eq!(got.iter().filter(|x| x.verified).count(), 1, "the real event still arrives");
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
        drop(intake);
    }

    #[test]
    fn slow_connections_are_cut_off_and_cannot_hold_every_slot() {
        let limits = Limits { max_conns: 2, line_timeout: Duration::from_millis(300), conn_timeout: Duration::from_millis(800), ..Limits::default() };
        let (intake, rx, _d) = start("loris", limits);
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
    }

    #[test]
    fn refuses_non_socket_in_the_way() {
        let d = dir("block");
        fs::create_dir_all(&d).unwrap();
        fs::write(d.join(SOCKET_NAME), b"").unwrap();
        assert!(matches!(Intake::bind(&d, Limits::default(), Nonces::default(), Arc::new(|_| {})), Err(IntakeError::NotASocket(_))));
    }

    #[test]
    fn refuses_dir_or_socket_of_another_uid() {
        let d = dir("uid");
        assert!(matches!(secure_dir(&d, uid() + 1), Err(IntakeError::UnsafeDir(..))));
        let intake = Intake::bind(&d, Limits::default(), Nonces::default(), Arc::new(|_| {})).unwrap();
        assert!(matches!(check_socket(intake.path(), uid() + 1), Err(IntakeError::UnsafeSocket(..))));
        assert!(matches!(remove_stale(intake.path(), uid() + 1), Err(IntakeError::UnsafeSocket(..))));
        drop(intake);
    }

    #[test]
    fn refuses_symlinked_dir() {
        let real = dir("real");
        let link = dir("link");
        fs::create_dir(&real).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(matches!(Intake::bind(&link, Limits::default(), Nonces::default(), Arc::new(|_| {})), Err(IntakeError::UnsafeDir(..))));
    }

    #[test]
    fn peer_of_another_uid_is_refused() {
        let (a, _b) = UnixStream::pair().unwrap();
        assert!(peer_allowed(&a, uid()));
        assert!(!peer_allowed(&a, uid() + 1));
    }

    /// A real connection from another uid. Switching uid needs root, so it runs in the Linux container.
    #[test]
    fn a_connection_from_another_uid_is_refused() {
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } != 0 {
            eprintln!("skipped: needs root to connect as another uid");
            return;
        }
        const NOBODY: u32 = 65534;
        let d = TempDir::created("foreign");
        fs::set_permissions(&*d, fs::Permissions::from_mode(0o755)).unwrap();
        let path = d.join("s");
        let listener = UnixListener::bind(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o777)).unwrap();
        // SAFETY: an all-zero sockaddr_un is valid; the path is filled in below, NUL-terminated.
        let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
        addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
        for (dst, b) in addr.sun_path.iter_mut().zip(path.as_os_str().as_encoded_bytes()) {
            *dst = *b as libc::c_char;
        }
        // SAFETY: the child makes only raw syscalls on memory set up before the fork, then exits.
        let pid = unsafe { libc::fork() };
        if pid == 0 {
            unsafe {
                let dropped = libc::setgid(NOBODY) == 0 && libc::setuid(NOBODY) == 0;
                let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
                let len = size_of::<libc::sockaddr_un>() as libc::socklen_t;
                let connected = dropped && libc::connect(fd, (&raw const addr).cast(), len) == 0;
                libc::_exit(if connected { 0 } else { 1 });
            }
        }
        let (stream, _) = listener.accept().unwrap();
        let mut status = 0;
        // SAFETY: pid is our child.
        unsafe { libc::waitpid(pid, &mut status, 0) };
        assert_eq!(status, 0, "the child connected as nobody");
        assert_eq!(peer_uid(&stream), Some(NOBODY));
        assert!(!peer_allowed(&stream, uid()));
    }

    #[test]
    fn replaces_a_stale_socket_but_not_a_live_one() {
        let d = dir("stale");
        secure_dir(&d, uid()).unwrap();
        drop(UnixListener::bind(d.join(SOCKET_NAME)).unwrap());
        let intake = Intake::bind(&d, Limits::default(), Nonces::default(), Arc::new(|_| {})).expect("stale socket replaced");
        assert!(matches!(Intake::bind(&d, Limits::default(), Nonces::default(), Arc::new(|_| {})), Err(IntakeError::InUse(_))));
        drop(intake);
    }
}
