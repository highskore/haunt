import Foundation
import UserNotifications

/// A plugin's hold on notifications (`HostRequest.holdNotifications`): Haunt's "done" notes and other
/// plugins' notes wait, and one summary shows when it ends. A note about an agent that needs you is never held.
final class NotificationHold {
    private(set) var owner: (id: String, name: String)?
    private var held: [(id: String, title: String)] = []
    private var timer: Timer?
    /// The owner's name and the titles of what waited, oldest first.
    var onRelease: ((String, [String]) -> Void)?

    /// The core already refused a second plugin's hold; the app ends it itself after `minutes`.
    func start(pluginId: String, name: String, minutes: UInt32) {
        if let o = owner, o.id != pluginId { return }
        owner = (pluginId, name)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes) * 60, repeats: false) { [weak self] _ in
            self?.release(pluginId: pluginId)
        }
    }

    /// Ends the hold if `pluginId` (nil: anyone) has it.
    func release(pluginId: String? = nil) {
        guard let o = owner, pluginId == nil || pluginId == o.id else { return }
        owner = nil
        timer?.invalidate()
        timer = nil
        let titles = held.map(\.title)
        held = []
        if !titles.isEmpty { onRelease?(o.name, titles) }
    }

    /// Whether note `id` waits instead of showing. `plugin`: who posts it, nil for Haunt; the owner's own show.
    func keeps(id: String, title: String, from plugin: String?) -> Bool {
        guard let o = owner, plugin != o.id else { return false }
        held.removeAll { $0.id == id }
        held.append((id, title))
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
