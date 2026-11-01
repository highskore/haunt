//! haunt-core: the UI-free model shared by every platform shell.

pub mod event;
pub mod intake;
pub mod layout;
pub mod model;
#[cfg(feature = "plugins")]
pub mod plugin_cache;
#[cfg(feature = "plugins")]
pub mod plugins;
pub mod progress;
pub mod session;

pub use event::{AgentEvent, EventKind, ParseError, ToolCall, parse_body, parse_osc};
pub use layout::{Progress, Row, RowKind, SidebarGroup, SidebarSnapshot, Subrow};
pub use model::{Core, CoreError, Listener, SurfaceEnv};

#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();
