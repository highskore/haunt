//! UniFFI surface of haunt-core for the Swift app.

#[cfg(feature = "plugins")]
use std::sync::Mutex;

pub use haunt_core::{AgentEvent, EventKind, ParseError};

uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn parse_osc(title: String, body: String) -> Result<AgentEvent, ParseError> {
    haunt_core::parse_osc(&title, &body)
}

#[uniffi::export]
pub fn event_name(event: AgentEvent) -> String {
    event.kind.name().to_owned()
}

pub use haunt_core::{
    Agent, AllowSuggestion, CoreError, Decision, Outcome, PendingRequest, Progress, Row, RowKind, SidebarGroup, SidebarSnapshot, Subrow,
    SurfaceEnv,
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

    pub fn answer_permission(&self, surface_id: String, request_key: u64, allow: bool) -> Option<Vec<u8>> {
        self.core.answer_permission(&surface_id, request_key, allow)
    }

    /// Call on every keyDown routed to the surface, before it reaches the pty.
    pub fn on_user_input(&self, surface_id: String) {
        self.core.on_user_input(&surface_id);
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
pub use haunt_core::plugins::{HostRequest, NotifyAction, PaletteItem};
#[cfg(feature = "plugins")]
pub use haunt_core::ptygate::PtyWrite;

#[cfg(feature = "plugins")]
#[uniffi::export]
impl HauntCore {
    /// For each request from `HauntPlugins.takeRequests()`: the bytes to write, or nil to write nothing.
    pub fn gate_plugin_request(&self, request: HostRequest) -> Option<PtyWrite> {
        self.core.gate_plugin_request(&request)
    }
}

/// Installed plugins from `<haunt_dir>/plugins`, each with only the capabilities the user granted.
#[cfg(feature = "plugins")]
#[derive(uniffi::Object)]
pub struct HauntPlugins {
    set: Mutex<haunt_core::plugin_store::PluginSet>,
}

#[cfg(feature = "plugins")]
#[uniffi::export]
impl HauntPlugins {
    /// Plugins that fail verification (hash mismatch, link error) are skipped and listed in `load_errors`.
    #[uniffi::constructor]
    pub fn load(haunt_dir: String) -> Result<std::sync::Arc<Self>, HostError> {
        let fail = |e: haunt_core::plugin_store::StoreError| HostError::Failed { reason: e.to_string() };
        let host = haunt_core::plugins::PluginHost::new()?;
        let set = haunt_core::plugin_store::Store::open(haunt_dir.as_ref()).map_err(fail)?.load_all(&host).map_err(fail)?;
        Ok(std::sync::Arc::new(Self { set: Mutex::new(set) }))
    }

    pub fn load_errors(&self) -> Vec<String> {
        haunt_core::sync::lock(&self.set).errors().to_vec()
    }

    /// No mode: registered commands and modes. A mode word: that mode's items for `query`.
    pub fn palette_items(&self, mode: Option<String>, query: String) -> Vec<PaletteItem> {
        haunt_core::sync::lock(&self.set).palette_items(mode.as_deref(), &query)
    }

    pub fn invoke_palette_item(&self, plugin_id: String, item_id: String) -> Result<(), HostError> {
        Ok(haunt_core::sync::lock(&self.set).invoke(&plugin_id, &item_id)?)
    }

    /// Notifications and pty writes plugins asked for since the last call.
    pub fn take_requests(&self) -> Vec<HostRequest> {
        haunt_core::sync::lock(&self.set).take_requests()
    }
}
