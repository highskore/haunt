import AppKit
import Combine
import GhosttyKit
import UserNotifications

/// Our surface: it reports each keyDown and paste that reaches it, so the core can retire a request the user
/// may already have answered at the terminal. A subclass, so the vendored Ghostty sources stay unpatched;
/// Ghostty's own bindings that it handles in performKeyEquivalent also arrive here through keyDown.
final class HauntSurfaceView: Ghostty.SurfaceView {
    var onInput: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        onInput?()
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        onInput?()
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        onInput?()
        super.pasteAsPlainText(sender)
    }

    override func pasteSelection(_ sender: Any?) {
        onInput?()
        super.pasteSelection(sender)
    }
}

/// One sidebar row: a libghostty surface registered with the core.
final class Tab {
    let env: SurfaceEnv
    let view: Ghostty.SurfaceView
    /// Ghostty's scroll wrapper; it is what tells the surface its size.
    let host: SurfaceScrollView
    var subscriptions: [AnyCancellable] = []
    /// Bumped per info report, so a slow branch lookup never overwrites a newer one.
    var infoGeneration = 0

    init(env: SurfaceEnv, view: Ghostty.SurfaceView, size: CGSize) {
        self.env = env
        self.view = view
        host = SurfaceScrollView(contentSize: size, surfaceView: view)
    }
}

/// Lays out title bar, sidebar and pane at fixed mockup sizes; without the sidebar, mockup 10's.
private final class RootView: NSView {
    let titleBar = TitleBarView()
    let sidebar = SidebarView()
    let pane = NSView()
    /// The palette mockup's scrim over everything below the title bar.
    let scrim = NSView()

    var sidebarHidden = false {
        didSet {
            titleBar.zen = sidebarHidden
            sidebar.isHidden = sidebarHidden
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pane.wantsLayer = true
        pane.layer?.backgroundColor = Tok.Color.windowBg.cgColor
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor(white: 0, alpha: Tok.Size.paletteScrimAlpha).cgColor
        scrim.isHidden = true
        for v in [titleBar, sidebar, pane, scrim] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let top = TitleBarView.height(zen: sidebarHidden), w = sidebarHidden ? 0 : Tok.Size.sidebarW
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        sidebar.frame = NSRect(x: 0, y: top, width: Tok.Size.sidebarW, height: bounds.height - top)
        pane.frame = NSRect(x: w, y: top, width: bounds.width - w, height: bounds.height - top)
        scrim.frame = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        for v in pane.subviews { v.frame = pane.bounds }
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let core: CoreAPI
    private let ghostty: Ghostty.App
    private let fixture: Fixture?
    private let config: HauntConfig
    private let plugins: PluginsAPI?
    private lazy var palette: PaletteController = {
        let p = PaletteController(host: self)
        p.sticky = fixture != nil
        return p
    }()
    private let root = RootView()
    private(set) var tabs: [Tab] = []
    private var selectedId: String?
    private var refreshQueued = false
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?
    private lazy var listener = MainQueueListener { [weak self] in self?.coalescedRefresh() }

    init(core: CoreAPI, ghostty: Ghostty.App, fixture: Fixture?, config: HauntConfig, plugins: PluginsAPI?) {
        self.core = core
        self.ghostty = ghostty
        self.fixture = fixture
        self.config = config
        self.plugins = plugins
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
        root.titleBar.onHint = { [weak self] hint in
            switch hint {
            case .agents: self?.toggleSidebar()
            case .search: self?.togglePalette()
            }
        }
        // Fixtures neither read nor overwrite the user's saved state.
        root.sidebarHidden = fixture?.sidebarHidden ?? config.loadState().sidebarHidden
        updateKeys(config.keys)
        root.sidebar.onSelect = { [weak self] id in self?.select(id) }
        core.setListener(listener: listener)
        // Subagent elapsed times are computed in snapshot(), so poll once a second to keep them ticking.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.drainPluginRequests()
        }

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
        // The core refuses past its surface cap; no tab beats an unverifiable one.
        guard let env = try? core.registerSurface(cwd: dir) else { NSSound.beep(); return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = dir
        config.environmentVariables = [
            "HAUNT": "1",
            "HAUNT_SURFACE_ID": env.surfaceId,
            "HAUNT_HOOK_NONCE": env.nonce,
            "HAUNT_SOCK": env.socketPath,
        ]
        if let fixture = fixtureCommand() { config.command = fixture }
        let view = HauntSurfaceView(app, baseConfig: config, uuid: nil)
        // Before the keystroke reaches the pty, so a late Allow/Deny can't be typed into a running tool.
        view.onInput = { [weak self] in self?.core.onUserInput(surfaceId: env.surfaceId) }
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

    private static let gitQueue = DispatchQueue(label: "dev.haunt.git", qos: .utility)

    /// The branch lookup reads files a pty-chosen pwd points at, so it stays off the main thread.
    private func reportInfo(_ tab: Tab, title: String, pwd: String) {
        tab.infoGeneration += 1
        let gen = tab.infoGeneration
        Self.gitQueue.async { [weak self, weak tab] in
            let branch = Git.branch(at: pwd)
            DispatchQueue.main.async {
                guard let self, let tab, tab.infoGeneration == gen else { return }
                self.core.setSurfaceInfo(surfaceId: tab.env.surfaceId, title: title, cwd: pwd, gitBranch: branch)
            }
        }
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
        let sel = snap.groups.lazy.flatMap(\.rows).first { $0.selected }
        root.titleBar.progress = sel?.progress.map { $0.total == 0 ? 0 : CGFloat($0.done) / CGFloat($0.total) }
    }

    // MARK: Sidebar, palette, keys

    var isSidebarHidden: Bool { root.sidebarHidden }

    func toggleSidebar() {
        root.sidebarHidden.toggle()
        root.layoutSubtreeIfNeeded()
        if fixture == nil {
            var state = config.loadState()
            state.sidebarHidden = root.sidebarHidden
            config.saveState(state)
        }
    }

    /// The zen hint and anything else that shows a shortcut follow the `[keys]` table.
    func updateKeys(_ keys: KeyMap) {
        func hint(_ a: KeyMap.Action, _ word: String) -> String {
            keys[a].map { "\($0.display) \(word)" } ?? word
        }
        root.titleBar.hints = [(.agents, hint(.toggleSidebar, "agents")), (.search, hint(.palette, "search"))]
    }

    func togglePalette() {
        if palette.isOpen { return palette.close() }
        openPalette()
    }

    func openPalette(text: String = "") {
        guard let window else { return }
        root.scrim.isHidden = false
        palette.open(over: window, top: TitleBarView.height(zen: root.sidebarHidden) + Tok.Size.paletteTop, text: text)
    }

    func paletteFixtureSelectNext() { palette.edit(.down) }

    /// Writes bytes the core handed back for a surface, as `ghostty_surface_text` does for typed text.
    private func write(_ bytes: Data, to surfaceId: String) {
        guard !bytes.isEmpty, let surface = tabs.first(where: { $0.env.surfaceId == surfaceId })?.view.surface else { return }
        bytes.withUnsafeBytes { buf in
            guard let p = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, p, UInt(buf.count))
        }
    }

    // MARK: Plugins

    /// `.notify` becomes a macOS notification; a `.ptyAnswer` is written only as the bytes the core's gate returns.
    func drainPluginRequests() {
        guard let plugins else { return }
        for req in plugins.takeRequests() {
            switch req {
            case let .notify(pluginId, title, body, _, _):
                Self.notify(pluginId: pluginId, title: title, body: body)
            case .ptyAnswer:
                guard let w = core.gatePluginRequest(request: req) else { continue }
                write(w.bytes, to: w.surfaceId)
            }
        }
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
        case .search: togglePalette()
        case .newTab: newTab()
        case .settings: (NSApp.delegate as? AppDelegate)?.openConfig(nil)
        case .sidebar: toggleSidebar()
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

    func windowDidResize(_ notification: Notification) {
        guard palette.isOpen, let window else { return }
        palette.position(over: window, top: TitleBarView.height(zen: root.sidebarHidden) + Tok.Size.paletteTop)
    }

    func windowWillClose(_ notification: Notification) {
        for t in tabs { core.unregisterSurface(surfaceId: t.env.surfaceId) }
        tabs.removeAll()
    }
}

extension MainWindowController: PaletteHost {
    var paletteTabs: [Row] {
        let order = root.sidebar.orderedIds
        let rows = Dictionary(root.sidebar.snapshot.groups.flatMap(\.rows).map { ($0.surfaceId, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { rows[$0] }
    }

    var selectedSurfaceId: String? { selectedId }

    func paletteDecisions(query: String) -> [Decision] { core.decisions(query: query, limit: 200) }

    var palettePlugins: PluginsAPI? { plugins }

    var pluginLoadErrors: [String] { plugins?.loadErrors() ?? [] }

    func paletteSelectTab(_ surfaceId: String) { select(surfaceId) }

    func paletteInvoke(pluginId: String, itemId: String) {
        do {
            try plugins?.invokePaletteItem(pluginId: pluginId, itemId: itemId)
        } catch {
            AppDelegate.logger.error("plugin \(pluginId, privacy: .public) item \(itemId, privacy: .public): \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
        drainPluginRequests()
    }

    func paletteDidClose() {
        root.scrim.isHidden = true
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        if let tab = tabs.first(where: { $0.env.surfaceId == selectedId }) { window.makeFirstResponder(tab.view) }
        syncFocus()
    }
}
