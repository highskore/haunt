//! `Core`: surfaces, their agent sessions, the socket intake and the sidebar snapshot.

use std::fs::File;
use std::io::Read;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Instant;

use crate::event::{AgentEvent, parse_osc};
use crate::intake::{Delivery, Intake, IntakeError, Limits, SOCKET_NAME};
use crate::layout::{self, SidebarSnapshot, SurfaceView};
use crate::session::Session;

const MAX_SURFACES: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[cfg_attr(feature = "ffi", derive(uniffi::Error))]
pub enum CoreError {
    #[error("insecure: {reason}")]
    Insecure { reason: String },
    #[error("io: {reason}")]
    Io { reason: String },
}

impl From<IntakeError> for CoreError {
    fn from(e: IntakeError) -> Self {
        let reason = e.to_string();
        match e {
            IntakeError::Io(_) | IntakeError::InUse(_) | IntakeError::PathTooLong(_) => Self::Io { reason },
            _ => Self::Insecure { reason },
        }
    }
}

/// What the UI puts in a surface's pty environment.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SurfaceEnv {
    pub surface_id: String,
    pub nonce: String,
    pub socket_path: String,
}

pub type Listener = Arc<dyn Fn() + Send + Sync>;

struct Surface {
    id: String,
    nonce: String,
    cwd: String,
    branch: Option<String>,
    session: Session,
}

#[derive(Default)]
pub(crate) struct State {
    surfaces: Vec<Surface>,
    selected: Option<String>,
    home: Option<String>,
    listener: Option<Listener>,
}

impl State {
    fn surface(&mut self, id: &str) -> Option<&mut Surface> {
        self.surfaces.iter_mut().find(|s| s.id == id)
    }

    /// One intake delivery; the intake already checked the nonce and the rate limit.
    pub(crate) fn deliver(&mut self, d: &Delivery, now: Instant) -> bool {
        let Some(event) = &d.event else { return false };
        self.surface(&d.surface_id).is_some_and(|s| s.session.apply(event, d.verified, now))
    }

    /// A socket line as the intake would deliver it, minus the socket and the rate limit.
    #[cfg(test)]
    pub(crate) fn handle_line(&mut self, line: &str, now: Instant) -> bool {
        let nonces = self.surfaces.iter().map(|s| (s.id.clone(), s.nonce.clone())).collect();
        self.deliver(&crate::intake::decode(line, &nonces), now)
    }

    fn apply_unverified(&mut self, id: &str, event: &AgentEvent, now: Instant) -> bool {
        self.surface(id).is_some_and(|s| s.session.apply(event, false, now))
    }

    pub(crate) fn snapshot(&self, now: Instant) -> SidebarSnapshot {
        let views: Vec<SurfaceView> = self
            .surfaces
            .iter()
            .map(|s| SurfaceView {
                id: &s.id,
                cwd: &s.cwd,
                branch: s.branch.as_deref(),
                session: &s.session,
                selected: self.selected.as_deref() == Some(s.id.as_str()),
            })
            .collect();
        layout::snapshot(&views, self.home.as_deref(), now)
    }
}

fn random_bytes() -> [u8; 16] {
    let mut b = [0; 16];
    // Without a random nonce the hook channel has no authentication at all, so failing here is fatal.
    File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).expect("read /dev/urandom");
    b
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn uuid() -> String {
    let mut b = random_bytes();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex(&b);
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

/// Thread-safe; the listener fires on whichever thread caused the change, never under the lock.
pub struct Core {
    dir: PathBuf,
    state: Arc<Mutex<State>>,
    intake: Mutex<Option<Intake>>,
}

fn lock(m: &Mutex<State>) -> MutexGuard<'_, State> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Core {
    pub fn new(config_dir: impl Into<PathBuf>) -> Self {
        let state = State { home: std::env::var("HOME").ok(), ..State::default() };
        Self { dir: config_dir.into(), state: Arc::new(Mutex::new(state)), intake: Mutex::new(None) }
    }

    pub fn socket_path(&self) -> PathBuf {
        self.dir.join(SOCKET_NAME)
    }

    /// Binds the intake socket and registers every surface's nonce with it; a second call is a no-op.
    pub fn start(&self) -> Result<(), CoreError> {
        let mut intake = self.intake.lock().unwrap_or_else(|e| e.into_inner());
        if intake.is_some() {
            return Ok(());
        }
        let state = self.state.clone();
        let sink = Arc::new(move |d: Delivery| {
            let mut st = lock(&state);
            let changed = st.deliver(&d, Instant::now());
            let listener = st.listener.clone();
            drop(st);
            if changed && let Some(l) = listener {
                l();
            }
        });
        let bound = Intake::bind(&self.dir, Limits::default(), sink).map_err(CoreError::from)?;
        for s in &lock(&self.state).surfaces {
            bound.register_surface(&s.id, &s.nonce);
        }
        *intake = Some(bound);
        Ok(())
    }

    fn with_intake(&self, f: impl FnOnce(&Intake)) {
        if let Some(i) = self.intake.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            f(i);
        }
    }

    /// Runs `f` on the state and fires the listener if it reports a change.
    fn update(&self, f: impl FnOnce(&mut State, Instant) -> bool) -> bool {
        let mut st = lock(&self.state);
        let changed = f(&mut st, Instant::now());
        let listener = st.listener.clone();
        drop(st);
        if changed && let Some(l) = listener {
            l();
        }
        changed
    }

    pub fn register_surface(&self, cwd: &str) -> SurfaceEnv {
        let env = SurfaceEnv {
            surface_id: uuid(),
            nonce: hex(&random_bytes()),
            socket_path: self.socket_path().to_string_lossy().into_owned(),
        };
        let added = self.update(|st, now| {
            if st.surfaces.len() >= MAX_SURFACES {
                return false;
            }
            let (id, nonce, cwd) = (env.surface_id.clone(), env.nonce.clone(), cwd.to_owned());
            st.surfaces.push(Surface { id, nonce, cwd, branch: None, session: Session::new(now) });
            true
        });
        if added {
            self.with_intake(|i| i.register_surface(&env.surface_id, &env.nonce));
        }
        env
    }

    pub fn unregister_surface(&self, surface_id: &str) {
        self.with_intake(|i| i.unregister_surface(surface_id));
        self.update(|st, _| {
            let before = st.surfaces.len();
            st.surfaces.retain(|s| s.id != surface_id);
            if st.selected.as_deref() == Some(surface_id) {
                st.selected = None;
            }
            st.surfaces.len() != before
        });
    }

    /// `title` is accepted for the contract; rows are named after the cwd.
    pub fn set_surface_info(&self, surface_id: &str, _title: &str, cwd: &str, git_branch: Option<String>) {
        self.update(|st, _| {
            let Some(s) = st.surface(surface_id) else { return false };
            let changed = s.cwd != cwd || s.branch != git_branch;
            s.cwd = cwd.to_owned();
            s.branch = git_branch;
            changed
        });
    }

    pub fn select_surface(&self, surface_id: &str) {
        self.update(|st, _| {
            if st.selected.as_deref() == Some(surface_id) || !st.surfaces.iter().any(|s| s.id == surface_id) {
                return false;
            }
            st.selected = Some(surface_id.to_owned());
            true
        });
    }

    /// The OSC 777 fallback: anything in the pty can print these, so they are status-only.
    pub fn on_osc_notification(&self, surface_id: &str, title: &str, body: &str) {
        let Ok(event) = parse_osc(title, body) else { return };
        self.update(|st, now| st.apply_unverified(surface_id, &event, now));
    }

    pub fn snapshot(&self) -> SidebarSnapshot {
        lock(&self.state).snapshot(Instant::now())
    }

    pub fn set_listener(&self, listener: Listener) {
        lock(&self.state).listener = Some(listener);
    }

    /// Bytes for `ghostty_surface_text` (Enter allows, Esc denies), only while that surface is
    /// blocked on a nonce-verified permission request. The request is consumed.
    pub fn answer_permission(&self, surface_id: &str, allow: bool) -> Option<Vec<u8>> {
        let mut answered = false;
        self.update(|st, now| {
            answered = st.surface(surface_id).is_some_and(|s| s.session.answered(now));
            answered
        });
        answered.then(|| if allow { b"\r".to_vec() } else { b"\x1b".to_vec() })
    }

    #[cfg(test)]
    pub(crate) fn with_state<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        f(&mut lock(&self.state))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    fn core() -> Core {
        let c = Core::new(format!("/tmp/haunt-core-test-{}", std::process::id()));
        c.with_state(|st| st.home = Some("/Users/me".into()));
        c
    }

    fn line(env: &SurfaceEnv, nonce: Option<&str>, body: &str) -> String {
        let nonce = nonce.map(|n| format!(r#","nonce":"{n}""#)).unwrap_or_default();
        format!(r#"{{"v":1,"surface_id":"{}"{nonce},{body}}}"#, env.surface_id)
    }

    const PERM: &str = r#""event":"permission_seen","tool_name":"Bash","tool_input":{"command":"git push"}"#;

    fn blocked(c: &Core, verified: bool) -> SurfaceEnv {
        let env = c.register_surface("/Users/me/code/orchestrator");
        let nonce = if verified { env.nonce.clone() } else { "0".repeat(32) };
        c.with_state(|st| {
            let now = Instant::now();
            st.handle_line(&line(&env, Some(&nonce), r#""event":"prompt_submit","query":"release""#), now);
            st.handle_line(&line(&env, Some(&nonce), PERM), now);
        });
        env
    }

    #[test]
    fn surfaces_get_unique_ids_and_128_bit_nonces() {
        let c = core();
        let (a, b) = (c.register_surface("/a"), c.register_surface("/b"));
        assert_ne!(a.surface_id, b.surface_id);
        assert_ne!(a.nonce, b.nonce);
        assert_eq!(a.nonce.len(), 32);
        assert!(a.nonce.chars().all(|ch| ch.is_ascii_hexdigit()));
        assert_eq!(a.surface_id.len(), 36);
        assert!(a.socket_path.ends_with("/sock"));
    }

    #[test]
    fn answer_only_for_a_verified_live_request() {
        let c = core();
        let env = blocked(&c, true);
        assert_eq!(c.answer_permission(&env.surface_id, true), Some(b"\r".to_vec()));
        assert_eq!(c.answer_permission(&env.surface_id, true), None, "consumed");

        let env = blocked(&c, true);
        assert_eq!(c.answer_permission(&env.surface_id, false), Some(b"\x1b".to_vec()));
        assert_eq!(c.answer_permission("nope", true), None);
    }

    #[test]
    fn wrong_or_missing_nonce_is_status_only() {
        let c = core();
        let env = blocked(&c, false);
        let row = &c.snapshot().groups[0].rows[0];
        assert!(row.needs_you, "status still moves");
        assert_eq!(c.answer_permission(&env.surface_id, true), None);

        let env = c.register_surface("/w");
        c.with_state(|st| st.handle_line(&line(&env, None, PERM), Instant::now()));
        assert_eq!(c.answer_permission(&env.surface_id, true), None);
    }

    #[test]
    fn another_surfaces_nonce_does_not_verify() {
        let c = core();
        let a = c.register_surface("/a");
        let b = c.register_surface("/b");
        c.with_state(|st| st.handle_line(&line(&b, Some(&a.nonce), PERM), Instant::now()));
        assert_eq!(c.answer_permission(&b.surface_id, true), None);
    }

    #[test]
    fn osc_fallback_is_status_only() {
        let c = core();
        let env = c.register_surface("/w");
        let body = format!(r#"{{"v":1,"nonce":"{}",{PERM}}}"#, env.nonce);
        c.on_osc_notification(&env.surface_id, "warp://cli-agent", &body);
        assert!(c.snapshot().groups[0].rows[0].needs_you);
        assert_eq!(c.answer_permission(&env.surface_id, true), None, "even with the right nonce");
        c.on_osc_notification(&env.surface_id, "Build done", "{}");
    }

    #[test]
    fn stale_answer_after_the_prompt_resolved_writes_nothing() {
        let c = core();
        let env = blocked(&c, true);
        c.with_state(|st| {
            let ran = r#""event":"tool_ran","tool_name":"Bash","tool_input":{"command":"git push"}"#;
            st.handle_line(&line(&env, Some(&env.nonce), ran), Instant::now())
        });
        assert_eq!(c.answer_permission(&env.surface_id, true), None);
    }

    #[test]
    fn unknown_surface_and_bad_lines_are_dropped() {
        let c = core();
        c.register_surface("/a");
        c.with_state(|st| {
            let now = Instant::now();
            assert!(!st.handle_line(r#"{"v":1,"surface_id":"ghost","event":"stop"}"#, now));
            assert!(!st.handle_line("not json", now));
        });
    }

    #[test]
    fn listener_fires_on_changes_only() {
        let c = core();
        let n = Arc::new(AtomicUsize::new(0));
        let k = n.clone();
        c.set_listener(Arc::new(move || {
            k.fetch_add(1, Ordering::SeqCst);
        }));
        let env = c.register_surface("/a");
        c.select_surface(&env.surface_id);
        c.select_surface(&env.surface_id);
        c.set_surface_info(&env.surface_id, "zsh", "/a", None);
        c.set_surface_info(&env.surface_id, "zsh", "/a", Some("main".into()));
        assert_eq!(n.load(Ordering::SeqCst), 3);
        assert!(c.snapshot().groups[0].rows[0].selected);
        c.unregister_surface(&env.surface_id);
        assert_eq!(n.load(Ordering::SeqCst), 4);
        assert!(c.snapshot().groups.is_empty());
    }

    #[test]
    fn socket_end_to_end() {
        use std::io::Write;
        use std::os::unix::net::UnixStream;
        let dir = format!("/tmp/haunt-e2e-{}", std::process::id());
        let _ = std::fs::remove_dir_all(&dir);
        let c = Core::new(&dir);
        c.start().unwrap();
        c.start().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let tx = Mutex::new(tx);
        c.set_listener(Arc::new(move || {
            let _ = tx.lock().unwrap().send(());
        }));
        let env = c.register_surface("/w");
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let mut s = UnixStream::connect(&env.socket_path).unwrap();
        writeln!(s, "{}", line(&env, Some(&env.nonce), PERM)).unwrap();
        drop(s);
        rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(c.answer_permission(&env.surface_id, true), Some(b"\r".to_vec()));
        drop(c);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
