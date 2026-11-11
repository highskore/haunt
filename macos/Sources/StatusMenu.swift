import AppKit

/// The menu bar menu's content (pawr-notif concept 07), from the sidebar's snapshot: its groups in order, shells left out.
struct StatusMenuModel: Equatable {
    struct Item: Equatable {
        var surfaceId: String
        var text: String
        var filled: Bool
        /// The tab's ⌘N, shown on rows waiting on you.
        var key: Shortcut?
    }

    struct Section: Equatable {
        var title: String
        var items: [Item]
    }

    var sections: [Section] = []
    var waiting = 0

    static let titles = ["NEEDS YOU": "Waiting on you", "RUNNING": "Running", "IDLE": "Idle"]

    init() {}

    /// `keys` maps a surface id to its select-tab shortcut, as the sidebar numbers its rows.
    init(snapshot: SidebarSnapshot, keys: [String: Shortcut]) {
        for g in snapshot.groups {
            let items = g.rows.filter { $0.kind != .shell }.map { r in
                Item(surfaceId: r.surfaceId, text: Self.text(r), filled: r.needsYou, key: r.needsYou ? keys[r.surfaceId] : nil)
            }
            if items.isEmpty { continue }
            sections.append(Section(title: Self.titles[g.label] ?? g.label.capitalized, items: items))
            waiting += items.filter(\.filled).count
        }
    }

    /// "api-refactor · approve push", "docs · 3/5 tasks", "infra · 2 subagents".
    static func text(_ r: Row) -> String {
        var detail = r.task
        if !r.needsYou {
            // The core shows running-with-progress as "3/5".
            if let p = r.progress, r.statusText == "\(p.done)/\(p.total)" {
                detail = "\(p.done)/\(p.total) tasks"
            } else if !r.subagents.isEmpty {
                detail = r.subagents.count == 1 ? "1 subagent" : "\(r.subagents.count) subagents"
            }
        }
        return detail.isEmpty ? r.name : "\(r.name) · \(detail)"
    }
}

/// The NSStatusItem with Haunt's glyph and the waiting count, and the menu it drops down.
/// The menu is drawn by Haunt (`StatusMenuView`), since an NSMenu can't take the mockup's highlight and keys.
final class StatusMenu: NSObject, NSWindowDelegate {
    var onOpen: ((String) -> Void)?
    var onTogglePause: (() -> Void)?

    private var item: NSStatusItem?
    private let panel = StatusMenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: true)
    private let view = StatusMenuView()
    private var model = StatusMenuModel()
    private var paused = false
    private var mouseMonitor: Any?
    /// The fixture capture keeps it open whatever has focus.
    private var sticky = false

    override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.colorSpace = .sRGB
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        panel.delegate = self
        view.onPick = { [weak self] i in self?.pick(i) }
        view.onClose = { [weak self] in self?.close() }
    }

    var isShown: Bool {
        get { item != nil }
        set {
            guard newValue != isShown else { return }
            if newValue {
                let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                it.button?.image = Self.glyph
                it.button?.imagePosition = .imageLeading
                it.button?.target = self
                it.button?.action = #selector(toggle(_:))
                it.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
                it.button?.setAccessibilityLabel("Haunt agents")
                item = it
                updateButton()
            } else {
                close()
                item.map(NSStatusBar.system.removeStatusItem)
                item = nil
            }
        }
    }

    func update(_ model: StatusMenuModel, paused: Bool) {
        guard model != self.model || paused != self.paused else { return }
        self.model = model
        self.paused = paused
        updateButton()
        view.entries = Self.entries(model, paused: paused)
        if panel.isVisible { position() }
    }

    private func updateButton() {
        item?.button?.title = model.waiting > 0 ? "\(model.waiting)" : ""
    }

    static func entries(_ model: StatusMenuModel, paused: Bool) -> [StatusMenuView.Entry] {
        var out: [StatusMenuView.Entry] = []
        for s in model.sections {
            out.append(.header(s.title))
            out += s.items.map { .item(text: $0.text, dot: $0.filled ? .filled : .hollow, key: $0.key, action: .open($0.surfaceId)) }
            out.append(.rule)
        }
        if model.sections.isEmpty { out += [.header("No agents"), .rule] }
        out.append(.item(text: paused ? "Resume notifications" : "Pause all notifications", dot: nil, key: nil, action: .togglePause))
        return out
    }

    @objc private func toggle(_ sender: Any?) {
        panel.isVisible ? close() : show()
    }

    private func show() {
        view.highlighted = nil
        position()
        item?.button?.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    #if HAUNT_FIXTURES
    /// The fixture: the mockup's menu with its first row highlighted, on the main screen rather than under an item.
    func showFixture() {
        sticky = true
        panel.level = .normal
        let size = view.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        view.highlighted = view.entries.firstIndex { if case .item = $0 { return true } else { return false } }
        panel.orderFrontRegardless()
    }
    #endif

    /// Left-aligned under the item, kept on its screen.
    private func position() {
        let size = view.fittingSize
        guard let button = item?.button, let win = button.window else {
            panel.setContentSize(size)
            return
        }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = win.screen?.visibleFrame ?? r
        let x = min(max(r.minX, screen.minX), screen.maxX - size.width)
        panel.setFrame(NSRect(x: x, y: r.minY - size.height - 1, width: size.width, height: size.height), display: true)
    }

    func close() {
        guard panel.isVisible, !sticky else { return }
        panel.orderOut(nil)
        item?.button?.highlight(false)
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func pick(_ i: Int) {
        guard view.entries.indices.contains(i), case let .item(_, _, _, action) = view.entries[i] else { return }
        close()
        switch action {
        case let .open(id): onOpen?(id)
        case .togglePause: onTogglePause?()
        }
    }

    /// Haunt's icon as a template: three blocks at the icon's 55% and the sleepy ghost with its eyes cut out.
    static let glyph: NSImage = {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // The icon's 1024 grid, body 220…804, into 1…15 pt.
            let s: CGFloat = 14 / 584
            ctx.translateBy(x: 1, y: 1)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -220, y: -220)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            for (x, y) in [(220.0, 220.0), (524.0, 220.0), (220.0, 524.0)] {
                ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 280, height: 280), cornerWidth: 40, cornerHeight: 40, transform: nil))
            }
            ctx.fillPath()
            let ghost = CGMutablePath()
            ghost.move(to: CGPoint(x: 524, y: 820))
            ghost.addLine(to: CGPoint(x: 524, y: 564))
            ghost.addQuadCurve(to: CGPoint(x: 564, y: 524), control: CGPoint(x: 524, y: 524))
            ghost.addLine(to: CGPoint(x: 764, y: 524))
            ghost.addQuadCurve(to: CGPoint(x: 804, y: 564), control: CGPoint(x: 804, y: 524))
            ghost.addLine(to: CGPoint(x: 804, y: 820))
            ghost.addQuadCurve(to: CGPoint(x: 710.667, y: 820), control: CGPoint(x: 757.333, y: 776))
            ghost.addQuadCurve(to: CGPoint(x: 617.333, y: 820), control: CGPoint(x: 664, y: 776))
            ghost.addQuadCurve(to: CGPoint(x: 524, y: 820), control: CGPoint(x: 570.667, y: 776))
            ghost.closeSubpath()
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(ghost)
            ctx.fillPath()
            // Closed eyes: the lower halves of 40×30 ellipses at (620, 640) and (708, 640).
            ctx.setBlendMode(.destinationOut)
            for cx in [620.0, 708.0] {
                let eye = CGMutablePath()
                let t = CGAffineTransform(translationX: cx, y: 640).scaledBy(x: 1, y: 0.75)
                eye.addArc(center: .zero, radius: 40, startAngle: 0, endAngle: .pi, clockwise: false, transform: t)
                eye.closeSubpath()
                ctx.addPath(eye)
            }
            ctx.fillPath()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

/// A borderless panel still has to take keys for the arrows, return and ⌘N.
final class StatusMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Draws the menu at the mockup's sizes (`.mb-drop`) and takes its mouse and keys.
final class StatusMenuView: NSView {
    enum Dot: Equatable { case filled, hollow }
    enum Action: Equatable { case open(String), togglePause }
    enum Entry: Equatable {
        case header(String)
        case item(text: String, dot: Dot?, key: Shortcut?, action: Action)
        case rule
    }

    var entries: [Entry] = [] {
        didSet {
            if entries != oldValue { highlighted = nil }
            needsDisplay = true
        }
    }
    var highlighted: Int? { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry (pt, border box)

    private let border: CGFloat = 1
    private let lh = Tok.Size.statusmenuLine
    private var inset: CGFloat { border + Tok.Size.statusmenuPad }
    private var innerW: CGFloat { Tok.Size.statusmenuW - 2 * inset }
    private var textH: CGFloat { Tok.Size.statusmenuFont * lh }
    private var kbdH: CGFloat { Tok.Size.statusmenuKbdFont * lh + 2 }

    private func height(_ e: Entry) -> CGFloat {
        switch e {
        case .header: return Tok.Size.statusmenuSubFont * lh + Tok.Size.statusmenuSubPad[0] * 2
        case let .item(_, _, key, _): return max(textH, key == nil ? 0 : kbdH) + Tok.Size.statusmenuItemPad[0] * 2
        case .rule: return 1 + Tok.Size.statusmenuRuleMargin * 2
        }
    }

    /// Each entry's top, with the grid's gap between entries.
    private var tops: [CGFloat] {
        var y = inset, out: [CGFloat] = []
        for e in entries {
            out.append(y)
            y += height(e) + Tok.Size.statusmenuGap
        }
        return out
    }

    override var fittingSize: NSSize {
        let content = entries.reduce(0) { $0 + height($1) } + Tok.Size.statusmenuGap * CGFloat(max(entries.count - 1, 0))
        return NSSize(width: Tok.Size.statusmenuW, height: (content + 2 * inset).rounded())
    }

    private func index(at p: NSPoint) -> Int? {
        guard p.x >= inset, p.x < inset + innerW else { return nil }
        for (i, top) in tops.enumerated() where p.y >= top && p.y < top + height(entries[i]) {
            if case .item = entries[i] { return i }
            return nil
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = Tok.Size.statusmenuRadius
        Tok.Color.statusmenuBorder.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        Tok.Color.statusmenuBg.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: border, dy: border), xRadius: r - border, yRadius: r - border).fill()
        for (i, top) in tops.enumerated() {
            let e = entries[i], h = height(e)
            switch e {
            case let .header(title):
                let f = Draw.mono(Tok.Size.statusmenuSubFont)
                let line = Draw.truncated(Draw.line(title, f, Tok.Color.statusmenuMute), innerW - 2 * Tok.Size.statusmenuSubPad[1], f, Tok.Color.statusmenuMute)
                Draw.text(line, font: f, x: inset + Tok.Size.statusmenuSubPad[1], top: top + Tok.Size.statusmenuSubPad[0],
                          lineHeight: Tok.Size.statusmenuSubFont * lh, in: ctx)
            case .rule:
                Draw.fill(NSRect(x: inset, y: top + Tok.Size.statusmenuRuleMargin, width: innerW, height: 1), Tok.Color.statusmenuBorder)
            case let .item(text, dot, key, _):
                drawItem(text: text, dot: dot, key: key, rect: NSRect(x: inset, y: top, width: innerW, height: h),
                         hl: i == highlighted, ctx: ctx)
            }
        }
    }

    private func drawItem(text: String, dot: Dot?, key: Shortcut?, rect: NSRect, hl: Bool, ctx: CGContext) {
        let fg = hl ? Tok.Color.statusmenuHlFg : Tok.Color.statusmenuInk
        if hl {
            let r = Tok.Size.statusmenuItemRadius
            Tok.Color.statusmenuInk.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        }
        let padX = Tok.Size.statusmenuItemPad[1], gap = Tok.Size.statusmenuItemGap
        var x = rect.minX + padX
        let mid = rect.midY
        if let dot {
            let d = Tok.Size.statusmenuDot
            let box = NSRect(x: x, y: mid - d / 2, width: d, height: d)
            if dot == .filled {
                fg.setFill()
                NSBezierPath(ovalIn: box).fill()
            } else {
                let p = NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5))
                p.lineWidth = 1
                (hl ? fg : Tok.Color.statusmenuMute).setStroke()
                p.stroke()
            }
            x += d + gap
        }
        var right = rect.maxX - padX
        if let key {
            let f = Draw.mono(Tok.Size.statusmenuKbdFont)
            let kc = hl ? fg : Tok.Color.statusmenuMute
            let line = Draw.line(key.display, f, kc)
            let pad = Tok.Size.statusmenuKbdPad[1]
            let box = NSRect(x: right - Draw.width(line) - 2 * pad - 2, y: mid - kbdH / 2, width: Draw.width(line) + 2 * pad + 2, height: kbdH)
            let kr = Tok.Size.statusmenuKbdRadius
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: kr - 0.5, yRadius: kr - 0.5)
            path.lineWidth = 1
            (hl ? fg : Tok.Color.statusmenuLine).setStroke()
            path.stroke()
            Draw.text(line, font: f, x: box.minX + 1 + pad, top: box.minY + 1, lineHeight: kbdH - 2, in: ctx)
            right = box.minX - gap
        }
        let f = Draw.mono(Tok.Size.statusmenuFont)
        let line = Draw.truncated(Draw.line(text, f, fg), right - x, f, fg)
        Draw.text(line, font: f, x: x, top: mid - textH / 2, lineHeight: textH, in: ctx)
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != highlighted { highlighted = i }
    }

    override func mouseExited(with event: NSEvent) { highlighted = nil }

    override func mouseUp(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onPick?(i) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onClose?()
            return
        case 36, 76:
            if let h = highlighted { onPick?(h) }
            return
        case 126: return move(-1)
        case 125: return move(1)
        default: break
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        for (i, e) in entries.enumerated() {
            guard case let .item(_, _, key?, _) = e, key.mods == mods,
                  key.keyEquivalent == event.charactersIgnoringModifiers?.lowercased() else { continue }
            onPick?(i)
            return
        }
        super.keyDown(with: event)
    }

    private func move(_ d: Int) {
        let items = entries.indices.filter { if case .item = entries[$0] { return true } else { return false } }
        guard !items.isEmpty else { return }
        let at = highlighted.flatMap { items.firstIndex(of: $0) }
        let next = at.map { min(max($0 + d, 0), items.count - 1) } ?? (d > 0 ? 0 : items.count - 1)
        highlighted = items[next]
    }
}
