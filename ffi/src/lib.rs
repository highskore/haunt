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
    AllowSuggestion, CoreError, Decision, Outcome, PendingRequest, Progress, Row, RowKind, SidebarGroup, SidebarSnapshot, Subrow,
    SurfaceEnv,
};

/// Called after any change to the snapshot, on the thread that caused it (often the socket thread).
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

    pub fn register_surface(&self, cwd: String) -> SurfaceEnv {
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

    pub fn set_listener(&self, listener: Box<dyn CoreListener>) {
        self.core.set_listener(std::sync::Arc::new(move || listener.changed()));
    }

    pub fn answer_permission(&self, surface_id: String, request_key: u64, allow: bool) -> Option<Vec<u8>> {
        self.core.answer_permission(&surface_id, request_key, allow)
    }

    pub fn decisions(&self, query: String, limit: u32) -> Vec<Decision> {
        self.core.decisions(&query, limit)
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
pub use haunt_core::plugins::{Decoration, LoadStats};

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

/// One loaded plugin; wasmtime stores are not Sync, hence the mutex.
#[cfg(feature = "plugins")]
#[derive(uniffi::Object)]
pub struct PluginHandle {
    plugin: Mutex<haunt_core::plugins::LoadedPlugin>,
    stats: LoadStats,
}

#[cfg(feature = "plugins")]
#[uniffi::export]
impl PluginHandle {
    #[uniffi::constructor]
    pub fn load(wasm_path: String, cache_dir: String) -> Result<std::sync::Arc<Self>, HostError> {
        let host = haunt_core::plugins::PluginHost::new()?;
        let (plugin, stats) = host.load(wasm_path.as_ref(), cache_dir.as_ref())?;
        Ok(std::sync::Arc::new(Self { plugin: Mutex::new(plugin), stats }))
    }

    pub fn stats(&self) -> LoadStats {
        self.stats.clone()
    }

    pub fn on_event(&self, event: AgentEvent) -> Result<Option<Decoration>, HostError> {
        Ok(self.plugin.lock().unwrap().on_event(&event)?)
    }

    pub fn take_logs(&self) -> Vec<String> {
        self.plugin.lock().unwrap().take_logs()
    }
}

#[cfg(feature = "plugins")]
pub use haunt_core::plugins::{HostRequest, NotifyAction, PaletteItem};

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
        self.set.lock().unwrap().errors().to_vec()
    }

    /// No mode: registered commands and modes. A mode word: that mode's items for `query`.
    pub fn palette_items(&self, mode: Option<String>, query: String) -> Vec<PaletteItem> {
        self.set.lock().unwrap().palette_items(mode.as_deref(), &query)
    }

    pub fn invoke_palette_item(&self, plugin_id: String, item_id: String) -> Result<(), HostError> {
        Ok(self.set.lock().unwrap().invoke(&plugin_id, &item_id)?)
    }

    /// Notifications and pty writes plugins asked for since the last call.
    pub fn take_requests(&self) -> Vec<HostRequest> {
        self.set.lock().unwrap().take_requests()
    }
}

pub use haunt_core::intake::Delivery;

#[uniffi::export(with_foreign)]
pub trait IntakeListener: Send + Sync {
    /// Called on the intake thread; hop to the main actor before touching UI.
    fn on_delivery(&self, delivery: Delivery);
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum IntakeBindError {
    #[error("{reason}")]
    Failed { reason: String },
}

/// Hook-event socket at `<dir>/sock`; dropping it closes and unlinks the socket.
#[derive(uniffi::Object)]
pub struct HauntIntake {
    inner: haunt_core::intake::Intake,
}

#[uniffi::export]
impl HauntIntake {
    #[uniffi::constructor]
    pub fn bind(dir: String, listener: std::sync::Arc<dyn IntakeListener>) -> Result<std::sync::Arc<Self>, IntakeBindError> {
        let sink: haunt_core::intake::Sink = std::sync::Arc::new(move |d| listener.on_delivery(d));
        haunt_core::intake::Intake::bind(dir.as_ref(), Default::default(), sink)
            .map(|inner| std::sync::Arc::new(Self { inner }))
            .map_err(|e| IntakeBindError::Failed { reason: e.to_string() })
    }

    pub fn path(&self) -> String {
        self.inner.path().display().to_string()
    }

    pub fn register_surface(&self, surface_id: String, nonce: String) {
        self.inner.register_surface(&surface_id, &nonce);
    }

    pub fn unregister_surface(&self, surface_id: String) {
        self.inner.unregister_surface(&surface_id);
    }
}
