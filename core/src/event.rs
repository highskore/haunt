//! OSC 777 `notify;<title>;<body>` hook events from the Claude Code plugin.

use serde_json::Value;

pub const TITLES: [&str; 2] = ["haunt://cli-agent", "warp://cli-agent"];

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct AgentEvent {
    pub agent: String,
    pub session_id: Option<String>,
    pub cwd: Option<String>,
    pub agent_id: Option<String>,
    pub agent_type: Option<String>,
    pub nonce: Option<String>,
    pub kind: EventKind,
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum EventKind {
    SessionStart { plugin_version: Option<String> },
    PromptSubmit { query: Option<String> },
    TaskCreated { task_id: String, subject: Option<String> },
    TaskUpdated { task_id: String, status: String },
    SubagentSpawn { description: Option<String> },
    SubagentStart,
    SubagentStop,
    SubagentResult { description: Option<String>, tool_count: Option<u64>, duration_ms: Option<u64> },
    SubagentTool { tool_name: String },
    ToolRan { tool_name: String, command: Option<String>, file_path: Option<String> },
    PlanExit { summary: Option<String> },
    QuestionAnswered { summary: Option<String> },
    TodosWritten { count: Option<u64> },
    FileEdited { tool_name: Option<String>, file_path: Option<String> },
    Stop,
    Unknown { event: String },
}

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
#[cfg_attr(feature = "ffi", derive(uniffi::Error))]
pub enum ParseError {
    #[error("not a cli-agent title: {title}")]
    NotAgentTitle { title: String },
    #[error("control character in body")]
    ControlCharacter,
    #[error("invalid json: {reason}")]
    InvalidJson { reason: String },
    #[error("unsupported envelope version {version}")]
    UnsupportedVersion { version: i64 },
    #[error("missing field {field}")]
    MissingField { field: String },
}

/// Parses one notification; `title` and `body` are as libghostty reports them.
pub fn parse_osc(title: &str, body: &str) -> Result<AgentEvent, ParseError> {
    if !TITLES.contains(&title) {
        return Err(ParseError::NotAgentTitle { title: title.to_owned() });
    }
    if body.chars().any(char::is_control) {
        return Err(ParseError::ControlCharacter);
    }
    let v: Value =
        serde_json::from_str(body).map_err(|e| ParseError::InvalidJson { reason: e.to_string() })?;
    let version = v.get("v").and_then(Value::as_i64).unwrap_or(0);
    if version != 1 {
        return Err(ParseError::UnsupportedVersion { version });
    }
    let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
    let n = |k: &str| v.get(k).and_then(Value::as_u64);
    let req = |k: &str| s(k).ok_or_else(|| ParseError::MissingField { field: k.to_owned() });
    let input = |k: &str| v.get("tool_input").and_then(|i| i.get(k)).and_then(Value::as_str).map(str::to_owned);

    let event = req("event")?;
    let kind = match event.as_str() {
        "session_start" => EventKind::SessionStart { plugin_version: s("plugin_version") },
        "prompt_submit" => EventKind::PromptSubmit { query: s("query") },
        "task_created" => EventKind::TaskCreated { task_id: req("task_id")?, subject: s("task_subject") },
        "task_updated" => EventKind::TaskUpdated { task_id: req("task_id")?, status: req("task_status")? },
        "subagent_spawn" => EventKind::SubagentSpawn { description: s("description") },
        "subagent_start" => EventKind::SubagentStart,
        "subagent_stop" => EventKind::SubagentStop,
        "subagent_result" => EventKind::SubagentResult {
            description: s("description"),
            tool_count: n("tool_count"),
            duration_ms: n("duration_ms"),
        },
        "subagent_tool" => EventKind::SubagentTool { tool_name: req("tool_name")? },
        "tool_ran" => EventKind::ToolRan {
            tool_name: req("tool_name")?,
            command: input("command"),
            file_path: input("file_path"),
        },
        "plan_exit" => EventKind::PlanExit { summary: s("summary") },
        "question_answered" => EventKind::QuestionAnswered { summary: s("summary") },
        "todos_written" => EventKind::TodosWritten { count: n("tool_count") },
        "file_edited" => EventKind::FileEdited { tool_name: s("tool_name"), file_path: input("file_path") },
        "stop" => EventKind::Stop,
        _ => EventKind::Unknown { event },
    };
    Ok(AgentEvent {
        agent: s("agent").unwrap_or_else(|| "claude".to_owned()),
        session_id: s("session_id"),
        cwd: s("cwd"),
        agent_id: s("agent_id"),
        agent_type: s("agent_type"),
        nonce: s("nonce"),
        kind,
    })
}

impl EventKind {
    pub fn name(&self) -> &str {
        match self {
            Self::SessionStart { .. } => "session_start",
            Self::PromptSubmit { .. } => "prompt_submit",
            Self::TaskCreated { .. } => "task_created",
            Self::TaskUpdated { .. } => "task_updated",
            Self::SubagentSpawn { .. } => "subagent_spawn",
            Self::SubagentStart => "subagent_start",
            Self::SubagentStop => "subagent_stop",
            Self::SubagentResult { .. } => "subagent_result",
            Self::SubagentTool { .. } => "subagent_tool",
            Self::ToolRan { .. } => "tool_ran",
            Self::PlanExit { .. } => "plan_exit",
            Self::QuestionAnswered { .. } => "question_answered",
            Self::TodosWritten { .. } => "todos_written",
            Self::FileEdited { .. } => "file_edited",
            Self::Stop => "stop",
            Self::Unknown { event } => event,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const B: &str = r#""v":1,"agent":"claude","session_id":"s1","cwd":"/tmp""#;

    #[test]
    fn parses_task_created() {
        let e = parse_osc("warp://cli-agent", &format!(r#"{{{B},"event":"task_created","task_id":"3","task_subject":"step 3"}}"#)).unwrap();
        assert_eq!(e.kind, EventKind::TaskCreated { task_id: "3".into(), subject: Some("step 3".into()) });
        assert_eq!(e.session_id.as_deref(), Some("s1"));
    }

    #[test]
    fn parses_tool_ran_input() {
        let e = parse_osc("haunt://cli-agent", &format!(r#"{{{B},"event":"tool_ran","tool_name":"Bash","tool_input":{{"command":"ls"}}}}"#)).unwrap();
        assert_eq!(e.kind, EventKind::ToolRan { tool_name: "Bash".into(), command: Some("ls".into()), file_path: None });
    }

    #[test]
    fn rejects_other_titles_and_control_chars() {
        assert!(matches!(parse_osc("Build done", "{}"), Err(ParseError::NotAgentTitle { .. })));
        assert_eq!(parse_osc("haunt://cli-agent", "{\"v\":1,\u{1b}}"), Err(ParseError::ControlCharacter));
    }

    #[test]
    fn rejects_bad_version_and_truncated_json() {
        assert_eq!(parse_osc("haunt://cli-agent", r#"{"v":2,"event":"stop"}"#), Err(ParseError::UnsupportedVersion { version: 2 }));
        assert!(matches!(parse_osc("haunt://cli-agent", r#"{"v":1,"event":"st"#), Err(ParseError::InvalidJson { .. })));
    }

    #[test]
    fn unknown_events_pass_through() {
        let e = parse_osc("haunt://cli-agent", r#"{"v":1,"event":"new_thing"}"#).unwrap();
        assert_eq!(e.kind.name(), "new_thing");
    }
}
