//! Installed plugins under `<home>/plugins` and the lockfile that pins them (plan section 3.5).

use std::fs::{self, DirBuilder};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use wasmtime::component::Linker;

use crate::ids::hex;
use crate::model::{CoreHandle, Tapped};
use crate::plugin_cache::{CwasmCache, check_dir, write_atomic};
use crate::plugin_manifest::{ALWAYS, Capabilities, MANIFEST, Manifest, valid_id};
use crate::plugin_pack::{self, ThemeContribution};
use crate::plugin_settings::PluginConfig;
use crate::plugin_theme::{Theme, ThemeToken};
use crate::plugin_panel::PanelPlacement;
use crate::plugins::{dropped_fs_grants, HostRequest, HostState, LoadSpec, LoadedPlugin, PaletteItem, PluginError, PluginHost, RowMenuItem};

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
    #[serde(deserialize_with = "known_grants")]
    pub granted: Capabilities,
    /// A data-only plugin's files (`plugin_pack::files_digest`); its `sha256_wasm` is empty.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub sha256_files: String,
}

/// A grant pinned by a newer haunt can name capabilities this one doesn't know; they are dropped,
/// never granted, and the rest still loads.
fn known_grants<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Capabilities, D::Error> {
    let mut table = toml::Table::deserialize(d)?;
    let all = Capabilities { clipboard: Some(String::new()), ..Default::default() };
    let known = toml::Table::try_from(all).map_err(serde::de::Error::custom)?;
    table.retain(|k, _| known.contains_key(k));
    Capabilities::deserialize(table).map_err(serde::de::Error::custom)
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
    /// What every code plugin may do; empty for a data-only one, which runs none.
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

/// What `install_bundled_plugin` would do.
#[derive(Debug, Clone, PartialEq)]
pub enum Preview {
    Install(Installed),
    /// The same files from the same source are installed, and the copy on disk still matches them.
    Unchanged,
}

/// A plugin folder, validated, and what installing it would change.
struct Checked {
    id: String,
    version: String,
    caps: Capabilities,
    manifest_bytes: Vec<u8>,
    wasm: Vec<u8>,
    sha256_wasm: String,
    sha256_manifest: String,
    /// A data-only plugin's files and their digest; empty for a component.
    files: Vec<(String, Vec<u8>)>,
    sha256_files: String,
    source: String,
    prompt: Prompt,
    prompted: bool,
    installed: Installed,
    unchanged: bool,
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
        self.install_inner(src, false, host, approve)
    }

    /// Installs one of the app's own plugins (a `<id>` folder of what `install_bundled` reads), pinned as
    /// `bundled` so later app updates reach it. Asks like `install`, and takes the id off `removed_bundled`.
    pub fn install_bundled_plugin(&self, src: &Path, host: &PluginHost, approve: &mut dyn FnMut(&Prompt) -> bool) -> Result<Installed, StoreError> {
        self.install_inner(src, true, host, approve)
    }

    /// What `install_bundled_plugin` would do and ask, changing nothing but the compile cache.
    pub fn preview_bundled_plugin(&self, src: &Path, host: &PluginHost) -> Result<(Preview, Prompt), StoreError> {
        let c = self.check(src, true, host)?;
        Ok((if c.unchanged { Preview::Unchanged } else { Preview::Install(c.installed) }, c.prompt))
    }

    /// Where the installed plugin with this id came from, if one is installed.
    pub fn installed_source(&self, id: &str) -> Result<Option<String>, StoreError> {
        Ok(self.read_lock()?.plugins.into_iter().find(|p| p.id == id).map(|p| p.source))
    }

    fn install_inner(&self, src: &Path, bundled: bool, host: &PluginHost, approve: &mut dyn FnMut(&Prompt) -> bool) -> Result<Installed, StoreError> {
        let c = self.check(src, bundled, host)?;
        if c.prompted && !approve(&c.prompt) {
            return Err(StoreError::Declined);
        }
        if c.sha256_files.is_empty() {
            self.put(&c.id, &c.manifest_bytes, &c.wasm)?;
        } else {
            self.put_data(&c.id, &c.manifest_bytes, &c.files)?;
        }
        let entry = LockEntry {
            id: c.id.clone(),
            version: c.version,
            source: c.source,
            commit: None,
            sha256_wasm: c.sha256_wasm,
            sha256_manifest: c.sha256_manifest,
            granted: c.caps,
            sha256_files: c.sha256_files,
        };
        let mut lock = self.read_lock()?;
        lock.plugins.retain(|p| p.id != c.id);
        lock.plugins.push(entry);
        if bundled {
            lock.removed_bundled.retain(|r| *r != c.id);
        }
        self.write_lock(&lock)?;
        Ok(c.installed)
    }

    fn check(&self, src: &Path, bundled: bool, host: &PluginHost) -> Result<Checked, StoreError> {
        let s = src.to_string_lossy();
        if s.contains("://") || s.starts_with("git@") || (!src.exists() && s.contains('@')) {
            return Err(StoreError::Invalid("only local paths can be installed in this version; git URLs and id@version come later".into()));
        }
        let src = src.canonicalize()?;
        let manifest_bytes = read_capped(&src.join(MANIFEST))?;
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes))?;
        let id = manifest.plugin.id.clone();
        // launch updates find a bundled plugin by its folder name.
        if bundled && src.file_name() != Some(id.as_ref()) {
            return Err(StoreError::Invalid(format!("its manifest is for {id}")));
        }
        let Some(entry) = manifest.plugin.entry.clone() else {
            return self.check_data(&src, bundled, manifest, manifest_bytes);
        };
        let wasm = read_capped(&src.join(&entry))?;
        let caps = &manifest.capabilities;

        let wasm_digest = digest(&wasm);
        let cache = CwasmCache::open(&self.cache_dir())?;
        let (component, _) = host.compile_cached(&wasm, &wasm_digest, &cache).map_err(|e| StoreError::Invalid(format!("entry is not a valid component: {e}")))?;
        host.check_links(&component, caps)
            .map_err(|e| StoreError::Invalid(format!("plugin uses an import its manifest does not request: {e}")))?;

        let old = self.read_lock()?.plugins.into_iter().find(|p| p.id == id);
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
        let source = if bundled { BUNDLED.to_owned() } else { src.display().to_string() };
        let (wasm_sha, manifest_sha) = (hex(&wasm_digest), sha(&manifest_bytes));
        let same = old.as_ref().is_some_and(|o| o.source == source && o.sha256_wasm == wasm_sha && o.sha256_manifest == manifest_sha);
        // Installing the same files again rewrites them, which repairs a copy changed on disk.
        let intact = same && old.as_ref().is_some_and(|o| self.verify(o).is_ok());
        prompt.changed_on_disk = same && !intact;
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
        let installed = match &old {
            Some(o) if prompt.replaces.is_some() => Installed::Replaced { old_source: o.source.clone() },
            Some(_) => Installed::Updated { prompted },
            None => Installed::New,
        };
        Ok(Checked {
            id,
            version: manifest.plugin.version.clone(),
            caps: caps.clone(),
            manifest_bytes,
            wasm,
            sha256_wasm: wasm_sha,
            sha256_manifest: manifest_sha,
            files: Vec::new(),
            sha256_files: String::new(),
            source,
            prompt,
            prompted,
            installed,
            unchanged: intact,
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

    /// Updates the plugins shipped in `dir` (`<dir>/<id>/haunt-plugin.toml` and `plugin.wasm`, or a theme's files) that are already
    /// installed from the bundle, without asking: they come inside the signed app. It never installs a new
    /// one (`haunt setup --plugins` does). A bundled update that asks for more than was granted is put on
    /// disk unpinned, so it stays off until `haunt plugin approve`. A copy installed from elsewhere, or
    /// one the user removed, is left alone. Returns one line per plugin it skipped.
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
        let Some(i) = lock.plugins.iter().position(|p| p.id == id) else { return Ok(false) };
        if lock.plugins[i].source != BUNDLED {
            return Ok(false);
        }
        let manifest_bytes = read_capped(&src.join(MANIFEST))?;
        if !src.join(WASM).exists() {
            return self.bundled_data_one(src, id, &manifest_bytes, lock, i);
        }
        let wasm = read_capped(&src.join(WASM))?;
        let wasm_digest = digest(&wasm);
        let (wasm_sha, manifest_sha) = (hex(&wasm_digest), sha(&manifest_bytes));
        if lock.plugins[i].sha256_wasm == wasm_sha && lock.plugins[i].sha256_manifest == manifest_sha {
            return Ok(false);
        }
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes))?;
        if manifest.plugin.id != id {
            return Err(StoreError::Invalid(format!("its manifest is for {}", manifest.plugin.id)));
        }
        let dest = self.plugin_dir(id)?;
        let grew = !manifest.capabilities.added_since(&lock.plugins[i].granted).is_empty();
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
            sha256_files: String::new(),
        };
        lock.plugins[i] = entry;
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
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes))?;
        if manifest.plugin.id != id {
            return Err(StoreError::Invalid(format!("installed manifest is for {}, not {id}", manifest.plugin.id)));
        }
        if manifest.plugin.entry.is_none() {
            return self.approve_data(&mut lock, pos, &dir, &manifest, &manifest_bytes, approve);
        }
        let wasm = read_capped(&dir.join(WASM))?;
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
        Ok(self
            .read_lock()?
            .plugins
            .into_iter()
            .map(|entry| {
                let problem = if entry.sha256_wasm.is_empty() { self.verify_data(&entry).err() } else { self.verify(&entry).err().map(|e| e.to_string()) };
                Listing { problem, entry }
            })
            .collect())
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

    /// `load_all_with` and no user settings.
    pub fn load_all(&self, host: &PluginHost, core: Option<&CoreHandle>) -> Result<PluginSet, StoreError> {
        self.load_all_with(host, core, &PluginConfig::default())
    }

    /// Loads every pinned plugin with exactly the capabilities the user granted; `core` backs the
    /// `decisions` and `allowlist` imports, and `config` holds the user's settings for each.
    pub fn load_all_with(&self, host: &PluginHost, core: Option<&CoreHandle>, config: &PluginConfig) -> Result<PluginSet, StoreError> {
        let mut set = PluginSet {
            settings_problems: config.problems.clone(),
            config_tables: config.parsed.then(|| config.tables.clone()),
            core: core.cloned(),
            ..PluginSet::default()
        };
        if let Some(core) = core {
            core.set_row_labels(config.row_labels.clone());
        }
        let cache = CwasmCache::open(&self.cache_dir());
        // Plugins with the same grants share a linker.
        let mut linkers: Vec<(Capabilities, Linker<HostState>)> = Vec::new();
        for e in self.read_lock()?.plugins {
            if e.sha256_wasm.is_empty() {
                match self.verify_data(&e) {
                    Ok(t) if set.themes.iter().any(|o| o.id == t.id) => set.errors.push(format!("{}: theme {} is already installed", e.id, t.id)),
                    Ok(t) => set.themes.push(t),
                    Err(err) => set.errors.push(format!("{}: {err}", e.id)),
                }
                continue;
            }
            set.errors.extend(dropped_fs_grants(&e.granted).into_iter().map(|why| format!("{}: {why}", e.id)));
            let loaded = self.verify(&e).and_then(|(manifest, wasm, wasm_digest)| {
                let cache = cache.as_ref().map_err(|err| StoreError::Invalid(err.to_string()))?;
                let data = self.data_dir(&e.id);
                mkdir_private(&data)?;
                let spec = LoadSpec {
                    id: e.id.clone(),
                    name: manifest.plugin.name.clone(),
                    caps: e.granted.clone(),
                    kv_path: Some(data.join("kv.json")),
                    settings_json: capped_settings(config, &e.id, &manifest.settings, &mut set.settings_problems)
                        .unwrap_or_else(|| PluginConfig::default().settings_json(&e.id, &manifest.settings, &mut Vec::new())),
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
                let p = host.instantiate_with(&component, &spec, &linkers[i].1)?;
                Ok((p, manifest.settings, spec.settings_json))
            });
            match loaded {
                Ok((p, schema, json)) => {
                    set.settings.insert(e.id.clone(), (schema, json));
                    set.plugins.push((e.granted, p));
                }
                Err(err) => set.errors.push(format!("{}: {err}", e.id)),
            }
        }
        Ok(set)
    }
}

/// Data-only plugins: their files are copied and pinned like a component, and nothing runs.
impl Store {
    fn check_data(&self, src: &Path, bundled: bool, manifest: Manifest, manifest_bytes: Vec<u8>) -> Result<Checked, StoreError> {
        let pack = plugin_pack::theme_pack(&manifest)?.ok_or_else(|| StoreError::Invalid("no [contributes.theme]".into()))?;
        let files = plugin_pack::read_files(src, &pack).map_err(StoreError::Invalid)?;
        let id = manifest.plugin.id.clone();
        let caps = manifest.capabilities.clone();
        let old = self.read_lock()?.plugins.into_iter().find(|p| p.id == id);
        let source = if bundled { BUNDLED.to_owned() } else { src.display().to_string() };
        let (files_sha, manifest_sha) = (plugin_pack::files_digest(&files), sha(&manifest_bytes));
        let mut prompt = Prompt {
            id: id.clone(),
            name: manifest.plugin.name.clone(),
            version: manifest.plugin.version.clone(),
            lines: caps.describe(),
            always: "",
            update_from: None,
            changed_on_disk: false,
            replaces: None,
        };
        let same = old.as_ref().is_some_and(|o| o.source == source && o.sha256_files == files_sha && o.sha256_manifest == manifest_sha);
        let intact = same && old.as_ref().is_some_and(|o| self.verify_data(o).is_ok());
        prompt.changed_on_disk = same && !intact;
        let prompted = match &old {
            Some(o) if o.source == source => {
                prompt.update_from = Some(o.version.clone());
                prompt.lines = caps.added_since(&o.granted);
                let new = self.new_fonts(&id, &pack, &files);
                if new > 0 {
                    prompt.lines.push((format!("adds or changes {new} font file(s) in its theme, which can change how text, including the terminal, is drawn"), false));
                }
                !prompt.lines.is_empty()
            }
            Some(o) => {
                prompt.replaces = Some(o.source.clone());
                true
            }
            None => true,
        };
        let installed = match &old {
            Some(o) if prompt.replaces.is_some() => Installed::Replaced { old_source: o.source.clone() },
            Some(_) => Installed::Updated { prompted },
            None => Installed::New,
        };
        Ok(Checked {
            id,
            version: manifest.plugin.version.clone(),
            caps,
            manifest_bytes,
            wasm: Vec::new(),
            sha256_wasm: String::new(),
            sha256_manifest: manifest_sha,
            files,
            sha256_files: files_sha,
            source,
            prompt,
            prompted,
            installed,
            unchanged: intact,
        })
    }

    /// `bundled_one` for a data-only plugin: the same rules, with its files pinned instead of a component.
    fn bundled_data_one(&self, src: &Path, id: &str, manifest_bytes: &[u8], lock: &mut Lock, i: usize) -> Result<bool, StoreError> {
        let manifest = Manifest::parse(&String::from_utf8_lossy(manifest_bytes))?;
        if manifest.plugin.id != id {
            return Err(StoreError::Invalid(format!("its manifest is for {}", manifest.plugin.id)));
        }
        let pack = plugin_pack::theme_pack(&manifest)?.ok_or_else(|| StoreError::Invalid("no [contributes.theme]".into()))?;
        let files = plugin_pack::read_files(src, &pack).map_err(StoreError::Invalid)?;
        let (files_sha, manifest_sha) = (plugin_pack::files_digest(&files), sha(manifest_bytes));
        if lock.plugins[i].sha256_files == files_sha && lock.plugins[i].sha256_manifest == manifest_sha {
            return Ok(false);
        }
        let dest = self.plugin_dir(id)?;
        let grew = !manifest.capabilities.added_since(&lock.plugins[i].granted).is_empty() || self.new_fonts(id, &pack, &files) > 0;
        let on_disk = read_capped(&dest.join(MANIFEST)).is_ok_and(|m| m == manifest_bytes)
            && plugin_pack::read_files(&dest, &pack).is_ok_and(|f| plugin_pack::files_digest(&f) == files_sha);
        if grew && on_disk {
            return Ok(false);
        }
        self.put_data(id, manifest_bytes, &files)?;
        if grew {
            return Ok(false);
        }
        lock.plugins[i] = LockEntry {
            id: id.to_owned(),
            version: manifest.plugin.version.clone(),
            source: BUNDLED.into(),
            commit: None,
            sha256_wasm: String::new(),
            sha256_manifest: manifest_sha,
            granted: manifest.capabilities,
            sha256_files: files_sha,
        };
        Ok(true)
    }

    /// How many of `pack`'s fonts, as read into `files`, the installed copy of `id` doesn't have byte for byte;
    /// all of them if it can't be read. A font swapped under the same name counts.
    fn new_fonts(&self, id: &str, pack: &plugin_pack::ThemePack, files: &[(String, Vec<u8>)]) -> usize {
        let old: BTreeMap<String, Vec<u8>> = self
            .plugin_dir(id)
            .ok()
            .and_then(|d| {
                let m = Manifest::parse(&String::from_utf8_lossy(&read_capped(&d.join(MANIFEST)).ok()?)).ok()?;
                let old = plugin_pack::theme_pack(&m).ok().flatten()?;
                let read = plugin_pack::read_files(&d, &old).ok()?;
                Some(read.into_iter().filter(|(rel, _)| old.fonts.contains(rel)).map(|(rel, b)| (rel, Sha256::digest(b).to_vec())).collect())
            })
            .unwrap_or_default();
        pack.fonts
            .iter()
            .filter(|f| {
                let now = files.iter().find(|(rel, _)| rel == *f).map(|(_, b)| Sha256::digest(b).to_vec());
                now.is_none() || old.get(*f) != now.as_ref()
            })
            .count()
    }

    fn put_data(&self, id: &str, manifest_bytes: &[u8], files: &[(String, Vec<u8>)]) -> Result<(), StoreError> {
        let dest = self.plugins_dir().join(id);
        let staging = self.plugins_dir().join(format!(".{id}.staging"));
        let _ = fs::remove_dir_all(&staging);
        mkdir_private(&staging)?;
        write_atomic(&staging.join(MANIFEST), manifest_bytes)?;
        for (rel, bytes) in files {
            let path = staging.join(rel);
            if let Some(parent) = path.parent() {
                mkdir_private(parent)?;
            }
            write_atomic(&path, bytes)?;
        }
        if dest.exists() {
            fs::remove_dir_all(&dest)?;
        }
        fs::rename(&staging, &dest)?;
        Ok(())
    }

    fn approve_data(&self, lock: &mut Lock, pos: usize, dir: &Path, manifest: &Manifest, manifest_bytes: &[u8], approve: &mut dyn FnMut(&Prompt) -> bool) -> Result<(), StoreError> {
        let pack = plugin_pack::theme_pack(manifest)?.ok_or_else(|| StoreError::Invalid("no [contributes.theme]".into()))?;
        let files_sha = plugin_pack::files_digest(&plugin_pack::read_files(dir, &pack).map_err(StoreError::Invalid)?);
        let manifest_sha = sha(manifest_bytes);
        let e = &mut lock.plugins[pos];
        let prompt = Prompt {
            id: e.id.clone(),
            name: manifest.plugin.name.clone(),
            version: manifest.plugin.version.clone(),
            lines: manifest.capabilities.describe(),
            always: "",
            update_from: None,
            changed_on_disk: e.sha256_files != files_sha || e.sha256_manifest != manifest_sha,
            replaces: None,
        };
        if !approve(&prompt) {
            return Err(StoreError::Declined);
        }
        e.version = manifest.plugin.version.clone();
        e.sha256_wasm = String::new();
        e.sha256_manifest = manifest_sha;
        e.sha256_files = files_sha;
        e.granted = manifest.capabilities.clone();
        self.write_lock(lock)
    }

    /// The installed theme, only if its manifest and files still hash to what was approved.
    fn verify_data(&self, e: &LockEntry) -> Result<ThemeContribution, String> {
        let dir = self.plugin_dir(&e.id).map_err(|err| err.to_string())?;
        let manifest_bytes = read_capped(&dir.join(MANIFEST)).map_err(|err| err.to_string())?;
        if sha(&manifest_bytes) != e.sha256_manifest {
            return Err(format!("manifest does not match the lockfile; run `haunt plugin approve {}`", e.id));
        }
        let manifest = Manifest::parse(&String::from_utf8_lossy(&manifest_bytes)).map_err(|err| err.to_string())?;
        let pack = plugin_pack::theme_pack(&manifest).map_err(|err| err.to_string())?.ok_or("no [contributes.theme]")?;
        if plugin_pack::files_digest(&plugin_pack::read_files(&dir, &pack)?) != e.sha256_files {
            return Err(format!("the theme's files do not match the lockfile; run `haunt plugin approve {}`", e.id));
        }
        plugin_pack::contribution(&e.id, &dir, &pack, e.source == BUNDLED)
    }
}

/// The user's installed plugins, loaded.
#[derive(Default)]
pub struct PluginSet {
    plugins: Vec<(Capabilities, LoadedPlugin)>,
    errors: Vec<String>,
    /// Each plugin's manifest `[settings]` and the settings JSON it last got.
    settings: BTreeMap<String, (toml::Table, String)>,
    settings_problems: Vec<String>,
    /// The `[plugins]` tables last applied; None until a config.toml that parses.
    config_tables: Option<BTreeMap<String, toml::Table>>,
    themes: Vec<ThemeContribution>,
    /// The (plugin, panel) that has the right pane.
    right_pane: Option<(String, String)>,
    core: Option<CoreHandle>,
}

/// The most settings JSON one plugin gets.
pub const MAX_SETTINGS: usize = 256 << 10;

/// `id`'s settings JSON, or None (reported) when it is over `MAX_SETTINGS`.
fn capped_settings(config: &PluginConfig, id: &str, schema: &toml::Table, problems: &mut Vec<String>) -> Option<String> {
    let json = config.settings_json(id, schema, problems);
    if json.len() > MAX_SETTINGS {
        problems.push(format!("[plugins.\"{id}\"]: over {} KB of settings; keeping the previous ones", MAX_SETTINGS >> 10));
        return None;
    }
    Some(json)
}

impl PluginSet {
    /// The themes installed data-only plugins contribute.
    pub fn themes(&self) -> &[ThemeContribution] {
        &self.themes
    }

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

    /// The user chose `item_id` in the palette or pressed its key; `terminal_shown` is whether the
    /// selected tab's terminal is on screen, which typing needs.
    pub fn invoke(&mut self, plugin_id: &str, item_id: &str, terminal_shown: bool) -> Result<(), PluginError> {
        self.plugin(plugin_id)?.run_command(item_id, terminal_shown)
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

    /// Delivers an event to plugins whose `events` grant covers it; `verified` as the core decided it.
    pub fn on_event(&mut self, t: &Tapped) {
        for (caps, p) in &mut self.plugins {
            if caps.wants_event(&t.event.kind, t.verified) {
                let _ = p.on_event(t);
            }
        }
    }

    /// The user clicked `plugin_id`'s top row.
    pub fn top_row_clicked(&mut self, plugin_id: &str) -> Result<(), PluginError> {
        self.plugin(plugin_id)?.top_row_clicked()
    }

    /// The user chose an action on one of `plugin_id`'s notifications.
    pub fn notify_action(&mut self, plugin_id: &str, action_id: &str, binding: &str) -> Result<(), PluginError> {
        self.plugin(plugin_id)?.notify_action(action_id, binding)
    }

    /// A button on show `generation` of one of `plugin_id`'s panels, or the user closing it (`action` empty).
    pub fn panel_action(&mut self, plugin_id: &str, panel_id: &str, generation: u64, action: &str) -> Result<(), PluginError> {
        if action.is_empty() && self.right_pane.as_ref().is_some_and(|(p, i)| p == plugin_id && i == panel_id) {
            self.right_pane = None;
        }
        self.plugin(plugin_id)?.panel_action(panel_id, generation, action)
    }

    /// Whether any plugin granted `timer` is still enabled.
    pub fn ticking(&self) -> bool {
        self.plugins.iter().any(|(caps, p)| caps.timer && p.disabled().is_none())
    }

    /// Ticks the plugins granted `timer` whose interval has passed.
    pub fn tick(&mut self, now: std::time::Instant) {
        for (caps, p) in &mut self.plugins {
            if caps.timer {
                let _ = p.tick(now);
            }
        }
    }

    /// What was wrong with the user's plugin settings at the last load or `set_config`.
    pub fn settings_problems(&self) -> &[String] {
        &self.settings_problems
    }

    /// config.toml changed: each plugin whose settings JSON differs gets `on-settings-changed`, after
    /// its palette commands are cleared for it to register again. Returns whether `[plugins]` changed;
    /// a file that doesn't parse keeps the settings, and the next good one is applied in full.
    pub fn set_config(&mut self, config: &PluginConfig) -> bool {
        if config.parsed && let Some(core) = &self.core {
            core.set_row_labels(config.row_labels.clone());
        }
        if !config.parsed {
            self.config_tables = None;
            self.settings_problems.clone_from(&config.problems);
            return false;
        }
        if self.config_tables.as_ref() == Some(&config.tables) {
            return false;
        }
        self.config_tables = Some(config.tables.clone());
        self.settings_problems.clone_from(&config.problems);
        let problems = &mut self.settings_problems;
        for (_, p) in &mut self.plugins {
            let id = p.id().to_owned();
            let Some((schema, last)) = self.settings.get_mut(&id) else { continue };
            let Some(json) = capped_settings(config, &id, schema, problems).filter(|j| j != last) else { continue };
            if let Some(why) = p.disabled() {
                problems.push(format!("{id} is off ({why}); restart Haunt to load it with the new settings"));
                continue;
            }
            match p.on_settings_changed(&json) {
                Ok(()) => *last = json,
                Err(e) => problems.push(format!("{id}: on-settings-changed failed: {e}")),
            }
        }
        true
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

    /// The plugins' requests, oldest plugin first, with the right pane's owner applied (`own_right_pane`).
    pub fn take_requests(&mut self) -> Vec<HostRequest> {
        let all: Vec<HostRequest> = self.plugins.iter_mut().flat_map(|(_, p)| p.take_requests()).collect();
        let (out, displaced) = own_right_pane(&mut self.right_pane, all);
        for (plugin_id, id) in displaced {
            if let Ok(p) = self.plugin(&plugin_id) {
                p.panel_displaced(&id);
            }
        }
        out
    }

    pub fn take_logs(&mut self) -> Vec<(String, String)> {
        self.plugins.iter_mut().flat_map(|(_, p)| {
            let id = p.id().to_owned();
            p.take_logs().into_iter().map(move |l| (id.clone(), l))
        }).collect()
    }
}

/// How often the tick thread looks for due timers; `timer.every` is at least 15 s, so this is coarse.
const TICK_POLL: std::time::Duration = std::time::Duration::from_secs(1);

/// Sends the core's events to `set`'s plugins, and their timer ticks, for as long as `set` lives.
/// The tick thread ends once no timer plugin is enabled. Plugin calls need the set's lock, so a
/// tick skips a second the set is busy rather than queue behind an event.
pub fn attach(core: &crate::Core, set: &Arc<Mutex<PluginSet>>) {
    if crate::sync::lock(set).ticking() {
        let weak = Arc::downgrade(set);
        let core = core.handle();
        let spawned = std::thread::Builder::new().name("haunt-tick".into()).spawn(move || {
            loop {
                std::thread::sleep(TICK_POLL);
                let Some(set) = weak.upgrade() else { return };
                let mut set = match set.try_lock() {
                    Ok(s) => s,
                    Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner(),
                    Err(std::sync::TryLockError::WouldBlock) => continue,
                };
                if !set.ticking() {
                    return;
                }
                set.tick(std::time::Instant::now());
                let pending = set.pending_requests() > 0;
                drop(set);
                if pending {
                    core.requests_queued();
                }
            }
        });
        if let Err(e) = spawned {
            crate::sync::lock(set).errors.push(format!("timer ticks are off: {e}"));
        }
    }
    let weak = Arc::downgrade(set);
    core.set_event_tap(Some(Arc::new(move |t: &Tapped| {
        let Some(set) = weak.upgrade() else { return false };
        let mut set = crate::sync::lock(&set);
        set.on_event(t);
        // Any left, not just new ones: a drain that found the set busy took none.
        set.pending_requests() > 0
    })));
}

/// `take_requests` without waiting: empty while a plugin is handling an event, whose tap then
/// signals again (see `attach`). The UI thread drains with this, so a slow plugin never stalls it.
/// There is one right pane: a show there closes the pane another (plugin, panel) had, with no
/// `on-action` for it, and only the owner's close clears it. Returns the requests and who lost the pane.
fn own_right_pane(owner: &mut Option<(String, String)>, requests: Vec<HostRequest>) -> (Vec<HostRequest>, Vec<(String, String)>) {
    let (mut out, mut displaced) = (Vec::with_capacity(requests.len()), Vec::new());
    for r in requests {
        match &r {
            HostRequest::ShowPanel { plugin_id, panel, .. } if panel.placement == PanelPlacement::Right => {
                let me = (plugin_id.clone(), panel.id.clone());
                if let Some(old) = owner.replace(me.clone()).filter(|old| *old != me) {
                    out.push(HostRequest::ClosePanel { plugin_id: old.0.clone(), id: old.1.clone() });
                    displaced.push(old);
                }
            }
            HostRequest::ClosePanel { plugin_id, id } if owner.as_ref().is_some_and(|(p, i)| p == plugin_id && i == id) => {
                *owner = None;
            }
            _ => {}
        }
        out.push(r);
    }
    (out, displaced)
}

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
    fn a_lockfile_grant_from_a_newer_haunt_drops_what_this_one_doesnt_know() {
        let entry = |granted: &str| format!(
            "[[plugin]]\nid = \"dev.x.p\"\nversion = \"1\"\nsource = \"s\"\nsha256_wasm = \"a\"\nsha256_manifest = \"b\"\n[plugin.granted]\n{granted}\n"
        );
        let lock: Lock = toml::from_str(&entry("timer = true\nteleport = true\nclipboard = \"read\"")).unwrap();
        let g = &lock.plugins[0].granted;
        assert!(g.timer && g.clipboard.as_deref() == Some("read"));
        assert_eq!(*g, Capabilities { timer: true, clipboard: Some("read".into()), ..Default::default() });
        assert!(toml::from_str::<Lock>(&entry("timer = \"yes\"")).is_err(), "a known one still has to be well-formed");
    }

    #[test]
    fn a_new_right_pane_closes_the_old_owners_and_only_the_owner_clears_it() {
        let show = |plugin: &str, id: &str, placement| HostRequest::ShowPanel {
            plugin_id: plugin.into(),
            plugin_name: plugin.into(),
            panel: crate::plugin_panel::Panel { id: id.into(), generation: 1, placement, title: String::new(), nodes: vec![] },
        };
        let close = |plugin: &str, id: &str| HostRequest::ClosePanel { plugin_id: plugin.into(), id: id.into() };
        let is_close = |r: &HostRequest, plugin: &str, panel: &str| matches!(r, HostRequest::ClosePanel { plugin_id, id } if plugin_id == plugin && id == panel);
        let mut owner = None;
        let (out, lost) = own_right_pane(&mut owner, vec![show("a", "map", PanelPlacement::Right), show("a", "map", PanelPlacement::Right)]);
        assert!(out.len() == 2 && lost.is_empty(), "the owner may show again");
        let (out, lost) = own_right_pane(&mut owner, vec![show("b", "x", PanelPlacement::Card), close("b", "map"), show("b", "map", PanelPlacement::Right)]);
        assert_eq!(lost, [("a".to_string(), "map".to_string())]);
        assert!(is_close(&out[2], "a", "map") && matches!(&out[3], HostRequest::ShowPanel { plugin_id, .. } if plugin_id == "b"));
        assert_eq!(owner, Some(("b".into(), "map".into())), "another plugin's close of the same id doesn't clear it");
        own_right_pane(&mut owner, vec![close("a", "map")]);
        assert!(owner.is_some());
        own_right_pane(&mut owner, vec![close("b", "map")]);
        assert!(owner.is_none());
    }

    #[test]
    fn draining_never_waits_for_a_busy_set() {
        let set = Arc::new(Mutex::new(PluginSet::default()));
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
            format!("[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"0.1.0\"\napi = \"0.5\"\nentry = \"p.wasm\"\n[capabilities]\n{caps}\n"),
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
            format!("[plugin]\nid = \"dev.haunt.t\"\nname = \"T\"\nversion = \"{version}\"\napi = \"0.5\"\nentry = \"plugin.wasm\"\n[capabilities]\n{caps}\n"),
        )
        .unwrap();
        fs::write(b.join(id).join(WASM), "(component)").unwrap();
        b
    }

    #[test]
    fn bundled_plugins_install_only_when_asked_and_update_only_without_growth() {
        let dir = tempdir("bundled");
        let store = Store::open(&dir.join("home")).unwrap();
        let host = PluginHost::new().unwrap();
        let b = bundle(&dir, "dev.haunt.t", "0.1.0", "decisions_read = true");
        let t = b.join("dev.haunt.t");
        assert!(store.install_bundled(&b, &host).unwrap().is_empty());
        assert!(store.list().unwrap().is_empty(), "launch never installs a bundled plugin");

        let (what, prompt) = store.preview_bundled_plugin(&t, &host).unwrap();
        assert_eq!(what, Preview::Install(Installed::New));
        assert!(prompt.lines.iter().any(|(l, _)| l.contains("decision")), "{:?}", prompt.lines);
        assert!(store.list().unwrap().is_empty() && !store.plugins_dir().join("dev.haunt.t").exists(), "a preview writes nothing");
        assert!(matches!(store.install_bundled_plugin(&t, &host, &mut |_| false), Err(StoreError::Declined)));
        assert!(store.list().unwrap().is_empty());
        assert_eq!(store.install_bundled_plugin(&t, &host, &mut |_| true).unwrap(), Installed::New);
        assert_eq!(store.preview_bundled_plugin(&t, &host).unwrap().0, Preview::Unchanged);
        // A copy changed on disk isn't unchanged: installing it again rewrites the files.
        fs::write(store.plugins_dir().join("dev.haunt.t").join(WASM), b"tampered").unwrap();
        let (what, prompt) = store.preview_bundled_plugin(&t, &host).unwrap();
        assert_eq!((what, prompt.changed_on_disk), (Preview::Install(Installed::Updated { prompted: false }), true));
        store.install_bundled_plugin(&t, &host, &mut |_| panic!("same files, no new capability: no prompt")).unwrap();
        assert_eq!(store.list().unwrap()[0].problem, None);
        assert_eq!(store.preview_bundled_plugin(&t, &host).unwrap().0, Preview::Unchanged);
        assert_eq!(store.installed_source("dev.haunt.t").unwrap().as_deref(), Some(BUNDLED));
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

        // Asking for it again brings it back, and launches update it again.
        store.install_bundled_plugin(&t, &host, &mut |_| true).unwrap();
        bundle(&dir, "dev.haunt.t", "0.4.0", "notifications = true");
        store.install_bundled(&b, &host).unwrap();
        assert_eq!(store.list().unwrap()[0].entry.version, "0.4.0");
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

        let (what, prompt) = store.preview_bundled_plugin(&b.join("dev.haunt.t"), &host).unwrap();
        assert_eq!(what, Preview::Install(Installed::Replaced { old_source: mine.canonicalize().unwrap().display().to_string() }));
        assert!(prompt.replaces.is_some());

        let b = bundle(&dir, "dev.haunt.other", "0.1.0", "");
        assert!(store.install_bundled(&b, &host).unwrap().is_empty(), "not installed, so never read");
        let e = store.install_bundled_plugin(&b.join("dev.haunt.other"), &host, &mut |_| true).unwrap_err();
        assert!(e.to_string().contains("manifest is for dev.haunt.t"), "{e}");
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
