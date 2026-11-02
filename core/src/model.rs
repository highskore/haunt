//! `Core`: surfaces, their agent sessions, the socket intake and the sidebar snapshot.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use serde_json::{Value, json};

use crate::allowlist::{self, AllowError, AllowSuggestion, Approval};
use crate::arrange::{self, Arrangement, RowInfo};
use crate::ctl::{self, Ctl};
use crate::decisions::{Decision, DecisionLog};
use crate::git::Branches;
use crate::event::{AgentEvent, parse_osc};
use crate::ids::{hex, random, uuid_v4};
use crate::intake::{Delivery, Intake, IntakeError, Limits, Nonces, SOCKET_NAME};
use crate::layout::{self, SidebarSnapshot, SurfaceView};
use crate::session::{Outcome, Session};
use crate::sync::{lock, write};
use crate::turn::{ReviewTurn, TurnLog};

const MAX_SURFACES: usize = 512;
const MAX_PROPOSALS: usize = 256;
/// Hand-offs queued per worker; past this a stalled worker's jobs are dropped, never waited on.
const OFFLOAD_QUEUE: usize = 1024;

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
/// Returns whether host requests are waiting, so the UI is told to drain them.
pub type EventTap = Arc<dyn Fn(&AgentEvent, bool) -> bool + Send + Sync>;

struct Surface {
    id: String,
    cwd: String,
    /// Branch at `cwd`.
    branch: Option<String>,
    /// Branch at `session.cwd`.
    agent_branch: Option<String>,
    session: Session,
    /// The latest turn, from verified events, for the review screen.
    turn: TurnLog,
}

#[derive(Default)]
pub(crate) struct State {
    surfaces: Vec<Surface>,
    /// Surface id to nonce, shared with the intake: the one place a nonce is kept.
    nonces: Nonces,
    selected: Option<String>,
    home: Option<String>,
    /// Basename of the login shell surfaces run, for shell rows.
    shell: Option<String>,
    listener: Option<Listener>,
    /// The listener fired and no snapshot was taken since: further changes don't fire it again.
    notified: bool,
    version: u64,
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

    /// Runs `f` on one surface, then moves the requests it ended into the decision log. Only
    /// verified requests ever exist, so unverified events can at most end one, never add one.
    fn with_surface<R>(&mut self, id: &str, f: impl FnOnce(&mut Surface) -> R) -> Option<R> {
        let s = self.surfaces.iter_mut().find(|s| s.id == id)?;
        let r = f(s);
        for (p, outcome) in s.session.take_ended() {
            self.decisions.record(Decision::new(&s.id, &p, outcome));
        }
        Some(r)
    }

    /// One intake delivery; the intake already checked the nonce and the rate limit.
    fn deliver(&mut self, d: &Delivery, now: Instant) -> bool {
        let Some(event) = &d.event else { return false };
        self.with_surface(&d.surface_id, |s| {
            let changed = s.session.apply(event, d.verified, now);
            if d.verified {
                s.turn.apply(event, &s.session.agent);
            }
            changed
        }) == Some(true)
    }

    /// None once the surface is gone.
    fn set_agent_branch(&mut self, surface_id: &str, branch: Option<String>) -> Option<bool> {
        let s = self.surface(surface_id)?;
        let changed = s.agent_branch != branch;
        s.agent_branch = branch;
        Some(changed)
    }

    /// The turn number a verified prompt just started, for reading its start commit off the lock.
    fn started_turn(&mut self, d: &Delivery) -> Option<u32> {
        if !starts_turn(d) {
            return None;
        }
        self.surface(&d.surface_id).map(|s| s.turn.turn.number)
    }

    /// Records where turn `number` started, unless a newer turn began meanwhile.
    fn set_turn_head(&mut self, surface_id: &str, number: u32, head: Option<String>) {
        if let Some(s) = self.surface(surface_id).filter(|s| s.turn.turn.number == number) {
            s.turn.turn.head_at_start = head;
        }
    }

    /// A socket line as the intake would deliver it, minus the socket and the rate limit.
    #[cfg(test)]
    pub(crate) fn handle_line(&mut self, line: &str, now: Instant) -> bool {
        let Some(d) = crate::intake::decode(line, &self.nonces) else { return false };
        let cwd = d.event.as_ref().and_then(|e| e.cwd.clone()).filter(|c| c.starts_with('/'));
        let known = self.surfaces.iter().find(|s| s.id == d.surface_id).and_then(|s| s.session.cwd.clone());
        let shell = self.surfaces.iter().find(|s| s.id == d.surface_id).map(|s| s.cwd.clone());
        let at = d.verified.then(|| cwd.or(known)).flatten();
        let branch = at.as_deref().map(crate::git::branch);
        let mut changed = self.deliver(&d, now);
        if let Some(b) = branch {
            changed |= self.set_agent_branch(&d.surface_id, b) == Some(true);
        }
        if let Some(n) = self.started_turn(&d) {
            let head = at.or(shell).and_then(|c| crate::git::head_commit(&c));
            self.set_turn_head(&d.surface_id, n, head);
        }
        changed
    }

    fn apply_unverified(&mut self, id: &str, event: &AgentEvent, now: Instant) -> bool {
        self.with_surface(id, |s| s.session.apply(event, false, now)) == Some(true)
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
        SidebarSnapshot { version: self.version, ..layout::snapshot(&views, self.home.as_deref(), self.shell.as_deref(), now) }
    }

    /// The snapshot the UI draws, which re-arms the listener.
    fn take_snapshot(&mut self, now: Instant) -> SidebarSnapshot {
        self.notified = false;
        self.snapshot(now)
    }
}

struct Servers {
    intake: Intake,
    _ctl: Ctl,
}

/// `$HAUNT_HOME`, else `~/.haunt`.
pub fn default_home() -> PathBuf {
    if let Some(h) = std::env::var_os("HAUNT_HOME") {
        return PathBuf::from(h);
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".haunt")
}

/// Thread-safe; the listener fires on whichever thread caused the change, never under the lock.
pub struct Core {
    dir: PathBuf,
    state: Arc<Mutex<State>>,
    branches: Arc<Branches>,
    servers: Mutex<Option<Servers>>,
}

/// A verified prompt: the review diffs from the commit HEAD is on now.
fn starts_turn(d: &Delivery) -> bool {
    d.verified && d.event.as_ref().is_some_and(|e| matches!(e.kind, crate::event::EventKind::PromptSubmit { .. }))
}

/// The two slow steps of a delivery, each on its own thread so neither holds up the socket or the
/// other: the branch lookup reads files a hook-chosen cwd points at (a dead mount can hang it), and
/// plugins run code and call back into the core.
#[derive(Clone)]
struct Offload {
    /// Surface, event cwd, and the turn number when the event started a turn (its start commit is read too).
    branch: SyncSender<(String, Option<String>, Option<u32>)>,
    tap: SyncSender<(EventTap, AgentEvent, bool)>,
}

impl Offload {
    fn spawn(state: Arc<Mutex<State>>, branches: Arc<Branches>) -> std::io::Result<Self> {
        let tap_state = state.clone();
        let branch = worker("haunt-branch", move |(surface, cwd, turn): (String, Option<String>, Option<u32>)| {
            let b = branches.agent(&surface, cwd.as_deref());
            let head = turn.map(|n| (n, branches.turn_cwd(&surface).and_then(|c| crate::git::head_commit(&c))));
            if b.is_none() && head.is_none() {
                return;
            }
            let mut gone = false;
            update_state(&state, |st, _| {
                if let Some((n, h)) = head {
                    st.set_turn_head(&surface, n, h);
                }
                let Some(b) = b else { return false };
                let changed = st.set_agent_branch(&surface, b);
                gone = changed.is_none();
                changed == Some(true)
            });
            // Unregistered meanwhile: drop the cache entry the lookup made.
            if gone {
                branches.forget(&surface);
            }
        })?;
        let tap = worker("haunt-tap", move |(tap, event, verified): (EventTap, AgentEvent, bool)| {
            if tap(&event, verified) {
                requests_queued(&tap_state);
            }
        })?;
        Ok(Self { branch, tap })
    }
}

/// Plugin requests are waiting. The listener fired for the delivery came before the tap ran, or
/// never fired (nothing changed, or it is waiting for a snapshot), and a waiting request may be all
/// that unblocks the agent, so this fires it whatever `notified` says.
fn requests_queued(state: &Mutex<State>) {
    let listener = lock(state).listener.clone();
    if let Some(l) = listener {
        l();
    }
}

/// A thread running `f` on each job sent, until every sender is gone.
fn worker<T: Send + 'static>(name: &str, mut f: impl FnMut(T) + Send + 'static) -> std::io::Result<SyncSender<T>> {
    let (tx, rx) = mpsc::sync_channel(OFFLOAD_QUEUE);
    std::thread::Builder::new().name(name.into()).spawn(move || rx.into_iter().for_each(&mut f))?;
    Ok(tx)
}

/// One intake delivery: the state now, the branch lookup and the plugins after, off this thread.
fn deliver(state: &Mutex<State>, offload: &Offload, d: Delivery) -> bool {
    let mut tap = None;
    let mut turn = None;
    let changed = update_state(state, |st, now| {
        tap = st.tap_for(&d.surface_id);
        let changed = st.deliver(&d, now);
        turn = st.started_turn(&d);
        changed
    });
    if let Some(event) = d.event {
        if d.verified {
            let _ = offload.branch.try_send((d.surface_id, event.cwd.clone(), turn));
        }
        if let Some(tap) = tap {
            let _ = offload.tap.try_send((tap, event, d.verified));
        }
    }
    changed
}

/// Runs `f` on the state and, if it reports a change, fires the listener outside the lock, once
/// until the next `Core::snapshot`.
fn update_state(state: &Mutex<State>, f: impl FnOnce(&mut State, Instant) -> bool) -> bool {
    let mut st = lock(state);
    let changed = f(&mut st, Instant::now());
    st.version += changed as u64;
    let fire = changed && !std::mem::replace(&mut st.notified, true);
    let listener = if fire { st.listener.clone() } else { None };
    let log = st.decisions.writer().clone();
    drop(st);
    log.flush();
    if let Some(l) = listener {
        l();
    }
    changed
}

const DEFAULT_LIMIT: u64 = 50;
const MAX_LIMIT: u64 = 1000;

/// One ctl request: `dump`, `event` (a hook line, nonce still required) or `decisions`.
fn ctl_request(state: &Mutex<State>, offload: &Offload, line: &str) -> String {
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
            let write_errors = lock(state).decisions.writer().errors();
            json!({ "ok": true, "snapshot": snapshot, "pending": pending, "decision_log_write_errors": write_errors }).to_string()
        }
        Some("event") => {
            let hook_line = match req.get("line") {
                Some(Value::String(s)) => s.clone(),
                Some(v @ Value::Object(_)) => v.to_string(),
                _ => return ctl::error("event needs a line"),
            };
            let nonces = lock(state).nonces.clone();
            let d = crate::intake::decode(&hook_line, &nonces);
            let verified = d.as_ref().is_some_and(|d| d.verified);
            let changed = d.is_some_and(|d| deliver(state, offload, d));
            json!({ "ok": true, "verified": verified, "changed": changed }).to_string()
        }
        Some("decisions") => {
            let query = req.get("query").and_then(Value::as_str).unwrap_or("");
            let limit = req.get("limit").and_then(Value::as_u64).unwrap_or(DEFAULT_LIMIT).min(MAX_LIMIT) as usize;
            let surface = req.get("surface").and_then(Value::as_str);
            let hits = lock(state).decisions.query(query, surface, limit);
            json!({ "ok": true, "decisions": hits.iter().map(|d| &**d).collect::<Vec<_>>() }).to_string()
        }
        _ => ctl::error("unknown cmd"),
    }
}

impl Core {
    pub fn new(config_dir: impl Into<PathBuf>) -> Self {
        let shell = std::env::var("SHELL").ok().and_then(|s| s.rsplit('/').next().map(str::to_owned)).filter(|s| !s.is_empty());
        // Version 0 is older than any snapshot, so `snapshot_if_newer(0)` always returns one.
        let state = State { home: std::env::var("HOME").ok(), shell, version: 1, ..State::default() };
        Self { dir: config_dir.into(), state: Arc::new(Mutex::new(state)), branches: Arc::default(), servers: Mutex::new(None) }
    }

    pub fn socket_path(&self) -> PathBuf {
        self.dir.join(SOCKET_NAME)
    }

    /// Binds the hook socket and the ctl socket, opens the decision log, and registers every
    /// surface's nonce with the intake; a second call is a no-op.
    pub fn start(&self) -> Result<(), CoreError> {
        let mut servers = lock(&self.servers);
        if servers.is_some() {
            return Ok(());
        }
        let offload = Offload::spawn(self.state.clone(), self.branches.clone()).map_err(|e| CoreError::Io { reason: e.to_string() })?;
        let (state, o) = (self.state.clone(), offload.clone());
        let sink = Arc::new(move |d: Delivery| {
            deliver(&state, &o, d);
        });
        // Binding the intake first secures the dir the log and ctl live in.
        let nonces = lock(&self.state).nonces.clone();
        let intake = Intake::bind(&self.dir, Limits::default(), nonces, sink).map_err(CoreError::from)?;
        lock(&self.state).decisions.open(&self.dir).map_err(|e| {
            let reason = format!("decision log: {e}");
            match e.raw_os_error() {
                Some(libc::ELOOP) | None => CoreError::Insecure { reason },
                Some(_) => CoreError::Io { reason },
            }
        })?;
        let state = self.state.clone();
        let ctl = Ctl::bind(&self.dir, Arc::new(move |line: &str| ctl_request(&state, &offload, line))).map_err(CoreError::from)?;
        *servers = Some(Servers { intake, _ctl: ctl });
        Ok(())
    }

    fn with_intake(&self, f: impl FnOnce(&Intake)) {
        if let Some(s) = lock(&self.servers).as_ref() {
            f(&s.intake);
        }
    }

    fn update(&self, f: impl FnOnce(&mut State, Instant) -> bool) -> bool {
        update_state(&self.state, f)
    }

    /// `Invalid` once `MAX_SURFACES` are registered: an env the core doesn't know would never verify.
    pub fn register_surface(&self, cwd: &str) -> Result<SurfaceEnv, CoreError> {
        let env = SurfaceEnv {
            surface_id: uuid_v4(),
            nonce: hex(&random::<16>()),
            socket_path: self.socket_path().to_string_lossy().into_owned(),
        };
        let added = self.update(|st, now| {
            if st.surfaces.len() >= MAX_SURFACES {
                return false;
            }
            let (id, cwd) = (env.surface_id.clone(), cwd.to_owned());
            st.surfaces.push(Surface { id, cwd, branch: None, agent_branch: None, session: Session::new(now), turn: TurnLog::default() });
            write(&st.nonces).insert(env.surface_id.clone(), env.nonce.clone());
            true
        });
        if !added {
            return Err(CoreError::Invalid { reason: format!("at most {MAX_SURFACES} surfaces") });
        }
        Ok(env)
    }

    pub fn unregister_surface(&self, surface_id: &str) {
        self.with_intake(|i| i.forget_surface(surface_id));
        self.branches.forget(surface_id);
        self.update(|st, _| {
            write(&st.nonces).remove(surface_id);
            let before = st.surfaces.len();
            st.with_surface(surface_id, |s| s.session.close());
            st.surfaces.retain(|s| s.id != surface_id);
            if st.selected.as_deref() == Some(surface_id) {
                st.selected = None;
            }
            st.surfaces.len() != before
        });
    }

    /// `_title` and `_git_branch` are ignored, kept so the app's call needs no change: rows are named
    /// after the cwd, and the core reads the branch at `cwd` itself, outside every lock.
    pub fn set_surface_info(&self, surface_id: &str, _title: &str, cwd: &str, _git_branch: Option<String>) {
        if !lock(&self.state).surfaces.iter().any(|s| s.id == surface_id) {
            return;
        }
        let branch = self.branches.shell(surface_id, cwd);
        let mut gone = false;
        self.update(|st, _| {
            let Some(s) = st.surface(surface_id) else {
                gone = true;
                return false;
            };
            let changed = s.cwd != cwd || s.branch != branch;
            cwd.clone_into(&mut s.cwd);
            s.branch = branch;
            changed
        });
        // Unregistered meanwhile: drop the cache entry the lookup made.
        if gone {
            self.branches.forget(surface_id);
        }
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
        if tap.is_some_and(|tap| tap(&event, false)) {
            requests_queued(&self.state);
        }
    }

    pub fn snapshot(&self) -> SidebarSnapshot {
        lock(&self.state).take_snapshot(Instant::now())
    }

    /// None while nothing changed since the snapshot with `version`. Elapsed times still move on
    /// their own, so a `next_tick_ms` redraw takes a full `snapshot`.
    pub fn snapshot_if_newer(&self, version: u64) -> Option<SidebarSnapshot> {
        let mut st = lock(&self.state);
        (st.version != version).then(|| st.take_snapshot(Instant::now()))
    }

    /// The listener fires once per change burst: after it fires, it waits for the next `snapshot`.
    pub fn set_listener(&self, listener: Listener) {
        let mut st = lock(&self.state);
        st.listener = Some(listener);
        st.notified = false;
    }

    /// Whether a verified permission prompt may be on the surface's screen (see
    /// `Session::has_unresolved`); false for an unknown surface. Unlike a row's `needs_you`, no
    /// unverified event can clear it.
    pub fn has_unresolved(&self, surface_id: &str) -> bool {
        lock(&self.state).surfaces.iter().any(|s| s.id == surface_id && s.session.has_unresolved())
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
            bytes = st
                .with_surface(surface_id, |s| {
                    let b = s.session.live_permission()?.agent.answer_bytes(allow)?;
                    s.session.answer_as(request_key, outcome, now).then_some(b)
                })
                .flatten();
            bytes.is_some()
        });
        bytes.map(<[u8]>::to_vec)
    }

    /// A key went to the surface's pty: from now on the terminal answers its pending request.
    pub fn on_user_input(&self, surface_id: &str) {
        self.update(|st, _| st.surface(surface_id).is_some_and(|s| s.session.user_input()));
    }

    /// The surface's latest turn for the review screen; None for an unknown surface or one that never
    /// had a verified agent event.
    pub fn review_turn(&self, surface_id: &str) -> Option<ReviewTurn> {
        let mut st = lock(&self.state);
        let s = st.surface(surface_id)?;
        if !s.session.is_agent || s.turn.turn.number == 0 && s.turn.turn.cwd.is_none() {
            return None;
        }
        let mut t = s.turn.turn.clone();
        t.cwd = t.cwd.or_else(|| s.session.cwd.clone());
        Some(t)
    }

    /// Ended permission requests, newest first; see `DecisionLog::query`.
    pub fn decisions(&self, query: &str, limit: u32) -> Vec<Decision> {
        self.decisions_in(query, None, limit)
    }

    /// `decisions` of one surface when `surface_id` is set, filtered before the limit.
    pub fn decisions_in(&self, query: &str, surface_id: Option<&str>, limit: u32) -> Vec<Decision> {
        let hits = lock(&self.state).decisions.query(query, surface_id, limit as usize);
        hits.iter().map(|d| Decision::clone(d)).collect()
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
        let hits = lock(&self.state).decisions.query(query, None, limit as usize);
        hits.iter().map(|d| Decision::clone(d)).collect()
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
    use crate::testdir::TempDir;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
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
        let repo = TempDir::new("model-cwd");
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

        let body = r#""event":"stop","cwd":"/Users/me/code/vibes/specs""#;
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), body), Instant::now()));
        let row = only_row(&c);
        assert_eq!(row.name, "specs");
        assert!(row.meta.starts_with("~/code/vibes/specs · Done in"), "no branch falls back to the cwd: {}", row.meta);
    }

    #[test]
    fn a_stale_request_key_writes_nothing() {
        let c = core();
        let env = c.register_surface("/Users/me/code/orchestrator").unwrap();
        for body in [r#""event":"prompt_submit","query":"release""#, r#""event":"tool_start","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git push"}"#, PERM] {
            c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), body), Instant::now()));
        }
        let old = pending(&c).expect("a live request");
        assert_eq!(old.preview, "git push");
        let changed = r#""event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#;
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), changed), Instant::now()));
        assert_eq!(c.answer_permission(&env.surface_id, old.key, true), None);
        let new = pending(&c).expect("the new request is still live");
        assert_eq!(new.preview, "rm -rf build");
        assert!(new.suspicious, "the git push prompt may still be on screen ahead of it");
        assert_eq!(c.answer_permission(&env.surface_id, new.key, false), None);
        let ran = r#""event":"tool_ran","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git push"}"#;
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), ran), Instant::now()));
        let new = pending(&c).expect("the new request is still live");
        assert!(!new.suspicious, "the only one left");
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

    /// A created, canonical project dir, as a string, and the guard that removes it.
    fn canonical_dir(tag: &str) -> (TempDir, String) {
        let d = TempDir::created(tag);
        let s = d.to_str().unwrap().to_owned();
        (d, s)
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
        let (_project, project) = canonical_dir("allow-raw");
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
        let (_project, project) = canonical_dir("allow");
        let c = core();
        let env = c.register_surface(&project).unwrap();
        let perm = format!(r#""event":"permission_seen","cwd":"{project}","tool_name":"Bash","tool_input":{{"command":"cargo test"}}"#);
        let ran = r#""event":"tool_ran","tool_name":"Bash","tool_input":{"command":"cargo test"}"#;
        let start = r#""event":"tool_start","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"cargo test"}"#;
        let ran_t1 = r#""event":"tool_ran","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"cargo test"}"#;
        let send = |nonce: Option<&str>, body: &str| c.with_state(|st| st.handle_line(&line(&env, nonce, body), Instant::now()));
        for _ in 0..3 {
            send(None, &perm);
            send(None, ran);
        }
        assert!(c.handle().approvals(1).is_empty(), "unverified approvals never count");
        send(Some(&env.nonce), start);
        send(Some(&env.nonce), &perm);
        answer(&c, &env.surface_id, true).unwrap();
        send(Some(&env.nonce), ran_t1);
        for _ in 0..3 {
            send(Some(&env.nonce), start);
            send(Some(&env.nonce), &perm);
            send(Some(&env.nonce), ran_t1);
        }
        let counts = |min| c.handle().approvals(min).into_iter().map(|a| (a.command, a.count)).collect::<Vec<_>>();
        assert_eq!(counts(1), [("cargo test".to_owned(), 1)], "answers in the terminal never count");
        for _ in 0..2 {
            send(Some(&env.nonce), start);
            send(Some(&env.nonce), &perm);
            answer(&c, &env.surface_id, true).unwrap();
            send(Some(&env.nonce), ran_t1);
        }
        assert_eq!(counts(3), [("cargo test".to_owned(), 3)]);
        assert!(c.allow_suggestions().is_empty(), "the core never suggests on its own");
    }

    /// One haunt approval of `command` in a fresh canonical project.
    fn approved(tag: &str, command: &str) -> (Core, TempDir, String) {
        let (dir, project) = canonical_dir(tag);
        let c = core();
        let env = c.register_surface(&project).unwrap();
        let perm = format!(r#""event":"permission_seen","cwd":"{project}","tool_name":"Bash","tool_input":{{"command":"{command}"}}"#);
        c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), &perm), Instant::now()));
        answer(&c, &env.surface_id, true).unwrap();
        (c, dir, project)
    }

    #[test]
    fn a_proposal_writes_nothing_until_accepted() {
        let (c, _project, project) = approved("allow-propose", "cargo test");
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
    }

    #[test]
    fn proposals_must_rest_on_an_exact_haunt_approval() {
        let (c, _project, project) = approved("allow-floor", "cargo test");
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
    }

    #[test]
    fn accepting_rechecks_the_project_and_never_follows_a_symlink() {
        let (c, _project, project) = approved("allow-recheck", "cargo test");
        c.handle().propose_allow_rule("p", &project, "cargo test").unwrap();
        let (_outside, outside) = canonical_dir("allow-recheck-out");
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
    fn a_stuck_plugin_never_holds_up_deliveries() {
        let c = core();
        let env = c.register_surface("/w").unwrap();
        let (release, wait) = std::sync::mpsc::channel::<()>();
        let wait = Mutex::new(wait);
        c.set_event_tap(Some(Arc::new(move |_: &AgentEvent, _| {
            let _ = wait.lock().unwrap().recv_timeout(Duration::from_secs(3));
            false
        })));
        let st = c.state.clone();
        let offload = Offload::spawn(st.clone(), c.branches.clone()).unwrap();
        let t = Instant::now();
        let nonces = lock(&st).nonces.clone();
        for body in [r#""event":"prompt_submit","query":"x""#, r#""event":"stop""#] {
            let d = crate::intake::decode(&line(&env, Some(&env.nonce), body), &nonces).unwrap();
            assert!(deliver(&st, &offload, d), "{body}");
        }
        assert!(t.elapsed() < Duration::from_secs(1));
        assert_eq!(c.with_state(|st| st.surface(&env.surface_id).unwrap().session.status), crate::session::Status::Done);
        drop(release);
    }

    #[test]
    fn waiting_plugin_requests_always_wake_the_ui() {
        let c = core();
        let env = c.register_surface("/w").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let tx = Mutex::new(tx);
        c.set_listener(Arc::new(move || {
            let _ = tx.lock().unwrap().send(());
        }));
        let queue = Arc::new(AtomicBool::new(false));
        let q = queue.clone();
        c.set_event_tap(Some(Arc::new(move |_: &AgentEvent, _| q.swap(false, Ordering::SeqCst))));
        let st = c.state.clone();
        let offload = Offload::spawn(st.clone(), c.branches.clone()).unwrap();
        let nonces = lock(&st).nonces.clone();
        let send = || {
            let d = crate::intake::decode(&line(&env, Some(&env.nonce), r#""event":"session_start""#), &nonces).unwrap();
            deliver(&st, &offload, d)
        };
        send();
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        // No snapshot from here on, so the listener stays spent for state changes.
        let osc = || c.on_osc_notification(&env.surface_id, "haunt://cli-agent", r#"{"v":1,"event":"session_start"}"#);

        queue.store(false, Ordering::SeqCst);
        assert!(!send(), "a repeated start changes nothing");
        osc();
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "no requests, no wake-up");

        queue.store(true, Ordering::SeqCst);
        send();
        rx.recv_timeout(Duration::from_secs(1)).expect("the tap's request wakes the UI");
        queue.store(true, Ordering::SeqCst);
        send();
        rx.recv_timeout(Duration::from_secs(1)).expect("every time, without a snapshot in between");
        queue.store(true, Ordering::SeqCst);
        osc();
        rx.recv_timeout(Duration::from_secs(1)).expect("so does one queued for an OSC event");
    }

    #[test]
    fn has_unresolved_outlives_forged_turn_ends() {
        let c = core();
        let env = c.register_surface("/w").unwrap();
        let send = |nonce: Option<&str>, body: &str| c.with_state(|st| st.handle_line(&line(&env, nonce, body), Instant::now()));
        assert!(!c.has_unresolved(&env.surface_id) && !c.has_unresolved("nope"));
        send(Some(&env.nonce), PERM);
        assert!(c.has_unresolved(&env.surface_id));
        send(None, r#""event":"stop""#);
        send(None, r#""event":"prompt_submit","query":"x""#);
        assert!(!only_row(&c).needs_you, "the row was cleared");
        assert!(c.has_unresolved(&env.surface_id), "the prompt may still be up");
        send(Some(&env.nonce), r#""event":"stop""#);
        assert!(c.has_unresolved(&env.surface_id), "a verified stop clears nothing either");
        c.unregister_surface(&env.surface_id);
        assert!(!c.has_unresolved(&env.surface_id));
    }

    #[test]
    fn the_event_tap_sees_events_for_registered_surfaces_only() {
        let c = core();
        let env = c.register_surface("/w").unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = seen.clone();
        c.set_event_tap(Some(Arc::new(move |e: &AgentEvent, verified| {
            s.lock().unwrap().push((e.kind.name().to_owned(), verified));
            false
        })));
        let st = c.state.clone();
        let offload = Offload::spawn(st.clone(), c.branches.clone()).unwrap();
        let nonces = lock(&st).nonces.clone();
        let stranger = SurfaceEnv { surface_id: "nope".into(), ..env.clone() };
        for (e, nonce) in [(&env, Some(env.nonce.as_str())), (&env, None), (&stranger, None)] {
            if let Some(d) = crate::intake::decode(&line(e, nonce, r#""event":"stop""#), &nonces) {
                deliver(&st, &offload, d);
            }
        }
        let t = Instant::now();
        while seen.lock().unwrap().len() < 2 && t.elapsed() < Duration::from_secs(2) {
            std::thread::yield_now();
        }
        c.on_osc_notification(&env.surface_id, "haunt://cli-agent", r#"{"v":1,"event":"stop"}"#);
        assert_eq!(*seen.lock().unwrap(), [("stop".to_owned(), true), ("stop".to_owned(), false), ("stop".to_owned(), false)]);
    }

    #[test]
    fn ctl_dumps_injects_and_queries() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;
        let (_dir, dir) = canonical_dir("ctl");
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
        assert_eq!(ask(json!({"cmd": "decisions", "surface": env.surface_id}))["decisions"].as_array().unwrap().len(), 1);
        assert_eq!(ask(json!({"cmd": "decisions", "surface": "other"}))["decisions"], json!([]));
        assert_eq!(ask(json!({"cmd": "dump"}))["decision_log_write_errors"], 0);
        assert_eq!(ask(json!({"cmd": "nope"}))["ok"], false);
        let log = std::fs::read_to_string(format!("{dir}/decisions.jsonl")).unwrap();
        assert_eq!(log.lines().count(), 1, "flushed once the lock is released");
        drop(c);
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
        let (_project, project) = canonical_dir("allow-codex");
        let c = core();
        let env = c.register_surface(&project).unwrap();
        let perm = format!(r#""agent":"codex","event":"permission_seen","cwd":"{project}","tool_name":"Bash","tool_input":{{"command":"cargo test"}}"#);
        let start = r#""agent":"codex","event":"tool_start","tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"cargo test"}"#;
        let ran_c1 = r#""agent":"codex","event":"tool_ran","tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"cargo test"}"#;
        let send = |body: &str| c.with_state(|st| st.handle_line(&line(&env, Some(&env.nonce), body), Instant::now()));
        for _ in 0..3 {
            send(start);
            send(&perm);
            answer(&c, &env.surface_id, true).unwrap();
            send(ran_c1);
            send(start);
            send(&perm);
            send(ran_c1);
        }
        assert_eq!(c.decisions("", 10).len(), 6);
        assert!(c.handle().approvals(1).is_empty());
        assert!(c.handle().propose_allow_rule("p", &project, "cargo test").is_err());
        assert!(c.allow_suggestions().is_empty());
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
    fn the_core_reads_the_shell_branch_itself() {
        let repo = TempDir::created("shell-branch");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::write(repo.join(".git/HEAD"), "ref: refs/heads/dev\n").unwrap();
        let c = core();
        let env = c.register_surface("/").unwrap();
        c.set_surface_info(&env.surface_id, "zsh", repo.to_str().unwrap(), Some("stale".into()));
        let s = c.with_state(|st| st.surface(&env.surface_id).map(|s| s.branch.clone()));
        assert_eq!(s, Some(Some("dev".into())));
    }

    #[test]
    fn listener_fires_on_changes_only() {
        let c = core();
        let n = Arc::new(AtomicUsize::new(0));
        let k = n.clone();
        c.set_listener(Arc::new(move || {
            k.fetch_add(1, Ordering::SeqCst);
        }));
        let fired = || n.load(Ordering::SeqCst);
        let env = c.register_surface("/a").unwrap();
        let v = c.snapshot().version;
        c.select_surface(&env.surface_id);
        c.select_surface(&env.surface_id);
        c.snapshot();
        c.set_surface_info(&env.surface_id, "zsh", "/a", None);
        assert_eq!((fired(), c.snapshot_if_newer(v + 1)), (2, None), "unchanged: no call, no snapshot");
        c.set_surface_info(&env.surface_id, "zsh", "/b", Some("ignored".into()));
        assert_eq!(fired(), 3);
        assert!(c.snapshot_if_newer(v + 1).unwrap().groups[0].rows[0].selected);
        c.unregister_surface(&env.surface_id);
        c.select_surface("gone");
        assert_eq!(fired(), 4);
        assert!(c.snapshot().groups.is_empty());
    }

    #[test]
    fn a_burst_of_changes_fires_once_until_the_next_snapshot() {
        let c = core();
        let n = Arc::new(AtomicUsize::new(0));
        let k = n.clone();
        c.set_listener(Arc::new(move || {
            k.fetch_add(1, Ordering::SeqCst);
        }));
        let a = c.register_surface("/a").unwrap();
        let b = c.register_surface("/b").unwrap();
        c.select_surface(&a.surface_id);
        assert_eq!(n.load(Ordering::SeqCst), 1);
        let v = c.snapshot().version;
        assert_eq!(c.snapshot_if_newer(0).map(|s| s.version), Some(v));
        c.select_surface(&b.surface_id);
        c.select_surface(&a.surface_id);
        assert_eq!((n.load(Ordering::SeqCst), c.snapshot_if_newer(v).map(|s| s.version)), (2, Some(v + 2)));
    }

    #[test]
    fn socket_end_to_end() {
        use std::io::Write;
        use std::os::unix::net::UnixStream;
        let (_dir, dir) = canonical_dir("e2e");
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
        c.snapshot();
        let mut s = UnixStream::connect(&env.socket_path).unwrap();
        writeln!(s, "{}", line(&env, Some(&env.nonce), PERM)).unwrap();
        drop(s);
        rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(answer(&c, &env.surface_id, true), Some(b"1".to_vec()));
        drop(c);
    }

    #[test]
    fn the_review_turn_comes_from_verified_events_only() {
        let repo = std::env::temp_dir().join(format!("haunt-model-turn-{}", std::process::id()));
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        let sha = "0123456789abcdef0123456789abcdef01234567";
        std::fs::write(repo.join(".git/HEAD"), format!("{sha}\n")).unwrap();
        let c = core();
        let env = c.register_surface("/Users/me").unwrap();
        assert_eq!(c.review_turn(&env.surface_id), None);
        let cmd = r#""event":"tool_start","tool_name":"Bash","tool_input":{"command":"cargo test"}"#;
        let prompt = format!(r#""event":"prompt_submit","cwd":"{}","query":"fix it""#, repo.display());
        c.with_state(|st| {
            st.handle_line(&line(&env, None, &prompt), Instant::now());
            st.handle_line(&line(&env, None, cmd), Instant::now());
        });
        assert_eq!(c.review_turn(&env.surface_id), None, "forged events leave no turn");
        c.with_state(|st| {
            st.handle_line(&line(&env, Some(&env.nonce), &prompt), Instant::now());
            st.handle_line(&line(&env, Some(&env.nonce), cmd), Instant::now());
        });
        let t = c.review_turn(&env.surface_id).unwrap();
        assert_eq!((t.number, t.prompt.as_deref(), t.head_at_start.as_deref()), (1, Some("fix it"), Some(sha)));
        assert_eq!(t.commands.len(), 1);
        let _ = std::fs::remove_dir_all(&repo);
    }
}
