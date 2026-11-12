//! The `dock` import: checks, rate limits and the one-owner rule. A child of `plugins`, so it implements
//! the WIT host traits on `HostState`.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub(super) use super::bindings::haunt::plugin::dock as wdock;
use super::{HostRequest, HostState};

/// The app-wide spots one plugin at a time may own: the first to set one keeps it until it clears it,
/// is disabled or is reloaded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Slot {
    Dock,
}

/// Who owns each `Slot`, shared by every plugin of one set.
#[derive(Debug, Clone, Default)]
pub struct Stage(Arc<Mutex<Vec<(Slot, String)>>>);

impl Stage {
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

pub const DOCK_IMAGES_MAX: usize = 8;
pub const DOCK_PNG_MAX: usize = 1 << 20;
/// Pixels each way; the Dock draws a tile at most 512 points, 1024 pixels on Retina.
pub const DOCK_PIXELS_MAX: u32 = 1024;
const DOCK_ID_MAX: usize = 32;
const SHOWS_PER_SEC: usize = 4;

/// One plugin's per-instance state for these imports.
#[derive(Debug)]
pub(crate) struct Fx {
    dock_images: Vec<(String, Vec<u8>)>,
    dock_images_rate: Rate,
    dock_rate: Rate,
}

impl Default for Fx {
    fn default() -> Self {
        Self {
            dock_images: Vec::new(),
            dock_images_rate: Rate::new(1, Duration::from_secs(1)),
            dock_rate: Rate::new(SHOWS_PER_SEC, Duration::from_secs(1)),
        }
    }
}

/// A Dock tile image: the PNG as the plugin gave it, checked by `check_png`; the app decodes it again
/// and drops it if that fails.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct DockImage {
    pub id: String,
    pub png: Vec<u8>,
}

fn dock_id_ok(id: &str) -> bool {
    (1..=DOCK_ID_MAX).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// A still PNG of at most `DOCK_PIXELS_MAX` pixels each way: the signature, an IHDR first, whole
/// chunks, no animation (`acTL`), and IEND last.
pub(crate) fn check_png(png: &[u8]) -> Result<(u32, u32), String> {
    const SIG: &[u8] = b"\x89PNG\r\n\x1a\n";
    if png.len() > DOCK_PNG_MAX {
        return Err(format!("larger than {DOCK_PNG_MAX} bytes"));
    }
    let mut rest = png.strip_prefix(SIG).ok_or("not a PNG")?;
    let mut size = None;
    let mut first = true;
    loop {
        if rest.len() < 12 {
            return Err("a PNG cut short".into());
        }
        let len = u32::from_be_bytes(rest[..4].try_into().unwrap()) as usize;
        let kind = &rest[4..8];
        let Some(data) = rest.get(8..8 + len).filter(|_| rest.len() >= 12 + len) else { return Err("a PNG chunk runs past the end".into()) };
        if first {
            if kind != b"IHDR" || len != 13 {
                return Err("a PNG without its header".into());
            }
            let w = u32::from_be_bytes(data[..4].try_into().unwrap());
            let h = u32::from_be_bytes(data[4..8].try_into().unwrap());
            if !(1..=DOCK_PIXELS_MAX).contains(&w) || !(1..=DOCK_PIXELS_MAX).contains(&h) {
                return Err(format!("{w}×{h} pixels; at most {DOCK_PIXELS_MAX} each way"));
            }
            size = Some((w, h));
            first = false;
        } else if kind == b"IHDR" {
            return Err("two PNG headers".into());
        }
        if kind == b"acTL" {
            return Err("an animated PNG; send each frame as its own image".into());
        }
        rest = &rest[8 + len + 4..];
        if kind == b"IEND" {
            return if rest.is_empty() { size.ok_or_else(|| "an empty PNG".into()) } else { Err("bytes after the PNG's end".into()) };
        }
    }
}

impl HostState {
    /// A disabled plugin gives back what it owns, and the app puts haunt's own back.
    pub(crate) fn release_fx(&mut self) {
        if self.stage.release(Slot::Dock, &self.id) {
            self.outbox.push(HostRequest::DockShow { plugin_id: self.id.clone(), image: None, badge: None, blink: None });
        }
    }

    fn dock_image(&self, id: &str) -> Result<DockImage, String> {
        self.fx
            .dock_images
            .iter()
            .find(|(i, _)| i == id)
            .map(|(id, png)| DockImage { id: id.clone(), png: png.clone() })
            .ok_or_else(|| format!("no image {id:?}; register it with images first"))
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
        self.fx.dock_images = images;
        Ok(())
    }

    fn show(&mut self, id: Option<String>, badge: Option<u32>, blink: Option<String>) -> Result<(), String> {
        let plugin_id = self.id.clone();
        if id.is_none() && badge.is_none() {
            if blink.is_some() {
                return Err("blink needs an image to go back to".into());
            }
            if self.stage.release(Slot::Dock, &plugin_id) {
                self.outbox.push(HostRequest::DockShow { plugin_id, image: None, badge: None, blink: None });
            }
            return Ok(());
        }
        let image = id.as_deref().map(|i| self.dock_image(i)).transpose()?;
        let blink = blink.as_deref().map(|i| self.dock_image(i)).transpose()?;
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
        self.request(HostRequest::DockShow { plugin_id, image, badge, blink })
    }
}

#[cfg(test)]
mod tests {
    use super::super::{Capabilities, PluginHost};
    use super::*;
    use wasmtime::component::Component;

    pub(crate) fn state(id: &str, stage: &Stage) -> HostState {
        let mut st = HostState::new(id, &Capabilities::default(), None, None, None);
        st.stage = stage.clone();
        st
    }

    pub(crate) fn png(w: u32, h: u32, extra: &[u8]) -> Vec<u8> {
        let chunk = |kind: &[u8], data: &[u8]| [&(data.len() as u32).to_be_bytes()[..], kind, data, &[0; 4]].concat();
        let ihdr = [&w.to_be_bytes()[..], &h.to_be_bytes(), &[8, 6, 0, 0, 0]].concat();
        [&b"\x89PNG\r\n\x1a\n"[..], &chunk(b"IHDR", &ihdr), extra, &chunk(b"IDAT", &[0; 16]), &chunk(b"IEND", &[])].concat()
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
        assert_eq!(check_png(&png(1024, 1024, &[])), Ok((1024, 1024)));
        let actl = [&8u32.to_be_bytes()[..], b"acTL", &[0; 8], &[0; 4]].concat();
        for (bad, why) in [
            (png(1025, 10, &[]), "pixels"),
            (png(0, 10, &[]), "pixels"),
            (png(64, 64, &actl), "animated"),
            (b"GIF89a".to_vec(), "not a PNG"),
            (png(64, 64, &[])[..50].to_vec(), "past the end"),
            (png(64, 64, &[])[..40].to_vec(), "cut short"),
            ([png(64, 64, &[]), b"tail".to_vec()].concat(), "after the PNG"),
            ([png(64, 64, &[]), vec![0; DOCK_PNG_MAX]].concat(), "larger than"),
        ] {
            let e = check_png(&bad).unwrap_err();
            assert!(e.contains(why), "{why}: {e}");
        }
    }

    #[test]
    fn dock_images_are_capped_named_and_rate_limited() {
        let stage = Stage::default();
        let mut st = state("dev.haunt.a", &stage);
        let img = |id: &str| (id.to_owned(), png(64, 64, &[]));
        let nine: Vec<_> = (0..9).map(|i| img(&format!("s{i}"))).collect();
        assert!(wdock::Host::images(&mut st, nine).unwrap_err().contains("at most 8"));
        for bad in ["", "a b", "ghost\u{202e}", "../x", &"x".repeat(33)] {
            assert!(wdock::Host::images(&mut st, vec![img(bad)]).unwrap_err().contains("must be"), "{bad:?}");
        }
        assert!(wdock::Host::images(&mut st, vec![img("a"), img("a")]).unwrap_err().contains("twice"));
        assert!(wdock::Host::images(&mut st, vec![("a".into(), b"no".to_vec())]).unwrap_err().contains("not a PNG"));
        wdock::Host::images(&mut st, vec![img("idle"), img("busy")]).unwrap();
        assert!(wdock::Host::images(&mut st, vec![img("idle")]).unwrap_err().contains("once a second"));
        assert!(st.outbox.is_empty(), "images alone change nothing on screen");
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
        assert_eq!((i.id.as_str(), k.id.as_str(), i.png.len()), ("idle", "blink", png(64, 64, &[]).len()));
        assert!(wdock::Host::show(&mut b, Some("idle".into()), None, None).unwrap_err().contains("dev.haunt.a has it"));
        wdock::Host::show(&mut b, None, None, None).unwrap();
        assert!(b.outbox.is_empty(), "a non-owner clearing changes nothing");

        a.outbox.clear();
        wdock::Host::show(&mut a, None, None, None).unwrap();
        assert!(matches!(&a.outbox[..], [HostRequest::DockShow { image: None, badge: None, blink: None, .. }]));
        wdock::Host::show(&mut b, None, Some(1), None).unwrap();
        assert_eq!(stage.owner(Slot::Dock).as_deref(), Some("dev.haunt.b"));
    }

    #[test]
    fn a_disabled_owner_gives_the_dock_tile_back() {
        let stage = Stage::default();
        let mut a = state("dev.haunt.a", &stage);
        wdock::Host::images(&mut a, vec![("idle".into(), png(8, 8, &[]))]).unwrap();
        wdock::Host::show(&mut a, Some("idle".into()), None, None).unwrap();
        a.outbox.clear();
        a.release_fx();
        assert!(matches!(&a.outbox[..], [HostRequest::DockShow { image: None, badge: None, blink: None, .. }]));
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
