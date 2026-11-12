//! UniFFI surface of haunt-core for the Swift app.

#[cfg(feature = "plugins")]
use std::sync::Mutex;

pub use haunt_core::{AgentEvent, EventKind, ParseError};

uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn parse_osc(title: String, body: String) -> Result<AgentEvent, ParseError> {
    haunt_core::parse_osc(&title, &body)
}

/// The host's own text for a plugin refusal.
#[uniffi::export]
pub fn refusal_text(reason: Refusal) -> String {
    reason.text().to_owned()
}

#[uniffi::export]
pub fn event_name(event: AgentEvent) -> String {
    event.kind.name().to_owned()
}

pub use haunt_core::{
    Agent, AllowSuggestion, ColorStyle, CommandOutcome, CoreError, Decision, Outcome, PendingRequest, PluginRefusal, Progress, Refusal, ReviewTurn,
    Row, RowKind, SidebarGroup, SidebarSnapshot, Subrow, SurfaceEnv, TabColor, TurnCommand, TurnSubagent, TurnTask,
};

/// Called after a change to the snapshot, on the thread that caused it (often the socket thread);
/// then not again until the next `snapshot`.
#[uniffi::export(callback_interface)]
pub trait CoreListener: Send + Sync {
    fn changed(&self);
}

/// The sidebar model and hook intake. See docs/core-api.md.
#[derive(uniffi::Object)]
pub struct HauntCore {
    core: haunt_core::Core,
}

#[uniffi::export]
impl HauntCore {
    #[uniffi::constructor]
    pub fn new(config_dir: String) -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self { core: haunt_core::Core::new(config_dir) })
    }

    pub fn start(&self) -> Result<(), CoreError> {
        self.core.start()
    }

    pub fn register_surface(&self, cwd: String) -> Result<SurfaceEnv, CoreError> {
        self.core.register_surface(&cwd)
    }

    pub fn unregister_surface(&self, surface_id: String) {
        self.core.unregister_surface(&surface_id);
    }

    /// `title` and `git_branch` are ignored (see `Core::set_surface_info`). Never blocks on a lookup
    /// running for another surface, so any thread may call it.
    pub fn set_surface_info(&self, surface_id: String, title: String, cwd: String, git_branch: Option<String>) {
        self.core.set_surface_info(&surface_id, &title, &cwd, git_branch);
    }

    pub fn select_surface(&self, surface_id: String) {
        self.core.select_surface(&surface_id);
    }

    pub fn on_osc_notification(&self, surface_id: String, title: String, body: String) {
        self.core.on_osc_notification(&surface_id, &title, &body);
    }

    pub fn snapshot(&self) -> SidebarSnapshot {
        self.core.snapshot()
    }

    pub fn snapshot_if_newer(&self, version: u64) -> Option<SidebarSnapshot> {
        self.core.snapshot_if_newer(version)
    }

    pub fn set_listener(&self, listener: Box<dyn CoreListener>) {
        self.core.set_listener(std::sync::Arc::new(move || listener.changed()));
    }

    /// True while a verified permission prompt may be on the surface's screen; only verified
    /// events clear it, so gate anything that types into the surface on this, not `needs_you`.
    pub fn has_unresolved(&self, surface_id: String) -> bool {
        self.core.has_unresolved(&surface_id)
    }

    pub fn answer_permission(&self, surface_id: String, request_key: u64, allow: bool) -> Option<Vec<u8>> {
        self.core.answer_permission(&surface_id, request_key, allow)
    }

    /// Call on every keyDown routed to the surface, before it reaches the pty.
    pub fn on_user_input(&self, surface_id: String) {
        self.core.on_user_input(&surface_id);
    }

    pub fn review_turn(&self, surface_id: String) -> Option<ReviewTurn> {
        self.core.review_turn(&surface_id)
    }

    pub fn decisions(&self, query: String, limit: u32) -> Vec<Decision> {
        self.core.decisions(&query, limit)
    }

    /// `decisions` of one tab when `surface_id` is set; the filter applies before the limit.
    pub fn decisions_in(&self, query: String, surface_id: Option<String>, limit: u32) -> Vec<Decision> {
        self.core.decisions_in(&query, surface_id.as_deref(), limit)
    }

    pub fn allow_suggestions(&self) -> Vec<AllowSuggestion> {
        self.core.allow_suggestions()
    }

    pub fn accept_allow_suggestion(&self, project: String, command: String) -> Result<(), CoreError> {
        self.core.accept_allow_suggestion(&project, &command)
    }

    pub fn dismiss_allow_suggestion(&self, project: String, command: String) {
        self.core.dismiss_allow_suggestion(&project, &command);
    }
}

#[cfg(feature = "plugins")]
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HostError {
    #[error("{reason}")]
    Failed { reason: String },
}

#[cfg(feature = "plugins")]
impl From<haunt_core::plugins::PluginError> for HostError {
    fn from(e: haunt_core::plugins::PluginError) -> Self {
        Self::Failed { reason: e.0 }
    }
}

#[cfg(feature = "plugins")]
pub use haunt_core::plugins::{HostRequest, Mark, NotifyAction, PaletteItem, RowMenuItem};
#[cfg(feature = "plugins")]
pub use haunt_core::plugin_theme::ThemeToken;
#[cfg(feature = "plugins")]
pub use haunt_core::plugin_pack::ThemeContribution;
#[cfg(feature = "plugins")]
pub use haunt_core::ptygate::PtyWrite;

#[cfg(feature = "plugins")]
#[uniffi::export]
impl HauntCore {
    /// For each request from `HauntPlugins.takeRequests()`: the bytes to write, or nil to write nothing.
    pub fn gate_plugin_request(&self, request: HostRequest) -> Option<PtyWrite> {
        self.core.gate_plugin_request(&request)
    }

    /// Plugin answers the gate refused since the last call, oldest first, to show the user.
    pub fn take_plugin_refusals(&self) -> Vec<PluginRefusal> {
        self.core.take_plugin_refusals()
    }
}

/// Installs the bundled plugin `<bundled_dir>/<id>` without a prompt. Fixtures use it; users run `haunt setup --plugins`.
#[cfg(feature = "fixtures")]
#[uniffi::export]
pub fn install_bundled_plugin(haunt_dir: String, bundled_dir: String, id: String) -> Result<(), HostError> {
    let fail = |e: haunt_core::plugin_store::StoreError| HostError::Failed { reason: e.to_string() };
    let host = haunt_core::plugins::PluginHost::new()?;
    let store = haunt_core::plugin_store::Store::open(haunt_dir.as_ref()).map_err(fail)?;
    store.install_bundled_plugin(&std::path::Path::new(&bundled_dir).join(id), &host, &mut |_| true).map_err(fail)?;
    Ok(())
}

/// What `set_config` did: whether `[plugins]` changed (so palette commands may have), and what it ignored.
#[cfg(feature = "plugins")]
#[derive(uniffi::Record)]
pub struct ConfigApplied {
    pub changed: bool,
    pub problems: Vec<String>,
}

/// Installed plugins from `<haunt_dir>/plugins`, each with only the capabilities the user granted.
#[cfg(feature = "plugins")]
#[derive(uniffi::Object)]
pub struct HauntPlugins {
    set: std::sync::Arc<Mutex<haunt_core::plugin_store::PluginSet>>,
}

#[cfg(feature = "plugins")]
#[uniffi::export]
impl HauntPlugins {
    /// Plugins that fail verification (hash mismatch, link error) are skipped and listed in `load_errors`.
    /// `core` backs the `decisions` and `allowlist` imports, and its events reach the plugins from now on.
    /// Bundled plugins (the app's own, in `bundled_dir`) the user already installed are updated first,
    /// without a prompt; new ones are installed only by `haunt setup --plugins`.
    /// `config_toml` is config.toml's text, whose `[plugins."<id>"]` tables go over each plugin's default settings.
    #[uniffi::constructor]
    pub fn load(haunt_dir: String, core: std::sync::Arc<HauntCore>, bundled_dir: Option<String>, config_toml: String) -> Result<std::sync::Arc<Self>, HostError> {
        let fail = |e: haunt_core::plugin_store::StoreError| HostError::Failed { reason: e.to_string() };
        let host = haunt_core::plugins::PluginHost::new()?;
        let store = haunt_core::plugin_store::Store::open(haunt_dir.as_ref()).map_err(fail)?;
        let bundled = bundled_dir.map_or_else(Vec::new, |d| {
            store.install_bundled(d.as_ref(), &host).unwrap_or_else(|e| vec![format!("bundled plugins: {e}")])
        });
        let config = haunt_core::plugin_settings::PluginConfig::parse(&config_toml);
        let mut set = store.load_all_with(&host, Some(&core.core.handle()), &config).map_err(fail)?;
        set.add_errors(bundled);
        let set = std::sync::Arc::new(Mutex::new(set));
        haunt_core::plugin_store::attach(&core.core, &set);
        Ok(std::sync::Arc::new(Self { set }))
    }

    pub fn load_errors(&self) -> Vec<String> {
        haunt_core::sync::lock(&self.set).errors().to_vec()
    }

    /// The themes installed data-only plugins carry, with absolute paths inside each plugin's folder.
    pub fn themes(&self) -> Vec<ThemeContribution> {
        haunt_core::sync::lock(&self.set).themes().to_vec()
    }

    /// Settings from config.toml's `[plugins."<id>"]` that were ignored, at load or the last `set_config`.
    pub fn settings_problems(&self) -> Vec<String> {
        haunt_core::sync::lock(&self.set).settings_problems().to_vec()
    }

    /// config.toml changed; plugins whose settings changed get `on-settings-changed`. A file that doesn't
    /// parse keeps every plugin's settings as they were.
    pub fn set_config(&self, config_toml: String) -> ConfigApplied {
        let mut set = haunt_core::sync::lock(&self.set);
        let changed = set.set_config(&haunt_core::plugin_settings::PluginConfig::parse(&config_toml));
        ConfigApplied { changed, problems: set.settings_problems().to_vec() }
    }

    /// No mode: registered commands and modes. A mode word: that mode's items for `query`.
    pub fn palette_items(&self, mode: Option<String>, query: String) -> Vec<PaletteItem> {
        haunt_core::sync::lock(&self.set).palette_items(mode.as_deref(), &query)
    }

    /// `terminal_shown`: the selected tab's terminal is on screen (no agents view or review over it), so a
    /// `pty_type` plugin may type into it.
    pub fn invoke_palette_item(&self, plugin_id: String, item_id: String, terminal_shown: bool) -> Result<(), HostError> {
        Ok(haunt_core::sync::lock(&self.set).invoke(&plugin_id, &item_id, terminal_shown)?)
    }

    /// Notifications and pty writes plugins asked for since the last call. Never waits: while a
    /// plugin is busy with an event it returns none, and the listener fires again once it is done.
    pub fn take_requests(&self) -> Vec<HostRequest> {
        haunt_core::plugin_store::take_requests_now(&self.set)
    }

    /// Plugin entries for a row's context menu, built when the menu opens.
    pub fn row_menu_items(&self, surface_id: String) -> Vec<RowMenuItem> {
        haunt_core::sync::lock(&self.set).row_menu(&surface_id)
    }

    pub fn invoke_row_menu_item(&self, plugin_id: String, item_id: String, surface_id: String) -> Result<(), HostError> {
        Ok(haunt_core::sync::lock(&self.set).invoke_row_item(&plugin_id, &item_id, &surface_id)?)
    }

    /// A button on a plugin's panel, or the user closing it (`action` empty); see `HostRequest::ShowPanel`.
    pub fn panel_action(&self, plugin_id: String, panel_id: String, action: String) -> Result<(), HostError> {
        Ok(haunt_core::sync::lock(&self.set).panel_action(&plugin_id, &panel_id, &action)?)
    }

    /// A drag dropped `surface_id` into `SidebarGroup.id` `group_id`, above `before_surface_id` (nil: at the end).
    pub fn row_moved(&self, surface_id: String, group_id: String, before_surface_id: Option<String>) {
        haunt_core::sync::lock(&self.set).row_moved(&surface_id, &group_id, before_surface_id.as_deref());
    }

    /// The app switched theme. Until the first call plugins see "default", the colours in design/tokens.json.
    pub fn set_theme(&self, name: String, tokens: Vec<ThemeToken>) -> Result<(), HostError> {
        haunt_core::sync::lock(&self.set).set_theme(&name, tokens).map_err(|reason| HostError::Failed { reason })
    }
}
