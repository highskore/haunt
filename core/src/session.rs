//! Agent state of one surface, driven by hook events.

use std::collections::VecDeque;
use std::time::Instant;

use crate::event::{Agent, AgentEvent, EventKind, ToolCall};
use crate::progress::Progress;
use crate::turn::TurnLog;

const MAX_PROMPT_CHARS: usize = 120;
const MAX_RECENT_STARTS: usize = 16;
const MAX_UNRESOLVED: usize = 16;
/// Tools whose one command or file path is the whole of what the call may touch. Any other tool
/// (`apply_patch`, MCP tools) can do more than its preview shows, so only the terminal answers it.
const SINGLE_TARGET: [&str; 6] = ["Bash", "Edit", "MultiEdit", "Write", "NotebookEdit", "Read"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Idle,
    Running,
    NeedsYou,
    Done,
    Failed,
}

/// A permission prompt the agent is blocked on, as reported by a nonce-verified hook.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Permission {
    pub tool: String,
    /// The command or file path exactly as the hook sent it; shown only through `preview`.
    pub input: Option<String>,
    pub tool_use_id: Option<String>,
    /// The Bash command exactly as sent, for allow rules.
    pub raw_command: Option<String>,
    /// The hook's cwd, from the same verified event.
    pub cwd: Option<String>,
    /// The agent that asked; it decides the answer keys.
    pub agent: Agent,
    /// The subagent that asked, `None` for the main thread.
    thread: Option<String>,
    /// The `Session::generation` of the NeedsYou episode that created it.
    generation: u64,
    /// The user typed into the surface, so the terminal is answering; it only waits for its outcome.
    in_terminal: bool,
}

/// How a verified permission request ended.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Outcome {
    AllowedInHaunt,
    DeniedInHaunt,
    /// A plugin answered through `ptygate`, not the user; never counts as an approval.
    AllowedByPlugin { plugin_id: String },
    DeniedByPlugin { plugin_id: String },
    /// The matching call ran, so it was allowed at the terminal prompt.
    AnsweredInTerminal,
    Superseded,
}

impl Outcome {
    /// The serde tag, without serializing.
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::AllowedInHaunt => "allowed_in_haunt",
            Self::DeniedInHaunt => "denied_in_haunt",
            Self::AllowedByPlugin { .. } => "allowed_by_plugin",
            Self::DeniedByPlugin { .. } => "denied_by_plugin",
            Self::AnsweredInTerminal => "answered_in_terminal",
            Self::Superseded => "superseded",
        }
    }
}

impl Permission {
    /// None when the input is missing: the user has to answer in the terminal then.
    fn from_call(t: &ToolCall, e: &AgentEvent, generation: u64) -> Option<Self> {
        let input = raw_input(t)?;
        Some(Self {
            tool: t.tool_name.clone(),
            input: Some(input),
            tool_use_id: t.tool_use_id.clone(),
            raw_command: t.raw_command.clone(),
            cwd: e.cwd.clone(),
            agent: e.agent.as_str().into(),
            thread: e.agent_id.clone(),
            generation,
            in_terminal: false,
        })
    }

    /// The request key: an answer must name it, so it can only reach the prompt it was shown for.
    pub fn key(&self) -> u64 {
        self.generation
    }

    /// A truncated preview may differ from what was asked, so it never matches.
    fn matches(&self, t: &ToolCall, truncated: bool) -> bool {
        if truncated || self.tool != t.tool_name {
            return false;
        }
        match (&self.tool_use_id, &t.tool_use_id) {
            (Some(a), Some(b)) => a == b,
            _ => self.input == raw_input(t),
        }
    }

    /// "git push" for Bash, "Edit /w/a.rs" for the rest, with newlines, tabs and invisible
    /// characters shown rather than removed (see `event::visible`).
    pub fn preview(&self) -> String {
        let text = match &self.input {
            Some(i) if self.tool == "Bash" => i.clone(),
            Some(i) => format!("{} {i}", self.tool),
            None => self.tool.clone(),
        };
        crate::event::visible(&text)
    }

    /// Answered only in the terminal, because what runs may not be what the preview suggests: a
    /// multi-line input, one with control or invisible characters, or a tool not known to touch
    /// just the one target it shows (Bash by its command, the file tools by their path). A U+FFFD
    /// means some hop replaced bytes it couldn't decode, so the shown input may not be what runs.
    pub fn suspicious(&self) -> bool {
        let single = SINGLE_TARGET.contains(&self.tool.as_str()) && (self.tool == "Bash") == self.raw_command.is_some();
        !single || self.input.as_deref().is_some_and(|i| i.chars().any(|c| crate::event::is_hidden(c) || c == '\u{FFFD}'))
    }
}

fn raw_input(t: &ToolCall) -> Option<String> {
    t.raw_command.clone().or_else(|| t.raw_file_path.clone())
}

#[derive(Debug, Clone)]
pub struct Session {
    pub is_agent: bool,
    /// Set from verified events only, so a forged OSC body can't relabel the row.
    pub agent: Agent,
    pub status: Status,
    pub prompt: Option<String>,
    /// The latest verified hook's cwd: a command-launched agent never reports its cwd through the shell.
    pub cwd: Option<String>,
    pub progress: Progress,
    /// Only ever set from a verified, untruncated `permission_seen`, and only while NeedsYou.
    pub permission: Option<Permission>,
    /// Bumped on every entry into NeedsYou and every `permission_seen`.
    generation: u64,
    pub turn_started: Option<Instant>,
    pub turn_finished: Option<Instant>,
    pub status_changed: Instant,
    /// Verified `tool_start`s, to find the `tool_use_id` a `permission_seen` lacks.
    recent_starts: VecDeque<ToolCall>,
    /// Requests that ended since the last `take_ended`, for the decision log.
    ended: Vec<(Permission, Outcome)>,
    /// The latest turn, from verified events, for the review screen.
    pub turn: TurnLog,
    /// Superseded requests whose call hasn't been seen to run: the agent may still show their
    /// prompt (Codex queues parallel approvals), so no other request is answerable until their call runs
    /// or the turn ends.
    unresolved: Vec<Permission>,
    /// More requests went unresolved than `unresolved` holds: every request stays terminal-only
    /// until a verified turn end, rather than forgetting one that may still be on screen.
    overflowed: bool,
}

impl Session {
    pub fn new(now: Instant) -> Self {
        Self {
            is_agent: false,
            agent: Agent::Claude,
            status: Status::Idle,
            prompt: None,
            cwd: None,
            progress: Progress::default(),
            permission: None,
            generation: 0,
            turn_started: None,
            turn_finished: None,
            status_changed: now,
            recent_starts: VecDeque::new(),
            ended: Vec::new(),
            turn: TurnLog::default(),
            unresolved: Vec::new(),
            overflowed: false,
        }
    }

    /// Applies one event. `verified` is true only for socket events whose nonce matched; others
    /// may change status and progress but never the permission request. Returns whether anything changed.
    pub fn apply(&mut self, e: &AgentEvent, verified: bool, now: Instant) -> bool {
        let mut changed = !self.is_agent;
        self.is_agent = true;
        changed |= self.progress.apply(e, now);
        // A replaced request always has a new generation, so the generation stands for the request.
        let before = self.fingerprint();
        let main = e.agent_id.is_none();
        if verified
            && let Some(c) = e.cwd.as_ref().filter(|c| c.starts_with('/'))
            && self.cwd.as_ref() != Some(c)
        {
            self.cwd = Some(c.clone());
            changed = true;
        }
        if verified && self.agent.id() != e.agent {
            self.agent = e.agent.as_str().into();
            changed = true;
        }
        if verified {
            self.turn.apply(e, &self.agent);
        }

        match &e.kind {
            EventKind::PromptSubmit { query } => {
                let prompt = query.as_deref().map(one_line);
                changed |= prompt != self.prompt;
                self.prompt = prompt;
                self.progress.new_turn();
                self.turn_started = Some(now);
                self.turn_finished = None;
                self.set(Status::Running, now);
                if verified {
                    self.clear_unresolved();
                }
            }
            EventKind::ToolStart { tool } => {
                if verified {
                    if self.recent_starts.len() >= MAX_RECENT_STARTS {
                        self.recent_starts.pop_front();
                    }
                    self.recent_starts.push_back(tool.clone());
                }
                if matches!(self.status, Status::Idle | Status::Done | Status::Failed) || self.moved_on(e, tool, verified) {
                    self.set(Status::Running, now);
                }
            }
            EventKind::ToolDone { tool } | EventKind::ToolFailed { tool } | EventKind::ToolRan { tool } => {
                // Only an exact tool_use_id on the same thread retires an unresolved request; one
                // without an id can't be told apart from a lookalike call and waits for the turn end.
                let earlier = verified
                    && !e.truncated
                    && self
                        .unresolved
                        .iter()
                        .position(|p| p.tool == tool.tool_name && p.thread == e.agent_id && p.tool_use_id.is_some() && p.tool_use_id == tool.tool_use_id)
                        .map(|i| self.unresolved.remove(i))
                        .is_some();
                if self.status == Status::NeedsYou {
                    let resolved = match &self.permission {
                        Some(p) => !earlier && verified && p.matches(tool, e.truncated),
                        None => main,
                    };
                    if resolved {
                        self.end_permission(Outcome::AnsweredInTerminal);
                        self.set(Status::Running, now);
                    } else if !earlier && self.moved_on(e, tool, verified) {
                        self.set(Status::Running, now);
                    }
                }
            }
            EventKind::PermissionSeen { tool } => {
                self.set(Status::NeedsYou, now);
                // Every prompt, forged or not, retires the one before it.
                self.generation += 1;
                self.end_permission(Outcome::Superseded);
                if verified && !e.truncated
                    && let Some(mut p) = Permission::from_call(tool, e, self.generation)
                {
                    let start = self.recent_starts.iter().rev().find(|s| p.tool_use_id.is_none() && p.matches(s, false));
                    p.tool_use_id = start.and_then(|s| s.tool_use_id.clone());
                    self.permission = Some(p);
                }
            }
            EventKind::Notification { notification_type: Some(t), .. } if t == "permission_prompt" => {
                self.set(Status::NeedsYou, now);
            }
            EventKind::Stop => self.finish(Status::Done, verified, now),
            // Names the official Warp plugin uses; status only.
            EventKind::Unknown { event } => match event.as_str() {
                "stop_failure" => self.finish(Status::Failed, verified, now),
                "permission_request" | "question_asked" | "agent_needs_input" => self.set(Status::NeedsYou, now),
                "permission_replied" | "tool_complete" if self.status == Status::NeedsYou && self.permission.is_none() => {
                    self.set(Status::Running, now)
                }
                _ => {}
            },
            _ => {}
        }
        changed || before != self.fingerprint()
    }

    fn fingerprint(&self) -> (Status, Option<u64>, usize, bool) {
        (self.status, self.permission.as_ref().map(|p| p.generation), self.unresolved.len(), self.overflowed)
    }

    /// A verified call other than the pending one, on the thread that asked: the prompt is gone. Only
    /// for agents without Claude Code's failure hook (Codex), where a denied call never reports back.
    fn moved_on(&self, e: &AgentEvent, tool: &ToolCall, verified: bool) -> bool {
        self.permission.as_ref().is_some_and(|p| {
            verified && p.agent != Agent::Claude && p.thread == e.agent_id && !p.matches(tool, e.truncated)
        })
    }

    /// The permission an answer may go to: verified, created by the NeedsYou episode still on screen,
    /// and not since taken over by keys typed into the terminal.
    pub fn live_permission(&self) -> Option<&Permission> {
        self.permission.as_ref().filter(|p| self.status == Status::NeedsYou && p.generation == self.generation && !p.in_terminal)
    }

    /// The user typed into the surface: whatever they typed answers or moves the prompt, so an answer
    /// from haunt could now land in the running tool. The request stays only to record its outcome.
    pub fn user_input(&mut self) -> bool {
        match &mut self.permission {
            Some(p) if !p.in_terminal => {
                p.in_terminal = true;
                true
            }
            _ => false,
        }
    }

    /// The live request may be shown but not answered from haunt: it is suspicious, or another
    /// verified request may still be on screen ahead of it.
    pub fn terminal_only(&self, p: &Permission) -> bool {
        p.suspicious() || self.overflowed || !self.unresolved.is_empty()
    }

    /// Consumes the live permission if `key` names it; false for a stale or unknown key, and for a
    /// terminal-only request, which stays live for the terminal to answer.
    pub fn answer(&mut self, key: u64, allow: bool, now: Instant) -> bool {
        self.answer_as(key, if allow { Outcome::AllowedInHaunt } else { Outcome::DeniedInHaunt }, now)
    }

    /// `answer`, logging `outcome` (an `…InHaunt` or `…ByPlugin` one).
    pub fn answer_as(&mut self, key: u64, outcome: Outcome, now: Instant) -> bool {
        if self.live_permission().is_none_or(|p| p.key() != key || self.terminal_only(p)) {
            return false;
        }
        self.end_permission(outcome);
        self.set(Status::Running, now);
        true
    }

    /// Ends the request, if any, as superseded: the surface is going away.
    pub fn close(&mut self) {
        self.end_permission(Outcome::Superseded);
        self.clear_unresolved();
    }

    #[cfg(test)]
    pub(crate) fn current_key(&self) -> u64 {
        self.generation
    }

    pub fn take_ended(&mut self) -> Vec<(Permission, Outcome)> {
        std::mem::take(&mut self.ended)
    }

    fn end_permission(&mut self, outcome: Outcome) {
        if let Some(p) = self.permission.take() {
            if outcome == Outcome::Superseded {
                if self.unresolved.len() < MAX_UNRESOLVED {
                    self.unresolved.push(p.clone());
                } else {
                    self.overflowed = true;
                }
            }
            self.ended.push((p, outcome));
        }
    }

    /// A turn end. Only a verified one clears the unresolved requests: a forged stop may end the
    /// live request, but never unblocks another.
    fn finish(&mut self, status: Status, verified: bool, now: Instant) {
        self.turn_finished = Some(now);
        self.set(status, now);
        if verified {
            self.clear_unresolved();
        }
    }

    fn clear_unresolved(&mut self) {
        self.unresolved.clear();
        self.overflowed = false;
    }

    /// Leaving NeedsYou always drops the request; entering it starts a new generation.
    fn set(&mut self, status: Status, now: Instant) {
        if self.status == status {
            return;
        }
        if self.status == Status::NeedsYou {
            self.end_permission(Outcome::Superseded);
        }
        if status == Status::NeedsYou {
            self.generation += 1;
        }
        self.status = status;
        self.status_changed = now;
    }
}

fn one_line(s: &str) -> String {
    let line = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() <= MAX_PROMPT_CHARS {
        return line.to_owned();
    }
    let mut cut: String = line.chars().take(MAX_PROMPT_CHARS - 1).collect();
    cut.push('…');
    cut
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::parse_osc;

    fn ev(json: &str) -> AgentEvent {
        parse_osc("haunt://cli-agent", &format!(r#"{{"v":1,{}"#, &json[1..])).expect("valid event")
    }

    const PERM: &str = r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"git push"}}"#;
    const RAN: &str = r#"{"event":"tool_ran","tool_name":"Bash","tool_input":{"command":"git push"}}"#;
    const START_T1: &str = r#"{"event":"tool_start","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git push"}}"#;
    const RAN_T1: &str = r#"{"event":"tool_ran","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"git push"}}"#;

    fn running() -> (Session, Instant) {
        let now = Instant::now();
        let mut s = Session::new(now);
        s.apply(&ev(r#"{"event":"prompt_submit","query":"ship it\nplease"}"#), true, now);
        (s, now)
    }

    #[test]
    fn prompt_runs_and_stop_finishes() {
        let (mut s, now) = running();
        assert!(s.is_agent);
        assert_eq!(s.status, Status::Running);
        assert_eq!(s.prompt.as_deref(), Some("ship it please"));
        assert!(s.apply(&ev(r#"{"event":"stop"}"#), true, now));
        assert_eq!(s.status, Status::Done);
        assert!(s.turn_finished.is_some());
    }

    #[test]
    fn first_event_makes_a_shell_an_agent() {
        let now = Instant::now();
        let mut s = Session::new(now);
        assert!(s.apply(&ev(r#"{"event":"session_start"}"#), false, now));
        assert!(s.is_agent);
        assert_eq!(s.status, Status::Idle);
        assert!(!s.apply(&ev(r#"{"event":"session_start"}"#), false, now));
    }

    #[test]
    fn verified_permission_blocks_until_the_matching_call_runs() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), true, now);
        assert_eq!(s.status, Status::NeedsYou);
        assert_eq!(s.live_permission().map(Permission::preview).as_deref(), Some("git push"));
        s.apply(&ev(r#"{"event":"tool_ran","tool_name":"Bash","tool_input":{"command":"ls"}}"#), true, now);
        assert_eq!(s.status, Status::NeedsYou, "another call does not resolve it");
        s.apply(&ev(RAN), true, now);
        assert_eq!(s.status, Status::Running);
        assert_eq!(s.permission, None);
    }

    #[test]
    fn truncated_tool_ran_never_matches() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(r#"{"event":"tool_ran","tool_name":"Bash","truncated":true,"tool_input":{"command":"git push"}}"#), true, now);
        assert_eq!(s.status, Status::NeedsYou);
        assert!(s.live_permission().is_some());
    }

    #[test]
    fn permission_takes_tool_use_id_from_its_tool_start() {
        let (mut s, now) = running();
        s.apply(&ev(r#"{"event":"tool_start","tool_name":"Bash","tool_use_id":"tu9","tool_input":{"command":"git push"}}"#), true, now);
        s.apply(&ev(PERM), true, now);
        assert_eq!(s.permission.as_ref().and_then(|p| p.tool_use_id.as_deref()), Some("tu9"));
        s.apply(&ev(r#"{"event":"tool_ran","tool_name":"Bash","tool_use_id":"tu8","tool_input":{"command":"git push"}}"#), true, now);
        assert_eq!(s.status, Status::NeedsYou, "same input, different call");
        s.apply(&ev(r#"{"event":"tool_ran","tool_name":"Bash","tool_use_id":"tu9","tool_input":{"command":"git push"}}"#), true, now);
        assert_eq!(s.status, Status::Running);
    }

    const CODEX_START: &str = r#"{"agent":"codex","event":"tool_start","tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"git push"}}"#;
    const CODEX_PERM: &str = r#"{"agent":"codex","event":"permission_seen","tool_name":"Bash","tool_input":{"command":"git push"}}"#;

    #[test]
    fn the_agent_comes_from_verified_events_only() {
        let (mut s, now) = running();
        assert_eq!(s.agent, Agent::Claude, "no agent field is the legacy Claude hook");
        assert!(s.apply(&ev(r#"{"agent":"codex","event":"session_start"}"#), true, now));
        assert_eq!(s.agent, Agent::Codex);
        s.apply(&ev(r#"{"agent":"claude","event":"session_start"}"#), false, now);
        assert_eq!(s.agent, Agent::Codex, "a forged body can't relabel the row");
        s.apply(&ev(r#"{"agent":"aider","event":"session_start"}"#), true, now);
        assert_eq!(s.agent, Agent::Other { id: "aider".into() });
    }

    #[test]
    fn a_codex_request_carries_its_agent_and_the_tool_start_id() {
        let (mut s, now) = running();
        s.apply(&ev(CODEX_START), true, now);
        s.apply(&ev(CODEX_PERM), true, now);
        let p = s.live_permission().unwrap();
        assert_eq!((p.agent.clone(), p.tool_use_id.as_deref()), (Agent::Codex, Some("c1")));
        s.apply(&ev(r#"{"agent":"codex","event":"tool_done","tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"git push"}}"#), true, now);
        assert_eq!(s.status, Status::Running);
        assert_eq!(s.take_ended().iter().map(|(_, o)| o.clone()).collect::<Vec<_>>(), [Outcome::AnsweredInTerminal]);
    }

    #[test]
    fn a_codex_request_without_a_tool_start_matches_on_exact_input() {
        let (mut s, now) = running();
        s.apply(&ev(CODEX_PERM), true, now);
        assert_eq!(s.live_permission().unwrap().tool_use_id, None);
        s.apply(&ev(r#"{"agent":"codex","event":"tool_ran","tool_name":"Bash","tool_use_id":"c7","tool_input":{"command":"git push"}}"#), true, now);
        assert_eq!(s.take_ended().iter().map(|(_, o)| o.clone()).collect::<Vec<_>>(), [Outcome::AnsweredInTerminal]);
    }

    #[test]
    fn a_codex_request_ends_when_codex_moves_on() {
        let other_start = r#"{"agent":"codex","event":"tool_start","tool_name":"Bash","tool_use_id":"c2","tool_input":{"command":"ls"}}"#;
        let other_done = r#"{"agent":"codex","event":"tool_done","tool_name":"update_plan","tool_use_id":"c3","tool_input":{}}"#;
        for next in [other_start, other_done, r#"{"agent":"codex","event":"prompt_submit","query":"no"}"#, r#"{"agent":"codex","event":"stop"}"#] {
            let (mut s, now) = running();
            s.apply(&ev(CODEX_START), true, now);
            s.apply(&ev(CODEX_PERM), true, now);
            s.apply(&ev(next), true, now);
            assert_ne!(s.status, Status::NeedsYou, "{next}");
            assert_eq!(s.take_ended().iter().map(|(_, o)| o.clone()).collect::<Vec<_>>(), [Outcome::Superseded], "{next}");
        }
    }

    #[test]
    fn a_codex_request_survives_other_threads_and_forged_calls() {
        let (mut s, now) = running();
        s.apply(&ev(CODEX_START), true, now);
        s.apply(&ev(CODEX_PERM), true, now);
        s.apply(&ev(r#"{"agent":"codex","event":"tool_start","agent_id":"th2","tool_name":"Bash","tool_input":{"command":"rg x"}}"#), true, now);
        s.apply(&ev(r#"{"agent":"codex","event":"tool_start","tool_name":"Bash","tool_input":{"command":"ls"}}"#), false, now);
        s.apply(&ev(r#"{"agent":"codex","event":"tool_start","tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"git push"}}"#), true, now);
        assert!(s.live_permission().is_some(), "a subagent's call, a forged one and its own call leave it");
        assert!(s.user_input());
        assert_eq!(s.live_permission(), None, "typing retires it, as for Claude");
    }

    #[test]
    fn a_claude_request_waits_through_other_calls() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(r#"{"event":"tool_start","tool_name":"Bash","tool_input":{"command":"ls"}}"#), true, now);
        assert!(s.live_permission().is_some(), "unchanged for Claude");
    }

    #[test]
    fn unverified_events_change_status_but_never_the_permission() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), false, now);
        assert_eq!(s.status, Status::NeedsYou);
        assert_eq!(s.live_permission(), None);

        s.apply(&ev(PERM), true, now);
        assert!(s.live_permission().is_some());
        s.apply(&ev(RAN), false, now);
        assert!(s.live_permission().is_some(), "a forged tool_ran does not resolve it");
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#), false, now);
        assert_eq!(s.status, Status::NeedsYou);
        assert_eq!(s.live_permission(), None, "a forged prompt retires the real one rather than taking its place");
    }

    #[test]
    fn stale_request_is_not_revived_by_unverified_needs_you() {
        for middle in [None, Some(r#"{"event":"prompt_submit","query":"next"}"#)] {
            let (mut s, now) = running();
            s.apply(&ev(PERM), true, now);
            s.apply(&ev(r#"{"event":"stop"}"#), false, now);
            if let Some(m) = middle {
                s.apply(&ev(m), false, now);
            }
            for revive in [r#"{"event":"notification","notification_type":"permission_prompt"}"#, r#"{"event":"permission_request"}"#] {
                s.apply(&ev(revive), false, now);
                assert_eq!(s.status, Status::NeedsYou);
                assert_eq!(s.live_permission(), None, "{middle:?} {revive}");
                assert!(!s.answer(s.generation, true, now));
            }
        }
    }

    #[test]
    fn a_request_belongs_to_its_own_needs_you_episode() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), true, now);
        let first = s.live_permission().cloned().unwrap();
        s.apply(&ev(PERM), true, now);
        let second = s.live_permission().cloned().unwrap();
        assert_ne!(first, second, "a new prompt is a new generation even with the same text");
        s.apply(&ev(r#"{"event":"notification","notification_type":"permission_prompt"}"#), true, now);
        assert_eq!(s.live_permission(), Some(&second), "the prompt's own notification keeps it");
    }

    #[test]
    fn truncated_or_inputless_prompt_is_not_answerable() {
        for p in [
            r#"{"event":"permission_seen","tool_name":"Bash","truncated":true,"tool_input":{"command":"git push"}}"#,
            r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{}}"#,
            r#"{"event":"permission_seen","tool_name":"ExitPlanMode","tool_input":{}}"#,
        ] {
            let (mut s, now) = running();
            s.apply(&ev(p), true, now);
            assert_eq!(s.status, Status::NeedsYou, "{p}");
            assert_eq!(s.live_permission(), None, "{p}");
        }
    }

    #[test]
    fn preview_shows_invisible_characters_and_they_block_answers() {
        let (mut s, now) = running();
        let spoof = "{\"event\":\"permission_seen\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi \\u202e\\u2066/ fr- mr\\u2069\\u200b\\ufeff\"}}";
        s.apply(&ev(spoof), true, now);
        let p = s.live_permission().unwrap().clone();
        assert_eq!(p.preview(), "echo hi \\u{202e}\\u{2066}/ fr- mr\\u{2069}\\u{200b}\\u{feff}");
        assert!(p.suspicious());
        assert!(!s.answer(p.key(), true, now), "answered in the terminal only");
        assert_eq!(s.live_permission(), Some(&p), "a refused answer leaves it live");
        let p = Permission { tool: "Bash".into(), input: Some("a\u{202e}b".into()), tool_use_id: None, raw_command: None, cwd: None, agent: Agent::Claude, thread: None, generation: 0, in_terminal: false };
        assert_eq!(p.preview(), "a\\u{202e}b", "preview shows even input that skipped the parser");
    }

    #[test]
    fn a_hidden_newline_is_shown_and_never_answerable() {
        let (mut s, now) = running();
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"ls #\nrm -rf ~/x"}}"#), true, now);
        let p = s.live_permission().unwrap().clone();
        assert_eq!(p.preview(), "ls #⏎rm -rf ~/x");
        assert!(p.suspicious());
        assert!(!s.answer(p.key(), true, now) && !s.answer(p.key(), false, now));
        s.apply(&ev(r#"{"event":"tool_ran","tool_name":"Bash","tool_input":{"command":"ls #\nrm -rf ~/x"}}"#), true, now);
        assert_eq!(s.take_ended().last().map(|(_, o)| o.clone()), Some(Outcome::AnsweredInTerminal));
    }

    #[test]
    fn unverified_needs_you_clears_on_main_agent_tool_activity() {
        let (mut s, now) = running();
        s.apply(&ev(r#"{"event":"notification","notification_type":"permission_prompt"}"#), false, now);
        assert_eq!(s.status, Status::NeedsYou);
        s.apply(&ev(r#"{"event":"tool_done","tool_name":"Read","agent_id":"sub","tool_input":{}}"#), false, now);
        assert_eq!(s.status, Status::NeedsYou, "a subagent's call is not the prompt");
        s.apply(&ev(r#"{"event":"tool_done","tool_name":"Read","tool_input":{}}"#), false, now);
        assert_eq!(s.status, Status::Running);
    }

    #[test]
    fn idle_notification_keeps_done() {
        let (mut s, now) = running();
        s.apply(&ev(r#"{"event":"stop"}"#), true, now);
        assert!(!s.apply(&ev(r#"{"event":"notification","notification_type":"idle_prompt"}"#), true, now));
        assert_eq!(s.status, Status::Done);
    }

    #[test]
    fn answering_consumes_the_request_once() {
        let (mut s, now) = running();
        assert!(!s.answer(0, true, now));
        s.apply(&ev(PERM), true, now);
        let key = s.live_permission().unwrap().key();
        assert!(s.answer(key, true, now));
        assert_eq!(s.status, Status::Running);
        assert!(!s.answer(key, true, now));
    }

    #[test]
    fn typing_in_the_terminal_retires_the_request_until_its_outcome() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), true, now);
        let key = s.live_permission().unwrap().key();
        assert!(s.user_input());
        assert!(!s.user_input(), "once");
        assert_eq!(s.live_permission(), None);
        assert!(!s.answer(key, true, now), "the tool may be running: haunt must not type into it");
        assert_eq!(s.status, Status::NeedsYou);
        s.apply(&ev(RAN), true, now);
        assert_eq!(s.take_ended().iter().map(|(_, o)| o.clone()).collect::<Vec<_>>(), [Outcome::AnsweredInTerminal]);

        s.apply(&ev(PERM), true, now);
        s.user_input();
        s.apply(&ev(r#"{"event":"stop"}"#), true, now);
        assert_eq!(s.take_ended().iter().map(|(_, o)| o.clone()).collect::<Vec<_>>(), [Outcome::Superseded], "denied at the terminal");
        assert!(!s.user_input(), "nothing pending");
    }

    #[test]
    fn a_stale_key_is_refused_after_the_prompt_changed() {
        let (mut s, now) = running();
        s.apply(&ev(START_T1), true, now);
        s.apply(&ev(PERM), true, now);
        let old = s.live_permission().unwrap().key();
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#), true, now);
        assert!(!s.answer(old, true, now));
        assert_eq!(s.status, Status::NeedsYou, "the refused answer changed nothing");
        let new = s.live_permission().unwrap().key();
        assert_ne!(old, new);
        assert!(!s.answer(new, false, now), "git push may still be on screen ahead of it");
        s.apply(&ev(RAN_T1), true, now);
        assert!(s.answer(new, false, now), "the only request left");
    }

    #[test]
    fn every_verified_request_ends_with_one_outcome() {
        use Outcome::*;
        let (mut s, now) = running();
        let answer = |s: &mut Session, allow: bool| {
            s.apply(&ev(PERM), true, now);
            let key = s.live_permission().unwrap().key();
            s.answer(key, allow, now);
        };
        s.apply(&ev(r#"{"event":"permission_seen","cwd":"/p","tool_name":"Bash","tool_input":{"command":"git push"}}"#), true, now);
        s.apply(&ev(r#"{"event":"prompt_submit","query":"next"}"#), true, now);
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(RAN), true, now);
        answer(&mut s, true);
        answer(&mut s, false);
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(r#"{"event":"stop"}"#), false, now);
        s.apply(&ev(PERM), false, now);
        s.close();
        let ended = s.take_ended();
        let outcomes: Vec<_> = ended.iter().map(|(_, o)| o.clone()).collect();
        assert_eq!(outcomes, [Superseded, AnsweredInTerminal, AllowedInHaunt, DeniedInHaunt, Superseded], "an unverified prompt is no request");
        assert_eq!(ended[0].0.cwd.as_deref(), Some("/p"));
        assert!(s.take_ended().is_empty());
    }

    #[test]
    fn new_prompt_and_stop_clear_a_verified_request() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(r#"{"event":"prompt_submit","query":"next"}"#), true, now);
        assert_eq!(s.permission, None);
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(r#"{"event":"stop"}"#), true, now);
        assert_eq!(s.permission, None);
    }

    #[test]
    fn warp_plugin_names_drive_status() {
        let (mut s, now) = running();
        s.apply(&ev(r#"{"event":"permission_request"}"#), false, now);
        assert_eq!(s.status, Status::NeedsYou);
        s.apply(&ev(r#"{"event":"permission_replied"}"#), false, now);
        assert_eq!(s.status, Status::Running);
        s.apply(&ev(r#"{"event":"stop_failure"}"#), false, now);
        assert_eq!(s.status, Status::Failed);
    }

    #[test]
    fn only_single_target_tools_are_answerable() {
        let answerable = |body: &str| {
            let (mut s, now) = running();
            s.apply(&ev(body), true, now);
            let p = s.live_permission().cloned().expect(body);
            (s.answer(p.key(), true, now), p.preview())
        };
        let perm = |agent: &str, tool: &str, input: &str| {
            format!(r#"{{"agent":"{agent}","event":"permission_seen","tool_name":"{tool}","tool_input":{input}}}"#)
        };
        for (tool, input) in [("Bash", r#"{"command":"git push"}"#), ("Edit", r#"{"file_path":"/w/a.rs"}"#), ("MultiEdit", r#"{"file_path":"/w/a.rs"}"#), ("Write", r#"{"file_path":"/w/a.rs"}"#)] {
            assert!(answerable(&perm("claude", tool, input)).0, "{tool}");
        }
        assert!(answerable(&perm("codex", "Bash", r#"{"command":"git push"}"#)).0);
        for (agent, tool, input) in [
            ("codex", "apply_patch", r#"{"file_path":"/w/src/zz_main.rs"}"#),
            ("claude", "mcp__fs__write", r#"{"file_path":"/w/a.rs"}"#),
            ("claude", "mcp__sh__run", r#"{"command":"ls"}"#),
            ("claude", "Bash", r#"{"file_path":"/w/a.rs"}"#),
            ("claude", "Edit", r#"{"command":"ls","file_path":"/w/a.rs"}"#),
        ] {
            assert!(!answerable(&perm(agent, tool, input)).0, "{tool} {input}");
        }
        let many = answerable(&perm("codex", "apply_patch", r#"{"file_path":"/w/src/zz_main.rs\n/Users/me/.zshenv"}"#));
        assert_eq!(many, (false, "apply_patch /w/src/zz_main.rs⏎/Users/me/.zshenv".to_owned()), "every path shows");
    }

    const CODEX_START_B: &str = r#"{"agent":"codex","event":"tool_start","tool_name":"Bash","tool_use_id":"c2","tool_input":{"command":"rm -rf build"}}"#;
    const CODEX_PERM_B: &str = r#"{"agent":"codex","event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#;
    const CODEX_DONE_A: &str = r#"{"agent":"codex","event":"tool_done","tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"git push"}}"#;

    #[test]
    fn parallel_requests_are_answerable_only_once_one_is_left() {
        for order in [[CODEX_START, CODEX_PERM, CODEX_START_B, CODEX_PERM_B], [CODEX_START, CODEX_START_B, CODEX_PERM, CODEX_PERM_B]] {
            let (mut s, now) = running();
            for e in order {
                s.apply(&ev(e), true, now);
            }
            let b = s.live_permission().cloned().expect("the newest is shown");
            assert_eq!(b.preview(), "rm -rf build");
            assert!(s.terminal_only(&b), "git push may still be on screen ahead of it");
            assert!(!s.answer(b.key(), true, now) && !s.answer(b.key(), false, now));
            assert!(s.apply(&ev(CODEX_DONE_A), true, now), "the change reaches the UI");
            assert_eq!(s.live_permission(), Some(&b), "the earlier call ran; that is no sign the newer prompt is gone");
            assert!(!s.terminal_only(&b));
            assert!(s.answer(b.key(), true, now));
        }
    }

    #[test]
    fn an_unresolved_request_blocks_answers_until_the_turn_ends() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#), true, now);
        s.apply(&ev(r#"{"event":"tool_ran","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#), true, now);
        assert_eq!(s.status, Status::Running);
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"ls"}}"#), true, now);
        let p = s.live_permission().cloned().unwrap();
        assert!(s.terminal_only(&p), "git push never ran, so its prompt may be up");
        s.apply(&ev(RAN), false, now);
        assert!(s.terminal_only(&p), "a forged tool_ran doesn't clear it");
        s.apply(&ev(r#"{"event":"prompt_submit","query":"next"}"#), true, now);
        s.apply(&ev(PERM), true, now);
        let p = s.live_permission().cloned().unwrap();
        assert!(s.answer(p.key(), true, now), "a new turn starts clean");
    }

    #[test]
    fn a_forged_turn_end_never_unblocks_a_request() {
        for end in [r#"{"event":"stop"}"#, r#"{"event":"stop_failure"}"#, r#"{"event":"prompt_submit","query":"x"}"#] {
            let (mut s, now) = running();
            s.apply(&ev(PERM), true, now);
            s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"ls"}}"#), true, now);
            s.apply(&ev(end), false, now);
            s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf ~"}}"#), true, now);
            let p = s.live_permission().cloned().unwrap();
            assert!(s.terminal_only(&p), "{end}: git push and ls may still be on screen");
            assert!(!s.answer(p.key(), true, now), "{end}");
            s.apply(&ev(end), true, now);
            s.apply(&ev(r#"{"event":"prompt_submit","query":"y"}"#), true, now);
            s.apply(&ev(PERM), true, now);
            let p = s.live_permission().cloned().unwrap();
            assert!(!s.terminal_only(&p), "{end}: a verified turn end clears them");
        }
    }

    #[test]
    fn overflowing_the_unresolved_list_stays_terminal_only_until_the_turn_ends() {
        let (mut s, now) = running();
        s.apply(&ev(START_T1), true, now);
        s.apply(&ev(PERM), true, now);
        for i in 0..MAX_UNRESOLVED + 4 {
            s.apply(&ev(&format!(r#"{{"event":"permission_seen","tool_name":"Bash","tool_use_id":"f{i}","tool_input":{{"command":"echo {i}"}}}}"#)), true, now);
        }
        for i in 0..MAX_UNRESOLVED + 4 {
            s.apply(&ev(&format!(r#"{{"event":"tool_ran","tool_name":"Bash","tool_use_id":"f{i}","tool_input":{{"command":"echo {i}"}}}}"#)), true, now);
        }
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf ~"}}"#), true, now);
        let p = s.live_permission().cloned().unwrap();
        assert!(s.terminal_only(&p), "a request pushed past the cap is never forgotten");
        s.apply(&ev(r#"{"event":"stop"}"#), true, now);
        s.apply(&ev(r#"{"event":"prompt_submit","query":"y"}"#), true, now);
        s.apply(&ev(PERM), true, now);
        let p = s.live_permission().cloned().unwrap();
        assert!(!s.terminal_only(&p));
    }

    #[test]
    fn only_the_same_id_on_the_same_thread_retires_an_unresolved_request() {
        let (mut s, now) = running();
        s.apply(&ev(START_T1), true, now);
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"ls"}}"#), true, now);
        let p = s.live_permission().cloned().unwrap();
        for ran in [
            RAN,
            r#"{"event":"tool_ran","tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"git push"}}"#,
            r#"{"event":"tool_ran","tool_name":"Bash","tool_use_id":"t1","agent_id":"sub","tool_input":{"command":"git push"}}"#,
        ] {
            s.apply(&ev(ran), true, now);
            assert!(s.terminal_only(&p), "{ran}");
        }
        s.apply(&ev(RAN_T1), true, now);
        assert!(!s.terminal_only(&p));

        let (mut s, now) = running();
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"ls"}}"#), true, now);
        s.apply(&ev(RAN), true, now);
        let p = s.live_permission().cloned().unwrap();
        assert!(s.terminal_only(&p), "an id-less request waits for the turn end");
    }

    #[test]
    fn requests_match_their_call_byte_for_byte() {
        for (asked, ran) in [("git push", "git push "), ("git\u{200b}push", "gitpush"), ("rm a\u{a0}b", "rm a b"), ("caf\u{e9}", "cafe\u{301}")] {
            let (mut s, now) = running();
            let call = |ev_name: &str, cmd: &str| ev(&serde_json::json!({"event": ev_name, "tool_name": "Bash", "tool_input": {"command": cmd}}).to_string());
            s.apply(&call("permission_seen", asked), true, now);
            assert_eq!(s.live_permission().unwrap().raw_command.as_deref(), Some(asked), "stored exactly as sent");
            s.apply(&call("tool_ran", ran), true, now);
            assert!(s.live_permission().is_some(), "{asked:?} is not answered by {ran:?}");
        }
        let (mut s, now) = running();
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm �"}}"#), true, now);
        let p = s.live_permission().cloned().unwrap();
        assert!(p.suspicious(), "a replacement character means bytes were lost on the way");
    }

    #[test]
    fn outcome_names_are_the_serde_tags() {
        let p = || "p".to_owned();
        for o in [Outcome::AllowedInHaunt, Outcome::DeniedInHaunt, Outcome::AllowedByPlugin { plugin_id: p() }, Outcome::DeniedByPlugin { plugin_id: p() }, Outcome::AnsweredInTerminal, Outcome::Superseded] {
            let json = serde_json::to_string(&o).unwrap();
            assert!(json.starts_with(&format!("\"{}\"", o.as_str())) || json.starts_with(&format!("{{\"{}\"", o.as_str())), "{json}");
        }
    }

    #[test]
    fn long_prompts_are_cut() {
        assert_eq!(one_line(&"x".repeat(500)).chars().count(), MAX_PROMPT_CHARS);
        assert_eq!(one_line("  hi \n there  "), "hi there");
    }
}
