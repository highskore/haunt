//! Task, todo and subagent progress of one agent session.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use crate::event::{AgentEvent, EventKind};

// Any program can feed events, so every list has a hard cap.
const MAX_TASKS: usize = 200;
const MAX_SUBAGENTS: usize = 12;
const MAX_SPAWNS: usize = 16;
const MAX_TODO_OWNERS: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskState {
    Pending,
    InProgress,
    Completed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Task {
    pub id: String,
    pub subject: String,
    pub state: TaskState,
    /// The subagent that owns the task; `None` for the main agent.
    pub owner: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Subagent {
    pub id: String,
    pub kind: String,
    pub description: Option<String>,
    pub running: bool,
    pub started: Instant,
    pub duration: Option<Duration>,
    pub tools: u64,
}

impl Subagent {
    pub fn elapsed(&self, now: Instant) -> Duration {
        self.duration.unwrap_or_else(|| now.saturating_duration_since(self.started))
    }
}

#[derive(Debug, Clone, Default)]
pub struct Progress {
    pub tasks: Vec<Task>,
    pub subagents: Vec<Subagent>,
    /// The latest TodoWrite `(done, total)` per owner.
    todos: Vec<(Option<String>, u64, u64)>,
    /// `(agent_type, description)` of Agent calls not yet matched to a SubagentStart, which has no description.
    spawns: VecDeque<(Option<String>, String)>,
}

impl Progress {
    /// Applies one event; returns whether anything changed.
    pub fn apply(&mut self, e: &AgentEvent, now: Instant) -> bool {
        let owner = e.agent_id.clone();
        match &e.kind {
            EventKind::TaskCreated { task_id, subject } => {
                if self.tasks.len() >= MAX_TASKS || self.tasks.iter().any(|t| &t.id == task_id) {
                    return false;
                }
                let subject = subject.clone().unwrap_or_else(|| task_id.clone());
                self.tasks.push(Task { id: task_id.clone(), subject, state: TaskState::Pending, owner });
                true
            }
            EventKind::TaskUpdated { task_id, status } => {
                let state = match status.as_str() {
                    "deleted" => {
                        let before = self.tasks.len();
                        self.tasks.retain(|t| &t.id != task_id);
                        return self.tasks.len() != before;
                    }
                    "pending" => TaskState::Pending,
                    "in_progress" => TaskState::InProgress,
                    "completed" => TaskState::Completed,
                    _ => return false,
                };
                let full = self.tasks.len() >= MAX_TASKS;
                match self.tasks.iter_mut().find(|t| &t.id == task_id) {
                    Some(t) if t.state == state => false,
                    Some(t) => {
                        t.state = state;
                        true
                    }
                    None if full => false,
                    // The task was created before haunt started listening.
                    None => {
                        self.tasks.push(Task { id: task_id.clone(), subject: task_id.clone(), state, owner });
                        true
                    }
                }
            }
            EventKind::TodosWritten { count: Some(total), done } => {
                let entry = (owner.clone(), (*done).unwrap_or(0).min(*total), *total);
                let full = self.todos.len() >= MAX_TODO_OWNERS;
                match self.todos.iter_mut().find(|t| t.0 == owner) {
                    Some(t) if *t == entry => false,
                    Some(t) => {
                        *t = entry;
                        true
                    }
                    None if full => false,
                    None => {
                        self.todos.push(entry);
                        true
                    }
                }
            }
            EventKind::SubagentSpawn { description: Some(d) } => {
                if self.spawns.len() >= MAX_SPAWNS {
                    self.spawns.pop_front();
                }
                self.spawns.push_back((e.agent_type.clone(), d.clone()));
                false
            }
            EventKind::SubagentStart => {
                let Some(id) = owner else { return false };
                if self.subagent(&id).is_some() {
                    return false;
                }
                let kind = e.agent_type.clone().unwrap_or_else(|| "agent".to_owned());
                let description = self.take_spawn(&kind);
                self.subagents.push(Subagent { id, kind, description, running: true, started: now, duration: None, tools: 0 });
                self.trim();
                true
            }
            EventKind::SubagentStop => {
                let Some(s) = owner.and_then(|id| self.subagent(&id)) else { return false };
                if !s.running {
                    return false;
                }
                s.running = false;
                s.duration = Some(now.saturating_duration_since(s.started));
                true
            }
            // The parent's Agent result: exact id, final counts and description.
            EventKind::SubagentResult { description, tool_count, duration_ms } => {
                let Some(s) = owner.and_then(|id| self.subagent(&id)) else { return false };
                if s.description.is_none() {
                    s.description = description.clone();
                }
                if let Some(n) = tool_count {
                    s.tools = *n;
                }
                if let Some(ms) = duration_ms {
                    s.duration = Some(Duration::from_millis(*ms));
                }
                s.running = false;
                true
            }
            EventKind::SubagentTool { .. } => {
                let Some(s) = owner.and_then(|id| self.subagent(&id)) else { return false };
                s.tools += 1;
                true
            }
            _ => false,
        }
    }

    /// `(done, total)` for the main agent (`None`) or a subagent: tasks first, else the latest todo list.
    pub fn counts(&self, owner: Option<&str>) -> Option<(u64, u64)> {
        let mine = self.tasks.iter().filter(|t| t.owner.as_deref() == owner);
        let (done, total) = mine.fold((0, 0), |(d, n), t| (d + u64::from(t.state == TaskState::Completed), n + 1));
        if total > 0 {
            return Some((done, total));
        }
        self.todos.iter().find(|t| t.0.as_deref() == owner && t.2 > 0).map(|t| (t.1, t.2))
    }

    /// The subject of the main agent's latest in-progress task.
    pub fn current_task(&self) -> Option<&str> {
        let mut main = self.tasks.iter().rev().filter(|t| t.owner.is_none());
        main.find(|t| t.state == TaskState::InProgress).map(|t| t.subject.as_str())
    }

    /// A new user turn drops finished subagents.
    pub fn new_turn(&mut self) {
        self.subagents.retain(|s| s.running);
        self.spawns.clear();
    }

    fn subagent(&mut self, id: &str) -> Option<&mut Subagent> {
        self.subagents.iter_mut().find(|s| s.id == id)
    }

    fn take_spawn(&mut self, kind: &str) -> Option<String> {
        let i = self.spawns.iter().position(|(t, _)| t.as_deref().is_none_or(|t| t == kind))?;
        self.spawns.remove(i).map(|(_, d)| d)
    }

    fn trim(&mut self) {
        while self.subagents.len() > MAX_SUBAGENTS {
            let i = self.subagents.iter().position(|s| !s.running).unwrap_or(0);
            self.subagents.remove(i);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::parse_osc;

    fn ev(json: &str) -> AgentEvent {
        let body = format!(r#"{{"v":1,{}"#, &json[1..]);
        parse_osc("haunt://cli-agent", &body).expect("valid event")
    }

    fn t0() -> Instant {
        Instant::now()
    }

    #[test]
    fn main_and_subagent_tasks_count_separately() {
        let (mut p, now) = (Progress::default(), t0());
        for e in [
            r#"{"event":"task_created","task_id":"1","task_subject":"count files"}"#,
            r#"{"event":"task_created","task_id":"2","task_subject":"report"}"#,
            r#"{"event":"task_created","task_id":"3","task_subject":"sub-step","agent_id":"a1"}"#,
            r#"{"event":"task_updated","task_id":"1","task_status":"in_progress"}"#,
            r#"{"event":"task_updated","task_id":"3","task_status":"completed","agent_id":"a1"}"#,
        ] {
            assert!(p.apply(&ev(e), now), "{e}");
        }
        assert_eq!(p.current_task(), Some("count files"));
        assert!(p.apply(&ev(r#"{"event":"task_updated","task_id":"1","task_status":"completed"}"#), now));
        assert_eq!(p.counts(None), Some((1, 2)));
        assert_eq!(p.counts(Some("a1")), Some((1, 1)));
        assert_eq!(p.counts(Some("nobody")), None);
        assert_eq!(p.current_task(), None);
    }

    #[test]
    fn repeated_status_is_no_change_and_deleted_removes() {
        let (mut p, now) = (Progress::default(), t0());
        p.apply(&ev(r#"{"event":"task_created","task_id":"1","task_subject":"a"}"#), now);
        p.apply(&ev(r#"{"event":"task_updated","task_id":"1","task_status":"in_progress"}"#), now);
        assert!(!p.apply(&ev(r#"{"event":"task_updated","task_id":"1","task_status":"in_progress"}"#), now));
        assert!(p.apply(&ev(r#"{"event":"task_updated","task_id":"1","task_status":"deleted"}"#), now));
        assert!(p.tasks.is_empty());
        assert!(!p.apply(&ev(r#"{"event":"task_updated","task_id":"1","task_status":"bogus"}"#), now));
    }

    #[test]
    fn update_for_unknown_task_inserts_it() {
        let (mut p, now) = (Progress::default(), t0());
        assert!(p.apply(&ev(r#"{"event":"task_updated","task_id":"9","task_status":"completed"}"#), now));
        assert_eq!(p.tasks[0].state, TaskState::Completed);
        assert_eq!(p.counts(None), Some((1, 1)));
    }

    #[test]
    fn todos_count_when_there_are_no_tasks() {
        let (mut p, now) = (Progress::default(), t0());
        assert!(p.apply(&ev(r#"{"event":"todos_written","tool_count":4,"todos_done":2,"agent_id":"a1"}"#), now));
        assert!(!p.apply(&ev(r#"{"event":"todos_written","tool_count":4,"todos_done":2,"agent_id":"a1"}"#), now));
        assert_eq!(p.counts(Some("a1")), Some((2, 4)));
        assert_eq!(p.counts(None), None);
        p.apply(&ev(r#"{"event":"todos_written","tool_count":3,"todos_done":9}"#), now);
        assert_eq!(p.counts(None), Some((3, 3)));
        p.apply(&ev(r#"{"event":"task_created","task_id":"1"}"#), now);
        assert_eq!(p.counts(None), Some((0, 1)));
    }

    #[test]
    fn subagent_lifecycle_takes_spawn_description_and_result() {
        let (mut p, now) = (Progress::default(), t0());
        assert!(!p.apply(&ev(r#"{"event":"subagent_spawn","agent_type":"Explore","description":"Trace validateSession"}"#), now));
        assert!(p.apply(&ev(r#"{"event":"subagent_start","agent_id":"a1","agent_type":"Explore"}"#), now));
        assert_eq!(p.subagents[0].description.as_deref(), Some("Trace validateSession"));
        assert!(p.subagents[0].running);
        assert!(p.apply(&ev(r#"{"event":"subagent_tool","agent_id":"a1","tool_name":"Read"}"#), now));
        assert_eq!(p.subagents[0].tools, 1);
        assert!(p.apply(&ev(r#"{"event":"subagent_result","agent_id":"a1","tool_count":7,"duration_ms":4200}"#), now));
        let s = &p.subagents[0];
        assert!(!s.running);
        assert_eq!(s.tools, 7);
        assert_eq!(s.elapsed(now + Duration::from_secs(99)).as_millis(), 4200);
    }

    #[test]
    fn stop_freezes_elapsed() {
        let (mut p, now) = (Progress::default(), t0());
        p.apply(&ev(r#"{"event":"subagent_start","agent_id":"a1"}"#), now);
        assert_eq!(p.subagents[0].elapsed(now + Duration::from_secs(5)), Duration::from_secs(5));
        assert!(p.apply(&ev(r#"{"event":"subagent_stop","agent_id":"a1"}"#), now + Duration::from_secs(8)));
        assert!(!p.apply(&ev(r#"{"event":"subagent_stop","agent_id":"a1"}"#), now + Duration::from_secs(9)));
        assert_eq!(p.subagents[0].elapsed(now + Duration::from_secs(60)), Duration::from_secs(8));
    }

    #[test]
    fn spawn_description_matches_by_type() {
        let (mut p, now) = (Progress::default(), t0());
        p.apply(&ev(r#"{"event":"subagent_spawn","agent_type":"builder","description":"build it"}"#), now);
        p.apply(&ev(r#"{"event":"subagent_spawn","agent_type":"Explore","description":"look around"}"#), now);
        p.apply(&ev(r#"{"event":"subagent_start","agent_id":"e1","agent_type":"Explore"}"#), now);
        p.apply(&ev(r#"{"event":"subagent_start","agent_id":"b1","agent_type":"builder"}"#), now);
        assert_eq!(p.subagents[0].description.as_deref(), Some("look around"));
        assert_eq!(p.subagents[1].description.as_deref(), Some("build it"));
    }

    #[test]
    fn new_turn_clears_finished_subagents_only() {
        let (mut p, now) = (Progress::default(), t0());
        p.apply(&ev(r#"{"event":"subagent_start","agent_id":"a1","agent_type":"Explore"}"#), now);
        p.apply(&ev(r#"{"event":"subagent_start","agent_id":"a2","agent_type":"Explore"}"#), now);
        p.apply(&ev(r#"{"event":"subagent_stop","agent_id":"a1"}"#), now);
        p.new_turn();
        assert_eq!(p.subagents.len(), 1);
        assert_eq!(p.subagents[0].id, "a2");
    }

    #[test]
    fn events_without_ids_are_ignored() {
        let (mut p, now) = (Progress::default(), t0());
        assert!(!p.apply(&ev(r#"{"event":"subagent_start"}"#), now));
        assert!(!p.apply(&ev(r#"{"event":"subagent_stop","agent_id":"missing"}"#), now));
        assert!(!p.apply(&ev(r#"{"event":"subagent_tool","tool_name":"Read"}"#), now));
    }

    #[test]
    fn caps_hold_against_event_floods() {
        let (mut p, now) = (Progress::default(), t0());
        for i in 0..30 {
            p.apply(&ev(&format!(r#"{{"event":"subagent_start","agent_id":"a{i}","agent_type":"x"}}"#)), now);
        }
        for i in 0..500 {
            p.apply(&ev(&format!(r#"{{"event":"task_created","task_id":"{i}","task_subject":"t"}}"#)), now);
        }
        for i in 0..100 {
            p.apply(&ev(&format!(r#"{{"event":"todos_written","tool_count":1,"agent_id":"a{i}"}}"#)), now);
        }
        assert_eq!(p.subagents.len(), 12);
        assert_eq!(p.subagents[0].id, "a18");
        assert_eq!(p.tasks.len(), 200);
        assert_eq!(p.todos.len(), 32);
    }
}
