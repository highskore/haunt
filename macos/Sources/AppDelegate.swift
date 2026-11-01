import AppKit
import GhosttyKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate, GhosttyAppDelegate {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.haunt.Haunt", category: "app")

    let fixture = Fixture.current
    let config: HauntConfig
    let ghostty: Ghostty.App
    private let core: CoreAPI
    private var controller: MainWindowController?

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
        config.writeGhosttyConfig(useUserConfig: fixture == nil)
        ghostty = Ghostty.App(configPath: config.ghosttyURL.path)
        core = Self.makeCore(fixture: fixture, configDir: config.dir.path)
        super.init()
    }

    private static func makeCore(fixture: Fixture?, configDir: String) -> CoreAPI {
        #if HAUNT_REAL_CORE
        if fixture == nil { return HauntCore(configDir: configDir) }
        #endif
        return MockCore(fixture: fixture)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ghostty.readiness == .ready else {
            FileHandle.standardError.write("ghostty app not ready\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        ghostty.delegate = self
        buildMenu()

        // The listener goes in before start() so no change is missed.
        let c = MainWindowController(core: core, ghostty: ghostty, fixture: fixture)
        controller = c
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
        for _ in 0..<(fixture == nil ? 1 : Fixture.tabCount) { c.newTab(select: false) }
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
            config.watch { [weak self] in self?.ghostty.reloadConfig() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) { controller?.newTab() }
    @objc func closeTab(_ sender: Any?) { controller?.closeSelectedTab() }
    @objc func selectTab(_ sender: NSMenuItem) { controller?.select(index: sender.tag) }

    @objc func openConfig(_ sender: Any?) {
        let url = config.tomlURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            # Haunt config. Saved changes apply right away.
            # font = "\(Tok.Font.monoFamily)"
            # font_size = 12.5

            # Raw Ghostty keys, passed through as is.
            [ghostty]

            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }

        submenu("Haunt", [
            item("About Haunt", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(openConfig(_:)), ","),
            .separator(),
            item("Hide Haunt", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Haunt", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Copy", #selector(Ghostty.SurfaceView.copy(_:)), "c"),
            item("Paste", #selector(Ghostty.SurfaceView.paste(_:)), "v"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
        ])
        submenu("View", [
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let tabs = (1...9).map { n -> NSMenuItem in
            let i = item("Select Tab \(n)", #selector(selectTab(_:)), "\(n)")
            i.tag = n - 1
            return i
        }
        submenu("Window", [
            item("New Tab", #selector(newTab(_:)), "t"),
            item("Close Tab", #selector(closeTab(_:)), "w"),
            .separator(),
        ] + tabs + [
            .separator(),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }
}
