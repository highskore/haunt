import AppKit
import GhosttyKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, GhosttyAppDelegate {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.haunt.Haunt", category: "app")

    let fixture: Fixture? = Fixture.current
    let config: HauntConfig
    let ghostty: Ghostty.App
    private let core: CoreAPI
    private var plugins: PluginsAPI?
    private var controller: MainWindowController?
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
        if fixture == nil { plugins = Self.startPlugins(dir: config.dir) }

        // The listener goes in before start() so no change is missed.
        let c = MainWindowController(core: core, ghostty: ghostty, fixture: fixture, config: config, plugins: plugins)
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
        Ghostty.App.desktopNotificationHook = { [weak c, weak self] view, title, body in
            guard let self, let tab = c?.tab(for: view) else { return false }
            self.core.onOscNotification(surfaceId: tab.env.surfaceId, title: title, body: body)
            // Agent events are the core's; other notifications still reach macOS.
            return title == "haunt://cli-agent" || title == "warp://cli-agent"
        }
        for _ in 0..<(fixture?.tabCount ?? 1) { c.newTab(select: false) }
        c.refresh()
        c.window?.center()
        c.showWindow(nil)
        if let startError { c.showStartError(startError) }
        // HAUNT_INACTIVE=1 lets the fidelity script capture the unfocused window state.
        if ProcessInfo.processInfo.environment["HAUNT_INACTIVE"] == "1" {
            NSApp.deactivate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        if fixture == nil {
            config.watch { [weak self] ghosttyChanged, keysChanged, layoutChanged in
                guard let self else { return }
                if keysChanged {
                    self.buildMenu()
                    self.controller?.updateKeys(self.config.keys)
                }
                if ghosttyChanged { self.ghostty.reloadConfig() }
                if layoutChanged { self.controller?.updateTitlebarButtons(self.config.titlebarButtons) }
            }
            c.drainPluginRequests()
        }
        #if HAUNT_FIXTURES
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

    /// Load errors are logged, and listed in the palette, rather than put in front of the user.
    private static func startPlugins(dir: URL) -> PluginsAPI? {
        do {
            let p = try loadPlugins(hauntDir: dir.path)
            for e in p.loadErrors() { logger.error("plugin not loaded: \(e, privacy: .public)") }
            return p
        } catch {
            logger.error("plugins unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { config.flushState() }

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

    @objc func openSettings(_ sender: Any?) {
        let s = settings ?? SettingsWindowController(sheets: setup, configPath: config.tomlURL.path) { [weak self] in
            self?.openConfig(nil)
        }
        settings = s
        s.rebuild()
        if s.window?.isVisible != true { s.window?.center() }
        s.showWindow(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleHauntSidebar(_:)) { item.title = Self.sidebarTitle(hidden: sidebarHidden) }
        if item.action == #selector(toggleAgentsOnlyView(_:)) {
            item.state = controller?.isAgentsViewOn == true ? .on : .off
        }
        // While a tab name is being edited, Haunt's own shortcuts stay out of the way; disabled items
        // don't take their key equivalents, so the keys reach the text field.
        return !(controller?.isRenaming == true && Self.renameBlocked.contains(item.action))
    }

    private static let renameBlocked: Set<Selector?> = [
        #selector(newTab(_:)), #selector(closeTab(_:)), #selector(selectTab(_:)), #selector(selectNextHauntTab(_:)),
        #selector(selectPreviousHauntTab(_:)), #selector(renameHauntTab(_:)), #selector(toggleHauntSidebar(_:)),
        #selector(togglePalette(_:)), #selector(openConfig(_:)), #selector(NSWindow.toggleFullScreen(_:)),
        #selector(toggleAgentsOnlyView(_:)),
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

            [layout]
            # The view cmd+shift+a shows. Only "narrow-list" for now.
            # agents_view = "narrow-list"
            # Title bar icons, left to right: any of "search", "new_tab", "settings", "sidebar".
            # titlebar_buttons = [\(TitlebarButton.defaults.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))]

            # Raw Ghostty keys, passed through as is.
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
            item("Select All", #selector(NSResponder.selectAll(_:)), .selectAll),
        ])
        submenu("View", [
            item("Command Palette", #selector(togglePalette(_:)), .palette),
            item(Self.sidebarTitle(hidden: sidebarHidden), #selector(toggleHauntSidebar(_:)), .toggleSidebar),
            item("Agents Only", #selector(toggleAgentsOnlyView(_:)), .agentsView),
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
        submenu("Window", [
            item("New Tab", #selector(newTab(_:)), .newTab),
            item("Close Tab", #selector(closeTab(_:)), .closeTab),
            .separator(),
            item("Next Tab", #selector(selectNextHauntTab(_:)), .nextTab),
            item("Previous Tab", #selector(selectPreviousHauntTab(_:)), .previousTab),
            item("Rename Tab…", #selector(renameHauntTab(_:)), .renameTab),
        ] + tabs + [
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
