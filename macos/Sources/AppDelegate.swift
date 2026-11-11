import AppKit
import GhosttyKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, GhosttyAppDelegate {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.haunt.Haunt", category: "app")

    let fixture: Fixture? = Fixture.current
    let config: HauntConfig
    let ghostty: Ghostty.App
    private let core: CoreAPI
    private var controller: MainWindowController?
    private var notifier: AgentNotifier?
    private var noteCenter: SystemNoteCenter?
    /// HAUNT_INACTIVE=1 is a test launch: no menu bar item and no real notifications.
    private static let inactiveLaunch = ProcessInfo.processInfo.environment["HAUNT_INACTIVE"] == "1"
    private let statusMenu = StatusMenu()
    private lazy var setup = SetupSheets(config: config, fixture: fixture != nil)
    private var settings: SettingsWindowController?

    // Members the vendored wrapper calls on NSApp.delegate.
    let undoManager: UndoManager? = nil
    func checkForUpdates(_ sender: Any?) {}
    func toggleVisibility(_ sender: Any?) {}
    func closeAllWindows(_ sender: Any?) { controller?.window?.performClose(sender) }
    func syncFloatOnTopMenu(_ window: NSWindow) {}
    func setSecureInput(_ mode: Ghostty.SetSecureInput) {}
    func toggleQuickTerminal(_ sender: Any?) {}
    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool { false }

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        controller?.tabs.first { $0.view.id == uuid }?.view
    }

    override init() {
        // Fixture screens must not pick up, or overwrite, the user's config.
        config = fixture == nil ? HauntConfig()
            : HauntConfig(dir: FileManager.default.temporaryDirectory.appendingPathComponent("haunt-fixture"))
        config.reload(useUserConfig: fixture == nil)
        ghostty = Ghostty.App(configPath: config.ghosttyURL.path)
        core = Self.makeCore(fixture: fixture, configDir: config.dir.path)
        super.init()
    }

    private static func makeCore(fixture: Fixture?, configDir: String) -> CoreAPI {
        #if HAUNT_FIXTURES
        #if HAUNT_REAL_CORE
        if fixture == nil { return HauntCore(configDir: configDir) }
        #endif
        return MockCore(fixture: fixture)
        #else
        return HauntCore(configDir: configDir)
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ghostty.readiness == .ready else {
            FileHandle.standardError.write(Data("ghostty app not ready\n".utf8))
            NSApp.terminate(nil)
            return
        }
        ghostty.delegate = self
        buildMenu()

        // The listener goes in before start() so no change is missed.
        let c = MainWindowController(core: core, ghostty: ghostty, fixture: fixture, config: config)
        controller = c
        c.onSidebarToggle = { [weak self] in self?.updateSidebarItem() }
        updateSidebarItem()
        #if HAUNT_FIXTURES
        if fixture != nil {
            // Lets a launch check confirm who answers the item and what it reads, once the window is key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let item = self?.menuItems[.toggleSidebar], let action = item.action else { return }
                func who(_ sel: Selector) -> String {
                    NSApp.target(forAction: sel, to: nil, from: item).map { String(describing: type(of: $0)) } ?? "nil"
                }
                let line = "menu: \(item.title) -> \(who(action)); toggleSidebar: -> \(who(Selector(("toggleSidebar:"))))\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        #endif
        var startError: Error?
        do {
            try core.start()
        } catch {
            startError = error
            Self.logger.error("core start failed: \(String(describing: error), privacy: .public)")
        }
        c.bridge.plugins = Self.startPlugins(fixture: fixture, core: core, dir: config.dir, configToml: config.text)
        applyPluginKeys()
        Ghostty.App.desktopNotificationHook = { [weak c, weak self] view, title, body in
            guard let self, let tab = c?.tab(for: view) else { return false }
            self.core.onOscNotification(surfaceId: tab.env.surfaceId, title: title, body: body)
            // Agent events are the core's; other notifications still reach macOS.
            return title == "haunt://cli-agent" || title == "warp://cli-agent"
        }
        if fixture == nil && !Self.inactiveLaunch { startNotifications(c) }
        statusMenu.onOpen = { [weak c] id in c?.open(id) }
        statusMenu.onTogglePause = { [weak self] in
            guard let self, let n = self.notifier else { return }
            n.paused.toggle()
            self.controller?.refresh()
        }
        c.onSnapshot = { [weak self, weak c] snap in
            guard let self, let c else { return }
            self.notifier?.update(snap)
            self.updateStatusMenu(snap, order: c.sidebarOrder)
        }
        for _ in 0..<(fixture?.tabCount ?? 1) { c.newTab(select: false) }
        c.refresh()
        c.window?.center()
        c.showWindow(nil)
        if let startError { c.showStartError(startError) }
        // A real launch leaves focus to the launcher. Fixtures are for the fidelity script, which captures
        // them focused, or unfocused with HAUNT_INACTIVE=1.
        if Self.inactiveLaunch {
            NSApp.deactivate()
        } else if fixture != nil {
            NSApp.activate(ignoringOtherApps: true)
        }

        if fixture == nil {
            config.watch { [weak self] ghosttyChanged, keysChanged, layoutChanged, notificationsChanged, textChanged in
                guard let self else { return }
                var (ghosttyChanged, keysChanged) = (ghosttyChanged, keysChanged)
                if textChanged, let plugins = self.controller?.bridge.plugins {
                    let applied = plugins.setConfig(configToml: self.config.text)
                    Self.logSettingsProblems(applied.problems)
                    // A plugin may register or drop commands as its settings change.
                    if applied.changed {
                        ghosttyChanged = self.rebuildPluginKeys() || ghosttyChanged
                        keysChanged = true
                    }
                }
                if keysChanged {
                    self.buildMenu()
                    self.controller?.updateKeys(self.config.keys)
                }
                if notificationsChanged {
                    self.notifier?.settings = self.config.notifications
                    self.settings?.rebuild()
                }
                if keysChanged || notificationsChanged { self.controller?.refresh() }
                if ghosttyChanged { self.ghostty.reloadConfig() }
                if layoutChanged { self.controller?.updateTitlebarButtons(self.config.titlebarButtons) }
            }
            c.drainPluginRequests()
        }
        #if HAUNT_FIXTURES
        if fixture == .statusMenu {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.statusMenu.showFixture() }
        }
        // HAUNT_RENAME=<n>:<text> opens the rename editor on the nth row with <text>; <n>=<text> names it.
        if let spec = ProcessInfo.processInfo.environment["HAUNT_RENAME"],
           let sep = spec.firstIndex(where: { $0 == ":" || $0 == "=" }), let n = Int(spec[..<sep]) {
            let text = String(spec[spec.index(after: sep)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak c] in
                guard let c else { return }
                if spec[sep] == "=" { return c.setCustomName(text, at: n - 1) }
                c.select(index: n - 1)
                c.renameSelectedTab(text: text)
            }
        }
        if fixture?.isReview == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak c] in c?.toggleReview() }
        }
        if fixture == .pasteRisky {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak c] in c?.pasteRiskyFixture() }
        }
        if fixture == .pasteConfirm {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak c] in c?.showPasteFixture() }
        }
        #endif
        showSetupIfNeeded(on: c)
        #if HAUNT_FIXTURES
        // HAUNT_PALETTE, like HAUNT_INACTIVE, lets a launch check capture the palette without synthetic keys.
        // It opens once activation has settled, or the main window taking key would close it again.
        if let text = fixture?.paletteQuery ?? ProcessInfo.processInfo.environment["HAUNT_PALETTE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak c, fixture] in
                c?.openPalette(text: text)
                // The mockup's selection is its second entry.
                if fixture == .palette { c?.paletteFixtureSelectNext() }
            }
        }
        #endif
    }

    /// Fixtures and HAUNT_INACTIVE launches never post: they would land in the user's Notification Center.
    private func startNotifications(_ c: MainWindowController) {
        let center = SystemNoteCenter()
        let n = AgentNotifier(center: center, core: core,
                              write: { [weak c] bytes, id in c?.write(bytes, to: id) },
                              open: { [weak c] id in c?.open(id) },
                              isFocused: { [weak c] id in c?.isFocused(id) ?? false })
        n.settings = config.notifications
        center.onResponse = { [weak n] action, surface, key in n?.respond(action, surfaceId: surface, requestKey: key) }
        center.presentsGhosttyNote = { [weak self] note in self?.ghostty.shouldPresentNotification(notification: note) ?? true }
        notifier = n
        noteCenter = center
    }

    /// The fixture's menu is shown without an item, so a capture never touches the user's menu bar.
    private func updateStatusMenu(_ snap: SidebarSnapshot, order: [String]) {
        statusMenu.isShown = fixture == nil && !Self.inactiveLaunch && config.notifications.menuBar
        var keys: [String: Shortcut] = [:]
        for a in KeyMap.Action.allCases {
            if let i = a.tabIndex, order.indices.contains(i) { keys[order[i]] = config.keys[a] }
        }
        statusMenu.update(StatusMenuModel(snapshot: snap, keys: keys), paused: notifier?.paused ?? false)
    }

    /// Load errors are logged, and listed in the palette, rather than put in front of the user. Fixtures
    /// get their own plugins; only the log palettes have any.
    private static func startPlugins(fixture: Fixture?, core: CoreAPI, dir: URL, configToml: String) -> PluginsAPI? {
        do {
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("plugins").path
            #if HAUNT_FIXTURES
            let fromFixture = try fixture.map { try fixturePlugins($0, bundledDir: bundled) }
            #else
            let fromFixture: PluginsAPI?? = nil
            #endif
            guard let p = try fromFixture ?? loadPlugins(hauntDir: dir.path, core: core, bundledDir: bundled, configToml: configToml) else { return nil }
            for e in p.loadErrors() { logger.error("plugin not loaded: \(e, privacy: .public)") }
            logSettingsProblems(p.settingsProblems())
            return p
        } catch {
            logger.error("plugins unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func logSettingsProblems(_ problems: [String]) {
        for p in problems { logger.warning("plugin settings: \(p, privacy: .public)") }
    }

    /// First launch, before any agent choice is recorded, asks which agents to set up; fixtures show each screen.
    private func showSetupIfNeeded(on c: MainWindowController) {
        guard let window = c.window else { return }
        var show: (() -> Void)? = fixture == nil && setup.recorded == nil ? { [setup] in setup.showPicker(on: window) } : nil
        #if HAUNT_FIXTURES
        switch fixture {
        case .setupPicker: show = { [setup] in setup.showPicker(on: window) }
        case .setupChange: show = { [setup] in setup.confirm([.claude, .codex], remove: false, on: window, back: {}, done: {}) }
        case .settings:
            show = { [weak self] in
                guard let self else { return }
                var state = HauntConfig.State()
                state.agents = ["claude"]
                self.config.saveState(state)
                self.openSettings(nil)
            }
        default: break
        }
        #endif
        if let show { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: show) }
    }

    /// Snapshots only come with core changes; coming to the front re-reads one so the focused tab's notes go.
    func applicationDidBecomeActive(_ notification: Notification) { controller?.refresh() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        config.flushState()
        notifier?.removeAll()
        noteCenter?.removeOurs()
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) { controller?.newTab() }
    @objc func closeTab(_ sender: Any?) { controller?.closeSelectedTab() }
    @objc func selectTab(_ sender: NSMenuItem) { controller?.select(index: sender.tag) }
    // Not selectNextTab(_:)/selectPreviousTab(_:): NSWindow answers those for its own window tabs.
    @objc func selectNextHauntTab(_ sender: Any?) { controller?.selectAdjacent(1) }
    @objc func renameHauntTab(_ sender: Any?) { controller?.renameSelectedTab() }
    @objc func selectPreviousHauntTab(_ sender: Any?) { controller?.selectAdjacent(-1) }
    // Not toggleSidebar(_:): NSWindow answers that selector and sits ahead of us in the responder chain,
    // so the menu item validated (and kept its title) against the window instead of us.
    @objc func toggleHauntSidebar(_ sender: Any?) { controller?.toggleSidebar() }
    @objc func togglePalette(_ sender: Any?) { controller?.togglePalette() }
    // Checked with responds(to:): no NSWindow/NSApplication/NSResponder method of this name (cf. toggleSidebar:).
    @objc func toggleAgentsOnlyView(_ sender: Any?) { controller?.toggleAgentsView() }
    // Checked with responds(to:) like the one above: nothing in AppKit answers toggleReviewScreen:.
    @objc func toggleReviewScreen(_ sender: Any?) { controller?.toggleReview() }

    @objc func openSettings(_ sender: Any?) {
        let s = settings ?? SettingsWindowController(sheets: setup, configPath: config.tomlURL.path,
                                                     notifications: { [config] in config.notifications }) { [weak self] in
            self?.openConfig(nil)
        }
        settings = s
        s.refresh()
        if s.window?.isVisible != true { s.window?.center() }
        s.showWindow(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleHauntSidebar(_:)) { item.title = Self.sidebarTitle(hidden: sidebarHidden) }
        if item.action == #selector(toggleAgentsOnlyView(_:)) {
            item.state = controller?.isAgentsViewOn == true ? .on : .off
        }
        if item.action == #selector(toggleReviewScreen(_:)) {
            item.state = controller?.isReviewOn == true ? .on : .off
        }
        // The sidebar's editor is hidden behind the agents view.
        if item.action == #selector(renameHauntTab(_:)), controller?.isAgentsViewOn == true { return false }
        // While a tab name is being edited, Haunt's own shortcuts stay out of the way; disabled items
        // don't take their key equivalents, so the keys reach the text field.
        return !(controller?.isRenaming == true && Self.renameBlocked.contains(item.action))
    }

    private static let renameBlocked: Set<Selector?> = [
        #selector(newTab(_:)), #selector(closeTab(_:)), #selector(selectTab(_:)), #selector(selectNextHauntTab(_:)),
        #selector(selectPreviousHauntTab(_:)), #selector(renameHauntTab(_:)), #selector(toggleHauntSidebar(_:)),
        #selector(togglePalette(_:)), #selector(openConfig(_:)), #selector(NSWindow.toggleFullScreen(_:)),
        #selector(toggleAgentsOnlyView(_:)), #selector(toggleReviewScreen(_:)), #selector(runPluginCommand(_:)),
    ]

    private var sidebarHidden: Bool { controller?.isSidebarHidden ?? false }

    static func sidebarTitle(hidden: Bool) -> String { hidden ? "Show Sidebar" : "Hide Sidebar" }

    /// Set directly as well as in validation, so the title is right even when nothing validates it.
    private func updateSidebarItem() {
        menuItems[.toggleSidebar]?.title = Self.sidebarTitle(hidden: sidebarHidden)
    }

    @objc func openConfig(_ sender: Any?) {
        let url = config.tomlURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            # Haunt config. Saved changes apply right away.
            # font = "\(Tok.Font.monoFamily)"
            # font_size = 11

            # Shortcuts, as "cmd+shift+b" (cmd, shift, ctrl, opt). Commented lines show the defaults.
            [keys]
            \(KeyMap.Action.allCases.map { a in a.defaultKey.map { "# \(a.rawValue) = \"\($0)\"" } ?? "# \(a.rawValue): no default" }.joined(separator: "\n"))
            # A plugin command by "<plugin id>/<item id>", e.g. "dev.haunt.tabs-plus/move-up" = "alt+cmd+up".

            [layout]
            # The view cmd+shift+a shows. Only "narrow-list" for now.
            # agents_view = "narrow-list"
            # Title bar icons, left to right: any of "search", "new_tab", "settings", "sidebar".
            # titlebar_buttons = [\(TitlebarButton.defaults.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))]

            # Notifications when an agent needs you or finishes, and the menu bar item.
            [notifications]
            \(NotificationSettings.keys.keys.sorted().map { "# \($0) = true" }.joined(separator: "\n"))

            # Raw Ghostty keys, passed through, except ones that paste past Haunt's check (see the README).
            [ghostty]

            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    /// The menu carries every shortcut, so the `[keys]` table only has to change its key equivalents.
    /// The menu items by the `[keys]` action they carry, so the palette can run exactly what the menu runs.
    private var menuItems: [KeyMap.Action: NSMenuItem] = [:]

    /// Runs the menu item for `action` the way choosing it would, validation included.
    func performMenuItem(_ action: KeyMap.Action) {
        guard let item = menuItems[action], let menu = item.menu else { return }
        menu.update()
        guard item.isEnabled else { return NSSound.beep() }
        menu.performActionForItem(at: menu.index(of: item))
    }

    @objc func runPluginCommand(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? PaletteItem else { return }
        controller?.paletteInvoke(pluginId: item.pluginId, itemId: item.id)
    }

    /// Plugin commands with a key go in the Window menu, so `[keys]` and the menu treat them like Haunt's own.
    private var pluginCommands: [PaletteItem] = []

    /// Re-reads the plugins' commands into the key map, from the config.toml text already read; says
    /// whether the Ghostty file changed.
    private func rebuildPluginKeys() -> Bool {
        pluginCommands = controller?.bridge.plugins?.paletteItems(mode: nil, query: "").filter { !$0.isMode } ?? []
        config.pluginKeyDefaults = Dictionary(pluginCommands.compactMap { i in i.defaultKey.map { (KeyMap.pluginName(i.pluginId, i.id), $0) } },
                                              uniquingKeysWith: { a, _ in a })
        return config.rebuildKeys().ghostty
    }

    private func applyPluginKeys() {
        if rebuildPluginKeys() { ghostty.reloadConfig() }
        buildMenu()
        controller?.updateKeys(config.keys)
    }

    private func buildMenu() {
        let keys = config.keys
        menuItems = [:]
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: KeyMap.Action? = nil) -> NSMenuItem {
            let s = key.flatMap { keys[$0] }
            let i = NSMenuItem(title: title, action: action, keyEquivalent: s?.keyEquivalent ?? "")
            i.keyEquivalentModifierMask = s?.mods ?? []
            if let key { menuItems[key] = i }
            return i
        }

        submenu("Haunt", [
            item("About Haunt", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(openSettings(_:)), .settings),
            .separator(),
            item("Hide Haunt", #selector(NSApplication.hide(_:)), .hide),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), .hideOthers),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Haunt", #selector(NSApplication.terminate(_:)), .quit),
        ])
        submenu("Edit", [
            item("Copy", #selector(Ghostty.SurfaceView.copy(_:)), .copy),
            item("Paste", #selector(Ghostty.SurfaceView.paste(_:)), .paste),
            item("Paste Selection", #selector(Ghostty.SurfaceView.pasteSelection(_:)), .pasteSelection),
            item("Select All", #selector(NSResponder.selectAll(_:)), .selectAll),
        ])
        submenu("View", [
            item("Command Palette", #selector(togglePalette(_:)), .palette),
            item(Self.sidebarTitle(hidden: sidebarHidden), #selector(toggleHauntSidebar(_:)), .toggleSidebar),
            item("Agents Only", #selector(toggleAgentsOnlyView(_:)), .agentsView),
            item("Review Changes", #selector(toggleReviewScreen(_:)), .review),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), .fullScreen),
        ])
        let selects: [KeyMap.Action] = [.selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
                                        .selectTab6, .selectTab7, .selectTab8, .selectTab9]
        let tabs = selects.map { a -> NSMenuItem in
            let i = item("Select Tab \(a.tabIndex! + 1)", #selector(selectTab(_:)), a)
            i.tag = a.tabIndex!
            return i
        }
        let pluginItems = pluginCommands.compactMap { p -> NSMenuItem? in
            guard let s = keys.plugin[KeyMap.pluginName(p.pluginId, p.id)] else { return nil }
            let i = NSMenuItem(title: p.title, action: #selector(runPluginCommand(_:)), keyEquivalent: s.keyEquivalent)
            i.keyEquivalentModifierMask = s.mods
            i.representedObject = p
            return i
        }
        submenu("Window", [
            item("New Tab", #selector(newTab(_:)), .newTab),
            item("Close Tab", #selector(closeTab(_:)), .closeTab),
            .separator(),
            item("Next Tab", #selector(selectNextHauntTab(_:)), .nextTab),
            item("Previous Tab", #selector(selectPreviousHauntTab(_:)), .previousTab),
            item("Rename Tab…", #selector(renameHauntTab(_:)), .renameTab),
        ] + (pluginItems.isEmpty ? [] : [.separator()] + pluginItems + [.separator()]) + tabs + [
            .separator(),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), .minimize),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }
}
