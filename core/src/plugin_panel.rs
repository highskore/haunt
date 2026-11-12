//! `panel` import: a plugin describes a small tree of nodes and the app draws it natively. The tree is
//! checked and capped here, and every string made plain, before it leaves the host.

use std::collections::{BTreeMap, VecDeque};
use std::time::{Duration, Instant};

use crate::plugins::{plain, plain_lines, wpanel};

pub const MAX_NODES: usize = 512;
pub const MAX_DEPTH: usize = 8;
pub const MAX_SHAPES: usize = 4096;
pub const MAX_PANELS: usize = 4;
pub const MAX_TEXT: usize = 256;
/// Lines a text node keeps; each is plain and cut like any other string.
pub const MAX_LINES: usize = 40;
pub const MAX_SUB: usize = 80;
const MAX_KEY: usize = 64;
pub const SHOWS_PER_SEC: usize = 4;
pub const MAX_PULSES: usize = 16;
/// After the user closes a plugin's sheet, it can't show another for this long.
pub const SHEET_COOLDOWN: Duration = Duration::from_secs(10);
/// A second close of this plugin's sheets within this long ends its sheets for the session.
pub const SHEET_STRIKES: Duration = Duration::from_secs(60);
const GRID_GAP: u32 = 2;
const MAX_ID: usize = 64;
const MAX_GRID_CELLS: u32 = 4096;
const MAX_CELL: u32 = 64;
const MAX_CANVAS: u32 = 2048;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PanelPlacement {
    Sheet,
    Right,
    Card,
    Window,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PanelTone {
    Text,
    Dim,
    Faint,
    /// The plugin warn orange, never haunt's needs-you colour.
    Warn,
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PanelShape {
    Dot { x: f32, y: f32, r: f32, shade: f32, warn: bool, pulse: bool, key: Option<String> },
    Rect { x: f32, y: f32, w: f32, h: f32, shade: f32, warn: bool, label: Option<String>, sub: Option<String>, key: Option<String> },
    Line { x1: f32, y1: f32, x2: f32, y2: f32, shade: f32, key: Option<String> },
    Label { x: f32, y: f32, text: String, tone: PanelTone, key: Option<String> },
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum PanelNodeKind {
    VStack,
    HStack,
    Text { text: String, tone: PanelTone, mono: bool, bold: bool },
    Row { label: String, sub: Option<String>, right: Option<String>, tone: PanelTone },
    /// `surface`: the tab the app brings forward on a press, before `on-action`.
    Button { label: String, action: String, primary: bool, surface: Option<String> },
    Divider,
    /// `cells` row by row, each 0 to 1, or -1 for an empty cell.
    Grid { rows: u32, columns: u32, cell: u32, cells: Vec<f32>, marked: Vec<u32> },
    Canvas { width: u32, height: u32, shapes: Vec<PanelShape> },
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PanelNode {
    /// An earlier stack's index; None: the panel itself.
    pub parent: Option<u32>,
    pub kind: PanelNodeKind,
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Panel {
    pub id: String,
    /// Bumped on every show; the app passes it back so a close of an older show can't close a newer one.
    pub generation: u64,
    pub placement: PanelPlacement,
    pub title: String,
    pub nodes: Vec<PanelNode>,
}

#[derive(Debug)]
struct Open {
    placement: PanelPlacement,
    generation: u64,
    actions: Vec<String>,
}

/// One plugin instance's open panels and its recent shows.
#[derive(Debug, Default)]
pub struct Panels {
    open: BTreeMap<String, Open>,
    shows: VecDeque<Instant>,
    generation: u64,
    /// When the user last closed one of this plugin's sheets.
    sheet_closed: Option<Instant>,
    /// Set by a second close within `SHEET_STRIKES`: no more sheets this session.
    sheets_off: bool,
}

impl Panels {
    /// Checks the caps, the rate and the sheet rules for a show of `p`, then records it as open with
    /// its generation set.
    pub fn show(&mut self, p: &mut Panel) -> Result<(), String> {
        if !self.open.contains_key(&p.id) && self.open.len() >= MAX_PANELS {
            return Err(format!("at most {MAX_PANELS} panels open"));
        }
        if p.placement == PanelPlacement::Sheet {
            if self.sheets_off {
                return Err("the user closed this plugin's sheets twice in a minute; no more this session".into());
            }
            if self.open.iter().any(|(id, o)| o.placement == PanelPlacement::Sheet && *id != p.id) {
                return Err("one sheet at a time".into());
            }
            if self.sheet_closed.is_some_and(|t| t.elapsed() < SHEET_COOLDOWN) {
                return Err("the user just closed a sheet; try later".into());
            }
        }
        let now = Instant::now();
        while self.shows.front().is_some_and(|t| now.duration_since(*t) >= Duration::from_secs(1)) {
            self.shows.pop_front();
        }
        if self.shows.len() >= SHOWS_PER_SEC {
            return Err(format!("panel rate limit ({SHOWS_PER_SEC}/s)"));
        }
        self.shows.push_back(now);
        self.generation += 1;
        p.generation = self.generation;
        let actions = p.nodes.iter().filter_map(|n| if let PanelNodeKind::Button { action, .. } = &n.kind { Some(action.clone()) } else { None });
        self.open.insert(p.id.clone(), Open { placement: p.placement, generation: p.generation, actions: actions.collect() });
        Ok(())
    }

    /// Whether `id` was open.
    pub fn close(&mut self, id: &str) -> bool {
        self.open.remove(id).is_some()
    }

    pub fn placement(&self, id: &str) -> Option<PanelPlacement> {
        self.open.get(id).map(|o| o.placement)
    }

    pub fn ids(&self) -> Vec<String> {
        self.open.keys().cloned().collect()
    }

    /// The user pressed `action` on show `generation` of panel `id`, or closed it (`action` empty).
    /// Anything else, including a stale generation, is refused. A close is recorded.
    pub fn user_action(&mut self, id: &str, generation: u64, action: &str) -> bool {
        let Some(o) = self.open.get(id).filter(|o| o.generation == generation) else { return false };
        if !action.is_empty() {
            return o.actions.iter().any(|a| a == action);
        }
        if o.placement == PanelPlacement::Sheet {
            let now = Instant::now();
            self.sheets_off |= self.sheet_closed.is_some_and(|t| now.duration_since(t) < SHEET_STRIKES);
            self.sheet_closed = Some(now);
        }
        self.open.remove(id);
        true
    }
}

fn text(s: String) -> String {
    plain(&s, MAX_TEXT)
}

fn lines(s: String) -> String {
    plain_lines(&s, MAX_LINES, MAX_TEXT)
}

fn key(s: String) -> String {
    plain(&s, MAX_KEY)
}

impl PanelShape {
    fn key(&self) -> Option<&str> {
        match self {
            Self::Dot { key, .. } | Self::Rect { key, .. } | Self::Line { key, .. } | Self::Label { key, .. } => key.as_deref(),
        }
    }
}

fn tone(t: wpanel::Tone) -> PanelTone {
    match t {
        wpanel::Tone::Text => PanelTone::Text,
        wpanel::Tone::Dim => PanelTone::Dim,
        wpanel::Tone::Faint => PanelTone::Faint,
        wpanel::Tone::Warn => PanelTone::Warn,
    }
}

fn num(v: f32) -> Result<f32, String> {
    if v.is_finite() { Ok(v) } else { Err("panel numbers must be finite".into()) }
}

fn shade(v: f32) -> Result<f32, String> {
    Ok(num(v)?.clamp(0.0, 1.0))
}

/// A canvas coordinate, kept within a canvas-sized margin so nothing draws far off it.
fn coord(v: f32) -> Result<f32, String> {
    Ok(num(v)?.clamp(-(MAX_CANVAS as f32), 2.0 * MAX_CANVAS as f32))
}

fn shape(s: wpanel::Shape) -> Result<PanelShape, String> {
    Ok(match s {
        wpanel::Shape::Dot(d) => PanelShape::Dot {
            x: coord(d.x)?,
            y: coord(d.y)?,
            r: num(d.r)?.clamp(0.0, MAX_CANVAS as f32),
            shade: shade(d.shade)?,
            warn: d.warn,
            pulse: d.pulse,
            key: d.key.map(key),
        },
        wpanel::Shape::Rect(r) => PanelShape::Rect {
            x: coord(r.x)?,
            y: coord(r.y)?,
            w: num(r.w)?.clamp(0.0, MAX_CANVAS as f32),
            h: num(r.h)?.clamp(0.0, MAX_CANVAS as f32),
            shade: shade(r.shade)?,
            warn: r.warn,
            label: r.label.map(text),
            sub: r.sub.map(|s| plain(&s, MAX_SUB)),
            key: r.key.map(key),
        },
        wpanel::Shape::Line(l) => {
            PanelShape::Line { x1: coord(l.x1)?, y1: coord(l.y1)?, x2: coord(l.x2)?, y2: coord(l.y2)?, shade: shade(l.shade)?, key: l.key.map(key) }
        }
        wpanel::Shape::Label(l) => PanelShape::Label { x: coord(l.x)?, y: coord(l.y)?, text: text(l.text), tone: tone(l.tone), key: l.key.map(key) },
    })
}

fn kind(n: wpanel::Node, shapes: &mut usize, pulses: &mut usize) -> Result<PanelNodeKind, String> {
    Ok(match n {
        wpanel::Node::Vstack => PanelNodeKind::VStack,
        wpanel::Node::Hstack => PanelNodeKind::HStack,
        wpanel::Node::Divider => PanelNodeKind::Divider,
        wpanel::Node::Text(t) => PanelNodeKind::Text { text: lines(t.text), tone: tone(t.tone), mono: t.mono, bold: t.bold },
        wpanel::Node::Row(r) => PanelNodeKind::Row { label: text(r.label), sub: r.sub.map(text), right: r.right.map(text), tone: tone(r.tone) },
        wpanel::Node::Button(b) => {
            let action = text(b.action);
            if action.is_empty() {
                return Err("a button needs an action".into());
            }
            PanelNodeKind::Button { label: text(b.label), action, primary: b.primary, surface: b.surface.map(text).filter(|s| !s.is_empty()) }
        }
        wpanel::Node::Grid(g) => {
            let n = g.rows.checked_mul(g.columns).filter(|&n| n <= MAX_GRID_CELLS).ok_or(format!("a grid has at most {MAX_GRID_CELLS} cells"))?;
            if g.cells.len() != n as usize {
                return Err("a grid needs rows × columns cells".into());
            }
            if !(2..=MAX_CELL).contains(&g.cell) {
                return Err(format!("a grid cell is 2 to {MAX_CELL} points"));
            }
            let side = |n: u32| n.saturating_mul(g.cell + GRID_GAP) <= MAX_CANVAS;
            if !side(g.rows) || !side(g.columns) {
                return Err(format!("a grid is at most {MAX_CANVAS} points each way"));
            }
            if g.marked.iter().any(|&m| m >= n) || g.marked.len() > n as usize {
                return Err("a marked cell is outside the grid".into());
            }
            let cells = g.cells.into_iter().map(|c| num(c).map(|c| if c < 0.0 { -1.0 } else { c.min(1.0) })).collect::<Result<_, _>>()?;
            PanelNodeKind::Grid { rows: g.rows, columns: g.columns, cell: g.cell, cells, marked: g.marked }
        }
        wpanel::Node::Canvas(c) => {
            if !(1..=MAX_CANVAS).contains(&c.width) || !(1..=MAX_CANVAS).contains(&c.height) {
                return Err(format!("a canvas is 1 to {MAX_CANVAS} points each way"));
            }
            *shapes += c.shapes.len();
            if *shapes > MAX_SHAPES {
                return Err(format!("at most {MAX_SHAPES} shapes in a panel"));
            }
            *pulses += c.shapes.iter().filter(|s| matches!(s, wpanel::Shape::Dot(d) if d.pulse)).count();
            if *pulses > MAX_PULSES {
                return Err(format!("at most {MAX_PULSES} pulsing dots in a panel"));
            }
            let shapes: Vec<PanelShape> = c.shapes.into_iter().map(shape).collect::<Result<_, _>>()?;
            let mut keys: Vec<&str> = shapes.iter().filter_map(PanelShape::key).collect();
            keys.sort_unstable();
            if keys.windows(2).any(|w| w[0] == w[1]) {
                return Err("a shape key is used once per canvas".into());
            }
            PanelNodeKind::Canvas { width: c.width, height: c.height, shapes }
        }
    })
}

/// The panel a `show` call describes, or why it is refused: too many nodes, too deep, a parent that
/// isn't an earlier stack, a number that isn't finite. Strings are made plain and cut to 256.
pub fn build(id: String, placement: wpanel::Placement, title: String, nodes: Vec<wpanel::PanelNode>) -> Result<Panel, String> {
    let id_ok = (1..=MAX_ID).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b));
    if !id_ok {
        return Err(format!("a panel id is 1 to {MAX_ID} of letters, digits, '-', '_' and '.'"));
    }
    if nodes.len() > MAX_NODES {
        return Err(format!("at most {MAX_NODES} nodes"));
    }
    let mut out: Vec<PanelNode> = Vec::with_capacity(nodes.len());
    let mut depth = Vec::with_capacity(nodes.len());
    let (mut shapes, mut pulses) = (0, 0);
    for (i, n) in nodes.into_iter().enumerate() {
        let d = match n.parent {
            None => 1,
            Some(p) => {
                let parent = out.get(p as usize).filter(|_| (p as usize) < i);
                if !parent.is_some_and(|p| matches!(p.kind, PanelNodeKind::VStack | PanelNodeKind::HStack)) {
                    return Err(format!("node {i}: parent {p} is not an earlier stack"));
                }
                depth[p as usize] + 1
            }
        };
        if d > MAX_DEPTH {
            return Err(format!("at most {MAX_DEPTH} levels"));
        }
        depth.push(d);
        out.push(PanelNode { parent: n.parent, kind: kind(n.node, &mut shapes, &mut pulses)? });
    }
    let placement = match placement {
        wpanel::Placement::Sheet => PanelPlacement::Sheet,
        wpanel::Placement::Right => PanelPlacement::Right,
        wpanel::Placement::Card => PanelPlacement::Card,
        wpanel::Placement::Window => PanelPlacement::Window,
    };
    Ok(Panel { id, generation: 0, placement, title: text(title), nodes: out })
}

#[cfg(test)]
mod tests {
    use super::*;
    use wpanel::{Node, PanelNode as N, Placement};

    fn node(parent: Option<u32>, node: Node) -> N {
        N { parent, node }
    }

    fn txt(s: &str) -> Node {
        Node::Text(wpanel::TextNode { text: s.into(), tone: wpanel::Tone::Dim, mono: false, bold: false })
    }

    fn button(action: &str) -> Node {
        Node::Button(wpanel::ButtonNode { label: "Go".into(), action: action.into(), primary: true, surface: None })
    }

    #[test]
    fn strings_are_plain_and_capped() {
        let p = build("welcome".into(), Placement::Sheet, "Hi\u{202e}\nthere".into(), vec![node(None, txt(&format!("a\tb{}", "c".repeat(300))))]).unwrap();
        assert_eq!(p.title, "Hi there");
        let PanelNodeKind::Text { text, .. } = &p.nodes[0].kind else { panic!() };
        assert!(text.starts_with("a b") && text.chars().count() == MAX_TEXT);
        for bad in ["", "a b", "x\u{200b}", &"a".repeat(65)] {
            assert!(build(bad.into(), Placement::Card, String::new(), vec![]).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_text_node_keeps_up_to_40_plain_lines() {
        let many = (0..50).map(|i| format!("{i}\r\u{200b}")).collect::<Vec<_>>().join("\n");
        let long = format!("{}\nend", "x".repeat(300));
        let p = build("p".into(), Placement::Card, String::new(), vec![node(None, txt(&many)), node(None, txt(&long))]).unwrap();
        let PanelNodeKind::Text { text, .. } = &p.nodes[0].kind else { panic!() };
        assert_eq!(text.lines().count(), MAX_LINES);
        assert!(text.starts_with("0\n1\n") && text.ends_with("\n39"), "CR and hidden characters go: {text:?}");
        let PanelNodeKind::Text { text, .. } = &p.nodes[1].kind else { panic!() };
        assert_eq!(text.split('\n').map(|l| l.chars().count()).collect::<Vec<_>>(), [MAX_TEXT, 3]);
    }

    #[test]
    fn the_tree_is_checked() {
        let stack = || node(None, Node::Vstack);
        assert!(build("p".into(), Placement::Right, String::new(), vec![stack(), node(Some(0), txt("x"))]).is_ok());
        assert!(build("p".into(), Placement::Right, String::new(), vec![node(Some(0), txt("x"))]).is_err(), "parent must be earlier");
        assert!(build("p".into(), Placement::Right, String::new(), vec![node(None, txt("x")), node(Some(0), txt("y"))]).is_err(), "parent must be a stack");
        let deep: Vec<N> = (0..=MAX_DEPTH as u32).map(|i| node(i.checked_sub(1), Node::Hstack)).collect();
        assert!(build("p".into(), Placement::Right, String::new(), deep[..MAX_DEPTH].to_vec()).is_ok());
        assert!(build("p".into(), Placement::Right, String::new(), deep).unwrap_err().contains("levels"));
        let many = vec![node(None, Node::Divider); MAX_NODES + 1];
        assert!(build("p".into(), Placement::Right, String::new(), many).is_err());
        assert!(build("p".into(), Placement::Right, String::new(), vec![node(None, button(""))]).is_err(), "a button needs an action");
    }

    #[test]
    fn grids_and_canvases_are_capped_and_finite() {
        let grid = |rows, columns, cells: Vec<f32>, marked| Node::Grid(wpanel::GridNode { rows, columns, cell: 10, cells, marked });
        let p = build("g".into(), Placement::Window, String::new(), vec![node(None, grid(1, 3, vec![-5.0, 0.5, 9.0], vec![2]))]).unwrap();
        let PanelNodeKind::Grid { cells, .. } = &p.nodes[0].kind else { panic!() };
        assert_eq!(cells, &[-1.0, 0.5, 1.0]);
        for bad in [grid(1, 2, vec![0.0], vec![]), grid(1, 1, vec![f32::NAN], vec![]), grid(1, 1, vec![0.0], vec![1]), grid(65, 64, vec![0.0; 65 * 64], vec![])] {
            assert!(build("g".into(), Placement::Window, String::new(), vec![node(None, bad)]).is_err());
        }
        assert!(build("g".into(), Placement::Window, String::new(), vec![node(None, grid(u32::MAX, 2, vec![], vec![]))]).is_err(), "no overflow");

        let dot = |x: f32, pulse| wpanel::Shape::Dot(wpanel::Dot { x, y: 1.0, r: 2.0, shade: 3.0, warn: false, pulse, key: None });
        let canvas = |shapes: Vec<wpanel::Shape>| Node::Canvas(wpanel::CanvasNode { width: 100, height: 50, shapes });
        let p = build("c".into(), Placement::Card, String::new(), vec![node(None, canvas(vec![dot(1.0, true)]))]).unwrap();
        let PanelNodeKind::Canvas { shapes, .. } = &p.nodes[0].kind else { panic!() };
        assert!(matches!(shapes[0], PanelShape::Dot { shade, .. } if shade == 1.0));
        assert!(build("c".into(), Placement::Card, String::new(), vec![node(None, canvas(vec![dot(f32::INFINITY, false)]))]).is_err());
        let half = || node(None, canvas((0..MAX_SHAPES / 2 + 1).map(|_| dot(0.0, false)).collect()));
        assert!(build("c".into(), Placement::Card, String::new(), vec![half(), half()]).unwrap_err().contains("shapes"));
        let pulsing = |n| node(None, canvas((0..n).map(|_| dot(0.0, true)).collect()));
        assert!(build("c".into(), Placement::Card, String::new(), vec![pulsing(MAX_PULSES)]).is_ok());
        assert!(build("c".into(), Placement::Card, String::new(), vec![pulsing(1), pulsing(MAX_PULSES)]).unwrap_err().contains("pulsing"));
    }

    #[test]
    fn shape_keys_are_unique_per_canvas_and_a_rect_sub_is_capped() {
        let rect = |key: Option<&str>, sub: Option<String>| {
            wpanel::Shape::Rect(wpanel::Rect { x: 0.0, y: 0.0, w: 10.0, h: 10.0, shade: 0.5, warn: false, label: Some("src".into()), sub, key: key.map(Into::into) })
        };
        let label = |key: &str| wpanel::Shape::Label(wpanel::Label { x: 0.0, y: 0.0, text: "x".into(), tone: wpanel::Tone::Dim, key: Some(key.into()) });
        let canvas = |shapes| node(None, Node::Canvas(wpanel::CanvasNode { width: 100, height: 50, shapes }));
        let p = build("c".into(), Placement::Right, String::new(), vec![canvas(vec![rect(Some("src"), Some(format!("24\nedits{}", "x".repeat(99)))), label("lbl"), rect(None, None), rect(None, None)])]).unwrap();
        let PanelNodeKind::Canvas { shapes, .. } = &p.nodes[0].kind else { panic!() };
        let PanelShape::Rect { sub: Some(sub), key: Some(k), .. } = &shapes[0] else { panic!() };
        assert!(sub.starts_with("24 edits") && sub.chars().count() == MAX_SUB && k == "src");
        let dup = build("c".into(), Placement::Right, String::new(), vec![canvas(vec![rect(Some("a"), None), label("a")])]);
        assert!(dup.unwrap_err().contains("once per canvas"));
        assert!(build("c".into(), Placement::Right, String::new(), vec![canvas(vec![label("a")]), canvas(vec![label("a")])]).is_ok(), "per canvas");
    }

    #[test]
    fn a_button_may_bring_a_tab_forward() {
        let b = |surface: Option<&str>| node(None, Node::Button(wpanel::ButtonNode { label: "Start with api".into(), action: "go".into(), primary: false, surface: surface.map(Into::into) }));
        let p = build("b".into(), Placement::Card, String::new(), vec![b(Some("s-1\u{202e}")), b(Some("")), b(None)]).unwrap();
        let surfaces: Vec<_> = p.nodes.iter().map(|n| match &n.kind { PanelNodeKind::Button { surface, .. } => surface.clone(), _ => panic!() }).collect();
        assert_eq!(surfaces, [Some("s-1".into()), None, None]);
    }

    #[test]
    fn a_grid_draws_no_bigger_than_a_canvas() {
        let grid = |columns: u32, cell| Node::Grid(wpanel::GridNode { rows: 1, columns, cell, cells: vec![0.0; columns as usize], marked: vec![] });
        assert!(build("g".into(), Placement::Window, String::new(), vec![node(None, grid(MAX_CANVAS / (32 + GRID_GAP), 32))]).is_ok());
        assert!(build("g".into(), Placement::Window, String::new(), vec![node(None, grid(MAX_CANVAS / (32 + GRID_GAP) + 1, 32))]).unwrap_err().contains("points each way"));
    }

    fn panel(id: &str, placement: Placement) -> Panel {
        build(id.into(), placement, String::new(), vec![node(None, button("go"))]).unwrap()
    }

    #[test]
    fn open_panels_and_shows_are_limited() {
        let mut panels = Panels::default();
        for i in 0..MAX_PANELS {
            panels.show(&mut panel(&i.to_string(), Placement::Card)).unwrap();
        }
        assert!(panels.show(&mut panel("extra", Placement::Card)).unwrap_err().contains("panels open"));
        assert!(panels.show(&mut panel("0", Placement::Card)).unwrap_err().contains("rate"), "replacing is fine, but not a fifth show this second");
        assert!(panels.close("0") && !panels.close("0"));
        assert_eq!(panels.ids(), ["1", "2", "3"]);
    }

    #[test]
    fn only_the_current_show_answers_and_a_close_ends_it() {
        let mut panels = Panels::default();
        let (mut a, mut b) = (panel("p", Placement::Card), panel("p", Placement::Card));
        panels.show(&mut a).unwrap();
        panels.show(&mut b).unwrap();
        assert_eq!((a.generation, b.generation), (1, 2));
        assert!(!panels.user_action("p", 1, "go") && !panels.user_action("p", 1, ""), "an older show's buttons and close are stale");
        assert!(panels.user_action("p", 2, "go") && !panels.user_action("p", 2, "other") && !panels.user_action("x", 2, ""));
        assert!(panels.user_action("p", 2, "") && !panels.user_action("p", 2, "go"));
    }

    #[test]
    fn one_sheet_at_a_time_and_a_pause_after_the_user_closes_one() {
        let mut panels = Panels::default();
        let mut s = panel("s", Placement::Sheet);
        panels.show(&mut s).unwrap();
        assert!(panels.show(&mut panel("t", Placement::Sheet)).unwrap_err().contains("one sheet"));
        panels.show(&mut panel("s", Placement::Sheet)).unwrap();
        assert!(panels.user_action("s", 2, ""));
        assert!(panels.show(&mut panel("s", Placement::Sheet)).unwrap_err().contains("just closed"));
        panels.show(&mut panel("c", Placement::Card)).unwrap();
        panels.sheet_closed = Some(Instant::now() - SHEET_COOLDOWN);
        panels.show(&mut panel("s", Placement::Sheet)).unwrap();
        assert!(panels.user_action("s", 4, ""), "a second close within a minute");
        panels.sheet_closed = Some(Instant::now() - SHEET_STRIKES);
        panels.shows.clear();
        assert!(panels.show(&mut panel("s", Placement::Sheet)).unwrap_err().contains("no more this session"));
        panels.show(&mut panel("c", Placement::Card)).unwrap();
    }
}
