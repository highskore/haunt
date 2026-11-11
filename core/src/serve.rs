//! One poll(2) thread per private socket. It accepts same-uid peers and reads newline-delimited
//! lines under per-connection deadlines, so no peer gets a thread of its own.

use std::fs;
use std::io::{self, ErrorKind, Read};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::intake::{peer_allowed, uid};

/// Replies one read may queue: one chunk of short lines could otherwise ask for many large replies.
const MAX_OUT: usize = 1 << 20;
/// Out of fds, a pending connection keeps the listener readable, so accepting pauses this long.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Copy)]
pub(crate) struct Limits {
    pub max_line: usize,
    pub max_conns: usize,
    /// Each line, counted from when the previous one ended, must arrive whole within this.
    pub line_timeout: Duration,
    /// A connection is closed after this, however steadily it trickles bytes.
    pub conn_timeout: Duration,
}

pub(crate) enum Input<'a> {
    /// One line without its line ending; never empty.
    Line(&'a [u8]),
    /// A line of this many bytes, over `max_line`; it was read to its newline and dropped.
    TooLong(usize),
}

/// Handles one input and appends any reply to the buffer; false closes the connection once the
/// reply is sent.
pub(crate) type Handler = Box<dyn FnMut(Input<'_>, &mut Vec<u8>) -> bool + Send>;

/// The serving thread; dropping it stops the thread and removes the socket file.
pub(crate) struct Server {
    path: PathBuf,
    stop: Arc<AtomicBool>,
}

impl Server {
    pub(crate) fn spawn(name: &str, listener: UnixListener, path: PathBuf, limits: Limits, handler: Handler) -> io::Result<Self> {
        listener.set_nonblocking(true)?;
        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        std::thread::Builder::new().name(name.into()).spawn(move || run(listener, &s, limits, handler))?;
        Ok(Self { path, stop })
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Wake the poll so it sees `stop`.
        let _ = UnixStream::connect(&self.path);
        let _ = fs::remove_file(&self.path);
    }
}

struct Conn {
    stream: UnixStream,
    /// The line so far, up to `max_line + 1` bytes.
    line: Vec<u8>,
    /// Bytes of the line so far, counting any dropped past the limit.
    seen: usize,
    out: Vec<u8>,
    line_due: Instant,
    end: Instant,
    /// Reading is over: send what is left in `out`, then close.
    closing: bool,
    dead: bool,
}

impl Conn {
    fn due(&self) -> Instant {
        self.line_due.min(self.end)
    }

    fn finished(&self, now: Instant) -> bool {
        self.dead || now >= self.due() || (self.closing && self.out.is_empty())
    }

    fn read(&mut self, chunk: &mut [u8], limits: &Limits, handler: &mut Handler) {
        let n = match self.stream.read(chunk) {
            Ok(n) => n,
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) => return,
            Err(_) => return self.dead = true,
        };
        if n == 0 {
            // A last line without a newline still counts.
            if self.seen > 0 && self.seen <= limits.max_line {
                self.end_line(None, limits, handler);
            }
            self.closing = true;
            return;
        }
        let mut rest = &chunk[..n];
        while !rest.is_empty() && !self.closing {
            let newline = rest.iter().position(|&b| b == b'\n');
            let take = newline.map_or(rest.len(), |i| i + 1);
            if self.seen + take <= limits.max_line + 1 {
                self.line.extend_from_slice(&rest[..take]);
            }
            self.seen += take;
            rest = &rest[take..];
            if newline.is_some() {
                let over = (self.seen > limits.max_line + 1).then_some(self.seen);
                self.end_line(over, limits, handler);
            }
        }
    }

    fn end_line(&mut self, over: Option<usize>, limits: &Limits, handler: &mut Handler) {
        let mut line = &self.line[..];
        while let [rest @ .., b'\n' | b'\r'] = line {
            line = rest;
        }
        let keep = match over {
            Some(n) => handler(Input::TooLong(n), &mut self.out),
            None if line.is_empty() => true,
            None => handler(Input::Line(line), &mut self.out),
        };
        self.closing |= !keep || self.out.len() > MAX_OUT;
        self.line.clear();
        self.seen = 0;
        self.line_due = Instant::now() + limits.line_timeout;
    }

    fn flush(&mut self) {
        while !self.out.is_empty() {
            // SAFETY: the fd is the live socket `stream` owns; the pointer and length are `out`'s.
            let n = unsafe { libc::send(self.stream.as_raw_fd(), self.out.as_ptr().cast(), self.out.len(), SEND_FLAGS) };
            if n < 0 {
                let e = io::Error::last_os_error().kind();
                self.dead = !matches!(e, ErrorKind::WouldBlock | ErrorKind::Interrupted);
                return;
            }
            self.out.drain(..n as usize);
        }
    }
}

// A peer that hangs up before reading its reply must not raise SIGPIPE in the host app.
#[cfg(target_vendor = "apple")]
const SEND_FLAGS: libc::c_int = 0;
#[cfg(not(target_vendor = "apple"))]
const SEND_FLAGS: libc::c_int = libc::MSG_NOSIGNAL;

#[cfg(target_vendor = "apple")]
fn no_sigpipe(s: &UnixStream) {
    let on: libc::c_int = 1;
    // SAFETY: a live socket fd, and a valid int option value of the size given.
    unsafe {
        libc::setsockopt(s.as_raw_fd(), libc::SOL_SOCKET, libc::SO_NOSIGPIPE, (&raw const on).cast(), size_of_val(&on) as libc::socklen_t);
    }
}

#[cfg(not(target_vendor = "apple"))]
fn no_sigpipe(_: &UnixStream) {}

fn pollfd(fd: i32, events: libc::c_short) -> libc::pollfd {
    libc::pollfd { fd, events, revents: 0 }
}

fn run(listener: UnixListener, stop: &AtomicBool, limits: Limits, mut handler: Handler) {
    let me = uid();
    let mut conns: Vec<Conn> = Vec::new();
    let mut fds: Vec<libc::pollfd> = Vec::new();
    let mut chunk = vec![0u8; 16 * 1024];
    let mut paused = None;
    loop {
        let now = Instant::now();
        conns.retain(|c| !c.finished(now));
        paused = paused.filter(|&t| now < t);
        fds.clear();
        fds.push(pollfd(listener.as_raw_fd(), if paused.is_some() { 0 } else { libc::POLLIN }));
        // A peer with a reply still unsent isn't read from, so it can't pile replies up.
        fds.extend(conns.iter().map(|c| pollfd(c.stream.as_raw_fd(), if c.out.is_empty() { libc::POLLIN } else { libc::POLLOUT })));
        let timeout = conns.iter().map(Conn::due).chain(paused).map(|t| t.saturating_duration_since(now).as_millis().saturating_add(1)).min();
        let timeout = timeout.map_or(-1, |ms| ms.min(i32::MAX as u128) as i32);
        // SAFETY: `fds` is a valid array of `fds.len()` pollfds.
        if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) } < 0 {
            if io::Error::last_os_error().kind() == ErrorKind::Interrupted {
                continue;
            }
            return;
        }
        if stop.load(Ordering::SeqCst) {
            return;
        }
        for (c, p) in conns.iter_mut().zip(&fds[1..]) {
            if p.revents == 0 {
                continue;
            }
            if c.out.is_empty() && !c.closing {
                c.read(&mut chunk, &limits, &mut handler);
            }
            c.flush();
        }
        if fds[0].revents != 0 && paused.is_none() && !accept(&listener, &mut conns, me, &limits) {
            paused = Some(Instant::now() + ACCEPT_BACKOFF);
        }
    }
}

/// Accepts every pending connection; false when out of fds.
fn accept(listener: &UnixListener, conns: &mut Vec<Conn>, me: u32, limits: &Limits) -> bool {
    loop {
        let stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(e) => return !matches!(e.raw_os_error(), Some(libc::EMFILE | libc::ENFILE)),
        };
        if !peer_allowed(&stream, me) || conns.len() >= limits.max_conns || stream.set_nonblocking(true).is_err() {
            continue;
        }
        no_sigpipe(&stream);
        let now = Instant::now();
        // Deadlines, not idle timeouts, so a peer trickling a byte at a time can't hold a slot.
        conns.push(Conn {
            stream,
            line: Vec::new(),
            seen: 0,
            out: Vec::new(),
            line_due: now + limits.line_timeout,
            end: now + limits.conn_timeout,
            closing: false,
            dead: false,
        });
    }
}
