//! A theme's `[[layer]]` tables: shapes and images a theme draws into Haunt's slots, checked and capped
//! here so the app only ever sees the documented shapes. See docs/themes.md, "Layers".

use std::collections::HashMap;

pub const MAX_LAYERS: usize = 64;
pub const MAX_PRIMS: usize = 16;
pub const MAX_PATH_CMDS: usize = 256;
pub const MAX_COORD: f64 = 400.0;
pub const MAX_IMAGES: usize = 8;
pub const MAX_PNG_BYTES: usize = 256 << 10;
pub const MAX_PNG_PIXELS: u32 = 512;
pub const MAX_DECODED_BYTES: usize = 4 << 20;
pub const MAX_STOPS: usize = 8;
pub const MAX_CELL: f64 = 16.0;
pub const MAX_DOTS: usize = 64;
pub const MAX_DASH: usize = 4;
pub const MAX_BLUR: f64 = 12.0;
pub const MAX_SHADOW_OFFSET: f64 = 6.0;
pub const MAX_RINGS: usize = 2;
pub const MAX_WIDTH: f64 = 8.0;
const MAX_ID: usize = 32;

/// Where a layer may draw. Each is clipped to its own bounds in the app, and none covers the terminal.
pub const SLOTS: &[&str] = &[
    "window.bg",
    "pane.backdrop",
    "pane.frame",
    "titlebar",
    "lights",
    "sidebar",
    "sidebar.footer",
    "label.group",
    "row",
    "row.selected",
    "row.hover",
    "icon",
    "bar.track",
    "bar.fill",
    "status.needs",
    "palette",
    "palette.caption",
    "palette.field",
    "palette.row.selected",
    "palette.row.hover",
    "button",
    "button.default",
];

pub const STATES: &[&str] = &["focused", "inactive", "selected", "hover", "pressed"];
const KINDS: &[&str] = &["rect", "line", "gradient", "bevel", "pattern", "image", "path", "shadow"];

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct LayerSet {
    pub layers: Vec<Layer>,
    pub images: Vec<LayerImage>,
    /// Each one says what was skipped and why.
    pub problems: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Layer {
    pub id: Option<String>,
    pub slot: String,
    /// Empty: every state.
    pub when: Vec<String>,
    pub opacity: f64,
    /// For `lights`: only the light at this index.
    pub index: Option<u8>,
    pub prims: Vec<LayerPrim>,
}

/// One axis of a primitive's frame: either insets from the slot's two edges, or an anchor and a length.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct LayerSpan {
    /// "inset", or an anchor: "left", "center", "right", "text.left", "text.right" (x); "top", "center", "bottom" (y).
    pub mode: String,
    /// Inset mode: the near and far insets. Anchor mode: `a` is the offset from the anchor, `b` the length.
    pub a: f64,
    pub b: f64,
    /// Inset mode: the near edge starts at the slot text's trailing edge instead of the slot's (x only).
    pub from_text: bool,
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct LayerStop {
    pub color: String,
    /// 0–1.
    pub at: f64,
}

/// A path command in the frame's own units (`view`), absolute: "M" and "L" take 2 numbers, "Q" 4, "C" 6, "Z" none.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct LayerPathCmd {
    pub op: String,
    pub pts: Vec<f64>,
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct LayerPrim {
    pub kind: String,
    pub x: LayerSpan,
    pub y: LayerSpan,
    pub radius: f64,
    /// Colours are "#rrggbb", "#rrggbbaa" or "@token" (a colour token's name, resolved by the app).
    pub fill: Option<String>,
    pub stroke: Option<String>,
    pub width: f64,
    pub dash: Vec<f64>,
    /// line: "top", "bottom", "left", "right", "hmid" or "vmid" of the frame.
    pub along: String,
    /// gradient: 0 runs left to right, 90 top to bottom.
    pub angle: f64,
    pub stops: Vec<LayerStop>,
    /// bevel: up to two 1 pt rings, outermost first, each [top, left, bottom, right].
    pub rings: Vec<Vec<String>>,
    /// pattern: the cell's size, and its 1 pt dots as (colour, x, y).
    pub cell: Vec<f64>,
    pub dots: Vec<LayerStop>,
    pub dot_y: Vec<f64>,
    /// image or pattern tile: an index into `LayerSet::images`.
    pub image: Option<u32>,
    /// image and path: "none", "corners" (a quarter turn more at each corner, clockwise from the top left) or "tile".
    pub repeat_mode: String,
    pub path: Vec<LayerPathCmd>,
    pub view: Vec<f64>,
    /// shadow
    pub blur: f64,
    pub offset: Vec<f64>,
    pub color: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct LayerImage {
    pub name: String,
    pub width: u32,
    pub height: u32,
    /// Straight-alpha RGBA, `width * height * 4` bytes.
    pub rgba: Vec<u8>,
}

/// A file from the theme's package, by its plain name.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ThemeFile {
    pub name: String,
    pub bytes: Vec<u8>,
}

/// One theme file in an `extends` chain: its name for messages, its text, and the PNGs its layers may name.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ThemeSource {
    pub name: String,
    pub toml: String,
    pub files: Vec<ThemeFile>,
}

/// The `[[layer]]` tables in one theme file, with `files` the PNGs they may name.
pub fn parse(text: &str, files: &[ThemeFile]) -> LayerSet {
    parse_chain(&[ThemeSource { name: "theme".into(), toml: text.into(), files: files.to_vec() }])
}

/// The layers of a theme's `extends` chain, ancestors first: a layer whose `id` an earlier file used replaces
/// that one in place, and the caps hold for the chain as a whole. Never fails: whatever is wrong is skipped at
/// the narrowest level (a key, then a primitive, then a layer) and named in `problems`.
pub fn parse_chain(sources: &[ThemeSource]) -> LayerSet {
    let mut out = LayerSet { layers: Vec::new(), images: Vec::new(), problems: Vec::new() };
    let mut decoded = 0;
    for src in sources {
        let file = clip(&src.name);
        let table: toml::Table = match toml::from_str(&src.toml) {
            Ok(t) => t,
            Err(e) => {
                out.problems.push(format!("{file}: layers: the file doesn't parse: {}", e.message()));
                continue;
            }
        };
        let Some(raw) = table.get("layer") else { continue };
        let Some(raw) = raw.as_array() else {
            out.problems.push(format!("{file}: layer: not an array of tables ([[layer]])"));
            continue;
        };
        let mut cx = Cx { files: &src.files, images: &mut out.images, decoded, problems: &mut out.problems, names: HashMap::new() };
        for (i, v) in raw.iter().enumerate() {
            let at = format!("{file}: layer {}", i + 1);
            let Some(t) = v.as_table() else {
                cx.bad(&at, "not a table");
                continue;
            };
            let Some(l) = cx.layer(t, &at) else { continue };
            if let Some(old) = l.id.as_ref().and_then(|id| out.layers.iter_mut().find(|o| o.id.as_ref() == Some(id))) {
                *old = l;
            } else if out.layers.len() == MAX_LAYERS {
                cx.bad(&at, format!("more than {MAX_LAYERS} layers; the rest are skipped"));
                break;
            } else {
                out.layers.push(l);
            }
        }
        decoded = cx.decoded;
    }
    out
}

struct Cx<'a> {
    files: &'a [ThemeFile],
    images: &'a mut Vec<LayerImage>,
    decoded: usize,
    problems: &'a mut Vec<String>,
    names: HashMap<String, u32>,
}

impl Cx<'_> {
    fn bad(&mut self, at: &str, why: impl std::fmt::Display) {
        self.problems.push(format!("{at}: {why}"));
    }

    fn layer(&mut self, t: &toml::Table, at: &str) -> Option<Layer> {
        let slot = match t.get("slot").and_then(|v| v.as_str()) {
            Some(s) if SLOTS.contains(&s) => s.to_owned(),
            Some(s) => return self.skip(at, format!("unknown slot {:?}; layer skipped", clip(s))),
            None => return self.skip(at, "no slot; layer skipped"),
        };
        let at = &format!("{at} ({slot})");
        let mut l = Layer { id: None, slot, when: Vec::new(), opacity: 1.0, index: None, prims: Vec::new() };
        for (k, v) in t {
            match k.as_str() {
                "slot" | "draw" => {}
                "id" => match v.as_str() {
                    Some(s) if valid_id(s) => l.id = Some(s.to_owned()),
                    _ => self.bad(at, "id: not [a-z0-9-], up to 32"),
                },
                "when" => match strings(v) {
                    Some(w) if w.iter().all(|s| STATES.contains(&s.as_str())) && !w.is_empty() => l.when = w,
                    _ => self.bad(at, format!("when: not a list of {}", STATES.join(", "))),
                },
                "opacity" => match num(v) {
                    Some(n) if (0.0..=1.0).contains(&n) => l.opacity = n,
                    _ => self.bad(at, "opacity: not a number from 0 to 1"),
                },
                "index" => match v.as_integer() {
                    Some(n @ 0..=2) if l.slot == "lights" => l.index = Some(n as u8),
                    _ => self.bad(at, "index: only for lights, 0 to 2"),
                },
                _ => self.bad(at, format!("unknown key {:?}", clip(k))),
            }
        }
        let draws = match t.get("draw") {
            None => return self.skip(at, "nothing to draw; layer skipped"),
            Some(d) => match d.as_array() {
                Some(a) => a,
                None => {
                    return self.skip(at, "draw: not an array of tables ([[layer.draw]]); layer skipped");
                }
            },
        };
        for (j, d) in draws.iter().enumerate() {
            let pat = format!("{at} draw {}", j + 1);
            if l.prims.len() == MAX_PRIMS {
                self.bad(&pat, format!("more than {MAX_PRIMS} shapes in a layer; the rest are skipped"));
                break;
            }
            match d.as_table() {
                Some(d) => {
                    if let Some(p) = self.prim(d, &pat, &l.slot) {
                        l.prims.push(p);
                    }
                }
                None => self.bad(&pat, "not a table"),
            }
        }
        if l.prims.is_empty() {
            return self.skip(at, "nothing left to draw; layer skipped");
        }
        Some(l)
    }

    fn skip<T>(&mut self, at: &str, why: impl std::fmt::Display) -> Option<T> {
        self.bad(at, why);
        None
    }

    fn prim(&mut self, t: &toml::Table, at: &str, slot: &str) -> Option<LayerPrim> {
        let kind = match t.get("kind").and_then(|v| v.as_str()) {
            Some(k) if KINDS.contains(&k) => k,
            Some(k) => return self.skip(at, format!("unknown kind {:?}; skipped", clip(k))),
            None => return self.skip(at, "no kind; skipped"),
        };
        let at = &format!("{at} ({kind})");
        let mut p = LayerPrim {
            kind: kind.to_owned(),
            x: LayerSpan { mode: "inset".into(), a: 0.0, b: 0.0, from_text: false },
            y: LayerSpan { mode: "inset".into(), a: 0.0, b: 0.0, from_text: false },
            radius: 0.0,
            fill: None,
            stroke: None,
            width: 1.0,
            dash: Vec::new(),
            along: "hmid".into(),
            angle: 90.0,
            stops: Vec::new(),
            rings: Vec::new(),
            cell: Vec::new(),
            dots: Vec::new(),
            dot_y: Vec::new(),
            image: None,
            repeat_mode: "none".into(),
            path: Vec::new(),
            view: Vec::new(),
            blur: 0.0,
            offset: vec![0.0, 0.0],
            color: None,
        };
        // Which keys each kind reads, beyond the frame's.
        let allowed: &[&str] = match kind {
            "rect" => &["radius", "fill", "stroke", "width", "dash"],
            "line" => &["stroke", "width", "dash", "along"],
            "gradient" => &["radius", "angle", "stops"],
            "bevel" => &["rings"],
            "pattern" => &["cell", "dots", "tile"],
            "image" => &["file", "repeat"],
            "path" => &["d", "view", "fill", "stroke", "width", "dash", "repeat"],
            _ => &["radius", "blur", "offset", "color"],
        };
        let frame = ["left", "right", "top", "bottom", "x", "y", "w", "h", "dx", "dy", "from_text", "kind"];
        for k in t.keys() {
            if !frame.contains(&k.as_str()) && !allowed.contains(&k.as_str()) {
                self.bad(at, format!("unknown key {:?} for {kind}", clip(k)));
            }
        }
        p.x = self.span(t, at, ["left", "right", "x", "w", "dx"], &["left", "center", "right", "text.left", "text.right"])?;
        p.y = self.span(t, at, ["top", "bottom", "y", "h", "dy"], &["top", "center", "bottom"])?;
        match t.get("from_text") {
            None => {}
            Some(v) if v.as_bool().is_some() && p.x.mode == "inset" && text_slot(slot) => p.x.from_text = v.as_bool() == Some(true),
            Some(_) => self.bad(at, "from_text: only true or false, with left/right insets, in a slot with text"),
        }
        if (p.x.mode.starts_with("text.") || p.x.from_text) && slot != "label.group" && slot != "status.needs" {
            return self.skip(at, "anchored to text in a slot without a text run; skipped");
        }
        for (k, v) in t {
            let ok = match k.as_str() {
                "radius" => num_in(v, 0.0, 40.0).map(|n| p.radius = n).ok_or("not a number from 0 to 40"),
                "width" => num_in(v, 0.25, MAX_WIDTH).map(|n| p.width = n).ok_or("not a number from 0.25 to 8"),
                "fill" => color(v).map(|c| p.fill = Some(c)).ok_or("not #rrggbb, #rrggbbaa or @token"),
                "stroke" => color(v).map(|c| p.stroke = Some(c)).ok_or("not #rrggbb, #rrggbbaa or @token"),
                "color" => color(v).map(|c| p.color = Some(c)).ok_or("not #rrggbb, #rrggbbaa or @token"),
                "dash" => match nums(v) {
                    Some(d) if (1..=MAX_DASH).contains(&d.len()) && d.iter().all(|n| (0.5..=40.0).contains(n)) => {
                        p.dash = d;
                        Ok(())
                    }
                    _ => Err("not 1 to 4 numbers from 0.5 to 40"),
                },
                "along" => match v.as_str() {
                    Some(s @ ("top" | "bottom" | "left" | "right" | "hmid" | "vmid")) => {
                        p.along = s.to_owned();
                        Ok(())
                    }
                    _ => Err("not top, bottom, left, right, hmid or vmid"),
                },
                "angle" => num_in(v, -360.0, 360.0).map(|n| p.angle = n).ok_or("not a number from -360 to 360"),
                "stops" => self.stops(v).map(|s| p.stops = s),
                "rings" => rings(v).map(|r| p.rings = r),
                "cell" => match nums(v) {
                    Some(c) if c.len() == 2 && c.iter().all(|n| (1.0..=MAX_CELL).contains(n)) => {
                        p.cell = c;
                        Ok(())
                    }
                    _ => Err("not [w, h], each from 1 to 16"),
                },
                "dots" => Ok(()),
                "tile" | "file" => match self.image(v) {
                    Ok(i) => {
                        p.image = Some(i);
                        Ok(())
                    }
                    Err(e) => return self.skip(at, format!("{k}: {e}; skipped")),
                },
                "repeat" => match v.as_str() {
                    Some(s @ ("none" | "corners" | "tile")) if !(kind == "path" && s == "tile") => {
                        p.repeat_mode = s.to_owned();
                        Ok(())
                    }
                    _ => Err("not none, corners or (for an image) tile"),
                },
                "d" => match v.as_str().map(path) {
                    Some(Ok(cmds)) => {
                        p.path = cmds;
                        Ok(())
                    }
                    Some(Err(e)) => return self.skip(at, format!("d: {e}; skipped")),
                    None => Err("not a string"),
                },
                "view" => match nums(v) {
                    Some(w) if w.len() == 2 && w.iter().all(|n| *n > 0.0 && *n <= MAX_COORD) => {
                        p.view = w;
                        Ok(())
                    }
                    _ => Err("not [w, h], each above 0 and up to 400"),
                },
                "blur" => num_in(v, 0.0, MAX_BLUR).map(|n| p.blur = n).ok_or("not a number from 0 to 12"),
                "offset" => match nums(v) {
                    Some(o) if o.len() == 2 && o.iter().all(|n| n.abs() <= MAX_SHADOW_OFFSET) => {
                        p.offset = o;
                        Ok(())
                    }
                    _ => Err("not [x, y], each from -6 to 6"),
                },
                _ => Ok(()),
            };
            if let Err(why) = ok {
                self.bad(at, format!("{k}: {why}"));
            }
        }
        if let Some(v) = t.get("dots") {
            match dots(v) {
                Some((d, y)) => {
                    p.dots = d;
                    p.dot_y = y;
                }
                None => self.bad(at, format!("dots: not up to {MAX_DOTS} \"#colour x y\" inside the cell")),
            }
        }
        // What each kind can't draw without.
        let missing = match kind {
            "rect" if p.fill.is_none() && p.stroke.is_none() => Some("a fill or a stroke"),
            "line" if p.stroke.is_none() => Some("a stroke"),
            "gradient" if p.stops.len() < 2 => Some("two stops"),
            "bevel" if p.rings.is_empty() => Some("rings"),
            "pattern" if p.image.is_none() && (p.cell.is_empty() || p.dots.is_empty()) => Some("a cell with dots, or a tile"),
            "image" if p.image.is_none() => Some("a file"),
            "path" if p.path.is_empty() || p.view.is_empty() || (p.fill.is_none() && p.stroke.is_none()) => Some("d, view, and a fill or a stroke"),
            "shadow" if p.color.is_none() || p.blur == 0.0 => Some("a color and a blur"),
            _ => None,
        };
        if let Some(m) = missing {
            return self.skip(at, format!("needs {m}; skipped"));
        }
        if p.dots.iter().any(|d| d.at >= p.cell.first().copied().unwrap_or(0.0))
            || p.dot_y.iter().any(|y| *y >= p.cell.get(1).copied().unwrap_or(0.0))
        {
            return self.skip(at, "a dot outside its cell; skipped");
        }
        Some(p)
    }

    /// One axis: `left`/`right` insets (the default, both 0), or `x` anchor + `w` length (+ `dx`).
    fn span(&mut self, t: &toml::Table, at: &str, [near, far, anchor, len, off]: [&str; 5], anchors: &[&str]) -> Option<LayerSpan> {
        let coord = |k: &str| t.get(k).map(|v| num_in(v, -MAX_COORD, MAX_COORD));
        let has_len = t.contains_key(len) || t.contains_key(anchor) || t.contains_key(off);
        if has_len && (t.contains_key(near) || t.contains_key(far)) {
            return self.skip(at, format!("{near}/{far} and {anchor}/{len} both given; skipped"));
        }
        if !has_len {
            let (Some(a), Some(b)) = (coord(near).unwrap_or(Some(0.0)), coord(far).unwrap_or(Some(0.0))) else {
                return self.skip(at, format!("{near}/{far}: not a number from -400 to 400; skipped"));
            };
            return Some(LayerSpan { mode: "inset".into(), a, b, from_text: false });
        }
        let mode = match t.get(anchor) {
            None => anchors[0].to_owned(),
            Some(v) => match v.as_str() {
                Some(s) if anchors.contains(&s) => s.to_owned(),
                _ => {
                    return self.skip(at, format!("{anchor}: not one of {}; skipped", anchors.join(", ")));
                }
            },
        };
        let Some(Some(b)) = t.get(len).map(|v| num_in(v, 0.0, MAX_COORD)) else {
            return self.skip(at, format!("{len}: needed with {anchor}, a number from 0 to 400; skipped"));
        };
        let Some(a) = coord(off).unwrap_or(Some(0.0)) else {
            return self.skip(at, format!("{off}: not a number from -400 to 400; skipped"));
        };
        Some(LayerSpan { mode, a, b, from_text: false })
    }

    fn stops(&mut self, v: &toml::Value) -> Result<Vec<LayerStop>, &'static str> {
        let s = strings(v).ok_or("not a list of \"#colour\" or \"#colour 40%\"")?;
        if !(2..=MAX_STOPS).contains(&s.len()) {
            return Err("not 2 to 8 stops");
        }
        let mut out = Vec::new();
        let placed = s.iter().filter(|x| x.contains(' ')).count();
        if placed != 0 && placed != s.len() {
            return Err("give every stop a place, or none");
        }
        for (i, x) in s.iter().enumerate() {
            let mut parts = x.split_whitespace();
            let c = parts.next().and_then(color_str).ok_or("a stop that isn't a colour")?;
            let at = match parts.next() {
                Some(p) => {
                    p.strip_suffix('%')
                        .and_then(|n| n.parse::<f64>().ok())
                        .filter(|n| (0.0..=100.0).contains(n))
                        .ok_or("a place that isn't 0% to 100%")?
                        / 100.0
                }
                None => i as f64 / (s.len() - 1) as f64,
            };
            if parts.next().is_some() || out.last().is_some_and(|l: &LayerStop| l.at > at) {
                return Err("stops out of order");
            }
            out.push(LayerStop { color: c, at });
        }
        Ok(out)
    }

    fn image(&mut self, v: &toml::Value) -> Result<u32, String> {
        let name = v.as_str().ok_or("not a file name")?;
        if !valid_png_name(name) {
            return Err(format!("{:?} isn't a plain [a-z0-9-].png name", clip(name)));
        }
        if let Some(&i) = self.names.get(name) {
            return Ok(i);
        }
        if self.images.len() == MAX_IMAGES {
            return Err(format!("more than {MAX_IMAGES} images"));
        }
        let f = self.files.iter().find(|f| f.name == name).ok_or("not in the theme's package")?;
        if f.bytes.len() > MAX_PNG_BYTES {
            return Err(format!("over {} KB", MAX_PNG_BYTES >> 10));
        }
        let (width, height, rgba) = decode_png(&f.bytes)?;
        if self.decoded + rgba.len() > MAX_DECODED_BYTES {
            return Err(format!("the images come to over {} MB decoded", MAX_DECODED_BYTES >> 20));
        }
        self.decoded += rgba.len();
        let i = self.images.len() as u32;
        self.images.push(LayerImage { name: name.to_owned(), width, height, rgba });
        self.names.insert(name.to_owned(), i);
        Ok(i)
    }
}

/// Slots whose content includes text Haunt draws on top.
pub fn text_slot(slot: &str) -> bool {
    !matches!(slot, "window.bg" | "pane.backdrop" | "pane.frame" | "lights" | "icon" | "bar.track" | "bar.fill")
}

fn clip(s: &str) -> String {
    s.chars().take(32).collect()
}

fn valid_id(s: &str) -> bool {
    (1..=MAX_ID).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn valid_png_name(s: &str) -> bool {
    s.strip_suffix(".png").is_some_and(valid_id)
}

fn num(v: &toml::Value) -> Option<f64> {
    v.as_float().or_else(|| v.as_integer().map(|i| i as f64)).filter(|n| n.is_finite())
}

fn num_in(v: &toml::Value, lo: f64, hi: f64) -> Option<f64> {
    num(v).filter(|n| (lo..=hi).contains(n))
}

fn nums(v: &toml::Value) -> Option<Vec<f64>> {
    v.as_array()?.iter().map(num).collect()
}

fn strings(v: &toml::Value) -> Option<Vec<String>> {
    v.as_array()?.iter().map(|s| s.as_str().map(str::to_owned)).collect()
}

fn color(v: &toml::Value) -> Option<String> {
    color_str(v.as_str()?)
}

/// "#rrggbb", "#rrggbbaa", or "@" and a colour token's name ("@row.selected", "@app.bevel.light").
fn color_str(s: &str) -> Option<String> {
    let hex = matches!(s.len(), 7 | 9) && s.starts_with('#') && s[1..].bytes().all(|b| b.is_ascii_hexdigit());
    let token = s
        .strip_prefix('@')
        .is_some_and(|t| (1..=64).contains(&t.len()) && t.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-'));
    (hex || token).then(|| s.to_owned())
}

fn rings(v: &toml::Value) -> Result<Vec<Vec<String>>, &'static str> {
    let why = "not up to 2 rings, each [top, left, bottom, right] colours";
    let a = v.as_array().ok_or(why)?;
    if a.is_empty() || a.len() > MAX_RINGS {
        return Err(why);
    }
    a.iter()
        .map(|r| {
            let s = strings(r).ok_or(why)?;
            if s.len() != 4 {
                return Err(why);
            }
            s.iter().map(|c| color_str(c).ok_or(why)).collect()
        })
        .collect()
}

/// "#colour x y" each: the colour, with x in `LayerStop::at` and y beside it.
fn dots(v: &toml::Value) -> Option<(Vec<LayerStop>, Vec<f64>)> {
    let s = strings(v)?;
    if s.is_empty() || s.len() > MAX_DOTS {
        return None;
    }
    let mut d = Vec::new();
    let mut ys = Vec::new();
    for x in s {
        let p: Vec<&str> = x.split_whitespace().collect();
        let [c, x, y] = p[..] else { return None };
        let (x, y) = (x.parse::<f64>().ok().filter(|n| *n >= 0.0)?, y.parse::<f64>().ok().filter(|n| *n >= 0.0)?);
        d.push(LayerStop { color: color_str(c)?, at: x });
        ys.push(y);
    }
    Some((d, ys))
}

/// The SVG path subset `M L H V C Q Z` (and their relative forms), made absolute: M, L, Q, C and Z.
pub fn path(d: &str) -> Result<Vec<LayerPathCmd>, String> {
    if d.len() > 16 << 10 {
        return Err("longer than 16 KB".into());
    }
    let mut toks = Vec::new();
    let mut num = String::new();
    let flush = |num: &mut String, toks: &mut Vec<Tok>| -> Result<(), String> {
        if !num.is_empty() {
            let n: f64 = num.parse().map_err(|_| format!("{:?} isn't a number", clip(num)))?;
            if !n.is_finite() || n.abs() > MAX_COORD {
                return Err(format!("{n} is outside -400 to 400"));
            }
            toks.push(Tok::N(n));
            num.clear();
        }
        Ok(())
    };
    for c in d.chars() {
        match c {
            'M' | 'm' | 'L' | 'l' | 'H' | 'h' | 'V' | 'v' | 'C' | 'c' | 'Q' | 'q' | 'Z' | 'z' => {
                flush(&mut num, &mut toks)?;
                toks.push(Tok::C(c));
            }
            '-' if !num.is_empty() && !num.ends_with('e') => {
                flush(&mut num, &mut toks)?;
                num.push(c);
            }
            '0'..='9' | '.' | '-' | 'e' => num.push(c),
            ' ' | ',' | '\n' | '\t' => flush(&mut num, &mut toks)?,
            _ => return Err(format!("{c:?} isn't in the path subset (M L H V C Q Z)")),
        }
    }
    flush(&mut num, &mut toks)?;
    let mut out: Vec<LayerPathCmd> = Vec::new();
    let (mut cur, mut start) = ((0.0, 0.0), (0.0, 0.0));
    let mut i = 0;
    let mut cmd = None;
    while i < toks.len() {
        if let Tok::C(c) = toks[i] {
            cmd = Some(c);
            i += 1;
            if c == 'Z' || c == 'z' {
                out.push(LayerPathCmd { op: "Z".into(), pts: Vec::new() });
                cur = start;
                cmd = None;
                continue;
            }
        }
        let Some(c) = cmd else {
            return Err("numbers before a command".into());
        };
        let n = match c.to_ascii_uppercase() {
            'H' | 'V' => 1,
            'M' | 'L' => 2,
            'Q' => 4,
            _ => 6,
        };
        let mut args = Vec::with_capacity(n);
        for _ in 0..n {
            match toks.get(i) {
                Some(Tok::N(v)) => args.push(*v),
                _ => return Err(format!("{c} needs {n} numbers")),
            }
            i += 1;
        }
        let rel = c.is_ascii_lowercase();
        let (ox, oy) = if rel { cur } else { (0.0, 0.0) };
        let (op, pts) = match c.to_ascii_uppercase() {
            'H' => ("L", vec![args[0] + ox, cur.1]),
            'V' => ("L", vec![cur.0, args[0] + if rel { cur.1 } else { 0.0 }]),
            'M' => ("M", vec![args[0] + ox, args[1] + oy]),
            'L' => ("L", vec![args[0] + ox, args[1] + oy]),
            'Q' => ("Q", vec![args[0] + ox, args[1] + oy, args[2] + ox, args[3] + oy]),
            _ => ("C", args.chunks(2).flat_map(|p| [p[0] + ox, p[1] + oy]).collect()),
        };
        if pts.iter().any(|v: &f64| v.abs() > MAX_COORD) {
            return Err("a point outside -400 to 400".into());
        }
        cur = (pts[pts.len() - 2], pts[pts.len() - 1]);
        if op == "M" {
            start = cur;
            // Further pairs after a moveto are linetos, as in SVG.
            cmd = Some(if rel { 'l' } else { 'L' });
        }
        if out.is_empty() && op != "M" {
            return Err("a path must start with M".into());
        }
        out.push(LayerPathCmd { op: op.into(), pts });
        if out.len() > MAX_PATH_CMDS {
            return Err(format!("more than {MAX_PATH_CMDS} commands"));
        }
    }
    if out.is_empty() {
        return Err("empty".into());
    }
    Ok(out)
}

enum Tok {
    C(char),
    N(f64),
}

/// `png` decoded to straight-alpha RGBA, at most `MAX_PNG_PIXELS` each way; animated PNGs are refused.
/// TODO(host-b): share `plugin_fx::decode_png` once it lands.
pub fn decode_png(png: &[u8]) -> Result<(u32, u32, Vec<u8>), String> {
    let bad = |e: png::DecodingError| format!("a PNG that doesn't decode: {e}");
    let limits = png::Limits { bytes: (MAX_PNG_PIXELS * MAX_PNG_PIXELS * 4) as usize };
    let mut d = png::Decoder::new_with_limits(std::io::Cursor::new(png), limits);
    d.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut r = d.read_info().map_err(bad)?;
    let (w, h) = (r.info().width, r.info().height);
    if !(1..=MAX_PNG_PIXELS).contains(&w) || !(1..=MAX_PNG_PIXELS).contains(&h) {
        return Err(format!("{w}×{h} pixels; at most {MAX_PNG_PIXELS} each way"));
    }
    if r.info().animation_control.is_some() {
        return Err("an animated PNG".into());
    }
    let mut buf = vec![0; r.output_buffer_size().ok_or("a PNG too large to decode")?];
    let info = r.next_frame(&mut buf).map_err(bad)?;
    buf.truncate(info.buffer_size());
    if info.bit_depth != png::BitDepth::Eight {
        return Err("a PNG that doesn't decode to 8 bits".into());
    }
    let rgba: Vec<u8> = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => buf.as_chunks::<3>().0.iter().flat_map(|&[r, g, b]| [r, g, b, 255]).collect(),
        png::ColorType::GrayscaleAlpha => buf.as_chunks::<2>().0.iter().flat_map(|&[g, a]| [g, g, g, a]).collect(),
        png::ColorType::Grayscale => buf.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::Indexed => return Err("a palette PNG that didn't expand".into()),
    };
    if rgba.len() != w as usize * h as usize * 4 {
        return Err("a PNG that decodes short".into());
    }
    Ok((w, h, rgba))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(w: u32, h: u32) -> Vec<u8> {
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, w, h);
        e.set_color(png::ColorType::Rgba);
        e.set_depth(png::BitDepth::Eight);
        let mut wr = e.write_header().unwrap();
        wr.write_image_data(&vec![200; (w * h * 4) as usize]).unwrap();
        wr.finish().unwrap();
        out
    }

    fn one(text: &str) -> LayerSet {
        parse(text, &[])
    }

    #[test]
    fn every_kind_parses() {
        let files = [ThemeFile { name: "corner.png".into(), bytes: png(4, 4) }];
        let s = parse(
            r##"
[[layer]]
id = "a"
slot = "row.selected"
when = ["focused"]
opacity = 0.5
  [[layer.draw]]
  kind = "rect"
  left = 2
  right = 2
  radius = 4
  fill = "@row.selected"
  stroke = "#ffffff26"
  dash = [2, 2]
  [[layer.draw]]
  kind = "line"
  along = "bottom"
  stroke = "#000000"
  [[layer.draw]]
  kind = "gradient"
  angle = 0
  stops = ["#ffffff20 0%", "#ffffff00 60%"]
  [[layer.draw]]
  kind = "bevel"
  rings = [["#ffffff", "#ffffff", "#000000", "#000000"], ["@hairline", "@hairline", "#808080", "#808080"]]
  [[layer.draw]]
  kind = "pattern"
  cell = [2, 2]
  dots = ["#00000014 0 0"]
  [[layer.draw]]
  kind = "shadow"
  radius = 9
  blur = 6
  offset = [0, 2]
  color = "#00000040"
[[layer]]
slot = "window.bg"
  [[layer.draw]]
  kind = "image"
  file = "corner.png"
  x = "left"
  w = 46
  y = "top"
  h = 46
  repeat = "corners"
  [[layer.draw]]
  kind = "path"
  d = "M23 0 L46 23 l-23 23 H0 v-23 C1 2 3 4 5 6 Q1 2 3 4 Z"
  view = [46, 46]
  stroke = "@text.meta"
"##,
            &files,
        );
        assert!(s.problems.is_empty(), "{:?}", s.problems);
        assert_eq!(s.layers.len(), 2);
        assert_eq!(s.layers[0].prims.iter().map(|p| p.kind.as_str()).collect::<Vec<_>>(), ["rect", "line", "gradient", "bevel", "pattern", "shadow"]);
        assert_eq!(s.layers[0].prims[0].x, LayerSpan { mode: "inset".into(), a: 2.0, b: 2.0, from_text: false });
        assert_eq!(s.layers[0].prims[2].stops[1].at, 0.6);
        let img = &s.layers[1].prims[0];
        assert_eq!((img.image, img.repeat_mode.as_str(), img.x.mode.as_str(), img.x.b), (Some(0), "corners", "left", 46.0));
        assert_eq!(s.images.len(), 1);
        assert_eq!(s.images[0].rgba.len(), 64);
        let ops: Vec<_> = s.layers[1].prims[1].path.iter().map(|c| c.op.as_str()).collect();
        assert_eq!(ops, ["M", "L", "L", "L", "L", "C", "Q", "Z"]);
        assert_eq!(s.layers[1].prims[1].path[2].pts, [23.0, 46.0], "relative made absolute");
        assert_eq!(s.layers[1].prims[1].path[3].pts, [0.0, 46.0]);
        assert_eq!(s.layers[1].prims[1].path[4].pts, [0.0, 23.0]);
    }

    #[test]
    fn bad_input_is_skipped_at_the_narrowest_level() {
        let s = one(r##"
[[layer]]
slot = "terminal"
  [[layer.draw]]
  kind = "rect"
  fill = "#000000"
[[layer]]
slot = "sidebar"
glow = true
  [[layer.draw]]
  kind = "text"
  [[layer.draw]]
  kind = "rect"
  fill = "red"
  stroke = "#ffffff"
  sparkle = 1
  [[layer.draw]]
  kind = "rect"
  [[layer.draw]]
  kind = "rect"
  fill = "#000000"
  left = 1
  x = "left"
  w = 3
"##);
        assert_eq!(s.layers.len(), 1, "{:?}", s.problems);
        assert_eq!(s.layers[0].slot, "sidebar");
        assert_eq!(s.layers[0].prims.len(), 1, "only the rect with a valid stroke");
        assert_eq!(s.layers[0].prims[0].fill, None);
        let p = s.problems.join("\n");
        for want in [
            "unknown slot \"terminal\"",
            "unknown key \"glow\"",
            "unknown kind \"text\"",
            "fill: not",
            "unknown key \"sparkle\"",
            "needs a fill or a stroke",
            "both given",
        ] {
            assert!(p.contains(want), "{want}: {p}");
        }
        assert_eq!(s.problems.len(), 7, "{p}");
    }

    #[test]
    fn caps_hold_at_their_edges() {
        let layer = |n: usize| {
            let draws = "  [[layer.draw]]\n  kind = \"rect\"\n  fill = \"#000000\"\n".repeat(n);
            format!("[[layer]]\nslot = \"sidebar\"\n{draws}")
        };
        let s = one(&layer(MAX_PRIMS));
        assert!(s.problems.is_empty() && s.layers[0].prims.len() == MAX_PRIMS);
        let s = one(&layer(MAX_PRIMS + 1));
        assert_eq!((s.layers[0].prims.len(), s.problems.len()), (MAX_PRIMS, 1));

        let s = one(&layer(1).repeat(MAX_LAYERS));
        assert!(s.problems.is_empty() && s.layers.len() == MAX_LAYERS);
        let s = one(&layer(1).repeat(MAX_LAYERS + 1));
        assert_eq!((s.layers.len(), s.problems.len()), (MAX_LAYERS, 1));

        let d = |n: usize| format!("M0 0{}", " L1 1".repeat(n - 1));
        assert_eq!(path(&d(MAX_PATH_CMDS)).unwrap().len(), MAX_PATH_CMDS);
        assert!(path(&d(MAX_PATH_CMDS + 1)).is_err());
        assert!(path("M0 0 L400 400").is_ok() && path("M0 0 L401 0").is_err() && path("M0 0 l300 0 l200 0").is_err());

        let stops = |n: usize| {
            format!("[[layer]]\nslot = \"sidebar\"\n  [[layer.draw]]\n  kind = \"gradient\"\n  stops = [{}]\n", vec!["\"#000000\""; n].join(","))
        };
        assert!(one(&stops(MAX_STOPS)).problems.is_empty());
        assert_eq!(one(&stops(MAX_STOPS + 1)).layers.len(), 0);

        let shadow =
            |b: f64| format!("[[layer]]\nslot = \"row.selected\"\n  [[layer.draw]]\n  kind = \"shadow\"\n  color = \"#000000\"\n  blur = {b}\n");
        assert!(one(&shadow(MAX_BLUR)).problems.is_empty());
        assert!(one(&shadow(MAX_BLUR + 0.5)).layers.is_empty());
        let big = |x: f64| format!("[[layer]]\nslot = \"sidebar\"\n  [[layer.draw]]\n  kind = \"rect\"\n  fill = \"#000000\"\n  left = {x}\n");
        assert!(one(&big(MAX_COORD)).problems.is_empty() && one(&big(MAX_COORD + 1.0)).layers.is_empty());
    }

    #[test]
    fn images_are_plain_names_from_the_package_and_capped() {
        let img = |name: &str| format!("[[layer]]\nslot = \"window.bg\"\n  [[layer.draw]]\n  kind = \"image\"\n  file = \"{name}\"\n");
        let ok = [ThemeFile { name: "a.png".into(), bytes: png(2, 2) }];
        for name in ["../a.png", "/a.png", "sub/a.png", "a.svg", "A.png", "a.png.png"] {
            let s = parse(&img(name), &ok);
            assert!(s.layers.is_empty() && s.images.is_empty(), "{name}");
        }
        assert!(parse(&img("b.png"), &ok).problems[0].contains("not in the theme's package"));
        assert_eq!(parse(&img("a.png"), &ok).images.len(), 1);

        let too_wide = [ThemeFile { name: "a.png".into(), bytes: png(MAX_PNG_PIXELS + 1, 1) }];
        assert!(parse(&img("a.png"), &too_wide).problems[0].contains("at most 512"));
        let edge = [ThemeFile { name: "a.png".into(), bytes: png(MAX_PNG_PIXELS, 1) }];
        assert!(parse(&img("a.png"), &edge).problems.is_empty());
        let junk = [ThemeFile { name: "a.png".into(), bytes: b"\x89PNG\r\n\x1a\nnope".to_vec() }];
        assert!(parse(&img("a.png"), &junk).problems[0].contains("doesn't decode"));
        let heavy = [ThemeFile { name: "a.png".into(), bytes: vec![0; MAX_PNG_BYTES + 1] }];
        assert!(parse(&img("a.png"), &heavy).problems[0].contains("over 256 KB"));

        // Nine distinct images: the ninth is refused; the same name twice decodes once.
        let files: Vec<_> = (0..=MAX_IMAGES).map(|i| ThemeFile { name: format!("i{i}.png"), bytes: png(1, 1) }).collect();
        let text: String = (0..=MAX_IMAGES).map(|i| img(&format!("i{i}.png"))).collect::<String>() + &img("i0.png");
        let s = parse(&text, &files);
        assert_eq!((s.images.len(), s.layers.len(), s.problems.len()), (MAX_IMAGES, MAX_IMAGES + 1, 2), "{:?}", s.problems);

        // 4 MB decoded in all: four 512×512 images (1 MB each) fit, a fifth doesn't.
        let files: Vec<_> = (0..5).map(|i| ThemeFile { name: format!("b{i}.png"), bytes: png(512, 512) }).collect();
        let text: String = (0..5).map(|i| img(&format!("b{i}.png"))).collect();
        let s = parse(&text, &files);
        assert_eq!(s.images.len(), 4, "{:?}", s.problems);
        assert!(s.problems[0].contains("over 4 MB"));
    }

    #[test]
    fn text_anchors_need_a_text_run_and_states_are_known() {
        let s = one(
            "[[layer]]\nslot = \"label.group\"\nwhen = [\"hover\"]\n  [[layer.draw]]\n  kind = \"line\"\n  stroke = \"#ffffff\"\n  left = 6\n  from_text = true\n",
        );
        assert!(s.problems.is_empty(), "{:?}", s.problems);
        assert!(s.layers[0].prims[0].x.from_text);
        let s = one("[[layer]]\nslot = \"sidebar\"\n  [[layer.draw]]\n  kind = \"line\"\n  stroke = \"#ffffff\"\n  x = \"text.right\"\n  w = 4\n");
        assert!(s.layers.is_empty());
        let s = one("[[layer]]\nslot = \"sidebar\"\nwhen = [\"angry\"]\nindex = 1\n  [[layer.draw]]\n  kind = \"rect\"\n  fill = \"#000000\"\n");
        assert_eq!((s.layers[0].when.len(), s.layers[0].index, s.problems.len()), (0, None, 2));
    }

    #[test]
    fn a_chain_replaces_by_id_and_caps_the_whole_chain() {
        let src = |name: &str, toml: String, files: Vec<ThemeFile>| ThemeSource { name: name.into(), toml, files };
        let layer = |id: &str, fill: &str| format!("[[layer]]\nid = \"{id}\"\nslot = \"sidebar\"\n  [[layer.draw]]\n  kind = \"rect\"\n  fill = \"{fill}\"\n");
        let s = parse_chain(&[
            src("parent.toml", layer("a", "#111111") + &layer("b", "#222222"), vec![]),
            src("child.toml", layer("a", "#333333") + &layer("c", "#444444"), vec![]),
        ]);
        assert!(s.problems.is_empty(), "{:?}", s.problems);
        let fills: Vec<_> = s.layers.iter().map(|l| l.prims[0].fill.clone().unwrap()).collect();
        assert_eq!(fills, ["#333333", "#222222", "#444444"], "the child's a replaces the parent's in place");

        let many = |p: &str, n: usize| (0..n).map(|i| layer(&format!("{p}{i}"), "#000000")).collect::<String>();
        let s = parse_chain(&[src("p.toml", many("p", 40), vec![]), src("c.toml", many("c", 40), vec![])]);
        assert_eq!(s.layers.len(), MAX_LAYERS);
        assert!(s.problems[0].starts_with("c.toml: layer 25:"), "{:?}", s.problems);

        // Images are named per file, and count against the chain's caps together.
        let img = |name: &str| format!("[[layer]]\nslot = \"window.bg\"\n  [[layer.draw]]\n  kind = \"image\"\n  file = \"{name}\"\n");
        let f = |n: &str, w: u32| ThemeFile { name: n.into(), bytes: png(w, w) };
        let s = parse_chain(&[
            src("p.toml", img("a.png") + &img("b.png") + &img("c.png"), vec![f("a.png", 512), f("b.png", 512), f("c.png", 512)]),
            src("c.toml", img("a.png") + &img("d.png"), vec![f("a.png", 2), f("d.png", 512)]),
        ]);
        assert_eq!(s.images.iter().map(|i| i.width).collect::<Vec<_>>(), [512, 512, 512, 2], "{:?}", s.problems);
        assert!(s.problems.iter().any(|p| p.starts_with("c.toml") && p.contains("over 4 MB")), "{:?}", s.problems);
    }

    #[test]
    fn a_theme_without_layers_has_none_and_a_bad_file_says_so() {
        assert_eq!(one("[color]\nwindow.bg = \"#000000\"\n"), LayerSet { layers: vec![], images: vec![], problems: vec![] });
        assert_eq!(one("layer = 3").problems.len(), 1);
        assert_eq!(one("[[layer").problems.len(), 1);
    }
}
