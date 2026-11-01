//! Installed plugins under `<home>/plugins` and the lockfile that pins them (plan section 3.5).

use std::fs::{self, DirBuilder};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::event::AgentEvent;
use crate::plugin_cache::{CwasmCache, check_dir, hex, write_atomic};
use crate::plugin_manifest::{ALWAYS, Capabilities, MANIFEST, Manifest};
use crate::plugins::{Decoration, HostRequest, LoadSpec, LoadedPlugin, PaletteItem, PluginError, PluginHost};

pub const LOCKFILE: &str = "plugins.lock";
pub const WASM: &str = "plugin.wasm";
const WASM_CAP: u64 = 64 << 20;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("{0}")]
    Invalid(String),
    #[error("not approved; nothing was installed")]
    Declined,
    #[error("no installed plugin {0}")]
    NotInstalled(String),
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

impl From<PluginError> for StoreError {
    fn from(e: PluginError) -> Self {
        Self::Invalid(e.0)
    }
}
impl From<crate::plugin_cache::CacheError> for StoreError {
    fn from(e: crate::plugin_cache::CacheError) -> Self {
        Self::Invalid(e.to_string())
    }
}
impl From<crate::plugin_manifest::ManifestError> for StoreError {
    fn from(e: crate::plugin_manifest::ManifestError) -> Self {
        Self::Invalid(e.0)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LockEntry {
    pub id: String,
    pub version: String,
    pub source: String,
    pub commit: Option<String>,
    pub sha256_wasm: String,
    pub sha256_manifest: String,
    pub granted: Capabilities,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Lock {
    #[serde(default, rename = "plugin")]
    plugins: Vec<LockEntry>,
}

/// What the user is asked to approve.
#[derive(Debug, Clone)]
pub struct Prompt {
    pub id: String,
    pub name: String,
    pub version: String,
    /// Plain-word capability lines; `true` marks the dangerous ones.
    pub lines: Vec<(String, bool)>,
    pub always: &'static str,
    /// Set on an update; `lines` then holds only the added capabilities.
    pub update_from: Option<String>,
    /// Set by `approve` when the files on disk no longer match the lockfile.
    pub changed_on_disk: bool,
    /// Source of the installed plugin this one would replace, when the source differs.
    pub replaces: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Installed {
    New,
    Replaced { old_source: String },
    Updated { prompted: bool },
}

#[derive(Debug, Clone)]
pub struct Listing {
    pub entry: LockEntry,
    /// None when the files on disk match the lockfile.
    pub problem: Option<String>,
}

pub struct Store {
    home: PathBuf,
}

fn sha(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

fn mkdir_private(dir: &Path) -> Result<(), StoreError> {
    DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    check_dir(dir)?;
    Ok(())
}

fn read_capped(path: &Path) -> Result<Vec<u8>, StoreError> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_file() {
        return Err(StoreError::Invalid(format!("{} is not a regular file", path.display())));
    }
    if meta.len() > WASM_CAP {
        return Err(StoreError::Invalid(format!("{} is larger than {WASM_CAP} bytes", path.display())));
    }
    Ok(fs::read(path)?)
}

/// Default values of the manifest's `[settings]`, as the JSON `init` receives.
fn default_settings(m: &Manifest) -> String {
    let defaults: serde_json::Map<String, serde_json::Value> = m
        .settings
        .iter()
        .filter_map(|(k, v)| Some((k.clone(), serde_json::to_value(v.get("default")?).ok()?)))
        .collect();
    serde_json::Value::Object(defaults).to_string()
}

impl Store {
    /// `home` is `~/.haunt`; `plugins/` is created 0700 and refused if others can write it.
    pub fn open(home: &Path) -> Result<Self, StoreError> {
        mkdir_private(home)?;
        mkdir_private(&home.join("plugins"))?;
        Ok(Self { home: home.to_owned() })
    }

    pub fn plugins_dir(&self) -> PathBuf {
        self.home.join("plugins")
    }

    fn cache_dir(&self) -> PathBuf {
        self.home.join("cache")
    }

    fn data_dir(&self, id: &str) -> PathBuf {
        self.home.join("plugin-data").join(id)
    }

    fn read_lock(&self) -> Result<Lock, StoreError> {
        let path = self.home.join(LOCKFILE);
        let meta = match fs::symlink_metadata(&path) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Lock::default()),
            Err(e) => return Err(e.into()),
        };
        if !meta.is_file() || meta.uid() != unsafe { libc::getuid() } || meta.mode() & 0o022 != 0 {
            return Err(StoreError::Invalid(format!("{} must be a file owned by you that nobody else can write", path.display())));
        }
        toml::from_str(&fs::read_to_string(&path)?).map_err(|e| StoreError::Invalid(format!("{LOCKFILE}: {e}")))
    }

    fn write_lock(&self, lock: &Lock) -> Result<(), StoreError> {
        let text = toml::to_string(lock).map_err(|e| StoreError::Invalid(e.to_string()))?;
        write_atomic(&self.home.join(LOCKFILE), text.as_bytes())?;
        Ok(())
    }

    /// Validates the manifest and component under `src`, asks `approve` when capabilities are new, and installs.
    pub fn install(&self, src: &Path, host: &PluginHost, approve: &mut dyn FnMut(&Prompt) -> bool) -> Result<Installed, StoreError> {
        let s = src.to_string_lossy();
        if s.contains("://") || s.starts_with("git@") || (!src.exists() && s.contains('@')) {
            return Err(StoreError::Invalid("only local paths can be installed in this version; git URLs and id@version come later".into()));
        }
        let src = src.canonicalize()?;
        let manifest_bytes = read_capped(&src.join(MANIFEST))?;
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes))?;
        let wasm = read_capped(&src.join(&manifest.plugin.entry))?;
        let caps = &manifest.capabilities;
        let id = manifest.plugin.id.clone();

        let cache = CwasmCache::open(&self.cache_dir())?;
        let (component, _) = host.compile_cached(&wasm, &cache).map_err(|e| StoreError::Invalid(format!("entry is not a valid component: {e}")))?;
        host.check_links(&component, caps)
            .map_err(|e| StoreError::Invalid(format!("plugin uses an import its manifest does not request: {e}")))?;

        let mut lock = self.read_lock()?;
        let old = lock.plugins.iter().find(|p| p.id == id).cloned();
        let mut prompt = Prompt {
            id: id.clone(),
            name: manifest.plugin.name.clone(),
            version: manifest.plugin.version.clone(),
            lines: caps.describe(),
            always: ALWAYS,
            update_from: None,
            changed_on_disk: false,
            replaces: None,
        };
        let source = src.display().to_string();
        // Only a same-source update that adds nothing skips the prompt; an id is not an identity.
        let prompted = match &old {
            Some(o) if o.source == source => {
                prompt.update_from = Some(o.version.clone());
                prompt.lines = caps.added_since(&o.granted);
                !prompt.lines.is_empty()
            }
            Some(o) => {
                prompt.replaces = Some(o.source.clone());
                true
            }
            None => true,
        };
        if prompted && !approve(&prompt) {
            return Err(StoreError::Declined);
        }

        let dest = self.plugins_dir().join(&id);
        let staging = self.plugins_dir().join(format!(".{id}.staging"));
        let _ = fs::remove_dir_all(&staging);
        mkdir_private(&staging)?;
        write_atomic(&staging.join(MANIFEST), &manifest_bytes)?;
        write_atomic(&staging.join(WASM), &wasm)?;
        if dest.exists() {
            fs::remove_dir_all(&dest)?;
        }
        fs::rename(&staging, &dest)?;

        let entry = LockEntry {
            id: id.clone(),
            version: manifest.plugin.version.clone(),
            source,
            commit: None,
            sha256_wasm: sha(&wasm),
            sha256_manifest: sha(&manifest_bytes),
            granted: caps.clone(),
        };
        lock.plugins.retain(|p| p.id != id);
        lock.plugins.push(entry);
        self.write_lock(&lock)?;
        Ok(match old {
            Some(o) if prompt.replaces.is_some() => Installed::Replaced { old_source: o.source },
            Some(_) => Installed::Updated { prompted },
            None => Installed::New,
        })
    }

    /// Re-approves an installed plugin whose files changed on disk, pinning the new hashes.
    pub fn approve(&self, id: &str, host: &PluginHost, approve: &mut dyn FnMut(&Prompt) -> bool) -> Result<(), StoreError> {
        let mut lock = self.read_lock()?;
        let Some(pos) = lock.plugins.iter().position(|p| p.id == id) else {
            return Err(StoreError::NotInstalled(id.to_owned()));
        };
        let dir = self.plugins_dir().join(id);
        let manifest_bytes = read_capped(&dir.join(MANIFEST))?;
        let wasm = read_capped(&dir.join(WASM))?;
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes))?;
        if manifest.plugin.id != id {
            return Err(StoreError::Invalid(format!("installed manifest is for {}, not {id}", manifest.plugin.id)));
        }
        let cache = CwasmCache::open(&self.cache_dir())?;
        let (component, _) = host.compile_cached(&wasm, &cache)?;
        host.check_links(&component, &manifest.capabilities)?;
        let e = &mut lock.plugins[pos];
        let prompt = Prompt {
            id: id.to_owned(),
            name: manifest.plugin.name.clone(),
            version: manifest.plugin.version.clone(),
            lines: manifest.capabilities.describe(),
            always: ALWAYS,
            update_from: None,
            changed_on_disk: e.sha256_wasm != sha(&wasm) || e.sha256_manifest != sha(&manifest_bytes),
            replaces: None,
        };
        if !approve(&prompt) {
            return Err(StoreError::Declined);
        }
        e.version = manifest.plugin.version;
        e.sha256_wasm = sha(&wasm);
        e.sha256_manifest = sha(&manifest_bytes);
        e.granted = manifest.capabilities;
        self.write_lock(&lock)
    }

    /// Removes the code and the lock entry; `plugin-data/<id>` is kept so a reinstall keeps its state.
    pub fn remove(&self, id: &str) -> Result<(), StoreError> {
        let mut lock = self.read_lock()?;
        let before = lock.plugins.len();
        lock.plugins.retain(|p| p.id != id);
        let dir = self.plugins_dir().join(id);
        if before == lock.plugins.len() && !dir.exists() {
            return Err(StoreError::NotInstalled(id.to_owned()));
        }
        if dir.exists() {
            fs::remove_dir_all(&dir)?;
        }
        self.write_lock(&lock)
    }

    pub fn list(&self) -> Result<Vec<Listing>, StoreError> {
        Ok(self.read_lock()?.plugins.into_iter().map(|entry| Listing { problem: self.verify(&entry).err().map(|e| e.to_string()), entry }).collect())
    }

    /// The installed manifest and wasm, only if both still hash to what was approved.
    fn verify(&self, e: &LockEntry) -> Result<(Manifest, Vec<u8>), StoreError> {
        let dir = self.plugins_dir().join(&e.id);
        let manifest_bytes = read_capped(&dir.join(MANIFEST))?;
        let wasm = read_capped(&dir.join(WASM))?;
        if sha(&wasm) != e.sha256_wasm {
            return Err(StoreError::Invalid(format!("{}: plugin.wasm does not match the lockfile; run `haunt plugin approve {}`", e.id, e.id)));
        }
        if sha(&manifest_bytes) != e.sha256_manifest {
            return Err(StoreError::Invalid(format!("{}: manifest does not match the lockfile; run `haunt plugin approve {}`", e.id, e.id)));
        }
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes))?;
        Ok((manifest, wasm))
    }

    /// Loads every pinned plugin with exactly the capabilities the user granted.
    pub fn load_all(&self, host: &PluginHost) -> Result<PluginSet, StoreError> {
        let mut set = PluginSet { plugins: Vec::new(), errors: Vec::new() };
        for e in self.read_lock()?.plugins {
            let loaded = self.verify(&e).and_then(|(manifest, wasm)| {
                let data = self.data_dir(&e.id);
                mkdir_private(&data)?;
                let spec = LoadSpec {
                    id: e.id.clone(),
                    caps: e.granted.clone(),
                    kv_path: Some(data.join("kv.json")),
                    settings_json: default_settings(&manifest),
                };
                Ok(host.load_bytes(&wasm, &self.cache_dir(), &spec)?.0)
            });
            match loaded {
                Ok(p) => set.plugins.push((e.granted, p)),
                Err(err) => set.errors.push(format!("{}: {err}", e.id)),
            }
        }
        Ok(set)
    }
}

/// The user's installed plugins, loaded.
pub struct PluginSet {
    plugins: Vec<(Capabilities, LoadedPlugin)>,
    errors: Vec<String>,
}

impl PluginSet {
    /// Plugins that were not loaded, with the reason (hash mismatch, link failure, trap in `init`).
    pub fn errors(&self) -> &[String] {
        &self.errors
    }

    pub fn ids(&self) -> Vec<String> {
        self.plugins.iter().map(|(_, p)| p.id().to_owned()).collect()
    }

    /// With no mode: every registered command and mode. With a mode word: the owning plugins' items.
    pub fn palette_items(&mut self, mode: Option<&str>, query: &str) -> Vec<PaletteItem> {
        let q = query.to_lowercase();
        let mut out = Vec::new();
        for (_, p) in self.plugins.iter_mut().filter(|(_, p)| p.disabled().is_none()) {
            match mode {
                None => out.extend(p.palette().iter().filter(|i| q.is_empty() || i.title.to_lowercase().contains(&q)).cloned()),
                Some(word) => {
                    if p.palette().iter().any(|i| i.is_mode && i.id == word)
                        && let Ok(items) = p.palette_items(word, query)
                    {
                        out.extend(items);
                    }
                }
            }
        }
        out
    }

    pub fn invoke(&mut self, plugin_id: &str, item_id: &str) -> Result<(), PluginError> {
        let (_, p) = self
            .plugins
            .iter_mut()
            .find(|(_, p)| p.id() == plugin_id)
            .ok_or_else(|| PluginError(format!("no loaded plugin {plugin_id}")))?;
        p.on_action(item_id, "")
    }

    /// Delivers `event` to plugins whose `events` grant covers it.
    pub fn on_event(&mut self, event: &AgentEvent) -> Vec<(String, Decoration)> {
        let mut out = Vec::new();
        for (caps, p) in &mut self.plugins {
            if caps.wants_event(&event.kind)
                && let Ok(Some(d)) = p.on_event(event)
            {
                out.push((p.id().to_owned(), d));
            }
        }
        out
    }

    pub fn take_requests(&mut self) -> Vec<HostRequest> {
        self.plugins.iter_mut().flat_map(|(_, p)| p.take_requests()).collect()
    }

    pub fn take_logs(&mut self) -> Vec<(String, String)> {
        self.plugins.iter_mut().flat_map(|(_, p)| {
            let id = p.id().to_owned();
            p.take_logs().into_iter().map(move |l| (id.clone(), l))
        }).collect()
    }
}

/// `$HAUNT_HOME`, else `~/.haunt`.
pub fn default_home() -> PathBuf {
    if let Some(h) = std::env::var_os("HAUNT_HOME") {
        return PathBuf::from(h);
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".haunt")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("haunt-store-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn src(dir: &Path, caps: &str) -> PathBuf {
        let s = dir.join("src");
        fs::create_dir_all(&s).unwrap();
        fs::write(
            s.join(MANIFEST),
            format!("[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"0.1.0\"\napi = \"0.1\"\nentry = \"p.wasm\"\n[capabilities]\n{caps}\n"),
        )
        .unwrap();
        fs::write(s.join("p.wasm"), "(component)").unwrap();
        s
    }

    #[test]
    fn install_pins_hashes_and_update_reprompts_only_on_growth() {
        let dir = tempdir("pin");
        let home = dir.join("home");
        let store = Store::open(&home).unwrap();
        let host = PluginHost::new().unwrap();
        let s = src(&dir, "events = [\"agent.tool\"]");

        assert!(matches!(store.install(&s, &host, &mut |_| false), Err(StoreError::Declined)));
        assert!(store.list().unwrap().is_empty());

        let mut seen = Vec::new();
        assert_eq!(store.install(&s, &host, &mut |p| { seen.push(p.lines.clone()); true }).unwrap(), Installed::New);
        assert!(seen[0][0].0.contains("agent.tool"));
        let l = store.list().unwrap();
        assert_eq!(l.len(), 1);
        assert!(l[0].problem.is_none());
        assert_eq!(fs::metadata(home.join("plugins")).unwrap().mode() & 0o777, 0o700);

        let r = store.install(&s, &host, &mut |_| panic!("same capabilities must not prompt")).unwrap();
        assert_eq!(r, Installed::Updated { prompted: false });

        let s = src(&dir, "events = [\"agent.tool\", \"agent.task\"]\nnotifications = true");
        assert!(matches!(store.install(&s, &host, &mut |_| false), Err(StoreError::Declined)));
        assert!(!store.list().unwrap()[0].entry.granted.notifications, "declined update keeps the old grant");
        let mut added = Vec::new();
        store.install(&s, &host, &mut |p| { assert!(p.replaces.is_none() && p.update_from.is_some()); added = p.lines.clone(); true }).unwrap();
        assert_eq!(added.len(), 2, "{added:?}");
        assert!(store.list().unwrap()[0].entry.granted.notifications);

        store.remove("dev.haunt.t").unwrap();
        assert!(store.list().unwrap().is_empty());
        assert!(!home.join("plugins/dev.haunt.t").exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn same_id_from_another_source_is_a_new_install() {
        let dir = tempdir("takeover");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let first = src(&dir, "events = [\"agent.tool\"]\nnotifications = true");
        store.install(&first, &host, &mut |_| true).unwrap();
        let old_source = first.canonicalize().unwrap().display().to_string();

        let other = dir.join("other");
        fs::create_dir_all(&other).unwrap();
        fs::write(other.join(MANIFEST), fs::read(first.join(MANIFEST)).unwrap()).unwrap();
        fs::write(other.join("p.wasm"), "(component (core module))").unwrap();

        let mut prompt = None;
        assert!(matches!(store.install(&other, &host, &mut |p| { prompt = Some(p.clone()); false }), Err(StoreError::Declined)));
        let p = prompt.expect("takeover must prompt even with the same capabilities");
        assert_eq!(p.replaces.as_deref(), Some(old_source.as_str()));
        assert_eq!(p.lines.len(), 2, "full capability list, not a diff: {:?}", p.lines);
        assert!(p.update_from.is_none());
        assert_eq!(store.list().unwrap()[0].entry.source, old_source, "declined takeover keeps the original");
        assert!(store.list().unwrap()[0].problem.is_none());

        let r = store.install(&other, &host, &mut |_| true).unwrap();
        assert_eq!(r, Installed::Replaced { old_source });
        assert_eq!(store.list().unwrap()[0].entry.source, other.canonicalize().unwrap().display().to_string());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn tampered_files_fail_verification_until_approved() {
        let dir = tempdir("tamper");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        store.install(&src(&dir, ""), &host, &mut |_| true).unwrap();
        fs::write(store.plugins_dir().join("dev.haunt.t").join(WASM), "(component (core module))").unwrap();
        let p = store.list().unwrap()[0].problem.clone().unwrap();
        assert!(p.contains("does not match the lockfile"), "{p}");

        let mut changed = false;
        store.approve("dev.haunt.t", &host, &mut |p| { changed = p.changed_on_disk; true }).unwrap();
        assert!(changed);
        assert!(store.list().unwrap()[0].problem.is_none());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn terminal_read_and_remote_sources_are_rejected() {
        let dir = tempdir("reject");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let e = store.install(&src(&dir, "terminal_read = true"), &host, &mut |_| true).unwrap_err().to_string();
        assert!(e.contains("terminal_read is not supported"), "{e}");
        let e = store.install(Path::new("https://github.com/x/y"), &host, &mut |_| true).unwrap_err().to_string();
        assert!(e.contains("only local paths"), "{e}");
        assert!(store.list().unwrap().is_empty());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn writable_lockfile_is_refused() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempdir("lockperm");
        let home = dir.join("home");
        let store = Store::open(&home).unwrap();
        fs::write(home.join(LOCKFILE), "").unwrap();
        fs::set_permissions(home.join(LOCKFILE), fs::Permissions::from_mode(0o666)).unwrap();
        assert!(store.list().is_err());
        fs::remove_dir_all(dir).unwrap();
    }
}
