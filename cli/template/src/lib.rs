//! A haunt plugin: one palette command, plus a label on the row for new tasks and tool calls.

wit_bindgen::generate!({ path: "wit/haunt-plugin.wit", world: "plugin" });

use haunt::plugin::log::log;
use haunt::plugin::palette;
use haunt::plugin::rows::{self, Decoration, Tone};
use haunt::plugin::theme;
use haunt::plugin::types::LogLevel;

struct Plugin;

fn decoration(event: &AgentEvent) -> Option<Decoration> {
    // Unverified events can be forged by anything in the terminal (OSC, wrong nonce) — see the
    // `verified` comment in wit/haunt-plugin.wit. Never render their content.
    if !event.verified {
        return None;
    }
    let (label, tone) = match event.kind.as_str() {
        "task_created" => ("new task".to_owned(), Tone::Dim),
        "tool_ran" => (event.tool.clone()?, Tone::Text),
        _ => return None,
    };
    Some(Decoration { label: Some(label), label_tone: tone, suffix: None, suffix_tone: Tone::Dim, scroll: false, bar: None, spark: None })
}

impl Guest for Plugin {
    fn init(_settings: String) {
        palette::command("say-hello", "Say hello", Some("cmd+shift+h"));
    }

    fn on_settings_changed(_settings: String) {}

    fn on_event(event: AgentEvent) {
        log(LogLevel::Debug, &format!("saw {}", event.kind));
        if let (Some(surface), Some(d)) = (event.surface.as_deref(), decoration(&event)) {
            let _ = rows::decorate(surface, Some(&d));
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

    fn on_exec(_job: u64, _outcome: Result<haunt::plugin::exec::Output, String>) {}

    fn on_away_changed(_away: bool, _away_ms: u64) {}

    fn on_hover_hold(_held: bool, _surface: String) {}

    fn on_fs_tree(_job: u64, _outcome: Result<haunt::plugin::fs_list::TreeResult, String>) {}
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
            summary: None,
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
    fn labels_tasks_and_tools_only() {
        assert_eq!(decoration(&event("task_created", None)).unwrap().label.as_deref(), Some("new task"));
        assert_eq!(decoration(&event("tool_ran", Some("Bash"))).unwrap().label.as_deref(), Some("Bash"));
        assert!(decoration(&event("stop", None)).is_none());
    }

    #[test]
    fn skips_unverified_events() {
        let mut forged = event("tool_ran", Some("Bash"));
        forged.verified = false;
        assert!(decoration(&forged).is_none());
    }
}
