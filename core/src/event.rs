//! v1 hook events: OSC 777 `notify;<title>;<body>` bodies and socket lines share one JSON envelope.

use crate::wire::{self, Scalar, Str, Wire};

pub const TITLES: [&str; 2] = ["haunt://cli-agent", "warp://cli-agent"];

/// The coding agent behind a session, from the envelope's `agent` id (docs/agent-events.md).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, serde::Serialize, serde::Deserialize)]
#[serde(from = "String", into = "String")]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Agent {
    #[default]
    Claude,
    Codex,
    Other { id: String },
}

impl Agent {
    pub fn id(&self) -> &str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Other { id } => id,
        }
    }

    /// The keys that pick Allow or Deny in this agent's approval prompt; None where haunt doesn't know them.
    /// Claude Code: `1` is "Yes" wherever the highlight is. Codex (0.136 tui keymap): `y` proceeds.
    /// Esc cancels in both, declining the call.
    pub fn answer_bytes(&self, allow: bool) -> Option<&'static [u8]> {
        match (self, allow) {
            (Self::Claude, true) => Some(b"1"),
            (Self::Codex, true) => Some(b"y"),
            (Self::Claude | Self::Codex, false) => Some(b"\x1b"),
            (Self::Other { .. }, _) => None,
        }
    }
}

/// The spec's agent id: 1 to 32 of `a-z`, `0-9` and `-`.
pub fn valid_agent_id(id: &str) -> bool {
    (1..=32).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

impl From<&str> for Agent {
    fn from(id: &str) -> Self {
        match id {
            "claude" => Self::Claude,
            "codex" => Self::Codex,
            id => Self::Other { id: id.to_owned() },
        }
    }
}

impl From<String> for Agent {
    fn from(id: String) -> Self {
        id.as_str().into()
    }
}

impl From<Agent> for String {
    fn from(a: Agent) -> Self {
        a.id().to_owned()
    }
}

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
    /// `command` as sent, before invisible characters were removed; shown only through `visible`.
    pub raw_command: Option<String>,
    pub url: Option<String>,
    pub file_path: Option<String>,
    /// `file_path` as sent.
    pub raw_file_path: Option<String>,
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
    #[error("invalid agent id")]
    InvalidAgent,
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
    parse_line(body).1
}

/// One parse for both: the line's `surface_id` as sent (empty unless 1 to 64 bytes), and its event.
pub(crate) fn parse_line(body: &str) -> (String, Result<AgentEvent, ParseError>) {
    let w = wire::parse(body);
    let surface = match &w {
        Ok(w) => w.surface_id.text().filter(|id| !id.is_empty() && id.len() <= 64).unwrap_or_default().to_owned(),
        Err(_) => String::new(),
    };
    let event = if body.chars().any(char::is_control) {
        Err(ParseError::ControlCharacter)
    } else {
        w.map_err(|e| ParseError::InvalidJson { reason: e.to_string() }).and_then(|w| event_of(&w))
    };
    (surface, event)
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

/// Characters a terminal shows as nothing or as layout: anything but a plain space that is a
/// control, a format (Cf) character, whitespace (Zl and Zp included) or default-ignorable.
pub fn is_hidden(c: char) -> bool {
    c != ' ' && (c.is_control() || is_format(c) || c.is_whitespace() || is_default_ignorable(c))
}

/// Unicode Default_Ignorable_Code_Point (Unicode 16): fonts draw these as nothing, so `ls` and
/// `l\u{115F}s` look the same.
pub fn is_default_ignorable(c: char) -> bool {
    matches!(c as u32,
        0xAD | 0x34F | 0x61C | 0x115F..=0x1160 | 0x17B4..=0x17B5 | 0x180B..=0x180F
        | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x206F | 0x3164 | 0xFE00..=0xFE0F | 0xFEFF
        | 0xFFA0 | 0xFFF0..=0xFFF8 | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0000..=0xE0FFF)
}

/// `s` with nothing hidden: a newline shows as ⏎, a tab as ⇥, and every other hidden character
/// as `\u{…}`, so `ls #\nrm -rf ~` can't pass for a comment.
pub fn visible(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\n' => out.push('⏎'),
            '\t' => out.push('⇥'),
            c if is_hidden(c) => out.push_str(&format!("\\u{{{:x}}}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Unicode General_Category Cf (Unicode 16).
pub fn is_format(c: char) -> bool {
    matches!(c as u32,
        0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x890..=0x891 | 0x8E2 | 0x180E
        | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB
        | 0x110BD | 0x110CD | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A
        | 0xE0001 | 0xE0020..=0xE007F)
}

fn s(f: &Str) -> Option<String> {
    f.text().map(clean)
}

fn req(f: &Str, k: &str) -> Result<String, ParseError> {
    s(f).ok_or_else(|| missing(k))
}

fn event_of(w: &Wire) -> Result<AgentEvent, ParseError> {
    let version = w.v.as_i64().unwrap_or(0);
    if version != 1 {
        return Err(ParseError::UnsupportedVersion { version });
    }
    let n = Scalar::as_u64;
    let raw = |f: &Str| f.text().map(str::to_owned);
    let tool = || -> Result<ToolCall, ParseError> {
        let i = &w.tool_input;
        Ok(ToolCall {
            tool_name: req(&w.tool_name, "tool_name")?,
            tool_use_id: s(&w.tool_use_id),
            command: s(&i.command),
            raw_command: raw(&i.command),
            url: s(&i.url),
            file_path: s(&i.file_path),
            raw_file_path: raw(&i.file_path),
        })
    };

    let event = req(&w.event, "event")?;
    let kind = match event.as_str() {
        "session_start" => EventKind::SessionStart { plugin_version: s(&w.plugin_version) },
        "prompt_submit" => EventKind::PromptSubmit { query: s(&w.query) },
        "task_created" => EventKind::TaskCreated { task_id: req(&w.task_id, "task_id")?, subject: s(&w.task_subject) },
        "task_updated" => {
            EventKind::TaskUpdated { task_id: req(&w.task_id, "task_id")?, status: req(&w.task_status, "task_status")? }
        }
        "subagent_spawn" => EventKind::SubagentSpawn { description: s(&w.description) },
        "subagent_start" => EventKind::SubagentStart,
        "subagent_stop" => EventKind::SubagentStop,
        "subagent_result" => EventKind::SubagentResult {
            description: s(&w.description),
            tool_count: n(w.tool_count),
            duration_ms: n(w.duration_ms),
        },
        "subagent_tool" => EventKind::SubagentTool { tool_name: req(&w.tool_name, "tool_name")? },
        "tool_start" => EventKind::ToolStart { tool: tool()? },
        "tool_done" => EventKind::ToolDone { tool: tool()? },
        "tool_failed" => EventKind::ToolFailed { tool: tool()? },
        "tool_ran" => EventKind::ToolRan { tool: tool()? },
        "permission_seen" => EventKind::PermissionSeen { tool: tool()? },
        "notification" => {
            EventKind::Notification { notification_type: s(&w.notification_type), message: s(&w.message) }
        }
        "plan_exit" => EventKind::PlanExit { summary: s(&w.summary) },
        "question_answered" => EventKind::QuestionAnswered { summary: s(&w.summary) },
        "todos_written" => EventKind::TodosWritten { count: n(w.tool_count), done: n(w.todos_done) },
        "file_edited" => EventKind::FileEdited { tool_name: s(&w.tool_name), file_path: s(&w.tool_input.file_path) },
        "stop" => EventKind::Stop,
        _ => EventKind::Unknown { event },
    };
    // Checked raw: `clean` could turn a disallowed id into an allowed one.
    let agent = match &w.agent {
        Str::Absent => "claude".to_owned(),
        Str::Text(a) if valid_agent_id(a) => a.clone().into_owned(),
        _ => return Err(ParseError::InvalidAgent),
    };
    Ok(AgentEvent {
        agent,
        session_id: s(&w.session_id),
        cwd: s(&w.cwd),
        agent_id: s(&w.agent_id),
        agent_type: s(&w.agent_type),
        nonce: s(&w.nonce),
        truncated: w.truncated.as_bool().unwrap_or(false),
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

    #[test]
    fn answer_bytes_match_the_shared_table() {
        // The macOS app presses only these (macos/tests/answerkey.sh checks its side against the same file).
        let table: serde_json::Value = serde_json::from_str(include_str!("../answer-keys.json")).unwrap();
        for (agent, id) in [(Agent::Claude, "claude"), (Agent::Codex, "codex")] {
            for (allow, key) in [(true, "allow"), (false, "deny")] {
                let want = table[id][key].as_str().unwrap().as_bytes();
                assert_eq!(agent.answer_bytes(allow), Some(want), "{id} {key}");
            }
        }
        assert_eq!(table.as_object().unwrap().len(), 2, "every agent with keys is listed");
    }

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
        let tool = ToolCall { tool_name: "Bash".into(), tool_use_id: Some("tu1".into()), command: Some("ls".into()), raw_command: Some("ls".into()), ..Default::default() };
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
            EventKind::PermissionSeen { tool: ToolCall { tool_name: "Bash".into(), command: Some("rm -rf build".into()), raw_command: Some("rm -rf build".into()), ..Default::default() } }
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
    fn visible_shows_every_hidden_character() {
        assert_eq!(visible("ls #\nrm -rf ~/x"), "ls #⏎rm -rf ~/x");
        assert_eq!(visible("a\tb\r\x1b[2J\u{202e}c\u{200b}\u{a0}d"), "a⇥b\\u{d}\\u{1b}[2J\\u{202e}c\\u{200b}\\u{a0}d");
        assert_eq!(visible("git push -- 'é 👻'"), "git push -- 'é 👻'");
        assert!(!"git push".chars().any(is_hidden));
    }

    #[test]
    fn default_ignorable_and_separator_characters_are_hidden() {
        for c in ['\u{2028}', '\u{2029}', '\u{115F}', '\u{1160}', '\u{3164}', '\u{FFA0}', '\u{FE00}', '\u{FE0F}', '\u{E0100}', '\u{E01EF}', '\u{34F}', '\u{17B4}', '\u{180B}', '\u{FFF0}', '\u{E0FFF}'] {
            assert!(is_hidden(c), "{:x}", c as u32);
            assert_eq!(visible(&format!("l{c}s")), format!("l\\u{{{:x}}}s", c as u32));
        }
        for c in ['a', 'é', '한', '\u{1100}', '\u{3165}', '\u{FFA1}', '\u{E1000}', '👻'] {
            assert!(!is_hidden(c), "{:x}", c as u32);
        }
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

    #[test]
    fn agent_ids_round_trip() {
        for a in [Agent::Claude, Agent::Codex, Agent::Other { id: "aider".into() }] {
            assert_eq!(Agent::from(a.id()), a);
        }
        assert_eq!(parse_body(r#"{"v":1,"event":"stop"}"#).unwrap().agent, "claude", "the legacy hook sends none");
    }

    #[test]
    fn agent_ids_outside_the_spec_are_rejected() {
        let agent = |a: &str| parse_body(&format!(r#"{{"v":1,"agent":{a},"event":"stop"}}"#)).map(|e| e.agent);
        for ok in ["claude", "codex", "my-agent2", &"a".repeat(32)] {
            assert_eq!(agent(&format!("\"{ok}\"")), Ok(ok.to_owned()));
        }
        let long = format!("\"{}\"", "a".repeat(33));
        for bad in ["\"\"", "\"Claude\"", "\"co dex\"", "\"a_b\"", "\"é\"", "\"co\\u200bdex\"", "\"codex\\u0007\"", &long, "1", "null", "[\"codex\"]"] {
            assert_eq!(agent(bad), Err(ParseError::InvalidAgent), "{bad}");
        }
    }

    /// Variants without a name of their own in the parser are listed here, so a new one won't compile
    /// until it is counted, and the spec test then wants an example of it.
    fn variant(k: &EventKind) -> Option<usize> {
        use EventKind::*;
        Some(match k {
            SessionStart { .. } => 0,
            PromptSubmit { .. } => 1,
            TaskCreated { .. } => 2,
            TaskUpdated { .. } => 3,
            SubagentSpawn { .. } => 4,
            SubagentStart => 5,
            SubagentStop => 6,
            SubagentResult { .. } => 7,
            SubagentTool { .. } => 8,
            ToolStart { .. } => 9,
            ToolDone { .. } => 10,
            ToolFailed { .. } => 11,
            ToolRan { .. } => 12,
            PermissionSeen { .. } => 13,
            Notification { .. } => 14,
            PlanExit { .. } => 15,
            QuestionAnswered { .. } => 16,
            TodosWritten { .. } => 17,
            FileEdited { .. } => 18,
            Stop => 19,
            Unknown { .. } => return None,
        })
    }
    const VARIANTS: usize = 20;
    const SPEC_UNKNOWN: [&str; 2] = ["question_asked", "stop_failure"];

    #[test]
    fn the_spec_examples_parse_and_cover_every_event() {
        let spec = include_str!("../../docs/agent-events.md");
        let section = |start: &str, end: &str| spec.split_once(start).and_then(|(_, r)| r.split_once(end)).map(|(s, _)| s).unwrap();
        let table: Vec<&str> = section("| event | fields | core effect |\n", "\n\n")
            .lines()
            .filter_map(|l| l.strip_prefix("| `")?.split_once('`').map(|(name, _)| name))
            .collect();
        let examples: Vec<&str> = section("```jsonl\n", "```").lines().collect();

        let mut names = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for line in &examples {
            let e = parse_body(line).unwrap_or_else(|err| panic!("{line}: {err}"));
            assert!(matches!(Agent::from(e.agent.as_str()), Agent::Claude | Agent::Codex), "{line}");
            match variant(&e.kind) {
                Some(i) => assert!(seen.insert(i), "two examples of {}", e.kind.name()),
                None => assert!(SPEC_UNKNOWN.contains(&e.kind.name()), "{} would fall into Unknown", e.kind.name()),
            }
            names.push(e.kind.name().to_owned());
        }
        assert_eq!(seen.len(), VARIANTS, "every parsed event has an example");
        let mut sorted = names.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), names.len(), "one example per event");
        let mut table_sorted: Vec<String> = table.iter().map(|s| (*s).to_owned()).collect();
        table_sorted.sort();
        assert_eq!(sorted, table_sorted, "the events table and the examples list the same events");
    }
}
