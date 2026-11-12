import Foundation
import UserNotifications

/// `NoteCenter` on macOS's notification center. Allow and Deny need the Mac unlocked; Open tab brings Haunt forward.
final class SystemNoteCenter: NSObject, NoteCenter, UNUserNotificationCenterDelegate {
    static let answerCategory = "dev.haunt.answer"
    static let openCategory = "dev.haunt.open"

    /// On the main queue: the action, and the note's surface and request key.
    var onResponse: ((NoteAction, String?, UInt64?) -> Void)?
    /// On the main queue: a plugin's note was chosen, as (plugin id, its action id or "", binding or "").
    var onPluginResponse: ((String, String, String) -> Void)?

    static let pluginKey = "pluginId", bindingKey = "binding"
    private static let pluginAction = "plugin."

    /// A category for a plugin's action buttons, named by its actions so equal sets share one.
    static func pluginCategory(_ actions: [NotifyAction], foreground: Bool) -> UNNotificationCategory {
        var h: UInt64 = 0xcbf29ce484222325
        for b in actions.map({ "\($0.id)\u{1f}\($0.title)" }).joined(separator: "\u{1e}").utf8 + [foreground ? 1 : 0] {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        let acts = actions.map {
            UNNotificationAction(identifier: pluginAction + $0.id, title: $0.title, options: foreground ? [.foreground] : [])
        }
        return UNNotificationCategory(identifier: "dev.haunt.plugin.\(String(h, radix: 16))", actions: acts, intentIdentifiers: [])
    }
    /// Whether one of Ghostty's own notes shows while Haunt is in front: not over the surface it came from.
    var presentsGhosttyNote: (UNNotification) -> Bool = { _ in true }

    private let center = UNUserNotificationCenter.current()
    /// Bumped per post and remove, so a post still waiting for authorization can't land after its removal.
    private var generation: [String: Int] = [:]

    override init() {
        super.init()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.authenticationRequired])
        let open = UNNotificationAction(identifier: "open", title: "Open tab", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.answerCategory, actions: [allow, deny, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.openCategory, actions: [open], intentIdentifiers: []),
        ])
        removeOurs()
    }

    func post(_ note: AgentNote) {
        let gen = (generation[note.id] ?? 0) + 1
        generation[note.id] = gen
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.categoryIdentifier = note.kind == .answer ? Self.answerCategory : Self.openCategory
        content.threadIdentifier = note.surfaceId
        content.userInfo = note.userInfo
        let request = UNNotificationRequest(identifier: note.id, content: content, trigger: nil)
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                guard let self, self.generation[note.id] == gen else { return }
                self.center.add(request)
            }
        }
    }

    func remove(ids: [String]) {
        for id in ids { generation[id, default: 0] += 1 }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Delivered and pending agent notes, a previous run's included: their keys mean nothing once that run is gone.
    func removeOurs() {
        let ours = { (id: String) in id.hasPrefix("needs.") || id.hasPrefix("done.") }
        center.getDeliveredNotifications { [center] notes in
            center.removeDeliveredNotifications(withIdentifiers: notes.map(\.request.identifier).filter(ours))
        }
        center.getPendingNotificationRequests { [center] requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter(ours))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let category = notification.request.content.categoryIdentifier
        completionHandler(Self.foreground(category: category, ghostty: Ghostty.userNotificationCategory,
                                          ghosttyShows: category == Ghostty.userNotificationCategory && presentsGhosttyNote(notification)))
    }

    /// How a note shows while Haunt is in front. Haunt's own notes banner (the focused tab never gets one);
    /// Ghostty's keep its focus rule; anything else, a plugin's, goes only to Notification Center, as with no delegate.
    static func foreground(category: String, ghostty: String, ghosttyShows: Bool) -> UNNotificationPresentationOptions {
        switch category {
        case answerCategory, openCategory: [.banner, .list]
        case ghostty: ghosttyShows ? [.banner, .sound] : []
        default: [.list]
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let plugin = info[Self.pluginKey] as? String {
            let id = response.actionIdentifier
            let action = id.hasPrefix(Self.pluginAction) ? String(id.dropFirst(Self.pluginAction.count)) : ""
            let binding = info[Self.bindingKey] as? String ?? ""
            DispatchQueue.main.async { [weak self] in
                if id != UNNotificationDismissActionIdentifier { self?.onPluginResponse?(plugin, action, binding) }
                completionHandler()
            }
            return
        }
        let action: NoteAction?
        switch response.actionIdentifier {
        case "allow": action = .allow
        case "deny": action = .deny
        case "open", UNNotificationDefaultActionIdentifier: action = .open
        default: action = nil
        }
        let (surface, key) = AgentNote.target(info)
        DispatchQueue.main.async { [weak self] in
            if let action { self?.onResponse?(action, surface, key) }
            completionHandler()
        }
    }
}
