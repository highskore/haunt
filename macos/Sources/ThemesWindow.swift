import AppKit

/// What the Themes window reads and drives; `AppDelegate` provides it.
protocol ThemesHost: AnyObject {
    var themeChoices: [HauntConfig.ThemeChoice] { get }
    /// The theme on screen when no preview runs.
    var savedTheme: String { get }
    func loadTheme(_ id: String) -> Theme
    /// Shows `id` live; nil goes back to config.toml's theme.
    func previewTheme(_ id: String?)
    func chooseTheme(_ id: String)
}

/// View ▸ Themes…: a card per theme drawn in its own colours. A click previews it, Use Theme (or a
/// double click) keeps it; Cancel, esc or closing the window puts the previous theme back.
final class ThemesWindowController: NSWindowController, NSWindowDelegate {
    /// The buttons below the grid, their gap and the bottom inset.
    private static let buttonsH: CGFloat = 60
    private weak var host: ThemesHost?
    private let grid = ThemeGridView()
    private let scroll = NSScrollView()
    private var use: NSButton!
    private var cancel: NSButton!
    private var targets: [BlockTarget] = []
    /// The theme to go back to; nil once one was kept.
    private var before: String?
    private(set) var previewed: String?

    init(host: ThemesHost) {
        self.host = host
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ThemeGridView.width, height: 400),
                           styleMask: [.titled, .closable], backing: .buffered, defer: true)
        win.title = "Themes"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        grid.onSelect = { [weak self] id in self?.preview(id) }
        grid.onKeep = { [weak self] in self?.keep() }
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        use = button("Use Theme", key: "\r") { [weak self] in self?.keep() }
        cancel = button("Cancel", key: "\u{1b}") { [weak self] in self?.window?.performClose(nil) }
        let buttons = NSStackView(views: [NSView(), cancel, use])
        buttons.orientation = .horizontal
        buttons.spacing = Tok.App.settingsRowGap
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(buttons)
        let inset = Tok.App.settingsInsets
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Tok.App.settingsGap),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset.left),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset.right),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset.bottom),
        ])
        win.contentView = content
        themeDidChange()
    }

    required init?(coder: NSCoder) { fatalError() }

    func open() {
        if window?.isVisible != true { load() }
        showWindow(nil)
        window?.makeFirstResponder(grid)
    }

    /// Re-reads the list, which may have changed since last time, and starts on the theme in use.
    func load() {
        guard let host else { return }
        before = host.savedTheme
        previewed = nil
        grid.set(host.themeChoices.map { ($0, host.loadTheme($0.id)) }, selected: host.savedTheme)
        let rows = CGFloat(min(3, (grid.count + ThemeGridView.columns - 1) / ThemeGridView.columns))
        window?.setContentSize(NSSize(width: ThemeGridView.width, height: ThemeGridView.height(rows: rows) + Self.buttonsH))
        window?.center()
    }

    func themeDidChange() {
        window?.appearance = Tok.App.appearance
        window?.backgroundColor = Tok.Color.windowBg
        grid.needsDisplay = true
    }

    func preview(_ id: String) {
        guard let before, id != (previewed ?? before) else { return }
        previewed = id
        host?.previewTheme(id)
    }

    func keep() {
        guard let id = grid.selectedId else { return }
        before = nil
        previewed = nil
        host?.chooseTheme(id)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard before != nil else { return }
        before = nil
        if previewed != nil { host?.previewTheme(nil) }
        previewed = nil
    }

    private func button(_ title: String, key: String, _ action: @escaping () -> Void) -> NSButton {
        let t = BlockTarget(action)
        targets.append(t)
        let b = NSButton(title: title, target: t, action: #selector(BlockTarget.fire))
        b.bezelStyle = .rounded
        b.keyEquivalent = key
        return b
    }
}

/// The cards: a miniature of the app (title bar, sidebar with a selected row, terminal lines) in each
/// theme's own colours, with its name below.
final class ThemeGridView: NSView {
    static let columns = 3
    static let thumb = NSSize(width: 176, height: 110)
    static let gap: CGFloat = 16
    static let labelH: CGFloat = 44
    static var width: CGFloat { Tok.App.settingsInsets.left + Tok.App.settingsInsets.right + CGFloat(columns) * thumb.width + CGFloat(columns - 1) * gap }
    static func height(rows: CGFloat) -> CGFloat {
        Tok.App.settingsInsets.top + rows * (thumb.height + labelH) + max(0, rows - 1) * gap
    }

    var onSelect: ((String) -> Void)?
    var onKeep: (() -> Void)?
    private var cards: [(HauntConfig.ThemeChoice, Theme)] = []
    private var selected = 0

    var count: Int { cards.count }
    var selectedId: String? { cards.indices.contains(selected) ? cards[selected].0.id : nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func set(_ cards: [(HauntConfig.ThemeChoice, Theme)], selected id: String) {
        self.cards = cards
        selected = cards.firstIndex { $0.0.id == id } ?? 0
        let rows = CGFloat((cards.count + Self.columns - 1) / Self.columns)
        setFrameSize(NSSize(width: Self.width, height: Self.height(rows: rows)))
        needsDisplay = true
    }

    private func frame(_ i: Int) -> NSRect {
        let (row, col) = (i / Self.columns, i % Self.columns)
        return NSRect(x: Tok.App.settingsInsets.left + CGFloat(col) * (Self.thumb.width + Self.gap),
                      y: Tok.App.settingsInsets.top + CGFloat(row) * (Self.thumb.height + Self.labelH + Self.gap),
                      width: Self.thumb.width, height: Self.thumb.height)
    }

    func select(_ i: Int) {
        guard cards.indices.contains(i) else { return }
        selected = i
        scrollToVisible(frame(i).insetBy(dx: 0, dy: -Self.gap))
        needsDisplay = true
        onSelect?(cards[i].0.id)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = cards.indices.first(where: { var f = frame($0); f.size.height += Self.labelH; return f.contains(p) }) else { return }
        select(i)
        if event.clickCount == 2 { onKeep?() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: select(selected - 1)
        case 124: select(selected + 1)
        case 125: select(selected + Self.columns)
        case 126: select(selected - Self.columns)
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (i, (choice, theme)) in cards.enumerated() {
            let r = frame(i)
            Self.miniature(theme.color, in: r)
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: 8, yRadius: 8)
            ring.lineWidth = i == selected ? 2 : Tok.App.hairline
            (i == selected ? Tok.Color.textHi : Tok.Color.hairline).setStroke()
            ring.stroke()
            let name = Draw.ui(Tok.Size.rowName, i == selected ? .semibold : .regular)
            Draw.text(Draw.truncated(Draw.line(choice.name, name, Tok.Color.textHi), r.width, name, Tok.Color.textHi),
                      font: name, x: r.minX, top: r.maxY + 8, lineHeight: Tok.Size.rowName * Tok.Font.baseLine, in: ctx)
            let meta = Draw.ui(Tok.Size.rowMeta)
            Draw.text(Draw.line(choice.id, meta, Tok.Color.textMeta), font: meta, x: r.minX,
                      top: r.maxY + 8 + Tok.Size.rowName * Tok.Font.baseLine, lineHeight: Tok.Size.rowMeta * Tok.Font.baseLine, in: ctx)
        }
    }

    /// Bars stand in for text, so a theme's fonts needn't be loaded to show its colours.
    static func miniature(_ c: Theme.Colors, in r: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).addClip()
        Draw.fill(r, c.windowBg)
        let title = NSRect(x: r.minX, y: r.minY, width: r.width, height: 14)
        Draw.fill(title, c.windowBg)
        Draw.fill(NSRect(x: r.minX, y: title.maxY, width: r.width, height: 1), c.hairline)
        for (j, dot) in [c.textMeta, c.textMeta, c.textMeta].enumerated() {
            Draw.fill(NSRect(x: r.minX + 6 + CGFloat(j) * 7, y: r.minY + 5, width: 4, height: 4), dot)
        }
        let side = NSRect(x: r.minX, y: title.maxY + 1, width: (r.width * 0.38).rounded(), height: r.maxY - title.maxY - 1)
        Draw.fill(side, c.sidebarBg)
        Draw.fill(NSRect(x: side.maxX, y: side.minY, width: 1, height: side.height), c.hairline)
        for k in 0..<4 {
            let row = NSRect(x: side.minX + 4, y: side.minY + 6 + CGFloat(k) * 20, width: side.width - 8, height: 16)
            if k == 1 { Draw.fill(row, c.rowSelected) }
            Draw.fill(NSRect(x: row.minX + 4, y: row.minY + 4, width: 4, height: 4), k == 0 ? c.needs : k == 1 ? c.claude : c.dot)
            Draw.fill(NSRect(x: row.minX + 12, y: row.minY + 3, width: row.width * 0.55, height: 3), c.textHi)
            Draw.fill(NSRect(x: row.minX + 12, y: row.minY + 10, width: row.width * 0.4, height: 2), c.textMeta)
        }
        let term = NSRect(x: side.maxX + 1, y: side.minY, width: r.maxX - side.maxX - 1, height: side.height)
        for (k, w) in [0.7, 0.45, 0.6, 0.3, 0.52].enumerated() {
            Draw.fill(NSRect(x: term.minX + 8, y: term.minY + 8 + CGFloat(k) * 9, width: (term.width - 16) * w, height: 3),
                      k == 3 ? c.textMeta : c.textPrimary)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
