import Foundation

#if HAUNT_FIXTURES
extension Fixture {
    var isInbox: Bool { self == .reviewInbox }
}


/// The review mockup's turn (haunt-review/index.html: FILES, H, PROMPT), fed through the real diff parser.
extension Fixture {
    private struct MockHunk {
        var file: String, old: Int, new: Int, label: String, body: String
    }

    private static let mockReviewFiles: [(path: String, added: Bool)] = [
        ("Sources/Haunt/Notify/FocusTracker.swift", true),
        ("Sources/Haunt/Notify/HauntNotifier.swift", false),
        ("Sources/Haunt/Settings/Settings.swift", false),
        ("Tests/HauntTests/NotifyTests.swift", true),
        ("Resources/defaults.toml", false),
    ]

    private static let reviewHunks: [MockHunk] = [
        MockHunk(file: "Sources/Haunt/Notify/HauntNotifier.swift", old: 18, new: 18, label: "final class HauntNotifier {", body: #"""
           private let center = UNUserNotificationCenter.current()
        +  private let focus: FocusTracker
        +  private let settings: Settings

        -  init() {}
        +  init(focus: FocusTracker, settings: Settings) {
        +    self.focus = focus
        +    self.settings = settings
        +  }

           func agentNeedsYou(_ tab: AgentTab) {
        +    if settings.quietWhenFocused && focus.isFrontmost(tab) {
        +      tab.pulse()
        +      return
        +    }
             post(title: tab.name, body: tab.waitingReason)
           }
        """#),
        MockHunk(file: "Sources/Haunt/Notify/HauntNotifier.swift", old: 52, new: 61, label: "private func post(title: String, body: String) {", body: #"""
             let content = UNMutableNotificationContent()
             content.title = title
             content.body = body
        -    content.sound = .default
        +    content.sound = settings.notifySound.map(UNNotificationSound.named)
             center.add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
           }
        """#),
        MockHunk(file: "Sources/Haunt/Notify/FocusTracker.swift", old: 0, new: 1, label: "", body: #"""
        +import AppKit
        +
        +/// Knows whether a tab is the one the user is looking at right now.
        +@MainActor
        +final class FocusTracker {
        +  private(set) weak var keyWindow: NSWindow?
        +  private var tokens: [NSObjectProtocol] = []
        +
        +  init(center: NotificationCenter = .default) {
        +    tokens.append(center.addObserver(
        +      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        +    ) { [weak self] note in
        +      self?.keyWindow = note.object as? NSWindow
        +    })
        +    tokens.append(center.addObserver(
        +      forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        +    ) { [weak self] _ in
        +      self?.keyWindow = nil
        +    })
        +  }
        +
        +  func isFrontmost(_ tab: AgentTab) -> Bool {
        +    NSApp.isActive && keyWindow === tab.window && tab.isSelected
        +  }
        +}
        """#),
        MockHunk(file: "Sources/Haunt/Settings/Settings.swift", old: 12, new: 12, label: "struct Settings: Codable {", body: #"""
           var notifyOnNeedsYou = true
           var notifyOnDone = true
        -  var notifySound = "Tink"
        +  var notifySound: String? = nil
        +  var quietWhenFocused = true
           var dockBadge = true
         }
        """#),
        MockHunk(file: "Tests/HauntTests/NotifyTests.swift", old: 0, new: 1, label: "", body: #"""
        +import XCTest
        +@testable import Haunt
        +
        +@MainActor
        +final class NotifyTests: XCTestCase {
        +  func testQuietWhenTabIsFrontmost() {
        +    let (notifier, spy, tab) = makeNotifier(frontmost: true)
        +    notifier.agentNeedsYou(tab)
        +    XCTAssertTrue(spy.posted.isEmpty)
        +    XCTAssertEqual(tab.pulses, 1)
        +  }
        +
        +  func testPostsWhenAppIsInBackground() {
        +    let (notifier, spy, tab) = makeNotifier(frontmost: false)
        +    notifier.agentNeedsYou(tab)
        +    XCTAssertEqual(spy.posted.map(\.title), ["notify"])
        +  }
        +
        +  func testPostsWhenSettingIsOff() {
        +    var settings = Settings()
        +    settings.quietWhenFocused = false
        +    let (notifier, spy, tab) = makeNotifier(frontmost: true, settings: settings)
        +    notifier.agentNeedsYou(tab)
        +    XCTAssertEqual(spy.posted.count, 1)
        +  }
        +
        +  func testNoSoundByDefault() {
        +    XCTAssertNil(Settings().notifySound)
        +  }
        +}
        """#),
        MockHunk(file: "Resources/defaults.toml", old: 4, new: 4, label: "[notify]", body: #"""
         [notify]
         needs_you = true
         done = true
        -sound = "Tink"
        +sound = ""
        +quiet_when_focused = true
         dock_badge = true
        """#),
    ]

    /// The mockup's hunks as `git diff` would print them; the mockup's empty context lines have no space.
    static func reviewPatch() -> String {
        var out = ""
        for f in Self.mockReviewFiles {
            out += "diff --git a/\(f.path) b/\(f.path)\n"
            out += f.added ? "new file mode 100644\n--- /dev/null\n" : "--- a/\(f.path)\n"
            out += "+++ b/\(f.path)\n"
            for h in reviewHunks where h.file == f.path {
                let lines = h.body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? " " : String($0) }
                let add = lines.filter { $0.hasPrefix("+") }.count, del = lines.filter { $0.hasPrefix("-") }.count
                out += "@@ -\(h.old),\(lines.count - add) +\(h.new),\(lines.count - del) @@ \(h.label)\n"
                out += lines.joined(separator: "\n") + "\n"
            }
        }
        return out
    }

    private static func todayMs(_ h: Int, _ m: Int, _ s: Int) -> UInt64 {
        let d = Calendar.current.date(bySettingHour: h, minute: m, second: s, of: Date())!
        return UInt64(d.timeIntervalSince1970 * 1000)
    }

    /// Turn 7: 13:58 → 14:03, 4m51s, the two commands the mockup shows. The mockup's agent summary has no
    /// source in Haunt's hooks, so like the app the fixture has none.
    var reviewTurn: ReviewTurn? {
        guard isReview else { return nil }
        return ReviewTurn(
            agent: .claude, number: 7,
            prompt: "Don't send a banner when I'm already looking at the tab that needs me. Pulse the tab instead, and add tests.",
            cwd: "/Users/me/code/haunt-wt/notify-quiet", startedMs: Self.todayMs(13, 58, 12), finishedMs: Self.todayMs(14, 3, 3),
            failed: false, headAtStart: nil, toolCount: 12, editCount: 6,
            tasks: [], commands: [TurnCommand(command: "swift build", outcome: .passed),
                                  TurnCommand(command: "swift test --filter NotifyTests", outcome: .passed)],
            files: Self.mockReviewFiles.map(\.path),
            subagents: [TurnSubagent(label: "Explore · find notification call sites", toolCount: 7, durationMs: 41_000)])
    }

    var reviewDiff: ReviewDiff {
        ReviewDiff(root: NSHomeDirectory() + "/code/haunt-wt/notify-quiet", files: DiffParser.parse(Self.reviewPatch()),
                   branch: "notify-quiet", upstream: "main", commits: 0, baseNote: "HEAD", uncommitted: true, isWorktree: true)
    }

    /// The mockup project's files: Package.swift and .swiftlint.yml, the source of its two "not run" checks.
    var reviewProject: (Set<String>, Set<String>) { (["Package.swift", ".swiftlint.yml"], []) }

    /// Each version's moment: 01 on HauntNotifier.swift with FocusTracker.swift viewed; 06 with one comment
    /// saved and a second being written; 09 on the overview.
    func setUpReview(_ s: ReviewState) {
        s.selectedFile = 1
        s.viewed = ["Sources/Haunt/Notify/FocusTracker.swift"]
        switch self {
        case .reviewSend:
            s.mode = .sendBack
            s.comments = [
                ReviewComment(path: "Sources/Haunt/Notify/HauntNotifier.swift", line: 64, deleted: false,
                              text: "Why did the sound change? Keep \"Tink\" as the default. The prompt was only about banners."),
                ReviewComment(path: "Sources/Haunt/Settings/Settings.swift", line: 14, deleted: false, text: "Same here, revert this line."),
            ]
        case .reviewOverview: s.mode = .overview
        default: s.mode = .files
        }
    }

    /// 06's second note is open in the editor.
    var reviewEditingComment: Int? { self == .reviewSend ? 1 : nil }
}

/// haunt-review-2 version 11: five agent branches, session-restore selected. Its diff goes through the real
/// parser; hunks the mockup doesn't show are filled to the file list's counts.
extension Fixture {
    private static let inboxSaveHunk = #"""
       private let url: URL
       private let queue = DispatchQueue(label: "haunt.session")

    -  func save(_ tabs: [Tab]) {
    -    let data = try? JSONEncoder().encode(tabs)
    -    try? data?.write(to: url)
    +  func save(_ snapshot: Snapshot) {
    +    pending?.cancel()
    +    let work = DispatchWorkItem { [url] in
    +      do {
    +        let data = try JSONEncoder.haunt.encode(snapshot)
    +        try data.write(to: url, options: .atomic)
    +      } catch {
    +        Log.session.error("save failed: \(error)")
    +      }
    +    }
    +    pending = work
    +    queue.asyncAfter(deadline: .now() + 0.25, execute: work)
       }

       func load() -> Snapshot? {
    """#

    private static let inboxSnapshotStart = ["struct Snapshot: Codable, Equatable {", "  var version = 2", "  var windows: [WindowState]", "}"]

    /// Path, added, the mockup's +/− counts.
    private static let inboxFiles: [(String, Bool, Int, Int)] = [
        ("Sources/Haunt/Session/SessionStore.swift", false, 14, 3),
        ("Sources/Haunt/Session/Snapshot.swift", true, 62, 0),
        ("Sources/Haunt/Window/WindowController.swift", false, 41, 18),
        ("Sources/Haunt/App/AppDelegate.swift", false, 9, 2),
        ("Sources/Haunt/Splits/SplitTree.swift", false, 22, 15),
        ("Tests/HauntTests/SessionStoreTests.swift", true, 66, 0),
    ]

    static func inboxPatch() -> String {
        func hunk(_ old: Int, _ new: Int, _ label: String, _ lines: [String]) -> String {
            let add = lines.filter { $0.hasPrefix("+") }.count, del = lines.filter { $0.hasPrefix("-") }.count
            let oc = old == 0 && add == lines.count ? "0,0" : "\(old),\(lines.count - add)"
            return "@@ -\(oc) +\(new),\(lines.count - del) @@ \(label)\n" + lines.joined(separator: "\n") + "\n"
        }
        func filler(_ n: Int, _ sign: String, _ word: String) -> [String] { (0..<n).map { "\(sign)  \(word)(\($0))" } }
        var out = ""
        for (path, added, a, d) in inboxFiles {
            out += "diff --git a/\(path) b/\(path)\n" + (added ? "new file mode 100644\n--- /dev/null\n" : "--- a/\(path)\n") + "+++ b/\(path)\n"
            if path.hasSuffix("SessionStore.swift") {
                let save = inboxSaveHunk.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? " " : String($0) }
                out += hunk(18, 18, "final class SessionStore {", save)
            } else if path.hasSuffix("Snapshot.swift") {
                out += hunk(0, 1, "", inboxSnapshotStart.map { "+" + $0 } + filler(a - inboxSnapshotStart.count, "+", "field"))
            } else {
                out += hunk(added ? 0 : 10, added ? 1 : 10, "", filler(d, "-", "old") + filler(a, "+", "new"))
            }
        }
        return out
    }

    private static func agoMs(_ s: Int) -> UInt64 { UInt64((Date().timeIntervalSince1970 - TimeInterval(s)) * 1000) }

    private static func turn(_ agent: Agent, _ n: UInt32, prompt: String, finishedAgo: Int?, took: Int = 400, tasks: Int = 0,
                             subagents: Int = 0, _ cmds: [(String, CommandOutcome)]) -> ReviewTurn {
        let end = finishedAgo.map(agoMs)
        return ReviewTurn(
            agent: agent, number: n, prompt: prompt, cwd: "/Users/me/code/haunt-wt", startedMs: (end ?? agoMs(0)) - UInt64(took * 1000),
            finishedMs: end, failed: false, headAtStart: nil, toolCount: 0, editCount: 0,
            tasks: (0..<tasks).map { TurnTask(subject: "task \($0 + 1)", status: "completed") },
            commands: cmds.map { TurnCommand(command: $0.0, outcome: $0.1) }, files: [],
            subagents: (0..<subagents).map { TurnSubagent(label: "Explore · \($0 + 1)", toolCount: nil, durationMs: nil) })
    }

    func inboxTurn(tab: String) -> ReviewTurn? {
        switch tab {
        case "pawr":
            return Self.turn(.claude, 4, prompt: "restore tabs, splits and cwd on relaunch; keep startup under 250ms", finishedAgo: 240,
                             tasks: 5, subagents: 2, [("swift build", .passed), ("swift test", .passed), ("swiftlint", .passed)])
        case "codex-1":
            return Self.turn(.codex, 2, prompt: "coalesce notifications from one agent", finishedAgo: 900, [("swift test", .unknown)])
        case "main tab":
            return Self.turn(.claude, 9, prompt: "cache gas prices per chain", finishedAgo: 1800, [("cargo test", .passed)])
        case "hooks":
            return Self.turn(.claude, 6, prompt: "Two changes from review", finishedAgo: nil, [])
        case "ui":
            return Self.turn(.claude, 3, prompt: "show task progress in sidebar rows", finishedAgo: nil, [("swift test", .running)])
        default:
            return nil
        }
    }

    /// Each entry's diff, checks, and the one sent-back review (hooks).
    func setUpInbox(_ e: InboxEntry) {
        let s = e.state
        func stub(_ branch: String, repo: String = "haunt", _ counts: [(Int, Int)]) -> ReviewDiff {
            ReviewDiff(root: "/Users/me/code/haunt-wt/" + branch,
                       files: counts.enumerated().map { FileDiff(path: "f\($0.offset).swift", additions: $0.element.0, deletions: $0.element.1) },
                       branch: branch, upstream: "main", commits: 1, baseNote: "HEAD", uncommitted: true, repo: repo)
        }
        switch e.row.name {
        case "pawr":
            // The mockup lists SessionStore.swift as +14 −3 but shows one hunk of +12 −3.
            var files = DiffParser.parse(Self.inboxPatch())
            files[0].additions = 14
            s.diff = ReviewDiff(root: "/Users/me/code/haunt-wt/pawr", files: files, branch: "session-restore",
                                upstream: "main", commits: 3, baseNote: "the commit the turn started on", uncommitted: false, isWorktree: true,
                                repo: "haunt")
        case "codex-1": s.diff = stub("notify-coalesce", [(40, 20), (30, 15), (18, 6)])
        case "main tab": s.diff = stub("fix-gas-cache", repo: "orchestrator", [(20, 5), (11, 4)])
        case "hooks":
            s.diff = stub("hooks-timeout", [(47, 12)])
            e.sentBack = (2, true)
        case "ui": s.diff = stub("sidebar-progress", [(12, 3)])
        default: break
        }
        s.checks = Checks.merge(turn: Checks.fromTurn(s.turn?.commands ?? []),
                                expected: Checks.expected(files: ["Package.swift", ".swiftlint.yml"], packageScripts: []))
        s.selectedFile = 0
    }
}
#else
extension Fixture {
    var isInbox: Bool { switch self {} }
    var reviewTurn: ReviewTurn? { switch self {} }
    var reviewDiff: ReviewDiff { switch self {} }
    var reviewProject: (Set<String>, Set<String>) { switch self {} }
    var reviewEditingComment: Int? { switch self {} }
    func setUpReview(_ s: ReviewState) {}
    func inboxTurn(tab: String) -> ReviewTurn? { switch self {} }
    func setUpInbox(_ e: InboxEntry) {}
}
#endif
