//! A haunt plugin: one palette command, plus a log line for new tasks and tool calls.

wit_bindgen::generate!({ path: "wit/haunt-plugin.wit", world: "plugin" });

use haunt::plugin::log::log;
use haunt::plugin::palette;
use haunt::plugin::theme;
use haunt::plugin::types::LogLevel;

struct Plugin;

fn describe(event: &AgentEvent) -> Option<String> {
    match event.kind.as_str() {
        "task_created" => Some(format!("new task: {}", event.summary.as_deref().unwrap_or(""))),
        "tool_ran" => Some(format!("ran {}", event.tool.as_deref()?)),
        _ => None,
    }
}

impl Guest for Plugin {
    fn init(_settings: String) {
        palette::command("say-hello", "Say hello", Some("cmd+shift+h"));
    }

    fn on_settings_changed(_settings: String) {}

    fn on_event(event: AgentEvent) {
        if let Some(line) = describe(&event) {
            log(LogLevel::Info, &line);
        }
    }

    fn palette_items(_mode: String, _query: String) -> Vec<PaletteItem> {
        Vec::new()
    }

    fn on_action(action_id: String, _payload: String) {
        log(LogLevel::Info, &format!("hello: {action_id}"));
    }

    fn row_menu(_surface: String) -> Vec<MenuItem> {
        Vec::new()
    }

    fn on_row_moved(_surface: String, _group: String, _before: Option<String>) {}

    fn on_theme_changed() {
        log(LogLevel::Info, &format!("theme: {}", theme::name()));
    }

    fn on_tick(_now_ms: u64) {}
}

export!(Plugin);

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: &str, tool: Option<&str>) -> AgentEvent {
        AgentEvent {
            kind: kind.into(),
            session_id: None,
            agent_id: None,
            cwd: None,
            summary: Some("fix it".into()),
            verified: true,
            surface: Some("s1".into()),
            tool: tool.map(Into::into),
            command: None,
            file_path: None,
            task_id: None,
            request_key: None,
        }
    }

    #[test]
    fn describes_tasks_and_tools_only() {
        assert_eq!(describe(&event("task_created", None)).as_deref(), Some("new task: fix it"));
        assert_eq!(describe(&event("tool_ran", Some("Bash"))).as_deref(), Some("ran Bash"));
        assert!(describe(&event("stop", None)).is_none());
    }
}
