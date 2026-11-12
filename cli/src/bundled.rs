//! The plugins haunt.app bundles, for `haunt setup --plugins`: which there are, and the plan to install or remove them.

use std::path::{Path, PathBuf};

use haunt_core::plugin_manifest::{MANIFEST, Manifest, escape_hidden as e};
use haunt_core::plugin_store::{BUNDLED, Installed, Preview, Prompt, Store, StoreError};
use haunt_core::plugins::PluginHost;

/// First-party ids are `dev.haunt.<short>`, built from the repo `haunt-plugins/haunt-<short>`.
const FIRST_PARTY: &str = "dev.haunt.";

pub struct Bundled {
    pub id: String,
    pub name: String,
    pub description: String,
    pub dir: PathBuf,
}

/// The name `make-app.sh --plugins` and `haunt setup --plugins` take for an id.
pub fn short(id: &str) -> &str {
    id.strip_prefix(FIRST_PARTY).unwrap_or(id)
}

/// haunt.app/Contents/Resources/plugins beside this CLI (resolved through symlinks). Debug builds, which tests
/// run, may point elsewhere with `$HAUNT_BUNDLED_PLUGINS`; a release build trusts only its own app bundle.
pub fn dir() -> Option<PathBuf> {
    #[cfg(debug_assertions)]
    if let Some(d) = std::env::var_os("HAUNT_BUNDLED_PLUGINS") {
        return Some(PathBuf::from(d));
    }
    let exe = std::env::current_exe().and_then(std::fs::canonicalize).ok()?;
    Some(exe.parent()?.parent()?.join("Resources/plugins"))
}

/// The bundled plugins, by id, with the name and description from each manifest; none when the app was built
/// without `--plugins`.
pub fn list() -> Vec<Bundled> {
    let Some(dir) = dir() else { return vec![] };
    let Ok(rd) = std::fs::read_dir(&dir) else { return vec![] };
    let mut out: Vec<Bundled> = rd
        .filter_map(Result::ok)
        .filter_map(|e| {
            let id = e.file_name().to_string_lossy().into_owned();
            let text = std::fs::read_to_string(e.path().join(MANIFEST)).ok()?;
            let m = Manifest::parse(&text).ok()?;
            (m.plugin.id == id).then(|| Bundled {
                id,
                name: m.plugin.name,
                description: m.plugin.description.unwrap_or_default(),
                dir: e.path(),
            })
        })
        .collect();
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

/// Ids for a comma-separated list of short names or ids, each one this app bundles; `all` (only when installing)
/// is every bundled one. Removing also takes a bundled plugin still installed from an older app (`installed`).
pub fn resolve(list: &str, installing: bool, bundled: &[Bundled], installed: &[String]) -> Result<Vec<String>, String> {
    let known: Vec<&str> = bundled.iter().map(|b| b.id.as_str()).chain(installed.iter().map(String::as_str).filter(|_| !installing)).collect();
    let mut ids = vec![];
    for name in list.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let found: Vec<String> = match name {
            "none" => vec![],
            "all" if installing => bundled.iter().map(|b| b.id.clone()).collect(),
            "all" => return Err("all only works with --plugins; name the plugins to remove".into()),
            n => match known.iter().find(|id| **id == n || short(id) == n) {
                Some(id) => vec![(*id).to_owned()],
                None if bundled.is_empty() => {
                    return Err(format!("unknown plugin {n:?}: this haunt.app bundles no plugins; build it with `macos/make-app.sh --plugins <names>`"));
                }
                None => {
                    let names: Vec<&str> = bundled.iter().map(|b| short(&b.id)).collect();
                    return Err(format!("unknown plugin {n:?}; this haunt.app bundles {}; choose from those, all or none", names.join(", ")));
                }
            },
        };
        for id in found {
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
    }
    Ok(ids)
}

/// The store, opened once for a whole `haunt setup` run.
pub struct Plugins {
    home: PathBuf,
    store: Store,
    host: PluginHost,
}

pub enum Action {
    /// From the bundle folder, with the capability lines the preview showed.
    Install(PathBuf, Vec<String>),
    Remove,
    Nothing,
}

pub struct Step {
    pub id: String,
    pub text: String,
    pub action: Action,
}

/// The ids of plugins installed from an app bundle, read without creating the store.
pub fn installed_bundled(home: &Path) -> Vec<String> {
    let Some(store) = home.join("plugins").is_dir().then(|| Store::open(home).ok()).flatten() else { return vec![] };
    store.list().unwrap_or_default().into_iter().filter(|l| l.entry.source == BUNDLED).map(|l| l.entry.id).collect()
}

/// The bundled plugins as JSON for the app: `source` is where the installed copy came from, if any.
pub fn list_json(home: &Path, bundled: &[Bundled]) -> String {
    // Read-only: Store::open would create the folders.
    let store = home.join("plugins").is_dir().then(|| Store::open(home).ok()).flatten();
    let rows: Vec<serde_json::Value> = bundled
        .iter()
        .map(|b| {
            let source = store.as_ref().and_then(|s| s.installed_source(&b.id).ok().flatten());
            serde_json::json!({
                "id": b.id, "short": short(&b.id), "name": b.name, "description": b.description,
                "installed": source.as_deref() == Some(BUNDLED), "source": source,
            })
        })
        .collect();
    serde_json::Value::Array(rows).to_string()
}

impl Plugins {
    pub fn open(home: &Path) -> Result<Self, String> {
        let store = Store::open(home).map_err(|e| e.to_string())?;
        let host = PluginHost::new().map_err(|e| e.to_string())?;
        Ok(Self { home: home.to_owned(), store, host })
    }

    /// The plan text for one plugin and what applying it does. Previews only read, apart from the compile cache.
    pub fn plan(&self, id: &str, install: bool, bundled: &[Bundled]) -> Result<Step, String> {
        let step = |text: String, action| Step { id: id.to_owned(), text, action };
        if !install {
            return Ok(match self.store.installed_source(id).map_err(|e| e.to_string())? {
                None => step(format!("The plugin {id} is not installed; nothing to remove.\n"), Action::Nothing),
                Some(s) if s != BUNDLED => {
                    return Err(format!("{id} was installed from {s}, not from the app; remove it with `haunt plugin remove {id}`"));
                }
                Some(_) => {
                    let data = self.home.join("plugin-data").join(id);
                    step(format!("Remove the plugin {id}. Its saved data in {} is kept.\n", data.display()), Action::Remove)
                }
            });
        }
        let b = bundled.iter().find(|b| b.id == id).ok_or_else(|| format!("this haunt.app doesn't bundle {id}"))?;
        let (what, prompt) = self.store.preview_bundled_plugin(&b.dir, &self.host).map_err(|e| format!("{id}: {e}"))?;
        let (name, version) = (e(&prompt.name), e(&prompt.version));
        let label = format!("{name} ({id}) {version}");
        let what = match what {
            Preview::Unchanged => return Ok(step(format!("The plugin {label} is already installed; nothing to do.\n"), Action::Nothing)),
            Preview::Install(w) => w,
        };
        let mut text = match &what {
            Installed::New => format!("Install the bundled plugin {label}. It:\n"),
            Installed::Replaced { old_source } => format!("Install the bundled plugin {label} in place of the copy from {}. It:\n", e(old_source)),
            Installed::Updated { .. } if prompt.changed_on_disk => {
                format!("Reinstall the bundled plugin {label}: its files on disk don't match what was installed. It asks for nothing new.\n")
            }
            Installed::Updated { .. } => {
                let from = e(prompt.update_from.as_deref().unwrap_or("?"));
                if prompt.lines.is_empty() {
                    format!("Update the bundled plugin {name} ({id}) from {from} to {version}. It asks for nothing new.\n")
                } else {
                    format!("Update the bundled plugin {name} ({id}) from {from} to {version}. It now also:\n")
                }
            }
        };
        for (line, _) in &prompt.lines {
            text += &format!("  - {}\n", e(line));
        }
        if !matches!(what, Installed::Updated { .. }) && !prompt.always.is_empty() {
            text += &format!("  - {}\n", prompt.always);
        }
        let lines = prompt.lines.into_iter().map(|(l, _)| l).collect();
        Ok(step(text, Action::Install(b.dir.clone(), lines)))
    }

    pub fn apply(&self, step: &Step) -> Result<(), String> {
        let id = &step.id;
        match &step.action {
            Action::Install(dir, shown) => {
                // The user approved the preview's capability lines; anything else, such as a bundle swapped since, is declined.
                let mut same = |p: &Prompt| p.lines.iter().map(|(l, _)| l).eq(shown.iter());
                self.store.install_bundled_plugin(dir, &self.host, &mut same).map_err(|e| match e {
                    StoreError::Declined => format!("{id} asks for other capabilities than the preview showed; not installed"),
                    e => format!("{id}: {e}"),
                })?;
                println!("installed {id}");
            }
            Action::Remove => {
                self.store.remove(id).map_err(|e| format!("{id}: {e}"))?;
                println!("removed {id}");
            }
            Action::Nothing => {}
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_installs_only_what_the_preview_showed() {
        let root = std::env::temp_dir().join(format!("haunt-bundled-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let dir = root.join("bundle/dev.haunt.t");
        std::fs::create_dir_all(&dir).unwrap();
        let manifest = |caps: &str| {
            format!("[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"0.1.0\"\napi = \"0.5\"\nentry = \"plugin.wasm\"\n[capabilities]\n{caps}\n")
        };
        std::fs::write(dir.join(MANIFEST), manifest("sidebar = true")).unwrap();
        // An empty component in binary form.
        std::fs::write(dir.join("plugin.wasm"), [0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00]).unwrap();
        let bundled = vec![Bundled { id: "dev.haunt.t".into(), name: "T".into(), description: String::new(), dir: dir.clone() }];
        let p = Plugins::open(&root.join("home")).unwrap();
        let step = p.plan("dev.haunt.t", true, &bundled).unwrap();

        // The bundle asks for more between the preview and the install.
        std::fs::write(dir.join(MANIFEST), manifest("sidebar = true\nnotifications = true")).unwrap();
        let e = p.apply(&step).unwrap_err();
        assert!(e.contains("other capabilities than the preview showed"), "{e}");
        assert_eq!(p.store.installed_source("dev.haunt.t").unwrap(), None);

        std::fs::write(dir.join(MANIFEST), manifest("sidebar = true")).unwrap();
        p.apply(&step).unwrap();
        assert_eq!(p.store.installed_source("dev.haunt.t").unwrap().as_deref(), Some(BUNDLED));
        let _ = std::fs::remove_dir_all(&root);
    }
}
