//! haunt-core: the UI-free model shared by every platform shell.

pub mod allowlist;
pub mod arrange;
pub mod ctl;
pub mod decisions;
pub mod event;
mod wire;
pub mod git;
mod ids;
#[cfg(test)]
mod testdir;
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
pub mod plugin_settings;
#[cfg(feature = "plugins")]
pub mod plugin_theme;
#[cfg(feature = "plugins")]
pub mod plugins;
pub mod progress;
#[cfg(feature = "plugins")]
pub mod ptygate;
mod serve;
pub mod session;
#[doc(hidden)]
pub mod sync;
pub mod turn;

pub use allowlist::{AllowSuggestion, Approval};
pub use arrange::{Arrangement, ColorStyle, TabColor};
pub use decisions::Decision;
pub use event::{Agent, AgentEvent, EventKind, ParseError, ToolCall, parse_body, parse_osc};
pub use layout::{PendingRequest, Progress, Row, RowKind, SidebarGroup, SidebarSnapshot, Subrow};
pub use model::{Core, CoreError, CoreHandle, EventTap, Listener, SurfaceEnv};
pub use session::Outcome;
pub use turn::{CommandOutcome, ReviewTurn, TurnCommand, TurnSubagent, TurnTask};

#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!();
