//! What the latest agent turn did, for the review screen. Built from verified hook events only, so a
//! line printed into the pty can't invent a passing test.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::event::{Agent, AgentEvent, EventKind};

const MAX_PROMPT_CHARS: usize = 4000;
const MAX_COMMANDS: usize = 200;
const MAX_FILES: usize = 500;
const MAX_TASKS: usize = 100;
const MAX_SUBAGENTS: usize = 50;

/// How a shell command the agent ran ended, as far as its hooks tell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum CommandOutcome {
    Running,
    /// Claude Code reported the call done; its failure hook would have fired on a non-zero exit.
    Passed,
    Failed,
    /// It ran, but the agent's hooks don't say how it ended (Codex has no failure hook).
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct TurnCommand {
    pub command: String,
    pub outcome: CommandOutcome,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct TurnTask {
    pub subject: String,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct TurnSubagent {
    /// `Explore · trace hooks`: the subagent type and its description, where known.
    pub label: String,
    pub tool_count: Option<u64>,
    pub duration_ms: Option<u64>,
}

/// The surface's latest turn as the review screen shows it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ReviewTurn {
    pub agent: Agent,
    /// Verified prompts seen on this surface, this one included; 0 before the first.
    pub number: u32,
    pub prompt: Option<String>,
    /// The agent's cwd from the latest verified event.
    pub cwd: Option<String>,
    pub started_ms: Option<u64>,
    pub finished_ms: Option<u64>,
    pub failed: bool,
    /// The commit HEAD pointed at when the prompt arrived, to find commits made during the turn.
    pub head_at_start: Option<String>,
    pub tool_count: u32,
    pub edit_count: u32,
    pub tasks: Vec<TurnTask>,
    pub commands: Vec<TurnCommand>,
    /// Files the agent's edit tools reported, in first-edit order.
    pub files: Vec<String>,
    pub subagents: Vec<TurnSubagent>,
}

#[derive(Debug, Clone)]
struct Pending {
    tool_use_id: Option<String>,
    index: usize,
}

#[derive(Debug, Clone, Default)]
pub struct TurnLog {
    pub turn: ReviewTurn,
    running: Vec<Pending>,
    /// Ids of `turn.tasks`, index for index, so the FFI record stays plain.
    task_ids: Vec<String>,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn push_capped<T>(v: &mut Vec<T>, cap: usize, x: T) {
    if v.len() < cap {
        v.push(x);
    }
}

impl TurnLog {
    /// Applies one verified event; `agent` is the session's agent after the event.
    pub fn apply(&mut self, e: &AgentEvent, agent: &Agent) {
        self.apply_at(e, agent, now_ms());
    }

    pub(crate) fn apply_at(&mut self, e: &AgentEvent, agent: &Agent, now: u64) {
        let t = &mut self.turn;
        t.agent = agent.clone();
        if let Some(c) = e.cwd.as_ref().filter(|c| c.starts_with('/')) {
            t.cwd = Some(c.clone());
        }
        match &e.kind {
            EventKind::PromptSubmit { query } => {
                let number = t.number.saturating_add(1);
                *t = ReviewTurn { agent: agent.clone(), number, cwd: t.cwd.clone(), started_ms: Some(now), ..ReviewTurn::default() };
                t.prompt = query.as_ref().map(|q| q.trim().chars().take(MAX_PROMPT_CHARS).collect());
                self.running.clear();
                self.task_ids.clear();
            }
            EventKind::ToolStart { tool } => {
                t.tool_count = t.tool_count.saturating_add(1);
                if tool.tool_name == "Bash"
                    && let Some(c) = &tool.command
                    && t.commands.len() < MAX_COMMANDS
                {
                    t.commands.push(TurnCommand { command: c.clone(), outcome: CommandOutcome::Running });
                    self.running.push(Pending { tool_use_id: tool.tool_use_id.clone(), index: t.commands.len() - 1 });
                }
            }
            EventKind::ToolDone { tool } | EventKind::ToolFailed { tool } if tool.tool_name == "Bash" => {
                let failed = matches!(e.kind, EventKind::ToolFailed { .. });
                // Only Claude Code reports failures, so only its "done" means the command passed.
                let outcome = match (failed, agent) {
                    (true, _) => CommandOutcome::Failed,
                    (false, Agent::Claude) => CommandOutcome::Passed,
                    (false, _) => CommandOutcome::Unknown,
                };
                let commands = &t.commands;
                let at = self.running.iter().position(|p| match (&p.tool_use_id, &tool.tool_use_id) {
                    (Some(a), Some(b)) => a == b,
                    _ => tool.command.as_ref() == Some(&commands[p.index].command),
                });
                if let Some(i) = at {
                    let p = self.running.remove(i);
                    t.commands[p.index].outcome = outcome;
                }
            }
            EventKind::TaskCreated { task_id, subject } => {
                if t.tasks.len() < MAX_TASKS {
                    t.tasks.push(TurnTask { subject: subject.clone().unwrap_or_default(), status: "pending".into() });
                    self.task_ids.push(task_id.clone());
                }
            }
            EventKind::TaskUpdated { task_id, status } => {
                if let Some(i) = self.task_index(task_id) {
                    self.turn.tasks[i].status = status.clone();
                }
            }
            EventKind::FileEdited { file_path, .. } => {
                t.edit_count = t.edit_count.saturating_add(1);
                if let Some(f) = file_path
                    && !t.files.contains(f)
                {
                    push_capped(&mut t.files, MAX_FILES, f.clone());
                }
            }
            EventKind::SubagentResult { description, tool_count, duration_ms } => {
                let label = [e.agent_type.clone(), description.clone()].into_iter().flatten().collect::<Vec<_>>().join(" · ");
                push_capped(&mut t.subagents, MAX_SUBAGENTS, TurnSubagent { label, tool_count: *tool_count, duration_ms: *duration_ms });
            }
            EventKind::Stop => self.finish(now, false),
            EventKind::Unknown { event } if event == "stop_failure" => self.finish(now, true),
            _ => {}
        }
    }

    fn finish(&mut self, now: u64, failed: bool) {
        self.turn.finished_ms = Some(now);
        self.turn.failed = failed;
        for p in self.running.drain(..) {
            self.turn.commands[p.index].outcome = CommandOutcome::Unknown;
        }
    }

    fn task_index(&self, id: &str) -> Option<usize> {
        self.task_ids.iter().position(|t| t == id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::parse_body;

    fn feed(log: &mut TurnLog, agent: &Agent, lines: &[&str]) {
        for (i, l) in lines.iter().enumerate() {
            log.apply_at(&parse_body(&format!(r#"{{"v":1,{l}}}"#)).unwrap(), agent, 1000 + i as u64);
        }
    }

    const BASH: &str = r#""tool_name":"Bash","tool_input":{"command":"#;

    #[test]
    fn records_commands_with_outcomes_from_claude_hooks() {
        let mut log = TurnLog::default();
        feed(&mut log, &Agent::Claude, &[
            r#""event":"prompt_submit","cwd":"/w","query":"add tests""#,
            &format!(r#""event":"tool_start","tool_use_id":"a",{BASH}"swift build"}}"#),
            &format!(r#""event":"tool_done","tool_use_id":"a",{BASH}"swift build"}}"#),
            &format!(r#""event":"tool_start",{BASH}"swift test"}}"#),
            &format!(r#""event":"tool_failed",{BASH}"swift test"}}"#),
            &format!(r#""event":"tool_start","tool_use_id":"c",{BASH}"cargo test"}}"#),
            r#""event":"file_edited","tool_name":"Edit","tool_input":{"file_path":"/w/a.rs"}"#,
            r#""event":"file_edited","tool_name":"Edit","tool_input":{"file_path":"/w/a.rs"}"#,
            r#""event":"task_created","task_id":"1","task_subject":"Write tests""#,
            r#""event":"task_updated","task_id":"1","task_status":"completed""#,
            r#""event":"subagent_result","agent_id":"x","agent_type":"Explore","description":"find call sites","tool_count":7,"duration_ms":41000"#,
            r#""event":"stop""#,
        ]);
        let t = &log.turn;
        assert_eq!((t.number, t.prompt.as_deref(), t.cwd.as_deref()), (1, Some("add tests"), Some("/w")));
        let got: Vec<_> = t.commands.iter().map(|c| (c.command.as_str(), c.outcome)).collect();
        assert_eq!(got, [("swift build", CommandOutcome::Passed), ("swift test", CommandOutcome::Failed), ("cargo test", CommandOutcome::Unknown)]);
        assert_eq!((t.tool_count, t.edit_count, t.files.clone()), (3, 2, vec!["/w/a.rs".to_owned()]));
        assert_eq!(t.tasks, [TurnTask { subject: "Write tests".into(), status: "completed".into() }]);
        assert_eq!(t.subagents[0].label, "Explore · find call sites");
        assert_eq!((t.started_ms, t.finished_ms, t.failed), (Some(1000), Some(1011), false));

        feed(&mut log, &Agent::Claude, &[r#""event":"prompt_submit","query":"again""#]);
        assert_eq!((log.turn.number, log.turn.commands.len(), log.turn.cwd.as_deref()), (2, 0, Some("/w")), "a new turn starts clean");
    }

    #[test]
    fn a_done_without_a_failure_hook_is_not_a_pass() {
        let mut log = TurnLog::default();
        feed(&mut log, &Agent::Codex, &[
            r#""event":"prompt_submit","query":"x""#,
            &format!(r#""event":"tool_start","tool_use_id":"a",{BASH}"cargo test"}}"#),
            &format!(r#""event":"tool_done","tool_use_id":"a",{BASH}"cargo test"}}"#),
        ]);
        assert_eq!(log.turn.commands[0].outcome, CommandOutcome::Unknown);
    }
}
