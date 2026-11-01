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
    /// The command or file path exactly as the hook sent it; shown only through `preview`.
    pub input: Option<String>,
    pub tool_use_id: Option<String>,
    /// The Bash command exactly as sent, for allow rules.
    pub raw_command: Option<String>,
    /// The hook's cwd, from the same verified event.
    pub cwd: Option<String>,
    /// The `Session::generation` of the NeedsYou episode that created it.
    generation: u64,
    /// The user typed into the surface, so the terminal is answering; it only waits for its outcome.
    in_terminal: bool,
}

/// How a verified permission request ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Outcome {
    AllowedInHaunt,
    DeniedInHaunt,
    /// The matching call ran, so it was allowed at the terminal prompt.
    AnsweredInTerminal,
    Superseded,
}

impl Permission {
    /// None when the input is missing: the user has to answer in the terminal then.
    fn from_call(t: &ToolCall, cwd: Option<String>, generation: u64) -> Option<Self> {
        let input = raw_input(t)?;
        Some(Self {
            tool: t.tool_name.clone(),
            input: Some(input),
            tool_use_id: t.tool_use_id.clone(),
            raw_command: t.raw_command.clone(),
            cwd,
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

    /// A multi-line input, or one with control or invisible characters: what runs may not be what
    /// a one-line preview suggests, so it is answered only in the terminal.
    pub fn suspicious(&self) -> bool {
        self.input.as_deref().is_some_and(|i| i.chars().any(crate::event::is_hidden))
    }
}

fn raw_input(t: &ToolCall) -> Option<String> {
    t.raw_command.clone().or_else(|| t.raw_file_path.clone())
}

#[derive(Debug, Clone)]
pub struct Session {
    pub is_agent: bool,
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
}

impl Session {
    pub fn new(now: Instant) -> Self {
        Self {
            is_agent: false,
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
        if verified
            && let Some(c) = e.cwd.as_ref().filter(|c| c.starts_with('/'))
            && self.cwd.as_ref() != Some(c)
        {
            self.cwd = Some(c.clone());
            changed = true;
        }

        match &e.kind {
            EventKind::PromptSubmit { query } => {
                self.prompt = query.as_deref().map(one_line);
                self.progress.new_turn();
                self.turn_started = Some(now);
                self.turn_finished = None;
                self.set(Status::Running, now);
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
                        self.end_permission(Outcome::AnsweredInTerminal);
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
                    && let Some(mut p) = Permission::from_call(tool, e.cwd.clone(), self.generation)
                {
                    let start = self.recent_starts.iter().rev().find(|s| p.tool_use_id.is_none() && p.matches(s, false));
                    p.tool_use_id = start.and_then(|s| s.tool_use_id.clone());
                    self.permission = Some(p);
                }
            }
            EventKind::Notification { notification_type: Some(t), .. } if t == "permission_prompt" => {
                self.set(Status::NeedsYou, now);
            }
            EventKind::Stop => self.finish(Status::Done, now),
            // Names the official Warp plugin uses; status only.
            EventKind::Unknown { event } => match event.as_str() {
                "stop_failure" => self.finish(Status::Failed, now),
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

    /// Consumes the live permission if `key` names it; false for a stale or unknown key, and for a
    /// suspicious request, which stays live for the terminal to answer.
    pub fn answer(&mut self, key: u64, allow: bool, now: Instant) -> bool {
        if self.live_permission().is_none_or(|p| p.key() != key || p.suspicious()) {
            return false;
        }
        self.end_permission(if allow { Outcome::AllowedInHaunt } else { Outcome::DeniedInHaunt });
        self.set(Status::Running, now);
        true
    }

    /// Ends the request, if any, as superseded: the surface is going away.
    pub fn close(&mut self) {
        self.end_permission(Outcome::Superseded);
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
            self.ended.push((p, outcome));
        }
    }

    fn finish(&mut self, status: Status, now: Instant) {
        self.turn_finished = Some(now);
        self.set(status, now);
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
        let p = Permission { tool: "Bash".into(), input: Some("a\u{202e}b".into()), tool_use_id: None, raw_command: None, cwd: None, generation: 0, in_terminal: false };
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
        assert_eq!(s.take_ended().last().map(|(_, o)| *o), Some(Outcome::AnsweredInTerminal));
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
        assert_eq!(s.take_ended().iter().map(|(_, o)| *o).collect::<Vec<_>>(), [Outcome::AnsweredInTerminal]);

        s.apply(&ev(PERM), true, now);
        s.user_input();
        s.apply(&ev(r#"{"event":"stop"}"#), true, now);
        assert_eq!(s.take_ended().iter().map(|(_, o)| *o).collect::<Vec<_>>(), [Outcome::Superseded], "denied at the terminal");
        assert!(!s.user_input(), "nothing pending");
    }

    #[test]
    fn a_stale_key_is_refused_after_the_prompt_changed() {
        let (mut s, now) = running();
        s.apply(&ev(PERM), true, now);
        let old = s.live_permission().unwrap().key();
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#), true, now);
        assert!(!s.answer(old, true, now));
        assert_eq!(s.status, Status::NeedsYou, "the refused answer changed nothing");
        let new = s.live_permission().unwrap().key();
        assert_ne!(old, new);
        assert!(s.answer(new, false, now));
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
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(RAN), true, now);
        answer(&mut s, true);
        answer(&mut s, false);
        s.apply(&ev(PERM), true, now);
        s.apply(&ev(r#"{"event":"stop"}"#), false, now);
        s.apply(&ev(PERM), false, now);
        s.close();
        let ended = s.take_ended();
        let outcomes: Vec<_> = ended.iter().map(|(_, o)| *o).collect();
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
    fn long_prompts_are_cut() {
        assert_eq!(one_line(&"x".repeat(500)).chars().count(), MAX_PROMPT_CHARS);
        assert_eq!(one_line("  hi \n there  "), "hi there");
    }
}
