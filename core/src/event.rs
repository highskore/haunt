//! v1 hook events: OSC 777 `notify;<title>;<body>` bodies and socket lines share one JSON envelope.

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
    pub truncated: bool,
    pub kind: EventKind,
}

/// The `tool_name` and `tool_input` preview of one tool call.
#[derive(Debug, Clone, PartialEq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ToolCall {
    pub tool_name: String,
    pub tool_use_id: Option<String>,
    pub command: Option<String>,
    pub url: Option<String>,
    pub file_path: Option<String>,
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
    ToolStart { tool: ToolCall },
    ToolDone { tool: ToolCall },
    ToolFailed { tool: ToolCall },
    ToolRan { tool: ToolCall },
    PermissionSeen { tool: ToolCall },
    Notification { notification_type: Option<String>, message: Option<String> },
    PlanExit { summary: Option<String> },
    QuestionAnswered { summary: Option<String> },
    TodosWritten { count: Option<u64>, done: Option<u64> },
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
    parse_body(body)
}

/// Parses one v1 event body, from OSC 777 or a socket line.
pub fn parse_body(body: &str) -> Result<AgentEvent, ParseError> {
    if body.chars().any(char::is_control) {
        return Err(ParseError::ControlCharacter);
    }
    parse_value(&parse_json(body)?)
}

fn parse_json(body: &str) -> Result<Value, ParseError> {
    serde_json::from_str(body).map_err(|e| ParseError::InvalidJson { reason: e.to_string() })
}

fn missing(field: &str) -> ParseError {
    ParseError::MissingField { field: field.to_owned() }
}

// JSON escapes can still decode to control characters, so every string is cleaned after decoding.
/// Drops control and format (Cf) characters, so bidi overrides and zero-widths cannot disguise text.
pub fn clean(s: &str) -> String {
    s.chars()
        .filter_map(|c| if c.is_whitespace() && !is_format(c) { Some(' ') } else { (!c.is_control() && !is_format(c)).then_some(c) })
        .collect()
}

/// Unicode General_Category Cf (Unicode 16).
pub fn is_format(c: char) -> bool {
    matches!(c as u32,
        0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x890..=0x891 | 0x8E2 | 0x180E
        | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB
        | 0x110BD | 0x110CD | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A
        | 0xE0001 | 0xE0020..=0xE007F)
}

fn str_field(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).map(clean)
}

fn parse_value(v: &Value) -> Result<AgentEvent, ParseError> {
    let version = v.get("v").and_then(Value::as_i64).unwrap_or(0);
    if version != 1 {
        return Err(ParseError::UnsupportedVersion { version });
    }
    let s = |k: &str| str_field(v, k);
    let n = |k: &str| v.get(k).and_then(Value::as_u64);
    let req = |k: &str| s(k).ok_or_else(|| missing(k));
    let input = |k: &str| v.get("tool_input").and_then(|i| str_field(i, k));
    let tool = || -> Result<ToolCall, ParseError> {
        Ok(ToolCall {
            tool_name: req("tool_name")?,
            tool_use_id: s("tool_use_id"),
            command: input("command"),
            url: input("url"),
            file_path: input("file_path"),
        })
    };

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
        "tool_start" => EventKind::ToolStart { tool: tool()? },
        "tool_done" => EventKind::ToolDone { tool: tool()? },
        "tool_failed" => EventKind::ToolFailed { tool: tool()? },
        "tool_ran" => EventKind::ToolRan { tool: tool()? },
        "permission_seen" => EventKind::PermissionSeen { tool: tool()? },
        "notification" => EventKind::Notification { notification_type: s("notification_type"), message: s("message") },
        "plan_exit" => EventKind::PlanExit { summary: s("summary") },
        "question_answered" => EventKind::QuestionAnswered { summary: s("summary") },
        "todos_written" => EventKind::TodosWritten { count: n("tool_count"), done: n("todos_done") },
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
        truncated: v.get("truncated").and_then(Value::as_bool).unwrap_or(false),
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
            Self::ToolStart { .. } => "tool_start",
            Self::ToolDone { .. } => "tool_done",
            Self::ToolFailed { .. } => "tool_failed",
            Self::ToolRan { .. } => "tool_ran",
            Self::PermissionSeen { .. } => "permission_seen",
            Self::Notification { .. } => "notification",
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
        let e = parse_osc("haunt://cli-agent", &format!(r#"{{{B},"event":"tool_ran","tool_name":"Bash","tool_use_id":"tu1","tool_input":{{"command":"ls"}},"truncated":true}}"#)).unwrap();
        let tool = ToolCall { tool_name: "Bash".into(), tool_use_id: Some("tu1".into()), command: Some("ls".into()), ..Default::default() };
        assert_eq!(e.kind, EventKind::ToolRan { tool });
        assert!(e.truncated);
    }

    #[test]
    fn parses_new_variants() {
        let p = |body: &str| parse_osc("haunt://cli-agent", &format!("{{{B},{body}}}")).unwrap().kind;
        assert_eq!(
            p(r#""event":"tool_start","tool_name":"WebFetch","tool_input":{"url":"https://x.dev"}"#),
            EventKind::ToolStart { tool: ToolCall { tool_name: "WebFetch".into(), url: Some("https://x.dev".into()), ..Default::default() } }
        );
        assert!(matches!(p(r#""event":"tool_failed","tool_name":"Bash","tool_input":{}"#), EventKind::ToolFailed { .. }));
        assert!(matches!(p(r#""event":"tool_done","tool_name":"Bash","tool_input":{}"#), EventKind::ToolDone { .. }));
        assert_eq!(
            p(r#""event":"permission_seen","tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#),
            EventKind::PermissionSeen { tool: ToolCall { tool_name: "Bash".into(), command: Some("rm -rf build".into()), ..Default::default() } }
        );
        assert_eq!(
            p(r#""event":"notification","notification_type":"permission_prompt","message":"m""#),
            EventKind::Notification { notification_type: Some("permission_prompt".into()), message: Some("m".into()) }
        );
        assert_eq!(p(r#""event":"todos_written","tool_count":3,"todos_done":1"#), EventKind::TodosWritten { count: Some(3), done: Some(1) });
    }

    #[test]
    fn rejects_other_titles_and_control_chars() {
        assert!(matches!(parse_osc("Build done", "{}"), Err(ParseError::NotAgentTitle { .. })));
        assert_eq!(parse_osc("haunt://cli-agent", "{\"v\":1,\u{1b}}"), Err(ParseError::ControlCharacter));
    }

    #[test]
    fn escaped_control_chars_are_stripped() {
        let e = parse_body(r#"{"v":1,"event":"prompt_submit","query":"a\u001b[2Jb\u0007c\nd"}"#).unwrap();
        assert_eq!(e.kind, EventKind::PromptSubmit { query: Some("a[2Jbc d".into()) });
    }

    #[test]
    fn format_characters_are_stripped() {
        let raw = "{\"v\":1,\"event\":\"prompt_submit\",\"query\":\"rm -rf \u{202E}/ \u{2066}x\u{2069}\u{200B}\u{200F}\u{2060}\u{FEFF}\u{AD}\u{E0041}y\"}";
        assert_eq!(parse_body(raw).unwrap().kind, EventKind::PromptSubmit { query: Some("rm -rf / xy".into()) });
        assert!(!is_format('a') && !is_format('é') && !is_format('👻'));
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
