//! `~/.haunt/sock`: the hook intake. Newline-delimited JSON from processes of the same user only.

use std::fs;
use std::io::{self, BufRead, BufReader, ErrorKind, Read};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

use crate::CoreError;

pub const SOCKET_NAME: &str = "sock";
pub const MAX_MESSAGE: usize = 64 * 1024;
const MAX_CONNECTIONS: usize = 32;
const READ_TIMEOUT: Duration = Duration::from_secs(2);
// macOS `sun_path` is 104 bytes including the terminator.
const MAX_PATH: usize = 103;

pub type LineHandler = Arc<dyn Fn(&str) + Send + Sync>;

pub fn uid() -> u32 {
    // SAFETY: getuid has no preconditions and cannot fail.
    unsafe { libc::getuid() }
}

fn insecure(reason: String) -> CoreError {
    CoreError::Insecure { reason }
}

fn io_err(what: &str, path: &Path, e: io::Error) -> CoreError {
    CoreError::Io { reason: format!("{what} {}: {e}", path.display()) }
}

/// Creates `dir` 0700 if missing; refuses a symlink, another owner, or any group/other access.
pub fn check_dir(dir: &Path, owner: u32) -> Result<(), CoreError> {
    if let Err(e) = fs::DirBuilder::new().mode(0o700).create(dir)
        && e.kind() != ErrorKind::AlreadyExists
    {
        return Err(io_err("create", dir, e));
    }
    let m = fs::symlink_metadata(dir).map_err(|e| io_err("stat", dir, e))?;
    if !m.is_dir() {
        return Err(insecure(format!("{} is not a directory", dir.display())));
    }
    check_owner_mode(dir, &m, owner, 0o700)
}

fn check_owner_mode(path: &Path, m: &fs::Metadata, owner: u32, want: u32) -> Result<(), CoreError> {
    if m.uid() != owner {
        return Err(insecure(format!("{} is owned by uid {}, not {owner}", path.display(), m.uid())));
    }
    let mode = m.mode() & 0o777;
    if mode != want {
        return Err(insecure(format!("{} has mode {mode:o}, want {want:o}", path.display())));
    }
    Ok(())
}

pub fn peer_uid(s: &UnixStream) -> io::Result<u32> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: the fd is a live socket owned by `s`; uid and gid are valid out-pointers.
    if unsafe { libc::getpeereid(s.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

pub struct Server {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Server {
    /// Binds `dir/sock` after checking `dir`, and serves each line to `handler` on a worker thread.
    pub fn bind(dir: &Path, owner: u32, handler: LineHandler) -> Result<Self, CoreError> {
        check_dir(dir, owner)?;
        let path = dir.join(SOCKET_NAME);
        if path.as_os_str().len() > MAX_PATH {
            return Err(CoreError::Io { reason: format!("socket path too long: {}", path.display()) });
        }
        remove_stale(&path, owner)?;
        let listener = UnixListener::bind(&path).map_err(|e| io_err("bind", &path, e))?;
        // The 0700 directory already keeps others out between bind and chmod.
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|e| io_err("chmod", &path, e))?;
        let m = fs::symlink_metadata(&path).map_err(|e| io_err("stat", &path, e))?;
        check_owner_mode(&path, &m, owner, 0o600)?;

        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let thread = std::thread::Builder::new()
            .name("haunt-sock".into())
            .spawn(move || accept_loop(listener, owner, handler, flag))
            .map_err(|e| io_err("spawn for", &path, e))?;
        Ok(Self { path, stop, thread: Some(thread) })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Wakes the blocking accept.
        let _ = UnixStream::connect(&self.path);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        let _ = fs::remove_file(&self.path);
    }
}

/// Removes a leftover socket of ours; refuses anything else, and a socket that still answers.
fn remove_stale(path: &Path, owner: u32) -> Result<(), CoreError> {
    let m = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(io_err("stat", path, e)),
    };
    if !m.file_type().is_socket() || m.uid() != owner {
        return Err(insecure(format!("{} exists and is not our socket", path.display())));
    }
    if UnixStream::connect(path).is_ok() {
        return Err(CoreError::Io { reason: format!("{} is in use by another haunt", path.display()) });
    }
    fs::remove_file(path).map_err(|e| io_err("remove", path, e))
}

fn accept_loop(listener: UnixListener, owner: u32, handler: LineHandler, stop: Arc<AtomicBool>) {
    let active = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        let Ok(stream) = stream else { continue };
        if !peer_allowed(&stream, owner) {
            continue;
        }
        if active.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            active.fetch_sub(1, Ordering::SeqCst);
            continue;
        }
        let (handler, live) = (handler.clone(), active.clone());
        let spawned = std::thread::Builder::new().name("haunt-sock-conn".into()).spawn(move || {
            let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
            read_lines(stream, &*handler);
            live.fetch_sub(1, Ordering::SeqCst);
        });
        if spawned.is_err() {
            active.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

pub fn peer_allowed(s: &UnixStream, owner: u32) -> bool {
    peer_uid(s).is_ok_and(|u| u == owner)
}

/// Hands each line to `handler`; a line over `MAX_MESSAGE` drops the connection.
pub fn read_lines(stream: impl Read, handler: &dyn Fn(&str)) {
    let mut r = BufReader::new(stream);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let limit = (MAX_MESSAGE + 1) as u64;
        match r.by_ref().take(limit).read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let complete = buf.last() == Some(&b'\n');
        if !complete && buf.len() > MAX_MESSAGE {
            return;
        }
        let line = buf.strip_suffix(b"\n").unwrap_or(&buf);
        if line.len() > MAX_MESSAGE {
            return;
        }
        if let Ok(text) = std::str::from_utf8(line) {
            let text = text.trim();
            if !text.is_empty() {
                handler(text);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::Mutex;
    use std::sync::mpsc;

    fn tmp(name: &str) -> PathBuf {
        let d = PathBuf::from(format!("/tmp/haunt-test-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    fn collect() -> (LineHandler, mpsc::Receiver<String>) {
        let (tx, rx) = mpsc::channel();
        let tx = Mutex::new(tx);
        (Arc::new(move |l: &str| tx.lock().unwrap().send(l.to_owned()).unwrap()), rx)
    }

    fn send(path: &Path, bytes: &[u8]) {
        let mut s = UnixStream::connect(path).unwrap();
        let _ = s.write_all(bytes);
    }

    #[test]
    fn binds_0600_in_a_new_0700_dir_and_delivers_lines() {
        let dir = tmp("bind");
        let (h, rx) = collect();
        let server = Server::bind(&dir, uid(), h).unwrap();
        assert_eq!(fs::metadata(&dir).unwrap().mode() & 0o777, 0o700);
        assert_eq!(fs::symlink_metadata(server.path()).unwrap().mode() & 0o777, 0o600);
        send(server.path(), b"{\"a\":1}\n\n{\"b\":2}");
        let got: Vec<_> = (0..2).map(|_| rx.recv_timeout(Duration::from_secs(2)).unwrap()).collect();
        assert_eq!(got, ["{\"a\":1}", "{\"b\":2}"]);
        let path = server.path().to_owned();
        drop(server);
        assert!(!path.exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn refuses_group_or_world_accessible_dir() {
        for mode in [0o750, 0o705, 0o777] {
            let dir = tmp(&format!("mode{mode:o}"));
            fs::create_dir(&dir).unwrap();
            fs::set_permissions(&dir, fs::Permissions::from_mode(mode)).unwrap();
            let (h, _rx) = collect();
            assert!(matches!(Server::bind(&dir, uid(), h), Err(CoreError::Insecure { .. })), "{mode:o}");
            let _ = fs::remove_dir_all(&dir);
        }
    }

    #[test]
    fn refuses_dir_of_another_owner() {
        let dir = tmp("owner");
        let (h, _rx) = collect();
        assert!(matches!(Server::bind(&dir, uid() + 1, h), Err(CoreError::Insecure { .. })));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn refuses_symlinked_dir() {
        let real = tmp("real");
        let link = tmp("link");
        fs::create_dir(&real).unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o700)).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(matches!(check_dir(&link, uid()), Err(CoreError::Insecure { .. })));
        let _ = fs::remove_file(&link);
        let _ = fs::remove_dir_all(&real);
    }

    #[test]
    fn refuses_a_non_socket_in_the_way_but_replaces_a_stale_socket() {
        let dir = tmp("stale");
        check_dir(&dir, uid()).unwrap();
        let path = dir.join(SOCKET_NAME);
        fs::write(&path, "x").unwrap();
        let (h, _rx) = collect();
        assert!(matches!(Server::bind(&dir, uid(), h.clone()), Err(CoreError::Insecure { .. })));
        fs::remove_file(&path).unwrap();
        drop(UnixListener::bind(&path).unwrap());
        let server = Server::bind(&dir, uid(), h.clone()).expect("stale socket replaced");
        assert!(matches!(Server::bind(&dir, uid(), h), Err(CoreError::Io { .. })), "a live socket is not stolen");
        drop(server);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn peer_of_another_uid_is_refused() {
        let (a, _b) = UnixStream::pair().unwrap();
        assert!(peer_allowed(&a, uid()));
        assert!(!peer_allowed(&a, uid() + 1));
    }

    #[test]
    fn oversize_message_is_dropped_with_its_connection() {
        let dir = tmp("big");
        let (h, rx) = collect();
        let server = Server::bind(&dir, uid(), h).unwrap();
        let mut big = vec![b'x'; MAX_MESSAGE + 1];
        big.extend_from_slice(b"\n{\"after\":1}\n");
        send(server.path(), &big);
        let mut exact = vec![b'y'; MAX_MESSAGE];
        exact.push(b'\n');
        send(server.path(), &exact);
        let got = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(got.len(), MAX_MESSAGE, "the 64 KB line arrives; nothing after the oversize one does");
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
        drop(server);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_lines_skips_invalid_utf8() {
        let got = std::cell::RefCell::new(vec![]);
        read_lines(&b"\xff\xfe\nok\n"[..], &|l: &str| got.borrow_mut().push(l.to_owned()));
        assert_eq!(got.into_inner(), ["ok"]);
    }
}
