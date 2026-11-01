//! UniFFI surface of haunt-core for the Swift app.

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
