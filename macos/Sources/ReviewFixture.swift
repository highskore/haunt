import Foundation

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
