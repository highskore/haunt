//! haunt-core: the UI-free model shared by every platform shell.

pub mod event;
pub mod layout;
pub mod model;
#[cfg(feature = "plugins")]
pub mod plugins;
pub mod progress;
pub mod session;
pub mod socket;

pub use model::{Core, CoreError, Listener, SurfaceEnv};
pub use event::{AgentEvent, EventKind, ParseError, ToolCall, parse_line, parse_osc};
pub use layout::{Group, Progress, Row, RowKind, SidebarSnapshot, Subrow};

#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();
