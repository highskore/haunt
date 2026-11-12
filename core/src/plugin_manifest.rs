//! `haunt-plugin.toml`, plan section 3.5, and the capability set the user approves.

use serde::{Deserialize, Serialize};

use crate::event::EventKind;

pub const MANIFEST: &str = "haunt-plugin.toml";
/// The `haunt:plugin` minor this host implements.
pub const API: (u64, u64) = (0, 4);
pub const KV_CAP: usize = 10 << 20;
pub const NAME_MAX: usize = 64;
pub const DESCRIPTION_MAX: usize = 160;
pub const LICENSE_MAX: usize = 64;
pub const HOMEPAGE_MAX: usize = 256;

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
    /// The component; a plugin without one carries data only (see `plugin_pack`).
    pub entry: Option<String>,
    /// One line for the setup sheet and Settings.
    pub description: Option<String>,
    pub license: Option<String>,
    pub homepage: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct Capabilities {
    pub events: Vec<String>,
    pub pty_write: bool,
    pub pty_type: bool,
    pub notifications: bool,
    pub decisions_read: bool,
    pub allowlist_suggest: bool,
    pub sidebar: bool,
    pub fs_read: Vec<String>,
    pub fs_write: Vec<String>,
    pub net: Vec<String>,
    pub hid: Vec<toml::Value>,
    pub exec: Vec<String>,
    pub terminal_read: bool,
    pub clipboard: Option<String>,
    /// Data only: contributes a theme in `[contributes.theme]`.
    pub theme: bool,
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
    /// Whether an event goes to this plugin. Anything in the terminal can forge an unverified one,
    /// so a plugin that can answer prompts, type or see approved commands only gets verified events.
    pub fn wants_event(&self, kind: &EventKind, verified: bool) -> bool {
        let topic = event_topic(kind);
        (verified || !self.verified_only()) && self.events.iter().any(|e| e == topic || e == "agent.*")
    }

    pub fn verified_only(&self) -> bool {
        self.pty_write || self.pty_type || self.allowlist_suggest || self.decisions_read
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
        if self.theme {
            out.push(("adds a theme: colours, fonts and window effects. Its fonts can change how text, including the terminal, is drawn. Runs no code".into(), false));
        }
        if !self.events.is_empty() {
            out.push((
                format!("can see agent events ({}): commands, file paths and prompts, which can contain secrets", self.events.join(", ")),
                false,
            ));
        }
        if self.notifications {
            out.push(("can show notifications with action buttons".into(), false));
        }
        if self.decisions_read {
            out.push(("can read your whole permission decision log: every command and file path an agent asked to use, its folder, tab and your answer; these can contain secrets".into(), false));
        }
        if self.allowlist_suggest {
            out.push(("can read the commands you approved in Haunt more than once and the folders they ran in; these can contain secrets. Can suggest allow rules for them (nothing is written until you accept)".into(), false));
        }
        if self.sidebar {
            out.push(("can see your tabs' names and states, and reorder, pin, group and colour them (rows needing you stay on top)".into(), false));
        }
        if self.pty_write {
            out.push(("can answer permission prompts in your terminal (Allow or Deny, nothing else)".into(), true));
        }
        if self.pty_type {
            out.push(("can type text into the current tab when you run one of its commands".into(), true));
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
            pty_type: self.pty_type && !old.pty_type,
            notifications: self.notifications && !old.notifications,
            decisions_read: self.decisions_read && !old.decisions_read,
            allowlist_suggest: self.allowlist_suggest && !old.allowlist_suggest,
            sidebar: self.sidebar && !old.sidebar,
            theme: self.theme && !old.theme,
            fs_read: self.fs_read.iter().filter(|g| !old.fs_read.contains(g)).cloned().collect(),
            fs_write: self.fs_write.iter().filter(|g| !old.fs_write.contains(g)).cloned().collect(),
            ..Default::default()
        };
        grown.describe()
    }
}

/// The capabilities every plugin gets, for the install prompt.
pub const ALWAYS: &str = "can add commands and modes to the palette and entries to tab menus, keep up to 10 MB of its own data, and write to its log";

fn plain_glob(g: &str) -> String {
    g.replace("${cwd}", "<agent folder>")
}

pub fn valid_id(id: &str) -> bool {
    let parts: Vec<&str> = id.split('.').collect();
    parts.len() >= 2
        && id.len() <= 128
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                && !p.starts_with('-')
        })
}

/// Text the UI shows as is: at most `max` characters, with no control, format, line-separator,
/// bidi-override or zero-width character that could hide or reorder what is shown.
pub fn plain_line(s: &str, max: usize) -> bool {
    s.chars().count() <= max && !s.chars().any(|c| c.is_control() || is_format(c) || matches!(c, '\u{2028}' | '\u{2029}'))
}

/// `s` with every character `plain_line` refuses written as `\u{..}`, for printing text that wasn't checked.
pub fn escape_hidden(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_control() || is_format(c) || matches!(c, '\u{2028}' | '\u{2029}') { format!("\\u{{{:x}}}", c as u32) } else { c.to_string() })
        .collect()
}

/// Unicode's Cf (format) characters, which include the bidi controls, zero-width characters and BOM.
fn is_format(c: char) -> bool {
    matches!(c as u32,
        0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x890..=0x891 | 0x8E2 | 0x180E | 0x200B..=0x200F
        | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD
        | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
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
        if let Some(e) = &p.entry {
            let plain = std::path::Path::new(e).components().all(|c| matches!(c, std::path::Component::Normal(_)));
            if e.is_empty() || !plain {
                return Err(ManifestError(format!("entry {e:?} must be a relative path inside the plugin folder")));
            }
        }
        crate::plugin_pack::validate_data_only(self)?;
        if !plain_line(&p.name, NAME_MAX) || p.name.trim().is_empty() {
            return Err(ManifestError(format!("name must be one line of at most {NAME_MAX} plain characters")));
        }
        if p.description.as_deref().is_some_and(|d| !plain_line(d, DESCRIPTION_MAX)) {
            return Err(ManifestError(format!("description must be one line of at most {DESCRIPTION_MAX} plain characters")));
        }
        let version_ok = (1..=32).contains(&p.version.len()) && p.version.bytes().all(|b| b.is_ascii_alphanumeric() || b"+-.".contains(&b));
        if !version_ok {
            return Err(ManifestError(format!("version {:?} must be 1-32 of letters, digits, '.', '+' and '-'", p.version)));
        }
        if p.license.as_deref().is_some_and(|l| !plain_line(l, LICENSE_MAX)) {
            return Err(ManifestError(format!("license must be one line of at most {LICENSE_MAX} plain characters")));
        }
        if p.homepage.as_deref().is_some_and(|h| !plain_line(h, HOMEPAGE_MAX)) {
            return Err(ManifestError(format!("homepage must be one line of at most {HOMEPAGE_MAX} plain characters")));
        }
        validate_settings(&self.settings)?;
        self.capabilities.validate()
    }
}

/// Every `[settings]` entry is a table with a `default`, which also fixes the type a user value must have.
fn validate_settings(settings: &toml::Table) -> Result<(), ManifestError> {
    match settings.iter().find(|(_, v)| v.get("default").is_none()) {
        Some((k, _)) => Err(ManifestError(format!("[settings] {k} needs a default, like {k} = {{ type = \"bool\", default = false }}"))),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(caps: &str) -> String {
        format!(
            "[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"0.1.0\"\napi = \"0.4\"\nentry = \"plugin.wasm\"\n\n[capabilities]\n{caps}\n"
        )
    }

    #[test]
    fn description_is_one_short_line() {
        let with = |d: &str| manifest("").replace("entry =", &format!("description = {d:?}\nentry ="));
        assert_eq!(Manifest::parse(&with("Sorts tabs")).unwrap().plugin.description.as_deref(), Some("Sorts tabs"));
        assert!(Manifest::parse(&manifest("")).unwrap().plugin.description.is_none());
        assert!(Manifest::parse(&with("two\nlines")).is_err());
        assert!(Manifest::parse(&with(&"x".repeat(DESCRIPTION_MAX + 1))).is_err());
    }

    #[test]
    fn name_and_description_refuse_hidden_or_reordering_characters() {
        let named = |n: &str| manifest("").replace("name = \"T\"", &format!("name = {n:?}"));
        let described = |d: &str| manifest("").replace("entry =", &format!("description = {d:?}\nentry ="));
        for bad in ["evil\u{202E}gnp.exe", "one\u{2028}two", "red \u{1b}[31m", "zero\u{200B}width", "\u{FEFF}bom"] {
            assert!(Manifest::parse(&named(bad)).is_err(), "name {bad:?}");
            assert!(Manifest::parse(&described(bad)).is_err(), "description {bad:?}");
        }
        assert!(Manifest::parse(&named(&"n".repeat(NAME_MAX + 1))).is_err());
        assert!(Manifest::parse(&named(" ")).is_err());
        assert!(Manifest::parse(&named("Décision log ⌘K")).is_ok());
    }

    #[test]
    fn version_license_and_homepage_are_plain_too() {
        let set = |k: &str, v: &str| manifest("").replace("entry =", &format!("{k} = {v:?}\nentry ="));
        let versioned = |v: &str| manifest("").replace("version = \"0.1.0\"", &format!("version = {v:?}"));
        assert!(Manifest::parse(&versioned("1.2.3-rc.1+build.5")).is_ok());
        for bad in ["0.1.0\u{1b}[2K", "", "1 2", "1.0\u{202E}", &"9".repeat(33)] {
            assert!(Manifest::parse(&versioned(bad)).is_err(), "version {bad:?}");
        }
        assert!(Manifest::parse(&set("homepage", "https://haunt.dev/\u{202E}lmth.exe")).is_err());
        assert!(Manifest::parse(&set("homepage", &format!("https://{}", "x".repeat(HOMEPAGE_MAX)))).is_err());
        assert!(Manifest::parse(&set("homepage", "https://haunt.dev/plugins")).is_ok());
        assert!(Manifest::parse(&set("license", "MIT\u{2028}OR evil")).is_err());
        assert!(Manifest::parse(&set("license", "MIT OR Apache-2.0")).is_ok());
    }

    #[test]
    fn escape_hidden_shows_what_plain_line_refuses() {
        assert_eq!(escape_hidden("a\u{1b}[31mb\u{202E}c\u{2028}"), "a\\u{1b}[31mb\\u{202e}c\\u{2028}");
        assert_eq!(escape_hidden("Décision ⌘K"), "Décision ⌘K");
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
    fn plugins_that_act_or_see_approvals_get_verified_events_only() {
        let kind = EventKind::SubagentStart;
        for (caps, unverified) in [
            ("", true),
            ("notifications = true\nsidebar = true", true),
            ("pty_write = true", false),
            ("pty_type = true", false),
            ("allowlist_suggest = true", false),
            ("decisions_read = true", false),
        ] {
            let m = Manifest::parse(&manifest(&format!("events = [\"agent.*\"]\n{caps}"))).unwrap();
            assert!(m.capabilities.wants_event(&kind, true), "{caps}");
            assert_eq!(m.capabilities.wants_event(&kind, false), unverified, "{caps}");
        }
    }

    #[test]
    fn typing_is_its_own_capability_and_consent_line() {
        let m = Manifest::parse(&manifest("pty_type = true")).unwrap();
        assert_eq!(m.capabilities.describe(), [("can type text into the current tab when you run one of its commands".to_owned(), true)]);
        let answers = Capabilities { pty_write: true, ..Default::default() };
        assert_eq!(m.capabilities.added_since(&answers).len(), 1, "pty_write never implies typing");
        assert!(!answers.describe().iter().any(|(l, _)| l.contains("type text")));
    }

    #[test]
    fn every_setting_needs_a_default() {
        let base = manifest("");
        assert!(Manifest::parse(&format!("{base}\n[settings]\npins = {{ type = \"bool\", default = true }}\n")).is_ok());
        for bad in ["pins = { type = \"bool\" }", "pins = true"] {
            let e = Manifest::parse(&format!("{base}\n[settings]\n{bad}\n")).unwrap_err().0;
            assert!(e.contains("pins needs a default"), "{bad}: {e}");
        }
    }

    #[test]
    fn the_consent_text_says_what_the_log_imports_expose() {
        let m = Manifest::parse(&manifest("decisions_read = true\nallowlist_suggest = true")).unwrap();
        let lines: Vec<_> = m.capabilities.describe().into_iter().map(|(l, _)| l).collect();
        let [log, allow] = &lines[..] else { panic!("{lines:?}") };
        for want in ["every command and file path", "folder", "secrets"] {
            assert!(log.contains(want), "{log}");
        }
        for want in ["commands you approved", "folders they ran in", "secrets", "nothing is written until you accept"] {
            assert!(allow.contains(want), "{allow}");
        }
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
        assert!(Manifest::parse(&m.replace("api = \"0.4\"", "api = \"1.0\"")).is_err());
        assert!(Manifest::parse(&m.replace("plugin.wasm", "../x.wasm")).is_err());
        assert!(Manifest::parse(&m.replace("plugin.wasm", "/tmp/x.wasm")).is_err());
        assert!(Manifest::parse(&m.replace("api = \"0.4\"", "api = \"0.4.3\"")).is_ok());
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
