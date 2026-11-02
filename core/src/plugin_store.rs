//! Installed plugins under `<home>/plugins` and the lockfile that pins them (plan section 3.5).

use std::fs::{self, DirBuilder};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use wasmtime::component::Linker;

use crate::event::AgentEvent;
use crate::ids::hex;
use crate::model::CoreHandle;
use crate::plugin_cache::{CwasmCache, check_dir, write_atomic};
use crate::plugin_manifest::{ALWAYS, Capabilities, MANIFEST, Manifest, valid_id};
use crate::plugin_theme::{Theme, ThemeToken};
use crate::plugins::{Decoration, HostRequest, HostState, LoadSpec, LoadedPlugin, PaletteItem, PluginError, PluginHost, RowMenuItem};

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

/// `source` of a plugin that ships inside the app.
pub const BUNDLED: &str = "bundled";

#[derive(Debug, Default, Serialize, Deserialize)]
struct Lock {
    /// Bundled plugins the user removed; they are never installed again.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    removed_bundled: Vec<String>,
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

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn sha(bytes: &[u8]) -> String {
    hex(&digest(bytes))
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

    /// `plugins/<id>` for a valid id: a direct child of `plugins/` that is not a symlink, if it exists.
    fn plugin_dir(&self, id: &str) -> Result<PathBuf, StoreError> {
        if !valid_id(id) {
            return Err(StoreError::Invalid(format!("{id:?} is not a plugin id")));
        }
        let plugins = self.plugins_dir();
        let dir = plugins.join(id);
        if dir.parent() != Some(plugins.as_path()) {
            return Err(StoreError::Invalid(format!("{id:?} is not a plugin id")));
        }
        match fs::symlink_metadata(&dir) {
            Ok(m) if m.file_type().is_symlink() => Err(StoreError::Invalid(format!("{} is a symlink", dir.display()))),
            Ok(m) if !m.is_dir() => Err(StoreError::Invalid(format!("{} is not a directory", dir.display()))),
            _ => Ok(dir),
        }
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

        let wasm_digest = digest(&wasm);
        let cache = CwasmCache::open(&self.cache_dir())?;
        let (component, _) = host.compile_cached(&wasm, &wasm_digest, &cache).map_err(|e| StoreError::Invalid(format!("entry is not a valid component: {e}")))?;
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

        self.put(&id, &manifest_bytes, &wasm)?;
        let entry = LockEntry {
            id: id.clone(),
            version: manifest.plugin.version.clone(),
            source,
            commit: None,
            sha256_wasm: hex(&wasm_digest),
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

    /// Replaces `plugins/<id>` with the given files, through a staging directory.
    fn put(&self, id: &str, manifest_bytes: &[u8], wasm: &[u8]) -> Result<(), StoreError> {
        let dest = self.plugins_dir().join(id);
        let staging = self.plugins_dir().join(format!(".{id}.staging"));
        let _ = fs::remove_dir_all(&staging);
        mkdir_private(&staging)?;
        write_atomic(&staging.join(MANIFEST), manifest_bytes)?;
        write_atomic(&staging.join(WASM), wasm)?;
        if dest.exists() {
            fs::remove_dir_all(&dest)?;
        }
        fs::rename(&staging, &dest)?;
        Ok(())
    }

    /// Installs or updates the plugins shipped in `dir` (`<dir>/<id>/haunt-plugin.toml` and `plugin.wasm`)
    /// without asking: they come inside the signed app. A bundled update that asks for more than was
    /// granted is put on disk unpinned, so it stays off until `haunt plugin approve`. A copy installed
    /// from elsewhere, or one the user removed, is left alone. Returns one line per plugin it skipped.
    pub fn install_bundled(&self, dir: &Path, host: &PluginHost) -> Result<Vec<String>, StoreError> {
        let mut lock = self.read_lock()?;
        let mut errors = Vec::new();
        let mut changed = false;
        let entries = match fs::read_dir(dir) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(errors),
            r => r?,
        };
        let mut entries: Vec<_> = entries.filter_map(Result::ok).map(|e| e.path()).collect();
        entries.sort();
        for src in entries {
            let name = src.file_name().unwrap_or_default().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            match self.bundled_one(&src, &name, host, &mut lock) {
                Ok(c) => changed |= c,
                Err(e) => errors.push(format!("{name} (bundled): {e}")),
            }
        }
        if changed {
            self.write_lock(&lock)?;
        }
        Ok(errors)
    }

    /// Whether the lockfile changed.
    fn bundled_one(&self, src: &Path, id: &str, host: &PluginHost, lock: &mut Lock) -> Result<bool, StoreError> {
        if lock.removed_bundled.iter().any(|r| r == id) {
            return Ok(false);
        }
        let old = lock.plugins.iter().position(|p| p.id == id);
        if old.is_some_and(|i| lock.plugins[i].source != BUNDLED) {
            return Ok(false);
        }
        let manifest_bytes = read_capped(&src.join(MANIFEST))?;
        let wasm = read_capped(&src.join(WASM))?;
        let wasm_digest = digest(&wasm);
        let (wasm_sha, manifest_sha) = (hex(&wasm_digest), sha(&manifest_bytes));
        if old.is_some_and(|i| lock.plugins[i].sha256_wasm == wasm_sha && lock.plugins[i].sha256_manifest == manifest_sha) {
            return Ok(false);
        }
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes))?;
        if manifest.plugin.id != id {
            return Err(StoreError::Invalid(format!("its manifest is for {}", manifest.plugin.id)));
        }
        let dest = self.plugin_dir(id)?;
        let grew = old.is_some_and(|i| !manifest.capabilities.added_since(&lock.plugins[i].granted).is_empty());
        let on_disk = read_capped(&dest.join(WASM)).is_ok_and(|w| w == wasm)
            && read_capped(&dest.join(MANIFEST)).is_ok_and(|m| m == manifest_bytes);
        if grew && on_disk {
            return Ok(false);
        }
        let cache = CwasmCache::open(&self.cache_dir())?;
        let (component, _) = host.compile_cached(&wasm, &wasm_digest, &cache)?;
        host.check_links(&component, &manifest.capabilities)?;
        self.put(id, &manifest_bytes, &wasm)?;
        if grew {
            return Ok(false);
        }
        let entry = LockEntry {
            id: id.to_owned(),
            version: manifest.plugin.version.clone(),
            source: BUNDLED.into(),
            commit: None,
            sha256_wasm: wasm_sha,
            sha256_manifest: manifest_sha,
            granted: manifest.capabilities,
        };
        match old {
            Some(i) => lock.plugins[i] = entry,
            None => lock.plugins.push(entry),
        }
        Ok(true)
    }

    /// Re-approves an installed plugin whose files changed on disk, pinning the new hashes.
    pub fn approve(&self, id: &str, host: &PluginHost, approve: &mut dyn FnMut(&Prompt) -> bool) -> Result<(), StoreError> {
        let mut lock = self.read_lock()?;
        let dir = self.plugin_dir(id)?;
        let Some(pos) = lock.plugins.iter().position(|p| p.id == id) else {
            return Err(StoreError::NotInstalled(id.to_owned()));
        };
        let manifest_bytes = read_capped(&dir.join(MANIFEST))?;
        let wasm = read_capped(&dir.join(WASM))?;
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes))?;
        if manifest.plugin.id != id {
            return Err(StoreError::Invalid(format!("installed manifest is for {}, not {id}", manifest.plugin.id)));
        }
        let wasm_digest = digest(&wasm);
        let (wasm_sha, manifest_sha) = (hex(&wasm_digest), sha(&manifest_bytes));
        let cache = CwasmCache::open(&self.cache_dir())?;
        let (component, _) = host.compile_cached(&wasm, &wasm_digest, &cache)?;
        host.check_links(&component, &manifest.capabilities)?;
        let e = &mut lock.plugins[pos];
        let prompt = Prompt {
            id: id.to_owned(),
            name: manifest.plugin.name.clone(),
            version: manifest.plugin.version.clone(),
            lines: manifest.capabilities.describe(),
            always: ALWAYS,
            update_from: None,
            changed_on_disk: e.sha256_wasm != wasm_sha || e.sha256_manifest != manifest_sha,
            replaces: None,
        };
        if !approve(&prompt) {
            return Err(StoreError::Declined);
        }
        e.version = manifest.plugin.version;
        e.sha256_wasm = wasm_sha;
        e.sha256_manifest = manifest_sha;
        e.granted = manifest.capabilities;
        self.write_lock(&lock)
    }

    /// Removes the code and the lock entry of a plugin in the lockfile; `plugin-data/<id>` is kept
    /// so a reinstall keeps its state. A removed bundled plugin stays removed.
    pub fn remove(&self, id: &str) -> Result<(), StoreError> {
        let dir = self.plugin_dir(id)?;
        let mut lock = self.read_lock()?;
        let Some(pos) = lock.plugins.iter().position(|p| p.id == id) else {
            return Err(StoreError::NotInstalled(id.to_owned()));
        };
        if lock.plugins.remove(pos).source == BUNDLED && !lock.removed_bundled.iter().any(|r| r == id) {
            lock.removed_bundled.push(id.to_owned());
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
    fn verify(&self, e: &LockEntry) -> Result<(Manifest, Vec<u8>, [u8; 32]), StoreError> {
        let dir = self.plugin_dir(&e.id)?;
        let manifest_bytes = read_capped(&dir.join(MANIFEST))?;
        let wasm = read_capped(&dir.join(WASM))?;
        let wasm_digest = digest(&wasm);
        if hex(&wasm_digest) != e.sha256_wasm {
            return Err(StoreError::Invalid(format!("{}: plugin.wasm does not match the lockfile; run `haunt plugin approve {}`", e.id, e.id)));
        }
        if sha(&manifest_bytes) != e.sha256_manifest {
            return Err(StoreError::Invalid(format!("{}: manifest does not match the lockfile; run `haunt plugin approve {}`", e.id, e.id)));
        }
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes))?;
        Ok((manifest, wasm, wasm_digest))
    }

    /// Loads every pinned plugin with exactly the capabilities the user granted; `core` backs the
    /// `decisions` and `allowlist` imports.
    pub fn load_all(&self, host: &PluginHost, core: Option<&CoreHandle>) -> Result<PluginSet, StoreError> {
        let mut set = PluginSet { plugins: Vec::new(), errors: Vec::new() };
        let cache = CwasmCache::open(&self.cache_dir());
        // Plugins with the same grants share a linker.
        let mut linkers: Vec<(Capabilities, Linker<HostState>)> = Vec::new();
        for e in self.read_lock()?.plugins {
            let loaded = self.verify(&e).and_then(|(manifest, wasm, wasm_digest)| {
                let cache = cache.as_ref().map_err(|err| StoreError::Invalid(err.to_string()))?;
                let data = self.data_dir(&e.id);
                mkdir_private(&data)?;
                let spec = LoadSpec {
                    id: e.id.clone(),
                    caps: e.granted.clone(),
                    kv_path: Some(data.join("kv.json")),
                    settings_json: default_settings(&manifest),
                    haunt_dir: Some(self.home.clone()),
                    core: core.cloned(),
                };
                let (component, _) = host.compile_cached(&wasm, &wasm_digest, cache)?;
                let i = match linkers.iter().position(|(c, _)| *c == e.granted) {
                    Some(i) => i,
                    None => {
                        linkers.push((e.granted.clone(), host.linker(&e.granted)?));
                        linkers.len() - 1
                    }
                };
                Ok(host.instantiate_with(&component, &spec, &linkers[i].1)?)
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

    /// Lists problems found before loading, such as a bundled plugin that couldn't be installed.
    pub fn add_errors(&mut self, errors: Vec<String>) {
        self.errors.splice(0..0, errors);
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
        self.plugin(plugin_id)?.on_action(item_id, "")
    }

    fn plugin(&mut self, plugin_id: &str) -> Result<&mut LoadedPlugin, PluginError> {
        self.plugins
            .iter_mut()
            .map(|(_, p)| p)
            .find(|p| p.id() == plugin_id)
            .ok_or_else(|| PluginError(format!("no loaded plugin {plugin_id}")))
    }

    /// Every loaded plugin's context-menu entries for the row of `surface`.
    pub fn row_menu(&mut self, surface: &str) -> Vec<RowMenuItem> {
        self.plugins
            .iter_mut()
            .filter(|(_, p)| p.disabled().is_none())
            .flat_map(|(_, p)| p.row_menu(surface).unwrap_or_default())
            .collect()
    }

    /// A chosen context-menu entry: `on-action(item_id, surface)`.
    pub fn invoke_row_item(&mut self, plugin_id: &str, item_id: &str, surface: &str) -> Result<(), PluginError> {
        self.plugin(plugin_id)?.on_action(item_id, surface)
    }

    /// A row dropped into snapshot group `group` above `before`; only `sidebar` plugins hear it.
    pub fn row_moved(&mut self, surface: &str, group: &str, before: Option<&str>) {
        for (caps, p) in &mut self.plugins {
            if caps.sidebar {
                let _ = p.on_row_moved(surface, group, before);
            }
        }
    }

    /// Delivers `event` to plugins whose `events` grant covers it; `verified` as the core decided it.
    pub fn on_event(&mut self, event: &AgentEvent, verified: bool) -> Vec<(String, Decoration)> {
        let mut out = Vec::new();
        for (caps, p) in &mut self.plugins {
            if caps.wants_event(&event.kind, verified)
                && let Ok(Some(d)) = p.on_event(event, verified)
            {
                out.push((p.id().to_owned(), d));
            }
        }
        out
    }

    /// Gives every plugin the app's new theme and calls its `on-theme-changed`; a bad name is refused.
    pub fn set_theme(&mut self, name: &str, tokens: Vec<ThemeToken>) -> Result<(), String> {
        let theme = Arc::new(Theme::new(name, tokens)?);
        for (_, p) in self.plugins.iter_mut().filter(|(_, p)| p.disabled().is_none()) {
            let _ = p.set_theme(theme.clone());
        }
        Ok(())
    }

    fn pending_requests(&self) -> usize {
        self.plugins.iter().map(|(_, p)| p.pending_requests()).sum()
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

/// Sends the core's events to `set`'s plugins for as long as `set` lives. Row decorations are
/// dropped until the snapshot has a place for them.
pub fn attach(core: &crate::Core, set: &Arc<Mutex<PluginSet>>) {
    let weak = Arc::downgrade(set);
    core.set_event_tap(Some(Arc::new(move |event, verified| {
        let Some(set) = weak.upgrade() else { return false };
        let mut set = crate::sync::lock(&set);
        set.on_event(event, verified);
        // Any left, not just new ones: a drain that found the set busy took none.
        set.pending_requests() > 0
    })));
}

/// `take_requests` without waiting: empty while a plugin is handling an event, whose tap then
/// signals again (see `attach`). The UI thread drains with this, so a slow plugin never stalls it.
pub fn take_requests_now(set: &Mutex<PluginSet>) -> Vec<HostRequest> {
    match set.try_lock() {
        Ok(mut s) => s.take_requests(),
        Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner().take_requests(),
        Err(std::sync::TryLockError::WouldBlock) => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testdir::TempDir;

    fn tempdir(tag: &str) -> TempDir {
        TempDir::created(&format!("store-{tag}"))
    }

    #[test]
    fn draining_never_waits_for_a_busy_set() {
        let set = Arc::new(Mutex::new(PluginSet { plugins: Vec::new(), errors: Vec::new() }));
        let (held, release) = (std::sync::mpsc::channel(), std::sync::mpsc::channel::<()>());
        let s = set.clone();
        let th = std::thread::spawn(move || {
            let _busy = s.lock().unwrap();
            held.0.send(()).unwrap();
            let _ = release.1.recv();
        });
        held.1.recv().unwrap();
        let t = std::time::Instant::now();
        assert!(take_requests_now(&set).is_empty());
        assert!(t.elapsed() < std::time::Duration::from_millis(100));
        release.0.send(()).unwrap();
        th.join().unwrap();
        assert!(take_requests_now(&set).is_empty(), "free again");
    }

    fn src(dir: &Path, caps: &str) -> PathBuf {
        let s = dir.join("src");
        fs::create_dir_all(&s).unwrap();
        fs::write(
            s.join(MANIFEST),
            format!("[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"0.1.0\"\napi = \"0.4\"\nentry = \"p.wasm\"\n[capabilities]\n{caps}\n"),
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
    }

    #[test]
    fn remove_and_approve_refuse_paths_and_unlisted_ids() {
        let dir = tempdir("traverse");
        let home = dir.join("home");
        let store = Store::open(&home).unwrap();
        let host = PluginHost::new().unwrap();
        store.install(&src(&dir, ""), &host, &mut |_| true).unwrap();
        fs::write(home.join("keep"), "x").unwrap();
        for id in ["..", "../..", "/", "a/b", ".", "", "dev.haunt.t/..", "../home/plugins/dev.haunt.t"] {
            assert!(matches!(store.remove(id), Err(StoreError::Invalid(_))), "remove {id:?}");
            assert!(matches!(store.approve(id, &host, &mut |_| true), Err(StoreError::Invalid(_))), "approve {id:?}");
        }
        assert!(home.join("keep").exists() && store.plugins_dir().join("dev.haunt.t").exists());

        fs::create_dir(store.plugins_dir().join("dev.haunt.stray")).unwrap();
        assert!(matches!(store.remove("dev.haunt.stray"), Err(StoreError::NotInstalled(_))), "only lockfile entries");
        assert!(store.plugins_dir().join("dev.haunt.stray").exists());
    }

    #[test]
    fn symlinked_plugin_dir_is_never_followed() {
        let dir = tempdir("symlink");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        store.install(&src(&dir, ""), &host, &mut |_| true).unwrap();
        let installed = store.plugins_dir().join("dev.haunt.t");
        let victim = dir.join("victim");
        fs::rename(&installed, &victim).unwrap();
        std::os::unix::fs::symlink(&victim, &installed).unwrap();

        assert!(matches!(store.remove("dev.haunt.t"), Err(StoreError::Invalid(_))));
        assert!(matches!(store.approve("dev.haunt.t", &host, &mut |_| true), Err(StoreError::Invalid(_))));
        assert!(store.list().unwrap()[0].problem.as_deref().unwrap().contains("symlink"));
        assert!(victim.join(WASM).exists(), "the link target is untouched");
    }

    fn bundle(dir: &Path, id: &str, version: &str, caps: &str) -> PathBuf {
        let b = dir.join("bundled");
        fs::create_dir_all(b.join(id)).unwrap();
        fs::write(
            b.join(id).join(MANIFEST),
            format!("[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"{version}\"\napi = \"0.4\"\nentry = \"plugin.wasm\"\n[capabilities]\n{caps}\n"),
        )
        .unwrap();
        fs::write(b.join(id).join(WASM), "(component)").unwrap();
        b
    }

    #[test]
    fn bundled_plugins_install_silently_and_update_only_without_growth() {
        let dir = tempdir("bundled");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let b = bundle(&dir, "dev.haunt.t", "0.1.0", "decisions_read = true");
        assert!(store.install_bundled(&b, &host).unwrap().is_empty());
        let l = store.list().unwrap();
        assert_eq!((l[0].entry.source.as_str(), l[0].problem.as_deref()), (BUNDLED, None));
        assert!(l[0].entry.granted.decisions_read);

        bundle(&dir, "dev.haunt.t", "0.2.0", "");
        store.install_bundled(&b, &host).unwrap();
        let l = store.list().unwrap();
        assert_eq!((l[0].entry.version.as_str(), l[0].problem.as_deref()), ("0.2.0", None));
        assert!(!l[0].entry.granted.decisions_read, "a shrunk grant is pinned as shipped");

        bundle(&dir, "dev.haunt.t", "0.3.0", "notifications = true");
        store.install_bundled(&b, &host).unwrap();
        let l = store.list().unwrap();
        assert_eq!(l[0].entry.version, "0.2.0", "growth is not pinned");
        assert!(!l[0].entry.granted.notifications);
        assert!(l[0].problem.as_deref().is_some_and(|p| p.contains("haunt plugin approve")), "{:?}", l[0].problem);
        assert!(store.load_all(&host, None).unwrap().errors()[0].contains("does not match"));
        store.approve("dev.haunt.t", &host, &mut |_| true).unwrap();
        let l = store.list().unwrap();
        assert_eq!((l[0].entry.version.as_str(), l[0].entry.granted.notifications, l[0].entry.source.as_str()), ("0.3.0", true, BUNDLED));

        store.remove("dev.haunt.t").unwrap();
        store.install_bundled(&b, &host).unwrap();
        assert!(store.list().unwrap().is_empty(), "a removed bundled plugin stays removed");
    }

    #[test]
    fn bundled_plugins_never_replace_a_users_copy_or_another_id() {
        let dir = tempdir("bundled-user");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let mine = src(&dir, "");
        store.install(&mine, &host, &mut |_| true).unwrap();
        let b = bundle(&dir, "dev.haunt.t", "9.0.0", "pty_write = true");
        assert!(store.install_bundled(&b, &host).unwrap().is_empty());
        let l = store.list().unwrap();
        assert_eq!((l[0].entry.version.as_str(), l[0].problem.as_deref()), ("0.1.0", None));
        assert!(!l[0].entry.granted.pty_write);

        let b = bundle(&dir, "dev.haunt.other", "0.1.0", "");
        let e = store.install_bundled(&b, &host).unwrap();
        assert!(e.iter().any(|l| l.contains("dev.haunt.other") && l.contains("manifest is for dev.haunt.t")), "{e:?}");
        assert!(!dir.join("home/plugins/dev.haunt.other").exists());
        assert!(store.install_bundled(&dir.join("missing"), &host).unwrap().is_empty());
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
    }
}
