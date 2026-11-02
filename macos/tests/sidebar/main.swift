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

print(failures == 0 ? "sidebar: all passed" : "sidebar: \(failures) failed")
exit(failures == 0 ? 0 : 1)
