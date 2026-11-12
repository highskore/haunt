import Foundation
import UserNotifications

/// A plugin's hold on notifications (`HostRequest.holdNotifications`): Haunt's "done" notes and other
/// plugins' notes wait, and one summary shows when it ends. A note about an agent that needs you is never held.
final class NotificationHold {
    private(set) var owner: String?
    private var held: [(id: String, title: String, from: String?)] = []
    private var timer: Timer?
    /// The owner's id and one line per note that waited, oldest first.
    var onRelease: ((String, [String]) -> Void)?

    /// The core already refused a second plugin's hold; the app ends it itself after `minutes`.
    func start(pluginId: String, minutes: UInt32) {
        if let o = owner, o != pluginId { return }
        owner = pluginId
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes) * 60, repeats: false) { [weak self] _ in
            self?.release(pluginId: pluginId)
        }
    }

    /// Ends the hold if `pluginId` (nil: anyone) has it.
    func release(pluginId: String? = nil) {
        guard let o = owner, pluginId == nil || pluginId == o else { return }
        owner = nil
        timer?.invalidate()
        timer = nil
        // Ids, not display names, so a plugin can't pass its lines off as Haunt's or another plugin's.
        let lines = held.map { n in AgentNotifier.visible(n.from.map { "\($0): \(n.title)" } ?? n.title) }
        held = []
        if !lines.isEmpty { onRelease?(o, lines) }
    }

    /// Whether note `id` waits instead of showing. `plugin`: who posts it, nil for Haunt; the owner's own show.
    func keeps(id: String, title: String, from plugin: String?) -> Bool {
        guard let o = owner, plugin != o else { return false }
        held.removeAll { $0.id == id }
        held.append((id, title, plugin))
        return true
    }

    /// Notes taken back while held, such as a "done" for a tab that started again, leave the summary.
    func forget(ids: [String]) {
        held.removeAll { ids.contains($0.id) }
    }

    /// The summary, as a plain system notification naming the plugin that held them.
    static func postSummary(holder: String, titles: [String]) {
        let content = UNMutableNotificationContent()
        content.title = titles.count == 1 ? "1 notification waited" : "\(titles.count) notifications waited"
        content.subtitle = "held by \(holder)"
        content.body = titles.prefix(5).joined(separator: "\n") + (titles.count > 5 ? "\n…" : "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hold.summary", content: content, trigger: nil))
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
