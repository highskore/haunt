import AppKit
import GhosttyKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate, GhosttyAppDelegate {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.haunt.Haunt", category: "app")

    // Spike: no user config yet; a missing path keeps Ghostty's defaults.
    let ghostty = Ghostty.App(configPath: ("~/.haunt/ghostty.conf" as NSString).expandingTildeInPath)
    private var window: NSWindow?
    private var surface: Ghostty.SurfaceView?
    private var bridge: HauntBridge?

    // Members the vendored wrapper calls on NSApp.delegate; inert in the spike.
    let undoManager: UndoManager? = nil
    func checkForUpdates(_ sender: Any?) {}
    func toggleVisibility(_ sender: Any?) {}
    func closeAllWindows(_ sender: Any?) { window?.close() }
    func syncFloatOnTopMenu(_ window: NSWindow) {}
    func setSecureInput(_ mode: Ghostty.SetSecureInput) {}
    func toggleQuickTerminal(_ sender: Any?) {}
    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool { false }

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        surface?.id == uuid ? surface : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ghostty.readiness == .ready, let app = ghostty.app else {
            FileHandle.standardError.write("ghostty app not ready\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        ghostty.delegate = self
        bridge = HauntBridge()
        buildMenu()

        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables = ["HAUNT": "1"]
        // Spike hook: HAUNT_INITIAL_INPUT is typed into the shell's pty once it starts.
        if let input = ProcessInfo.processInfo.environment["HAUNT_INITIAL_INPUT"] {
            config.initialInput = input
        }
        let view = Ghostty.SurfaceView(app, baseConfig: config, uuid: nil)
        surface = view

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "haunt"
        win.contentView = view
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        window = win
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit haunt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}
