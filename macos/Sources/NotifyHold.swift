import Foundation
import UserNotifications

/// Plugins' holds on notifications (`HostRequest.holdNotifications`): Haunt's "done" notes and other
/// plugins' notes wait while any plugin holds, and one summary shows when the last lets go. A note about
/// an agent that needs you is never held, and neither is a holder's own.
final class NotificationHold {
    static let binding = "hold", actionsKey = "holdActions"
    static let shownHolders = 2

    struct Summary: Equatable {
        /// Every plugin that held, in the order they started.
        var holders: [String]
        /// "id: headline" of the holders shown.
        var headlines: [String]
        /// The shown holders' actions, as (plugin id, action).
        var actions: [(String, NotifyAction)]
        /// One line per note that waited, oldest first.
        var lines: [String]

        static func == (a: Summary, b: Summary) -> Bool {
            a.holders == b.holders && a.headlines == b.headlines && a.lines == b.lines
                && a.actions.map { "\($0.0)/\($0.1.id)/\($0.1.title)" } == b.actions.map { "\($0.0)/\($0.1.id)/\($0.1.title)" }
        }
    }

    /// Who holds now.
    private(set) var holders: Set<String> = []
    /// Everyone who held since the hold began, with what each added to the summary.
    private var added: [(id: String, headline: String?, actions: [NotifyAction])] = []
    private var held: [(id: String, title: String, from: String?)] = []
    private var timers: [String: Timer] = [:]
    var onRelease: ((Summary) -> Void)?

    /// The core caps `minutes`; the app ends each plugin's hold itself after them.
    func start(pluginId: String, minutes: UInt32) {
        holders.insert(pluginId)
        added.removeAll { $0.id == pluginId }
        added.append((pluginId, nil, []))
        timers[pluginId]?.invalidate()
        timers[pluginId] = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes) * 60, repeats: false) { [weak self] _ in
            self?.release(pluginId: pluginId)
        }
    }

    func summary(pluginId: String, headline: String?, actions: [NotifyAction]) {
        guard holders.contains(pluginId), let i = added.firstIndex(where: { $0.id == pluginId }) else { return }
        added[i] = (pluginId, headline, Array(actions.prefix(2)))
    }

    /// Ends `pluginId`'s hold (nil: everyone's); the summary comes once nobody holds.
    func release(pluginId: String? = nil) {
        let ending = pluginId.map { holders.contains($0) ? [$0] : [] } ?? Array(holders)
        for p in ending {
            holders.remove(p)
            timers.removeValue(forKey: p)?.invalidate()
        }
        guard !ending.isEmpty, holders.isEmpty else { return }
        // Ids, not display names, so a plugin can't pass its lines off as Haunt's or another plugin's.
        let lines = held.map { n in AgentNotifier.visible(n.from.map { "\($0): \(n.title)" } ?? n.title) }
        let shown = added.prefix(Self.shownHolders)
        let summary = Summary(holders: added.map(\.id),
                              headlines: shown.compactMap { a in a.headline.map { AgentNotifier.visible("\(a.id): \($0)") } },
                              actions: shown.flatMap { a in a.actions.map { (a.id, $0) } }, lines: lines)
        held = []
        added = []
        if !lines.isEmpty { onRelease?(summary) }
    }

    /// Whether note `id` waits instead of showing. `plugin`: who posts it, nil for Haunt; a holder's own show.
    func keeps(id: String, title: String, from plugin: String?) -> Bool {
        guard !holders.isEmpty, !(plugin.map(holders.contains) ?? false) else { return false }
        held.removeAll { $0.id == id }
        held.append((id, title, plugin))
        return true
    }

    /// Notes taken back while held, such as a "done" for a tab that started again, leave the summary.
    func forget(ids: [String]) {
        held.removeAll { ids.contains($0.id) }
    }

    /// The subtitle naming who held: two by id, then "+n".
    static func heldBy(_ holders: [String]) -> String {
        let more = holders.count - shownHolders
        return "held by " + holders.prefix(shownHolders).joined(separator: ", ") + (more > 0 ? " +\(more)" : "")
    }

    /// The summary as a system notification; its buttons come back through `SystemNoteCenter.holdAction`.
    static func post(_ s: Summary) {
        let content = UNMutableNotificationContent()
        content.title = s.lines.count == 1 ? "1 notification waited" : "\(s.lines.count) notifications waited"
        content.subtitle = heldBy(s.holders)
        content.body = (s.headlines + s.lines.prefix(5)).joined(separator: "\n") + (s.lines.count > 5 ? "\n…" : "")
        content.userInfo = [actionsKey: s.actions.map { "\($0.0)\u{1f}\($0.1.id)" }]
        let center = UNUserNotificationCenter.current()
        let request = { center.add(UNNotificationRequest(identifier: "hold.summary", content: content, trigger: nil)) }
        guard !s.actions.isEmpty else { return request() }
        let category = SystemNoteCenter.pluginCategory(s.actions.enumerated().map { NotifyAction(id: "\($0.offset)", title: $0.element.1.title) },
                                                       foreground: false)
        content.categoryIdentifier = category.identifier
        center.getNotificationCategories { cats in
            center.setNotificationCategories(cats.filter { $0.identifier != category.identifier }.union([category]))
            request()
        }
    }
}

/// Haunt's own notes through a hold: "done" notes wait, "needs" notes always go through.
final class HoldingNoteCenter: NoteCenter {
    private let inner: NoteCenter
    private let hold: NotificationHold

    init(_ inner: NoteCenter, hold: NotificationHold) {
        self.inner = inner
        self.hold = hold
    }

    func post(_ note: AgentNote) {
        if note.id.hasPrefix(AgentNotifier.doneId("")), hold.keeps(id: note.id, title: note.title, from: nil) { return }
        inner.post(note)
    }

    func remove(ids: [String]) {
        hold.forget(ids: ids)
        inner.remove(ids: ids)
    }
}
