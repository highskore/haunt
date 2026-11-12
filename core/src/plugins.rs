//! wasmtime host for `haunt:plugin@0.5` components (plan sections 3.3 and 3.8).

use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};
use wasmtime::component::{Component, HasSelf, Linker, ResourceTable};
use wasmtime::{Config, Engine, EngineWeak, Store, StoreContextMut, StoreLimits, StoreLimitsBuilder, Trap};
use wasmtime_wasi::{HostMonotonicClock, HostWallClock, WasiCtx, WasiCtxView, WasiView};

use crate::event::{EventKind, is_blank, is_hidden, visible};
use crate::plugin_cache::{CacheError, CwasmCache, cache_name};
use crate::plugin_fs::FsScope;
use crate::arrange::{Arrangement, ColorStyle, Section, StateGroup, TabColor};
use crate::layout::RowKind;
use crate::model::{CoreHandle, SidebarToken, Tapped};
use crate::plugin_manifest::{Capabilities, KV_CAP};
use crate::plugin_theme::Theme;
use crate::session::Outcome;

mod bindings {
    wasmtime::component::bindgen!({ path: "../wit/haunt-plugin.wit", world: "plugin" });
}

use bindings::Plugin;
use bindings::haunt::plugin::{
    allowlist as wallow, clipboard as wclip, clock as wclock, fs_list as wfslist, link as wlink, exec as wexec, hold as whold, keys as wkeys, top_row as wtop, decisions as wdec, kv as wkv, log as wlog, notify as wnotify, palette as wpal, pty as wpty, rows as wrows,
    sidebar as wside, terminal as wterm, theme as wtheme, timer as wtimer, typing as wtyping, types as wit,
};
pub(crate) use bindings::haunt::plugin::panel as wpanel;
use crate::plugin_panel::{Panel, PanelPlacement, Panels};
use crate::decorate::{self, Decoration, Spark, Tone, TopRow};
use crate::model::RowsToken;

pub const MEMORY_CAP: usize = 64 << 20;
const TICK: Duration = Duration::from_millis(10);
/// 5 ticks of 10 ms: the plan's 50 ms per call.
const CALL_TICKS: u64 = 5;
const PTY_PER_SEC: usize = 10;
const FS_LIST_PER_SEC: usize = 20;
const TREE_EVERY: Duration = Duration::from_secs(10);
const MAX_PALETTE: usize = 64;
const MAX_OUTBOX: usize = 256;
const MAX_NOTIFIED: usize = 64;
pub const MAX_KEYS: usize = 8;
const MAX_LOGS: usize = 1000;
/// Audit lines kept between drains; past this they are counted, never silently lost.
const MAX_AUDIT: usize = 1024;
/// Audit kinds a plugin can repeat cheaply; within one call each folds into one line.
const FOLDED_AUDIT: [&str; 3] = ["fs.read", "fs.list", "fs-list.entries"];

/// What the host did for a plugin with the user's terminal or machine, recorded by the host apart from
/// the plugin's own log, so `log` can't crowd it out. Drained to `plugin-audit.jsonl`.
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditLine {
    pub ts_ms: u64,
    pub plugin: String,
    /// `terminal.read`, `pty.answer`, `pty.type`, `exec`, `fs.read`, `fs.list`, `fs.write`,
    /// `decisions.query`, `clipboard.write`, `link.open-url`, `sidebar.focus`, `fs-list.entries`,
    /// `fs-list.tree`, or `audit.dropped` for lines past `MAX_AUDIT`.
    pub kind: String,
    pub surface: String,
    /// The command's name, the path inside the project folder, or the query's text.
    pub detail: String,
    /// Lines read, the request answered, bytes typed or moved, the job started, names listed, rows
    /// returned, or lines dropped; summed over `count`.
    pub n: u64,
    /// Calls this line stands for: repeats of a cheap kind (`FOLDED_AUDIT`) in one plugin call fold
    /// into one line, `detail` the first one's, so a flood can't rotate older lines out of the file.
    pub count: u64,
    /// The full length in characters of a string field cut to `AUDIT_STR_MAX`, as (field, length).
    pub clipped: Vec<AuditClip>,
}

#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditClip {
    pub field: String,
    pub len: u64,
}

/// Characters kept of each audited string; the length beyond goes in `clipped`.
pub const AUDIT_STR_MAX: usize = 64;
const MAX_STR: usize = 4096;
/// Bytes a `clipboard.write` keeps.
pub const CLIPBOARD_MAX: usize = 16 * 1024;
/// Lines a `clipboard.write` keeps.
pub const CLIPBOARD_LINES: usize = 400;
/// Characters, not bytes, of a registered command or mode title.
const MAX_TITLE: usize = 80;
const MAX_DECISIONS: u32 = 1000;
/// One-off approvals (an `export TOKEN=…`, say) never reach a plugin; repeats are what rules are for.
pub const APPROVALS_MIN: u32 = 2;

#[derive(Debug, Clone, Default)]
pub struct LoadStats {
    pub wasm_bytes: u64,
    pub from_cache: bool,
    pub compile_ms: f64,
    pub instantiate_ms: f64,
}

/// A palette entry: a registered command or mode, or an item a mode returned.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PaletteItem {
    pub plugin_id: String,
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub default_key: Option<String>,
    pub is_mode: bool,
    /// Unix ms for the time column.
    pub at_ms: Option<u64>,
    pub mark: Option<Mark>,
    /// Enter jumps to this tab, if it is open, instead of invoking the item.
    pub surface_id: Option<String>,
}

/// A chord a plugin bound with `keys.bind`; the app's `[keys]` may move it.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PluginKey {
    pub plugin_id: String,
    pub id: String,
    /// Canonical, as `chord::canonical_with_cmd` spells it.
    pub chord: String,
}

/// The decision-log markers: open square for your answers, filled for a plugin's, round for one that lapsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Mark {
    Open,
    Filled,
    Round,
}

/// A row context-menu entry; one with a `parent` goes in that entry's submenu.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct RowMenuItem {
    pub plugin_id: String,
    pub id: String,
    pub title: String,
    pub checked: bool,
    pub parent: Option<String>,
}

pub use crate::host_request::{HostRequest, NotifyAction};

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct PluginError(pub String);

impl From<wasmtime::Error> for PluginError {
    fn from(e: wasmtime::Error) -> Self {
        Self(format!("{e:#}"))
    }
}
impl From<CacheError> for PluginError {
    fn from(e: CacheError) -> Self {
        Self(e.to_string())
    }
}
impl From<std::io::Error> for PluginError {
    fn from(e: std::io::Error) -> Self {
        Self(e.to_string())
    }
}

/// What one plugin instance is allowed and where its state lives.
#[derive(Debug, Clone, Default)]
pub struct LoadSpec {
    pub id: String,
    /// The manifest's name, which the app shows on the plugin's panels.
    pub name: String,
    pub caps: Capabilities,
    pub kv_path: Option<PathBuf>,
    pub settings_json: String,
    /// The haunt dir (`~/.haunt`) the plugin's `${cwd}` may never point into.
    pub haunt_dir: Option<PathBuf>,
    /// What `decisions` and `allowlist` read and propose to; without it they see nothing.
    pub core: Option<CoreHandle>,
}

/// Written once per export call (`LoadedPlugin::call`) and on drop, not once per `set`.
struct Kv {
    map: BTreeMap<String, String>,
    bytes: usize,
    path: Option<PathBuf>,
    dirty: bool,
}

impl Kv {
    fn open(path: Option<PathBuf>) -> Self {
        let map: BTreeMap<String, String> = path
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let bytes = map.iter().map(|(k, v)| k.len() + v.len()).sum();
        Self { map, bytes, path, dirty: false }
    }

    fn set(&mut self, key: String, value: String) -> Result<(), String> {
        let old = self.map.get(&key).map_or(0, |v| key.len() + v.len());
        let bytes = self.bytes - old + key.len() + value.len();
        if bytes > KV_CAP {
            return Err(format!("kv is over its {KV_CAP} byte cap"));
        }
        self.map.insert(key, value);
        self.bytes = bytes;
        self.dirty = true;
        Ok(())
    }

    fn delete(&mut self, key: &str) {
        if let Some(v) = self.map.remove(key) {
            self.bytes -= key.len() + v.len();
            self.dirty = true;
        }
    }

    /// A failed write stays dirty and is tried again after the next call.
    fn flush(&mut self) -> Result<(), String> {
        let Some(path) = self.path.as_deref().filter(|_| self.dirty) else { return Ok(()) };
        let json = serde_json::to_vec(&self.map).map_err(|e| e.to_string())?;
        crate::plugin_cache::write_atomic(path, &json).map_err(|e| e.to_string())?;
        self.dirty = false;
        Ok(())
    }
}

impl Drop for Kv {
    fn drop(&mut self) {
        let _ = self.flush();
    }
}

pub struct HostState {
    id: String,
    name: String,
    logs: Vec<String>,
    audit: Vec<AuditLine>,
    audit_dropped: u64,
    wasi: WasiCtx,
    table: ResourceTable,
    limits: StoreLimits,
    kv: Kv,
    palette: Vec<PaletteItem>,
    outbox: Vec<HostRequest>,
    fs: FsScope,
    pty_times: VecDeque<Instant>,
    list_times: VecDeque<Instant>,
    /// When `fs-list.tree` last ran.
    last_tree: Option<Instant>,
    core: Option<CoreHandle>,
    /// Set while this instance may arrange the sidebar.
    sidebar: Option<SidebarToken>,
    /// Set while this instance may decorate rows.
    rows: Option<RowsToken>,
    events: EventGrant,
    /// The `timer.every` interval and when `on-tick` is next due.
    timer: Option<(Duration, Instant)>,
    panels: Panels,
    /// The action of the top row this plugin set, while it is up.
    top_action: Option<String>,
    /// (action id, binding) of this run's recent notifications: the only replies `notify_action` takes.
    notified: VecDeque<(String, String)>,
    theme: Arc<Theme>,
    /// The tab focused when the user ran one of this plugin's commands, while that call runs.
    typing_into: Option<String>,
    /// Set while the plugin handles something the user just did (a command, a key, a panel button) or
    /// the user coming back: only then may a panel be a sheet, which takes the keyboard.
    user_call: bool,
    /// Set while a button, key or command the user just used runs; a clipboard write spends it.
    copy_ok: bool,
    /// The panel button action the user clicked, while that call runs; `link.open-url` spends it.
    clicked: Option<String>,
    /// Set while a button, key or command the user just used runs; `sidebar.focus` spends it.
    focus_ok: bool,
    /// The manifest's `open_url` domains.
    links: Vec<String>,
    /// (id, canonical chord) from `keys.bind`.
    keys: Vec<(String, String)>,
    /// `terminal.read` calls left in the command, key or hover-hold the user just used; 0 outside one.
    reads_left: u32,
    /// The only tab `terminal.read` may read now, during a hover-hold: the row under the pointer.
    read_only: Option<String>,
    /// Set while the plugin hears that the user came back.
    returning: bool,
    /// The sheet it asked for then and when, until the user switches to Haunt.
    return_sheet: Option<(Panel, Instant)>,
    /// When Haunt became active with a sheet held: it shows `RETURN_SHEET_DELAY` later.
    activated_at: Option<Instant>,
    /// Set while this plugin has `keys.hover-hold`.
    hover_hold: bool,
    /// (action id, tab) of this plugin's latest hold summary: the only `"hold"` replies `notify_action` takes.
    hold_actions: Vec<(String, Option<String>)>,
    /// The manifest's `exec` names.
    exec: Vec<String>,
    /// Jobs started and not yet reported.
    exec_jobs: Vec<u64>,
    /// `fs-list.tree` walks started and not yet reported, with the folder as audited.
    tree_jobs: Vec<(u64, String)>,
}

impl Drop for HostState {
    fn drop(&mut self) {
        self.release_sidebar();
        self.release_rows();
        if let Some(c) = &self.core {
            c.release_sheet(&self.id, None);
            c.release_notifications(&self.id);
            c.release_hover(&self.id);
            let _ = c.set_top_row(&self.id, None);
        }
    }
}

impl HostState {
    fn new(id: &str, caps: &Capabilities, kv_path: Option<PathBuf>, haunt_dir: Option<&Path>, core: Option<CoreHandle>) -> Self {
        Self {
            id: id.to_owned(),
            name: id.to_owned(),
            logs: Vec::new(),
            audit: Vec::new(),
            audit_dropped: 0,
            wasi: WasiCtx::builder().wall_clock(CoarseWall).monotonic_clock(CoarseMono(Instant::now())).build(),
            table: ResourceTable::new(),
            limits: StoreLimitsBuilder::new().memory_size(MEMORY_CAP).instances(16).tables(64).memories(4).build(),
            kv: Kv::open(kv_path),
            palette: Vec::new(),
            outbox: Vec::new(),
            fs: FsScope::new(&cwd_globs(&caps.fs_read), &cwd_globs(&caps.fs_write), haunt_dir),
            pty_times: VecDeque::new(),
            list_times: VecDeque::new(),
            last_tree: None,
            sidebar: match &core {
                Some(c) if caps.sidebar => Some(c.attach_sidebar()),
                Some(c) => {
                    c.forget_arrangement_of(id);
                    None
                }
                None => None,
            },
            rows: core.as_ref().filter(|_| caps.decorate).map(|c| c.attach_rows(id)),
            timer: None,
            panels: Panels::default(),
            notified: VecDeque::new(),
            top_action: None,
            core,
            theme: Theme::default_shared(),
            typing_into: None,
            user_call: false,
            copy_ok: false,
            clicked: None,
            focus_ok: false,
            links: caps.open_url.clone(),
            keys: Vec::new(),
            hold_actions: Vec::new(),
            hover_hold: false,
            returning: false,
            return_sheet: None,
            activated_at: None,
            reads_left: 0,
            read_only: None,
            exec: caps.exec.clone(),
            exec_jobs: Vec::new(),
            tree_jobs: Vec::new(),
            events: EventGrant { details: caps.event_details, answers: caps.pty_write },
        }
    }

    /// Gives up the sidebar: a disabled, reloaded or dropped instance's arrangement goes with it.
    fn release_sidebar(&mut self) {
        if let (Some(core), Some(token)) = (&self.core, self.sidebar.take()) {
            core.detach_sidebar(token);
        }
    }

    fn release_rows(&mut self) {
        if let (Some(core), Some(token)) = (&self.core, self.rows.take()) {
            core.detach_rows(token);
        }
    }

    fn push_log(&mut self, line: String) {
        if self.logs.len() < MAX_LOGS {
            self.logs.push(line);
        }
    }

    fn audit(&mut self, kind: &str, surface: &str, detail: &str, n: u64) {
        // The buffer holds one call's lines: it is drained after every call.
        if FOLDED_AUDIT.contains(&kind)
            && let Some(l) = self.audit.iter_mut().find(|l| l.kind == kind)
        {
            l.n += n;
            l.count += 1;
            return;
        }
        if self.audit.len() >= MAX_AUDIT {
            self.audit_dropped += 1;
            return;
        }
        let ts_ms = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        let mut clipped = Vec::new();
        let mut cut = |field: &str, v: &str| {
            let len = v.chars().count();
            if len > AUDIT_STR_MAX {
                clipped.push(AuditClip { field: field.into(), len: len as u64 });
            }
            v.chars().take(AUDIT_STR_MAX).collect::<String>()
        };
        let line = AuditLine {
            ts_ms,
            plugin: cut("plugin", &self.id),
            kind: kind.into(),
            surface: cut("surface", surface),
            detail: cut("detail", detail),
            n,
            count: 1,
            clipped,
        };
        self.audit.push(line);
    }

    fn fs_read(&mut self, path: &str) -> Result<Vec<u8>, String> {
        let bytes = self.fs.read(path)?;
        let rel = self.in_project(path);
        self.audit("fs.read", "", &rel, bytes.len() as u64);
        Ok(bytes)
    }

    fn fs_list(&mut self, path: &str) -> Result<Vec<String>, String> {
        let names = self.fs.list(path)?;
        let rel = self.in_project(path);
        self.audit("fs.list", "", &rel, names.len() as u64);
        Ok(names)
    }

    fn fs_write(&mut self, path: &str, data: &[u8]) -> Result<(), String> {
        self.fs.write(path, data)?;
        let rel = self.in_project(path);
        self.audit("fs.write", "", &rel, data.len() as u64);
        Ok(())
    }

    /// `path` as the plugin gave it, shown inside the project folder it falls in; a bare file name when
    /// it falls in none (a grant can't reach outside them).
    fn in_project(&self, path: &str) -> String {
        let p = Path::new(path);
        let full = p.canonicalize().ok().or_else(|| Some(p.parent()?.canonicalize().ok()?.join(p.file_name()?)));
        if let Some(rel) = full.as_deref().and_then(|f| self.fs.cwds().iter().find_map(|c| f.strip_prefix(c).ok())) {
            return rel.to_string_lossy().into_owned();
        }
        p.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned())
    }

    fn take_audit(&mut self) -> Vec<AuditLine> {
        let mut out = std::mem::take(&mut self.audit);
        if self.audit_dropped > 0 {
            let n = std::mem::take(&mut self.audit_dropped);
            let ts_ms = out.last().map_or(0, |l| l.ts_ms);
            out.push(AuditLine {
                ts_ms,
                plugin: self.id.chars().take(AUDIT_STR_MAX).collect(),
                kind: "audit.dropped".into(),
                surface: String::new(),
                detail: String::new(),
                n,
                count: 1,
                clipped: Vec::new(),
            });
        }
        out
    }

    fn request(&mut self, r: HostRequest) -> Result<(), String> {
        if self.outbox.len() >= MAX_OUTBOX {
            return Err("too many pending requests".into());
        }
        self.outbox.push(r);
        Ok(())
    }

    fn pty_rate_ok(&mut self) -> bool {
        per_sec_ok(&mut self.pty_times, PTY_PER_SEC)
    }

    /// An id with a hidden character is refused, and a title loses its hidden characters and is cut to
    /// `MAX_TITLE` characters, so no plugin can disguise a command or push the palette around.
    fn register(&mut self, id: String, title: String, default_key: Option<String>, is_mode: bool) {
        let Some(title) = palette_title(&title).filter(|_| !id.is_empty() && !id.chars().any(is_hidden)) else {
            self.push_log(format!("warn palette: {:?} refused: an empty or hidden-character id, or an empty title", visible(&id)));
            return;
        };
        // Both are "<plugin id>/<id>" in the key map; the key was there first.
        if !is_mode && self.keys.iter().any(|(k, _)| *k == id) {
            self.push_log(format!("warn palette: {:?} refused: it is already one of this plugin's keys", visible(&id)));
            return;
        }
        self.palette.retain(|p| !(p.id == id && p.is_mode == is_mode));
        if self.palette.len() >= MAX_PALETTE {
            self.push_log(format!("warn palette: more than {MAX_PALETTE} entries, {id} dropped"));
            return;
        }
        let (id, default_key) = (clip(id), default_key.map(clip));
        self.palette.push(PaletteItem {
            plugin_id: self.id.clone(),
            id,
            title,
            subtitle: None,
            default_key,
            is_mode,
            at_ms: None,
            mark: None,
            surface_id: None,
        });
    }
}

/// Records a call in `times` unless `max` already happened in the last second.
fn per_sec_ok(times: &mut VecDeque<Instant>, max: usize) -> bool {
    let now = Instant::now();
    while times.front().is_some_and(|t| now.duration_since(*t) >= Duration::from_secs(1)) {
        times.pop_front();
    }
    if times.len() >= max {
        return false;
    }
    times.push_back(now);
    true
}

impl WasiView for HostState {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

fn clip(s: String) -> String {
    if s.len() <= MAX_STR {
        return s;
    }
    let mut end = MAX_STR;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_owned()
}

impl wit::Host for HostState {}

impl wlog::Host for HostState {
    fn log(&mut self, level: wit::LogLevel, msg: String) {
        let level = match level {
            wit::LogLevel::Debug => "debug",
            wit::LogLevel::Info => "info",
            wit::LogLevel::Warn => "warn",
            wit::LogLevel::Error => "error",
        };
        self.push_log(format!("{level} {}", clip(msg)));
    }
}

impl wkv::Host for HostState {
    fn get(&mut self, key: String) -> Option<String> {
        self.kv.map.get(&key).cloned()
    }
    fn set(&mut self, key: String, value: String) -> Result<(), String> {
        self.kv.set(key, value)
    }
    fn delete(&mut self, key: String) {
        self.kv.delete(&key);
    }
}

impl wpal::Host for HostState {
    fn mode(&mut self, word: String, title: String) {
        self.register(word, title, None, true);
    }
    fn command(&mut self, id: String, title: String, default_key: Option<String>) {
        self.register(id, title, default_key, false);
    }
    fn remove(&mut self, id: String) {
        let keyed = self.palette.iter().any(|p| p.id == id && p.default_key.is_some());
        self.palette.retain(|p| p.id != id);
        if keyed {
            self.menu_changed();
        }
    }
    fn retitle(&mut self, id: String, title: String) -> Result<(), String> {
        let title = palette_title(&title).ok_or("a title needs a visible character")?;
        let (mut found, mut keyed) = (false, false);
        for p in self.palette.iter_mut().filter(|p| p.id == id) {
            (p.title, found, keyed) = (title.clone(), true, keyed || p.default_key.is_some());
        }
        if keyed {
            self.menu_changed();
        }
        found.then_some(()).ok_or_else(|| format!("no palette entry {:?}", visible(&id).chars().take(40).collect::<String>()))
    }
}

impl HostState {
    /// A command with a key is in the Window menu and the key map: one `keysChanged` rebuilds both,
    /// however many changes queue before the app drains.
    fn menu_changed(&mut self) {
        if !self.outbox.iter().any(|r| matches!(r, HostRequest::KeysChanged { .. })) {
            let _ = self.request(HostRequest::KeysChanged { plugin_id: self.id.clone() });
        }
    }
}

/// `title` without hidden characters, cut to `MAX_TITLE`; none if nothing visible is left.
fn palette_title(title: &str) -> Option<String> {
    let title: String = title.chars().filter(|&c| !is_hidden(c)).take(MAX_TITLE).collect();
    (!title.trim().is_empty()).then_some(title)
}

impl wtheme::Host for HostState {
    fn name(&mut self) -> String {
        self.theme.name.clone()
    }
    fn tokens(&mut self) -> Vec<wtheme::Token> {
        self.theme.tokens.iter().map(|t| wtheme::Token { name: t.name.clone(), value: t.value.clone() }).collect()
    }
}

impl wnotify::Host for HostState {
    fn notify(&mut self, title: String, body: String, actions: Vec<wnotify::Action>, binding: Option<String>) -> Result<(), String> {
        if actions.len() > 4 {
            return Err("at most 4 actions".into());
        }
        let actions: Vec<NotifyAction> = actions
            .into_iter()
            .map(|a| {
                let (id, title) = (clip(a.id), clip(a.title));
                // A button has no tooltip: one that opens a link names its host.
                let title = match link_host(&id).filter(|_| link_ok(&id, &self.links).is_ok()) {
                    Some(host) => format!("{title} ({host})"),
                    None => title,
                };
                NotifyAction { id, title }
            })
            .collect();
        let binding = binding.map(clip);
        let r = HostRequest::Notify { plugin_id: self.id.clone(), title: clip(title), body: clip(body), actions: actions.clone(), binding: binding.clone() };
        self.request(r)?;
        for a in actions {
            if self.notified.len() >= MAX_NOTIFIED {
                self.notified.pop_front();
            }
            self.notified.push_back((a.id, binding.clone().unwrap_or_default()));
        }
        Ok(())
    }
}

impl wpty::Host for HostState {
    fn answer(&mut self, surface: String, allow: bool, request_id: u64) -> Result<(), String> {
        if !self.pty_rate_ok() {
            return Err(format!("pty rate limit ({PTY_PER_SEC}/s)"));
        }
        let surface = clip(surface);
        // Only a real tab's answer is audited; the gate refuses the rest.
        if self.core.as_ref().is_some_and(|c| c.tab_folders(&surface).is_some()) {
            self.audit("pty.answer", &surface, "", request_id);
        }
        self.request(HostRequest::PtyAnswer { plugin_id: self.id.clone(), surface, allow, request_id })
    }
}

impl wtyping::Host for HostState {
    fn type_text(&mut self, text: String, enter: bool) -> Result<(), String> {
        let surface = self.typing_into.clone().ok_or("only while running a command the user chose")?;
        if let Some(why) = crate::ptygate::untypable(&text) {
            return Err(format!("not typed: {why}"));
        }
        if !self.pty_rate_ok() {
            return Err(format!("pty rate limit ({PTY_PER_SEC}/s)"));
        }
        self.audit("pty.type", &surface, "", text.len() as u64);
        self.request(HostRequest::PtyType { plugin_id: self.id.clone(), surface, text, enter })
    }
}

const READS_PER_ACTION: u32 = 8;
/// A held return sheet shows this long after Haunt becomes active, so it doesn't take the first keys
/// typed after switching.
pub const RETURN_SHEET_DELAY: Duration = Duration::from_secs(1);
/// A held return sheet the user never switched to Haunt for is dropped after this.
const RETURN_SHEET_TTL: Duration = Duration::from_secs(10 * 60);
const READ_LINES_MAX: u32 = 50;
const READ_LINE_CHARS: usize = 512;

impl wterm::Host for HostState {
    fn read(&mut self, surface: String, lines: u32) -> Result<Vec<String>, String> {
        if self.reads_left == 0 {
            return Err("only while handling a command or key the user just used".into());
        }
        if !(1..=READ_LINES_MAX).contains(&lines) {
            return Err(format!("lines is 1 to {READ_LINES_MAX}"));
        }
        let core = self.core.as_ref().ok_or("no haunt core")?;
        let surface = clip(surface);
        if self.read_only.as_ref().is_some_and(|only| *only != surface) {
            return Err("only the hovered tab".into());
        }
        if core.tab_folders(&surface).is_none() {
            return Err(format!("no tab {:?}", shown(&surface, 40)));
        }
        let reader = core.screen_reader().ok_or("haunt can't read screens here")?;
        self.reads_left -= 1;
        let got = reader(&surface, lines).ok_or("that tab's screen can't be read now")?;
        let skip = got.len().saturating_sub(lines as usize);
        let out: Vec<String> = got.iter().skip(skip).map(|l| shown(l, READ_LINE_CHARS)).collect();
        self.audit("terminal.read", &surface, "", out.len() as u64);
        Ok(out)
    }
}

impl wdec::Host for HostState {
    fn query(&mut self, text: String, limit: u32) -> Vec<wdec::Decision> {
        let Some(core) = &self.core else { return Vec::new() };
        // The 0.4 `outcome` variant has no case for a refused plugin answer; those rows stay out.
        let rows: Vec<wdec::Decision> = core.decisions_where(&text, limit.min(MAX_DECISIONS), |d| !matches!(d.outcome, Outcome::RefusedPlugin { .. }))
            .into_iter()
            .map(|d| {
                let outcome = match d.outcome {
                    Outcome::AllowedInHaunt => wdec::Outcome::AllowedInHaunt,
                    Outcome::DeniedInHaunt => wdec::Outcome::DeniedInHaunt,
                    Outcome::AllowedByPlugin { plugin_id } => wdec::Outcome::AllowedByPlugin(plugin_id),
                    Outcome::DeniedByPlugin { plugin_id } => wdec::Outcome::DeniedByPlugin(plugin_id),
                    Outcome::AnsweredInTerminal => wdec::Outcome::AnsweredInTerminal,
                    Outcome::Superseded => wdec::Outcome::Superseded,
                    Outcome::RefusedPlugin { .. } => unreachable!("filtered out by the query"),
                };
                wdec::Decision {
                    at_ms: d.at_ms,
                    surface_id: d.surface_id,
                    tool: d.tool,
                    preview: d.preview,
                    cwd: d.cwd,
                    outcome,
                    agent: d.agent.id().to_owned(),
                }
            })
            .collect();
        self.audit("decisions.query", "", &text, rows.len() as u64);
        rows
    }
}

impl wallow::Host for HostState {
    fn approvals(&mut self, min_count: u32) -> Vec<wallow::Approval> {
        let Some(core) = &self.core else { return Vec::new() };
        core.approvals(min_count.max(APPROVALS_MIN))
            .into_iter()
            .map(|a| wallow::Approval { project: a.project, command: a.command, count: a.count, last_at_ms: a.last_at_ms })
            .collect()
    }

    fn propose(&mut self, project: String, command: String) -> Result<(), String> {
        let core = self.core.as_ref().ok_or("no haunt core attached")?;
        core.propose_allow_rule(&self.id, &project, &command).map_err(|e| e.to_string())
    }
}

impl wside::Host for HostState {
    fn rows(&mut self) -> Vec<wside::RowInfo> {
        let Some(core) = &self.core else { return Vec::new() };
        core.sidebar_rows()
            .into_iter()
            .map(|r| wside::RowInfo {
                surface: r.surface,
                name: r.name,
                kind: match r.kind {
                    RowKind::Shell => "shell",
                    RowKind::Claude => "claude",
                    RowKind::Codex => "codex",
                }
                .to_owned(),
                group: match r.group {
                    StateGroup::NeedsYou => wside::StateGroup::NeedsYou,
                    StateGroup::Running => wside::StateGroup::Running,
                    StateGroup::Idle => wside::StateGroup::Idle,
                },
                selected: r.selected,
            })
            .collect()
    }

    fn arrange(&mut self, a: wside::Arrangement) -> Result<(), String> {
        let core = self.core.as_ref().ok_or("no haunt core attached")?;
        let color = |c: wside::TabColor| match c {
            wside::TabColor::Red => TabColor::Red,
            wside::TabColor::Orange => TabColor::Orange,
            wside::TabColor::Yellow => TabColor::Yellow,
            wside::TabColor::Green => TabColor::Green,
            wside::TabColor::Blue => TabColor::Blue,
            wside::TabColor::Purple => TabColor::Purple,
            wside::TabColor::Gray => TabColor::Gray,
        };
        let a = Arrangement {
            pinned: a.pinned,
            sections: a.sections.into_iter().map(|s| Section { id: s.id, title: s.title, surfaces: s.surfaces }).collect(),
            sections_after_state: a.placement == wside::Placement::AfterState,
            order: a.order,
            flat: a.flat,
            colors: a.colors.into_iter().map(|(s, c)| (s, color(c))).collect(),
            color_style: match a.color_style {
                wside::ColorStyle::Dot => ColorStyle::Dot,
                wside::ColorStyle::Tint => ColorStyle::Tint,
            },
        };
        let token = self.sidebar.ok_or("not loaded with the sidebar capability")?;
        core.set_arrangement(&self.id, token, a).map_err(|e| e.to_string())
    }

    fn clear(&mut self) {
        if let (Some(core), Some(token)) = (&self.core, self.sidebar) {
            core.clear_arrangement(token);
        }
    }

    fn focus(&mut self, surface: String) -> Result<(), String> {
        self.sidebar.ok_or("not loaded with the sidebar capability")?;
        if !std::mem::take(&mut self.focus_ok) {
            return Err("only once per button, key or command the user just used".into());
        }
        if !self.core.as_ref().is_some_and(|c| c.has_surface(&surface)) {
            return Err(format!("no open tab {:?}", visible(&surface).chars().take(64).collect::<String>()));
        }
        self.request(HostRequest::FocusTab { plugin_id: self.id.clone(), surface: surface.clone() })?;
        self.audit("sidebar.focus", &surface, "", 1);
        Ok(())
    }
}

fn tone(t: wrows::Tone) -> Tone {
    match t {
        wrows::Tone::Dim => Tone::Dim,
        wrows::Tone::Text => Tone::Text,
        wrows::Tone::Warn => Tone::Warn,
    }
}

/// Plain, capped text; None when nothing visible is left.
fn plain_opt(s: Option<String>, max: usize) -> Option<String> {
    s.map(|s| plain(&s, max)).filter(|s| !s.trim().is_empty())
}

/// One character of a label as matched: `wild` when it wasn't ASCII, so it stands for any letter;
/// `sym` when it wasn't a letter, digit or mark either (`✓`, `℮`, `💤`).
#[derive(Clone, Copy, PartialEq)]
struct Glyph {
    c: char,
    wild: bool,
    sym: bool,
}

/// A break between words: whitespace, ASCII punctuation and any Unicode punctuation (`—`, `【`, `·`).
/// Other symbols (`○`, `∨`, `✓`) stay, as wildcards.
fn status_separator(c: char) -> bool {
    use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};
    c.is_whitespace() || is_blank(c) || (c.is_ascii() && !c.is_ascii_alphanumeric()) || c.general_category_group() == GeneralCategoryGroup::Punctuation
}

/// `s` as compared: NFKC, lowercased, combining marks dropped, each character mapped to its TR39
/// confusable skeleton and lowercased again, lookalikes folded (0→o, 1/i/|→l, 5→s, then rn→m, vv→w).
/// A separator becomes one space.
fn status_fold(s: &str) -> Vec<Glyph> {
    use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};
    use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};
    let mut out: Vec<Glyph> = Vec::new();
    // Judged on the character as written: NFKC turns ™ into the letters "tm".
    let chars = s.chars().flat_map(|o| {
        let sym = !o.is_ascii()
            && !matches!(o.general_category_group(), GeneralCategoryGroup::Letter | GeneralCategoryGroup::Number | GeneralCategoryGroup::Mark);
        let lower = o.nfkc().collect::<String>().to_lowercase();
        lower.nfd().filter(|&c| !is_combining_mark(c)).map(move |c| (c, sym)).collect::<Vec<_>>()
    });
    for (c, sym) in chars {
        // | looks like l; it is folded, not a break.
        if c != '|' && status_separator(c) {
            out.push(Glyph { c: ' ', wild: false, sym: false });
            continue;
        }
        let mut buf = [0u8; 4];
        for k in unicode_security::skeleton(c.encode_utf8(&mut buf)).flat_map(char::to_lowercase) {
            let k = match k {
                '0' => 'o',
                '1' | 'i' | '|' => 'l',
                '5' => 's',
                k => k,
            };
            let g = Glyph { c: k, wild: !c.is_ascii(), sym };
            match (out.last().copied(), k) {
                (Some(Glyph { c: 'r', wild: false, .. }), 'n') if !g.wild => *out.last_mut().unwrap() = Glyph { c: 'm', wild: false, sym: false },
                (Some(Glyph { c: 'v', wild: false, .. }), 'v') if !g.wild => *out.last_mut().unwrap() = Glyph { c: 'w', wild: false, sym: false },
                _ => out.push(g),
            }
        }
    }
    out
}

/// What a word keeps: letters and digits, and anything non-ASCII as a wildcard.
fn status_kept(g: &Glyph) -> bool {
    g.c.is_alphanumeric() || g.wild
}

/// `w` reads as `p`: each glyph equal (its skeleton, for a lookalike) or a wildcard, and at least one
/// equal, so emoji alone spell nothing but a word all in lookalikes does.
fn status_same(w: &[Glyph], p: &[char]) -> bool {
    w.len() == p.len() && w.iter().zip(p).all(|(g, p)| g.c == *p || g.wild) && w.iter().zip(p).any(|(g, p)| g.c == *p)
}

/// Whether `text` spells one of Haunt's status words or phrases: the sidebar's own (`layout::STATUS_TEXTS`,
/// and "Waiting" alone) and the Allow/Deny buttons. Its words (`status_fold`ed, split at every
/// `status_separator`) are matched whole: refused when one word, or a run of adjacent words read
/// together, is a phrase run together ("done", "Do.ne", "d o n e", "needs you", "WaitingForYou"). So
/// "ok-done-ok" is refused, and "abandoned", "idler", "undone·x" and "allowlist ok" are not. Words are
/// split twice: with symbols kept as wildcards (`don℮`) and with every non-ASCII character or symbol
/// as a break (`done✓`, `doneꓸ`, `doneː`), so a word in another script touching one is refused too.
pub fn says_status(text: &str) -> bool {
    static PHRASES: std::sync::LazyLock<Vec<Vec<char>>> = std::sync::LazyLock::new(|| {
        let waiting = crate::layout::WAITING.split(' ').next();
        status_phrases(crate::layout::STATUS_TEXTS.iter().copied().chain(waiting).chain(["Allow", "Deny"]))
    });
    says_phrase(text, &PHRASES, false)
}

/// `says_status` for a theme's words, which also may not read as a permission request or its answer: no word
/// (or run of words) may start with these stems, so "Approving", "denies" and "permitted" are refused too.
pub fn theme_says_status(text: &str) -> bool {
    static STEMS: std::sync::LazyLock<Vec<Vec<char>>> =
        std::sync::LazyLock::new(|| status_phrases(["Allow", "Deny", "Deni", "Approv", "Permi", "Request"]));
    says_status(text) || says_phrase(text, &STEMS, true)
}

fn status_phrases<'a>(all: impl IntoIterator<Item = &'a str>) -> Vec<Vec<char>> {
    all.into_iter().map(|p| status_fold(p).iter().filter(|g| status_kept(g)).map(|g| g.c).collect()).collect()
}

/// Whether a word, or a run of words read together, is one of `phrases`, or with `stem` starts with one.
fn says_phrase(text: &str, phrases: &[Vec<char>], stem: bool) -> bool {
    let longest = phrases.iter().map(Vec::len).max().unwrap_or(0);
    let folded = status_fold(text);
    let says = |brk: &dyn Fn(&Glyph) -> bool| {
        let words: Vec<&[Glyph]> = folded.split(|g| brk(g)).filter(|w| !w.is_empty()).collect();
        (0..words.len()).any(|i| {
            let mut run: Vec<Glyph> = Vec::new();
            words[i..].iter().any(|w| {
                run.extend_from_slice(w);
                if stem {
                    phrases.iter().any(|p| run.len() >= p.len() && status_same(&run[..p.len()], p))
                } else {
                    run.len() <= longest && phrases.iter().any(|p| status_same(&run, p))
                }
            })
        })
    };
    says(&|g| !status_kept(g)) || says(&|g| !status_kept(g) || g.wild || g.sym)
}

/// Whether a suffix or ticker says what a row needing you says, "needs you" or "waiting for you", anywhere
/// in its letters and digits, compared as `says_status` compares labels. Other status words are fine there:
/// "checks running" and "failed 2m ago" are a plugin's own words.
pub(crate) fn says_needs_you(text: &str) -> bool {
    static PHRASES: std::sync::LazyLock<Vec<Vec<char>>> = std::sync::LazyLock::new(|| {
        [crate::layout::NEEDS_YOU, crate::layout::WAITING].map(|p| status_fold(p).iter().filter(|g| status_kept(g)).map(|g| g.c).collect()).to_vec()
    });
    let flat: Vec<Glyph> = status_fold(text).into_iter().filter(status_kept).collect();
    PHRASES.iter().any(|p| flat.windows(p.len()).any(|w| status_same(w, p)))
}

fn decoration(d: wrows::Decoration) -> Result<Decoration, String> {
    let spark = match d.spark {
        Some(s) => {
            decorate::check_spark(&s.points)?;
            Some(Spark { points: s.points, tone: tone(s.tone) })
        }
        None => None,
    };
    let label = plain_opt(d.label, decorate::LABEL_MAX);
    if let Some(l) = &label {
        // Text is close enough to the needs-you white to pass for it.
        if d.label_tone == wrows::Tone::Text {
            return Err("a row label is dim or warn, never text".into());
        }
        if says_status(l) {
            return Err(format!("{l:?} reads as Haunt's own status"));
        }
    }
    let suffix = plain_opt(d.suffix, if d.scroll { decorate::TICKER_MAX } else { decorate::SUFFIX_MAX });
    if let Some(t) = suffix.as_deref().filter(|t| says_needs_you(t)) {
        return Err(format!("{t:?} reads as a row that needs you"));
    }
    Ok(Decoration {
        label,
        label_tone: tone(d.label_tone),
        suffix,
        suffix_tone: tone(d.suffix_tone),
        scroll: d.scroll,
        bar_permille: d.bar.map(decorate::permille).transpose()?,
        spark,
    })
}

impl wrows::Host for HostState {
    fn decorate(&mut self, surface: String, d: Option<wrows::Decoration>) -> Result<(), String> {
        let core = self.core.as_ref().ok_or("no haunt core attached")?;
        let token = self.rows.ok_or("not loaded with the decorate capability")?;
        let d = d.map(decoration).transpose()?;
        core.decorate(token, &surface, d).map_err(|e| e.to_string())
    }

    fn clear_all(&mut self) {
        if let (Some(core), Some(token)) = (&self.core, self.rows) {
            core.detach_rows(token);
        }
    }
}

/// The fs globs the manifest check allows, again, so a hand-edited lockfile can't widen a grant.
fn cwd_globs(globs: &[String]) -> Vec<String> {
    globs.iter().filter(|g| g.starts_with(crate::plugin_manifest::FS_PREFIX)).cloned().collect()
}

/// The pinned fs globs `cwd_globs` drops, as the load error the user sees for each.
pub fn dropped_fs_grants(caps: &Capabilities) -> Vec<String> {
    let dropped = |what: &'static str, gs: &[String]| {
        gs.iter().filter(|g| !g.starts_with(crate::plugin_manifest::FS_PREFIX)).map(move |g| {
            format!("{what} {g:?} is off: a plugin now reaches only the agent's project folder ({}…)", crate::plugin_manifest::FS_PREFIX)
        }).collect::<Vec<_>>()
    };
    [dropped("reading", &caps.fs_read), dropped("writing", &caps.fs_write)].concat()
}

impl wpanel::Host for HostState {
    fn show(&mut self, id: String, placement: wpanel::Placement, title: String, nodes: Vec<wpanel::PanelNode>) -> Result<(), String> {
        let mut panel = crate::plugin_panel::build(id, placement, title, nodes)?;
        if self.outbox.len() >= MAX_OUTBOX {
            return Err("too many pending requests".into());
        }
        // Unasked, a sheet would take the keys the user is typing; it comes up as a card instead. One
        // asked for as the user comes back waits for them to switch to Haunt (`return_sheet_due`).
        if panel.placement == PanelPlacement::Sheet && !self.user_call {
            if self.returning {
                self.return_sheet = Some((panel, Instant::now()));
                self.activated_at = None;
                return Ok(());
            }
            panel.placement = PanelPlacement::Card;
        }
        self.show_panel(panel)
    }

    fn close(&mut self, id: String) {
        if self.return_sheet.as_ref().is_some_and(|(p, _)| p.id == id) {
            self.drop_return_sheet();
        }
        self.release_sheet(&id);
        if self.panels.close(&id) {
            let _ = self.request(HostRequest::ClosePanel { plugin_id: self.id.clone(), id });
        }
    }
}

impl HostState {
    fn show_panel(&mut self, mut panel: Panel) -> Result<(), String> {
        let was_sheet = self.panels.placement(&panel.id) == Some(PanelPlacement::Sheet);
        if let Some(c) = self.core.as_ref().filter(|_| panel.placement == PanelPlacement::Sheet) {
            c.claim_sheet(&self.id, &panel.id)?;
        }
        if let Err(e) = self.panels.show(&mut panel) {
            if panel.placement == PanelPlacement::Sheet && !was_sheet {
                self.release_sheet(&panel.id);
            }
            return Err(e);
        }
        if was_sheet && panel.placement != PanelPlacement::Sheet {
            self.release_sheet(&panel.id);
        }
        let plugin_name = self.name.clone();
        self.request(HostRequest::ShowPanel { plugin_id: self.id.clone(), plugin_name, panel })
    }

    fn drop_return_sheet(&mut self) {
        self.return_sheet = None;
        self.activated_at = None;
    }

    /// Haunt stopped being active before the held sheet was due: it waits for the next activation.
    fn return_resigned(&mut self) {
        self.activated_at = None;
    }

    /// Haunt became active: a held sheet is due `RETURN_SHEET_DELAY` later.
    fn return_activated(&mut self, now: Instant) {
        self.expire_return_sheet(now);
        if self.return_sheet.is_some() {
            self.activated_at = Some(now);
        }
    }

    fn expire_return_sheet(&mut self, now: Instant) {
        if self.return_sheet.as_ref().is_some_and(|(_, held)| now.saturating_duration_since(*held) >= RETURN_SHEET_TTL) {
            self.drop_return_sheet();
        }
    }

    /// The held sheet shows once its delay has passed, unless the user `typed` into Haunt meanwhile,
    /// which drops it.
    fn return_sheet_due(&mut self, now: Instant, typed: bool) -> Result<(), String> {
        self.expire_return_sheet(now);
        let Some(at) = self.activated_at else { return Ok(()) };
        if typed {
            self.drop_return_sheet();
            return Ok(());
        }
        if now.saturating_duration_since(at) < RETURN_SHEET_DELAY {
            return Ok(());
        }
        self.activated_at = None;
        match self.return_sheet.take() {
            Some((p, _)) => self.show_panel(p),
            None => Ok(()),
        }
    }
}

impl HostState {
    /// Only the folder the tab was opened in makes a root; the live cwd (OSC 7) is inside it or ignored.
    fn grant_tab_folder(&mut self, t: &Tapped) {
        self.fs.add_cwd(&t.opened_in);
    }

    fn release_sheet(&self, id: &str) {
        if let Some(c) = &self.core {
            c.release_sheet(&self.id, Some(id));
        }
    }

    /// A disabled plugin's panels close, since nothing can answer their buttons.
    fn close_panels(&mut self) {
        if let Some(c) = &self.core {
            c.release_sheet(&self.id, None);
        }
        for id in std::mem::take(&mut self.panels).ids() {
            self.outbox.push(HostRequest::ClosePanel { plugin_id: self.id.clone(), id });
        }
    }

    /// A disabled plugin's top row goes, since nothing can answer a click on it.
    fn clear_top_row(&mut self) {
        self.top_action = None;
        if let Some(c) = &self.core {
            let _ = c.set_top_row(&self.id, None);
        }
    }

    /// A disabled plugin's keys go back to the terminal.
    fn drop_keys(&mut self) {
        let hover = std::mem::take(&mut self.hover_hold);
        if hover && let Some(c) = &self.core {
            c.release_hover(&self.id);
        }
        if !std::mem::take(&mut self.keys).is_empty() || hover {
            self.outbox.push(HostRequest::KeysChanged { plugin_id: self.id.clone() });
        }
    }

    /// The user just did something for this plugin: the call may copy and focus a tab once, and open
    /// `clicked` if it is the link the button carried.
    fn arm(&mut self, copy: bool, clicked: Option<&str>) {
        (self.copy_ok, self.focus_ok) = (copy, copy);
        self.clicked = clicked.filter(|a| !a.is_empty()).map(str::to_owned);
    }

    fn disarm(&mut self) {
        (self.copy_ok, self.focus_ok, self.clicked) = (false, false, None);
    }

    /// The tab hold summary action `action_id` brings forward, while that tab is still open.
    fn hold_surface(&self, action_id: &str) -> Option<String> {
        let (_, tab) = self.hold_actions.iter().find(|(a, _)| a == action_id)?;
        tab.clone().filter(|s| self.core.as_ref().is_some_and(|c| c.has_surface(s)))
    }

    /// The user chose `action_id` on one of this run's notifications or its latest hold summary: armed
    /// like a panel button.
    fn notify_click(&mut self, action_id: &str, binding: &str) -> Result<(), String> {
        let held = binding == HOLD_BINDING && self.hold_actions.iter().any(|(a, _)| a == action_id);
        if !held && !self.notified.iter().any(|(a, b)| a == action_id && b == binding) {
            return Err(format!("no notification action {action_id:?}"));
        }
        self.arm(true, Some(action_id));
        Ok(())
    }

    /// A call that trapped doesn't get to change the clipboard, open a link or switch tabs.
    fn drop_user_effects(&mut self) {
        self.outbox.retain(|r| !matches!(r, HostRequest::ClipboardWrite { .. } | HostRequest::OpenUrl { .. } | HostRequest::FocusTab { .. }));
    }

    /// A disabled plugin's hold ends, so it can't keep notifications away.
    fn release_hold(&mut self) {
        if self.core.as_ref().is_some_and(|c| c.release_notifications(&self.id)) {
            self.outbox.push(HostRequest::ReleaseNotifications { plugin_id: self.id.clone() });
        }
    }
}

impl wtop::Host for HostState {
    fn set(&mut self, row: Option<wtop::Top>) -> Result<(), String> {
        let core = self.core.clone().ok_or("no haunt core")?;
        let Some(r) = row else {
            self.clear_top_row();
            return Ok(());
        };
        let title = plain_opt(Some(r.title), decorate::TOP_TITLE_MAX).ok_or("the top row needs a title")?;
        let action = r.action.map(clip).filter(|a| !a.is_empty());
        let top = TopRow {
            plugin_id: self.id.clone(),
            title,
            sub: plain_opt(r.sub, decorate::TOP_SUB_MAX),
            right: plain_opt(r.right, decorate::TOP_TEXT_MAX),
            tone: tone(r.tone),
            bar_permille: r.bar.map(decorate::permille).transpose()?,
            clickable: action.is_some(),
        };
        core.set_top_row(&self.id, Some(top))?;
        self.top_action = action;
        Ok(())
    }
}

impl wkeys::Host for HostState {
    fn bind(&mut self, id: String, chord: String) -> Result<(), String> {
        if id.is_empty() || id.chars().any(is_hidden) || id.chars().count() > MAX_TITLE {
            return Err("a key's id must be plain and non-empty".into());
        }
        // Both are named "<plugin id>/<id>" in the key map, so the key would replace the command's default.
        if self.palette.iter().any(|p| !p.is_mode && p.id == id) {
            return Err(format!("{:?} is already one of its palette commands", visible(&id)));
        }
        let c = crate::chord::canonical_with_cmd(&chord).ok_or_else(|| format!("{:?} is not a chord with cmd, like \"cmd+shift+p\"", visible(&chord).chars().take(40).collect::<String>()))?;
        let mine = format!("{}/{id}", self.id);
        if let Some(owner) = self.core.as_ref().and_then(|core| core.chord_owner(&c)).filter(|o| *o != mine) {
            return Err(if owner == "haunt" { format!("{c} is Haunt's or macOS's") } else { format!("{c} is already {owner}") });
        }
        if let Some((other, _)) = self.keys.iter().find(|(i, k)| *k == c && *i != id) {
            return Err(format!("{c} is already {other}"));
        }
        if !self.keys.iter().any(|(i, _)| *i == id) && self.keys.len() >= MAX_KEYS {
            return Err(format!("at most {MAX_KEYS} keys"));
        }
        if self.keys.iter().any(|(i, k)| *i == id && *k == c) {
            return Ok(());
        }
        self.request(HostRequest::KeysChanged { plugin_id: self.id.clone() })?;
        self.keys.retain(|(i, _)| *i != id);
        self.keys.push((id, c));
        Ok(())
    }

    fn unbind(&mut self, id: String) {
        let before = self.keys.len();
        self.keys.retain(|(i, _)| *i != id);
        if self.keys.len() != before {
            self.outbox.push(HostRequest::KeysChanged { plugin_id: self.id.clone() });
        }
    }

    fn hover_hold(&mut self, modifier: Option<String>) -> Result<(), String> {
        let take = match modifier.as_deref() {
            None => false,
            Some("alt") => true,
            Some(m) => return Err(format!("{:?} can't hover-hold; only \"alt\"", visible(m).chars().take(40).collect::<String>())),
        };
        if take == self.hover_hold {
            return Ok(());
        }
        let core = self.core.clone().ok_or("no haunt core")?;
        if take {
            core.claim_hover(&self.id)?;
        } else {
            core.release_hover(&self.id);
        }
        self.hover_hold = take;
        self.outbox.push(HostRequest::KeysChanged { plugin_id: self.id.clone() });
        Ok(())
    }
}

static NEXT_JOB: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

impl wexec::Host for HostState {
    fn run(&mut self, surface: String, command: wexec::Command) -> Result<u64, String> {
        use crate::plugin_exec::{self as px, ExecCommand as C, ExecDone};
        let cmd = match command {
            wexec::Command::GhPrChecks => C::GhPrChecks,
            wexec::Command::GhPrView => C::GhPrView,
            wexec::Command::GitStatus => C::GitStatus,
            wexec::Command::GitBranch => C::GitBranch,
            wexec::Command::GitHead => C::GitHead,
            wexec::Command::GitLog(n) => C::GitLog(n),
        };
        if !self.exec.iter().any(|x| x == cmd.name()) {
            return Err(format!("{} is not in this plugin's exec list", cmd.name()));
        }
        if self.exec_jobs.len() >= px::MAX_RUNNING {
            return Err(format!("at most {} commands at a time", px::MAX_RUNNING));
        }
        let cmd_name = cmd.name();
        let core = self.core.as_ref().ok_or("no haunt core")?;
        let (_, opened) = core.tab_folders(&surface).ok_or("no such tab")?;
        let repo = self.fs.tab_repo(&opened).ok_or("the tab wasn't opened in a git repository inside your home folder")?;
        let sink = core.exec_sink().ok_or("commands are off")?;
        let job = NEXT_JOB.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let plugin_id = self.id.clone();
        std::thread::Builder::new()
            .name("haunt-exec".into())
            .spawn(move || sink(ExecDone { plugin_id, job, outcome: px::JobOutcome::Exec(px::run(&cmd, &repo)) }))
            .map_err(|e| e.to_string())?;
        self.exec_jobs.push(job);
        self.audit("exec", &clip(surface), cmd_name, job);
        Ok(job)
    }
}

pub const HOLD_MAX_MINUTES: u32 = 240;
const HOLD_ACTIONS_MAX: usize = 2;
const HOLD_HEADLINE_MAX: usize = 64;
const HOLD_LABEL_MAX: usize = 24;
/// The binding a hold summary's actions come back with.
pub const HOLD_BINDING: &str = "hold";

impl whold::Host for HostState {
    fn start(&mut self, minutes: u32) -> Result<(), String> {
        if !(1..=HOLD_MAX_MINUTES).contains(&minutes) {
            return Err(format!("a hold is 1 to {HOLD_MAX_MINUTES} minutes"));
        }
        if self.outbox.len() >= MAX_OUTBOX {
            return Err("too many pending requests".into());
        }
        let core = self.core.as_ref().ok_or("no haunt core")?;
        core.hold_notifications(&self.id, Instant::now() + Duration::from_secs(u64::from(minutes) * 60));
        self.hold_actions.clear();
        self.request(HostRequest::HoldNotifications { plugin_id: self.id.clone(), minutes })
    }

    fn set_summary(&mut self, headline: Option<String>, actions: Vec<whold::SummaryAction>) -> Result<(), String> {
        if !self.core.as_ref().is_some_and(|c| c.holds_notifications(&self.id)) {
            return Err("no hold running".into());
        }
        if actions.len() > HOLD_ACTIONS_MAX {
            return Err(format!("at most {HOLD_ACTIONS_MAX} actions"));
        }
        let core = self.core.as_ref().ok_or("no haunt core")?;
        let (mut acts, mut tabs) = (Vec::new(), Vec::new());
        for a in actions {
            let (id, title) = (clip(a.id), plain(&a.label, HOLD_LABEL_MAX));
            if id.is_empty() || title.trim().is_empty() {
                return Err("an action needs an id and a label".into());
            }
            if says_status(&title) {
                return Err(format!("{title:?} reads as Haunt's own status"));
            }
            if let Some(s) = a.surface.as_deref().filter(|s| !core.has_surface(s)) {
                return Err(format!("no open tab {:?}", clip(s.to_owned())));
            }
            tabs.push((id.clone(), a.surface));
            acts.push(NotifyAction { id, title });
        }
        self.hold_actions = tabs;
        let headline = plain_opt(headline, HOLD_HEADLINE_MAX);
        self.request(HostRequest::HoldSummary { plugin_id: self.id.clone(), headline, actions: acts })
    }

    fn release(&mut self) {
        self.release_hold();
    }
}

pub const TICK_MIN_SECS: u32 = 15;
const TICK_MAX_SECS: u32 = 86_400;

impl wclip::Host for HostState {
    fn write(&mut self, text: String) -> Result<(), String> {
        if !self.copy_ok {
            return Err("only once per button, key or command the user just used".into());
        }
        let mut text = plain_lines(&text, CLIPBOARD_LINES, CLIPBOARD_MAX);
        let mut end = text.len().min(CLIPBOARD_MAX);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
        // No trailing line break, so a paste never ends by pressing Return; and no blank first line
        // to hide the rest below a harmless-looking start.
        let text = text.trim_end_matches('\n').to_owned();
        if text.split('\n').next().is_none_or(|l| l.trim().is_empty()) {
            return Err("the copied text's first line is empty".into());
        }
        self.copy_ok = false;
        let (bytes, lines) = (text.len() as u64, text.split('\n').count());
        self.request(HostRequest::ClipboardWrite { plugin_id: self.id.clone(), plugin_name: self.name.clone(), text })?;
        // Never the text: its size only.
        self.audit("clipboard.write", "", &format!("{lines} lines"), bytes);
        Ok(())
    }
}

impl wfslist::Host for HostState {
    fn entries(&mut self, dir: String) -> Result<Vec<wfslist::Entry>, String> {
        if !per_sec_ok(&mut self.list_times, FS_LIST_PER_SEC) {
            return Err(format!("fs-list rate limit ({FS_LIST_PER_SEC}/s)"));
        }
        let entries = self.fs.entries(&dir)?;
        let rel = self.in_project(&dir);
        self.audit("fs-list.entries", "", &rel, entries.len() as u64);
        Ok(entries.into_iter().map(|e| wfslist::Entry { name: e.name, size: e.size, dir: e.dir }).collect())
    }
    /// The walk runs on a thread of its own, off the plugin set's lock, and reports through the core's
    /// job sink like `exec.run`.
    fn tree(&mut self, dir: String, depth: u8) -> Result<u64, String> {
        use crate::plugin_exec::{ExecDone, JobOutcome};
        let now = Instant::now();
        if self.last_tree.is_some_and(|t| now.duration_since(t) < TREE_EVERY) {
            return Err(format!("fs-list.tree runs once per {} s", TREE_EVERY.as_secs()));
        }
        self.last_tree = Some(now);
        if depth > crate::plugin_fs::TREE_DEPTH {
            return Err(format!("depth is at most {}", crate::plugin_fs::TREE_DEPTH));
        }
        let sink = self.core.as_ref().and_then(CoreHandle::exec_sink).ok_or("no haunt core to report the walk to")?;
        let (fs, job, plugin_id) = (self.fs.clone(), NEXT_JOB.fetch_add(1, std::sync::atomic::Ordering::Relaxed), self.id.clone());
        std::thread::Builder::new()
            .name("haunt-fs-tree-job".into())
            .spawn({
                let dir = dir.clone();
                move || sink(ExecDone { plugin_id, job, outcome: JobOutcome::Tree(fs.tree(&dir, depth)) })
            })
            .map_err(|e| e.to_string())?;
        let rel = self.in_project(&dir);
        self.tree_jobs.push((job, rel));
        Ok(job)
    }
}

impl wlink::Host for HostState {
    fn open_url(&mut self, url: String) -> Result<(), String> {
        let clicked = self.clicked.take().ok_or("only once per click on one of its panel buttons")?;
        if url != clicked {
            return Err("the url must be the clicked button's action, which its tooltip shows".into());
        }
        link_ok(&url, &self.links)?;
        let host = link_host(&url).unwrap_or_default().to_owned();
        self.request(HostRequest::OpenUrl { plugin_id: self.id.clone(), url })?;
        // The domain only: a path or query can carry what the plugin read.
        self.audit("link.open-url", "", &host, 1);
        Ok(())
    }
}

/// Whether `url` may be opened: `https://`, then exactly one of `domains` (so no user, password or
/// port), then a path, query or fragment of printable ASCII with no space or backslash.
fn link_host(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    Some(&rest[..rest.find(['/', '?', '#']).unwrap_or(rest.len())])
}

pub fn link_ok(url: &str, domains: &[String]) -> Result<(), String> {
    let rest = url.strip_prefix("https://").ok_or("only https links open")?;
    let (host, tail) = rest.split_at(rest.find(['/', '?', '#']).unwrap_or(rest.len()));
    if host.contains('@') {
        return Err("a link can't carry a user or password".into());
    }
    if !domains.iter().any(|d| d == host) {
        return Err(format!("{:?} is not one of the manifest's open_url domains", visible(host).chars().take(64).collect::<String>()));
    }
    if tail.bytes().any(|b| !(0x21..0x7f).contains(&b) || b == b'\\') {
        return Err("a link is printable ASCII, with no space or backslash".into());
    }
    Ok(())
}

impl wtimer::Host for HostState {
    fn every(&mut self, seconds: u32) -> Result<(), String> {
        if !(TICK_MIN_SECS..=TICK_MAX_SECS).contains(&seconds) {
            return Err(format!("seconds must be {TICK_MIN_SECS} to {TICK_MAX_SECS}"));
        }
        let every = Duration::from_secs(seconds.into());
        self.timer = Some((every, Instant::now() + every));
        Ok(())
    }

    fn stop(&mut self) {
        self.timer = None;
    }
}

impl wclock::Host for HostState {
    fn local_offset_min(&mut self) -> i32 {
        local_offset_min()
    }
}

/// Minutes east of UTC in the user's time zone now; 0 if the zone can't be read.
pub fn local_offset_min() -> i32 {
    // Safety: `time` with a null pointer only returns; `localtime_r` writes only the `tm` we own.
    let now = unsafe { libc::time(std::ptr::null_mut()) };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&now, &mut tm) }.is_null() {
        return 0;
    }
    (tm.tm_gmtoff / 60) as i32
}

/// Characters of a command, path or summary a plugin gets; a plan's per line.
pub const EVENT_TEXT: usize = 1024;
/// Lines of a plan a plugin gets.
pub const PLAN_LINES: usize = 200;

/// One line of plain text: whitespace becomes a space, other hidden characters go, at most `max` characters.
pub fn plain(s: &str, max: usize) -> String {
    s.chars().map(|c| if c.is_whitespace() || is_blank(c) { ' ' } else { c }).filter(|&c| !is_hidden(c)).take(max).collect()
}

/// Text kept as lines: CR goes, then each line is `plain` and cut to `line_max`; at most `max_lines`.
pub fn plain_lines(s: &str, max_lines: usize, line_max: usize) -> String {
    s.split('\n').take(max_lines).map(|l| plain(&l.replace('\r', ""), line_max)).collect::<Vec<_>>().join("\n")
}

/// `s` as haunt shows it, hidden characters spelled out, at most `max` characters.
fn shown(s: &str, max: usize) -> String {
    visible(s).chars().take(max).collect()
}

/// What of an event a plugin may see beyond its kind and ids.
#[derive(Debug, Clone, Copy, Default)]
struct EventGrant {
    /// `event_details`: commands, file paths, prompts and plans, which can hold secrets.
    details: bool,
    /// `pty_write`: only a plugin that can answer a request gets its key.
    answers: bool,
}

/// The WIT event for `t`. Commands and paths keep what was sent, spelled out, so a plugin sees what
/// the user would; summaries are plain text.
fn agent_event(t: &Tapped, g: EventGrant) -> wit::AgentEvent {
    let e = &t.event;
    let call = match &e.kind {
        EventKind::ToolStart { tool } | EventKind::ToolDone { tool } | EventKind::ToolFailed { tool } | EventKind::ToolRan { tool } | EventKind::PermissionSeen { tool } => {
            Some(tool)
        }
        _ => None,
    };
    let plan = matches!(e.kind, EventKind::PlanExit { .. });
    let summary = match &e.kind {
        EventKind::TaskCreated { subject, .. } => subject.clone(),
        EventKind::TaskUpdated { status, .. } => Some(status.clone()),
        EventKind::ToolRan { tool } => Some(tool.tool_name.clone()),
        EventKind::SubagentTool { tool_name } => Some(tool_name.clone()),
        EventKind::PromptSubmit { query } => query.clone().filter(|_| g.details),
        EventKind::PlanExit { summary } => summary.clone().filter(|_| g.details),
        _ => None,
    };
    let tool = match &e.kind {
        EventKind::FileEdited { tool_name, .. } => tool_name.clone(),
        EventKind::SubagentTool { tool_name } => Some(tool_name.clone()),
        _ => call.map(|c| c.tool_name.clone()),
    };
    let file_path = match &e.kind {
        EventKind::FileEdited { file_path, .. } => file_path.clone(),
        _ => call.and_then(|c| c.raw_file_path.clone().or_else(|| c.file_path.clone())),
    }
    .filter(|_| g.details);
    let task_id = match &e.kind {
        EventKind::TaskCreated { task_id, .. } | EventKind::TaskUpdated { task_id, .. } => Some(task_id.clone()),
        _ => None,
    };
    wit::AgentEvent {
        kind: plain(e.kind.name(), 64),
        session_id: e.session_id.as_deref().map(|s| plain(s, 256)),
        agent_id: e.agent_id.as_deref().map(|s| plain(s, 256)),
        cwd: e.cwd.as_deref().map(|s| shown(s, EVENT_TEXT)),
        summary: summary.map(|s| if plan { plain_lines(&s, PLAN_LINES, EVENT_TEXT) } else { plain(&s, EVENT_TEXT) }),
        verified: t.verified,
        surface: Some(t.surface.clone()),
        tool: tool.map(|s| plain(&s, 256)),
        command: call.filter(|_| g.details).and_then(|c| c.raw_command.as_deref().or(c.command.as_deref())).map(|s| shown(s, EVENT_TEXT)),
        file_path: file_path.map(|s| shown(&s, EVENT_TEXT)),
        task_id: task_id.map(|s| plain(&s, 256)),
        request_key: t.request_key.filter(|_| t.verified && g.answers),
    }
}

/// Wall time to the second and monotonic time to 10 ms, so plugins get no fine-grained timer.
struct CoarseWall;
impl HostWallClock for CoarseWall {
    fn resolution(&self) -> Duration {
        Duration::from_secs(1)
    }
    fn now(&self) -> Duration {
        let d = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        Duration::from_secs(d.as_secs())
    }
}

struct CoarseMono(Instant);
impl HostMonotonicClock for CoarseMono {
    fn resolution(&self) -> u64 {
        10_000_000
    }
    fn now(&self) -> u64 {
        let ns = self.0.elapsed().as_nanos() as u64;
        ns - ns % 10_000_000
    }
}

/// Ticks the engine epoch only while a plugin call is running, so an idle host costs nothing.
struct Epoch {
    active: AtomicUsize,
    thread: std::thread::Thread,
}

impl Drop for Epoch {
    fn drop(&mut self) {
        self.thread.unpark();
    }
}

impl Epoch {
    fn enter(&self) {
        self.active.fetch_add(1, Ordering::AcqRel);
        self.thread.unpark();
    }
    fn exit(&self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }

    /// Runs `f`, which enters wasm, with the epoch ticking so its deadline can fire.
    fn ticking<R>(&self, f: impl FnOnce() -> R) -> R {
        struct Exit<'a>(&'a Epoch);
        impl Drop for Exit<'_> {
            fn drop(&mut self) {
                self.0.exit();
            }
        }
        self.enter();
        let _exit = Exit(self);
        f()
    }
}

fn spawn_epoch(engine: EngineWeak) -> Result<Arc<Epoch>, PluginError> {
    let (tx, rx) = std::sync::mpsc::channel::<Weak<Epoch>>();
    let handle = std::thread::Builder::new().name("haunt-plugin-epoch".into()).spawn(move || {
        let Ok(weak) = rx.recv() else { return };
        loop {
            std::thread::park();
            loop {
                let Some(e) = weak.upgrade() else { return };
                if e.active.load(Ordering::Acquire) == 0 {
                    break;
                }
                drop(e);
                std::thread::sleep(TICK);
                match engine.upgrade() {
                    Some(engine) => engine.increment_epoch(),
                    None => return,
                }
            }
        }
    })?;
    let epoch = Arc::new(Epoch { active: AtomicUsize::new(0), thread: handle.thread().clone() });
    let _ = tx.send(Arc::downgrade(&epoch));
    Ok(epoch)
}

pub struct LoadedPlugin {
    store: Store<HostState>,
    bindings: Plugin,
    epoch: Arc<Epoch>,
    disabled: Option<String>,
}

impl LoadedPlugin {
    pub fn id(&self) -> &str {
        &self.store.data().id
    }

    pub fn disabled(&self) -> Option<&str> {
        self.disabled.as_deref()
    }

    /// Runs one export under the CPU budget; any trap disables the plugin, since the instance is poisoned.
    fn call<R>(&mut self, f: impl FnOnce(&Plugin, &mut Store<HostState>) -> wasmtime::Result<R>) -> Result<R, PluginError> {
        if let Some(why) = &self.disabled {
            return Err(PluginError(why.clone()));
        }
        self.store.set_epoch_deadline(CALL_TICKS);
        let (bindings, store) = (&self.bindings, &mut self.store);
        let res = self.epoch.ticking(|| f(bindings, store));
        let data = self.store.data_mut();
        if let Err(e) = data.kv.flush() {
            data.push_log(format!("error kv write: {e}"));
        }
        res.map_err(|e| {
            let why = if e.downcast_ref::<Trap>() == Some(&Trap::Interrupt) {
                format!("plugin {} exceeded its {} ms CPU budget and was disabled", self.id(), CALL_TICKS * TICK.as_millis() as u64)
            } else {
                format!("plugin {} trapped and was disabled: {e:#}", self.id())
            };
            self.disabled = Some(why.clone());
            let data = self.store.data_mut();
            data.release_sidebar();
            data.release_rows();
            data.close_panels();
            data.release_hold();
            data.clear_top_row();
            data.drop_keys();
            data.drop_user_effects();
            PluginError(why)
        })
    }

    pub fn init(&mut self, settings_json: &str) -> Result<(), PluginError> {
        self.call(|b, s| b.call_init(s, settings_json))
    }

    /// A `verified` event widens the plugin's `${cwd}` grant to the git root of the folder the tab was opened
    /// in (`FsScope::project_folder`), never to its live cwd or the cwd the event names.
    pub fn on_event(&mut self, t: &Tapped) -> Result<(), PluginError> {
        if t.verified {
            self.store.data_mut().grant_tab_folder(t);
        }
        let ev = agent_event(t, self.store.data().events);
        self.call(|b, s| b.call_on_event(s, &ev))
    }

    /// Calls `on-tick` if this plugin's `timer.every` interval has passed by `now`; whether it did.
    pub fn tick(&mut self, now: Instant) -> Result<bool, PluginError> {
        let st = self.store.data_mut();
        match st.timer {
            Some((every, due)) if now >= due => st.timer = Some((every, now + every)),
            _ => return Ok(false),
        }
        let ms = CoarseWall.now().as_millis() as u64;
        self.call(|b, s| b.call_on_tick(s, ms)).map(|()| true)
    }

    /// The user stepped away (`back_ms` None) or came back after `back_ms`: `on-away-changed`. Coming
    /// back isn't a user gesture (they may be typing into another app): a sheet asked for then waits
    /// for `app_activated`.
    pub fn away_changed(&mut self, back_ms: Option<u64>) -> Result<(), PluginError> {
        let Some(ms) = back_ms else {
            self.store.data_mut().drop_return_sheet();
            return self.call(|b, s| b.call_on_away_changed(s, true, 0));
        };
        self.store.data_mut().returning = true;
        let res = self.call(|b, s| b.call_on_away_changed(s, false, ms));
        self.store.data_mut().returning = false;
        res
    }

    /// The user switched to Haunt at `now`, a gesture of theirs: a sheet held from their return is due
    /// `RETURN_SHEET_DELAY` later (`return_sheet_due`).
    pub fn app_activated(&mut self, now: Instant) {
        self.store.data_mut().return_activated(now);
    }

    /// Haunt stopped being the active app before a held sheet was due: it waits for the next activation.
    pub fn app_resigned(&mut self) {
        self.store.data_mut().return_resigned();
    }

    /// Shows a held sheet whose delay has passed, or drops it if the user `typed` into Haunt meanwhile.
    pub fn return_sheet_due(&mut self, now: Instant, typed: bool) -> Result<(), PluginError> {
        self.store.data_mut().return_sheet_due(now, typed).map_err(PluginError)
    }

    /// A job this instance started finished: `on-exec(job, outcome)` or `on-fs-tree(job, outcome)`.
    /// Another instance's job is dropped.
    pub fn exec_done(&mut self, job: u64, outcome: crate::plugin_exec::JobOutcome) -> Result<(), PluginError> {
        use crate::plugin_exec::JobOutcome;
        let data = self.store.data_mut();
        match outcome {
            JobOutcome::Exec(o) => {
                let Some(i) = data.exec_jobs.iter().position(|j| *j == job) else { return Ok(()) };
                data.exec_jobs.remove(i);
                let o = o.map(|o| wexec::Output { status: o.status, stdout: o.stdout, stderr: o.stderr, truncated: o.truncated });
                self.call(|b, s| b.call_on_exec(s, job, o.as_ref().map_err(String::as_str)))
            }
            JobOutcome::Tree(t) => {
                let Some(i) = data.tree_jobs.iter().position(|(j, _)| *j == job) else { return Ok(()) };
                let (_, rel) = data.tree_jobs.remove(i);
                if let Ok(t) = &t {
                    data.audit("fs-list.tree", "", &rel, t.folders.iter().map(|f| u64::from(f.files)).sum());
                }
                let t = t.map(|t| wfslist::TreeResult {
                    folders: t.folders.into_iter().map(|f| wfslist::Folder { path: f.path, files: f.files, bytes: f.bytes }).collect(),
                    truncated: t.truncated,
                });
                self.call(|b, s| b.call_on_fs_tree(s, job, t.as_ref().map_err(String::as_str)))
            }
        }
    }

    /// The user pressed a button on show `generation` of panel `id`, or closed it (`action` empty):
    /// `on-action(action, "panel:<id>")`. Anything but that show's own button is refused.
    pub fn panel_action(&mut self, id: &str, generation: u64, action: &str) -> Result<(), PluginError> {
        let data = self.store.data_mut();
        if !data.panels.user_action(id, generation, action) {
            return Err(PluginError(format!("panel {id} (show {generation}) has no action {action:?}")));
        }
        if action.is_empty() {
            data.release_sheet(id);
        }
        data.arm(!action.is_empty(), Some(action));
        let res = self.user_call(|p| p.on_action(action, &format!("panel:{id}")));
        self.store.data_mut().disarm();
        res
    }

    /// Runs `f` as the plugin's answer to something the user just did, when a sheet is allowed.
    fn user_call<R>(&mut self, f: impl FnOnce(&mut Self) -> R) -> R {
        self.store.data_mut().user_call = true;
        let r = f(self);
        self.store.data_mut().user_call = false;
        r
    }

    /// Another plugin's right pane took this one's place: it is closed, without an `on-action`.
    pub(crate) fn panel_displaced(&mut self, id: &str) {
        let data = self.store.data_mut();
        data.release_sheet(id);
        data.panels.close(id);
    }

    /// Commands and modes the plugin registered through `palette`.
    pub fn palette(&self) -> &[PaletteItem] {
        &self.store.data().palette
    }

    pub fn palette_items(&mut self, mode: &str, query: &str) -> Result<Vec<PaletteItem>, PluginError> {
        let items = self.call(|b, s| b.call_palette_items(s, mode, query))?;
        let id = self.id().to_owned();
        Ok(items
            .into_iter()
            .take(MAX_PALETTE * 4)
            .map(|i| PaletteItem {
                plugin_id: id.clone(),
                id: clip(i.id),
                title: clip(i.title),
                subtitle: i.subtitle.map(clip),
                default_key: None,
                is_mode: false,
                at_ms: i.at_ms,
                mark: i.mark.map(|m| match m {
                    wit::Mark::Open => Mark::Open,
                    wit::Mark::Filled => Mark::Filled,
                    wit::Mark::Round => Mark::Round,
                }),
                surface_id: i.surface.map(clip),
            })
            .collect())
    }

    /// Drops the plugin's palette commands first: it registers the ones its new settings call for.
    pub fn on_settings_changed(&mut self, settings_json: &str) -> Result<(), PluginError> {
        self.store.data_mut().palette.retain(|p| p.is_mode);
        self.call(|b, s| b.call_on_settings_changed(s, settings_json))
    }

    pub fn on_action(&mut self, action_id: &str, payload: &str) -> Result<(), PluginError> {
        self.call(|b, s| b.call_on_action(s, action_id, payload))
    }

    /// The user clicked this plugin's top row: `on-action(<its action>, "top")`.
    pub fn top_row_clicked(&mut self) -> Result<(), PluginError> {
        let action = self.store.data().top_action.clone().ok_or_else(|| PluginError("no top row to click".into()))?;
        self.on_action(&action, "top")
    }

    /// The user chose action `action_id` on a notification bound to `binding` (empty: none):
    /// `on-action(action_id, binding)`, only for an action this plugin posted in this run or put in its
    /// latest hold summary.
    pub fn notify_action(&mut self, action_id: &str, binding: &str) -> Result<(), PluginError> {
        self.store.data_mut().notify_click(action_id, binding).map_err(PluginError)?;
        let res = self.on_action(action_id, binding);
        self.store.data_mut().disarm();
        res
    }

    /// The user ran palette item `action_id` (from the palette or its key): `typing` may type into the
    /// tab focused now, until the call returns, but only if `terminal_shown`: none while the agents view
    /// or the review screen hides the terminal.
    pub fn run_command(&mut self, action_id: &str, terminal_shown: bool) -> Result<(), PluginError> {
        self.run_user_action(action_id, "", terminal_shown, true)
    }

    /// The user pressed (`down`) or released one of this plugin's keys: `on-action(id, "key-down" or
    /// "key-up")`, which may type like a command.
    pub fn key_action(&mut self, id: &str, down: bool, terminal_shown: bool) -> Result<(), PluginError> {
        if !self.store.data().keys.iter().any(|(i, _)| i == id) {
            return Err(PluginError(format!("no key {id:?}")));
        }
        // Only the press may copy: a release is the same gesture, not a second one.
        self.run_user_action(id, if down { "key-down" } else { "key-up" }, terminal_shown, down)
    }

    /// The tab hold summary action `action_id` brings forward, while that tab is still open.
    pub fn hold_surface(&self, action_id: &str) -> Option<String> {
        self.store.data().hold_surface(action_id)
    }

    /// Whether this plugin has `keys.hover-hold`.
    pub fn hover_holds(&self) -> bool {
        self.store.data().hover_hold
    }

    /// The user started (`held`) or stopped hover-holding on row `surface`: `on-hover-hold(held, surface)`.
    pub fn hover_hold(&mut self, held: bool, surface: &str) -> Result<(), PluginError> {
        if !self.store.data().hover_hold {
            return Err(PluginError("no hover-hold".into()));
        }
        if !held {
            return self.call(|b, s| b.call_on_hover_hold(s, false, surface));
        }
        let data = self.store.data_mut();
        data.reads_left = READS_PER_ACTION;
        // `read` compares the clipped surface it is given, so a long id still matches.
        data.read_only = Some(clip(surface.to_owned()));
        let res = self.call(|b, s| b.call_on_hover_hold(s, true, surface));
        let data = self.store.data_mut();
        data.reads_left = 0;
        data.read_only = None;
        res
    }

    pub fn keys(&self) -> Vec<PluginKey> {
        let id = self.id();
        self.store.data().keys.iter().map(|(i, c)| PluginKey { plugin_id: id.to_owned(), id: i.clone(), chord: c.clone() }).collect()
    }

    fn run_user_action(&mut self, action_id: &str, payload: &str, terminal_shown: bool, copy: bool) -> Result<(), PluginError> {
        let data = self.store.data_mut();
        data.typing_into = data.core.as_ref().and_then(CoreHandle::selected_surface).filter(|_| terminal_shown);
        data.reads_left = READS_PER_ACTION;
        data.arm(copy, None);
        let res = self.user_call(|p| p.on_action(action_id, payload));
        let data = self.store.data_mut();
        data.typing_into = None;
        data.reads_left = 0;
        data.disarm();
        res
    }

    pub fn row_menu(&mut self, surface: &str) -> Result<Vec<RowMenuItem>, PluginError> {
        let items = self.call(|b, s| b.call_row_menu(s, surface))?;
        let id = self.id().to_owned();
        Ok(items
            .into_iter()
            .take(MAX_PALETTE)
            .map(|i| RowMenuItem { plugin_id: id.clone(), id: clip(i.id), title: clip(i.title), checked: i.checked, parent: i.parent.map(clip) })
            .collect())
    }

    pub fn on_row_moved(&mut self, surface: &str, group: &str, before: Option<&str>) -> Result<(), PluginError> {
        self.call(|b, s| b.call_on_row_moved(s, surface, group, before))
    }

    /// Swaps in `theme` and tells the plugin, which reads it back through the `theme` import.
    pub fn set_theme(&mut self, theme: Arc<Theme>) -> Result<(), PluginError> {
        self.store.data_mut().theme = theme;
        self.call(|b, s| b.call_on_theme_changed(s))
    }

    pub fn take_logs(&mut self) -> Vec<String> {
        std::mem::take(&mut self.store.data_mut().logs)
    }

    pub fn take_audit(&mut self) -> Vec<AuditLine> {
        self.store.data_mut().take_audit()
    }

    pub fn take_requests(&mut self) -> Vec<HostRequest> {
        std::mem::take(&mut self.store.data_mut().outbox)
    }

    pub(crate) fn pending_requests(&self) -> usize {
        self.store.data().outbox.len()
    }
}

pub struct PluginHost {
    engine: Engine,
    epoch: Arc<Epoch>,
}

impl PluginHost {
    pub fn new() -> Result<Self, PluginError> {
        let mut config = Config::new();
        config.wasm_component_model(true);
        config.epoch_interruption(true);
        let engine = Engine::new(&config)?;
        let epoch = spawn_epoch(engine.weak())?;
        Ok(Self { engine, epoch })
    }

    /// Compiles `wasm`, or loads it from `cache` when an HMAC-verified artefact exists. The caller
    /// passes the SHA-256 it already took of `wasm`, so the bytes are hashed once.
    pub(crate) fn compile_cached(&self, wasm: &[u8], wasm_sha256: &[u8; 32], cache: &CwasmCache) -> Result<(Component, bool), PluginError> {
        debug_assert_eq!(<[u8; 32]>::from(Sha256::digest(wasm)), *wasm_sha256, "the digest names the cache entry");
        let name = cache_name(&self.engine, wasm_sha256);
        if let Some(art) = cache.get(&name) {
            // Safety: the bytes verified under our per-install key, so we serialised them.
            if let Ok(c) = unsafe { Component::deserialize(&self.engine, &art) } {
                return Ok((c, true));
            }
        }
        let c = Component::new(&self.engine, wasm)?;
        cache.put(&name, &c.serialize()?)?;
        Ok((c, false))
    }

    /// A linker holding only the imports `caps` grants; anything else is absent and fails to link.
    pub fn linker(&self, caps: &Capabilities) -> Result<Linker<HostState>, PluginError> {
        let mut l = Linker::<HostState>::new(&self.engine);
        // wasm32-wasip2 std imports WASI; the context grants nothing (no dirs, env, sockets).
        wasmtime_wasi::p2::add_to_linker_sync(&mut l)?;
        wit::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        wlog::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        wkv::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        wpal::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        wtheme::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        if caps.timer {
            wtimer::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
            wclock::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.notifications {
            wnotify::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.notify_hold {
            whold::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.sidebar_top {
            wtop::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.keys {
            wkeys::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if !caps.exec.is_empty() {
            wexec::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.pty_write {
            wpty::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.pty_type {
            wtyping::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.terminal_read {
            wterm::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.decisions_read {
            wdec::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.allowlist_suggest {
            wallow::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.sidebar {
            wside::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.decorate {
            wrows::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.clipboard_write() {
            wclip::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.fs_list {
            wfslist::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if !caps.open_url.is_empty() {
            wlink::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.panel {
            wpanel::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.fs_read_granted() || caps.fs_write_granted() {
            let mut fs = l.instance("haunt:plugin/fs@0.5.0")?;
            if caps.fs_read_granted() {
                fs.func_wrap("read", |mut s: StoreContextMut<'_, HostState>, (path,): (String,)| Ok((s.data_mut().fs_read(&path),)))?;
                fs.func_wrap("list", |mut s: StoreContextMut<'_, HostState>, (path,): (String,)| Ok((s.data_mut().fs_list(&path),)))?;
            }
            if caps.fs_write_granted() {
                fs.func_wrap("write", |mut s: StoreContextMut<'_, HostState>, (path, data): (String, Vec<u8>)| {
                    Ok((s.data_mut().fs_write(&path, &data),))
                })?;
            }
        }
        Ok(l)
    }

    /// Checks that `component` links against `caps` without running it.
    pub fn check_links(&self, component: &Component, caps: &Capabilities) -> Result<(), PluginError> {
        self.linker(caps)?.instantiate_pre(component)?;
        Ok(())
    }

    /// Instantiates a compiled component with `spec`'s grants and runs its `init`.
    pub fn instantiate(&self, component: &Component, spec: &LoadSpec) -> Result<LoadedPlugin, PluginError> {
        self.instantiate_with(component, spec, &self.linker(&spec.caps)?)
    }

    /// `instantiate` with a linker for `spec.caps` the caller may share between loads.
    pub fn instantiate_with(&self, component: &Component, spec: &LoadSpec, linker: &Linker<HostState>) -> Result<LoadedPlugin, PluginError> {
        let mut store = Store::new(&self.engine, HostState::new(&spec.id, &spec.caps, spec.kv_path.clone(), spec.haunt_dir.as_deref(), spec.core.clone()));
        if !spec.name.is_empty() {
            store.data_mut().name = spec.name.clone();
        }
        store.limiter(|s| &mut s.limits);
        // Instantiation runs the component's start functions, which get the same budget as a call.
        store.set_epoch_deadline(CALL_TICKS);
        let bindings = self.epoch.ticking(|| Plugin::instantiate(&mut store, component, linker))?;
        let mut plugin = LoadedPlugin { store, bindings, epoch: self.epoch.clone(), disabled: None };
        plugin.init(&spec.settings_json)?;
        Ok(plugin)
    }

    pub fn load_bytes(&self, bytes: &[u8], cache_dir: &Path, spec: &LoadSpec) -> Result<(LoadedPlugin, LoadStats), PluginError> {
        let cache = CwasmCache::open(cache_dir)?;
        let t = Instant::now();
        let (component, from_cache) = self.compile_cached(bytes, &Sha256::digest(bytes).into(), &cache)?;
        let compile_ms = t.elapsed().as_secs_f64() * 1e3;
        let t = Instant::now();
        let plugin = self.instantiate(&component, spec)?;
        let instantiate_ms = t.elapsed().as_secs_f64() * 1e3;
        Ok((plugin, LoadStats { wasm_bytes: bytes.len() as u64, from_cache, compile_ms, instantiate_ms }))
    }

    /// Loads a bundled component with no gated capabilities and in-memory kv.
    pub fn load(&self, wasm: &Path, cache_dir: &Path) -> Result<(LoadedPlugin, LoadStats), PluginError> {
        let bytes = std::fs::read(wasm)?;
        let spec = LoadSpec { id: "bundled".into(), settings_json: "{}".into(), ..Default::default() };
        self.load_bytes(&bytes, cache_dir, &spec)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testdir::TempDir;

    fn tempdir(tag: &str) -> TempDir {
        TempDir::new(&format!("host-{tag}"))
    }

    #[test]
    fn tampered_cwasm_is_rejected_and_recompiled() {
        let dir = tempdir("cwasm");
        let host = PluginHost::new().unwrap();
        let cache = CwasmCache::open(&dir).unwrap();
        // Text form; the dev-only `wat` feature lets Component::new parse it.
        let wasm = b"(component)".to_vec();

        let sha = Sha256::digest(&wasm).into();
        assert!(!host.compile_cached(&wasm, &sha, &cache).unwrap().1);
        assert!(host.compile_cached(&wasm, &sha, &cache).unwrap().1);

        let name = cache_name(&host.engine, &sha);
        let art = dir.join(format!("{name}.cwasm"));
        let mut bytes = std::fs::read(&art).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 0xff;
        std::fs::write(&art, bytes).unwrap();

        assert!(!host.compile_cached(&wasm, &sha, &cache).unwrap().1, "tampered artefact must not load");
        assert!(host.compile_cached(&wasm, &sha, &cache).unwrap().1, "recompiled artefact is cached again");
    }

    const FS_WRITE_IMPORT: &str = r#"(component
        (import "haunt:plugin/fs@0.5.0" (instance
            (export "write" (func (param "path" string) (param "data" (list u8)) (result (result (error string))))))))"#;

    #[test]
    fn ungranted_import_fails_to_link() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, FS_WRITE_IMPORT).unwrap();
        let e = host.check_links(&c, &Capabilities::default()).unwrap_err().0;
        assert!(e.contains("haunt:plugin/fs"), "{e}");

        let read_only = Capabilities { fs_read: vec!["${cwd}/x".into()], ..Default::default() };
        let e = host.check_links(&c, &read_only).unwrap_err().0;
        assert!(e.contains("write"), "{e}");

        let write = Capabilities { fs_write: vec!["${cwd}/x".into()], ..Default::default() };
        host.check_links(&c, &write).expect("granted import links");
    }

    #[test]
    fn pty_and_notify_imports_need_their_capability() {
        let host = PluginHost::new().unwrap();
        let pty = Component::new(
            &host.engine,
            r#"(component (import "haunt:plugin/pty@0.5.0" (instance
                (export "answer" (func (param "surface" string) (param "allow" bool) (param "request-id" u64) (result (result (error string))))))))"#,
        )
        .unwrap();
        assert!(host.check_links(&pty, &Capabilities::default()).is_err());
        host.check_links(&pty, &Capabilities { pty_write: true, ..Default::default() }).unwrap();

        let text = Component::new(
            &host.engine,
            r#"(component (import "haunt:plugin/pty@0.5.0" (instance
                (export "text" (func (param "surface" string) (param "text" string) (result (result (error string))))))))"#,
        )
        .unwrap();
        let e = host.check_links(&text, &Capabilities { pty_write: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("text"), "free-form pty text is gone: {e}");

        let notify = Component::new(
            &host.engine,
            r#"(component (import "haunt:plugin/notify@0.5.0" (instance
                (type $r (record (field "id" string) (field "title" string)))
                (export "action" (type $a (eq $r)))
                (export "notify" (func (param "title" string) (param "body" string) (param "actions" (list $a))
                    (param "binding" (option string)) (result (result (error string))))))))"#,
        )
        .unwrap();
        assert!(host.check_links(&notify, &Capabilities::default()).is_err());
        host.check_links(&notify, &Capabilities { notifications: true, ..Default::default() }).unwrap();
    }

    const DECISIONS_IMPORT: &str = r#"(component (import "haunt:plugin/decisions@0.5.0" (instance
        (type $o (variant (case "allowed-in-haunt") (case "denied-in-haunt") (case "allowed-by-plugin" string)
            (case "denied-by-plugin" string) (case "answered-in-terminal") (case "superseded")))
        (export "outcome" (type $oe (eq $o)))
        (type $d (record (field "at-ms" u64) (field "surface-id" string) (field "tool" string) (field "preview" string)
            (field "cwd" (option string)) (field "outcome" $oe) (field "agent" string)))
        (export "decision" (type $de (eq $d)))
        (export "query" (func (param "text" string) (param "limit" u32) (result (list $de)))))))"#;

    const PROPOSE_IMPORT: &str = r#"(component (import "haunt:plugin/allowlist@0.5.0" (instance
        (export "propose" (func (param "project" string) (param "command" string) (result (result (error string))))))))"#;

    #[test]
    fn decisions_and_allowlist_imports_need_their_capability() {
        let host = PluginHost::new().unwrap();
        let decisions = Component::new(&host.engine, DECISIONS_IMPORT).unwrap();
        let propose = Component::new(&host.engine, PROPOSE_IMPORT).unwrap();
        let all_else = Capabilities {
            notifications: true,
            pty_write: true,
            fs_read: vec!["${cwd}/x".into()],
            fs_write: vec!["${cwd}/x".into()],
            ..Default::default()
        };
        let e = host.check_links(&decisions, &all_else).unwrap_err().0;
        assert!(e.contains("haunt:plugin/decisions"), "{e}");
        let e = host.check_links(&propose, &Capabilities { decisions_read: true, ..all_else.clone() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/allowlist"), "{e}");
        host.check_links(&decisions, &Capabilities { decisions_read: true, ..Default::default() }).unwrap();
        host.check_links(&propose, &Capabilities { allowlist_suggest: true, ..Default::default() }).unwrap();
    }

    #[test]
    fn no_import_writes_decisions_or_settings() {
        let host = PluginHost::new().unwrap();
        let both = Capabilities { decisions_read: true, allowlist_suggest: true, ..Default::default() };
        for (iface, func) in [("decisions", "record"), ("decisions", "write"), ("allowlist", "add-rule"), ("allowlist", "accept"), ("allowlist", "write")] {
            let c = Component::new(
                &host.engine,
                format!(r#"(component (import "haunt:plugin/{iface}@0.5.0" (instance (export "{func}" (func (param "x" string))))))"#),
            )
            .unwrap();
            let e = host.check_links(&c, &both).unwrap_err().0;
            assert!(e.contains(func), "{iface}.{func}: {e}");
        }
    }

    #[test]
    fn the_theme_import_needs_no_capability_and_reads_the_current_theme() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/theme@0.5.0" (instance (export "name" (func (result string))))))"#).unwrap();
        host.check_links(&c, &Capabilities::default()).unwrap();
        let mut st = HostState::new("dev.haunt.t", &Capabilities::default(), None, None, None);
        assert_eq!(wtheme::Host::name(&mut st), "default");
        assert!(wtheme::Host::tokens(&mut st).iter().any(|t| t.name == "color.hairline"));
        let glass = crate::plugin_theme::ThemeToken { name: "color.hairline".into(), value: "#ffffff40".into() };
        st.theme = Arc::new(Theme::new("glass", vec![glass]).unwrap());
        assert_eq!((wtheme::Host::name(&mut st), wtheme::Host::tokens(&mut st).len()), ("glass".to_owned(), 1));
    }

    #[test]
    fn typing_needs_pty_type_and_a_command_the_user_ran() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/typing@0.5.0" (instance
            (export "type-text" (func (param "text" string) (param "enter" bool) (result (result (error string))))))))"#).unwrap();
        let e = host.check_links(&c, &Capabilities { pty_write: true, notifications: true, sidebar: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/typing"), "{e}");
        let caps = Capabilities { pty_type: true, ..Default::default() };
        host.check_links(&c, &caps).unwrap();

        let mut st = HostState::new("dev.haunt.t", &caps, None, None, None);
        assert!(wtyping::Host::type_text(&mut st, "ls".into(), true).unwrap_err().contains("only while"));
        st.typing_into = Some("s1".into());
        assert!(wtyping::Host::type_text(&mut st, "ls\nrm -rf ~".into(), false).unwrap_err().contains("not typed"));
        wtyping::Host::type_text(&mut st, "ls".into(), true).unwrap();
        assert_eq!(st.outbox, [HostRequest::PtyType { plugin_id: "dev.haunt.t".into(), surface: "s1".into(), text: "ls".into(), enter: true }]);
    }

    #[test]
    fn clipboard_needs_its_capability_and_a_user_action_and_never_reads() {
        use wclip::Host as _;
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/clipboard@0.5.0" (instance
            (export "write" (func (param "text" string) (result (result (error string))))))))"#).unwrap();
        let e = host.check_links(&c, &Capabilities { panel: true, keys: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/clipboard"), "{e}");
        let caps = Capabilities { clipboard: Some("write".into()), ..Default::default() };
        host.check_links(&c, &caps).unwrap();
        let read = Component::new(&host.engine, r#"(component (import "haunt:plugin/clipboard@0.5.0" (instance
            (export "read" (func (result string))))))"#).unwrap();
        assert!(host.check_links(&read, &caps).is_err(), "there is no read");

        let mut st = HostState::new("dev.x.relay", &caps, None, None, None);
        assert!(st.write("x".into()).unwrap_err().contains("only once per button"));
        st.copy_ok = true;
        st.write("git push\r\n\u{1b}[2J\u{202e}ok\tthen".into()).unwrap();
        assert!(st.write("again".into()).is_err(), "one write per user action");
        let relay = |text: &str| HostRequest::ClipboardWrite { plugin_id: "dev.x.relay".into(), plugin_name: "dev.x.relay".into(), text: text.into() };
        assert_eq!(st.outbox, [relay("git push\n[2Jok then")], "the request names the plugin for the toast");
        st.copy_ok = true;
        st.write("é".repeat(CLIPBOARD_MAX)).unwrap();
        let Some(HostRequest::ClipboardWrite { text, .. }) = st.outbox.last() else { panic!() };
        assert_eq!(text.len(), CLIPBOARD_MAX);
        st.copy_ok = true;
        st.write("x\n".repeat(1000)).unwrap();
        let Some(HostRequest::ClipboardWrite { text, .. }) = st.outbox.last() else { panic!() };
        assert_eq!(text.lines().count(), CLIPBOARD_LINES);
        assert!(!text.ends_with('\n'), "a 400th line break is cut too");

        st.outbox.clear();
        st.copy_ok = true;
        st.write("Goal: ship\nPlan\n\n\r\n".into()).unwrap();
        assert_eq!(st.outbox, [relay("Goal: ship\nPlan")], "no trailing line break, so a paste can't press Return");
        st.copy_ok = true;
        for hidden in ["\nrm -rf ~", " \u{200b}\nrm -rf ~", "\r\nrm -rf ~", "\n\n"] {
            assert!(st.write(hidden.into()).unwrap_err().contains("first line is empty"), "{hidden:?}");
        }
        st.write("ok".into()).unwrap();
        assert_eq!(st.outbox.len(), 2, "a refused write keeps the click's one copy");
        st.drop_user_effects();
        assert!(st.outbox.is_empty(), "a trapped call's writes are dropped");
    }

    #[test]
    fn fs_list_needs_its_own_grant_and_is_rate_limited() {
        use wfslist::Host as _;
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component
            (type $e (record (field "name" string) (field "size" u64) (field "dir" bool)))
            (import "haunt:plugin/fs-list@0.5.0" (instance
                (export "entry" (type $entry (eq $e)))
                (export "entries" (func (param "dir" string) (result (result (list $entry) (error string))))))))"#).unwrap();
        let e = host.check_links(&c, &Capabilities { fs_read: vec!["${cwd}/*".into()], ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/fs-list"), "fs_read doesn't grant listing: {e}");
        let caps = Capabilities { fs_list: true, ..Default::default() };
        host.check_links(&c, &caps).unwrap();

        let mut st = HostState::new("dev.x.map", &caps, None, None, None);
        for _ in 0..FS_LIST_PER_SEC {
            assert!(st.entries("/".into()).unwrap_err().contains("not inside"), "no project folder seen");
        }
        assert!(st.entries("/".into()).unwrap_err().contains("rate limit"));
        assert!(st.tree("/".into(), crate::plugin_fs::TREE_DEPTH + 1).unwrap_err().contains("depth is at most"));
        assert!(st.tree("/".into(), 2).unwrap_err().contains("once per 10 s"), "a refused walk still spends the call");
        st.last_tree = None;
        assert!(st.tree("/".into(), 2).unwrap_err().contains("no haunt core"), "nothing to report the walk to");
    }

    #[test]
    fn only_https_links_to_listed_domains_open() {
        let d = ["github.com".to_string(), "docs.rs".to_string()];
        for ok in ["https://github.com", "https://github.com/o/r/pull/3?x=1#c", "https://docs.rs/serde"] {
            link_ok(ok, &d).unwrap();
        }
        for bad in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "haunt://open",
            "vscode://file/x",
            "http://github.com/o/r",
            "HTTPS://github.com",
            "https://user:pw@github.com/",
            "https://github.com@evil.com/",
            "https://github.com:8443/",
            "https://evil.com/github.com",
            "https://api.github.com/",
            "https://github.com.evil.com/",
            "https://GitHub.com/",
            "https://github.com/a b",
            "https://github.com\\@evil.com",
            "https://github.com/\u{202e}x",
            "https://github.com/ä",
            " https://github.com",
        ] {
            assert!(link_ok(bad, &d).is_err(), "{bad}");
        }
    }

    #[test]
    fn open_url_needs_its_capability_and_the_clicked_buttons_own_url() {
        use wlink::Host as _;
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/link@0.5.0" (instance
            (export "open-url" (func (param "url" string) (result (result (error string))))))))"#).unwrap();
        assert!(host.check_links(&c, &Capabilities { panel: true, ..Default::default() }).unwrap_err().0.contains("haunt:plugin/link"));
        let caps = Capabilities { panel: true, open_url: vec!["github.com".into()], ..Default::default() };
        host.check_links(&c, &caps).unwrap();

        let mut st = HostState::new("dev.x.links", &caps, None, None, None);
        let pr = "https://github.com/o/r/pull/3";
        assert!(st.open_url(pr.into()).unwrap_err().contains("only once per click"), "no click, no link");
        st.clicked = Some(pr.into());
        assert!(st.open_url("https://github.com/o/r/pull/4".into()).unwrap_err().contains("tooltip"));
        st.clicked = Some("http://github.com/o".into());
        assert!(st.open_url("http://github.com/o".into()).is_err());
        st.clicked = Some(pr.into());
        st.open_url(pr.into()).unwrap();
        assert!(st.open_url(pr.into()).is_err(), "once per click");
        assert_eq!(st.outbox, [HostRequest::OpenUrl { plugin_id: "dev.x.links".into(), url: pr.into() }]);
        st.drop_user_effects();
        assert!(st.outbox.is_empty(), "a trapped call opens nothing");
    }

    #[test]
    fn retitle_cleans_a_title_exactly_as_registering_does() {
        use wpal::Host as _;
        let mut st = HostState::new("dev.x.p", &Capabilities::default(), None, None, None);
        for raw in ["Open\u{202e}gnihtemos", "a\nb\tc\u{200b}d", "\u{1b}[2J Settings…", &"é".repeat(200)] {
            st.command("added".into(), raw.into(), None);
            st.command("renamed".into(), "x".into(), None);
            st.retitle("renamed".into(), raw.into()).unwrap();
            let title = |id: &str| st.palette.iter().find(|p| p.id == id).unwrap().title.clone();
            assert_eq!(title("renamed"), title("added"), "{raw:?}");
        }
        for blank in ["", " ", "\u{200b}\u{202e}", "\n\t"] {
            st.command("blank".into(), blank.into(), None);
            assert!(!st.palette.iter().any(|p| p.id == "blank"), "add refuses {blank:?}");
            assert!(st.retitle("renamed".into(), blank.into()).is_err(), "retitle refuses {blank:?}");
        }
    }

    #[test]
    fn palette_entries_are_removed_and_retitled_by_their_own_plugin() {
        use wpal::Host as _;
        let mut st = HostState::new("dev.x.p", &Capabilities::default(), None, None, None);
        st.command("api".into(), "Start with api".into(), None);
        st.mode("api".into(), "api mode".into());
        st.command("web".into(), "Start with web".into(), None);
        st.retitle("web".into(), "Web".into()).unwrap();
        assert!(st.outbox.is_empty(), "no key, no menu entry to rebuild");
        st.command("keyed".into(), "Keyed".into(), Some("cmd+shift+k".into()));
        st.retitle("keyed".into(), "Keyed 2".into()).unwrap();
        st.remove("keyed".into());
        assert_eq!(st.outbox, [HostRequest::KeysChanged { plugin_id: "dev.x.p".into() }], "one rebuild for both");
        st.retitle("web".into(), "Back to \u{202e}web".into()).unwrap();
        assert!(st.retitle("web".into(), "\u{200b} ".into()).is_err(), "a title needs a visible character");
        assert!(st.retitle("nope".into(), "x".into()).unwrap_err().contains("no palette entry"));
        assert_eq!(st.palette.iter().find(|p| p.id == "web").unwrap().title, "Back to web");
        st.retitle("api".into(), "a".repeat(200)).unwrap();
        assert!(st.palette.iter().filter(|p| p.id == "api").all(|p| p.title.len() == MAX_TITLE));
        st.remove("api".into());
        st.remove("never-there".into());
        assert_eq!(st.palette.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(), ["web"]);
    }

    fn tapped(kind: EventKind, verified: bool, request_key: Option<u64>) -> Tapped {
        let event = crate::event::AgentEvent {
            agent: "claude".into(),
            session_id: Some("s\u{202e}1".into()),
            cwd: Some("/w/a\nb".into()),
            agent_id: None,
            agent_type: None,
            nonce: None,
            truncated: false,
            kind,
        };
        Tapped { surface: "tab-1".into(), event, verified, tab_cwd: "/w".into(), opened_in: "/w".into(), request_key }
    }

    #[test]
    fn events_spell_out_commands_and_paths_and_strip_summaries() {
        let call = crate::event::ToolCall {
            tool_name: "Bash".into(),
            raw_command: Some(format!("ls #\nrm -rf ~/x{}", "y".repeat(2000))),
            command: Some("ls #rm -rf ~/x".into()),
            ..Default::default()
        };
        let all = EventGrant { details: true, answers: true };
        let e = agent_event(&tapped(EventKind::PermissionSeen { tool: call.clone() }, true, Some(7)), all);
        let cmd = e.command.unwrap();
        assert!(cmd.starts_with("ls #⏎rm -rf ~/x"), "{cmd}");
        assert_eq!(cmd.chars().count(), EVENT_TEXT);
        assert_eq!((e.tool.as_deref(), e.surface.as_deref(), e.request_key), (Some("Bash"), Some("tab-1"), Some(7)));
        assert_eq!(e.session_id.as_deref(), Some("s1"));
        assert_eq!(e.cwd.as_deref(), Some("/w/a⏎b"));

        let prompt = agent_event(&tapped(EventKind::PromptSubmit { query: Some("fix\u{2066} it\nnow".into()) }, true, None), all);
        assert_eq!(prompt.summary.as_deref(), Some("fix it now"));

        let steps = (0..300).map(|i| format!("{i}. step\u{200b}")).collect::<Vec<_>>().join("\n");
        let plan = agent_event(&tapped(EventKind::PlanExit { summary: Some(steps) }, true, None), all).summary.unwrap();
        assert!(plan.starts_with("0. step\n1. step\n") && plan.lines().count() == PLAN_LINES, "a plan keeps its lines, up to {PLAN_LINES}");
        let long = agent_event(&tapped(EventKind::PlanExit { summary: Some(format!("{}\nend", "x".repeat(2000))) }, true, None), all).summary.unwrap();
        assert_eq!(long.split('\n').map(|l| l.chars().count()).collect::<Vec<_>>(), [EVENT_TEXT, 3]);

        let edit = agent_event(&tapped(EventKind::FileEdited { tool_name: Some("Edit".into()), file_path: Some("/a\u{200b}b".into()) }, true, None), all);
        assert_eq!(edit.file_path.as_deref(), Some("/a\\u{200b}b"));
        let task = agent_event(&tapped(EventKind::TaskUpdated { task_id: "t9".into(), status: "completed".into() }, true, None), all);
        assert_eq!((task.task_id.as_deref(), task.summary.as_deref()), (Some("t9"), Some("completed")));

        let none = EventGrant::default();
        let e = agent_event(&tapped(EventKind::PermissionSeen { tool: call }, true, Some(7)), none);
        assert_eq!((e.command, e.file_path, e.request_key, e.tool.as_deref()), (None, None, None, Some("Bash")), "no details, no key");
        let prompt = agent_event(&tapped(EventKind::PromptSubmit { query: Some("my token is x".into()) }, true, None), none);
        let plan = agent_event(&tapped(EventKind::PlanExit { summary: Some("plan".into()) }, true, None), none);
        let edit = agent_event(&tapped(EventKind::FileEdited { tool_name: Some("Edit".into()), file_path: Some("/p/.env".into()) }, true, None), none);
        assert_eq!((prompt.summary, plan.summary, edit.file_path), (None, None, None));
    }

    #[test]
    fn an_unverified_event_carries_no_request_key() {
        let call = crate::event::ToolCall { tool_name: "Bash".into(), command: Some("ls".into()), ..Default::default() };
        let all = EventGrant { details: true, answers: true };
        assert_eq!(agent_event(&tapped(EventKind::PermissionSeen { tool: call }, false, Some(7)), all).request_key, None);
    }

    #[test]
    fn registered_ids_and_titles_hide_nothing() {
        let mut st = HostState::new("dev.haunt.t", &Capabilities::default(), None, None, None);
        wpal::Host::command(&mut st, "dep\u{202e}loy".into(), "Deploy".into(), None);
        wpal::Host::command(&mut st, "".into(), "Empty".into(), None);
        wpal::Host::command(&mut st, "blank".into(), "\u{200b}\u{2028}".into(), None);
        assert!(st.palette.is_empty(), "{:?}", st.palette);
        assert_eq!(st.logs.len(), 3);
        wpal::Host::command(&mut st, "ok".into(), format!("Git\u{200b} st\u{202e}atus {}", "é".repeat(100)), None);
        let t = &st.palette[0].title;
        assert!(t.starts_with("Git status ") && !t.chars().any(is_hidden), "{t:?}");
        assert_eq!(t.chars().count(), MAX_TITLE);
    }

    #[test]
    fn the_sidebar_import_needs_its_capability() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/sidebar@0.5.0" (instance (export "clear" (func)))))"#).unwrap();
        let everything_else = Capabilities { decisions_read: true, allowlist_suggest: true, notifications: true, pty_write: true, ..Default::default() };
        let e = host.check_links(&c, &everything_else).unwrap_err().0;
        assert!(e.contains("haunt:plugin/sidebar"), "{e}");
        host.check_links(&c, &Capabilities { sidebar: true, ..Default::default() }).unwrap();
    }

    #[test]
    fn a_plugin_arrangement_keeps_needs_you_first() {
        use wside::Host as _;
        let core = crate::Core::new(&*tempdir("arrange-core"));
        let a = core.register_surface("/a").unwrap();
        let b = core.register_surface("/b").unwrap();
        let line = |env: &crate::SurfaceEnv, body: &str| {
            format!(r#"{{"v":1,"surface_id":"{}","nonce":"{}",{body}}}"#, env.surface_id, env.nonce)
        };
        core.with_state(|st| {
            st.handle_line(&line(&a, r#""event":"prompt_submit","query":"x""#), Instant::now());
            st.handle_line(&line(&b, r#""event":"permission_seen","tool_name":"Bash","tool_input":{"command":"ls"}"#), Instant::now());
        });
        let sidebar = Capabilities { sidebar: true, ..Default::default() };
        let mut st = HostState::new("dev.haunt.tabs-plus", &sidebar, None, None, Some(core.handle()));
        let rows = st.rows();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().any(|r| r.surface == b.surface_id && r.group == wside::StateGroup::NeedsYou));
        let arrangement = wside::Arrangement {
            pinned: vec![b.surface_id.clone(), a.surface_id.clone()],
            sections: vec![],
            placement: wside::Placement::BeforeState,
            order: vec![],
            flat: false,
            colors: vec![(a.surface_id.clone(), wside::TabColor::Blue)],
            color_style: wside::ColorStyle::Tint,
        };
        st.arrange(arrangement.clone()).unwrap();
        let snap = core.snapshot();
        let ids: Vec<_> = snap.groups.iter().map(|g| (g.id.as_str(), g.rows.iter().map(|r| r.surface_id.clone()).collect::<Vec<_>>())).collect();
        assert_eq!(ids, [("needs-you", vec![b.surface_id.clone()]), ("pinned", vec![a.surface_id.clone()])]);
        assert_eq!((snap.groups[1].rows[0].color, snap.color_style), (Some(TabColor::Blue), ColorStyle::Tint));

        let mut other = HostState::new("dev.x.other", &sidebar, None, None, Some(core.handle()));
        assert!(other.arrange(arrangement.clone()).unwrap_err().contains("dev.haunt.tabs-plus"), "one arranger at a time");
        other.clear();
        assert_eq!(core.snapshot().groups[1].id, "pinned", "only the owner clears");
        let mut no_cap = HostState::new("dev.x.nocap", &Capabilities::default(), None, None, Some(core.handle()));
        assert!(no_cap.arrange(arrangement.clone()).unwrap_err().contains("sidebar capability"));
        st.clear();
        assert_eq!(core.snapshot().groups[1].id, "running");
        st.arrange(arrangement.clone()).unwrap();

        // A reload: the new instance takes over, and dropping the old one leaves the new arrangement.
        let mut reloaded = HostState::new("dev.haunt.tabs-plus", &sidebar, None, None, Some(core.handle()));
        reloaded.arrange(wside::Arrangement { flat: true, ..arrangement.clone() }).unwrap();
        drop(st);
        assert_eq!(core.snapshot().groups[1].id, "pinned", "the reloaded instance's arrangement stays");
        reloaded.release_sidebar();
        assert_eq!(core.snapshot().groups[1].id, "running", "a disabled instance's arrangement goes with it");
        assert!(reloaded.arrange(arrangement.clone()).is_err(), "and it can't arrange again");

        let mut dropped = HostState::new("dev.haunt.tabs-plus", &sidebar, None, None, Some(core.handle()));
        dropped.arrange(arrangement).unwrap();
        drop(dropped);
        assert_eq!(core.snapshot().groups[1].id, "running", "a removed or reloaded plugin's arrangement goes");
    }

    fn deco(label: &str) -> wrows::Decoration {
        wrows::Decoration {
            label: Some(label.into()),
            label_tone: wrows::Tone::Warn,
            suffix: None,
            suffix_tone: wrows::Tone::Dim,
            scroll: false,
            bar: None,
            spark: None,
        }
    }

    #[test]
    fn the_rows_import_needs_decorate() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/rows@0.5.0" (instance (export "clear-all" (func)))))"#).unwrap();
        let e = host.check_links(&c, &Capabilities { sidebar: true, notifications: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/rows"), "{e}");
        host.check_links(&c, &Capabilities { decorate: true, ..Default::default() }).unwrap();
    }

    #[test]
    fn a_decoration_never_covers_a_row_that_needs_you() {
        use wrows::Host as _;
        let core = crate::Core::new(&*tempdir("rows-needs"));
        let a = core.register_surface("/a").unwrap();
        let mut st = HostState::new("dev.x.p", &Capabilities { decorate: true, ..Default::default() }, None, None, Some(core.handle()));
        let mut other = HostState::new("dev.x.q", &Capabilities { decorate: true, ..Default::default() }, None, None, Some(core.handle()));
        other.decorate(a.surface_id.clone(), Some(deco("QA ok"))).unwrap();
        let spark = wrows::Spark { points: vec![1, 2], tone: wrows::Tone::Warn };
        st.decorate(a.surface_id.clone(), Some(wrows::Decoration { suffix: Some("CI 9/9".into()), bar: Some(0.5), spark: Some(spark), ..deco("CI 9/9") })).unwrap();
        let row = |core: &crate::Core| core.snapshot().groups.iter().flat_map(|g| g.rows.clone()).find(|r| r.surface_id == a.surface_id).unwrap();
        assert_eq!(row(&core).decoration.unwrap().label.as_deref(), Some("CI 9/9"));
        let line = format!(r#"{{"v":1,"surface_id":"{}","nonce":"{}","event":"permission_seen","tool_name":"Bash","tool_input":{{"command":"git push"}}}}"#, a.surface_id, a.nonce);
        core.with_state(|s| s.handle_line(&line, Instant::now()));
        let r = row(&core);
        assert!(r.needs_you && r.pending.is_some());
        assert!(r.other_labels.is_empty(), "nor in its tooltip");
        let d = r.decoration.unwrap();
        assert_eq!((d.label, d.spark, d.suffix), (None, None, None), "Haunt's status owns the row");
        assert_eq!(d.bar_permille, Some(500), "the bar may stay");
    }

    #[test]
    fn a_scrolling_suffix_may_be_a_longer_ticker() {
        let long = || Some("x".repeat(300));
        let still = decoration(wrows::Decoration { suffix: long(), ..deco("a") }).unwrap();
        let ticker = decoration(wrows::Decoration { suffix: long(), scroll: true, ..deco("a") }).unwrap();
        assert_eq!((still.suffix.unwrap().len(), ticker.suffix.unwrap().len()), (decorate::SUFFIX_MAX, decorate::TICKER_MAX));
    }

    #[test]
    fn plugins_hold_side_by_side_and_each_releases_only_its_own() {
        use whold::Host as _;
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/hold@0.5.0" (instance (export "release" (func)))))"#).unwrap();
        assert!(host.check_links(&c, &Capabilities { notifications: true, ..Default::default() }).unwrap_err().0.contains("haunt:plugin/hold"));
        host.check_links(&c, &Capabilities { notify_hold: true, ..Default::default() }).unwrap();

        let core = crate::Core::new(&*tempdir("hold"));
        let caps = Capabilities { notify_hold: true, ..Default::default() };
        let mut focus = HostState::new("dev.x.focus", &caps, None, None, Some(core.handle()));
        let mut other = HostState::new("dev.x.other", &caps, None, None, Some(core.handle()));
        let act = |id: &str, label: &str| whold::SummaryAction { id: id.into(), label: label.into(), surface: None };
        assert!(focus.start(0).is_err() && focus.start(HOLD_MAX_MINUTES + 1).is_err());
        assert!(focus.set_summary(None, vec![]).unwrap_err().contains("no hold"));
        focus.start(25).unwrap();
        other.start(5).unwrap();

        assert!(focus.set_summary(None, vec![act("a", "A"), act("b", "B"), act("c", "C")]).is_err());
        assert!(focus.set_summary(None, vec![act("ok", "Allow")]).unwrap_err().contains("status"));
        assert!(focus.set_summary(None, vec![act("", "Again")]).is_err());
        focus.set_summary(Some("Focus\nblock over, a long headline that keeps going well past the cap".into()), vec![act("again", "Start another 25 minutes please")]).unwrap();
        let Some(HostRequest::HoldSummary { plugin_id, headline: Some(h), actions }) = focus.outbox.last() else { panic!() };
        assert_eq!((plugin_id.as_str(), h.chars().count(), actions[0].title.chars().count()), ("dev.x.focus", HOLD_HEADLINE_MAX, HOLD_LABEL_MAX));
        assert!(h.starts_with("Focus block over") && focus.hold_actions == [("again".to_string(), None)]);

        other.release();
        assert!(matches!(other.outbox.last(), Some(HostRequest::ReleaseNotifications { plugin_id }) if plugin_id == "dev.x.other"));
        assert!(core.handle().holds_notifications("dev.x.focus") && !core.handle().holds_notifications("dev.x.other"), "a release ends only its own hold");
        focus.start(10).unwrap();
        assert!(focus.hold_actions.is_empty(), "a new start clears the summary");
        drop(focus);
        assert!(!core.handle().holds_notifications("dev.x.focus"), "a dropped plugin lets go");
    }

    #[test]
    fn sidebar_focus_needs_the_capability_a_user_action_and_an_open_tab() {
        use wside::Host as _;
        let core = crate::Core::new(&*tempdir("focus"));
        let tab = core.register_surface("/a").unwrap().surface_id;
        let mut bare = HostState::new("dev.x.bare", &Capabilities::default(), None, None, Some(core.handle()));
        bare.arm(true, None);
        assert!(bare.focus(tab.clone()).unwrap_err().contains("sidebar capability"));

        let caps = Capabilities { sidebar: true, ..Default::default() };
        let mut st = HostState::new("dev.x.next", &caps, None, None, Some(core.handle()));
        assert!(st.focus(tab.clone()).unwrap_err().contains("once per"), "no user action");
        st.arm(false, None);
        assert!(st.focus(tab.clone()).is_err(), "a key's release arms nothing");
        st.arm(true, None);
        assert!(st.focus("no-such-tab".into()).unwrap_err().contains("no open tab"));
        assert!(st.focus(tab.clone()).is_err(), "a refused try spends the use");
        st.arm(true, None);
        st.focus(tab.clone()).unwrap();
        assert!(st.focus(tab.clone()).is_err(), "once per use");
        assert_eq!(st.outbox, [HostRequest::FocusTab { plugin_id: "dev.x.next".into(), surface: tab }]);
    }

    #[test]
    fn a_hold_summary_action_may_bring_an_open_tab_forward() {
        use whold::Host as _;
        let core = crate::Core::new(&*tempdir("hold-tab"));
        let tab = core.register_surface("/a").unwrap().surface_id;
        let caps = Capabilities { notify_hold: true, ..Default::default() };
        let mut focus = HostState::new("dev.x.focus", &caps, None, None, Some(core.handle()));
        let act = |id: &str, surface: Option<&str>| whold::SummaryAction { id: id.into(), label: "Go through them".into(), surface: surface.map(Into::into) };
        focus.start(25).unwrap();
        let e = focus.set_summary(None, vec![act("go", Some("no-such-tab"))]).unwrap_err();
        assert!(e.contains("no open tab"), "{e}");
        assert!(focus.hold_actions.is_empty(), "a refused summary keeps none of its actions");
        focus.set_summary(Some("Focus block over".into()), vec![act("go", Some(&tab)), act("again", None)]).unwrap();
        let Some(HostRequest::HoldSummary { actions, .. }) = focus.outbox.last() else { panic!() };
        assert_eq!(actions.iter().map(|a| a.title.as_str()).collect::<Vec<_>>(), ["Go through them", "Go through them"], "the tab id never shows");

        assert_eq!(focus.hold_surface("go").as_deref(), Some(tab.as_str()));
        assert_eq!(focus.hold_surface("again"), None, "an action without a tab brings none forward");
        assert_eq!(focus.hold_surface("other"), None, "only this summary's actions");
        focus.notify_click("go", HOLD_BINDING).unwrap();
        assert!(focus.typing_into.is_none(), "choosing it types nothing");
        focus.disarm();

        core.unregister_surface(&tab);
        assert_eq!(focus.hold_surface("go"), None, "a tab closed since the summary is not brought forward");
        assert!(focus.notify_click("go", HOLD_BINDING).is_ok(), "the action still reaches the plugin");
    }

    #[test]
    fn the_top_row_is_plain_capped_and_owned_by_one_plugin() {
        use wtop::Host as _;
        let core = crate::Core::new(&*tempdir("top"));
        let caps = Capabilities { sidebar_top: true, ..Default::default() };
        let top = |title: &str, action: Option<&str>| wtop::Top {
            title: title.into(),
            sub: Some(format!("3 held\u{202e} · {}", "x".repeat(40))),
            right: Some("17:42 left".into()),
            tone: wrows::Tone::Dim,
            bar: Some(0.29),
            action: action.map(Into::into),
        };
        let mut focus = HostState::new("dev.haunt.focus-block", &caps, None, None, Some(core.handle()));
        let mut other = HostState::new("dev.x.other", &caps, None, None, Some(core.handle()));
        assert!(focus.set(Some(top("\u{200b} ", None))).is_err(), "a title is needed");
        assert!(focus.set(Some(wtop::Top { bar: Some(f32::NAN), ..top("focus", None) })).is_err());
        focus.set(Some(top("focus", Some("open")))).unwrap();
        let t = core.snapshot().top.unwrap();
        assert_eq!((t.plugin_id.as_str(), t.title.as_str(), t.bar_permille, t.clickable), ("dev.haunt.focus-block", "focus", Some(290), true));
        assert_eq!(t.sub.unwrap().chars().count(), decorate::TOP_SUB_MAX);
        assert!(other.set(Some(top("mine", None))).unwrap_err().contains("dev.haunt.focus-block"));
        other.set(None).unwrap();
        assert!(core.snapshot().top.is_some(), "only the owner clears it");
        assert_eq!(focus.top_action.as_deref(), Some("open"));
        drop(focus);
        assert!(core.snapshot().top.is_none(), "a dropped plugin's row goes");
        other.set(Some(top("mine", None))).unwrap();
        assert!(!core.snapshot().top.unwrap().clickable && other.top_action.is_none());
    }

    #[test]
    fn terminal_read_is_linked_alone_and_reads_only_during_a_users_action() {
        use wterm::Host as _;
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/terminal@0.5.0" (instance (export "read" (func (param "surface" string) (param "lines" u32) (result (result (list string) (error string))))))))"#).unwrap();
        assert!(host.check_links(&c, &Capabilities { pty_type: true, ..Default::default() }).is_err());
        host.check_links(&c, &Capabilities { terminal_read: true, ..Default::default() }).unwrap();

        let dir = tempdir("read");
        let core = crate::Core::new(&*dir);
        let tab = core.register_surface(dir.to_str().unwrap()).unwrap().surface_id;
        let mut st = HostState::new("dev.x.read", &Capabilities { terminal_read: true, ..Default::default() }, None, None, Some(core.handle()));
        assert!(st.read(tab.clone(), 5).unwrap_err().contains("only while"));
        st.reads_left = READS_PER_ACTION;
        assert!(st.read(tab.clone(), 5).unwrap_err().contains("can't read"), "no reader in this app");
        core.handle().set_screen_reader(Some(Arc::new(|_, _| Some(vec!["one".into(), "two\u{1b}[2J".into(), "three".into()]))));
        assert!(st.read(tab.clone(), 0).is_err() && st.read(tab.clone(), READ_LINES_MAX + 1).is_err());
        assert!(st.read("nope".into(), 5).unwrap_err().contains("no tab"));
        assert_eq!(st.read(tab.clone(), 2).unwrap(), ["two\\u{1b}[2J", "three"], "the last lines, hidden characters spelled out");
        while st.reads_left > 0 {
            st.read(tab.clone(), 1).unwrap();
        }
        assert!(st.read(tab.clone(), 1).is_err(), "a few reads per action");
        let other = core.register_surface(dir.to_str().unwrap()).unwrap().surface_id;
        (st.reads_left, st.read_only) = (READS_PER_ACTION, Some(tab.clone()));
        assert_eq!(st.read(tab, 1).unwrap(), ["three"], "a hover-hold reads the hovered tab");
        assert!(st.read(other, 1).unwrap_err().contains("only the hovered"));
    }

    #[test]
    fn a_read_is_audited_however_much_the_plugin_logs() {
        use wterm::Host as _;
        let dir = tempdir("audit");
        let core = crate::Core::new(&*dir);
        let tab = core.register_surface(dir.to_str().unwrap()).unwrap().surface_id;
        core.handle().set_screen_reader(Some(Arc::new(|_, _| Some(vec!["one".into(), "two".into()]))));
        let mut st = HostState::new("dev.x.read", &Capabilities { terminal_read: true, ..Default::default() }, None, None, Some(core.handle()));
        for i in 0..1000 {
            wlog::Host::log(&mut st, wit::LogLevel::Info, format!("filler {i}"));
        }
        st.reads_left = READS_PER_ACTION;
        st.read(tab.clone(), 2).unwrap();
        let audit = st.take_audit();
        assert!(matches!(&audit[..], [l] if l.kind == "terminal.read" && l.surface == tab && l.n == 2 && l.plugin == "dev.x.read"), "{audit:?}");
        assert!(st.take_audit().is_empty(), "drained");
        assert!(!st.logs.iter().any(|l| l.contains("terminal.read")), "not in the plugin's own log");
        for _ in 0..MAX_AUDIT + 5 {
            st.audit("exec", &tab, "git-status", 1);
        }
        let audit = st.take_audit();
        assert_eq!(audit.len(), MAX_AUDIT + 1);
        assert!(matches!(audit.last(), Some(l) if l.kind == "audit.dropped" && l.n == 5), "an overflow is counted");
    }

    #[test]
    fn the_user_action_effects_and_listings_are_audited_without_their_content() {
        use {wclip::Host as _, wfslist::Host as _, wlink::Host as _, wside::Host as _};
        let home = tempdir("audit-fx-home");
        std::fs::create_dir_all(home.join("code/p/.git")).unwrap();
        std::fs::create_dir_all(home.join("code/p/src")).unwrap();
        std::fs::write(home.join("code/p/src/a.rs"), "fn a() {}").unwrap();
        let core = crate::Core::new(&*tempdir("audit-fx-core"));
        let tab = core.register_surface(home.to_str().unwrap()).unwrap().surface_id;
        let caps = Capabilities {
            clipboard: Some("write".into()), open_url: vec!["github.com".into()], sidebar: true, fs_list: true, ..Default::default()
        };
        let mut st = HostState::new("dev.x.fx", &caps, None, None, Some(core.handle()));
        st.fs.set_home(&home);
        assert!(st.fs.add_cwd(home.join("code/p").to_str().unwrap()));
        let pr = "https://github.com/o/r/pull/1?token=secret";
        st.arm(true, Some(pr));
        st.write("Goal: the secret plan\nstep two".into()).unwrap();
        st.open_url(pr.into()).unwrap();
        st.focus(tab.clone()).unwrap();
        st.entries(home.join("code/p/src").to_str().unwrap().into()).unwrap();
        let got: Vec<(String, String, String, u64)> = st.take_audit().into_iter().map(|l| (l.kind, l.surface, l.detail, l.n)).collect();
        assert_eq!(got, [
            ("clipboard.write".into(), String::new(), "2 lines".into(), 30),
            ("link.open-url".into(), String::new(), "github.com".into(), 1),
            ("sidebar.focus".into(), tab, String::new(), 1),
            ("fs-list.entries".into(), String::new(), "src".into(), 1),
        ]);
        assert!(st.write("again".into()).is_err());
        assert!(st.take_audit().is_empty(), "a refused effect is not audited");
    }

    #[test]
    fn repeated_reads_and_listings_in_one_call_fold_into_one_line() {
        let mut st = HostState::new("dev.x.fs", &Capabilities::default(), None, None, None);
        for i in 0..500 {
            st.audit("fs.read", "", &format!("src/{i}.rs"), 10);
        }
        st.audit("fs.list", "", "src", 3);
        st.audit("fs.write", "", "src/a.rs", 1);
        st.audit("fs.write", "", "src/b.rs", 1);
        st.audit("fs.list", "", "docs", 2);
        let got: Vec<(String, String, u64, u64)> = st.take_audit().into_iter().map(|l| (l.kind, l.detail, l.n, l.count)).collect();
        assert_eq!(got, [
            ("fs.read".into(), "src/0.rs".into(), 5000, 500),
            ("fs.list".into(), "src".into(), 5, 2),
            ("fs.write".into(), "src/a.rs".into(), 1, 1),
            ("fs.write".into(), "src/b.rs".into(), 1, 1),
        ]);
        st.audit("fs.read", "", "src/next.rs", 4);
        assert!(matches!(&st.take_audit()[..], [l] if l.detail == "src/next.rs" && l.count == 1), "the next call starts afresh");
    }

    #[test]
    fn audit_lines_name_what_was_touched_and_cut_long_strings() {
        use wpty::Host as _;
        let home = tempdir("audit-home");
        std::fs::create_dir_all(home.join("code/p/.git")).unwrap();
        std::fs::create_dir_all(home.join("code/p/src")).unwrap();
        std::fs::write(home.join("code/p/src/a.rs"), "fn a() {}").unwrap();
        let caps = Capabilities { fs_read: vec!["${cwd}/src/*".into()], fs_write: vec!["${cwd}/src/*".into()], pty_write: true, ..Default::default() };
        let core = crate::Core::new(&*tempdir("audit-core"));
        let mut st = HostState::new("dev.x.fs", &caps, None, None, Some(core.handle()));
        st.fs.set_home(&home);
        assert!(st.fs.add_cwd(home.join("code/p").to_str().unwrap()));
        let src = home.join("code/p/src");
        assert_eq!(st.fs_read(src.join("a.rs").to_str().unwrap()).unwrap().len(), 9);
        st.fs_list(src.to_str().unwrap()).unwrap();
        st.fs_write(src.join("b.rs").to_str().unwrap(), b"x").unwrap();
        assert!(st.fs_read(home.join("code/p/README").to_str().unwrap()).is_err());
        let got: Vec<(String, String, u64)> = st.take_audit().into_iter().map(|l| (l.kind, l.detail, l.n)).collect();
        assert_eq!(got, [("fs.read".into(), "src/a.rs".into(), 9), ("fs.list".into(), "src".into(), 1), ("fs.write".into(), "src/b.rs".into(), 1)]);

        st.answer("no-such-tab".into(), true, 3).unwrap();
        assert!(st.take_audit().is_empty(), "only a real tab's answer is audited");
        let tab = core.register_surface(home.to_str().unwrap()).unwrap().surface_id;
        st.answer(tab.clone(), true, 4).unwrap();
        assert!(matches!(&st.take_audit()[..], [l] if l.kind == "pty.answer" && l.surface == tab && l.n == 4));

        st.audit("decisions.query", "", &"é".repeat(100), 2);
        let l = &st.take_audit()[0];
        assert_eq!((l.detail.chars().count(), &l.clipped[..]), (AUDIT_STR_MAX, &[AuditClip { field: "detail".into(), len: 100 }][..]));
    }

    #[test]
    fn a_tabs_fs_grant_is_the_repo_it_was_opened_in_whatever_osc7_says() {
        let home = tempdir("osc7-home");
        for d in ["code/p/.git", "code/p/src", "code/q/.git", ".ssh/.git", "notes"] {
            std::fs::create_dir_all(home.join(d)).unwrap();
        }
        for f in ["code/p/a.txt", "code/q/secret.txt"] {
            std::fs::write(home.join(f), "x").unwrap();
        }
        let core = crate::Core::new(&*tempdir("osc7"));
        let st = |opened: &str, shell_cwd: &str| {
            let tab = core.register_surface(home.join(opened).to_str().unwrap()).unwrap().surface_id;
            core.set_surface_info(&tab, "", home.join(shell_cwd).to_str().unwrap(), None);
            let (tab_cwd, opened_in) = core.handle().tab_folders(&tab).unwrap();
            let mut st = HostState::new("dev.x.fs", &Capabilities { fs_read: vec!["${cwd}/*".into()], ..Default::default() }, None, None, None);
            st.fs.set_home(&home);
            st.grant_tab_folder(&Tapped { surface: tab, tab_cwd, opened_in, ..tapped(EventKind::Stop, true, None) });
            st
        };
        let p = home.join("code/p").canonicalize().unwrap();
        assert_eq!(st("code/p", "code/p/src").fs.cwds(), std::slice::from_ref(&p), "cd within the repo keeps its root");
        let steered = st("code/p", "code/q");
        assert_eq!(steered.fs.cwds(), std::slice::from_ref(&p), "an OSC 7 into a sibling repo adds no root");
        assert!(steered.fs.read(home.join("code/q/secret.txt").to_str().unwrap()).is_err(), "and gets no access to it");
        assert!(steered.fs.read(home.join("code/p/a.txt").to_str().unwrap()).is_ok());
        assert!(st("", "code/p").fs.cwds().is_empty(), "a tab opened at ~ gets no root from cd-ing into a repo");
        assert!(st(".ssh", ".ssh").fs.cwds().is_empty(), "~/.ssh is never a root, even with a .git there");
        assert!(st("notes", "notes").fs.cwds().is_empty(), "not a git repository");
    }

    #[test]
    fn exec_runs_in_the_repo_the_tab_was_opened_in_not_one_nested_where_its_shell_is() {
        use wexec::Host as _;
        if !std::path::Path::new("/usr/bin/git").exists() && !std::path::Path::new("/usr/local/bin/git").exists() {
            return;
        }
        let home = TempDir::created("host-exec-nested");
        let (p, n) = (home.join("code/p"), home.join("code/p/vendor/n"));
        let marker = home.join("ran");
        let evil = home.join("evil.sh");
        std::fs::write(&evil, format!("#!/bin/sh\ntouch {}\ncat\n", marker.display())).unwrap();
        std::fs::set_permissions(&evil, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        let git = |dir: &std::path::Path, a: &[&str]| {
            let o = std::process::Command::new("git").args(a).current_dir(dir).env("GIT_CONFIG_GLOBAL", "/dev/null").env("GIT_CONFIG_NOSYSTEM", "1").output().unwrap();
            assert!(o.status.success(), "{a:?}");
            String::from_utf8(o.stdout).unwrap()
        };
        for (dir, msg) in [(&p, "root"), (&n, "nested")] {
            std::fs::create_dir_all(dir).unwrap();
            git(dir, &["init", "-q", "-b", msg]);
            std::fs::write(dir.join("f"), msg).unwrap();
            git(dir, &["add", "f"]);
            git(dir, &["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", msg]);
        }
        let e = evil.display().to_string();
        for (k, v) in [("core.fsmonitor", e.as_str()), ("core.pager", &e), ("core.hooksPath", "."), ("filter.x.clean", &e)] {
            git(&n, &["config", k, v]);
        }
        let root_head = git(&p, &["rev-parse", "HEAD"]);

        let core = crate::Core::new(&*tempdir("exec-nested-core"));
        let (tx, rx) = std::sync::mpsc::channel();
        let tx = std::sync::Mutex::new(tx);
        core.handle().set_exec_sink(Some(Arc::new(move |d: crate::plugin_exec::ExecDone| tx.lock().unwrap().send(d).unwrap())));
        let tab = core.register_surface(p.to_str().unwrap()).unwrap().surface_id;
        core.set_surface_info(&tab, "", n.to_str().unwrap(), None);
        let caps = Capabilities { exec: vec!["git-head".into(), "git-status".into()], ..Default::default() };
        let mut st = HostState::new("dev.x.ci", &caps, None, None, Some(core.handle()));
        st.fs.set_home(&home);
        let mut run = |c| {
            st.run(tab.clone(), c).unwrap();
            st.exec_jobs.clear();
            let crate::plugin_exec::JobOutcome::Exec(o) = rx.recv_timeout(Duration::from_secs(10)).unwrap().outcome else { panic!("not an exec job") };
            o.unwrap()
        };
        assert_eq!(run(wexec::Command::GitHead).stdout, root_head, "the root repo's HEAD, not the nested one's");
        let status = run(wexec::Command::GitStatus);
        assert!(status.stdout.contains("# branch.head root"), "{status:?}");
        assert!(!marker.exists(), "the nested repo's config ran a program");
    }

    #[test]
    fn exec_runs_only_granted_commands_in_a_tabs_project_folder() {
        use wexec::Host as _;
        let core = crate::Core::new(&*tempdir("exec"));
        let caps = Capabilities { exec: vec!["git-status".into()], ..Default::default() };
        let mut p = HostState::new("dev.x.ci", &caps, None, None, Some(core.handle()));
        let tab = core.register_surface("/tmp").unwrap().surface_id;
        assert!(p.run(tab.clone(), wexec::Command::GitHead).unwrap_err().contains("not in this plugin's exec list"));
        assert_eq!(p.run("nope".into(), wexec::Command::GitStatus).unwrap_err(), "no such tab");
        assert!(p.run(tab, wexec::Command::GitStatus).unwrap_err().contains("opened in a git repository inside your home"), "/tmp is outside home");
        p.exec_jobs = vec![1, 2];
        assert!(p.run("nope".into(), wexec::Command::GitStatus).unwrap_err().contains("at most 2"));
    }

    #[test]
    fn a_tree_walk_reports_later_and_never_holds_up_a_user_action() {
        use crate::plugin_exec::{ExecDone, JobOutcome};
        use std::sync::{Mutex, mpsc};
        use wfslist::Host as _;
        let dir = tempdir("tree-job");
        let home = dir.join("home");
        std::fs::create_dir_all(home.join("proj/.git")).unwrap();
        std::fs::create_dir_all(home.join("proj/src")).unwrap();
        std::fs::write(home.join("proj/src/a.rs"), "abc").unwrap();
        let core = crate::Core::new(&*dir.join("haunt"));
        let tab = core.register_surface("/a").unwrap().surface_id;
        // The walk's report waits until the test lets it through, as a slow filesystem would; a tree() that
        // waited for it would pass the timeout and report early, failing below rather than hanging.
        let (go, gate) = mpsc::channel::<()>();
        let (done_tx, done) = mpsc::channel::<ExecDone>();
        let gate = Mutex::new(gate);
        core.handle().set_exec_sink(Some(Arc::new(move |d| {
            let _ = gate.lock().unwrap().recv_timeout(Duration::from_secs(5));
            let _ = done_tx.send(d);
        })));
        let mut p = arming_plugin(&core);
        let st = p.store.data_mut();
        st.fs.set_home(&home);
        assert!(st.fs.add_cwd(home.join("proj").to_str().unwrap()));
        let started = Instant::now();
        let job = st.tree(home.join("proj").to_str().unwrap().into(), 2).unwrap();
        assert!(started.elapsed() < Duration::from_secs(2), "tree() returns before the walk reports");

        p.run_command("https://github.com/o/r/pull/1", true).unwrap();
        assert_eq!(effects(&mut p).2, [tab], "a command runs while the walk is out");
        assert!(done.try_recv().is_err(), "and the walk hasn't reported yet");

        go.send(()).unwrap();
        let d = done.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!((d.plugin_id.as_str(), d.job), ("dev.x.arming", job));
        let JobOutcome::Tree(Ok(t)) = &d.outcome else { panic!("{:?}", d.outcome) };
        assert_eq!(t.folders.iter().find(|f| f.path == "src").map(|f| (f.files, f.bytes)), Some((1, 3)));
        p.exec_done(d.job, d.outcome.clone()).unwrap();
        assert!(p.store.data().tree_jobs.is_empty(), "on-fs-tree heard it");
        let walks: Vec<_> = p.store.data_mut().take_audit().into_iter().filter(|l| l.kind == "fs-list.tree").map(|l| (l.detail, l.n)).collect();
        assert_eq!(walks, [(String::new(), 1)], "the walk is audited as it reports: the project root and the files it counted");
        p.exec_done(d.job, JobOutcome::Exec(Err("x".into()))).unwrap();
        assert!(p.store.data().exec_jobs.is_empty(), "a tree job's id is no exec job");
    }

    #[test]
    fn theme_words_go_through_the_label_check() {
        for t in ["\u{13A0}one", "done\u{2800}", "needs  you", "\u{410}llow", "Approve", "RUNNING", "ALL IDLE", "a\u{300}llow"] {
            assert!(says_status(t), "{t:?}");
        }
        for t in ["Permission", "REQUEST", "Re\u{2800}quest", "p\u{435}rmission needed", "You approved", "You denied",
                  "Allowed in terminal:", "Approved", "Denied", "Permissions", "Requests", "\u{410}pproved", "allows", "allowing",
                  "denies", "denying", "approves", "approving", "permits", "permitted", "requesting", "requested", "Re quested"] {
            assert!(theme_says_status(t) && !says_status(t), "{t:?}");
        }
        for t in ["Invoke", "\u{21B5} SUMMON \u{B7} ESC BANISH", "XII \u{B7} XI \u{B7} MMXXVI", "AGENTS III", "Go To", "Open:",
                  "Type the name of a tab, a command or a theme.", "\u{21B5} OPEN \u{B7} ESC BACK", "\u{2514} ", "- "] {
            assert!(!theme_says_status(t), "{t:?}");
        }
    }

    #[test]
    fn row_labels_cant_pass_for_haunts_status() {
        let d = |label: &str, t: wrows::Tone| wrows::Decoration {
            label: Some(label.into()), label_tone: t, suffix: None, suffix_tone: wrows::Tone::Dim, scroll: false, bar: None,
            spark: Some(wrows::Spark { points: vec![1, 2], tone: wrows::Tone::Text }),
        };
        assert!(decoration(d("CI 7/9", wrows::Tone::Text)).unwrap_err().contains("never text"));
        for bad in [
            "Needs You", "needs  you", "NEEDS\u{200b}YOU", "N-E-E-D-S you!", "n\u{0435}eds you", "\u{FF24}one", "Waiting", "approve", "Allow.",
            "deny", "RUNNING", "idle", "done", "d0ne", "ldle", "|dle", "1DLE", "Waiting for…", "✓ done", "FAILED", "approve?", "needs you later",
            "done 3/4", "CI: d o n e", "fai1ed", "nee\u{1D41D}s you", "runn1ng", "allovv", "WaitingForYou",
            "Al·low", "Do.ne", "Allo\u{0353}w", "Al·low ok", "ok De·ny", "d\u{f3}ne", "ap-prove",
            "don\u{212E}", "\u{2373}dle", "d\u{25CB}ne", "D\u{2228}NE", "ok-done-ok", "a.done.b", "[x]done[x]", "x—done—x",
            "d\u{043E}ne", "\u{FF44}one", "\u{3010}done\u{3011}", "a\u{2026}done", "ok \u{2022} De\u{2010}ny",
            "\u{0501}\u{043E}\u{0578}\u{0435}", "\u{0456}\u{0501}\u{04CF}\u{0435}", "R\u{0456}\u{0578}\u{0578}\u{0456}\u{0578}g",
            "done\u{2800}", "\u{2800}done", "do\u{2800}ne", "d\u{2800}o\u{2800}n\u{2800}e", "Allow\u{2800}", "needs\u{2800}you",
            "done\u{1D159}", "idle\u{3000}", "ok\u{A0}deny", "fail\u{3164}ed", "do\u{115F}ne",
            "done✓", "✔done", "done★", "done™", "done\u{2804}", "done∙", "idle💤", "Allow✓", "needs you❗", "✓✓done✓✓",
            "done\u{A4F8}", "done\u{02D0}", "\u{02BB}done\u{02BC}", "done\u{30FC}", "done\u{06F0}", "done\u{0660}", "done\u{1427}",
            "done\u{A4FD}", "idle\u{A4FC}", "Allow\u{02D0}", "needs you\u{A4FD}",
        ] {
            assert!(decoration(d(bad, wrows::Tone::Dim)).is_err(), "{bad:?}");
        }
        // Also without plain(): the fold itself splits at a blank.
        assert!(says_status("done\u{2800}") && says_needs_you("needs\u{2800}you"));
        for ok in [
            "CI 7/9", "spec 11/18", "3 edits", "✓", "wait 2m", "allowlist", "allowlist ok", "🚀🚀🚀🚀", "dev ✓", "denylisted",
            "abandoned", "idler", "undone·x", "redone", "doneness", "rerunning", "x—undone", "abandoned✓", "idler💤", "✓allowlist", "abandoned\u{A4F8}", "idler\u{30FC}", "redone\u{02D0}", "café", "naïve",
        ] {
            let dec = decoration(d(ok, wrows::Tone::Warn)).unwrap();
            assert_eq!(dec.spark.unwrap().tone, Tone::Text, "the sparkline may keep text");
        }
        let s = |suffix: &str, scroll: bool| wrows::Decoration {
            label: None, label_tone: wrows::Tone::Dim, suffix: Some(suffix.into()), suffix_tone: wrows::Tone::Dim, scroll, bar: None, spark: None,
        };
        for bad in ["api needs you", "n\u{0435}eds-you", "Waiting for you", "x·NEEDS·YOU·x", "w a i t i n g for you", "api needs\u{2800}you",
                    "waiting\u{2800}for\u{2800}you", "needs\u{1D159}you"] {
            assert!(decoration(s(bad, false)).is_err() && decoration(s(bad, true)).is_err(), "{bad:?}");
        }
        for ok in ["#142 · checks running", "failed 2m ago", "held 3m · a failed turn", "echo done", "CI 7/9 · 3 edits", "waiting 2m"] {
            assert!(decoration(s(ok, false)).is_ok() && decoration(s(ok, true)).is_ok(), "{ok:?}");
        }
    }

    #[test]
    fn keys_need_cmd_skip_taken_chords_and_stop_at_eight() {
        use wkeys::Host as _;
        let core = crate::Core::new(&*tempdir("keys"));
        let mut p = HostState::new("dev.x.ptt", &Capabilities { keys: true, ..Default::default() }, None, None, Some(core.handle()));
        core.handle().set_taken_chords(
            [("cmd+t", "haunt"), ("cmd+shift+y", "dev.other/go"), ("cmd+shift+u", "dev.x.ptt/talk")].map(|(c, o)| (c.into(), o.into())).into(),
        );
        assert!(p.bind("talk".into(), "ctrl+space".into()).is_err(), "no cmd: terminal input");
        assert!(p.bind("talk".into(), "cmd+t".into()).unwrap_err().contains("Haunt's"));
        assert!(p.bind("talk".into(), "cmd+shift+y".into()).unwrap_err().contains("dev.other/go"));
        assert!(p.bind("\u{200b}".into(), "cmd+shift+j".into()).is_err());
        wpal::Host::command(&mut p, "deploy".into(), "Deploy".into(), Some("cmd+shift+d".into()));
        assert!(p.bind("deploy".into(), "cmd+shift+j".into()).unwrap_err().contains("palette command"));
        p.palette.clear();
        p.bind("talk".into(), "shift+cmd+u".into()).unwrap();
        wpal::Host::command(&mut p, "talk".into(), "Talk".into(), None);
        assert!(p.palette.is_empty(), "a command can't take a bound key's id either");
        assert!(p.bind("other".into(), "cmd+shift+u".into()).unwrap_err().contains("talk"));
        assert_eq!(p.keys, [("talk".to_owned(), "cmd+shift+u".to_owned())]);
        for i in 1..MAX_KEYS {
            p.bind(format!("k{i}"), format!("cmd+opt+{i}")).unwrap();
        }
        assert!(p.bind("k9".into(), "cmd+opt+9".into()).is_err());
        p.bind("talk".into(), "cmd+shift+i".into()).unwrap();
        p.unbind("talk".into());
        p.unbind("talk".into());
        let changes = p.outbox.iter().filter(|r| matches!(r, HostRequest::KeysChanged { .. })).count();
        assert_eq!((p.keys.len(), changes), (MAX_KEYS - 1, MAX_KEYS + 2));
        p.drop_keys();
        assert!(p.keys.is_empty());
    }

    #[test]
    fn hover_hold_is_alt_only_and_one_plugins_at_a_time() {
        use wkeys::Host as _;
        let core = crate::Core::new(&*tempdir("hover"));
        let caps = Capabilities { keys: true, ..Default::default() };
        let mut a = HostState::new("dev.x.peek", &caps, None, None, Some(core.handle()));
        let mut b = HostState::new("dev.x.other", &caps, None, None, Some(core.handle()));
        assert!(a.hover_hold(Some("cmd".into())).unwrap_err().contains("only \"alt\""));
        a.hover_hold(Some("alt".into())).unwrap();
        a.hover_hold(Some("alt".into())).unwrap();
        assert!(b.hover_hold(Some("alt".into())).unwrap_err().contains("dev.x.peek"));
        assert_eq!(a.outbox.len(), 1, "taking it twice is one change");
        a.hover_hold(None).unwrap();
        b.hover_hold(Some("alt".into())).unwrap();
        assert!(a.hover_hold(Some("alt".into())).is_err());
        b.drop_keys();
        assert!(!b.hover_hold && matches!(b.outbox.last(), Some(HostRequest::KeysChanged { .. })), "a disabled plugin gives it up");
        a.hover_hold(Some("alt".into())).unwrap();
        drop(a);
        b.hover_hold(Some("alt".into())).unwrap();
    }

    #[test]
    fn only_a_posted_notification_action_reaches_the_plugin() {
        use wnotify::Host as _;
        let mut st = HostState::new("dev.x.n", &Capabilities { notifications: true, ..Default::default() }, None, None, None);
        let action = |id: &str| wnotify::Action { id: id.into(), title: "Open".into() };
        st.notify("CI".into(), "red".into(), vec![action("open-pr")], Some("tab-1".into())).unwrap();
        assert!(st.notified.contains(&("open-pr".into(), "tab-1".into())));
        assert!(st.notify("x".into(), String::new(), (0..5).map(|i| action(&i.to_string())).collect(), None).is_err());
        for i in 0..MAX_NOTIFIED {
            st.notify("x".into(), String::new(), vec![action(&i.to_string())], None).unwrap();
        }
        assert_eq!(st.notified.len(), MAX_NOTIFIED);
        assert!(!st.notified.iter().any(|(a, _)| a == "open-pr"), "oldest first out");
    }

    #[test]
    fn a_click_on_a_notification_action_may_open_its_link_and_copy_once() {
        use wclip::Host as _;
        use wlink::Host as _;
        use wnotify::Host as _;
        let caps = Capabilities { notifications: true, clipboard: Some("write".into()), open_url: vec!["github.com".into()], ..Default::default() };
        let mut st = HostState::new("dev.haunt.ci-lights", &caps, None, None, None);
        let pr = "https://github.com/o/r/pull/142";
        let action = |id: &str, title: &str| wnotify::Action { id: id.into(), title: title.into() };
        st.notify("api · #142 checks failed".into(), String::new(), vec![action(pr, "Open PR"), action("https://evil.com/x", "Docs"), action("snooze", "Snooze")], Some("s1".into())).unwrap();
        let Some(HostRequest::Notify { actions, .. }) = st.outbox.pop() else { panic!() };
        let titles: Vec<&str> = actions.iter().map(|a| a.title.as_str()).collect();
        assert_eq!(titles, ["Open PR (github.com)", "Docs", "Snooze"], "a link's button names its host, if it can open");

        assert!(st.open_url(pr.into()).is_err() && st.write("x".into()).is_err(), "delivering a notification arms nothing");
        assert!(st.notify_click(pr, "").is_err(), "the binding must match the one posted");
        assert!(st.notify_click("https://github.com/o/r/pull/9", "s1").is_err(), "only a posted action");
        st.notify_click(pr, "s1").unwrap();
        assert!(st.open_url("https://github.com/o/r/pull/9".into()).is_err(), "only the action's own url");
        st.notify_click(pr, "s1").unwrap();
        st.open_url(pr.into()).unwrap();
        assert!(st.open_url(pr.into()).is_err(), "once per click");
        st.write("brief".into()).unwrap();
        st.disarm();
        st.notify_click("snooze", "s1").unwrap();
        assert!(st.open_url("snooze".into()).is_err());
        st.disarm();
        assert!(st.write("x".into()).is_err(), "the call ended");
        assert_eq!(st.outbox.iter().filter(|r| matches!(r, HostRequest::OpenUrl { .. })).count(), 1);
    }

    #[test]
    fn the_users_row_labels_pick_the_winner_and_the_rest_go_in_the_tooltip() {
        use wrows::Host as _;
        let core = crate::Core::new(&*tempdir("rows-order"));
        let a = core.register_surface("/a").unwrap();
        let caps = Capabilities { decorate: true, ..Default::default() };
        let row = |core: &crate::Core| core.snapshot().groups.iter().flat_map(|g| g.rows.clone()).find(|r| r.surface_id == a.surface_id).unwrap();
        let mut ci = HostState::new("dev.haunt.ci-lights", &caps, None, None, Some(core.handle()));
        let mut sticky = HostState::new("dev.haunt.sticky-notes", &caps, None, None, Some(core.handle()));
        let mut checklist = HostState::new("dev.haunt.checklist-meter", &caps, None, None, Some(core.handle()));
        ci.decorate(a.surface_id.clone(), Some(deco("CI 7/9"))).unwrap();
        sticky.decorate(a.surface_id.clone(), Some(wrows::Decoration { label: None, suffix: Some("note".into()), ..deco("") })).unwrap();
        checklist.decorate(a.surface_id.clone(), Some(deco("spec 11/18"))).unwrap();
        let r = row(&core);
        assert_eq!((r.decoration.unwrap().label.as_deref(), r.other_labels), (Some("CI 7/9"), vec!["note".to_owned(), "spec 11/18".to_owned()]), "load order");

        core.handle().set_row_labels(vec!["checklist".into(), "dev.haunt.ci-lights".into()]);
        let r = row(&core);
        assert_eq!(r.decoration.unwrap().label.as_deref(), Some("spec 11/18"));
        assert_eq!(r.other_labels, ["CI 7/9", "note"], "listed ones first, then the rest in load order");
        core.handle().set_row_labels(vec!["sticky-notes".into(), "check".into()]);
        assert_eq!(row(&core).decoration.unwrap().suffix.as_deref(), Some("note"), "a full short name; `check` names nothing");
        assert_eq!(row(&core).other_labels, ["CI 7/9", "spec 11/18"]);
    }

    #[test]
    fn decorations_are_plain_capped_and_the_first_loaded_plugin_wins() {
        use wrows::Host as _;
        let core = crate::Core::new(&*tempdir("rows-core"));
        let a = core.register_surface("/a").unwrap();
        let caps = Capabilities { decorate: true, ..Default::default() };
        let decoration_of = |core: &crate::Core| core.snapshot().groups.iter().flat_map(|g| g.rows.clone()).find(|r| r.surface_id == a.surface_id).unwrap().decoration;

        let mut first = HostState::new("dev.x.first", &caps, None, None, Some(core.handle()));
        let mut second = HostState::new("dev.x.second", &caps, None, None, Some(core.handle()));
        second.decorate(a.surface_id.clone(), Some(deco("second"))).unwrap();
        assert_eq!(decoration_of(&core).unwrap().label.as_deref(), Some("second"));

        let long = wrows::Decoration {
            suffix: Some(format!("a\u{202e}b\n{}", "c".repeat(200))),
            bar: Some(1.7),
            spark: Some(wrows::Spark { points: vec![0, 255], tone: wrows::Tone::Text }),
            ..deco("ab\u{200b}cdefghijklmnopqrstuvwxyz")
        };
        first.decorate(a.surface_id.clone(), Some(long)).unwrap();
        let d = decoration_of(&core).unwrap();
        assert_eq!(d.label.as_deref(), Some("abcdefghijklmnopqrstuvwx"), "first loaded wins, hidden characters go, cut to 24");
        assert_eq!(d.suffix.unwrap(), format!("ab {}", "c".repeat(61)));
        assert_eq!((d.bar_permille, d.label_tone), (Some(1000), Tone::Warn));

        assert!(first.decorate(a.surface_id.clone(), Some(wrows::Decoration { bar: Some(f32::NAN), ..deco("x") })).is_err());
        let spark = wrows::Spark { points: vec![1; 33], tone: wrows::Tone::Dim };
        assert!(first.decorate(a.surface_id.clone(), Some(wrows::Decoration { spark: Some(spark), ..deco("x") })).is_err());
        assert!(first.decorate("no-such-tab".into(), Some(deco("x"))).is_err());
        let mut no_cap = HostState::new("dev.x.nocap", &Capabilities::default(), None, None, Some(core.handle()));
        assert!(no_cap.decorate(a.surface_id.clone(), Some(deco("x"))).unwrap_err().contains("decorate capability"));

        first.decorate(a.surface_id.clone(), None).unwrap();
        assert_eq!(decoration_of(&core).unwrap().label.as_deref(), Some("second"), "removing one shows the next");
        first.decorate(a.surface_id.clone(), Some(deco("back"))).unwrap();
        first.release_rows();
        assert_eq!(decoration_of(&core).unwrap().label.as_deref(), Some("second"), "a disabled instance's decorations go");
        assert!(first.decorate(a.surface_id.clone(), Some(deco("x"))).is_err());
        drop(second);
        assert_eq!(decoration_of(&core), None);

        let mut third = HostState::new("dev.x.third", &caps, None, None, Some(core.handle()));
        third.decorate(a.surface_id.clone(), Some(deco("x"))).unwrap();
        core.unregister_surface(&a.surface_id);
        let b = core.register_surface("/b").unwrap();
        assert!(core.snapshot().groups.iter().flat_map(|g| &g.rows).all(|r| r.decoration.is_none()), "a closed tab's decorations go");
        third.clear_all();
        assert!(third.decorate(b.surface_id, Some(deco("x"))).is_ok());
    }

    #[test]
    fn a_lockfile_cannot_widen_fs_grants_past_agent_folders() {
        assert_eq!(cwd_globs(&["/etc/hosts".into(), "${cwd}/a".into(), "${cwd}x".into()]), ["${cwd}/a"]);
        let caps = Capabilities { fs_read: vec!["/etc/hosts".into(), "${cwd}/a".into()], fs_write: vec!["~/x".into()], ..Default::default() };
        let errs = dropped_fs_grants(&caps);
        assert!(errs.len() == 2 && errs[0].starts_with("reading \"/etc/hosts\" is off") && errs[1].starts_with("writing \"~/x\""), "{errs:?}");
    }

    #[test]
    fn the_timer_needs_its_capability_and_15_seconds() {
        use wtimer::Host as _;
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/timer@0.5.0" (instance (export "stop" (func)))))"#).unwrap();
        let e = host.check_links(&c, &Capabilities { decorate: true, sidebar: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/timer"), "{e}");
        host.check_links(&c, &Capabilities { timer: true, ..Default::default() }).unwrap();
        let clock = Component::new(&host.engine, r#"(component (import "haunt:plugin/clock@0.5.0" (instance (export "local-offset-min" (func (result s32))))))"#).unwrap();
        assert!(host.check_links(&clock, &Capabilities::default()).unwrap_err().0.contains("haunt:plugin/clock"));
        host.check_links(&clock, &Capabilities { timer: true, ..Default::default() }).unwrap();
        assert!((-14 * 60..=14 * 60).contains(&local_offset_min()));

        let mut st = HostState::new("dev.x.t", &Capabilities { timer: true, ..Default::default() }, None, None, None);
        assert!(st.every(14).is_err());
        assert!(st.every(86_401).is_err());
        let before = Instant::now();
        st.every(15).unwrap();
        let (every, due) = st.timer.unwrap();
        assert_eq!(every, Duration::from_secs(15));
        assert!(due >= before + every);
        st.stop();
        assert!(st.timer.is_none());
    }

    #[test]
    fn panels_need_their_capability_and_queue_show_and_close() {
        use wpanel::Host as _;
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/panel@0.5.0" (instance (export "close" (func (param "id" string))))))"#).unwrap();
        let e = host.check_links(&c, &Capabilities { decorate: true, notifications: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/panel"), "{e}");
        host.check_links(&c, &Capabilities { panel: true, ..Default::default() }).unwrap();

        let mut st = HostState::new("dev.x.p", &Capabilities { panel: true, ..Default::default() }, None, None, None);
        st.close("never-shown".into());
        assert!(st.outbox.is_empty());
        st.show("w".into(), wpanel::Placement::Sheet, "Welcome back".into(), vec![]).unwrap();
        assert!(st.show("bad id".into(), wpanel::Placement::Sheet, String::new(), vec![]).is_err());
        st.close("w".into());
        assert!(matches!(&st.outbox[..], [
            HostRequest::ShowPanel { plugin_id, plugin_name, panel },
            HostRequest::ClosePanel { id, .. },
        ] if plugin_id == "dev.x.p" && plugin_name == "dev.x.p" && panel.title == "Welcome back" && panel.generation == 1 && id == "w"));
    }

    #[test]
    fn a_sheet_needs_a_user_action_and_one_plugins_sheet_is_up_at_a_time() {
        use wpanel::Host as _;
        let core = crate::Core::new(&*tempdir("sheets"));
        let caps = Capabilities { panel: true, ..Default::default() };
        let mut a = HostState::new("dev.x.a", &caps, None, None, Some(core.handle()));
        let mut b = HostState::new("dev.x.b", &caps, None, None, Some(core.handle()));
        let placement = |st: &HostState| match st.outbox.last() { Some(HostRequest::ShowPanel { panel, .. }) => panel.placement, _ => panic!() };
        a.show("w".into(), wpanel::Placement::Sheet, "Hi".into(), vec![]).unwrap();
        assert_eq!(placement(&a), PanelPlacement::Card, "unasked, a sheet comes up as a card");
        a.user_call = true;
        a.show("w".into(), wpanel::Placement::Sheet, "Hi".into(), vec![]).unwrap();
        assert_eq!(placement(&a), PanelPlacement::Sheet);
        b.user_call = true;
        assert!(b.show("s".into(), wpanel::Placement::Sheet, "Me".into(), vec![]).unwrap_err().contains("dev.x.a's sheet is up"));
        b.show("c".into(), wpanel::Placement::Card, "Me".into(), vec![]).unwrap();
        a.show("w".into(), wpanel::Placement::Card, "Hi".into(), vec![]).unwrap();
        b.show("s".into(), wpanel::Placement::Sheet, "Me".into(), vec![]).unwrap();
        assert!(a.show("w".into(), wpanel::Placement::Sheet, "Hi".into(), vec![]).is_err(), "b has the slot now");
        b.close("s".into());
        a.show("w".into(), wpanel::Placement::Sheet, "Hi".into(), vec![]).unwrap();
        drop(a);
        b.show("s".into(), wpanel::Placement::Sheet, "Me".into(), vec![]).unwrap();
    }

    #[test]
    fn a_sheet_asked_for_on_return_waits_for_the_user_to_switch_to_haunt() {
        use wpanel::Host as _;
        let core = crate::Core::new(&*tempdir("return"));
        let mut a = HostState::new("dev.x.welcome", &Capabilities { panel: true, away: true, ..Default::default() }, None, None, Some(core.handle()));
        let held = |a: &mut HostState, title: &str| {
            a.returning = true;
            a.show("hi".into(), wpanel::Placement::Sheet, title.into(), vec![]).unwrap();
            a.returning = false;
        };
        let shown = |a: &HostState, title: &str| {
            a.outbox.iter().any(|r| matches!(r, HostRequest::ShowPanel { panel, .. } if panel.title == title && panel.placement == PanelPlacement::Sheet))
        };
        held(&mut a, "Welcome back");
        a.show("note".into(), wpanel::Placement::Card, "Note".into(), vec![]).unwrap();
        assert!(matches!(&a.outbox[..], [HostRequest::ShowPanel { panel, .. }] if panel.id == "note"), "no sheet while they may be typing elsewhere");
        let t = Instant::now();
        a.return_sheet_due(t + RETURN_SHEET_DELAY, false).unwrap();
        assert!(!shown(&a, "Welcome back"), "not before Haunt is active");
        a.return_activated(t);
        a.return_sheet_due(t + RETURN_SHEET_DELAY / 2, false).unwrap();
        assert!(!shown(&a, "Welcome back"), "not in the first second");
        a.return_sheet_due(t + RETURN_SHEET_DELAY, false).unwrap();
        assert!(shown(&a, "Welcome back"));
        a.return_sheet_due(t + RETURN_SHEET_DELAY * 2, false).unwrap();
        assert_eq!(a.outbox.len(), 2, "once");

        held(&mut a, "Left again");
        let t = Instant::now();
        a.return_activated(t);
        a.return_resigned();
        a.return_sheet_due(t + RETURN_SHEET_DELAY, false).unwrap();
        assert!(!shown(&a, "Left again"), "leaving before it was due keeps it waiting");
        let t = t + RETURN_SHEET_DELAY * 3;
        a.return_activated(t);
        a.return_sheet_due(t + RETURN_SHEET_DELAY, false).unwrap();
        assert!(shown(&a, "Left again"), "the next activation shows it");

        held(&mut a, "Typed over");
        let t = Instant::now();
        a.return_activated(t);
        a.return_sheet_due(t + RETURN_SHEET_DELAY, true).unwrap();
        a.return_activated(t + RETURN_SHEET_DELAY);
        a.return_sheet_due(t + RETURN_SHEET_DELAY * 2, false).unwrap();
        assert!(!shown(&a, "Typed over"), "typing into Haunt in that second drops it");

        held(&mut a, "Stale");
        let t = Instant::now() + RETURN_SHEET_TTL;
        a.return_activated(t);
        a.return_sheet_due(t + RETURN_SHEET_DELAY, false).unwrap();
        assert!(!shown(&a, "Stale"), "held ten minutes, it expires");

        held(&mut a, "Again");
        a.close("hi".into());
        let t = Instant::now();
        a.return_activated(t);
        a.return_sheet_due(t + RETURN_SHEET_DELAY, false).unwrap();
        assert!(!shown(&a, "Again"), "closed before it showed");
    }

    #[test]
    fn a_proposal_through_the_import_is_only_pending() {
        use wallow::Host as _;
        let project = tempdir("propose");
        std::fs::create_dir_all(&project).unwrap();
        let project = project.canonicalize().unwrap();
        let core = crate::Core::new(&*tempdir("propose-core"));
        let mut st = HostState::new("dev.haunt.allowlist", &Capabilities::default(), None, None, Some(core.handle()));
        let p = project.to_str().unwrap().to_owned();
        assert!(st.propose(p.clone(), "cargo test".into()).unwrap_err().contains("never approved"));
        assert!(st.approvals(1).is_empty());
        assert!(core.allow_suggestions().is_empty());
        assert!(!project.join(".claude").exists());
        let mut detached = HostState::new("x", &Capabilities::default(), None, None, None);
        assert!(detached.propose(p, "cargo test".into()).is_err());
    }

    #[test]
    fn the_approvals_import_hides_one_offs_other_agents_and_cleaned_commands() {
        use crate::{decisions::Decision, event::Agent, session::Outcome};
        use wallow::Host as _;
        let core = crate::Core::new(&*tempdir("approvals-floor"));
        let d = |cmd: &str, preview: &str, outcome, agent| Decision {
            at_ms: 1,
            surface_id: "s".into(),
            tool: "Bash".into(),
            preview: preview.into(),
            command: Some(cmd.into()),
            cwd: Some("/p".into()),
            outcome,
            agent,
        };
        core.with_state(|st| {
            for x in [
                d("export TOKEN=abc", "export TOKEN=abc", Outcome::AllowedInHaunt, Agent::Claude),
                d("cargo test", "cargo test", Outcome::AllowedInHaunt, Agent::Claude),
                d("cargo test", "cargo test", Outcome::AllowedInHaunt, Agent::Claude),
                d("make", "make", Outcome::AnsweredInTerminal, Agent::Claude),
                d("make", "make", Outcome::AnsweredInTerminal, Agent::Claude),
                d("npm i", "npm i", Outcome::AllowedInHaunt, Agent::Codex),
                d("npm i", "npm i", Outcome::AllowedInHaunt, Agent::Codex),
                d("ls\u{1b}[2K", "ls", Outcome::AllowedInHaunt, Agent::Claude),
                d("ls\u{1b}[2K", "ls", Outcome::AllowedInHaunt, Agent::Claude),
            ] {
                st.decisions.record(x);
            }
        });
        let mut st = HostState::new("p", &Capabilities::default(), None, None, Some(core.handle()));
        let got: Vec<_> = st.approvals(0).into_iter().map(|a| (a.command, a.count)).collect();
        assert_eq!(got, [("cargo test".to_owned(), 2)]);
    }

    fn raw_store(host: &PluginHost) -> Store<HostState> {
        let mut store = Store::new(&host.engine, HostState::new("t", &Capabilities::default(), None, None, None));
        store.limiter(|s| &mut s.limits);
        store
    }

    /// A whole-world plugin. `on-action(id, _)` does nothing for an `id` starting with "?"; otherwise it copies
    /// "copied" twice, opens `id` twice and focuses the first sidebar row twice, then traps if `id` starts
    /// with "!". `on-event` copies, opens https://github.com/o/r and focuses the first row. Every other
    /// export is empty.
    const ARMING_PLUGIN: &str = r#"(module
        (import "haunt:plugin/clipboard@0.5.0" "write" (func $write (param i32 i32 i32)))
        (import "haunt:plugin/link@0.5.0" "open-url" (func $open (param i32 i32 i32)))
        (import "haunt:plugin/sidebar@0.5.0" "rows" (func $rows (param i32)))
        (import "haunt:plugin/sidebar@0.5.0" "focus" (func $focus (param i32 i32 i32)))
        (memory (export "memory") 1)
        (data (i32.const 64) "copied")
        (data (i32.const 80) "https://github.com/o/r")
        (global $heap (mut i32) (i32.const 1024))
        (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
            (local $p i32)
            (local.set $p (i32.and (i32.add (global.get $heap) (i32.sub (local.get 2) (i32.const 1))) (i32.sub (i32.const 0) (local.get 2))))
            (global.set $heap (i32.add (local.get $p) (local.get 3)))
            (local.get $p))
        (func $focus_first
            (local $row i32)
            (call $rows (i32.const 256))
            (if (i32.eqz (i32.load (i32.const 260))) (then return))
            (local.set $row (i32.load (i32.const 256)))
            (call $focus (i32.load (local.get $row)) (i32.load offset=4 (local.get $row)) (i32.const 16)))
        (func (export "init") (param i32 i32))
        (func (export "on-settings-changed") (param i32 i32))
        (func (export "on-event") (param i32)
            (call $write (i32.const 64) (i32.const 6) (i32.const 16))
            (call $open (i32.const 80) (i32.const 22) (i32.const 16))
            (call $focus_first))
        (func (export "palette-items") (param i32 i32 i32 i32) (result i32) (i32.const 8))
        (func (export "on-action") (param $id i32) (param $len i32) (param i32 i32)
            (if (i32.and (i32.gt_u (local.get $len) (i32.const 0)) (i32.eq (i32.load8_u (local.get $id)) (i32.const 63)))
                (then return))
            (call $write (i32.const 64) (i32.const 6) (i32.const 16))
            (call $write (i32.const 64) (i32.const 6) (i32.const 16))
            (call $open (local.get $id) (local.get $len) (i32.const 16))
            (call $open (local.get $id) (local.get $len) (i32.const 16))
            (call $focus_first)
            (call $focus_first)
            (if (i32.and (i32.gt_u (local.get $len) (i32.const 0)) (i32.eq (i32.load8_u (local.get $id)) (i32.const 33)))
                (then unreachable)))
        (func (export "row-menu") (param i32 i32) (result i32) (i32.const 8))
        (func (export "on-row-moved") (param i32 i32 i32 i32 i32 i32 i32))
        (func (export "on-theme-changed"))
        (func (export "on-tick") (param i64))
        (func (export "on-exec") (param i64 i32 i32 i32 i32 i32 i32 i32))
        (func (export "on-away-changed") (param i32 i64))
        (func (export "on-hover-hold") (param i32 i32 i32))
        (func (export "on-fs-tree") (param i64 i32 i32 i32 i32)))"#;

    /// `ARMING_PLUGIN` as a component of the plugin world, loaded with clipboard, open_url, panel and
    /// sidebar, on `core`.
    fn arming_plugin(core: &crate::Core) -> LoadedPlugin {
        let mut resolve = wit_parser::Resolve::default();
        let pkg = resolve.push_path(Path::new(env!("CARGO_MANIFEST_DIR")).join("../wit/haunt-plugin.wit")).unwrap().0;
        let world = resolve.select_world(&[pkg], Some("plugin")).unwrap();
        let mut module = wat::parse_str(ARMING_PLUGIN).unwrap();
        wit_component::embed_component_metadata(&mut module, &resolve, world, wit_component::StringEncoding::UTF8, false).unwrap();
        let bytes = wit_component::ComponentEncoder::default().module(&module).unwrap().validate(true).encode().unwrap();
        let host = PluginHost::new().unwrap();
        let component = Component::new(&host.engine, &bytes).unwrap();
        let caps = Capabilities { clipboard: Some("write".into()), open_url: vec!["github.com".into()], panel: true, sidebar: true, ..Default::default() };
        let spec = LoadSpec { id: "dev.x.arming".into(), name: "Arming".into(), caps, settings_json: "{}".into(), core: Some(core.handle()), ..Default::default() };
        host.instantiate(&component, &spec).unwrap()
    }

    /// The clipboard writes, opened links and focused tabs the last calls queued, taken from the outbox.
    fn effects(p: &mut LoadedPlugin) -> (Vec<String>, Vec<String>, Vec<String>) {
        let (mut copied, mut opened, mut focused) = (Vec::new(), Vec::new(), Vec::new());
        for r in std::mem::take(&mut p.store.data_mut().outbox) {
            match r {
                HostRequest::ClipboardWrite { text, .. } => copied.push(text),
                HostRequest::OpenUrl { url, .. } => opened.push(url),
                HostRequest::FocusTab { surface, .. } => focused.push(surface),
                _ => {}
            }
        }
        (copied, opened, focused)
    }

    fn show_button(p: &mut LoadedPlugin, action: &str) -> u64 {
        use wpanel::Host as _;
        let button = wpanel::Node::Button(wpanel::ButtonNode { label: "Open".into(), action: action.into(), primary: false, surface: None });
        p.store.data_mut().show("p".into(), wpanel::Placement::Card, "PR".into(), vec![wpanel::PanelNode { parent: None, node: button }]).unwrap();
        let shown = p.store.data().outbox.iter().rev().find_map(|r| match r {
            HostRequest::ShowPanel { panel, .. } => Some(panel.generation),
            _ => None,
        });
        effects(p);
        shown.unwrap()
    }

    fn disarmed(p: &LoadedPlugin) -> bool {
        let st = p.store.data();
        !st.copy_ok && !st.focus_ok && st.clicked.is_none() && st.reads_left == 0 && st.typing_into.is_none() && !st.user_call
    }

    #[test]
    fn only_the_user_action_itself_may_copy_open_a_link_or_focus_a_tab() {
        let pr = "https://github.com/o/r/pull/1";
        let dir = tempdir("arming");
        let core = crate::Core::new(&*dir);
        let tab = core.register_surface("/a").unwrap().surface_id;
        let mut p = arming_plugin(&core);
        assert!(disarmed(&p), "init arms nothing");

        let g = show_button(&mut p, pr);
        p.panel_action("p", g, pr).unwrap();
        assert_eq!(effects(&mut p), (vec!["copied".to_string()], vec![pr.to_string()], vec![tab.clone()]), "a button press copies, opens its own url and focuses a tab, each once");
        assert!(disarmed(&p), "disarmed after the press");

        let g2 = show_button(&mut p, pr);
        assert!(p.panel_action("p", g, pr).is_err(), "an older show's button");
        assert_eq!(effects(&mut p), (vec![], vec![], vec![]));
        p.panel_action("p", g2, "").unwrap();
        assert_eq!(effects(&mut p), (vec![], vec![], vec![]), "closing the panel is not a press");
        assert!(disarmed(&p));

        let idle = "?https://github.com/o/r";
        let g3 = show_button(&mut p, idle);
        p.panel_action("p", g3, idle).unwrap();
        assert!(disarmed(&p), "an unspent press is disarmed when it returns");
        p.on_event(&tapped(EventKind::Stop, true, None)).unwrap();
        assert_eq!(effects(&mut p), (vec![], vec![], vec![]), "an agent event arms nothing, even after a press it didn't use");

        p.run_command(pr, true).unwrap();
        assert_eq!(effects(&mut p), (vec!["copied".to_string()], vec![], vec![tab.clone()]), "a command may copy and focus once but opens no link");
        assert!(disarmed(&p), "run_user_action disarms afterwards");
        p.run_command(idle, true).unwrap();
        assert!(disarmed(&p), "an unspent command is disarmed too");
        p.store.data_mut().keys.push((pr.into(), "cmd+k".into()));
        p.key_action(pr, true, true).unwrap();
        assert_eq!(effects(&mut p), (vec!["copied".to_string()], vec![], vec![tab.clone()]), "a key press may copy and focus once");
        p.key_action(pr, false, true).unwrap();
        assert_eq!(effects(&mut p), (vec![], vec![], vec![]), "its release may not copy again");
        assert!(disarmed(&p));
        p.on_event(&tapped(EventKind::Stop, true, None)).unwrap();
        assert_eq!(effects(&mut p), (vec![], vec![], vec![]));

        let note = "https://github.com/o/r/pull/2";
        p.store.data_mut().notified.extend([(note.to_string(), String::new()), (idle.to_string(), String::new())]);
        p.notify_action(note, "").unwrap();
        assert_eq!(effects(&mut p), (vec!["copied".to_string()], vec![note.to_string()], vec![tab.clone()]), "a notification action is a press");
        assert!(disarmed(&p));
        p.notify_action(idle, "").unwrap();
        assert!(disarmed(&p), "an unspent notification action is disarmed when it returns");
        p.on_event(&tapped(EventKind::Stop, true, None)).unwrap();
        assert_eq!(effects(&mut p), (vec![], vec![], vec![]), "nothing left armed for an agent event");
        assert!(p.notify_action("https://github.com/o/r/pull/3", "").is_err(), "only an action it posted");

        let trap = "!https://github.com/o/r";
        let g4 = show_button(&mut p, trap);
        assert!(p.panel_action("p", g4, trap).is_err());
        assert_eq!(effects(&mut p), (vec![], vec![], vec![]), "a call that traps leaves nothing queued");
        assert!(disarmed(&p));

        core.unregister_surface(&tab);
        let other = core.register_surface("/b").unwrap().surface_id;
        let mut p = arming_plugin(&core);
        p.run_command(pr, true).unwrap();
        assert_eq!(effects(&mut p).2, [other], "only a tab that is open now");
    }

    #[test]
    fn runaway_call_is_interrupted() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(
            &host.engine,
            r#"(component
                (core module $m (func (export "spin") (loop $l (br $l))))
                (core instance $i (instantiate $m))
                (func (export "spin") (canon lift (core func $i "spin"))))"#,
        )
        .unwrap();
        let mut store = raw_store(&host);
        let inst = Linker::new(&host.engine).instantiate(&mut store, &c).unwrap();
        let spin = inst.get_typed_func::<(), ()>(&mut store, "spin").unwrap();
        store.set_epoch_deadline(CALL_TICKS);
        let t = Instant::now();
        let e = host.epoch.ticking(|| spin.call(&mut store, ())).unwrap_err();
        assert_eq!(e.downcast_ref::<Trap>(), Some(&Trap::Interrupt));
        assert!(t.elapsed() < Duration::from_millis(500), "{:?}", t.elapsed());
    }

    #[test]
    fn looping_start_function_is_interrupted() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(
            &host.engine,
            r#"(component
                (core module $m (func $spin (loop $l (br $l))) (start $spin))
                (core instance $i (instantiate $m)))"#,
        )
        .unwrap();
        let mut store = raw_store(&host);
        store.set_epoch_deadline(CALL_TICKS);
        let t = Instant::now();
        let e = host.epoch.ticking(|| Linker::new(&host.engine).instantiate(&mut store, &c)).expect_err("start must not finish");
        assert_eq!(e.downcast_ref::<Trap>(), Some(&Trap::Interrupt), "{e:#}");
        assert!(t.elapsed() < Duration::from_millis(500), "{:?}", t.elapsed());
        assert_eq!(host.epoch.active.load(Ordering::Acquire), 0, "ticking stops after the trap");
    }

    #[test]
    fn memory_is_capped_at_64_mb() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(
            &host.engine,
            r#"(component
                (core module $m (memory 1) (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0))))
                (core instance $i (instantiate $m))
                (func (export "grow") (param "pages" u32) (result s32) (canon lift (core func $i "grow"))))"#,
        )
        .unwrap();
        let mut store = raw_store(&host);
        store.set_epoch_deadline(u64::MAX);
        let inst = Linker::new(&host.engine).instantiate(&mut store, &c).unwrap();
        let grow = inst.get_typed_func::<(u32,), (i32,)>(&mut store, "grow").unwrap();
        assert_eq!(grow.call(&mut store, (1100,)).unwrap().0, -1, "68 MB refused");
        assert_eq!(grow.call(&mut store, (900,)).unwrap().0, 1, "57 MB allowed");
    }

    #[test]
    fn kv_cap_and_persistence() {
        let dir = tempdir("kv");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("kv.json");
        let mut kv = Kv::open(Some(path.clone()));
        kv.set("a".into(), "x".repeat(KV_CAP - 1)).unwrap();
        assert!(kv.set("b".into(), "yy".into()).is_err());
        kv.set("a".into(), "small".into()).unwrap();
        kv.set("b".into(), "yy".into()).unwrap();
        kv.delete("a");
        assert!(!path.exists(), "nothing written before the flush");
        kv.flush().unwrap();
        kv.set("c".into(), "z".into()).unwrap();
        drop(kv);
        let again = Kv::open(Some(path));
        assert_eq!(again.map.get("b").map(String::as_str), Some("yy"));
        assert_eq!((again.map.get("c").map(String::as_str), again.bytes), (Some("z"), 5), "dropping flushes");
    }
}
