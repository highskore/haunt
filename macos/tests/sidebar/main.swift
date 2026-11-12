import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

func row(_ id: String) -> Row {
    Row(surfaceId: id, kind: .shell, name: id, meta: "", statusText: "", needsYou: false, progress: nil, subagents: [],
        selected: false, pending: nil, color: nil)
}

let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
view.snapshot = SidebarSnapshot(groups: [
    SidebarGroup(id: "needs-you", label: "NEEDS YOU", rows: [row("n")]),
    SidebarGroup(id: "pinned", label: "PINNED", rows: [row("p1"), row("p2")]),
    SidebarGroup(id: "idle", label: "IDLE", rows: [row("i")]),
], colorStyle: .dot)

// Walk down the view and record every distinct drop target.
var seen: [String] = []
for y in stride(from: CGFloat(0), to: 600, by: 1) {
    let t = view.target(at: NSPoint(x: 50, y: y))
    let s = t.map { "\($0.group):\($0.before ?? "end")" } ?? "none"
    if seen.last != s { seen.append(s) }
}
check(seen == ["none", "pinned:p1", "pinned:p2", "pinned:end", "idle:i", "idle:end"], "drop targets top to bottom: \(seen)")
check(!seen.contains { $0.hasPrefix("needs-you") }, "nothing lands in NEEDS YOU")

// The footer counts agent tabs, not shells.
var agent = row("a")
agent.kind = .claude
var codex = row("c")
codex.kind = .codex
check(SidebarView.agentCount(SidebarSnapshot(groups: [SidebarGroup(id: "g", label: "", rows: [agent, row("s"), codex])], colorStyle: .dot)) == 2,
      "two agents beside a shell")

// Leaving the agents view: the old frame comes back only if a screen still shows it.
let main = NSRect(x: 0, y: 0, width: 1440, height: 875), gone = NSRect(x: 1440, y: 0, width: 1200, height: 800)
check(AgentsView.restoredFrame(NSRect(x: 100, y: 100, width: 900, height: 600), screens: [main], current: main)
      == NSRect(x: 100, y: 100, width: 900, height: 600), "an on-screen frame is kept")
check(AgentsView.restoredFrame(NSRect(x: 1500, y: 100, width: 900, height: 600), screens: [main], current: main)
      == NSRect(x: 270, y: 137.5, width: 900, height: 600), "a frame on a lost screen is centred on the current one")
check(AgentsView.restoredFrame(gone.insetBy(dx: -200, dy: -200), screens: [], current: NSRect(x: 0, y: 0, width: 800, height: 600))
      == NSRect(x: 0, y: 0, width: 800, height: 600), "and capped to it")

// A decoration's label or spark never takes the status slot from a row that needs you.
let deco = Decoration(label: "CI 9/9", labelTone: .warn, suffix: "ok", suffixTone: .dim, scroll: false, barPermille: 500,
                      spark: Spark(points: [1, 2], tone: .text))
let calm = RowDecor(deco, statusWins: false)
check(calm?.rightWidth == RowDecor.sparkSize.width, "a calm row shows the spark")
let needs = RowDecor(deco, statusWins: true)
check(needs?.rightWidth == nil && needs?.label == nil && needs?.spark == nil, "a needs-you row keeps Haunt's status")
check(needs?.suffix == nil && needs?.bar == 0.5, "only the bar stays")
check(RowDecor.color(.warn) != Tok.Color.needs, "warn is not the needs colour")

// A theme's words are drawn whole and checked as drawn, or Haunt's own are.
Theme.statusCheck = { $0 == "Done" }
Theme.current.app.strings = ["sidebar.foot": "Doneness {agents}", "row.sub.prefix": "D"]
Theme.current.app.sidebarFootFont = 400
check(SidebarView.footText(agents: 3, room: 200) == "3 agents", "a foot too wide for the sidebar is Haunt's, never cut to \"Done…\"")
Theme.current.app.sidebarFootFont = 9
check(SidebarView.footText(agents: 3, room: 200) == "Doneness 3", "and the theme's when it fits")
check(SidebarView.subText("one", room: 200) == "↳ one", "a prefix that spells a status with its label falls back to Haunt's")
check(SidebarView.subText("builder", room: 200) == "Dbuilder", "otherwise the theme's prefix stays")
Theme.statusCheck = { $0.hasPrefix("Done") }
let doneW = Draw.width(Draw.line("Done…", Draw.ui(Tok.Size.subFont), .black))
check(SidebarView.subText("onerous task", room: doneW) == "↳ onerous task", "a label cut to fit is checked as drawn (\"Done…\")")
check(SidebarView.subText("builder", room: 5) == "↳ builder", "and the theme's prefix needs room for itself")
Theme.current = Theme()
Theme.statusCheck = { _ in true }

print(failures == 0 ? "sidebar: all passed" : "sidebar: \(failures) failed")
exit(failures == 0 ? 0 : 1)
