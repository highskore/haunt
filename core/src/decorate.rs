//! Row decorations plugins set through `rows.decorate`: plain text, capped, one per row and plugin.

pub const LABEL_MAX: usize = 24;
pub const SUFFIX_MAX: usize = 64;
/// A scrolling suffix, a ticker, may be longer.
pub const TICKER_MAX: usize = 160;
pub const SPARK_MAX: usize = 32;

/// dim: secondary text; text: primary; warn: orange for a failure. Never haunt's needs-you colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum Tone {
    Dim,
    Text,
    Warn,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Spark {
    /// Oldest first; 0 is the bottom of the row's slot, 255 the top.
    pub points: Vec<u8>,
    pub tone: Tone,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Decoration {
    /// In the right-hand slot, in place of the status text.
    pub label: Option<String>,
    pub label_tone: Tone,
    /// After the meta line, separated by " · ".
    pub suffix: Option<String>,
    pub suffix_tone: Tone,
    pub scroll: bool,
    /// A thin bar under the row, 0 to 1000; drawn in place of the task progress bar.
    pub bar_permille: Option<u16>,
    /// In the right-hand slot, in place of the label.
    pub spark: Option<Spark>,
}

pub const TOP_TITLE_MAX: usize = 32;
pub const TOP_TEXT_MAX: usize = 24;
pub const TOP_SUB_MAX: usize = 48;

/// The one plugin row above every sidebar group (`top-row.set`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct TopRow {
    /// The plugin that set it; a click goes back to it.
    pub plugin_id: String,
    pub title: String,
    pub sub: Option<String>,
    /// The right-hand text, in `tone`.
    pub right: Option<String>,
    pub tone: Tone,
    pub bar_permille: Option<u16>,
    /// Whether clicking it calls the plugin.
    pub clickable: bool,
}

/// A bar fraction as permille; NaN and infinities are refused, the rest clamped to 0..=1.
pub fn permille(f: f32) -> Result<u16, String> {
    if !f.is_finite() {
        return Err("bar must be a number from 0 to 1".into());
    }
    Ok((f.clamp(0.0, 1.0) * 1000.0).round() as u16)
}

pub fn check_spark(points: &[u8]) -> Result<(), String> {
    if points.len() > SPARK_MAX {
        return Err(format!("a spark has at most {SPARK_MAX} points"));
    }
    Ok(())
}
