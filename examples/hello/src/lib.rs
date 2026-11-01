//! Minimal haunt plugin: badges tasks and flags tool calls.

wit_bindgen::generate!({ path: "../../wit/haunt-plugin.wit", world: "plugin" });

use haunt::plugin::types::Style;

struct Hello;

impl Guest for Hello {
    fn on_event(event: AgentEvent) -> Option<Decoration> {
        log(&format!("hello saw {}", event.kind));
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
}

export!(Hello);
