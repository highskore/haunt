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

pub use haunt_core::{CoreError, Group, Progress, Row, RowKind, SidebarSnapshot, Subrow, SurfaceEnv};

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

    pub fn answer_permission(&self, surface_id: String, allow: bool) -> Option<Vec<u8>> {
        self.core.answer_permission(&surface_id, allow)
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
