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
