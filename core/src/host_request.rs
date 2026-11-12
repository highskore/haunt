//! What a plugin asks the app to do. Outside `plugins` so the replay can gate requests without the wasm host.

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct NotifyAction {
    pub id: String,
    pub title: String,
}

/// Side effects a plugin asked for; the app drains and performs them. A `PtyAnswer` or `PtyType`
/// becomes bytes only through `Core::gate_plugin_request` (`ptygate`).
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum HostRequest {
    Notify { plugin_id: String, title: String, body: String, actions: Vec<NotifyAction>, binding: Option<String> },
    PtyAnswer { plugin_id: String, surface: String, allow: bool, request_id: u64 },
    PtyType { plugin_id: String, surface: String, text: String, enter: bool },
    /// Show `panel`, or replace the one this plugin showed with its id.
    #[cfg(feature = "plugins")]
    ShowPanel { plugin_id: String, plugin_name: String, panel: crate::plugin_panel::Panel },
    /// Hold haunt's and other plugins' notifications (never a permission prompt's) for `minutes`, then
    /// show one summary; the app releases it then itself.
    HoldNotifications { plugin_id: String, minutes: u32 },
    /// What the holder adds to the summary; replaces its earlier one.
    HoldSummary { plugin_id: String, headline: Option<String>, actions: Vec<NotifyAction> },
    ReleaseNotifications { plugin_id: String },
    ClosePanel { plugin_id: String, id: String },
    /// The plugin bound or unbound a key: the app rebuilds its key map from `PluginSet::keys`.
    KeysChanged { plugin_id: String },
    /// Plain text for the clipboard, from a button, key or command the user just used.
    /// The app tags the pasteboard item with the plugin id (`dev.haunt.plugin-copy`) and says
    /// "<plugin_name> copied N lines".
    ClipboardWrite { plugin_id: String, plugin_name: String, text: String },
    /// An https link the user clicked a panel button for, checked by `plugins::link_ok`.
    OpenUrl { plugin_id: String, url: String },
    /// Select an open tab, from a button, key or command the user just used (`sidebar.focus`).
    FocusTab { plugin_id: String, surface: String },
    /// The Dock tile: image `image` (none: haunt's icon) with `badge` as its count, `blink` flashed now and then.
    /// Only the plugin that owns the tile sends one; all none gives haunt's own back.
    #[cfg(feature = "plugins")]
    DockShow { plugin_id: String, image: Option<String>, badge: Option<u32>, blink: Option<String> },
    /// The warn-orange glow along the top of the screen; the app labels it "`count` need(s) you" (0: no label).
    /// Only from its owner.
    #[cfg(feature = "plugins")]
    GlowShow { plugin_id: String, count: u8 },
    #[cfg(feature = "plugins")]
    GlowHide { plugin_id: String },
    /// One line of dim mono text in the title bar, next to its buttons; none clears it. Only from its owner.
    #[cfg(feature = "plugins")]
    TitleSet { plugin_id: String, text: Option<String> },
    /// One of haunt's sounds, `pitch` semitones off, at `volume` 0 to 1.
    #[cfg(feature = "plugins")]
    SoundPlay { plugin_id: String, sound: crate::plugins::SoundName, pitch: i32, volume: f32 },
    /// The plugin's one loop: `sound` at `level`, 0 to 1; 0 stops it.
    #[cfg(feature = "plugins")]
    SoundAmbient { plugin_id: String, sound: crate::plugins::SoundName, level: f32 },
    /// Speak plain `text` in the system voice, cutting off whatever was being said.
    #[cfg(feature = "plugins")]
    Say { plugin_id: String, text: String },
    /// Stop this plugin's utterance, if it is the one being spoken.
    #[cfg(feature = "plugins")]
    SayStop { plugin_id: String },
    /// The plugin's Dock images, decoded, replacing the ones it sent before; none drops them. Sent once, so a show
    /// names them by id.
    #[cfg(feature = "plugins")]
    DockImages { plugin_id: String, images: Vec<crate::plugins::DockImage> },
}
