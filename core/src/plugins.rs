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

use crate::event::{EventKind, is_hidden, visible};
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
    allowlist as wallow, clock as wclock, exec as wexec, hold as whold, keys as wkeys, top_row as wtop, decisions as wdec, kv as wkv, log as wlog, notify as wnotify, palette as wpal, pty as wpty, rows as wrows,
    sidebar as wside, theme as wtheme, timer as wtimer, typing as wtyping, types as wit,
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
const MAX_PALETTE: usize = 64;
const MAX_OUTBOX: usize = 256;
const MAX_NOTIFIED: usize = 64;
pub const MAX_KEYS: usize = 8;
const MAX_LOGS: usize = 1000;
const MAX_STR: usize = 4096;
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

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct NotifyAction {
    pub id: String,
    pub title: String,
}

/// Side effects a plugin asked for; the app drains and performs them. A `PtyAnswer` or `PtyType`
/// becomes bytes only through `Core::gate_plugin_request` (`ptygate`).
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum HostRequest {
    Notify { plugin_id: String, title: String, body: String, actions: Vec<NotifyAction>, binding: Option<String> },
    PtyAnswer { plugin_id: String, surface: String, allow: bool, request_id: u64 },
    PtyType { plugin_id: String, surface: String, text: String, enter: bool },
    /// Show `panel`, or replace the one this plugin showed with its id.
    ShowPanel { plugin_id: String, plugin_name: String, panel: Panel },
    /// Hold haunt's and other plugins' notifications (never a permission prompt's) for `minutes`, then
    /// show one summary; the app releases it then itself.
    HoldNotifications { plugin_id: String, plugin_name: String, minutes: u32 },
    ReleaseNotifications { plugin_id: String },
    ClosePanel { plugin_id: String, id: String },
    /// The plugin bound or unbound a key: the app rebuilds its key map from `PluginSet::keys`.
    KeysChanged { plugin_id: String },
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
    /// (id, canonical chord) from `keys.bind`.
    keys: Vec<(String, String)>,
    /// The manifest's `exec` names.
    exec: Vec<String>,
    /// Jobs started and not yet reported.
    exec_jobs: Vec<u64>,
}

impl Drop for HostState {
    fn drop(&mut self) {
        self.release_sidebar();
        self.release_rows();
        if let Some(c) = &self.core {
            c.release_sheet(&self.id, None);
            c.release_notifications(&self.id);
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
            wasi: WasiCtx::builder().wall_clock(CoarseWall).monotonic_clock(CoarseMono(Instant::now())).build(),
            table: ResourceTable::new(),
            limits: StoreLimitsBuilder::new().memory_size(MEMORY_CAP).instances(16).tables(64).memories(4).build(),
            kv: Kv::open(kv_path),
            palette: Vec::new(),
            outbox: Vec::new(),
            fs: FsScope::new(&cwd_globs(&caps.fs_read), &cwd_globs(&caps.fs_write), haunt_dir),
            pty_times: VecDeque::new(),
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
            keys: Vec::new(),
            exec: caps.exec.clone(),
            exec_jobs: Vec::new(),
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

    /// An id with a hidden character is refused, and a title loses its hidden characters and is cut to
    /// `MAX_TITLE` characters, so no plugin can disguise a command or push the palette around.
    fn register(&mut self, id: String, title: String, default_key: Option<String>, is_mode: bool) {
        let title: String = title.chars().filter(|&c| !is_hidden(c)).take(MAX_TITLE).collect();
        if id.is_empty() || id.chars().any(is_hidden) || title.trim().is_empty() {
            self.push_log(format!("warn palette: {:?} refused: an empty or hidden-character id, or an empty title", visible(&id)));
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
        let actions: Vec<NotifyAction> = actions.into_iter().map(|a| NotifyAction { id: clip(a.id), title: clip(a.title) }).collect();
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
        self.push_log(format!("info pty.answer surface={surface} allow={allow} request={request_id}"));
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
        self.push_log(format!("info typing surface={surface} bytes={} enter={enter}", text.len()));
        self.request(HostRequest::PtyType { plugin_id: self.id.clone(), surface, text, enter })
    }
}

impl wdec::Host for HostState {
    fn query(&mut self, text: String, limit: u32) -> Vec<wdec::Decision> {
        let Some(core) = &self.core else { return Vec::new() };
        // The 0.4 `outcome` variant has no case for a refused plugin answer; those rows stay out.
        core.decisions_where(&text, limit.min(MAX_DECISIONS), |d| !matches!(d.outcome, Outcome::RefusedPlugin { .. }))
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

/// Haunt's own row status words: a label saying one could pass for it.
const STATUS_WORDS: [&str; 8] = ["needs you", "waiting", "approve", "allow", "deny", "running", "idle", "done"];

/// Whether `label`'s letters and digits spell a status word, ignoring case, spacing and punctuation; any
/// non-ASCII letter counts as a match, so a lookalike from another script can't slip by.
fn says_status(label: &str) -> bool {
    let key: Vec<char> = label.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect();
    STATUS_WORDS.iter().any(|w| {
        let w: Vec<char> = w.chars().filter(char::is_ascii_alphanumeric).collect();
        key.len() == w.len() && key.iter().zip(&w).all(|(k, w)| k == w || !k.is_ascii())
    })
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
    Ok(Decoration {
        label,
        label_tone: tone(d.label_tone),
        suffix: plain_opt(d.suffix, if d.scroll { decorate::TICKER_MAX } else { decorate::SUFFIX_MAX }),
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
        // Unasked, a sheet would take the keys the user is typing; it comes up as a card instead.
        if panel.placement == PanelPlacement::Sheet && !self.user_call {
            panel.placement = PanelPlacement::Card;
        }
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

    fn close(&mut self, id: String) {
        self.release_sheet(&id);
        if self.panels.close(&id) {
            let _ = self.request(HostRequest::ClosePanel { plugin_id: self.id.clone(), id });
        }
    }
}

impl HostState {
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
        if !std::mem::take(&mut self.keys).is_empty() {
            self.outbox.push(HostRequest::KeysChanged { plugin_id: self.id.clone() });
        }
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
        let core = self.core.as_ref().ok_or("no haunt core")?;
        let opened = core.opened_in(&surface).ok_or("no such tab")?;
        let dir = self.fs.project_folder(&opened).ok_or("the tab's folder is not a project folder inside your home folder")?;
        let sink = core.exec_sink().ok_or("commands are off")?;
        let job = NEXT_JOB.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let plugin_id = self.id.clone();
        std::thread::Builder::new()
            .name("haunt-exec".into())
            .spawn(move || sink(ExecDone { plugin_id, job, outcome: px::run(&cmd, &dir) }))
            .map_err(|e| e.to_string())?;
        self.exec_jobs.push(job);
        Ok(job)
    }
}

pub const HOLD_MAX_MINUTES: u32 = 240;

impl whold::Host for HostState {
    fn start(&mut self, minutes: u32) -> Result<(), String> {
        if !(1..=HOLD_MAX_MINUTES).contains(&minutes) {
            return Err(format!("a hold is 1 to {HOLD_MAX_MINUTES} minutes"));
        }
        if self.outbox.len() >= MAX_OUTBOX {
            return Err("too many pending requests".into());
        }
        let core = self.core.as_ref().ok_or("no haunt core")?;
        core.hold_notifications(&self.id, Instant::now() + Duration::from_secs(u64::from(minutes) * 60))?;
        let (plugin_id, plugin_name) = (self.id.clone(), self.name.clone());
        self.request(HostRequest::HoldNotifications { plugin_id, plugin_name, minutes })
    }

    fn release(&mut self) {
        self.release_hold();
    }
}

pub const TICK_MIN_SECS: u32 = 15;
const TICK_MAX_SECS: u32 = 86_400;

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

/// Characters of a command, path or summary a plugin gets.
pub const EVENT_TEXT: usize = 1024;

/// One line of plain text: whitespace becomes a space, other hidden characters go, at most `max` characters.
pub fn plain(s: &str, max: usize) -> String {
    s.chars().map(|c| if c.is_whitespace() { ' ' } else { c }).filter(|&c| !is_hidden(c)).take(max).collect()
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
        summary: summary.map(|s| plain(&s, EVENT_TEXT)),
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
            PluginError(why)
        })
    }

    pub fn init(&mut self, settings_json: &str) -> Result<(), PluginError> {
        self.call(|b, s| b.call_init(s, settings_json))
    }

    /// A `verified` event widens the plugin's `${cwd}` grant to the folder the app opened the tab in,
    /// never to the cwd the event names.
    pub fn on_event(&mut self, t: &Tapped) -> Result<(), PluginError> {
        if t.verified {
            self.store.data_mut().fs.add_cwd(&t.tab_cwd);
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

    /// A job this instance started finished: `on-exec(job, outcome)`. Another instance's job is dropped.
    pub fn exec_done(&mut self, job: u64, outcome: Result<crate::plugin_exec::ExecOutput, String>) -> Result<(), PluginError> {
        let jobs = &mut self.store.data_mut().exec_jobs;
        let Some(i) = jobs.iter().position(|j| *j == job) else { return Ok(()) };
        jobs.remove(i);
        let outcome = outcome.map(|o| wexec::Output { status: o.status, stdout: o.stdout, stderr: o.stderr, truncated: o.truncated });
        self.call(|b, s| b.call_on_exec(s, job, outcome.as_ref().map_err(String::as_str)))
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
        self.user_call(|p| p.on_action(action, &format!("panel:{id}")))
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
    /// `on-action(action_id, binding)`, only for an action this plugin posted in this run.
    pub fn notify_action(&mut self, action_id: &str, binding: &str) -> Result<(), PluginError> {
        if !self.store.data().notified.iter().any(|(a, b)| a == action_id && b == binding) {
            return Err(PluginError(format!("no notification action {action_id:?}")));
        }
        self.on_action(action_id, binding)
    }

    /// The user ran palette item `action_id` (from the palette or its key): `typing` may type into the
    /// tab focused now, until the call returns, but only if `terminal_shown`: none while the agents view
    /// or the review screen hides the terminal.
    pub fn run_command(&mut self, action_id: &str, terminal_shown: bool) -> Result<(), PluginError> {
        self.run_user_action(action_id, "", terminal_shown)
    }

    /// The user pressed (`down`) or released one of this plugin's keys: `on-action(id, "key-down" or
    /// "key-up")`, which may type like a command.
    pub fn key_action(&mut self, id: &str, down: bool, terminal_shown: bool) -> Result<(), PluginError> {
        if !self.store.data().keys.iter().any(|(i, _)| i == id) {
            return Err(PluginError(format!("no key {id:?}")));
        }
        self.run_user_action(id, if down { "key-down" } else { "key-up" }, terminal_shown)
    }

    pub fn keys(&self) -> Vec<PluginKey> {
        let id = self.id();
        self.store.data().keys.iter().map(|(i, c)| PluginKey { plugin_id: id.to_owned(), id: i.clone(), chord: c.clone() }).collect()
    }

    fn run_user_action(&mut self, action_id: &str, payload: &str, terminal_shown: bool) -> Result<(), PluginError> {
        let data = self.store.data_mut();
        data.typing_into = data.core.as_ref().and_then(CoreHandle::selected_surface).filter(|_| terminal_shown);
        let res = self.user_call(|p| p.on_action(action_id, payload));
        self.store.data_mut().typing_into = None;
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
        if caps.panel {
            wpanel::add_to_linker::<_, HasSelf<_>>(&mut l, |s| s)?;
        }
        if caps.fs_read_granted() || caps.fs_write_granted() {
            let mut fs = l.instance("haunt:plugin/fs@0.5.0")?;
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
        Tapped { surface: "tab-1".into(), event, verified, tab_cwd: "/w".into(), request_key }
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
    fn one_plugin_holds_notifications_at_a_time_and_a_dropped_one_lets_go() {
        use whold::Host as _;
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/hold@0.5.0" (instance (export "release" (func)))))"#).unwrap();
        assert!(host.check_links(&c, &Capabilities { notifications: true, ..Default::default() }).unwrap_err().0.contains("haunt:plugin/hold"));
        host.check_links(&c, &Capabilities { notify_hold: true, ..Default::default() }).unwrap();

        let core = crate::Core::new(&*tempdir("hold"));
        let caps = Capabilities { notify_hold: true, ..Default::default() };
        let mut focus = HostState::new("dev.x.focus", &caps, None, None, Some(core.handle()));
        let mut other = HostState::new("dev.x.other", &caps, None, None, Some(core.handle()));
        assert!(focus.start(0).is_err() && focus.start(HOLD_MAX_MINUTES + 1).is_err());
        focus.start(25).unwrap();
        assert!(other.start(5).unwrap_err().contains("dev.x.focus"));
        other.release();
        assert!(matches!(&focus.outbox[..], [HostRequest::HoldNotifications { plugin_id, minutes: 25, .. }] if plugin_id == "dev.x.focus"));
        assert!(other.outbox.is_empty(), "releasing someone else's hold does nothing");
        focus.release();
        assert!(matches!(focus.outbox.last(), Some(HostRequest::ReleaseNotifications { plugin_id }) if plugin_id == "dev.x.focus"));
        other.start(5).unwrap();
        drop(other);
        focus.start(5).unwrap();
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
    fn exec_runs_only_granted_commands_in_a_tabs_project_folder() {
        use wexec::Host as _;
        let core = crate::Core::new(&*tempdir("exec"));
        let caps = Capabilities { exec: vec!["git-status".into()], ..Default::default() };
        let mut p = HostState::new("dev.x.ci", &caps, None, None, Some(core.handle()));
        let tab = core.register_surface("/tmp").unwrap().surface_id;
        assert!(p.run(tab.clone(), wexec::Command::GitHead).unwrap_err().contains("not in this plugin's exec list"));
        assert_eq!(p.run("nope".into(), wexec::Command::GitStatus).unwrap_err(), "no such tab");
        assert!(p.run(tab, wexec::Command::GitStatus).unwrap_err().contains("not a project folder"), "/tmp is outside home");
        p.exec_jobs = vec![1, 2];
        assert!(p.run("nope".into(), wexec::Command::GitStatus).unwrap_err().contains("at most 2"));
    }

    #[test]
    fn row_labels_cant_pass_for_haunts_status() {
        let d = |label: &str, t: wrows::Tone| wrows::Decoration {
            label: Some(label.into()), label_tone: t, suffix: None, suffix_tone: wrows::Tone::Dim, scroll: false, bar: None,
            spark: Some(wrows::Spark { points: vec![1, 2], tone: wrows::Tone::Text }),
        };
        assert!(decoration(d("CI 7/9", wrows::Tone::Text)).unwrap_err().contains("never text"));
        for bad in ["Needs You", "needs  you", "NEEDS\u{200b}YOU", "N-E-E-D-S you!", "n\u{0435}eds you", "\u{FF24}one", "Waiting", "approve", "Allow.", "deny", "RUNNING", "idle", "done"] {
            assert!(decoration(d(bad, wrows::Tone::Dim)).is_err(), "{bad:?}");
        }
        for ok in ["CI 7/9", "needs you later", "done 3/4", "idler", "✓"] {
            let dec = decoration(d(ok, wrows::Tone::Warn)).unwrap();
            assert_eq!(dec.spark.unwrap().tone, Tone::Text, "the sparkline may keep text");
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
        p.bind("talk".into(), "shift+cmd+u".into()).unwrap();
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
