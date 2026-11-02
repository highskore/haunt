//! `Core`: surfaces, their agent sessions, the socket intake and the sidebar snapshot.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Instant;

use serde_json::{Value, json};

use crate::allowlist::{self, AllowError, AllowSuggestion, Approval};
use crate::arrange::{self, Arrangement, RowInfo};
use crate::ctl::{self, Ctl};
use crate::decisions::{Decision, DecisionLog};
use crate::event::{AgentEvent, parse_osc};
use crate::intake::{Delivery, Intake, IntakeError, Limits, SOCKET_NAME};
use crate::layout::{self, SidebarSnapshot, SurfaceView};
use crate::session::{Outcome, Session};

const MAX_SURFACES: usize = 512;
const MAX_PROPOSALS: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[cfg_attr(feature = "ffi", derive(uniffi::Error))]
pub enum CoreError {
    #[error("insecure: {reason}")]
    Insecure { reason: String },
    #[error("io: {reason}")]
    Io { reason: String },
    #[error("invalid: {reason}")]
    Invalid { reason: String },
}

impl From<AllowError> for CoreError {
    fn from(e: AllowError) -> Self {
        let reason = e.to_string();
        match e {
            AllowError::Symlink(_) | AllowError::Unsafe(_) => Self::Insecure { reason },
            AllowError::Invalid(_) => Self::Invalid { reason },
            AllowError::Io(_) => Self::Io { reason },
        }
    }
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
/// Sees every event for a registered surface, with whether it was verified; called outside the lock.
pub type EventTap = Arc<dyn Fn(&AgentEvent, bool) + Send + Sync>;

struct Surface {
    id: String,
    nonce: String,
    cwd: String,
    branch: Option<String>,
    /// Branch at `session.cwd`, looked up here because the UI only knows the surface cwd.
    agent_branch: Option<String>,
    session: Session,
}

#[derive(Default)]
pub(crate) struct State {
    surfaces: Vec<Surface>,
    selected: Option<String>,
    home: Option<String>,
    /// Basename of the login shell surfaces run, for shell rows.
    shell: Option<String>,
    listener: Option<Listener>,
    pub(crate) decisions: DecisionLog,
    /// (project, command) suggestions the user accepted or dismissed.
    allow_done: HashSet<(String, String)>,
    /// Rules plugins proposed, newest first, as (plugin id, project, command).
    allow_proposals: Vec<(String, String, String)>,
    event_tap: Option<EventTap>,
    /// The arranging plugin's id, the token of the instance that set it, and its arrangement.
    arrangement: Option<(String, u64, Arrangement)>,
    /// Tokens of plugin instances loaded with the sidebar capability and not disabled.
    sidebar_live: HashSet<u64>,
    next_sidebar_token: u64,
}

impl State {
    /// Whether an arrangement set by `token` was dropped.
    fn drop_arrangement(&mut self, token: u64) -> bool {
        let owned = self.arrangement.as_ref().is_some_and(|(_, t, _)| *t == token);
        if owned {
            self.arrangement = None;
        }
        owned
    }

    fn surface(&mut self, id: &str) -> Option<&mut Surface> {
        self.surfaces.iter_mut().find(|s| s.id == id)
    }

    fn tap_for(&self, surface_id: &str) -> Option<EventTap> {
        self.event_tap.clone().filter(|_| self.surfaces.iter().any(|s| s.id == surface_id))
    }

    /// One intake delivery; the intake already checked the nonce and the rate limit.
    pub(crate) fn deliver(&mut self, d: &Delivery, now: Instant) -> bool {
        let Some(event) = &d.event else { return false };
        let changed = self.surface(&d.surface_id).is_some_and(|s| {
            let mut changed = s.session.apply(event, d.verified, now);
            // Every verified event re-reads HEAD, so a checkout inside the session shows up.
            if d.verified && let Some(cwd) = &s.session.cwd {
                let b = crate::git::branch(cwd);
                changed |= b != s.agent_branch;
                s.agent_branch = b;
            }
            changed
        });
        self.settle();
        changed
    }

    /// A hook line checked against the registered nonces, as the intake does.
    fn decode(&self, line: &str) -> Delivery {
        let nonces = self.surfaces.iter().map(|s| (s.id.clone(), s.nonce.clone())).collect();
        crate::intake::decode(line, &nonces)
    }

    /// A socket line as the intake would deliver it, minus the socket and the rate limit.
    #[cfg(test)]
    pub(crate) fn handle_line(&mut self, line: &str, now: Instant) -> bool {
        let d = self.decode(line);
        self.deliver(&d, now)
    }

    fn apply_unverified(&mut self, id: &str, event: &AgentEvent, now: Instant) -> bool {
        let changed = self.surface(id).is_some_and(|s| s.session.apply(event, false, now));
        self.settle();
        changed
    }

    /// Moves every ended request into the decision log. Only verified requests ever exist, so
    /// unverified events can at most end one (as superseded), never add one.
    fn settle(&mut self) {
        for s in &mut self.surfaces {
            for (p, outcome) in s.session.take_ended() {
                self.decisions.record(Decision::new(&s.id, &p, outcome));
            }
        }
    }

    /// Proposals that still pass every check, most recently approved first. Each is re-checked here
    /// and again on accept, so a proposal never outlives its approvals or its project's safety.
    fn suggestions(&self) -> Vec<AllowSuggestion> {
        if self.allow_proposals.is_empty() {
            return Vec::new();
        }
        let approvals = allowlist::approvals(self.decisions.iter(), 1);
        let counted: HashMap<(&str, &str), (usize, u32)> =
            approvals.iter().enumerate().map(|(rank, a)| ((a.project.as_str(), a.command.as_str()), (rank, a.count))).collect();
        let mut out: Vec<(usize, AllowSuggestion)> = self
            .allow_proposals
            .iter()
            .filter(|(_, p, c)| !self.allow_done.contains(&(p.clone(), c.clone())))
            .filter_map(|(plugin_id, project, command)| {
                let &(rank, count) = counted.get(&(project.as_str(), command.as_str()))?;
                let rule = allowlist::rule_for(command)?;
                allowlist::check_project(project).ok()?;
                let s = AllowSuggestion { project: project.clone(), command: command.clone(), rule, approvals: count, plugin_id: plugin_id.clone() };
                Some((rank, s))
            })
            .collect();
        out.sort_by_key(|(rank, _)| *rank);
        out.into_iter().map(|(_, s)| s).collect()
    }

    /// Records a plugin's proposal; true if it is new. Nothing is written until the user accepts it.
    fn propose(&mut self, plugin_id: &str, project: &str, command: &str) -> Result<bool, CoreError> {
        let invalid = |reason: &str| Err(CoreError::Invalid { reason: reason.into() });
        if allowlist::rule_for(command).is_none() {
            return invalid("not a command an exact rule can allow");
        }
        if !allowlist::approvals(self.decisions.iter(), 1).iter().any(|a| a.project == project && a.command == command) {
            return invalid("the user never approved this command in this project in haunt");
        }
        allowlist::check_project(project)?;
        let key = (project.to_owned(), command.to_owned());
        if self.allow_done.contains(&key) {
            return invalid("the user already accepted or dismissed this rule");
        }
        if self.allow_proposals.iter().any(|(_, p, c)| *p == key.0 && *c == key.1) {
            return Ok(false);
        }
        self.allow_proposals.insert(0, (plugin_id.to_owned(), key.0, key.1));
        self.allow_proposals.truncate(MAX_PROPOSALS);
        Ok(true)
    }

    pub(crate) fn snapshot(&self, now: Instant) -> SidebarSnapshot {
        let snap = self.core_snapshot(now);
        match &self.arrangement {
            Some((_, t, a)) if self.sidebar_live.contains(t) => arrange::arrange(snap, a),
            _ => snap,
        }
    }

    /// Before any plugin arrangement.
    fn core_snapshot(&self, now: Instant) -> SidebarSnapshot {
        let views: Vec<SurfaceView> = self
            .surfaces
            .iter()
            .map(|s| {
                let (cwd, branch) = match &s.session.cwd {
                    Some(c) => (c.as_str(), s.agent_branch.as_deref()),
                    None => (s.cwd.as_str(), s.branch.as_deref()),
                };
                SurfaceView { id: &s.id, cwd, branch, session: &s.session, selected: self.selected.as_deref() == Some(s.id.as_str()) }
            })
            .collect();
        layout::snapshot(&views, self.home.as_deref(), self.shell.as_deref(), now)
    }
}

pub(crate) fn random_bytes() -> [u8; 16] {
    let mut b = [0; 16];
    // Without a random nonce the hook channel has no authentication at all, so failing here is fatal.
    File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).expect("read /dev/urandom");
    b
}

pub(crate) fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn uuid() -> String {
    let mut b = random_bytes();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex(&b);
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

struct Servers {
    intake: Intake,
    _ctl: Ctl,
}

/// Thread-safe; the listener fires on whichever thread caused the change, never under the lock.
pub struct Core {
    dir: PathBuf,
    state: Arc<Mutex<State>>,
    servers: Mutex<Option<Servers>>,
}

fn lock(m: &Mutex<State>) -> MutexGuard<'_, State> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Runs `f` on the state and fires the listener, outside the lock, if it reports a change.
fn update_state(state: &Mutex<State>, f: impl FnOnce(&mut State, Instant) -> bool) -> bool {
    let mut st = lock(state);
    let changed = f(&mut st, Instant::now());
    let listener = st.listener.clone();
    drop(st);
    if changed && let Some(l) = listener {
        l();
    }
    changed
}

/// One intake delivery, then its event to the tap outside the lock (plugins call back into the core).
fn deliver(state: &Mutex<State>, d: &Delivery) -> bool {
    let mut tap = None;
    let changed = update_state(state, |st, now| {
        tap = st.tap_for(&d.surface_id);
        st.deliver(d, now)
    });
    if let (Some(tap), Some(event)) = (tap, &d.event) {
        tap(event, d.verified);
    }
    changed
}

const DEFAULT_LIMIT: u64 = 50;
const MAX_LIMIT: u64 = 1000;

/// One ctl request: `dump`, `event` (a hook line, nonce still required) or `decisions`.
fn ctl_request(state: &Mutex<State>, line: &str) -> String {
    let Ok(req) = serde_json::from_str::<Value>(line) else { return ctl::error("invalid json") };
    match req.get("cmd").and_then(Value::as_str) {
        Some("dump") => {
            let snapshot = lock(state).snapshot(Instant::now());
            let pending: Vec<Value> = snapshot
                .groups
                .iter()
                .flat_map(|g| &g.rows)
                .filter_map(|r| {
                    r.pending.as_ref().map(|p| json!({ "surface_id": r.surface_id, "key": p.key, "tool": p.tool, "preview": p.preview, "suspicious": p.suspicious }))
                })
                .collect();
            json!({ "ok": true, "snapshot": snapshot, "pending": pending }).to_string()
        }
        Some("event") => {
            let hook_line = match req.get("line") {
                Some(Value::String(s)) => s.clone(),
                Some(v @ Value::Object(_)) => v.to_string(),
                _ => return ctl::error("event needs a line"),
            };
            let d = lock(state).decode(&hook_line);
            let changed = deliver(state, &d);
            json!({ "ok": true, "verified": d.verified, "changed": changed }).to_string()
        }
        Some("decisions") => {
            let query = req.get("query").and_then(Value::as_str).unwrap_or("");
            let limit = req.get("limit").and_then(Value::as_u64).unwrap_or(DEFAULT_LIMIT).min(MAX_LIMIT) as usize;
            json!({ "ok": true, "decisions": lock(state).decisions.query(query, limit) }).to_string()
        }
        _ => ctl::error("unknown cmd"),
    }
}

impl Core {
    pub fn new(config_dir: impl Into<PathBuf>) -> Self {
        let shell = std::env::var("SHELL").ok().and_then(|s| s.rsplit('/').next().map(str::to_owned)).filter(|s| !s.is_empty());
        let state = State { home: std::env::var("HOME").ok(), shell, ..State::default() };
        Self { dir: config_dir.into(), state: Arc::new(Mutex::new(state)), servers: Mutex::new(None) }
    }

    pub fn socket_path(&self) -> PathBuf {
        self.dir.join(SOCKET_NAME)
    }

    /// Binds the hook socket and the ctl socket, opens the decision log, and registers every
    /// surface's nonce with the intake; a second call is a no-op.
    pub fn start(&self) -> Result<(), CoreError> {
        let mut servers = self.servers.lock().unwrap_or_else(|e| e.into_inner());
        if servers.is_some() {
            return Ok(());
        }
        let state = self.state.clone();
        let sink = Arc::new(move |d: Delivery| {
            deliver(&state, &d);
        });
        // Binding the intake first secures the dir the log and ctl live in.
        let intake = Intake::bind(&self.dir, Limits::default(), sink).map_err(CoreError::from)?;
        lock(&self.state).decisions.open(&self.dir).map_err(|e| {
            let reason = format!("decision log: {e}");
            match e.raw_os_error() {
                Some(libc::ELOOP) | None => CoreError::Insecure { reason },
                Some(_) => CoreError::Io { reason },
            }
        })?;
        let state = self.state.clone();
        let ctl = Ctl::bind(&self.dir, Arc::new(move |line: &str| ctl_request(&state, line))).map_err(CoreError::from)?;
        for s in &lock(&self.state).surfaces {
            intake.register_surface(&s.id, &s.nonce);
        }
        *servers = Some(Servers { intake, _ctl: ctl });
        Ok(())
    }

    fn with_intake(&self, f: impl FnOnce(&Intake)) {
        if let Some(s) = self.servers.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            f(&s.intake);
        }
    }

    fn update(&self, f: impl FnOnce(&mut State, Instant) -> bool) -> bool {
        update_state(&self.state, f)
    }

    /// `Invalid` once `MAX_SURFACES` are registered: an env the core doesn't know would never verify.
    pub fn register_surface(&self, cwd: &str) -> Result<SurfaceEnv, CoreError> {
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
            st.surfaces.push(Surface { id, nonce, cwd, branch: None, agent_branch: None, session: Session::new(now) });
            true
        });
        if !added {
            return Err(CoreError::Invalid { reason: format!("at most {MAX_SURFACES} surfaces") });
        }
        self.with_intake(|i| i.register_surface(&env.surface_id, &env.nonce));
        Ok(env)
    }

    pub fn unregister_surface(&self, surface_id: &str) {
        self.with_intake(|i| i.unregister_surface(surface_id));
        self.update(|st, _| {
            let before = st.surfaces.len();
            if let Some(s) = st.surface(surface_id) {
                s.session.close();
            }
            st.settle();
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
        let mut tap = None;
        self.update(|st, now| {
            tap = st.tap_for(surface_id);
            st.apply_unverified(surface_id, &event, now)
        });
        if let Some(tap) = tap {
            tap(&event, false);
        }
    }

    pub fn snapshot(&self) -> SidebarSnapshot {
        lock(&self.state).snapshot(Instant::now())
    }

    pub fn set_listener(&self, listener: Listener) {
        lock(&self.state).listener = Some(listener);
    }

    /// Bytes for `ghostty_surface_text`, only while `request_key` is that surface's live,
    /// nonce-verified permission request. The request is consumed. The keys are the asking agent's
    /// (`Agent::answer_bytes`); Enter is never sent, since it takes whichever option is highlighted.
    /// An agent without known keys gets nothing and its request stays for the terminal.
    pub fn answer_permission(&self, surface_id: &str, request_key: u64, allow: bool) -> Option<Vec<u8>> {
        self.answer_by(surface_id, request_key, allow, None)
    }

    /// `answer_permission`, logged as the plugin's answer when `plugin_id` is set.
    pub(crate) fn answer_by(&self, surface_id: &str, request_key: u64, allow: bool, plugin_id: Option<&str>) -> Option<Vec<u8>> {
        let outcome = match (plugin_id, allow) {
            (None, true) => Outcome::AllowedInHaunt,
            (None, false) => Outcome::DeniedInHaunt,
            (Some(id), true) => Outcome::AllowedByPlugin { plugin_id: id.to_owned() },
            (Some(id), false) => Outcome::DeniedByPlugin { plugin_id: id.to_owned() },
        };
        let mut bytes = None;
        self.update(|st, now| {
            bytes = st.surface(surface_id).and_then(|s| {
                let b = s.session.live_permission()?.agent.answer_bytes(allow)?;
                s.session.answer_as(request_key, outcome, now).then_some(b)
            });
            st.settle();
            bytes.is_some()
        });
        bytes.map(<[u8]>::to_vec)
    }

    /// A key went to the surface's pty: from now on the terminal answers its pending request.
    pub fn on_user_input(&self, surface_id: &str) {
        self.update(|st, _| st.surface(surface_id).is_some_and(|s| s.session.user_input()));
    }

    /// Ended permission requests, newest first; see `DecisionLog::query`.
    pub fn decisions(&self, query: &str, limit: u32) -> Vec<Decision> {
        lock(&self.state).decisions.query(query, limit as usize)
    }

    pub fn allow_suggestions(&self) -> Vec<AllowSuggestion> {
        lock(&self.state).suggestions()
    }

    /// Writes the suggested exact rule into `<project>/.claude/settings.local.json`.
    pub fn accept_allow_suggestion(&self, project: &str, command: &str) -> Result<(), CoreError> {
        let rule = lock(&self.state)
            .suggestions()
            .into_iter()
            .find(|s| s.project == project && s.command == command)
            .map(|s| s.rule)
            .ok_or_else(|| CoreError::Invalid { reason: "no such suggestion".into() })?;
        allowlist::add_rule(Path::new(project), &rule)?;
        lock(&self.state).allow_done.insert((project.to_owned(), command.to_owned()));
        Ok(())
    }

    pub fn dismiss_allow_suggestion(&self, project: &str, command: &str) {
        self.update(|st, _| st.allow_done.insert((project.to_owned(), command.to_owned())));
    }

    /// Replaces the event tap; plugins get their events through it.
    pub fn set_event_tap(&self, tap: Option<EventTap>) {
        lock(&self.state).event_tap = tap;
    }

    /// What plugin imports may reach: reading decisions and approvals, and proposing a rule.
    pub fn handle(&self) -> CoreHandle {
        CoreHandle { state: self.state.clone() }
    }
}

/// The core as plugins see it. Plugin calls hold the plugin lock and then take the core's, so the
/// core never calls a plugin while holding its own.
/// One plugin instance's claim on the sidebar, from `CoreHandle::attach_sidebar`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SidebarToken(u64);

#[derive(Clone)]
pub struct CoreHandle {
    state: Arc<Mutex<State>>,
}

impl std::fmt::Debug for CoreHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CoreHandle")
    }
}

impl CoreHandle {
    pub fn decisions(&self, query: &str, limit: u32) -> Vec<Decision> {
        lock(&self.state).decisions.query(query, limit as usize)
    }

    pub fn approvals(&self, min_count: u32) -> Vec<Approval> {
        allowlist::approvals(lock(&self.state).decisions.iter(), min_count)
    }

    /// Adds a pending suggestion for the UI; the rule is written only by `accept_allow_suggestion`.
    pub fn propose_allow_rule(&self, plugin_id: &str, project: &str, command: &str) -> Result<(), CoreError> {
        let mut res = Ok(false);
        update_state(&self.state, |st, _| {
            res = st.propose(plugin_id, project, command);
            *res.as_ref().unwrap_or(&false)
        });
        res.map(|_| ())
    }

    /// The rows in the core's own order, without meta or task text.
    pub fn sidebar_rows(&self) -> Vec<RowInfo> {
        arrange::row_infos(&lock(&self.state).core_snapshot(Instant::now()))
    }

    /// The first live plugin to arrange owns the sidebar until it clears or goes away.
    pub fn set_arrangement(&self, plugin_id: &str, token: SidebarToken, a: Arrangement) -> Result<(), CoreError> {
        a.validate().map_err(|reason| CoreError::Invalid { reason })?;
        let mut res = Ok(());
        update_state(&self.state, |st, _| {
            if !st.sidebar_live.contains(&token.0) {
                res = Err(CoreError::Invalid { reason: "not loaded with the sidebar capability".into() });
                return false;
            }
            match &st.arrangement {
                Some((owner, t, _)) if owner != plugin_id && st.sidebar_live.contains(t) => {
                    res = Err(CoreError::Invalid { reason: format!("the sidebar is arranged by {owner}") });
                    false
                }
                Some((_, t, old)) if *t == token.0 && *old == a => false,
                _ => {
                    st.arrangement = Some((plugin_id.to_owned(), token.0, a));
                    true
                }
            }
        });
        res
    }

    pub fn clear_arrangement(&self, token: SidebarToken) {
        update_state(&self.state, |st, _| st.drop_arrangement(token.0));
    }

    /// Marks a plugin instance loaded with the sidebar capability; only its arrangement is applied.
    pub fn attach_sidebar(&self) -> SidebarToken {
        let mut st = lock(&self.state);
        st.next_sidebar_token += 1;
        let t = st.next_sidebar_token;
        st.sidebar_live.insert(t);
        SidebarToken(t)
    }

    /// The instance was disabled, reloaded or dropped: its arrangement goes with it.
    pub fn detach_sidebar(&self, token: SidebarToken) {
        update_state(&self.state, |st, _| {
            st.sidebar_live.remove(&token.0);
            st.drop_arrangement(token.0)
        });
    }

    /// A plugin loaded without the sidebar capability loses any arrangement an earlier load left.
    pub fn forget_arrangement_of(&self, plugin_id: &str) {
        update_state(&self.state, |st, _| {
            let stale = st.arrangement.as_ref().is_some_and(|(owner, t, _)| owner == plugin_id && !st.sidebar_live.contains(t));
            if stale {
                st.arrangement = None;
            }
            stale
        });
    }
}

#[cfg(test)]
impl Core {
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
        let env = c.register_surface("/Users/me/code/orchestrator").unwrap();
        let nonce = if verified { env.nonce.clone() } else { "0".repeat(32) };
        c.with_state(|st| {
            let now = Instant::now();
            st.handle_line(&line(&env, Some(&nonce), r#""event":"prompt_submit","query":"release""#), now);
            st.handle_line(&line(&env, Some(&nonce), PERM), now);
        });
        env
    }

    /// Answers with the surface's current key, so a None means no live request at all.
    fn answer(c: &Core, id: &str, allow: bool) -> Option<Vec<u8>> {
        let key = c.with_state(|st| st.surface(id).map_or(0, |s| s.session.current_key()));
        c.answer_permission(id, key, allow)
    }

    fn pending(c: &Core) -> Option<crate::layout::PendingRequest> {
        c.snapshot().groups.iter().flat_map(|g| &g.rows).find_map(|r| r.pending.clone())
    }

    fn only_row(c: &Core) -> crate::layout::Row {
        c.snapshot().groups.into_iter().flat_map(|g| g.rows).next().expect("a row")
    }

    #[test]
    fn claude_rows_follow_the_verified_hook_cwd() {
        let repo = std::env::temp_dir().join(format!("haunt-model-cwd-{}", std::process::id()));
        let specs = repo.join("specs");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(&specs).unwrap();
        std::fs::write(repo.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();

        let c = core();
        let env = c.register_surface("/Users/me").unwrap();
        let forged = r#""event":"prompt_submit","cwd":"/Users/me/code/elsewhere""#;
        c.with_state(|st| st.handle_line(&line(&env, None, forged), Instant::now()));
        let row = only_row(&c);
        assert_eq!((row.name.as_str(), row.meta.as_str()), ("~", "~"), "an unverified cwd is ignored");

        let body = format!(r#""event":"stop","cwd":"{}""#, specs.display());
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), &body), Instant::now()));
        let row = only_row(&c);
        assert_eq!(row.name, "specs");
        assert!(row.meta.starts_with("main · Done in"), "{}", row.meta);

        std::fs::write(repo.join(".git/HEAD"), "ref: refs/heads/next\n").unwrap();
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), &body), Instant::now()));
        assert!(only_row(&c).meta.starts_with("next · "), "a checkout shows on the next event");
        let _ = std::fs::remove_dir_all(&repo);

        let body = r#""event":"stop","cwd":"/Users/me/code/vibes/specs""#;
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), body), Instant::now()));
        let row = only_row(&c);
        assert_eq!(row.name, "specs");
        assert!(row.meta.starts_with("~/code/vibes/specs · Done in"), "no branch falls back to the cwd: {}", row.meta);
    }

    #[test]
    fn a_stale_request_key_writes_nothing() {
        let c = core();
        let env = blocked(&c, true);
        let old = pending(&c).expect("a live request");
        assert_eq!(old.preview, "git push");
        let changed = r#""event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#;
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), changed), Instant::now()));
        assert_eq!(c.answer_permission(&env.surface_id, old.key, true), None);
        let new = pending(&c).expect("the new request is still live");
        assert_eq!(new.preview, "rm -rf build");
        assert_eq!(c.answer_permission("other", new.key, true), None, "a key is only good for its surface");
        assert_eq!(c.answer_permission(&env.surface_id, new.key, false), Some(b"\x1b".to_vec()));
        let log: Vec<_> = c.decisions("", 10).into_iter().map(|d| (d.preview, d.outcome)).collect();
        assert_eq!(log, [("rm -rf build".into(), crate::Outcome::DeniedInHaunt), ("git push".into(), crate::Outcome::Superseded)]);
    }

    #[test]
    fn unverified_prompts_never_reach_the_decision_log() {
        let c = core();
        let env = blocked(&c, false);
        c.with_state(|st| st.handle_line(&line(&env, None, r#""event":"stop""#), Instant::now()));
        c.on_osc_notification(&env.surface_id, "haunt://cli-agent", &format!("{{\"v\":1,{PERM}}}"));
        c.unregister_surface(&env.surface_id);
        assert!(c.decisions("", 10).is_empty());

        let env = blocked(&c, true);
        c.unregister_surface(&env.surface_id);
        let d = c.decisions("", 10);
        assert_eq!((d.len(), d[0].outcome.clone(), d[0].surface_id.as_str()), (1, crate::Outcome::Superseded, env.surface_id.as_str()));
    }

    fn canonical_dir(tag: &str) -> String {
        let d = format!("/tmp/haunt-{tag}-{}", std::process::id());
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::canonicalize(d).unwrap().to_str().unwrap().to_owned()
    }

    #[test]
    fn a_key_typed_in_the_terminal_retires_the_request() {
        let c = core();
        let env = blocked(&c, true);
        let key = pending(&c).expect("live").key;
        c.on_user_input("other");
        c.on_user_input(&env.surface_id);
        assert!(pending(&c).is_none());
        assert_eq!(c.snapshot().groups[0].rows[0].meta, "~/code/orchestrator · Waiting for you");
        assert_eq!(c.answer_permission(&env.surface_id, key, true), None);
        c.with_state(|st| {
            let ran = r#""event":"tool_ran","tool_name":"Bash","tool_input":{"command":"git push"}"#;
            st.handle_line(&line(&env, Some(&env.nonce), ran), Instant::now())
        });
        assert_eq!(c.decisions("", 1)[0].outcome, crate::Outcome::AnsweredInTerminal);
    }

    #[test]
    fn invisible_or_multiline_commands_are_never_suggested() {
        let project = canonical_dir("allow-raw");
        for cmd in [r"git\u200b push", r"ls\nrm -rf x", r"ls\t-la"] {
            let c = core();
            let env = c.register_surface(&project).unwrap();
            let perm = format!(r#""event":"permission_seen","cwd":"{project}","tool_name":"Bash","tool_input":{{"command":"{cmd}"}}"#);
            let ran = format!(r#""event":"tool_ran","tool_name":"Bash","tool_input":{{"command":"{cmd}"}}"#);
            for _ in 0..3 {
                c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), &perm), Instant::now()));
                assert_eq!(answer(&c, &env.surface_id, true), None, "{cmd} is answered in the terminal");
                c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), &ran), Instant::now()));
            }
            assert_eq!(c.decisions("", 10).len(), 3);
            assert!(c.handle().approvals(1).is_empty(), "{cmd}");
            let raw: String = serde_json::from_str(&format!("\"{cmd}\"")).unwrap();
            assert!(c.handle().propose_allow_rule("p", &project, &raw).is_err(), "{cmd}");
            assert!(c.allow_suggestions().is_empty(), "{cmd}");
        }
        std::fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn a_hidden_newline_is_flagged_and_never_answered_from_haunt() {
        let c = core();
        let env = c.register_surface("/w").unwrap();
        let perm = r#""event":"permission_seen","tool_name":"Bash","tool_input":{"command":"ls #\nrm -rf ~/x"}"#;
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), perm), Instant::now()));
        let p = pending(&c).expect("shown");
        assert_eq!((p.preview.as_str(), p.suspicious), ("ls #⏎rm -rf ~/x", true));
        assert_eq!(c.snapshot().groups[0].rows[0].meta, "/w · Approve: ls #⏎rm -rf ~/x?");
        assert_eq!(c.answer_permission(&env.surface_id, p.key, true), None);
        assert_eq!(c.answer_permission(&env.surface_id, p.key, false), None);
        assert!(pending(&c).is_some(), "still waiting for the terminal");
    }

    #[test]
    fn only_verified_haunt_approvals_are_counted() {
        let project = canonical_dir("allow");
        let c = core();
        let env = c.register_surface(&project).unwrap();
        let perm = format!(r#""event":"permission_seen","cwd":"{project}","tool_name":"Bash","tool_input":{{"command":"cargo test"}}"#);
        let ran = r#""event":"tool_ran","tool_name":"Bash","tool_input":{"command":"cargo test"}"#;
        let send = |nonce: Option<&str>, body: &str| c.with_state(|st| st.handle_line(&line(&env, nonce, body), Instant::now()));
        for _ in 0..3 {
            send(None, &perm);
            send(None, ran);
        }
        assert!(c.handle().approvals(1).is_empty(), "unverified approvals never count");
        send(Some(&env.nonce), &perm);
        answer(&c, &env.surface_id, true).unwrap();
        for _ in 0..3 {
            send(Some(&env.nonce), &perm);
            send(Some(&env.nonce), ran);
        }
        let counts = |min| c.handle().approvals(min).into_iter().map(|a| (a.command, a.count)).collect::<Vec<_>>();
        assert_eq!(counts(1), [("cargo test".to_owned(), 1)], "answers in the terminal never count");
        for _ in 0..2 {
            send(Some(&env.nonce), &perm);
            answer(&c, &env.surface_id, true).unwrap();
        }
        assert_eq!(counts(3), [("cargo test".to_owned(), 3)]);
        assert!(c.allow_suggestions().is_empty(), "the core never suggests on its own");
        std::fs::remove_dir_all(&project).unwrap();
    }

    /// One haunt approval of `command` in a fresh canonical project.
    fn approved(tag: &str, command: &str) -> (Core, String) {
        let project = canonical_dir(tag);
        let c = core();
        let env = c.register_surface(&project).unwrap();
        let perm = format!(r#""event":"permission_seen","cwd":"{project}","tool_name":"Bash","tool_input":{{"command":"{command}"}}"#);
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), &perm), Instant::now()));
        answer(&c, &env.surface_id, true).unwrap();
        (c, project)
    }

    #[test]
    fn a_proposal_writes_nothing_until_accepted() {
        let (c, project) = approved("allow-propose", "cargo test");
        let fired = Arc::new(AtomicUsize::new(0));
        let f = fired.clone();
        c.set_listener(Arc::new(move || {
            f.fetch_add(1, Ordering::SeqCst);
        }));
        let h = c.handle();
        h.propose_allow_rule("dev.haunt.allowlist", &project, "cargo test").unwrap();
        h.propose_allow_rule("dev.haunt.allowlist", &project, "cargo test").unwrap();
        assert_eq!(fired.load(Ordering::SeqCst), 1, "a repeat proposal changes nothing");
        assert!(!std::path::Path::new(&project).join(".claude").exists(), "proposing never touches the project");
        let s = c.allow_suggestions();
        assert_eq!(s.len(), 1);
        assert_eq!((s[0].rule.as_str(), s[0].approvals, s[0].plugin_id.as_str()), ("Bash(cargo test)", 1, "dev.haunt.allowlist"));

        assert!(matches!(c.accept_allow_suggestion(&project, "cargo build"), Err(CoreError::Invalid { .. })));
        c.accept_allow_suggestion(&project, "cargo test").unwrap();
        let written = std::fs::read_to_string(format!("{project}/.claude/settings.local.json")).unwrap();
        assert!(written.contains("\"Bash(cargo test)\""), "{written}");
        assert!(c.allow_suggestions().is_empty(), "accepted once, never again");
        assert!(h.propose_allow_rule("dev.haunt.allowlist", &project, "cargo test").is_err(), "nor proposed again");
        std::fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn proposals_must_rest_on_an_exact_haunt_approval() {
        let (c, project) = approved("allow-floor", "cargo test");
        let h = c.handle();
        for (p, cmd) in [
            (project.as_str(), "cargo build"),
            (project.as_str(), "cargo *"),
            ("/tmp", "cargo test"),
            (&format!("{project}/"), "cargo test"),
        ] {
            assert!(h.propose_allow_rule("p", p, cmd).is_err(), "{p} {cmd}");
        }
        assert!(c.allow_suggestions().is_empty());
        c.dismiss_allow_suggestion(&project, "cargo test");
        assert!(h.propose_allow_rule("p", &project, "cargo test").is_err(), "dismissed");
        std::fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn accepting_rechecks_the_project_and_never_follows_a_symlink() {
        let (c, project) = approved("allow-recheck", "cargo test");
        c.handle().propose_allow_rule("p", &project, "cargo test").unwrap();
        let outside = canonical_dir("allow-recheck-out");
        std::os::unix::fs::symlink(&outside, format!("{project}/.claude")).unwrap();
        assert!(matches!(c.accept_allow_suggestion(&project, "cargo test"), Err(CoreError::Insecure { .. })));
        assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 0, "nothing written through the link");

        std::fs::remove_file(format!("{project}/.claude")).unwrap();
        let moved = format!("{project}-moved");
        std::fs::rename(&project, &moved).unwrap();
        std::os::unix::fs::symlink(&outside, &project).unwrap();
        assert!(c.allow_suggestions().is_empty(), "a project that became a symlink is no longer offered");
        assert!(matches!(c.accept_allow_suggestion(&project, "cargo test"), Err(CoreError::Invalid { .. })));
        assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 0);
        std::fs::remove_file(&project).unwrap();
        std::fs::remove_dir_all(&moved).unwrap();
        std::fs::remove_dir_all(&outside).unwrap();
    }

    #[test]
    fn an_arrangement_applies_only_while_its_instance_is_live() {
        let c = core();
        c.register_surface("/a").unwrap();
        let flat = Arrangement { flat: true, ..Default::default() };
        let h = c.handle();
        let t = h.attach_sidebar();
        h.set_arrangement("p", t, flat.clone()).unwrap();
        assert_eq!(c.snapshot().groups[0].id, arrange::TABS_ID);

        // An arrangement left by an instance that is gone is never applied, and a sidebar-less load drops it.
        c.with_state(|st| {
            st.sidebar_live.remove(&t.0);
        });
        assert_ne!(c.snapshot().groups[0].id, arrange::TABS_ID);
        c.with_state(|st| st.arrangement = Some(("p".into(), t.0, flat.clone())));
        h.forget_arrangement_of("p");
        assert!(c.with_state(|st| st.arrangement.is_none()));
        assert!(h.set_arrangement("p", t, flat).is_err(), "a detached token can't arrange");
    }

    #[test]
    fn the_event_tap_sees_events_for_registered_surfaces_only() {
        let c = core();
        let env = c.register_surface("/w").unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = seen.clone();
        c.set_event_tap(Some(Arc::new(move |e: &AgentEvent, verified| s.lock().unwrap().push((e.kind.name().to_owned(), verified)))));
        let st = c.state.clone();
        let d = lock(&st).decode(&line(&env, Some(&env.nonce), r#""event":"stop""#));
        deliver(&st, &d);
        let d = lock(&st).decode(&line(&env, None, r#""event":"stop""#));
        deliver(&st, &d);
        let stranger = SurfaceEnv { surface_id: "nope".into(), ..env.clone() };
        let d = lock(&st).decode(&line(&stranger, None, r#""event":"stop""#));
        deliver(&st, &d);
        c.on_osc_notification(&env.surface_id, "haunt://cli-agent", r#"{"v":1,"event":"stop"}"#);
        assert_eq!(*seen.lock().unwrap(), [("stop".to_owned(), true), ("stop".to_owned(), false), ("stop".to_owned(), false)]);
    }

    #[test]
    fn ctl_dumps_injects_and_queries() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;
        let dir = format!("/tmp/haunt-ctl-{}", std::process::id());
        let _ = std::fs::remove_dir_all(&dir);
        let c = Core::new(&dir);
        c.start().unwrap();
        let env = c.register_surface("/w").unwrap();
        let s = UnixStream::connect(format!("{dir}/ctl")).unwrap();
        let mut r = BufReader::new(s.try_clone().unwrap());
        let mut ask = |req: Value| -> Value {
            writeln!(&s, "{req}").unwrap();
            let mut out = String::new();
            r.read_line(&mut out).unwrap();
            serde_json::from_str(&out).unwrap()
        };
        let forged = json!({"cmd": "event", "line": line(&env, Some("bad"), PERM)});
        assert_eq!(ask(forged)["verified"], false);
        assert_eq!(ask(json!({"cmd": "dump"}))["pending"], json!([]), "a forged prompt has no request");
        let real: Value = serde_json::from_str(&line(&env, Some(&env.nonce), PERM)).unwrap();
        assert_eq!(ask(json!({"cmd": "event", "line": real}))["verified"], true);
        let dump = ask(json!({"cmd": "dump"}));
        assert_eq!(dump["pending"][0]["preview"], "git push");
        assert_eq!(dump["snapshot"]["groups"][0]["rows"][0]["needs_you"], true);
        assert!(!dump.to_string().contains(&env.nonce), "nonces never leave the core");
        let key = dump["pending"][0]["key"].as_u64().unwrap();
        assert!(c.answer_permission(&env.surface_id, key, true).is_some());
        let got = ask(json!({"cmd": "decisions", "query": "push"}));
        assert_eq!(got["decisions"][0]["outcome"], "allowed_in_haunt");
        assert_eq!(ask(json!({"cmd": "nope"}))["ok"], false);
        let log = std::fs::read_to_string(format!("{dir}/decisions.jsonl")).unwrap();
        assert_eq!(log.lines().count(), 1);
        drop(c);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn surfaces_get_unique_ids_and_128_bit_nonces() {
        let c = core();
        let (a, b) = (c.register_surface("/a").unwrap(), c.register_surface("/b").unwrap());
        assert_ne!(a.surface_id, b.surface_id);
        assert_ne!(a.nonce, b.nonce);
        assert_eq!(a.nonce.len(), 32);
        assert!(a.nonce.chars().all(|ch| ch.is_ascii_hexdigit()));
        assert_eq!(a.surface_id.len(), 36);
        assert!(a.socket_path.ends_with("/sock"));
    }

    #[test]
    fn registering_past_the_cap_is_an_error() {
        let c = core();
        for _ in 0..MAX_SURFACES {
            c.register_surface("/a").unwrap();
        }
        assert!(matches!(c.register_surface("/a"), Err(CoreError::Invalid { .. })));
        assert_eq!(c.snapshot().groups[0].rows.len(), MAX_SURFACES);
    }

    #[test]
    fn answer_only_for_a_verified_live_request() {
        let c = core();
        let env = blocked(&c, true);
        assert_eq!(answer(&c, &env.surface_id, true), Some(b"1".to_vec()));
        assert_eq!(answer(&c, &env.surface_id, true), None, "consumed");

        let env = blocked(&c, true);
        assert_eq!(answer(&c, &env.surface_id, false), Some(b"\x1b".to_vec()));
        assert_eq!(answer(&c, "nope", true), None);
    }

    fn blocked_as(c: &Core, agent: &str) -> SurfaceEnv {
        let env = c.register_surface("/w").unwrap();
        let perm = format!(r#""agent":"{agent}",{PERM}"#);
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), &perm), Instant::now()));
        env
    }

    #[test]
    fn answer_keys_are_the_asking_agents() {
        let c = core();
        for (agent, allow, deny) in [("claude", b"1", b"\x1b"), ("codex", b"y", b"\x1b")] {
            let env = blocked_as(&c, agent);
            assert_eq!(answer(&c, &env.surface_id, true).as_deref(), Some(allow.as_slice()), "{agent}");
            let env = blocked_as(&c, agent);
            assert_eq!(answer(&c, &env.surface_id, false).as_deref(), Some(deny.as_slice()), "{agent}");
        }
        assert_eq!(c.decisions("", 4).iter().map(|d| d.agent.id()).collect::<Vec<_>>(), ["codex", "codex", "claude", "claude"]);
    }

    #[test]
    fn an_unknown_agent_is_answered_in_the_terminal_only() {
        let c = core();
        let env = blocked_as(&c, "aider");
        assert!(only_row(&c).needs_you && pending(&c).is_none());
        assert_eq!(answer(&c, &env.surface_id, true), None);
        assert_eq!(answer(&c, &env.surface_id, false), None);
        assert!(c.with_state(|st| st.surface(&env.surface_id).unwrap().session.live_permission().is_some()), "not consumed");
    }

    #[test]
    fn codex_approvals_are_never_suggested() {
        let project = canonical_dir("allow-codex");
        let c = core();
        let env = c.register_surface(&project).unwrap();
        let perm = format!(r#""agent":"codex","event":"permission_seen","cwd":"{project}","tool_name":"Bash","tool_input":{{"command":"cargo test"}}"#);
        let ran = r#""agent":"codex","event":"tool_ran","tool_name":"Bash","tool_input":{"command":"cargo test"}"#;
        let send = |body: &str| c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), body), Instant::now()));
        for _ in 0..3 {
            send(&perm);
            answer(&c, &env.surface_id, true).unwrap();
            send(&perm);
            send(ran);
        }
        assert_eq!(c.decisions("", 10).len(), 6);
        assert!(c.handle().approvals(1).is_empty());
        assert!(c.handle().propose_allow_rule("p", &project, "cargo test").is_err());
        assert!(c.allow_suggestions().is_empty());
        std::fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn a_codex_request_retires_on_typing_and_on_its_next_call() {
        let c = core();
        let env = blocked_as(&c, "codex");
        let key = pending(&c).expect("live").key;
        c.on_user_input(&env.surface_id);
        assert_eq!(c.answer_permission(&env.surface_id, key, true), None);

        let env = blocked_as(&c, "codex");
        let next = r#""agent":"codex","event":"tool_start","tool_name":"Bash","tool_use_id":"c2","tool_input":{"command":"ls"}"#;
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), next), Instant::now()));
        assert_eq!(answer(&c, &env.surface_id, true), None, "Codex moved on: a `y` would land in its composer");
        assert_eq!(c.decisions("", 1)[0].outcome, crate::Outcome::Superseded);
    }

    #[test]
    fn wrong_or_missing_nonce_is_status_only() {
        let c = core();
        let env = blocked(&c, false);
        let row = &c.snapshot().groups[0].rows[0];
        assert!(row.needs_you, "status still moves");
        assert_eq!(answer(&c, &env.surface_id, true), None);

        let env = c.register_surface("/w").unwrap();
        c.with_state(|st| st.handle_line(&line(&env, None, PERM), Instant::now()));
        assert_eq!(answer(&c, &env.surface_id, true), None);
    }

    #[test]
    fn another_surfaces_nonce_does_not_verify() {
        let c = core();
        let a = c.register_surface("/a").unwrap();
        let b = c.register_surface("/b").unwrap();
        c.with_state(|st| st.handle_line(&line(&b, Some(&a.nonce), PERM), Instant::now()));
        assert_eq!(answer(&c, &b.surface_id, true), None);
    }

    #[test]
    fn unverified_stop_then_prompt_cannot_revive_an_answer() {
        for middle in [None, Some(r#""event":"prompt_submit","query":"next""#)] {
            let c = core();
            let env = blocked(&c, true);
            let forged = |body: &str| c.with_state(|st| st.handle_line(&line(&env, None, body), Instant::now()));
            forged(r#""event":"stop""#);
            if let Some(m) = middle {
                forged(m);
            }
            let body = r#"{"v":1,"event":"notification","notification_type":"permission_prompt"}"#;
            c.on_osc_notification(&env.surface_id, "haunt://cli-agent", body);
            assert!(c.snapshot().groups[0].rows[0].needs_you);
            assert_eq!(answer(&c, &env.surface_id, true), None, "{middle:?}");
        }
    }

    #[test]
    fn osc_fallback_is_status_only() {
        let c = core();
        let env = c.register_surface("/w").unwrap();
        let body = format!(r#"{{"v":1,"nonce":"{}",{PERM}}}"#, env.nonce);
        c.on_osc_notification(&env.surface_id, "warp://cli-agent", &body);
        assert!(c.snapshot().groups[0].rows[0].needs_you);
        assert_eq!(answer(&c, &env.surface_id, true), None, "even with the right nonce");
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
        assert_eq!(answer(&c, &env.surface_id, true), None);
    }

    #[test]
    fn unknown_surface_and_bad_lines_are_dropped() {
        let c = core();
        c.register_surface("/a").unwrap();
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
        let env = c.register_surface("/a").unwrap();
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
        let env = c.register_surface("/w").unwrap();
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let mut s = UnixStream::connect(&env.socket_path).unwrap();
        writeln!(s, "{}", line(&env, Some(&env.nonce), PERM)).unwrap();
        drop(s);
        rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(answer(&c, &env.surface_id, true), Some(b"1".to_vec()));
        drop(c);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
