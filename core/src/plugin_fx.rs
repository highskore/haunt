//! The `dock`, `glow`, `title`, `sound` and `speech` imports: checks, rate limits and the one-owner rule. A child of `plugins`, so it implements
//! the WIT host traits on `HostState`.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub(super) use super::bindings::haunt::plugin::dock as wdock;
pub(super) use super::bindings::haunt::plugin::glow as wglow;
pub(super) use super::bindings::haunt::plugin::title as wtitle;
pub(super) use super::bindings::haunt::plugin::sound as wsound;
pub(super) use super::bindings::haunt::plugin::speech as wspeech;
use super::{HostRequest, HostState};

/// The app-wide spots one plugin at a time may own: the first to set one keeps it until it clears it,
/// is disabled or is reloaded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Slot {
    Dock,
    Glow,
    Title,
}

/// Who owns each `Slot`, and the Dock images waiting to be decoded, shared by every plugin of one set.
#[derive(Debug, Clone, Default)]
pub struct Stage(Arc<Mutex<Vec<(Slot, String)>>>, Arc<Mutex<Vec<DockBatch>>>);

/// One plugin's checked PNGs, by id, for `decode_dock` once the plugin call and the set lock are over; none
/// drops the plugin's images.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DockBatch {
    pub plugin_id: String,
    pub pngs: Vec<(String, Vec<u8>)>,
}

impl Stage {
    /// Queues `plugin`'s images, replacing any of its own still waiting, so the queue holds one batch a plugin.
    pub(crate) fn queue_dock(&self, plugin: &str, pngs: Vec<(String, Vec<u8>)>) {
        let mut q = crate::sync::lock(&self.1);
        match q.iter_mut().find(|b| b.plugin_id == plugin) {
            Some(b) => b.pngs = pngs,
            None => q.push(DockBatch { plugin_id: plugin.to_owned(), pngs }),
        }
    }

    /// The images waiting to be decoded, for `decode_dock`.
    pub fn take_dock(&self) -> Vec<DockBatch> {
        std::mem::take(&mut *crate::sync::lock(&self.1))
    }

    /// Takes `slot` for `plugin`, or keeps it; refused while another plugin has it.
    pub(crate) fn claim(&self, slot: Slot, plugin: &str) -> Result<(), String> {
        let mut owners = crate::sync::lock(&self.0);
        match owners.iter().find(|(s, _)| *s == slot) {
            Some((_, p)) if p == plugin => Ok(()),
            Some((_, p)) => Err(format!("plugin {p} has it")),
            None => {
                owners.push((slot, plugin.to_owned()));
                Ok(())
            }
        }
    }

    /// Gives `slot` up if `plugin` had it; whether it did.
    pub(crate) fn release(&self, slot: Slot, plugin: &str) -> bool {
        let mut owners = crate::sync::lock(&self.0);
        let before = owners.len();
        owners.retain(|(s, p)| !(*s == slot && p == plugin));
        owners.len() != before
    }

    #[cfg(test)]
    pub(crate) fn owner(&self, slot: Slot) -> Option<String> {
        crate::sync::lock(&self.0).iter().find(|(s, _)| *s == slot).map(|(_, p)| p.clone())
    }
}

/// Orders every claim and let-go of a `Slot` across plugins: the app drains each plugin's requests in turn,
/// so an older plugin's let-go can come after a newer one's claim. Process-wide, so it never restarts on a reload.
static SEQ: AtomicU64 = AtomicU64::new(1);

fn next_seq() -> u64 {
    SEQ.fetch_add(1, Ordering::Relaxed)
}

/// At most `n` calls in any `window`.
#[derive(Debug)]
pub(crate) struct Rate {
    n: usize,
    window: Duration,
    times: VecDeque<Instant>,
}

impl Rate {
    pub(crate) fn new(n: usize, window: Duration) -> Self {
        Self { n, window, times: VecDeque::new() }
    }

    pub(crate) fn ok(&mut self) -> bool {
        let now = Instant::now();
        while self.times.front().is_some_and(|t| now.duration_since(*t) >= self.window) {
            self.times.pop_front();
        }
        if self.times.len() >= self.n {
            return false;
        }
        self.times.push_back(now);
        true
    }
}

/// A state each for idle, working, needs-you and a blink.
pub const DOCK_IMAGES_MAX: usize = 4;
pub const DOCK_PNG_MAX: usize = 1 << 20;
/// Pixels each way: a Dock tile at 2x.
pub const DOCK_PIXELS_MAX: u32 = 512;
const DOCK_ID_MAX: usize = 32;
const SHOWS_PER_SEC: usize = 4;

/// One plugin's per-instance state for these imports.
#[derive(Debug)]
pub(crate) struct Fx {
    /// The ids of the images the app holds for this plugin; the pixels went to it once, with `DockImages`.
    dock_images: Vec<String>,
    dock_images_rate: Rate,
    dock_rate: Rate,
    glow_rate: Rate,
    title_rate: Rate,
    sound_rate: Rate,
    ambient_rate: Rate,
    say_rate: Rate,
    /// Whether this plugin has a loop playing, or may still be speaking, for `release_fx` to stop.
    ambient_on: bool,
    spoke: bool,
}

impl Default for Fx {
    fn default() -> Self {
        Self {
            dock_images: Vec::new(),
            dock_images_rate: Rate::new(1, Duration::from_secs(1)),
            dock_rate: Rate::new(SHOWS_PER_SEC, Duration::from_secs(1)),
            glow_rate: Rate::new(SHOWS_PER_SEC, Duration::from_secs(1)),
            title_rate: Rate::new(SHOWS_PER_SEC, Duration::from_secs(1)),
            sound_rate: Rate::new(SOUNDS_PER_SEC, Duration::from_secs(1)),
            ambient_rate: Rate::new(SOUNDS_PER_SEC, Duration::from_secs(1)),
            say_rate: Rate::new(1, SAY_EVERY),
            ambient_on: false,
            spoke: false,
        }
    }
}

/// A Dock tile image, decoded here by `decode_png` so the plugin's bytes never reach ImageIO: `rgba` is
/// `width` × `height` pixels, 8 bits a channel, alpha not premultiplied, rows top first.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct DockImage {
    pub id: String,
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

fn dock_id_ok(id: &str) -> bool {
    (1..=DOCK_ID_MAX).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Whether `png` is a still image of at most `DOCK_PIXELS_MAX` pixels each way, every chunk whole with a
/// good CRC, an IHDR first and IEND last, with no unknown critical chunk and no animation (`acTL`). Cheap
/// enough for the plugin's own call: it reads the bytes once and allocates nothing.
pub(crate) fn check_png(png: &[u8]) -> Result<(), String> {
    walk_png(png, None)
}

/// `png`, checked by `check_png`, with only the chunks haunt reads; other ancillary chunks (colour profiles,
/// text, Exif) are dropped unread.
pub(crate) fn keep_chunks(png: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(png.len());
    walk_png(png, Some(&mut out))?;
    Ok(out)
}

fn walk_png(png: &[u8], mut out: Option<&mut Vec<u8>>) -> Result<(), String> {
    const SIG: &[u8] = b"\x89PNG\r\n\x1a\n";
    if png.len() > DOCK_PNG_MAX {
        return Err(format!("larger than {DOCK_PNG_MAX} bytes"));
    }
    let mut rest = png.strip_prefix(SIG).ok_or("not a PNG")?;
    if let Some(o) = out.as_deref_mut() {
        o.extend_from_slice(SIG);
    }
    let mut first = true;
    loop {
        if rest.len() < 12 {
            return Err("a PNG cut short".into());
        }
        let len = u32::from_be_bytes(rest[..4].try_into().unwrap()) as usize;
        let Some(whole) = rest.get(..12 + len) else { return Err("a PNG chunk runs past the end".into()) };
        let (kind, data, crc) = (&whole[4..8], &whole[8..8 + len], &whole[8 + len..]);
        if crc32fast::hash(&whole[4..8 + len]).to_be_bytes() != crc {
            return Err("a PNG chunk with a bad checksum".into());
        }
        if first {
            if kind != b"IHDR" || len != 13 {
                return Err("a PNG without its header".into());
            }
            let w = u32::from_be_bytes(data[..4].try_into().unwrap());
            let h = u32::from_be_bytes(data[4..8].try_into().unwrap());
            if !(1..=DOCK_PIXELS_MAX).contains(&w) || !(1..=DOCK_PIXELS_MAX).contains(&h) {
                return Err(format!("{w}×{h} pixels; at most {DOCK_PIXELS_MAX} each way"));
            }
            first = false;
        } else if kind == b"IHDR" {
            return Err("two PNG headers".into());
        }
        match kind {
            b"IHDR" | b"PLTE" | b"tRNS" | b"IDAT" | b"IEND" => {
                if let Some(o) = out.as_deref_mut() {
                    o.extend_from_slice(whole);
                }
            }
            b"acTL" => return Err("an animated PNG; send each frame as its own image".into()),
            [k, ..] if k.is_ascii_lowercase() && kind.iter().all(u8::is_ascii_alphabetic) => {}
            _ => return Err(format!("a PNG chunk {:?} haunt doesn't read", String::from_utf8_lossy(kind))),
        }
        rest = &rest[12 + len..];
        if kind == b"IEND" {
            return if rest.is_empty() { Ok(()) } else { Err("bytes after the PNG's end".into()) };
        }
    }
}

/// Decodes the queued images, outside any plugin call and the set lock: each batch becomes a `DockImages`,
/// an image that doesn't decode left out and named in `dropped`.
pub fn decode_dock(batches: Vec<DockBatch>) -> Vec<HostRequest> {
    batches
        .into_iter()
        .map(|b| {
            let (mut images, mut dropped) = (Vec::new(), Vec::new());
            for (id, png) in b.pngs {
                match decode_png(&png) {
                    Ok((width, height, rgba)) => images.push(DockImage { id, width, height, rgba }),
                    Err(_) => dropped.push(id),
                }
            }
            HostRequest::DockImages { plugin_id: b.plugin_id, images, dropped }
        })
        .collect()
}

/// `png` decoded to straight-alpha RGBA, after `keep_chunks`.
pub(crate) fn decode_png(png: &[u8]) -> Result<(u32, u32, Vec<u8>), String> {
    let clean = keep_chunks(png)?;
    let bad = |e: png::DecodingError| format!("a PNG that doesn't decode: {e}");
    let limits = png::Limits { bytes: 4 * (DOCK_PIXELS_MAX * DOCK_PIXELS_MAX * 4) as usize };
    let mut d = png::Decoder::new_with_limits(std::io::Cursor::new(&clean[..]), limits);
    d.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut r = d.read_info().map_err(bad)?;
    let mut buf = vec![0; r.output_buffer_size().ok_or("a PNG too large to decode")?];
    let info = r.next_frame(&mut buf).map_err(bad)?;
    r.finish().map_err(bad)?;
    buf.truncate(info.buffer_size());
    if info.bit_depth != png::BitDepth::Eight {
        return Err("a PNG that doesn't decode to 8 bits".into());
    }
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => buf.as_chunks::<3>().0.iter().flat_map(|&[r, g, b]| [r, g, b, 255]).collect(),
        png::ColorType::GrayscaleAlpha => buf.as_chunks::<2>().0.iter().flat_map(|&[g, a]| [g, g, g, a]).collect(),
        png::ColorType::Grayscale => buf.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::Indexed => return Err("a palette PNG that didn't expand".into()),
    };
    if rgba.len() != info.width as usize * info.height as usize * 4 {
        return Err("a PNG that decodes short".into());
    }
    Ok((info.width, info.height, rgba))
}

impl HostState {
    /// A disabled plugin gives back what it owns, and the app puts haunt's own back.
    pub(crate) fn release_fx(&mut self) {
        if self.stage.release(Slot::Dock, &self.id) {
            self.outbox.push(HostRequest::DockShow { plugin_id: self.id.clone(), image: None, badge: None, blink: None, seq: next_seq() });
        }
        if !std::mem::take(&mut self.fx.dock_images).is_empty() {
            self.stage.queue_dock(&self.id, Vec::new());
        }
        if self.stage.release(Slot::Glow, &self.id) {
            self.outbox.push(HostRequest::GlowHide { plugin_id: self.id.clone(), seq: next_seq() });
        }
        if self.stage.release(Slot::Title, &self.id) {
            self.outbox.push(HostRequest::TitleSet { plugin_id: self.id.clone(), text: None, seq: next_seq() });
        }
        if std::mem::take(&mut self.fx.ambient_on) {
            self.outbox.push(HostRequest::SoundAmbient { plugin_id: self.id.clone(), sound: SoundName::Rain, level: 0.0 });
        }
        if std::mem::take(&mut self.fx.spoke) {
            self.outbox.push(HostRequest::SayStop { plugin_id: self.id.clone() });
        }
    }

    fn dock_image(&self, id: String) -> Result<String, String> {
        if self.fx.dock_images.contains(&id) { Ok(id) } else { Err(format!("no image {id:?}; register it with images first")) }
    }
}

impl wdock::Host for HostState {
    fn images(&mut self, images: Vec<(String, Vec<u8>)>) -> Result<(), String> {
        if images.len() > DOCK_IMAGES_MAX {
            return Err(format!("at most {DOCK_IMAGES_MAX} images"));
        }
        for (i, (id, png)) in images.iter().enumerate() {
            if !dock_id_ok(id) {
                return Err(format!("image id {:?} must be 1-{DOCK_ID_MAX} letters, digits and '-'", super::plain(id, DOCK_ID_MAX)));
            }
            if images[..i].iter().any(|(other, _)| other == id) {
                return Err(format!("image id {id:?} twice"));
            }
            check_png(png).map_err(|e| format!("image {id:?}: {e}"))?;
        }
        if !self.fx.dock_images_rate.ok() {
            return Err("images at most once a second".into());
        }
        // Decoding waits for the app's drain (`decode_dock`), off this plugin's CPU budget.
        self.fx.dock_images = images.iter().map(|(id, _)| id.clone()).collect();
        self.stage.queue_dock(&self.id, images);
        Ok(())
    }

    fn show(&mut self, id: Option<String>, badge: Option<u32>, blink: Option<String>) -> Result<(), String> {
        let plugin_id = self.id.clone();
        if id.is_none() && badge.is_none() {
            if blink.is_some() {
                return Err("blink needs an image to go back to".into());
            }
            if self.stage.release(Slot::Dock, &plugin_id) {
                self.outbox.push(HostRequest::DockShow { plugin_id, image: None, badge: None, blink: None, seq: next_seq() });
            }
            return Ok(());
        }
        let image = id.map(|i| self.dock_image(i)).transpose()?;
        let blink = blink.map(|i| self.dock_image(i)).transpose()?;
        if blink.is_some() && image.is_none() {
            return Err("blink needs an image to go back to".into());
        }
        if !self.fx.dock_rate.ok() {
            return Err(format!("show at most {SHOWS_PER_SEC} times a second"));
        }
        if self.outbox.len() >= super::MAX_OUTBOX {
            return Err("too many pending requests".into());
        }
        self.stage.claim(Slot::Dock, &plugin_id).map_err(|who| format!("the Dock tile is taken: {who}"))?;
        self.request(HostRequest::DockShow { plugin_id, image, badge, blink, seq: next_seq() })
    }
}

/// The whole label, as the app draws it.
pub const GLOW_LABEL_MAX: usize = 32;
/// A row label's command, before its `?`.
pub const GLOW_COMMAND_MAX: usize = 16;
/// Room left for " · " and a waiting time of up to six characters ("59m59s", "12h05m").
pub const GLOW_HEAD_MAX: usize = GLOW_LABEL_MAX - 9;

/// The glow's label, always haunt's own words from its own state; a plugin passes no text and no number.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum GlowLabel {
    NoLabel,
    /// The app's own count of the tabs that need you, kept up to date: "1 needs you", "N need you"; none for 0.
    Needs,
    /// "`head` · <time waiting>", `head` being "<tab> · <command>?" or "<tab>": the app counts the time on from
    /// `waited_secs`, and shows `Needs` once `surface` stops needing you.
    Row { surface: String, head: String, waited_secs: u64 },
}

impl HostState {
    fn glow_label(&self, label: wglow::GlowLabel) -> GlowLabel {
        let surface = match label {
            wglow::GlowLabel::None => return GlowLabel::NoLabel,
            wglow::GlowLabel::Needs => return GlowLabel::Needs,
            wglow::GlowLabel::Row(s) => s,
        };
        let Some(w) = self.core.as_ref().and_then(|c| c.needs_you(&surface)) else { return GlowLabel::Needs };
        let command = w.command.filter(|_| self.events.details).map(|p| super::plain(&p, GLOW_COMMAND_MAX)).filter(|p| !p.trim().is_empty());
        let head = match command {
            Some(c) => format!("{} · {}?", w.name, c.trim()),
            None => w.name,
        };
        GlowLabel::Row { surface, head: super::plain(head.trim(), GLOW_HEAD_MAX), waited_secs: w.since.as_secs() }
    }
}

impl wglow::Host for HostState {
    /// Only the warn orange: never Haunt's needs-you white, and no colour of the plugin's own. The label is
    /// haunt's, from a count or a tab's own state: free text drawn over other apps could pass for theirs.
    fn show(&mut self, tone: super::wrows::Tone, label: wglow::GlowLabel) -> Result<(), String> {
        if tone != super::wrows::Tone::Warn {
            return Err("the glow comes in warn only".into());
        }
        let label = self.glow_label(label);
        if !self.fx.glow_rate.ok() {
            return Err(format!("show at most {SHOWS_PER_SEC} times a second"));
        }
        if self.outbox.len() >= super::MAX_OUTBOX {
            return Err("too many pending requests".into());
        }
        let plugin_id = self.id.clone();
        self.stage.claim(Slot::Glow, &plugin_id).map_err(|who| format!("the glow is taken: {who}"))?;
        self.request(HostRequest::GlowShow { plugin_id, label, seq: next_seq() })
    }

    fn hide(&mut self) {
        if self.stage.release(Slot::Glow, &self.id) {
            self.outbox.push(HostRequest::GlowHide { plugin_id: self.id.clone(), seq: next_seq() });
        }
    }
}

pub const SOUNDS_PER_SEC: usize = 4;
pub const PITCH_MAX: i32 = 12;
pub const SAY_MAX: usize = 200;
const SAY_EVERY: Duration = Duration::from_secs(2);

/// Haunt's bundled sounds, which the app synthesises; a plugin never plays audio of its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum SoundName {
    Chime,
    Bell,
    Rain,
}

fn sound_name(n: wsound::Name) -> SoundName {
    match n {
        wsound::Name::Chime => SoundName::Chime,
        wsound::Name::Bell => SoundName::Bell,
        wsound::Name::Rain => SoundName::Rain,
    }
}

/// 0 to 1; NaN, infinities and anything outside are refused, not clamped.
fn unit(what: &str, v: f32) -> Result<f32, String> {
    if v.is_finite() && (0.0..=1.0).contains(&v) { Ok(v) } else { Err(format!("{what} must be 0 to 1")) }
}

impl wsound::Host for HostState {
    fn play(&mut self, sound: wsound::Name, pitch: i32, volume: f32) -> Result<(), String> {
        if !(-PITCH_MAX..=PITCH_MAX).contains(&pitch) {
            return Err(format!("pitch must be -{PITCH_MAX} to {PITCH_MAX} semitones"));
        }
        let volume = unit("volume", volume)?;
        if !self.fx.sound_rate.ok() {
            return Err(format!("at most {SOUNDS_PER_SEC} sounds a second"));
        }
        self.request(HostRequest::SoundPlay { plugin_id: self.id.clone(), sound: sound_name(sound), pitch, volume })
    }

    fn ambient(&mut self, sound: wsound::Name, level: f32) -> Result<(), String> {
        let level = unit("level", level)?;
        if !self.fx.ambient_rate.ok() {
            return Err(format!("at most {SOUNDS_PER_SEC} ambient changes a second"));
        }
        self.request(HostRequest::SoundAmbient { plugin_id: self.id.clone(), sound: sound_name(sound), level })?;
        self.fx.ambient_on = level > 0.0;
        Ok(())
    }
}

impl wspeech::Host for HostState {
    fn say(&mut self, text: String) -> Result<(), String> {
        // `[[` opens an embedded speech command (rate, voice, volume) in the system synthesiser. Brackets go
        // after `plain`, which drops hidden characters and so could join two of them.
        let text: String = super::plain(&text, SAY_MAX).chars().filter(|c| !matches!(c, '[' | ']')).collect();
        if text.trim().is_empty() {
            return Err("nothing to say".into());
        }
        if !self.fx.say_rate.ok() {
            return Err("at most one utterance every 2 seconds".into());
        }
        let n = text.chars().count() as u64;
        self.request(HostRequest::Say { plugin_id: self.id.clone(), text })?;
        // The length only: what a plugin says aloud may be anything it read.
        self.audit("speech.say", "", "", n);
        self.fx.spoke = true;
        Ok(())
    }

    fn stop(&mut self) {
        if std::mem::take(&mut self.fx.spoke) {
            let _ = self.request(HostRequest::SayStop { plugin_id: self.id.clone() });
        }
    }
}

pub const TITLE_MAX: usize = 48;

impl wtitle::Host for HostState {
    fn set(&mut self, text: Option<String>) -> Result<(), String> {
        let plugin_id = self.id.clone();
        let Some(text) = super::plain_opt(text, TITLE_MAX) else {
            if self.stage.release(Slot::Title, &plugin_id) {
                self.outbox.push(HostRequest::TitleSet { plugin_id, text: None, seq: next_seq() });
            }
            return Ok(());
        };
        // The stricter theme list: a plugin is trusted less than a theme, and the line sits beside Haunt's own.
        if super::theme_says_status(&text) {
            return Err("the title line can't use Haunt's status or permission words".into());
        }
        if !self.fx.title_rate.ok() {
            return Err(format!("set at most {SHOWS_PER_SEC} times a second"));
        }
        if self.outbox.len() >= super::MAX_OUTBOX {
            return Err("too many pending requests".into());
        }
        self.stage.claim(Slot::Title, &plugin_id).map_err(|who| format!("the title-bar slot is taken: {who}"))?;
        self.request(HostRequest::TitleSet { plugin_id, text: Some(text), seq: next_seq() })
    }
}

#[cfg(test)]
pub(super) mod tests {
    use super::super::{Capabilities, PluginHost};
    use super::*;
    use wasmtime::component::Component;

    pub(crate) fn state(id: &str, stage: &Stage) -> HostState {
        let mut st = HostState::new(id, &Capabilities::default(), None, None, None);
        st.stage = stage.clone();
        st
    }

    pub(crate) fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let crc = crc32fast::hash(&[&kind[..], data].concat());
        [&(data.len() as u32).to_be_bytes()[..], kind, data, &crc.to_be_bytes()].concat()
    }

    /// A real `w` × `h` PNG of `color`, with the chunks in `extra` right after its header.
    pub(crate) fn png_of(w: u32, h: u32, color: png::ColorType, extra: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, w, h);
        e.set_color(color);
        let channels = color.samples();
        let mut wr = e.write_header().unwrap();
        let px: Vec<u8> = (0..w * h).flat_map(|i| (0..channels).map(move |c| (i as usize * 7 + c * 50) as u8)).collect();
        wr.write_image_data(&px).unwrap();
        wr.finish().unwrap();
        // The signature (8) and IHDR (25) come first.
        [&out[..33], extra, &out[33..]].concat()
    }

    pub(crate) fn png(w: u32, h: u32, extra: &[u8]) -> Vec<u8> {
        png_of(w, h, png::ColorType::Rgba, extra)
    }

    /// A PNG whose IHDR claims `w` × `h`, for size checks that come before any decoding.
    fn header_only(w: u32, h: u32) -> Vec<u8> {
        let ihdr = [&w.to_be_bytes()[..], &h.to_be_bytes(), &[8, 6, 0, 0, 0]].concat();
        [&b"\x89PNG\r\n\x1a\n"[..], &chunk(b"IHDR", &ihdr), &chunk(b"IEND", &[])].concat()
    }

    const DOCK_IMPORT: &str = r#"(component (import "haunt:plugin/dock@0.5.0" (instance
        (export "show" (func (param "id" (option string)) (param "badge" (option u32)) (param "blink" (option string))
            (result (result (error string))))))))"#;

    #[test]
    fn the_dock_import_needs_its_capability() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, DOCK_IMPORT).unwrap();
        let everything_else = Capabilities { notifications: true, panel: true, decorate: true, timer: true, ..Default::default() };
        let e = host.check_links(&c, &everything_else).unwrap_err().0;
        assert!(e.contains("haunt:plugin/dock"), "{e}");
        host.check_links(&c, &Capabilities { dock: true, ..Default::default() }).unwrap();
    }

    #[test]
    fn dock_images_are_still_capped_pngs() {
        let (w, h, rgba) = decode_png(&png(512, 512, &[])).unwrap();
        assert_eq!((w, h, rgba.len()), (512, 512, 512 * 512 * 4));
        let mut bad_crc = png(64, 64, &[]);
        bad_crc[29] ^= 1;
        for (bad, why) in [
            (header_only(513, 10), "pixels"),
            (header_only(10, u32::MAX), "pixels"),
            (header_only(0, 10), "pixels"),
            (png(64, 64, &chunk(b"acTL", &[0; 8])), "animated"),
            (png(64, 64, &chunk(b"ZZZZ", &[1])), "doesn't read"),
            (png(64, 64, &chunk(b"a\0bc", &[1])), "doesn't read"),
            (bad_crc, "checksum"),
            (b"GIF89a".to_vec(), "not a PNG"),
            (png(64, 64, &[])[..50].to_vec(), "past the end"),
            (png(64, 64, &[])[..40].to_vec(), "cut short"),
            ([png(64, 64, &[]), b"tail".to_vec()].concat(), "after the PNG"),
            ([png(64, 64, &[]), vec![0; DOCK_PNG_MAX]].concat(), "larger than"),
            (header_only(64, 64), "doesn't decode"),
        ] {
            let e = decode_png(&bad).unwrap_err();
            assert!(e.contains(why), "{why}: {e}");
            if why != "doesn't decode" {
                assert_eq!(check_png(&bad).unwrap_err(), e, "the plugin's own call refuses it the same");
            }
        }
    }

    #[test]
    fn dock_images_lose_every_chunk_but_the_pixels_unread() {
        // A colour profile, Exif and compressed text, each garbage inside, so parsing any of them would fail.
        let extra = [chunk(b"iCCP", b"x\0\0garbage"), chunk(b"eXIf", b"MM\0*junk"), chunk(b"zTXt", b"k\0\0not zlib"), chunk(b"gAMA", &[0; 4])].concat();
        let with = png(16, 16, &extra);
        let kept = keep_chunks(&with).unwrap();
        for kind in [&b"iCCP"[..], b"eXIf", b"zTXt", b"gAMA"] {
            assert!(!kept.windows(4).any(|w| w == kind), "{}", String::from_utf8_lossy(kind));
        }
        assert_eq!(kept, png(16, 16, &[]));
        assert_eq!(decode_png(&with), decode_png(&png(16, 16, &[])));
    }

    #[test]
    fn dock_images_decode_to_straight_rgba_whatever_the_colour_type() {
        let (_, _, rgba) = decode_png(&png_of(2, 1, png::ColorType::Rgb, &[])).unwrap();
        assert_eq!(rgba, [0, 50, 100, 255, 7, 57, 107, 255]);
        let (_, _, rgba) = decode_png(&png_of(2, 1, png::ColorType::Grayscale, &[])).unwrap();
        assert_eq!(rgba, [0, 0, 0, 255, 7, 7, 7, 255]);
        let (_, _, rgba) = decode_png(&png_of(1, 1, png::ColorType::GrayscaleAlpha, &[])).unwrap();
        assert_eq!(rgba, [0, 0, 0, 50]);
        // A palette with a transparent second entry.
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, 2, 1);
        e.set_color(png::ColorType::Indexed);
        e.set_depth(png::BitDepth::Eight);
        e.set_palette(vec![255, 0, 0, 0, 0, 255]);
        e.set_trns(vec![255, 0]);
        let mut wr = e.write_header().unwrap();
        wr.write_image_data(&[0, 1]).unwrap();
        wr.finish().unwrap();
        assert_eq!(decode_png(&out).unwrap().2, [255, 0, 0, 255, 0, 0, 255, 0]);
    }

    #[test]
    fn dock_images_are_capped_named_and_rate_limited() {
        let stage = Stage::default();
        let mut st = state("dev.haunt.a", &stage);
        let img = |id: &str| (id.to_owned(), png(64, 64, &[]));
        let five: Vec<_> = (0..5).map(|i| img(&format!("s{i}"))).collect();
        assert!(wdock::Host::images(&mut st, five).unwrap_err().contains("at most 4"));
        assert!(wdock::Host::images(&mut st, vec![("a".into(), header_only(513, 1))]).unwrap_err().contains("at most 512"));
        for bad in ["", "a b", "ghost\u{202e}", "../x", &"x".repeat(33)] {
            assert!(wdock::Host::images(&mut st, vec![img(bad)]).unwrap_err().contains("must be"), "{bad:?}");
        }
        assert!(wdock::Host::images(&mut st, vec![img("a"), img("a")]).unwrap_err().contains("twice"));
        assert!(wdock::Host::images(&mut st, vec![("a".into(), b"no".to_vec())]).unwrap_err().contains("not a PNG"));
        assert!(stage.take_dock().is_empty());
        wdock::Host::images(&mut st, vec![img("idle"), ("bad".into(), header_only(8, 8)), img("busy")]).unwrap();
        assert!(wdock::Host::images(&mut st, vec![img("idle")]).unwrap_err().contains("once a second"));
        assert!(st.outbox.is_empty(), "nothing is decoded in the plugin's call");
        let [HostRequest::DockImages { plugin_id, images, dropped }] = &decode_dock(stage.take_dock())[..] else { panic!() };
        assert_eq!(images.iter().map(|i| (i.id.as_str(), i.rgba.len())).collect::<Vec<_>>(), [("idle", 64 * 64 * 4), ("busy", 64 * 64 * 4)]);
        assert_eq!((plugin_id.as_str(), &dropped[..]), ("dev.haunt.a", &["bad".to_owned()][..]), "one that doesn't decode is dropped and named");
        assert_eq!(stage.owner(Slot::Dock), None, "images alone take nothing on screen");
    }

    #[test]
    fn a_plugin_waits_on_checks_only_never_the_decode() {
        // The worst four: the most pixels, each padded with an ancillary chunk to the byte cap, every CRC read.
        let stage = Stage::default();
        let mut st = state("dev.haunt.a", &stage);
        let max = |i: usize| {
            let base = png(DOCK_PIXELS_MAX, DOCK_PIXELS_MAX, &[]);
            let pad = DOCK_PNG_MAX - base.len() - 12;
            (format!("s{i}"), png(DOCK_PIXELS_MAX, DOCK_PIXELS_MAX, &chunk(b"zTXt", &vec![7; pad])))
        };
        let four: Vec<_> = (0..DOCK_IMAGES_MAX).map(max).collect();
        assert!(four.iter().all(|(_, p)| p.len() == DOCK_PNG_MAX));
        wdock::Host::images(&mut st, four.clone()).unwrap();
        assert!(st.outbox.is_empty(), "no pixels leave the call");
        assert_eq!(stage.take_dock(), [DockBatch { plugin_id: "dev.haunt.a".into(), pngs: four }], "the bytes wait as sent, undecoded");
    }

    #[test]
    fn the_queue_keeps_one_batch_a_plugin_latest_first() {
        let stage = Stage::default();
        let mut a = state("dev.haunt.a", &stage);
        wdock::Host::images(&mut a, vec![("idle".into(), png(8, 8, &[]))]).unwrap();
        a.release_fx();
        let batches = stage.take_dock();
        assert_eq!(batches, [DockBatch { plugin_id: "dev.haunt.a".into(), pngs: vec![] }], "a let-go replaces the waiting images");
        assert!(matches!(&decode_dock(batches)[..], [HostRequest::DockImages { images, dropped, .. }] if images.is_empty() && dropped.is_empty()));
    }

    #[test]
    fn the_first_plugin_to_show_owns_the_dock_tile_until_it_lets_go() {
        let stage = Stage::default();
        let (mut a, mut b) = (state("dev.haunt.a", &stage), state("dev.haunt.b", &stage));
        for st in [&mut a, &mut b] {
            wdock::Host::images(st, vec![("idle".into(), png(64, 64, &[])), ("blink".into(), png(64, 64, &[]))]).unwrap();
        }
        assert!(wdock::Host::show(&mut a, Some("nope".into()), None, None).unwrap_err().contains("no image"));
        assert!(wdock::Host::show(&mut a, None, Some(3), Some("blink".into())).unwrap_err().contains("blink needs"));
        assert_eq!(stage.owner(Slot::Dock), None, "a refused show takes nothing");

        wdock::Host::show(&mut a, Some("idle".into()), Some(3), Some("blink".into())).unwrap();
        let [HostRequest::DockShow { image: Some(i), badge: Some(3), blink: Some(k), .. }] = &a.outbox[..] else { panic!("{:?}", a.outbox) };
        assert_eq!((i.as_str(), k.as_str()), ("idle", "blink"), "by id: the pixels went once, with images");
        assert!(wdock::Host::show(&mut b, Some("idle".into()), None, None).unwrap_err().contains("dev.haunt.a has it"));
        wdock::Host::show(&mut b, None, None, None).unwrap();
        assert!(b.outbox.is_empty(), "a non-owner clearing changes nothing");

        a.outbox.clear();
        wdock::Host::show(&mut a, None, None, None).unwrap();
        assert!(matches!(&a.outbox[..], [HostRequest::DockShow { image: None, badge: None, blink: None, .. }]));
        wdock::Host::show(&mut b, None, Some(1), None).unwrap();
        assert_eq!(stage.owner(Slot::Dock).as_deref(), Some("dev.haunt.b"));
        let ([HostRequest::DockShow { seq: release, .. }], [HostRequest::DockShow { seq: claim, .. }]) = (&a.outbox[..], &b.outbox[..]) else { panic!() };
        assert!(claim > release, "b's claim is stamped after a's let-go, whichever outbox the app drains first");
    }

    #[test]
    fn a_disabled_owner_gives_the_dock_tile_back() {
        let stage = Stage::default();
        let mut a = state("dev.haunt.a", &stage);
        wdock::Host::images(&mut a, vec![("idle".into(), png(8, 8, &[]))]).unwrap();
        wdock::Host::show(&mut a, Some("idle".into()), None, None).unwrap();
        a.outbox.clear();
        a.release_fx();
        assert!(matches!(&a.outbox[..], [HostRequest::DockShow { image: None, badge: None, blink: None, .. }]), "{:?}", a.outbox);
        assert_eq!(stage.take_dock(), [DockBatch { plugin_id: "dev.haunt.a".into(), pngs: vec![] }], "and the app drops its images");
        assert_eq!(stage.owner(Slot::Dock), None);
        drop(a);
        let mut b = state("dev.haunt.b", &stage);
        wdock::Host::show(&mut b, None, Some(2), None).unwrap();
        drop(b);
        assert_eq!(stage.owner(Slot::Dock), None, "a dropped instance lets go too");
    }

    #[test]
    fn dock_shows_are_rate_limited() {
        let mut a = state("dev.haunt.a", &Stage::default());
        for n in 0..SHOWS_PER_SEC as u32 {
            wdock::Host::show(&mut a, None, Some(n), None).unwrap();
        }
        assert!(wdock::Host::show(&mut a, None, Some(9), None).unwrap_err().contains("times a second"));
    }
}

#[cfg(test)]
mod glow_tests {
    use super::super::wrows::Tone;
    use super::super::{Capabilities, PluginHost};
    use super::tests::state;
    use super::*;
    use std::time::Instant;
    use wasmtime::component::Component;
    use wglow::GlowLabel::{Needs, Row};

    /// A plugin with `glow`, and `event_details` if `details`, over a core where tab `a` asks to run `command`
    /// and tab `b` doesn't need you.
    fn waiting(details: bool, command: &str) -> (crate::Core, HostState, String, String, crate::testdir::TempDir) {
        let dir = crate::testdir::TempDir::new("fx-glow-row");
        let core = crate::Core::new(&*dir);
        let (a, b) = (core.register_surface("/srv/api").unwrap(), core.register_surface("/srv/web").unwrap());
        let input = serde_json::json!({ "v": 1, "surface_id": a.surface_id, "nonce": a.nonce, "event": "permission_seen", "tool_name": "Bash", "tool_input": { "command": command } });
        core.with_state(|s| s.handle_line(&input.to_string(), Instant::now()));
        let caps = Capabilities { glow: true, event_details: details, ..Default::default() };
        let st = HostState::new("dev.haunt.a", &caps, None, None, Some(core.handle()));
        (core, st, a.surface_id, b.surface_id, dir)
    }

    fn label(st: &mut HostState, surface: &str) -> GlowLabel {
        st.fx.glow_rate = Rate::new(SHOWS_PER_SEC, Duration::from_secs(1));
        wglow::Host::show(st, Tone::Warn, Row(surface.into())).unwrap();
        let Some(HostRequest::GlowShow { label, .. }) = st.outbox.pop() else { panic!("{:?}", st.outbox) };
        label
    }

    #[test]
    fn a_row_label_is_the_tab_its_command_and_the_wait() {
        let (_core, mut st, a, _, _dir) = waiting(true, "git push");
        let GlowLabel::Row { surface, head, waited_secs } = label(&mut st, &a) else { panic!() };
        assert_eq!((surface.as_str(), head.as_str()), (a.as_str(), "api · git push?"));
        assert!(waited_secs < 5, "{waited_secs}");
    }

    #[test]
    fn a_row_label_names_the_command_only_with_event_details() {
        let (_core, mut st, a, _, _dir) = waiting(false, "git push --force origin main");
        assert!(matches!(label(&mut st, &a), GlowLabel::Row { head, .. } if head == "api"));
    }

    #[test]
    fn a_row_labels_command_is_plain_and_cut_and_the_label_fits() {
        let (_core, mut st, a, _, _dir) = waiting(true, "git\u{200b} push\u{202e} \u{1b}[31m--force origin main");
        let GlowLabel::Row { head, .. } = label(&mut st, &a) else { panic!() };
        assert_eq!(head, "api · git push [31m--f?");
        assert!(head.chars().count() <= GLOW_HEAD_MAX && GLOW_HEAD_MAX + " · 59m59s".chars().count() <= GLOW_LABEL_MAX);
    }

    #[test]
    fn a_row_label_for_a_tab_that_doesnt_need_you_is_haunts_count() {
        let (_core, mut st, _, b, _dir) = waiting(true, "git push");
        assert_eq!(label(&mut st, &b), GlowLabel::Needs);
        assert_eq!(label(&mut st, "no-such-tab"), GlowLabel::Needs);
        let mut coreless = state("dev.haunt.b", &Stage::default());
        assert_eq!(label(&mut coreless, "x"), GlowLabel::Needs);
    }

    #[test]
    fn the_glow_import_needs_its_capability() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/glow@0.5.0" (instance (export "hide" (func)))))"#).unwrap();
        let e = host.check_links(&c, &Capabilities { dock: true, panel: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/glow"), "{e}");
        host.check_links(&c, &Capabilities { glow: true, ..Default::default() }).unwrap();
    }

    #[test]
    fn the_glow_is_warn_only_and_its_label_haunts() {
        let mut a = state("dev.haunt.a", &Stage::default());
        for t in [Tone::Dim, Tone::Text] {
            assert!(wglow::Host::show(&mut a, t, Needs).unwrap_err().contains("warn only"));
        }
        assert!(a.outbox.is_empty());
        wglow::Host::show(&mut a, Tone::Warn, Needs).unwrap();
        wglow::Host::show(&mut a, Tone::Warn, wglow::GlowLabel::None).unwrap();
        assert!(
            matches!(&a.outbox[..], [HostRequest::GlowShow { label: GlowLabel::Needs, .. }, HostRequest::GlowShow { label: GlowLabel::NoLabel, .. }]),
            "{:?}",
            a.outbox
        );
    }

    #[test]
    fn the_first_plugin_to_show_owns_the_glow_until_it_hides_or_is_disabled() {
        let stage = Stage::default();
        let (mut a, mut b) = (state("dev.haunt.a", &stage), state("dev.haunt.b", &stage));
        wglow::Host::show(&mut a, Tone::Warn, Needs).unwrap();
        assert!(wglow::Host::show(&mut b, Tone::Warn, Needs).unwrap_err().contains("dev.haunt.a has it"));
        wglow::Host::hide(&mut b);
        assert!(b.outbox.is_empty(), "a non-owner's hide does nothing");
        a.outbox.clear();
        wglow::Host::hide(&mut a);
        assert!(matches!(&a.outbox[..], [HostRequest::GlowHide { .. }]));
        wglow::Host::show(&mut b, Tone::Warn, Needs).unwrap();
        b.outbox.clear();
        b.release_fx();
        assert!(matches!(&b.outbox[..], [HostRequest::GlowHide { .. }]));
        assert_eq!(stage.owner(Slot::Glow), None);
    }

    #[test]
    fn glow_shows_are_rate_limited() {
        let mut a = state("dev.haunt.a", &Stage::default());
        for _ in 0..SHOWS_PER_SEC {
            wglow::Host::show(&mut a, Tone::Warn, Needs).unwrap();
        }
        assert!(wglow::Host::show(&mut a, Tone::Warn, Needs).unwrap_err().contains("times a second"));
    }
}

#[cfg(test)]
mod title_tests {
    use super::super::{Capabilities, PluginHost};
    use super::tests::state;
    use super::*;
    use wasmtime::component::Component;

    #[test]
    fn the_title_import_needs_its_capability() {
        let host = PluginHost::new().unwrap();
        let c = Component::new(&host.engine, r#"(component (import "haunt:plugin/title@0.5.0" (instance
            (export "set" (func (param "text" (option string)) (result (result (error string))))))))"#).unwrap();
        let e = host.check_links(&c, &Capabilities { dock: true, glow: true, decorate: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/title"), "{e}");
        host.check_links(&c, &Capabilities { title: true, ..Default::default() }).unwrap();
    }

    #[test]
    fn the_title_is_one_plain_line_of_48() {
        let mut a = state("dev.haunt.a", &Stage::default());
        wtitle::Host::set(&mut a, Some(format!("main\u{202e}\u{1b}[31m ↑2\n{}", "y".repeat(60)))).unwrap();
        let [HostRequest::TitleSet { text: Some(t), .. }] = &a.outbox[..] else { panic!("{:?}", a.outbox) };
        assert_eq!(t.chars().count(), TITLE_MAX);
        assert!(t.starts_with("main[31m ↑2 y"), "{t}");
        a.outbox.clear();
        wtitle::Host::set(&mut a, Some("\u{200b} \u{2066}".into())).unwrap();
        assert!(matches!(&a.outbox[..], [HostRequest::TitleSet { text: None, .. }]), "nothing visible clears it");
    }

    #[test]
    fn the_title_never_says_what_haunt_says() {
        let mut a = state("dev.haunt.a", &Stage::default());
        for text in ["NEEDS YOU · api", "Allow", "approving the push", "d\u{200b}one"] {
            assert!(wtitle::Host::set(&mut a, Some(text.into())).unwrap_err().contains("status"), "{text}");
        }
        assert!(a.outbox.is_empty());
        wtitle::Host::set(&mut a, Some("Doneness of the build".into())).unwrap();
        assert_eq!(a.outbox.len(), 1, "a word that only starts like one is fine");
    }

    #[test]
    fn the_first_plugin_to_set_owns_the_title_slot() {
        let stage = Stage::default();
        let (mut a, mut b) = (state("dev.haunt.a", &stage), state("dev.haunt.b", &stage));
        wtitle::Host::set(&mut a, Some("3 agents".into())).unwrap();
        assert!(wtitle::Host::set(&mut b, Some("mine".into())).unwrap_err().contains("dev.haunt.a has it"));
        wtitle::Host::set(&mut b, None).unwrap();
        assert!(b.outbox.is_empty(), "a non-owner's clear does nothing");
        a.outbox.clear();
        a.release_fx();
        assert!(matches!(&a.outbox[..], [HostRequest::TitleSet { text: None, .. }]));
        wtitle::Host::set(&mut b, Some("mine".into())).unwrap();
        assert_eq!(stage.owner(Slot::Title).as_deref(), Some("dev.haunt.b"));
    }

    #[test]
    fn title_sets_are_rate_limited() {
        let mut a = state("dev.haunt.a", &Stage::default());
        for i in 0..SHOWS_PER_SEC {
            wtitle::Host::set(&mut a, Some(format!("{i}"))).unwrap();
        }
        assert!(wtitle::Host::set(&mut a, Some("x".into())).unwrap_err().contains("times a second"));
    }
}

#[cfg(test)]
mod sound_tests {
    use super::super::{Capabilities, PluginHost};
    use super::tests::state;
    use super::*;
    use wasmtime::component::Component;

    const STOP_IMPORT: &str = r#"(component (import "haunt:plugin/speech@0.5.0" (instance (export "stop" (func)))))"#;
    const AMBIENT_IMPORT: &str = r#"(component (import "haunt:plugin/sound@0.5.0" (instance
        (type $n (enum "chime" "bell" "rain"))
        (export "name" (type $ne (eq $n)))
        (export "ambient" (func (param "sound" $ne) (param "level" f32) (result (result (error string))))))))"#;

    #[test]
    fn sound_and_speech_are_separate_capabilities() {
        let host = PluginHost::new().unwrap();
        let (speech, sound) = (Component::new(&host.engine, STOP_IMPORT).unwrap(), Component::new(&host.engine, AMBIENT_IMPORT).unwrap());
        let e = host.check_links(&speech, &Capabilities { sound: true, notifications: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/speech"), "{e}");
        let e = host.check_links(&sound, &Capabilities { speech: true, notifications: true, ..Default::default() }).unwrap_err().0;
        assert!(e.contains("haunt:plugin/sound"), "{e}");
        host.check_links(&speech, &Capabilities { speech: true, ..Default::default() }).unwrap();
        host.check_links(&sound, &Capabilities { sound: true, ..Default::default() }).unwrap();
    }

    #[test]
    fn sounds_refuse_bad_numbers_and_are_rate_limited() {
        let mut a = state("dev.haunt.a", &Stage::default());
        for (pitch, volume) in [(13, 0.5), (-13, 0.5), (0, f32::NAN), (0, f32::INFINITY), (0, -0.1), (0, 1.01)] {
            assert!(wsound::Host::play(&mut a, wsound::Name::Chime, pitch, volume).is_err(), "{pitch} {volume}");
        }
        assert!(a.outbox.is_empty());
        for _ in 0..SOUNDS_PER_SEC {
            wsound::Host::play(&mut a, wsound::Name::Bell, -12, 1.0).unwrap();
        }
        assert!(wsound::Host::play(&mut a, wsound::Name::Bell, 0, 0.2).unwrap_err().contains("a second"));
        assert!(matches!(&a.outbox[0], HostRequest::SoundPlay { sound: SoundName::Bell, pitch: -12, .. }));
        for level in [f32::NAN, 2.0, -1.0] {
            assert!(wsound::Host::ambient(&mut a, wsound::Name::Rain, level).is_err(), "{level}");
        }
    }

    #[test]
    fn a_disabled_plugin_stops_its_loop_and_its_voice() {
        let mut a = state("dev.haunt.a", &Stage::default());
        wsound::Host::ambient(&mut a, wsound::Name::Rain, 0.3).unwrap();
        wspeech::Host::say(&mut a, "build done".into()).unwrap();
        a.outbox.clear();
        a.release_fx();
        assert!(matches!(&a.outbox[..], [HostRequest::SoundAmbient { level, .. }, HostRequest::SayStop { .. }] if *level == 0.0), "{:?}", a.outbox);
        a.outbox.clear();
        a.release_fx();
        assert!(a.outbox.is_empty(), "nothing left to stop");
        wsound::Host::ambient(&mut a, wsound::Name::Rain, 0.0).unwrap();
        a.outbox.clear();
        a.release_fx();
        assert!(a.outbox.is_empty(), "a loop set to 0 is already off");
    }

    #[test]
    fn speech_is_plain_capped_and_one_every_two_seconds() {
        let mut a = state("dev.haunt.a", &Stage::default());
        assert!(wspeech::Host::say(&mut a, " \u{200b}\u{202e}\n".into()).unwrap_err().contains("nothing"));
        wspeech::Host::say(&mut a, format!("tests\u{202e} passed\u{1b}]0;x\u{7}\n{}", "z".repeat(300))).unwrap();
        let [HostRequest::Say { text, .. }] = &a.outbox[..] else { panic!("{:?}", a.outbox) };
        assert_eq!(text.chars().count(), SAY_MAX - 1, "the cut comes first, then the bracket goes");
        assert!(text.starts_with("tests passed0;x z"), "{text}");
        assert!(wspeech::Host::say(&mut a, "again".into()).unwrap_err().contains("2 seconds"));
        a.fx.say_rate = Rate::new(1, SAY_EVERY);
        a.outbox.clear();
        wspeech::Host::say(&mut a, "[\u{200B}[rate 900]][\u{AD}[volm 1]]hi".into()).unwrap();
        assert!(matches!(&a.outbox[..], [HostRequest::Say { text, .. }] if text == "rate 900volm 1hi"), "{:?}", a.outbox);
        let lines: Vec<_> = a.take_audit().into_iter().map(|l| (l.kind, l.surface, l.detail, l.n)).collect();
        let said = |n| ("speech.say".to_string(), String::new(), String::new(), n);
        assert_eq!(lines, [said(SAY_MAX as u64 - 1), said(16)], "spoken lengths only, never the text");
        a.fx.say_rate = Rate::new(1, SAY_EVERY);
        assert!(wspeech::Host::say(&mut a, "[[]] [\u{200B}]".into()).unwrap_err().contains("nothing"));
        wspeech::Host::stop(&mut a);
        wspeech::Host::stop(&mut a);
        assert_eq!(a.outbox.iter().filter(|r| matches!(r, HostRequest::SayStop { .. })).count(), 1);
    }
}
