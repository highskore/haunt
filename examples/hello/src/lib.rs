//! Minimal haunt plugin: one palette command, plus badges for tasks and tool calls.
// wit-bindgen's flattened `notify` import has 14 params.
#![allow(clippy::too_many_arguments)]

wit_bindgen::generate!({ path: "../../wit/haunt-plugin.wit", world: "plugin" });

use haunt::plugin::log::log;
use haunt::plugin::palette;
use haunt::plugin::types::{LogLevel, Style};

struct Hello;

impl Guest for Hello {
    fn init(_settings: String) {
        palette::command("say-hello", "Say hello", Some("cmd+shift+h"));
    }

    fn on_settings_changed(_settings: String) {}

    fn on_event(event: AgentEvent) -> Option<Decoration> {
        log(LogLevel::Debug, &format!("hello saw {}", event.kind));
        match event.kind.as_str() {
            "task_created" => Some(Decoration {
                badge: Some("new task".into()),
                style: Style::Meta,
                meta_suffix: event.summary,
            }),
            "tool_ran" => Some(Decoration { badge: event.summary, style: Style::Kbd, meta_suffix: None }),
            _ => None,
        }
    }

    fn palette_items(_mode: String, _query: String) -> Vec<PaletteItem> {
        Vec::new()
    }

    fn on_action(action_id: String, _payload: String) {
        log(LogLevel::Info, &format!("hello: {action_id}"));
    }
}

export!(Hello);
