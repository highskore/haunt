import AppKit

/// Mockup screens the app can reproduce for `design/check`, selected with HAUNT_FIXTURE=<screen>.
enum Fixture: String {
    case iconOnly = "ui-03-icon-only"
    case groupedFlat = "ui-06-grouped-flat"

    static var current: Fixture? {
        ProcessInfo.processInfo.environment["HAUNT_FIXTURE"].flatMap(Fixture.init(rawValue:))
    }

    /// The mockup's window size in points.
    static let windowSize = NSSize(width: 900, height: Tok.Size.windowH)

    var titleAccessory: TitleBarView.Accessory {
        self == .iconOnly ? .icons : .kbd
    }

    private struct Tab {
        var kind: RowKind, name: String, meta: String, status: String, needs: Bool
        var progress: Progress?, subs: [Subrow]
    }

    // The mockup's TABS array (pawr-ui/index.html), in order.
    private static let tabs: [Tab] = [
        Tab(kind: .claude, name: "pawr", meta: "agent-sidebar · Writing tests", status: "3/5", needs: false,
            progress: Progress(done: 3, total: 5),
            subs: [Subrow(label: "Explore · trace hooks", meta: "2/4 · 1m12s"),
                   Subrow(label: "builder · sidebar styles", meta: "14 tools · 48s")]),
        Tab(kind: .claude, name: "orchestrator", meta: "main · Approve: git push?", status: "needs you", needs: true,
            progress: nil, subs: []),
        Tab(kind: .shell, name: "vibes", meta: "~/code/vibes · zsh", status: "", needs: false, progress: nil, subs: []),
        Tab(kind: .claude, name: "warp upstream", meta: "master · Done in 4m", status: "done", needs: false,
            progress: Progress(done: 6, total: 6), subs: []),
    ]

    static let tabCount = tabs.count

    func snapshot(surfaceIds ids: [String], selected: String?) -> SidebarSnapshot {
        let rows = zip(Self.tabs, ids).map { t, id in
            return Row(surfaceId: id, kind: t.kind, name: t.name, meta: t.meta, statusText: t.status,
                       needsYou: t.needs, progress: t.progress, subagents: t.subs, selected: id == selected, pending: nil)
        }
        guard rows.count == Self.tabs.count else { return SidebarSnapshot(groups: []) }
        switch self {
        case .iconOnly:
            return SidebarSnapshot(groups: [SidebarGroup(label: "", rows: rows)])
        case .groupedFlat:
            return SidebarSnapshot(groups: [
                SidebarGroup(label: "NEEDS YOU", rows: [rows[1]]),
                SidebarGroup(label: "RUNNING", rows: [rows[0]]),
                SidebarGroup(label: "IDLE", rows: [rows[2], rows[3]]),
            ])
        }
    }

    /// The mockup's pane text as truecolor ANSI, printed by the fixture surfaces' command.
    static func paneANSI() -> String {
        func fg(_ c: NSColor) -> String {
            let s = c.usingColorSpace(.sRGB)!
            let v = [s.redComponent, s.greenComponent, s.blueComponent].map { Int(($0 * 255).rounded()) }
            return "\u{1b}[38;2;\(v[0]);\(v[1]);\(v[2])m"
        }
        let dim = fg(Tok.Color.textMeta), hi = fg(Tok.Color.textHi), ok = fg(Tok.Color.textOk)
        let base = fg(Tok.Color.textTerminal)
        // HTML collapses the mockup's leading and doubled spaces, so these lines don't have them.
        let lines = [
            dim + "~/code/warp pawr/agent-sidebar",
            hi + "❯ claude",
            "",
            hi + "● Writing tests for the sidebar styles",
            ok + "✓ Read vertical_tabs_agent.rs",
            ok + "✓ Updated AgentSidebarStyle",
            base + "◼ Add style tests " + dim + "(3/5)",
            dim + "◻ Run presubmit",
            dim + "◻ Screenshot each style",
            "",
            dim + "↳ Explore · trace hooks … 1m12s",
            dim + "↳ builder · sidebar styles … 48s",
        ]
        return "\u{1b}[?25l" + lines.map { $0 + "\u{1b}[0m" }.joined(separator: "\r\n")
    }
}
