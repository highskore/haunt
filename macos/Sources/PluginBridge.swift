import AppKit
import UserNotifications

/// Carries out what plugins ask of the host: `.notify` becomes a macOS notification; a `.ptyAnswer` is
/// written only as the bytes the core's gate returns.
final class PluginBridge {
    /// Set once the core has started, so the decision log is loaded before plugins read it.
    var plugins: PluginsAPI?
    private let core: CoreAPI
    private let write: (Data, String) -> Void

    init(core: CoreAPI, write: @escaping (_ bytes: Data, _ surfaceId: String) -> Void) {
        self.core = core
        self.write = write
    }

    var loadErrors: [String] { plugins?.loadErrors() ?? [] }

    func drain() {
        guard let plugins else { return }
        for req in plugins.takeRequests() {
            switch req {
            case let .notify(pluginId, title, body, _, _):
                Self.notify(pluginId: pluginId, title: title, body: body)
            case .ptyAnswer:
                guard let w = core.gatePluginRequest(request: req) else { continue }
                write(w.bytes, w.surfaceId)
            }
        }
    }

    /// A palette item: errors are logged with a beep, and whatever it asked for is carried out at once.
    func invoke(pluginId: String, itemId: String) {
        do {
            try plugins?.invokePaletteItem(pluginId: pluginId, itemId: itemId)
        } catch {
            AppDelegate.logger.error("plugin \(pluginId, privacy: .public) item \(itemId, privacy: .public): \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
        drain()
    }

    /// A plugin's entry in a row's context menu.
    func invokeRowMenu(_ item: RowMenuItem, surfaceId: String) {
        do {
            try plugins?.invokeRowMenuItem(pluginId: item.pluginId, itemId: item.id, surfaceId: surfaceId)
        } catch {
            AppDelegate.logger.error("plugin \(item.pluginId, privacy: .public) row item \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
        drain()
    }

    private static var askedNotifications = false

    private static func notify(pluginId: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = title
            // Names the plugin, so a plugin can't pass its notification off as Haunt's own.
            content.subtitle = pluginId
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        guard !askedNotifications else { return post() }
        askedNotifications = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { post() } }
    }
}
