//! haunt-core: the UI-free model shared by every platform shell.

pub mod event;
#[cfg(feature = "plugins")]
pub mod plugins;

pub use event::{AgentEvent, EventKind, ParseError, parse_osc};

#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();
