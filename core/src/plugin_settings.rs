//! A plugin's settings: its manifest's `[settings]` defaults with the user's `[plugins."<id>"]` from
//! config.toml over them.

use std::collections::BTreeMap;

/// The `[plugins]` tables of config.toml, by plugin id.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PluginConfig {
    pub(crate) tables: BTreeMap<String, toml::Table>,
    /// What was wrong with config.toml's `[plugins]` itself.
    pub problems: Vec<String>,
    /// False when config.toml didn't parse: a reload then keeps every plugin's previous settings.
    pub parsed: bool,
    /// `[layout] row_labels`: plugin ids or short names whose row decoration wins, first first.
    pub row_labels: Vec<String>,
    /// `[presence] away_after`, in minutes: idle this long counts as away for plugins granted `away`.
    pub away_after_min: Option<u32>,
}

const MAX_ROW_LABELS: usize = 64;
pub const AWAY_AFTER_MAX_MIN: u32 = 240;
pub const AWAY_AFTER_DEFAULT_MIN: u32 = 10;

impl PluginConfig {
    /// A `plugins` entry that isn't a table sets nothing. A config.toml that doesn't parse sets nothing at
    /// load, and `PluginSet::set_config` leaves the settings as they were.
    pub fn parse(config_toml: &str) -> Self {
        let mut problems = Vec::new();
        let doc: toml::Table = match config_toml.parse() {
            Ok(t) => t,
            Err(e) => {
                let why = format!("config.toml doesn't parse: {}; keeping the previous plugin settings", e.message().trim());
                return Self { problems: vec![why], ..Self::default() };
            }
        };
        let mut tables = BTreeMap::new();
        match doc.get("plugins") {
            None => {}
            Some(toml::Value::Table(t)) => {
                for (id, v) in t {
                    match v {
                        toml::Value::Table(t) => {
                            tables.insert(id.clone(), t.clone());
                        }
                        _ => problems.push(format!("[plugins] {id}: not a table, ignored")),
                    }
                }
            }
            Some(_) => problems.push("[plugins]: not a table, ignored".into()),
        }
        let row_labels = match doc.get("layout").and_then(|l| l.get("row_labels")) {
            None => Vec::new(),
            Some(toml::Value::Array(a)) if a.iter().all(toml::Value::is_str) => {
                a.iter().filter_map(|v| v.as_str()).take(MAX_ROW_LABELS).map(str::to_owned).collect()
            }
            Some(_) => {
                problems.push("[layout] row_labels: not a list of plugin names, ignored".into());
                Vec::new()
            }
        };
        let away_after_min = match doc.get("presence").and_then(|p| p.get("away_after")) {
            None => None,
            Some(toml::Value::Integer(m)) if (1..=i64::from(AWAY_AFTER_MAX_MIN)).contains(m) => Some(*m as u32),
            Some(_) => {
                problems.push(format!("[presence] away_after: minutes from 1 to {AWAY_AFTER_MAX_MIN}, ignored"));
                None
            }
        };
        if doc.contains_key("away_after") {
            problems.push("away_after moved to [presence]; the top-level one is ignored".into());
        }
        Self { tables, problems, parsed: true, row_labels, away_after_min }
    }

    /// The JSON `init` and `on-settings-changed` get: the defaults in `schema` (the manifest's
    /// `[settings]`), each overridden by a user value of the same TOML type. Anything else is dropped
    /// into `problems`.
    pub fn settings_json(&self, id: &str, schema: &toml::Table, problems: &mut Vec<String>) -> String {
        let mut out: serde_json::Map<String, serde_json::Value> = schema
            .iter()
            .filter_map(|(k, v)| Some((k.clone(), serde_json::to_value(v.get("default")?).ok()?)))
            .collect();
        for (k, v) in self.tables.get(id).into_iter().flatten() {
            let Some(default) = schema.get(k).and_then(|s| s.get("default")) else {
                problems.push(format!("[plugins.\"{id}\"] {k}: not a setting of this plugin, ignored"));
                continue;
            };
            if v.type_str() != default.type_str() {
                problems.push(format!("[plugins.\"{id}\"] {k}: a {}, but this setting is a {}; ignored", v.type_str(), default.type_str()));
                continue;
            }
            match serde_json::to_value(v) {
                Ok(j) => {
                    out.insert(k.clone(), j);
                }
                Err(e) => problems.push(format!("[plugins.\"{id}\"] {k}: {e}, ignored")),
            }
        }
        serde_json::Value::Object(out).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn schema() -> toml::Table {
        r#"
        pins = { type = "bool", default = true, description = "x" }
        style = { type = "string", default = "dot" }
        commands = { type = "list", default = [] }
        "#
        .parse()
        .unwrap()
    }

    #[test]
    fn user_values_of_the_declared_type_go_over_the_defaults() {
        let c = PluginConfig::parse(
            "font_size = 12\n[plugins.\"dev.haunt.t\"]\npins = false\n[[plugins.\"dev.haunt.t\".commands]]\nid = \"a\"\ntext = \"ls\"\n",
        );
        assert!(c.problems.is_empty(), "{:?}", c.problems);
        let mut p = Vec::new();
        let j: serde_json::Value = serde_json::from_str(&c.settings_json("dev.haunt.t", &schema(), &mut p)).unwrap();
        assert!(p.is_empty(), "{p:?}");
        assert_eq!(j, serde_json::json!({"pins": false, "style": "dot", "commands": [{"id": "a", "text": "ls"}]}));
        let other: serde_json::Value = serde_json::from_str(&c.settings_json("dev.haunt.other", &schema(), &mut p)).unwrap();
        assert_eq!(other["pins"], true, "another plugin's table is not this one's");
    }

    #[test]
    fn undeclared_and_mistyped_keys_are_dropped_and_reported() {
        let c = PluginConfig::parse("[plugins.\"dev.haunt.t\"]\npins = \"no\"\nstyle = \"tint\"\nshell = \"/bin/sh\"\ncommands = {}\n");
        let mut p = Vec::new();
        let j: serde_json::Value = serde_json::from_str(&c.settings_json("dev.haunt.t", &schema(), &mut p)).unwrap();
        assert_eq!(j, serde_json::json!({"pins": true, "style": "tint", "commands": []}));
        assert_eq!(p.len(), 3, "{p:?}");
        assert!(p.iter().any(|l| l.contains("shell: not a setting")));
        assert!(p.iter().any(|l| l.contains("pins: a string, but this setting is a boolean")));
    }

    #[test]
    fn away_after_is_minutes_in_range() {
        assert_eq!(PluginConfig::parse("[presence]\naway_after = 5\n").away_after_min, Some(5));
        let top = PluginConfig::parse("away_after = 5\n");
        assert_eq!(top.away_after_min, None, "only in [presence]");
        assert_eq!(top.problems, ["away_after moved to [presence]; the top-level one is ignored"]);
        for bad in ["away_after = 0", "away_after = \"5m\"", "away_after = 999"] {
            let c = PluginConfig::parse(&format!("[presence]\n{bad}"));
            assert!(c.away_after_min.is_none() && c.problems[0].contains("away_after"), "{bad}");
        }
    }

    #[test]
    fn row_labels_are_a_list_of_names_in_layout() {
        assert_eq!(PluginConfig::parse("[layout]\nrow_labels = [\"checklist\", \"ci\"]\n").row_labels, ["checklist", "ci"]);
        let c = PluginConfig::parse("[layout]\nrow_labels = \"ci\"\n");
        assert!(c.row_labels.is_empty() && c.problems[0].contains("row_labels"));
        assert!(PluginConfig::parse("[layout]\nrow_labels = [\"ci\", 1]\n").row_labels.is_empty());
    }

    #[test]
    fn a_broken_config_applies_no_settings() {
        let c = PluginConfig::parse("[plugins\n");
        assert_eq!((c.tables.len(), c.problems.len(), c.parsed), (0, 1, false));
        assert!(c.problems[0].contains("keeping the previous plugin settings"), "{:?}", c.problems);
        let c = PluginConfig::parse("plugins = 3\n");
        assert_eq!((c.tables.len(), c.problems.len(), c.parsed), (0, 1, true));
    }
}
