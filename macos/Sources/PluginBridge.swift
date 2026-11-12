import AppKit
import UserNotifications

/// Carries out what plugins ask of the host: `.notify` becomes a macOS notification; a `.ptyAnswer` or
/// `.ptyType` is written only as the bytes the core's gate returns; panels go to `PluginPanels`.
final class PluginBridge {
    let panels = PluginPanels()
    let hold = NotificationHold()
    /// Brings tab `surfaceId` up, for a notification bound to it.
    var openTab: ((String) -> Void)?
    /// Set once the core has started, so the decision log is loaded before plugins read it.
    var plugins: PluginsAPI? {
        didSet {
            panels.closeAll()
            hold.release()
        }
    }
    private let core: CoreAPI
    private let write: (PtyRoute) -> Void
    /// A plugin's answer the gate refused, as one line of the host's own text.
    var onRefused: ((String) -> Void)?
    /// When each plugin's refusal was last shown: a plugin retrying can't keep the line up.
    private var refusalShown: [String: Date] = [:]
    private static let refusalQuiet: TimeInterval = 30

    init(core: CoreAPI, write: @escaping (PtyRoute) -> Void) {
        self.core = core
        self.write = write
        panels.onAction = { [weak self] plugin, panel, generation, action in
            self?.run("plugin \(plugin) panel \(panel) action \(action)") {
                try $0.panelAction(pluginId: plugin, panelId: panel, generation: generation, action: action)
            }
        }
        hold.onRelease = { holder, titles in NotificationHold.postSummary(holder: holder, titles: titles) }
    }

    func topRowClicked(pluginId: String) {
        run("plugin \(pluginId) top row") { try $0.topRowClicked(pluginId: pluginId) }
    }

    /// The user chose a plugin notification (`action` empty) or one of its actions. A binding naming an open
    /// tab brings it up; an action reaches the plugin as `on-action(action, binding)`.
    func notificationChosen(pluginId: String, action: String, binding: String) {
        if !binding.isEmpty { openTab?(binding) }
        guard !action.isEmpty else { return }
        run("plugin \(pluginId) notification action \(action)") {
            try $0.notifyAction(pluginId: pluginId, actionId: action, binding: binding)
        }
    }

    var loadErrors: [String] { plugins?.loadErrors() ?? [] }

    func drain() {
        guard let plugins else { return }
        for req in plugins.takeRequests() {
            switch req {
            case let .notify(pluginId, title, body, actions, binding):
                let id = UUID().uuidString
                if hold.keeps(id: id, title: title, from: pluginId) { continue }
                Self.notify(id: id, pluginId: pluginId, title: title, body: body, actions: actions, binding: binding)
            case let .holdNotifications(pluginId, pluginName, minutes):
                hold.start(pluginId: pluginId, name: pluginName, minutes: minutes)
            case let .releaseNotifications(pluginId):
                hold.release(pluginId: pluginId)
            case let .showPanel(pluginId, pluginName, panel):
                panels.show(pluginId: pluginId, pluginName: pluginName, panel: panel)
            case let .closePanel(pluginId, id):
                panels.close(pluginId: pluginId, id: id)
            case .ptyAnswer, .ptyType:
                guard let w = core.gatePluginRequest(request: req), let route = PtyRoute(req, w) else { continue }
                write(route)
            }
        }
        let now = Date()
        refusalShown = refusalShown.filter { now.timeIntervalSince($0.value) < Self.refusalQuiet }
        for r in core.takePluginRefusals() where refusalShown[r.pluginId] == nil {
            refusalShown[r.pluginId] = now
            onRefused?(Self.refusedLine(r))
        }
    }

    /// "Refused <plugin id>: <reason>". The reason is the core's fixed text, never the plugin's.
    static func refusedLine(_ r: PluginRefusal) -> String {
        "Refused \(AgentNotifier.visible(r.pluginId)): \(refusalText(reason: r.reason))"
    }

    /// A palette item. `terminalShown`: the selected tab's terminal is on screen, which typing needs.
    func invoke(pluginId: String, itemId: String, terminalShown: Bool) {
        run("plugin \(pluginId) item \(itemId)") { try $0.invokePaletteItem(pluginId: pluginId, itemId: itemId, terminalShown: terminalShown) }
    }

    /// A plugin's entry in a row's context menu.
    func invokeRowMenu(_ item: RowMenuItem, surfaceId: String) {
        run("plugin \(item.pluginId) row item \(item.id)") {
            try $0.invokeRowMenuItem(pluginId: item.pluginId, itemId: item.id, surfaceId: surfaceId)
        }
    }

    /// Errors are logged with a beep, and whatever the plugin asked for is carried out at once.
    private func run(_ what: @autoclosure () -> String, _ call: (PluginsAPI) throws -> Void) {
        guard let plugins else { return }
        do {
            try call(plugins)
        } catch {
            let what = what()
            AppDelegate.logger.error("\(what, privacy: .public): \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
        drain()
    }

    private static var askedNotifications = false

    private static func notify(id: String, pluginId: String, title: String, body: String, actions: [NotifyAction], binding: String?) {
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = title
            // Names the plugin, so a plugin can't pass its notification off as Haunt's own.
            content.subtitle = pluginId
            content.body = body
            content.userInfo = [SystemNoteCenter.pluginKey: pluginId, SystemNoteCenter.bindingKey: binding ?? ""]
            let request = { center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
            guard !actions.isEmpty else { return request() }
            let category = SystemNoteCenter.pluginCategory(actions, foreground: binding != nil)
            content.categoryIdentifier = category.identifier
            // Categories are set all at once, so this one joins Haunt's own.
            center.getNotificationCategories { cats in
                center.setNotificationCategories(cats.filter { $0.identifier != category.identifier }.union([category]))
                request()
            }
        }
        guard !askedNotifications else { return post() }
        askedNotifications = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { post() } }
    }
}
