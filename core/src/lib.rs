//! haunt-core: the UI-free model shared by every platform shell.

pub mod event;
pub mod intake;
#[cfg(feature = "plugins")]
pub mod plugin_cache;
#[cfg(feature = "plugins")]
pub mod plugins;

pub use event::{AgentEvent, EventKind, ParseError, parse_body, parse_osc};

#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();
