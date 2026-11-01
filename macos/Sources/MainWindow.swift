import AppKit
import Combine
import GhosttyKit

/// One sidebar row: a libghostty surface registered with the core.
final class Tab {
    let env: SurfaceEnv
    let view: Ghostty.SurfaceView
    /// Ghostty's scroll wrapper; it is what tells the surface its size.
    let host: SurfaceScrollView
    var subscriptions: [AnyCancellable] = []

    init(env: SurfaceEnv, view: Ghostty.SurfaceView, size: CGSize) {
        self.env = env
        self.view = view
        host = SurfaceScrollView(contentSize: size, surfaceView: view)
    }
}

/// Lays out title bar, sidebar and pane at fixed mockup sizes.
private final class RootView: NSView {
    let titleBar = TitleBarView()
    let sidebar = SidebarView()
    let pane = NSView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pane.wantsLayer = true
        pane.layer?.backgroundColor = Tok.Color.windowBg.cgColor
        for v in [titleBar, sidebar, pane] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let top = Tok.Size.titlebarH, w = Tok.Size.sidebarW
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        sidebar.frame = NSRect(x: 0, y: top, width: w, height: bounds.height - top)
        pane.frame = NSRect(x: w, y: top, width: bounds.width - w, height: bounds.height - top)
        for v in pane.subviews { v.frame = pane.bounds }
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let core: CoreAPI
    private let ghostty: Ghostty.App
    private let fixture: Fixture?
    private let root = RootView()
    private(set) var tabs: [Tab] = []
    private var selectedId: String?
    private var refreshQueued = false
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?
    private lazy var listener = MainQueueListener { [weak self] in self?.coalescedRefresh() }

    init(core: CoreAPI, ghostty: Ghostty.App, fixture: Fixture?) {
        self.core = core
        self.ghostty = ghostty
        self.fixture = fixture
        let size = Fixture.windowSize
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        // Hidden in the title bar; still names the window in the Window menu and to accessibility.
        win.title = "Haunt"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.colorSpace = .sRGB
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = Tok.Color.windowBg
        win.minSize = NSSize(width: Tok.Size.sidebarW + 300, height: 240)
        win.tabbingMode = .disallowed
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(b)?.isHidden = true
        }
        win.contentView = root
        super.init(window: win)
        win.delegate = self

        root.titleBar.accessory = fixture?.titleAccessory ?? .icons
        root.titleBar.onIcon = { [weak self] icon in self?.titleIcon(icon) }
        root.sidebar.onSelect = { [weak self] id in self?.select(id) }
        core.setListener(listener: listener)
        // Subagent elapsed times are computed in snapshot(), so poll once a second to keep them ticking.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main) { [weak self] n in
            guard let view = n.object as? Ghostty.SurfaceView else { return }
            self?.surfaceWantsClose(view, processAlive: n.userInfo?["process_alive"] as? Bool ?? false)
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    func tab(for view: Ghostty.SurfaceView) -> Tab? { tabs.first { $0.view === view } }

    // MARK: Tabs

    func newTab(cwd: String? = nil, select selectIt: Bool = true) {
        guard let app = ghostty.app else { return }
        let dir = cwd ?? tabs.first { $0.env.surfaceId == selectedId }?.view.pwd ?? NSHomeDirectory()
        let env = core.registerSurface(cwd: dir)
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = dir
        config.environmentVariables = [
            "HAUNT": "1",
            "HAUNT_SURFACE_ID": env.surfaceId,
            "HAUNT_HOOK_NONCE": env.nonce,
            "HAUNT_SOCK": env.socketPath,
        ]
        if let fixture = fixtureCommand() { config.command = fixture }
        let view = Ghostty.SurfaceView(app, baseConfig: config, uuid: nil)
        // So the surface starts at the pane's real size.
        root.layoutSubtreeIfNeeded()
        let tab = Tab(env: env, view: view, size: root.pane.bounds.size)
        tab.subscriptions.append(view.$title.combineLatest(view.$pwd)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] title, pwd in self?.reportInfo(tab, title: title, pwd: pwd ?? dir) })
        tabs.append(tab)
        tab.host.frame = root.pane.bounds
        tab.host.isHidden = true
        root.pane.addSubview(tab.host)
        if selectIt || selectedId == nil { select(env.surfaceId) }
    }

    private func fixtureCommand() -> String? {
        guard fixture != nil else { return nil }
        let dir = FileManager.default.temporaryDirectory
        let text = dir.appendingPathComponent("haunt-fixture-pane.ansi")
        let script = dir.appendingPathComponent("haunt-fixture-pane.sh")
        try? Fixture.paneANSI().write(to: text, atomically: true, encoding: .utf8)
        // Ghostty runs the command as `exec -l <command>`, so the sequence has to live in a script.
        try? "/bin/cat '\(text.path)'\nexec /bin/sleep 2147483647\n".write(to: script, atomically: true, encoding: .utf8)
        return "/bin/sh '\(script.path)'"
    }

    private func reportInfo(_ tab: Tab, title: String, pwd: String) {
        core.setSurfaceInfo(surfaceId: tab.env.surfaceId, title: title, cwd: pwd, gitBranch: Git.branch(at: pwd))
    }

    func select(_ id: String) {
        guard let tab = tabs.first(where: { $0.env.surfaceId == id }) else { return }
        selectedId = id
        core.selectSurface(surfaceId: id)
        // Every surface stays in the window (hidden when not selected) so its size and display stay current.
        for t in tabs { t.host.isHidden = t !== tab }
        window?.makeFirstResponder(tab.view)
        syncFocus()
    }

    /// Like Ghostty's own controller: only the selected surface of the key window has focus. Ghostty learns
    /// the display only on screen changes, so it is told up front for its vsync display link.
    private func syncFocus() {
        let key = window?.isKeyWindow ?? false
        let display = window?.screen?.displayID
        for t in tabs {
            let selected = t.env.surfaceId == selectedId
            t.view.focusDidChange(key && selected && t.view.isFirstResponder)
            guard let surface = t.view.surface else { continue }
            if let display { ghostty_surface_set_display_id(surface, display) }
            if selected { ghostty_surface_refresh(surface) }
        }
    }

    /// ⌘1–9 follow the sidebar's display order.
    func select(index: Int) {
        let ids = root.sidebar.orderedIds
        if ids.indices.contains(index) { select(ids[index]) }
    }

    func closeSelectedTab() {
        guard let surface = tabs.first(where: { $0.env.surfaceId == selectedId })?.view.surface else { return }
        ghostty.requestClose(surface: surface)
    }

    private func surfaceWantsClose(_ view: Ghostty.SurfaceView, processAlive: Bool) {
        guard let tab = tab(for: view), let window else { return }
        guard processAlive else { return remove(tab) }
        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        alert.informativeText = "A process is still running in it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.remove(tab) }
        }
    }

    private func remove(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        let order = root.sidebar.orderedIds
        let pos = order.firstIndex(of: tab.env.surfaceId)
        tab.subscriptions.removeAll()
        tab.host.removeFromSuperview()
        tabs.remove(at: i)
        core.unregisterSurface(surfaceId: tab.env.surfaceId)
        guard !tabs.isEmpty else {
            window?.close()
            return
        }
        if selectedId == tab.env.surfaceId {
            let rest = order.filter { $0 != tab.env.surfaceId }
            let next = pos.map { rest[min($0, rest.count - 1)] } ?? tabs[0].env.surfaceId
            select(next)
        }
        refresh()
    }

    // MARK: Core

    /// A burst of hook events becomes one redraw.
    private func coalescedRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    func refresh() {
        let snap = core.snapshot()
        if snap != root.sidebar.snapshot { root.sidebar.snapshot = snap }
    }

    /// The core keeps running without its socket; agent rows then only get OSC status.
    func showStartError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Haunt can't receive agent events"
        alert.informativeText = "The hook socket didn't start: \(error). Agent rows will only show basic status."
        alert.beginSheetModal(for: window)
    }


    // MARK: Title bar

    private func titleIcon(_ icon: TitleBarView.Icon) {
        switch icon {
        case .search: break
        case .newTab: newTab()
        case .settings: (NSApp.delegate as? AppDelegate)?.openConfig(nil)
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard ghostty.needsConfirmQuit else { return true }
        let alert = NSAlert()
        alert.messageText = "Close the window?"
        alert.informativeText = "Processes are still running in its tabs."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { r in
            if r == .alertFirstButtonReturn { sender.close() }
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) { syncFocus() }
    func windowDidResignKey(_ notification: Notification) { syncFocus() }
    func windowDidChangeScreen(_ notification: Notification) { syncFocus() }

    func windowWillClose(_ notification: Notification) {
        for t in tabs { core.unregisterSurface(surfaceId: t.env.surfaceId) }
        tabs.removeAll()
    }
}
