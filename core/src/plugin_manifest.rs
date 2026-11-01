//! `haunt-plugin.toml`, plan section 3.5, and the capability set the user approves.

use serde::{Deserialize, Serialize};

use crate::event::EventKind;

pub const MANIFEST: &str = "haunt-plugin.toml";
/// The `haunt:plugin` minor this host implements.
pub const API: (u64, u64) = (0, 1);
pub const KV_CAP: usize = 10 << 20;

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
#[error("{0}")]
pub struct ManifestError(pub String);

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub plugin: PluginMeta,
    #[serde(default)]
    pub capabilities: Capabilities,
    #[serde(default)]
    pub contributes: toml::Table,
    #[serde(default)]
    pub settings: toml::Table,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PluginMeta {
    pub id: String,
    pub name: String,
    pub version: String,
    pub api: String,
    pub entry: String,
    pub license: Option<String>,
    pub homepage: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct Capabilities {
    pub events: Vec<String>,
    pub pty_write: bool,
    pub notifications: bool,
    pub fs_read: Vec<String>,
    pub fs_write: Vec<String>,
    pub net: Vec<String>,
    pub hid: Vec<toml::Value>,
    pub exec: Vec<String>,
    pub terminal_read: bool,
    pub clipboard: Option<String>,
}

const AGENT_EVENTS: &[&str] = &[
    "agent.session-start",
    "agent.prompt",
    "agent.task",
    "agent.subagent",
    "agent.tool",
    "agent.permission-request",
    "agent.notification",
    "agent.plan-exit",
    "agent.question",
    "agent.todos",
    "agent.file-edited",
    "agent.stop",
    "agent.unknown",
];
const TERMINAL_EVENTS: &[&str] =
    &["terminal.surface", "terminal.title", "terminal.pwd", "terminal.bell", "terminal.command-finished", "terminal.progress"];

/// The manifest `events` name an event is delivered under.
pub fn event_topic(kind: &EventKind) -> &'static str {
    match kind {
        EventKind::SessionStart { .. } => "agent.session-start",
        EventKind::PromptSubmit { .. } => "agent.prompt",
        EventKind::TaskCreated { .. } | EventKind::TaskUpdated { .. } => "agent.task",
        EventKind::SubagentSpawn { .. }
        | EventKind::SubagentStart
        | EventKind::SubagentStop
        | EventKind::SubagentResult { .. }
        | EventKind::SubagentTool { .. } => "agent.subagent",
        EventKind::ToolStart { .. } | EventKind::ToolDone { .. } | EventKind::ToolFailed { .. } | EventKind::ToolRan { .. } => {
            "agent.tool"
        }
        EventKind::PermissionSeen { .. } => "agent.permission-request",
        EventKind::Notification { .. } => "agent.notification",
        EventKind::PlanExit { .. } => "agent.plan-exit",
        EventKind::QuestionAnswered { .. } => "agent.question",
        EventKind::TodosWritten { .. } => "agent.todos",
        EventKind::FileEdited { .. } => "agent.file-edited",
        EventKind::Stop => "agent.stop",
        EventKind::Unknown { .. } => "agent.unknown",
    }
}

impl Capabilities {
    pub fn wants_event(&self, kind: &EventKind) -> bool {
        let topic = event_topic(kind);
        self.events.iter().any(|e| e == topic || e == "agent.*")
    }

    pub fn fs_read_granted(&self) -> bool {
        !self.fs_read.is_empty()
    }

    pub fn fs_write_granted(&self) -> bool {
        !self.fs_write.is_empty()
    }

    fn validate(&self) -> Result<(), ManifestError> {
        let err = |m: String| Err(ManifestError(m));
        if self.terminal_read {
            return err("capability terminal_read is not supported by this haunt version; remove it from [capabilities]".into());
        }
        for (name, empty) in [
            ("net", self.net.is_empty()),
            ("hid", self.hid.is_empty()),
            ("exec", self.exec.is_empty()),
            ("clipboard", self.clipboard.as_deref().is_none_or(|c| c == "none")),
        ] {
            if !empty {
                return err(format!("capability {name} is not supported by this haunt version; remove it from [capabilities]"));
            }
        }
        for e in &self.events {
            let known = e == "agent.*" || e == "terminal.*" || AGENT_EVENTS.contains(&e.as_str()) || TERMINAL_EVENTS.contains(&e.as_str());
            if !known {
                return err(format!("unknown event {e:?} in [capabilities].events"));
            }
        }
        for g in self.fs_read.iter().chain(&self.fs_write) {
            crate::plugin_fs::validate_glob(g).map_err(ManifestError)?;
        }
        Ok(())
    }

    /// Plain-word lines for the install prompt; the bool marks the ones shown in red.
    pub fn describe(&self) -> Vec<(String, bool)> {
        let mut out = Vec::new();
        if !self.events.is_empty() {
            out.push((
                format!("can see agent events ({}): commands, file paths and prompts, which can contain secrets", self.events.join(", ")),
                false,
            ));
        }
        if self.notifications {
            out.push(("can show notifications with action buttons".into(), false));
        }
        if self.pty_write {
            out.push(("can write to your terminal: answer permission prompts and type text".into(), true));
        }
        for g in &self.fs_read {
            out.push((format!("can read files matching {}", plain_glob(g)), false));
        }
        for g in &self.fs_write {
            out.push((format!("can write files matching {}", plain_glob(g)), true));
        }
        out
    }

    /// Lines for capabilities `self` has that `old` did not.
    pub fn added_since(&self, old: &Capabilities) -> Vec<(String, bool)> {
        let grown = Capabilities {
            events: self.events.iter().filter(|e| !old.events.contains(e)).cloned().collect(),
            pty_write: self.pty_write && !old.pty_write,
            notifications: self.notifications && !old.notifications,
            fs_read: self.fs_read.iter().filter(|g| !old.fs_read.contains(g)).cloned().collect(),
            fs_write: self.fs_write.iter().filter(|g| !old.fs_write.contains(g)).cloned().collect(),
            ..Default::default()
        };
        grown.describe()
    }
}

/// The capabilities every plugin gets, for the install prompt.
pub const ALWAYS: &str = "can add commands and modes to the palette, keep up to 10 MB of its own data, and write to its log";

fn plain_glob(g: &str) -> String {
    g.replace("${cwd}", "<agent folder>")
}

fn valid_id(id: &str) -> bool {
    let parts: Vec<&str> = id.split('.').collect();
    parts.len() >= 2
        && id.len() <= 128
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                && !p.starts_with('-')
        })
}

fn api_supported(api: &str) -> bool {
    let mut it = api.split('.');
    let major = it.next().and_then(|s| s.parse::<u64>().ok());
    let minor = it.next().and_then(|s| s.parse::<u64>().ok());
    let patch_ok = it.next().is_none_or(|p| p.parse::<u64>().is_ok()) && it.next().is_none();
    patch_ok && major == Some(API.0) && minor == Some(API.1)
}

impl Manifest {
    pub fn parse(text: &str) -> Result<Self, ManifestError> {
        let m: Manifest = toml::from_str(text).map_err(|e| ManifestError(format!("{MANIFEST}: {e}")))?;
        m.validate()?;
        Ok(m)
    }

    fn validate(&self) -> Result<(), ManifestError> {
        let p = &self.plugin;
        if !valid_id(&p.id) {
            return Err(ManifestError(format!("plugin id {:?} must be reverse-DNS: lowercase letters, digits and '-', dot separated", p.id)));
        }
        if !api_supported(&p.api) {
            return Err(ManifestError(format!("plugin needs haunt:plugin api {}, this haunt supports {}.{}", p.api, API.0, API.1)));
        }
        let entry = std::path::Path::new(&p.entry);
        let plain = entry.components().all(|c| matches!(c, std::path::Component::Normal(_)));
        if p.entry.is_empty() || !plain {
            return Err(ManifestError(format!("entry {:?} must be a relative path inside the plugin folder", p.entry)));
        }
        self.capabilities.validate()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(caps: &str) -> String {
        format!(
            "[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"0.1.0\"\napi = \"0.1\"\nentry = \"plugin.wasm\"\n\n[capabilities]\n{caps}\n"
        )
    }

    #[test]
    fn plan_example_capabilities_parse() {
        let m = Manifest::parse(&manifest(
            "events = [\"agent.permission-request\", \"agent.tool\", \"terminal.pwd\"]\npty_write = false\nnotifications = true\n\
             fs_read = [\"${cwd}/.claude/settings.json\"]\nfs_write = [\"${cwd}/.claude/settings.local.json\"]\n\
             net = []\nhid = []\nexec = []\nterminal_read = false\nclipboard = \"none\"",
        ))
        .unwrap();
        assert!(m.capabilities.notifications);
        assert!(m.capabilities.describe().iter().any(|(l, _)| l.contains("<agent folder>/.claude/settings.json")));
    }

    #[test]
    fn terminal_read_is_rejected() {
        let e = Manifest::parse(&manifest("terminal_read = true")).unwrap_err();
        assert!(e.0.contains("terminal_read is not supported"), "{e}");
    }

    #[test]
    fn unsupported_and_unknown_capabilities_are_rejected() {
        assert!(Manifest::parse(&manifest("net = [\"api.example.com\"]")).is_err());
        assert!(Manifest::parse(&manifest("clipboard = \"read\"")).is_err());
        assert!(Manifest::parse(&manifest("terminal-read = true")).is_err());
        assert!(Manifest::parse(&manifest("events = [\"agent.tools\"]")).is_err());
        assert!(Manifest::parse(&manifest("fs_read = [\"relative/path\"]")).is_err());
    }

    #[test]
    fn bad_meta_is_rejected() {
        let m = manifest("");
        assert!(Manifest::parse(&m.replace("dev.haunt.t", "../evil")).is_err());
        assert!(Manifest::parse(&m.replace("dev.haunt.t", "Dev.Haunt")).is_err());
        assert!(Manifest::parse(&m.replace("api = \"0.1\"", "api = \"1.0\"")).is_err());
        assert!(Manifest::parse(&m.replace("plugin.wasm", "../x.wasm")).is_err());
        assert!(Manifest::parse(&m.replace("plugin.wasm", "/tmp/x.wasm")).is_err());
        assert!(Manifest::parse(&m.replace("api = \"0.1\"", "api = \"0.1.3\"")).is_ok());
    }

    #[test]
    fn growth_lists_only_new_capabilities() {
        let old = Capabilities { events: vec!["agent.tool".into()], ..Default::default() };
        let new = Capabilities { events: vec!["agent.tool".into(), "agent.task".into()], pty_write: true, ..Default::default() };
        let added = new.added_since(&old);
        assert_eq!(added.len(), 2);
        assert!(added[0].0.contains("agent.task") && !added[0].0.contains("agent.tool"));
        assert!(new.added_since(&new).is_empty());
    }
}
