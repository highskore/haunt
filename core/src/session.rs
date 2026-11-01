//! Agent state of one surface, driven by hook events.

use std::collections::VecDeque;
use std::time::Instant;

use crate::event::{AgentEvent, EventKind, ToolCall};
use crate::progress::Progress;

const MAX_PROMPT_CHARS: usize = 120;
const MAX_RECENT_STARTS: usize = 16;

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
    pub input: Option<String>,
    pub tool_use_id: Option<String>,
}

impl Permission {
    fn from_call(t: &ToolCall) -> Self {
        Self { tool: t.tool_name.clone(), input: t.command.clone().or_else(|| t.file_path.clone()), tool_use_id: t.tool_use_id.clone() }
    }

    /// A truncated preview may differ from what was asked, so it never matches.
    fn matches(&self, t: &ToolCall, truncated: bool) -> bool {
        if truncated || self.tool != t.tool_name {
            return false;
        }
        match (&self.tool_use_id, &t.tool_use_id) {
            (Some(a), Some(b)) => a == b,
            _ => self.input == t.command.clone().or_else(|| t.file_path.clone()),
        }
    }

    /// "git push" for Bash, "Edit /w/a.rs" for the rest.
    pub fn preview(&self) -> String {
        match &self.input {
            Some(i) if self.tool == "Bash" => i.clone(),
            Some(i) => format!("{} {i}", self.tool),
            None => self.tool.clone(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Session {
    pub is_agent: bool,
    pub status: Status,
    pub prompt: Option<String>,
    pub progress: Progress,
    /// Only ever set from verified events.
    pub permission: Option<Permission>,
    pub turn_started: Option<Instant>,
    pub turn_finished: Option<Instant>,
    pub status_changed: Instant,
    /// Verified `tool_start`s, to find the `tool_use_id` a `permission_seen` lacks.
    recent_starts: VecDeque<ToolCall>,
}

impl Session {
    pub fn new(now: Instant) -> Self {
        Self {
            is_agent: false,
            status: Status::Idle,
            prompt: None,
            progress: Progress::default(),
            permission: None,
            turn_started: None,
            turn_finished: None,
            status_changed: now,
            recent_starts: VecDeque::new(),
        }
    }

    /// Applies one event. `verified` is true only for socket events whose nonce matched; others
    /// may change status and progress but never the permission request. Returns whether anything changed.
    pub fn apply(&mut self, e: &AgentEvent, verified: bool, now: Instant) -> bool {
        let mut changed = !self.is_agent;
        self.is_agent = true;
        changed |= self.progress.apply(e, now);
        let before = (self.status, self.permission.clone(), self.prompt.clone());
        let main = e.agent_id.is_none();

        match &e.kind {
            EventKind::PromptSubmit { query } => {
                self.prompt = query.as_deref().map(one_line);
                self.progress.new_turn();
                self.turn_started = Some(now);
                self.turn_finished = None;
                self.set(Status::Running, now);
                if verified {
                    self.permission = None;
                }
            }
            EventKind::ToolStart { tool } => {
                if verified {
                    if self.recent_starts.len() >= MAX_RECENT_STARTS {
                        self.recent_starts.pop_front();
                    }
                    self.recent_starts.push_back(tool.clone());
                }
                if matches!(self.status, Status::Idle | Status::Done | Status::Failed) {
                    self.set(Status::Running, now);
                }
            }
            EventKind::ToolDone { tool } | EventKind::ToolFailed { tool } | EventKind::ToolRan { tool } => {
                if self.status == Status::NeedsYou {
                    let resolved = match &self.permission {
                        Some(p) => verified && p.matches(tool, e.truncated),
                        None => main,
                    };
                    if resolved {
                        if verified {
                            self.permission = None;
                        }
                        self.set(Status::Running, now);
                    }
                }
            }
            EventKind::PermissionSeen { tool } => {
                if verified {
                    let mut p = Permission::from_call(tool);
                    let start = self.recent_starts.iter().rev().find(|s| p.tool_use_id.is_none() && p.matches(s, false));
                    p.tool_use_id = start.and_then(|s| s.tool_use_id.clone());
                    self.permission = Some(p);
                }
                self.set(Status::NeedsYou, now);
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
        changed || before != (self.status, self.permission.clone(), self.prompt.clone())
    }

    /// The permission an answer may go to: verified and still blocking.
    pub fn live_permission(&self) -> Option<&Permission> {
        self.permission.as_ref().filter(|_| self.status == Status::NeedsYou)
    }

    /// Consumes the live permission after the UI answered it.
    pub fn answered(&mut self, now: Instant) -> bool {
        if self.live_permission().is_none() {
            return false;
        }
        self.permission = None;
        self.set(Status::Running, now);
        true
    }

    fn finish(&mut self, status: Status, verified: bool, now: Instant) {
        self.turn_finished = Some(now);
        self.set(status, now);
        if verified {
            self.permission = None;
        }
    }

    fn set(&mut self, status: Status, now: Instant) {
        if self.status != status {
            self.status = status;
            self.status_changed = now;
        }
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

    #[test]
    fn unverified_events_change_status_but_never_the_permission() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), false, now);
        assert_eq!(s.status, Status::NeedsYou);
        assert_eq!(s.live_permission(), None);

        s.apply(&ev(PERM), true, now);
        let key = s.permission.clone();
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#), false, now);
        s.apply(&ev(RAN), false, now);
        s.apply(&ev(r#"{"event":"stop"}"#), false, now);
        assert_eq!(s.permission, key, "forged events leave the verified request alone");
        assert_eq!(s.status, Status::Done);
        assert_eq!(s.live_permission(), None, "and an answer needs the request to still block");
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
        assert!(!s.answered(now));
        s.apply(&ev(PERM), true, now);
        assert!(s.answered(now));
        assert_eq!(s.status, Status::Running);
        assert!(!s.answered(now));
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
    fn long_prompts_are_cut() {
        assert_eq!(one_line(&"x".repeat(500)).chars().count(), MAX_PROMPT_CHARS);
        assert_eq!(one_line("  hi \n there  "), "hi there");
    }
}
