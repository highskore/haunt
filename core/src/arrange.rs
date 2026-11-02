//! A plugin's sidebar arrangement (pins, named sections, manual order, colours) merged over the
//! core's snapshot. NEEDS YOU stays first and complete, and every row is shown exactly once, so no
//! arrangement can hide a row or bury one that needs you.

use std::collections::{HashMap, HashSet};

use crate::layout::{IDLE, IDLE_ID, NEEDS_YOU, NEEDS_YOU_ID, RUNNING, RUNNING_ID, Row, RowKind, SidebarGroup, SidebarSnapshot};

pub const PINNED: &str = "PINNED";
pub const PINNED_ID: &str = "pinned";
pub const TABS: &str = "TABS";
pub const TABS_ID: &str = "tabs";
const MAX_SECTIONS: usize = 32;
const MAX_LIST: usize = 1024;
const MAX_TITLE: usize = 32;
const MAX_SECTION_ID: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum TabColor {
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
    Gray,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ColorStyle {
    #[default]
    Dot,
    Tint,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    pub id: String,
    pub title: String,
    pub surfaces: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Arrangement {
    pub pinned: Vec<String>,
    pub sections: Vec<Section>,
    pub sections_after_state: bool,
    pub order: Vec<String>,
    pub flat: bool,
    pub colors: Vec<(String, TabColor)>,
    pub color_style: ColorStyle,
}

/// Which core group a row is in before any arrangement.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateGroup {
    NeedsYou,
    Running,
    Idle,
}

/// A row as an arranging plugin sees it: no meta, task or command text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowInfo {
    pub surface: String,
    pub name: String,
    pub kind: RowKind,
    pub group: StateGroup,
    pub selected: bool,
}

pub fn row_infos(snap: &SidebarSnapshot) -> Vec<RowInfo> {
    snap.groups
        .iter()
        .flat_map(|g| {
            let group = match g.id.as_str() {
                NEEDS_YOU_ID => StateGroup::NeedsYou,
                RUNNING_ID => StateGroup::Running,
                _ => StateGroup::Idle,
            };
            g.rows.iter().map(move |r| RowInfo { surface: r.surface_id.clone(), name: r.name.clone(), kind: r.kind, group, selected: r.selected })
        })
        .collect()
}

/// The title as shown: single-spaced and uppercased like the core's labels. None unless it is 1 to 32
/// ASCII letters, digits, spaces and basic punctuation (no lookalikes), or if its letters and digits
/// spell a core group's label.
pub fn section_title(title: &str) -> Option<String> {
    let allowed = |c: char| c.is_ascii_alphanumeric() || c.is_ascii_whitespace() || "-_.,:;!?'&()/+#".contains(c);
    if !title.chars().all(allowed) {
        return None;
    }
    let t = title.split_ascii_whitespace().collect::<Vec<_>>().join(" ").to_ascii_uppercase();
    let key = |s: &str| s.chars().filter(char::is_ascii_alphanumeric).collect::<String>();
    let core = [NEEDS_YOU, RUNNING, IDLE, PINNED, TABS];
    (!t.is_empty() && t.len() <= MAX_TITLE && !key(&t).is_empty() && !core.iter().any(|c| key(c) == key(&t))).then_some(t)
}

fn valid_section_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= MAX_SECTION_ID && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

impl Arrangement {
    /// Refuses what the merge would otherwise drop, so the plugin hears about it.
    pub fn validate(&self) -> Result<(), String> {
        let mut lists = [self.pinned.len(), self.order.len(), self.colors.len()].into_iter().chain(self.sections.iter().map(|s| s.surfaces.len()));
        if lists.any(|n| n > MAX_LIST) {
            return Err(format!("at most {MAX_LIST} surfaces per list"));
        }
        if self.sections.len() > MAX_SECTIONS {
            return Err(format!("at most {MAX_SECTIONS} sections"));
        }
        let mut ids = HashSet::new();
        for s in &self.sections {
            if !valid_section_id(&s.id) || !ids.insert(s.id.as_str()) {
                return Err(format!("section id {:?} must be unique lowercase letters, digits and '-'", s.id));
            }
            if section_title(&s.title).is_none() {
                return Err(format!("section title {:?} must be 1 to {MAX_TITLE} ASCII letters, digits, spaces or basic punctuation, and not a core group's", s.title));
            }
        }
        Ok(())
    }
}

fn group(id: &str, label: &str, rows: Vec<Row>) -> SidebarGroup {
    SidebarGroup { id: id.to_owned(), label: label.to_owned(), rows }
}

/// `snap` rearranged. Rows needing you stay in NEEDS YOU, first and in the core's order, whatever
/// the plugin listed. Every other row lands in exactly one group: PINNED, the first section that
/// lists it, or its state group. Unknown and repeated surfaces are ignored.
pub fn arrange(snap: SidebarSnapshot, a: &Arrangement) -> SidebarSnapshot {
    let mut colors: HashMap<&str, TabColor> = HashMap::new();
    for (s, c) in &a.colors {
        colors.entry(s.as_str()).or_insert(*c);
    }
    let mut needs = Vec::new();
    let mut rest: Vec<(bool, Row)> = Vec::new();
    for g in snap.groups {
        let running = g.id == RUNNING_ID;
        let needs_group = g.id == NEEDS_YOU_ID;
        for mut r in g.rows {
            r.color = colors.get(r.surface_id.as_str()).copied();
            if needs_group || r.needs_you {
                needs.push(r);
            } else {
                rest.push((running, r));
            }
        }
    }
    let mut take = |ids: &[String]| -> Vec<Row> {
        ids.iter().filter_map(|id| rest.iter().position(|(_, r)| &r.surface_id == id).map(|i| rest.remove(i).1)).collect()
    };

    let pinned = take(&a.pinned);
    let mut seen = HashSet::new();
    let mut sections = Vec::new();
    for s in &a.sections {
        let Some(title) = section_title(&s.title) else { continue };
        if !valid_section_id(&s.id) || !seen.insert(s.id.as_str()) {
            continue;
        }
        sections.push(group(&format!("section:{}", s.id), &title, take(&s.surfaces)));
    }

    let mut rank: HashMap<&str, usize> = HashMap::new();
    for (i, s) in a.order.iter().enumerate() {
        rank.entry(s.as_str()).or_insert(i);
    }
    // Stable, so unranked rows keep the core's order after the ranked ones.
    rest.sort_by_key(|(_, r)| rank.get(r.surface_id.as_str()).copied().unwrap_or(usize::MAX));
    let mut state = if a.flat {
        vec![group(TABS_ID, TABS, rest.into_iter().map(|(_, r)| r).collect())]
    } else {
        let (running, idle): (Vec<_>, Vec<_>) = rest.into_iter().partition(|(running, _)| *running);
        vec![group(RUNNING_ID, RUNNING, running.into_iter().map(|(_, r)| r).collect()), group(IDLE_ID, IDLE, idle.into_iter().map(|(_, r)| r).collect())]
    };
    for g in &mut state {
        if g.rows.iter().all(|r| r.kind == RowKind::Shell) {
            g.label.clear();
        }
    }

    let mut groups = vec![group(NEEDS_YOU_ID, NEEDS_YOU, needs), group(PINNED_ID, PINNED, pinned)];
    if a.sections_after_state {
        groups.extend(state);
        groups.extend(sections);
    } else {
        groups.extend(sections);
        groups.extend(state);
    }
    groups.retain(|g| !g.rows.is_empty());
    SidebarSnapshot { groups, color_style: a.color_style, ..snap }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, kind: RowKind, needs_you: bool) -> Row {
        Row {
            surface_id: id.into(),
            kind,
            name: id.into(),
            meta: String::new(),
            status_text: String::new(),
            needs_you,
            progress: None,
            subagents: vec![],
            selected: false,
            pending: None,
            color: None,
        }
    }

    /// NEEDS YOU: n1 n2; RUNNING: r1 r2; IDLE: i1 and shell s1.
    fn snap() -> SidebarSnapshot {
        SidebarSnapshot {
            groups: vec![
                group(NEEDS_YOU_ID, NEEDS_YOU, vec![row("n1", RowKind::Claude, true), row("n2", RowKind::Codex, true)]),
                group(RUNNING_ID, RUNNING, vec![row("r1", RowKind::Claude, false), row("r2", RowKind::Claude, false)]),
                group(IDLE_ID, IDLE, vec![row("i1", RowKind::Claude, false), row("s1", RowKind::Shell, false)]),
            ],
            color_style: ColorStyle::Dot,
            version: 0,
            next_tick_ms: None,
        }
    }

    fn layout(s: &SidebarSnapshot) -> Vec<(String, Vec<String>)> {
        s.groups.iter().map(|g| (g.label.clone(), g.rows.iter().map(|r| r.surface_id.clone()).collect())).collect()
    }

    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| (*s).to_owned()).collect()
    }

    fn section(id: &str, title: &str, surfaces: &[&str]) -> Section {
        Section { id: id.into(), title: title.into(), surfaces: ids(surfaces) }
    }

    /// Every row exactly once, and NEEDS YOU first with exactly the rows that need you, in core order.
    fn assert_sound(before: &SidebarSnapshot, after: &SidebarSnapshot) {
        let mut a: Vec<_> = before.groups.iter().flat_map(|g| &g.rows).map(|r| r.surface_id.clone()).collect();
        let mut b: Vec<_> = after.groups.iter().flat_map(|g| &g.rows).map(|r| r.surface_id.clone()).collect();
        a.sort();
        b.sort();
        assert_eq!(a, b, "{:?}", layout(after));
        let needs: Vec<_> = before.groups.iter().flat_map(|g| &g.rows).filter(|r| r.needs_you).map(|r| r.surface_id.clone()).collect();
        if !needs.is_empty() {
            assert_eq!(after.groups[0].id, NEEDS_YOU_ID);
            assert_eq!(after.groups[0].rows.iter().map(|r| r.surface_id.clone()).collect::<Vec<_>>(), needs);
        }
        assert!(after.groups.iter().skip(1).flat_map(|g| &g.rows).all(|r| !r.needs_you));
        assert!(after.groups.iter().all(|g| !g.rows.is_empty()));
    }

    #[test]
    fn an_empty_arrangement_changes_nothing() {
        let out = arrange(snap(), &Arrangement::default());
        assert_eq!(out, snap());
    }

    #[test]
    fn pins_sections_and_order_place_each_row_once() {
        let a = Arrangement {
            pinned: ids(&["i1"]),
            sections: vec![section("work", "Work", &["r2", "s1"])],
            order: ids(&["r2", "r1"]),
            ..Default::default()
        };
        let out = arrange(snap(), &a);
        assert_sound(&snap(), &out);
        assert_eq!(
            layout(&out),
            [
                ("NEEDS YOU".into(), ids(&["n1", "n2"])),
                ("PINNED".into(), ids(&["i1"])),
                ("WORK".into(), ids(&["r2", "s1"])),
                ("RUNNING".into(), ids(&["r1"])),
            ]
        );
        assert_eq!(out.groups[2].id, "section:work");
    }

    #[test]
    fn needs_you_rows_cannot_be_pinned_sectioned_or_reordered() {
        let a = Arrangement {
            pinned: ids(&["n2"]),
            sections: vec![section("x", "X", &["n1"])],
            order: ids(&["n2", "n1"]),
            sections_after_state: true,
            flat: true,
            ..Default::default()
        };
        let out = arrange(snap(), &a);
        assert_sound(&snap(), &out);
        assert_eq!(layout(&out)[0], ("NEEDS YOU".into(), ids(&["n1", "n2"])));
        assert!(out.groups.iter().all(|g| g.id != "pinned" && g.id != "section:x"), "they were left empty and dropped");
    }

    #[test]
    fn a_row_that_starts_needing_you_leaves_its_section() {
        let mut s = snap();
        s.groups[1].rows[0].needs_you = true;
        let a = Arrangement { pinned: ids(&["r1"]), ..Default::default() };
        let out = arrange(s.clone(), &a);
        assert_sound(&s, &out);
        assert!(out.groups[0].rows.iter().any(|r| r.surface_id == "r1"));
    }

    #[test]
    fn unknown_and_repeated_surfaces_are_ignored() {
        let a = Arrangement {
            pinned: ids(&["ghost", "r1", "r1"]),
            sections: vec![section("a", "A", &["r1", "r2", "ghost"]), section("b", "B", &["r2"])],
            order: ids(&["i1", "ghost", "i1"]),
            ..Default::default()
        };
        let out = arrange(snap(), &a);
        assert_sound(&snap(), &out);
        let l = layout(&out);
        assert_eq!(l[1], ("PINNED".into(), ids(&["r1"])));
        assert_eq!(l[2], ("A".into(), ids(&["r2"])), "first section wins");
        assert!(l.iter().all(|(t, _)| t != "B"), "B is empty, so it is dropped");
    }

    #[test]
    fn sections_cannot_pass_for_core_groups() {
        let confusables = [
            "N\u{0415}\u{0415}DS YOU",                  // Cyrillic Е
            "\u{FF2E}\u{FF25}\u{FF25}\u{FF24}\u{FF33} YOU", // fullwidth
            "NEEDS\u{00a0}YOU",                         // no-break space
            "\u{0280}UNNING",                           // small capital R
            "\u{0399}DLE",                              // Greek Ι
            "Caf\u{e9}",                                // any non-ASCII
        ];
        let spaced = ["N-E-E-D-S YOU", "needs_you", "Needs.You!", "P I N N E D", "(tabs)", "---", "a\u{7}b"];
        for bad in ["needs you", "Needs  You", "NEEDS\u{200b} YOU", "pinned", "Running", "", "   ", &"x".repeat(33)]
            .into_iter()
            .chain(confusables)
            .chain(spaced)
        {
            assert_eq!(section_title(bad), None, "{bad:?}");
            let a = Arrangement { sections: vec![section("x", bad, &["r1"])], ..Default::default() };
            assert!(a.validate().is_err(), "{bad:?}");
            let out = arrange(snap(), &a);
            assert_sound(&snap(), &out);
            assert_eq!(layout(&out)[1], ("RUNNING".into(), ids(&["r1", "r2"])), "{bad:?}: its rows fall back");
        }
        assert_eq!(section_title(" side\tprojects ").as_deref(), Some("SIDE PROJECTS"));
        assert_eq!(section_title("Q3: web/api (v2) #1").as_deref(), Some("Q3: WEB/API (V2) #1"));
        assert_eq!(section_title("needs you later").as_deref(), Some("NEEDS YOU LATER"));
    }

    #[test]
    fn flat_and_after_state_placement() {
        let a = Arrangement { sections: vec![section("w", "Work", &["r1"])], flat: true, sections_after_state: true, order: ids(&["i1"]), ..Default::default() };
        let out = arrange(snap(), &a);
        assert_sound(&snap(), &out);
        assert_eq!(layout(&out)[1..], [("TABS".into(), ids(&["i1", "r2", "s1"])), ("WORK".into(), ids(&["r1"]))]);
    }

    #[test]
    fn manual_order_survives_a_change_of_state_group() {
        let a = Arrangement { order: ids(&["i1", "r2", "r1"]), ..Default::default() };
        let mut s = snap();
        let moved = s.groups[2].rows.remove(0);
        s.groups[1].rows.push(moved);
        let out = arrange(s, &a);
        assert_eq!(layout(&out)[1], ("RUNNING".into(), ids(&["i1", "r2", "r1"])));
    }

    #[test]
    fn colours_only_where_picked_and_shells_alone_stay_unlabelled() {
        let a = Arrangement {
            colors: vec![("r1".into(), TabColor::Blue), ("r1".into(), TabColor::Red), ("n1".into(), TabColor::Green)],
            color_style: ColorStyle::Tint,
            sections: vec![section("w", "Work", &["i1"])],
            ..Default::default()
        };
        let out = arrange(snap(), &a);
        let color = |id: &str| out.groups.iter().flat_map(|g| &g.rows).find(|r| r.surface_id == id).unwrap().color;
        assert_eq!((color("r1"), color("n1"), color("r2")), (Some(TabColor::Blue), Some(TabColor::Green), None));
        assert_eq!(out.color_style, ColorStyle::Tint);
        assert_eq!(layout(&out).last().unwrap(), &(String::new(), ids(&["s1"])));
    }

    #[test]
    fn any_arrangement_keeps_every_row_once() {
        let pool = ["n1", "n2", "r1", "r2", "i1", "s1", "ghost"];
        let seed = std::cell::Cell::new(0x2545_f491_u64);
        let next = |n: usize| {
            let mut s = seed.get();
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            seed.set(s);
            (s % n as u64) as usize
        };
        for _ in 0..2000 {
            let pick = || (0..next(5)).map(|_| pool[next(pool.len())].to_owned()).collect::<Vec<_>>();
            let a = Arrangement {
                pinned: pick(),
                sections: (0..next(4)).map(|i| Section { id: format!("s{}", next(3)), title: ["A", "", "IDLE", "B"][i % 4].into(), surfaces: pick() }).collect(),
                order: pick(),
                colors: pick().into_iter().map(|s| (s, TabColor::Gray)).collect(),
                sections_after_state: next(2) == 0,
                flat: next(2) == 0,
                color_style: ColorStyle::Dot,
            };
            assert_sound(&snap(), &arrange(snap(), &a));
        }
    }

    #[test]
    fn row_infos_show_the_core_groups() {
        let rows = row_infos(&snap());
        let g: Vec<_> = rows.iter().map(|r| (r.surface.as_str(), r.group)).collect();
        assert_eq!(g[0], ("n1", StateGroup::NeedsYou));
        assert_eq!(g[2], ("r1", StateGroup::Running));
        assert_eq!(g[5], ("s1", StateGroup::Idle));
    }
}
