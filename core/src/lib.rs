//! haunt-core: the UI-free model shared by every platform shell.

pub mod allowlist;
pub mod ctl;
pub mod decisions;
pub mod event;
pub mod git;
mod ids;
pub mod intake;
pub mod layout;
pub mod model;
#[cfg(feature = "plugins")]
pub mod plugin_cache;
#[cfg(feature = "plugins")]
pub mod plugin_fs;
#[cfg(feature = "plugins")]
pub mod plugin_manifest;
#[cfg(feature = "plugins")]
pub mod plugin_store;
#[cfg(feature = "plugins")]
pub mod plugins;
pub mod progress;
#[cfg(feature = "plugins")]
pub mod ptygate;
pub mod session;

pub use allowlist::AllowSuggestion;
pub use decisions::Decision;
pub use event::{Agent, AgentEvent, EventKind, ParseError, ToolCall, parse_body, parse_osc};
pub use layout::{PendingRequest, Progress, Row, RowKind, SidebarGroup, SidebarSnapshot, Subrow};
pub use model::{Core, CoreError, Listener, SurfaceEnv};
pub use session::Outcome;

#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();
