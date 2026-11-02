//! wasmtime host for `haunt:plugin@0.3` components (plan sections 3.3 and 3.8).

use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};
use wasmtime::component::{Component, HasSelf, Linker, ResourceTable};
use wasmtime::{Config, Engine, EngineWeak, Store, StoreContextMut, StoreLimits, StoreLimitsBuilder, Trap};
use wasmtime_wasi::{HostMonotonicClock, HostWallClock, WasiCtx, WasiCtxView, WasiView};

use crate::event::{AgentEvent, EventKind};
use crate::plugin_cache::{CacheError, CwasmCache, cache_name};
use crate::plugin_fs::FsScope;
use crate::arrange::{Arrangement, ColorStyle, Section, StateGroup, TabColor};
use crate::layout::RowKind;
use crate::model::{CoreHandle, SidebarToken};
use crate::plugin_manifest::{Capabilities, KV_CAP};
use crate::session::Outcome;

mod bindings {
    wasmtime::component::bindgen!({ path: "../wit/haunt-plugin.wit", world: "plugin" });
}

use bindings::Plugin;
use bindings::haunt::plugin::{
    allowlist as wallow, decisions as wdec, kv as wkv, log as wlog, notify as wnotify, palette as wpal, pty as wpty, sidebar as wside,
    types as wit,
};

pub const MEMORY_CAP: usize = 64 << 20;
const TICK: Duration = Duration::from_millis(10);
/// 5 ticks of 10 ms: the plan's 50 ms per call.
const CALL_TICKS: u64 = 5;
const PTY_PER_SEC: usize = 10;
const MAX_PALETTE: usize = 64;
const MAX_OUTBOX: usize = 256;
const MAX_LOGS: usize = 1000;
const MAX_STR: usize = 4096;
const MAX_DECISIONS: u32 = 1000;
/// One-off approvals (an `export TOKEN=…`, say) never reach a plugin; repeats are what rules are for.
pub const APPROVALS_MIN: u32 = 2;

#[derive(Debug, Clone, PartialEq)]
pub struct Decoration {
    pub badge: Option<String>,
    pub style: String,
    pub meta_suffix: Option<String>,
}

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

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct NotifyAction {
    pub id: String,
    pub title: String,
}

/// Side effects a plugin asked for; the app drains and performs them. A `PtyAnswer` becomes bytes
/// only through `Core::gate_plugin_request` (`ptygate`).
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum HostRequest {
    Notify { plugin_id: String, title: String, body: String, actions: Vec<NotifyAction>, binding: Option<String> },
    PtyAnswer { plugin_id: String, surface: String, allow: bool, request_id: u64 },
}

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
    logs: Vec<String>,
    wasi: WasiCtx,
    table: ResourceTable,
    limits: StoreLimits,
    kv: Kv,
    palette: Vec<PaletteItem>,
    outbox: Vec<HostRequest>,
    fs: FsScope,
    pty_times: VecDeque<Instant>,
    core: Option<CoreHandle>,
    /// Set while this instance may arrange the sidebar.
    sidebar: Option<SidebarToken>,
}

impl Drop for HostState {
    fn drop(&mut self) {
        self.release_sidebar();
    }
}

impl HostState {
    fn new(id: &str, caps: &Capabilities, kv_path: Option<PathBuf>, haunt_dir: Option<&Path>, core: Option<CoreHandle>) -> Self {
        Self {
            id: id.to_owned(),
            logs: Vec::new(),
            wasi: WasiCtx::builder().wall_clock(CoarseWall).monotonic_clock(CoarseMono(Instant::now())).build(),
            table: ResourceTable::new(),
            limits: StoreLimitsBuilder::new().memory_size(MEMORY_CAP).instances(16).tables(64).memories(4).build(),
            kv: Kv::open(kv_path),
            palette: Vec::new(),
            outbox: Vec::new(),
            fs: FsScope::new(&caps.fs_read, &caps.fs_write, haunt_dir),
            pty_times: VecDeque::new(),
            sidebar: match &core {
                Some(c) if caps.sidebar => Some(c.attach_sidebar()),
                Some(c) => {
                    c.forget_arrangement_of(id);
                    None
                }
                None => None,
            },
            core,
        }
    }

    /// Gives up the sidebar: a disabled, reloaded or dropped instance's arrangement goes with it.
    fn release_sidebar(&mut self) {
        if let (Some(core), Some(token)) = (&self.core, self.sidebar.take()) {
            core.detach_sidebar(token);
        }
    }

    fn push_log(&mut self, line: String) {
        if self.logs.len() < MAX_LOGS {
            self.logs.push(line);
        }
    }

    fn request(&mut self, r: HostRequest) -> Result<(), String> {
        if self.outbox.len() >= MAX_OUTBOX {
            return Err("too many pending requests".into());
        }
        self.outbox.push(r);
        Ok(())
    }

    fn pty_rate_ok(&mut self) -> bool {
        let now = Instant::now();
        while self.pty_times.front().is_some_and(|t| now.duration_since(*t) >= Duration::from_secs(1)) {
            self.pty_times.pop_front();
        }
        if self.pty_times.len() >= PTY_PER_SEC {
            return false;
        }
        self.pty_times.push_back(now);
        true
    }

    fn register(&mut self, id: String, title: String, default_key: Option<String>, is_mode: bool) {
        self.palette.retain(|p| !(p.id == id && p.is_mode == is_mode));
        if self.palette.len() >= MAX_PALETTE {
            self.push_log(format!("warn palette: more than {MAX_PALETTE} entries, {id} dropped"));
            return;
        }
        let (id, title, default_key) = (clip(id), clip(title), default_key.map(clip));
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
}

impl wnotify::Host for HostState {
    fn notify(&mut self, title: String, body: String, actions: Vec<wnotify::Action>, binding: Option<String>) -> Result<(), String> {
        if actions.len() > 4 {
            return Err("at most 4 actions".into());
        }
        let actions = actions.into_iter().map(|a| NotifyAction { id: clip(a.id), title: clip(a.title) }).collect();
        let r = HostRequest::Notify { plugin_id: self.id.clone(), title: clip(title), body: clip(body), actions, binding: binding.map(clip) };
        self.request(r)
    }
}

impl wpty::Host for HostState {
    fn answer(&mut self, surface: String, allow: bool, request_id: u64) -> Result<(), String> {
        if !self.pty_rate_ok() {
            return Err(format!("pty rate limit ({PTY_PER_SEC}/s)"));
        }
        let surface = clip(surface);
        self.push_log(format!("info pty.answer surface={surface} allow={allow} request={request_id}"));
        self.request(HostRequest::PtyAnswer { plugin_id: self.id.clone(), surface, allow, request_id })
    }
}

impl wdec::Host for HostState {
    fn query(&mut self, text: String, limit: u32) -> Vec<wdec::Decision> {
        let Some(core) = &self.core else { return Vec::new() };
        core.decisions(&text, limit.min(MAX_DECISIONS))
            .into_iter()
            .map(|d| wdec::Decision {
                at_ms: d.at_ms,
                surface_id: d.surface_id,
                tool: d.tool,
                preview: d.preview,
                cwd: d.cwd,
                outcome: match d.outcome {
                    Outcome::AllowedInHaunt => wdec::Outcome::AllowedInHaunt,
                    Outcome::DeniedInHaunt => wdec::Outcome::DeniedInHaunt,
                    Outcome::AllowedByPlugin { plugin_id } => wdec::Outcome::AllowedByPlugin(plugin_id),
                    Outcome::DeniedByPlugin { plugin_id } => wdec::Outcome::DeniedByPlugin(plugin_id),
                    Outcome::AnsweredInTerminal => wdec::Outcome::AnsweredInTerminal,
                    Outcome::Superseded => wdec::Outcome::Superseded,
                },
                agent: d.agent.id().to_owned(),
            })
            .collect()
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
            self.store.data_mut().release_sidebar();
            PluginError(why)
        })
    }

    pub fn init(&mut self, settings_json: &str) -> Result<(), PluginError> {
        self.call(|b, s| b.call_init(s, settings_json))
    }

    /// Only a `verified` event's cwd widens the plugin's `${cwd}` grant; anything in the pty can
    /// forge the rest.
    pub fn on_event(&mut self, event: &AgentEvent, verified: bool) -> Result<Option<Decoration>, PluginError> {
        if verified && let Some(cwd) = &event.cwd {
            self.store.data_mut().fs.add_cwd(cwd);
        }
        let summary = match &event.kind {
            EventKind::TaskCreated { subject, .. } => subject.clone(),
            EventKind::TaskUpdated { status, .. } => Some(status.clone()),
            EventKind::ToolRan { tool } => Some(tool.tool_name.clone()),
            EventKind::SubagentTool { tool_name } => Some(tool_name.clone()),
            _ => None,
        };
        let ev = wit::AgentEvent {
            kind: event.kind.name().to_owned(),
            session_id: event.session_id.clone(),
            agent_id: event.agent_id.clone(),
            cwd: event.cwd.clone(),
            summary,
            verified,
        };
        let out = self.call(|b, s| b.call_on_event(s, &ev))?;
        Ok(out.map(|d| Decoration {
            badge: d.badge,
            style: match d.style {
                wit::Style::Meta => "meta",
                wit::Style::Needs => "needs",
                wit::Style::Dot => "dot",
                wit::Style::HollowDot => "hollow-dot",
                wit::Style::Kbd => "kbd",
                wit::Style::Mono => "mono",
            }
            .to_owned(),
            meta_suffix: d.meta_suffix,
        }))
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

    pub fn on_action(&mut self, action_id: &str, payload: &str) -> Result<(), PluginError> {
        self.call(|b, s| b.call_on_action(s, action_id, payload))
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

    pub fn take_logs(&mut self) -> Vec<String> {
        std::mem::take(&mut self.store.data_mut().logs)
    }

    pub fn take_requests(&mut self) -> Vec<HostRequest> {
        std::mem::take(&mut self.store.data_mut().outbox)
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
        if caps.notifications {
            wnotify::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.pty_write {
            wpty::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
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
        if caps.fs_read_granted() || caps.fs_write_granted() {
            let mut fs = l.instance("haunt:plugin/fs@0.3.0")?;
            if caps.fs_read_granted() {
                fs.func_wrap("read", |s: StoreContextMut<'_, HostState>, (path,): (String,)| Ok((s.data().fs.read(&path),)))?;
                fs.func_wrap("list", |s: StoreContextMut<'_, HostState>, (path,): (String,)| Ok((s.data().fs.list(&path),)))?;
            }
            if caps.fs_write_granted() {
                fs.func_wrap("write", |s: StoreContextMut<'_, HostState>, (path, data): (String, Vec<u8>)| {
                    Ok((s.data().fs.write(&path, &data),))
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
        (import "haunt:plugin/fs@0.3.0" (instance
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
            r#"(component (import "haunt:plugin/pty@0.3.0" (instance
                (export "answer" (func (param "surface" string) (param "allow" bool) (param "request-id" u64) (result (result (error string))))))))"#,
        )
        .unwrap();
        assert!(host.check_links(&pty, &Capabilities::default()).is_err());
        host.check_links(&pty, &Capabilities { pty_write: true, ..Default::default() }).unwrap();

        let text = Component::new(
            &host.engine,
            r#"(component (import "haunt:plugin/pty@0.3.0" (instance
                (export "text" (func (param "surface" string) (param "text" string) (result (result (error string))))))))"#,
        )
        .unwrap();
        let e = host.check_links(&text, &Capabilities { pty_write: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("text"), "free-form pty text is gone: {e}");

        let notify = Component::new(
            &host.engine,
            r#"(component (import "haunt:plugin/notify@0.3.0" (instance
                (type $r (record (field "id" string) (field "title" string)))
                (export "action" (type $a (eq $r)))
                (export "notify" (func (param "title" string) (param "body" string) (param "actions" (list $a))
                    (param "binding" (option string)) (result (result (error string))))))))"#,
        )
        .unwrap();
        assert!(host.check_links(&notify, &Capabilities::default()).is_err());
        host.check_links(&notify, &Capabilities { notifications: true, ..Default::default() }).unwrap();
    }

    const DECISIONS_IMPORT: &str = r#"(component (import "haunt:plugin/decisions@0.3.0" (instance
        (type $o (variant (case "allowed-in-haunt") (case "denied-in-haunt") (case "allowed-by-plugin" string)
            (case "denied-by-plugin" string) (case "answered-in-terminal") (case "superseded")))
        (export "outcome" (type $oe (eq $o)))
        (type $d (record (field "at-ms" u64) (field "surface-id" string) (field "tool" string) (field "preview" string)
            (field "cwd" (option string)) (field "outcome" $oe) (field "agent" string)))
        (export "decision" (type $de (eq $d)))
        (export "query" (func (param "text" string) (param "limit" u32) (result (list $de)))))))"#;

    const PROPOSE_IMPORT: &str = r#"(component (import "haunt:plugin/allowlist@0.3.0" (instance
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
                format!(r#"(component (import "haunt:plugin/{iface}@0.3.0" (instance (export "{func}" (func (param "x" string))))))"#),
            )
            .unwrap();
            let e = host.check_links(&c, &both).unwrap_err().0;
            assert!(e.contains(func), "{iface}.{func}: {e}");
        }
    }

    #[test]
    fn the_sidebar_import_needs_its_capability() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/sidebar@0.3.0" (instance (export "clear" (func)))))"#).unwrap();
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
        let mut st = HostState::new("dev.haunt.tabs", &sidebar, None, None, Some(core.handle()));
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
        assert!(other.arrange(arrangement.clone()).unwrap_err().contains("dev.haunt.tabs"), "one arranger at a time");
        other.clear();
        assert_eq!(core.snapshot().groups[1].id, "pinned", "only the owner clears");
        let mut no_cap = HostState::new("dev.x.nocap", &Capabilities::default(), None, None, Some(core.handle()));
        assert!(no_cap.arrange(arrangement.clone()).unwrap_err().contains("sidebar capability"));
        st.clear();
        assert_eq!(core.snapshot().groups[1].id, "running");
        st.arrange(arrangement.clone()).unwrap();

        // A reload: the new instance takes over, and dropping the old one leaves the new arrangement.
        let mut reloaded = HostState::new("dev.haunt.tabs", &sidebar, None, None, Some(core.handle()));
        reloaded.arrange(wside::Arrangement { flat: true, ..arrangement.clone() }).unwrap();
        drop(st);
        assert_eq!(core.snapshot().groups[1].id, "pinned", "the reloaded instance's arrangement stays");
        reloaded.release_sidebar();
        assert_eq!(core.snapshot().groups[1].id, "running", "a disabled instance's arrangement goes with it");
        assert!(reloaded.arrange(arrangement.clone()).is_err(), "and it can't arrange again");

        let mut dropped = HostState::new("dev.haunt.tabs", &sidebar, None, None, Some(core.handle()));
        dropped.arrange(arrangement).unwrap();
        drop(dropped);
        assert_eq!(core.snapshot().groups[1].id, "running", "a removed or reloaded plugin's arrangement goes");
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
