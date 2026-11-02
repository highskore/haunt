//! A haunt plugin: one palette command, plus badges for new tasks and tool calls.
// wit-bindgen's flattened `notify` import has 14 params.
#![allow(clippy::too_many_arguments)]

wit_bindgen::generate!({ path: "wit/haunt-plugin.wit", world: "plugin" });

use haunt::plugin::log::log;
use haunt::plugin::palette;
use haunt::plugin::types::{LogLevel, Style};

struct Plugin;

fn decorate(event: AgentEvent) -> Option<Decoration> {
    match event.kind.as_str() {
        "task_created" => Some(Decoration { badge: Some("new task".into()), style: Style::Meta, meta_suffix: event.summary }),
        "tool_ran" => Some(Decoration { badge: event.summary, style: Style::Kbd, meta_suffix: None }),
        _ => None,
    }
}

impl Guest for Plugin {
    fn init(_settings: String) {
        palette::command("say-hello", "Say hello", Some("cmd+shift+h"));
    }

    fn on_settings_changed(_settings: String) {}

    fn on_event(event: AgentEvent) -> Option<Decoration> {
        log(LogLevel::Debug, &format!("saw {}", event.kind));
        decorate(event)
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
}

export!(Plugin);

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: &str, summary: Option<&str>) -> AgentEvent {
        AgentEvent { kind: kind.into(), session_id: None, agent_id: None, cwd: None, summary: summary.map(Into::into), verified: true }
    }

    #[test]
    fn badges_tasks_and_tools_only() {
        assert_eq!(decorate(event("task_created", Some("fix it"))).unwrap().badge.as_deref(), Some("new task"));
        assert_eq!(decorate(event("tool_ran", Some("Bash"))).unwrap().badge.as_deref(), Some("Bash"));
        assert!(decorate(event("stop", None)).is_none());
    }
}
