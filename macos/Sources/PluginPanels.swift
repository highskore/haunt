import AppKit

/// Where plugin panels go: sheets and cards hang off the main window, a right pane sits beside the terminal.
protocol PanelHost: AnyObject {
    var window: NSWindow? { get }
    func setRightPane(_ view: NSView?)
    /// The right pane's width the user last chose for a plugin, kept across launches.
    func rightPaneWidth(plugin: String) -> CGFloat?
    func setRightPaneWidth(_ width: CGFloat, plugin: String)
}

/// Shows the panels plugins describe (`HostRequest.showPanel`), drawn natively from the core's checked
/// node tree. A button press or the user closing one goes back through `onAction` with its show's generation.
/// No show takes focus: a plugin's timer can call `show`.
final class PluginPanels {
    static let rightWidth: CGFloat = 320
    static let rightWidths: ClosedRange<CGFloat> = 280...480
    private static let cardWidth: CGFloat = 300
    private static let sheetWidth: CGFloat = 420
    private static let windowWidth: CGFloat = 480
    private static let inset: CGFloat = 16

    weak var host: PanelHost?
    /// (plugin id, panel id, generation, action); an empty action means the user closed it.
    var onAction: ((String, String, UInt64, String) -> Void)?
    /// A button bound to a tab brings it forward before its action goes to the plugin.
    var openTab: ((String) -> Void)?

    private struct Key: Hashable { let plugin: String, id: String }
    private final class Shown {
        let placement: PanelPlacement
        let window: NSWindow?
        let frame: PanelFrame
        var generation: UInt64
        init(placement: PanelPlacement, window: NSWindow?, frame: PanelFrame, generation: UInt64) {
            self.placement = placement
            self.window = window
            self.frame = frame
            self.generation = generation
        }
    }
    private var shown: [Key: Shown] = [:]
    private var closeObservers: [Key: NSObjectProtocol] = [:]
    /// The one panel in the right pane; another plugin's show there replaces it.
    private var rightOwner: Key?

    func show(pluginId: String, pluginName: String, panel: Panel) {
        let key = Key(plugin: pluginId, id: panel.id)
        if let s = shown[key], s.placement == panel.placement {
            s.generation = panel.generation
            s.frame.update(panel)
            if let w = s.window { fit(w, s.placement) }
            return
        }
        close(key, byUser: false)
        // One sheet at a time, Haunt's own included: a second comes up as a card, which never takes the keys.
        let placement: PanelPlacement = panel.placement == .sheet && host?.window?.attachedSheet != nil ? .card : panel.placement
        if placement == .right, let old = rightOwner { close(old, byUser: false) }
        let frame = PanelFrame(from: pluginName, card: placement == .card) { [weak self] action in
            guard let self, let s = self.shown[key] else { return }
            if action.isEmpty { self.close(key, byUser: true) } else { self.onAction?(pluginId, panel.id, s.generation, action) }
        }
        frame.openTab = { [weak self] id in self?.openTab?(id) }
        frame.update(panel)
        var window: NSWindow?
        switch placement {
        case .right:
            rightOwner = key
            let pane = RightPane(frame, width: host?.rightPaneWidth(plugin: pluginId) ?? Self.rightWidth)
            pane.onResized = { [weak self] w in self?.host?.setRightPaneWidth(w, plugin: pluginId) }
            host?.setRightPane(pane)
        case .sheet:
            let w = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = frame
            fit(w, .sheet)
            w.onCancel = { [weak self] in self?.close(key, byUser: true) }
            host?.window?.beginSheet(w)
            window = w
        case .card:
            let w = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 120),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isFloatingPanel = true
            w.level = .floating
            w.hasShadow = true
            w.backgroundColor = .clear
            frame.wantsLayer = true
            frame.layer?.cornerRadius = Tok.Size.floatRadius
            frame.layer?.borderWidth = 1
            frame.layer?.borderColor = Tok.Color.floatBorder.cgColor
            w.contentView = frame
            fit(w, .card)
            if let main = host?.window {
                main.addChildWindow(w, ordered: .above)
                let top = main.frame.maxY - TitleBarView.height(zen: false) - Self.inset
                // Beside the right pane, not over it.
                let pane = rightOwner.flatMap { shown[$0]?.frame.superview as? RightPane }
                let right = main.frame.maxX - (pane.map { $0.frame.width } ?? 0)
                w.setFrameTopLeftPoint(NSPoint(x: right - w.frame.width - Self.inset, y: top))
            }
            w.orderFront(nil)
            window = w
        case .window:
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 300),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.title = "From \(pluginName)"
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Tok.Color.windowBg
            w.contentView = frame
            fit(w, .window)
            w.center()
            closeObservers[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) {
                [weak self] _ in self?.close(key, byUser: true)
            }
            w.orderFront(nil)
            window = w
        }
        shown[key] = Shown(placement: placement, window: window, frame: frame, generation: panel.generation)
    }

    func close(pluginId: String, id: String) {
        close(Key(plugin: pluginId, id: id), byUser: false)
    }

    /// Every panel goes, as when the plugins reload.
    func closeAll() {
        for key in Array(shown.keys) { close(key, byUser: false) }
    }

    private func close(_ key: Key, byUser: Bool) {
        guard let s = shown.removeValue(forKey: key) else { return }
        if let o = closeObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(o) }
        switch s.placement {
        case .right:
            if rightOwner == key {
                rightOwner = nil
                host?.setRightPane(nil)
            }
        case .sheet: if let w = s.window { (w.sheetParent ?? host?.window)?.endSheet(w) }
        case .card: if let w = s.window { w.parent?.removeChildWindow(w); w.orderOut(nil) }
        case .window: s.window?.close()
        }
        if byUser { onAction?(key.plugin, key.id, s.generation, "") }
    }

    /// Sizes a window to its content's height, at most 80% of the screen; the rest scrolls.
    private func fit(_ w: NSWindow, _ placement: PanelPlacement) {
        guard let v = w.contentView as? PanelFrame else { return }
        let width: CGFloat = placement == .card ? Self.cardWidth : placement == .sheet ? Self.sheetWidth : max(w.frame.width, Self.windowWidth)
        v.frame.size.width = width
        let maxH = (w.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let h = min(max(v.contentHeight(width: width), 60), maxH * 0.8)
        w.setContentSize(NSSize(width: width, height: h))
    }
}

/// Esc closes a sheet or card the way the user's close button would.
private final class PanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A panel's content: the host's header, which the plugin can't style ("From <plugin name>" and a close
/// button), then the plugin's title and node tree, scrolling when taller than the window.
final class PanelFrame: NSView {
    static let headerHeight: CGFloat = 30
    private let send: (String) -> Void
    var openTab: ((String) -> Void)?
    /// Keyed canvas shapes as last drawn, for the next `update` to ease from.
    private var previous: [String: CanvasView.Place] = [:]
    private let body = NSStackView()
    private let scroll = NSScrollView()

    override var isFlipped: Bool { true }

    init(from pluginName: String, card: Bool, send: @escaping (String) -> Void) {
        self.send = send
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (card ? Tok.Color.cardBg : Tok.Color.windowBg).cgColor
        setAccessibilityLabel("Panel from \(pluginName)")

        let from = NSTextField(labelWithString: "From \(pluginName)")
        from.font = Draw.mono(11)
        from.textColor = Tok.Color.textMeta
        from.lineBreakMode = .byTruncatingTail
        let close = NSButton(title: "×", target: self, action: #selector(closePressed))
        close.isBordered = false
        close.font = Draw.ui(15)
        close.contentTintColor = Tok.Color.textMeta
        close.setAccessibilityLabel("Close")
        let rule = NSBox()
        rule.boxType = .separator

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        let doc = FlippedView()
        doc.addSubview(body)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for v in [from, close, rule, scroll, body, doc] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        for v in [from, close, rule, scroll] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            from.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight / 2),
            from.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            from.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: from.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rule.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.topAnchor.constraint(equalTo: doc.topAnchor),
            body.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closePressed() { send("") }

    /// The height that shows everything without scrolling, at `width`.
    func contentHeight(width: CGFloat) -> CGFloat {
        frame.size.width = width
        layoutSubtreeIfNeeded()
        return Self.headerHeight + 1 + body.fittingSize.height
    }

    /// Rebuilds the tree; the core already checked parents, depth and caps.
    func update(_ panel: Panel) {
        previous = [:]
        for c in Self.canvases(in: body) { previous.merge(c.places) { a, _ in a } }
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !panel.title.isEmpty {
            let t = NSTextField(labelWithString: panel.title)
            t.font = Draw.ui(13, .semibold)
            t.textColor = Tok.Color.textPrimary
            t.lineBreakMode = .byTruncatingTail
            body.addArrangedSubview(t)
        }
        var views: [NSView] = []
        for n in panel.nodes {
            let v = view(for: n.kind)
            views.append(v)
            if let p = n.parent.map(Int.init), p < views.count, let stack = views[p] as? NSStackView {
                stack.addArrangedSubview(v)
            } else {
                body.addArrangedSubview(v)
            }
        }
        // Top-level rows and dividers span the panel.
        for v in body.arrangedSubviews where v is NSBox || v is PanelRow {
            v.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
        }
    }

    private static func canvases(in v: NSView) -> [CanvasView] {
        v.subviews.flatMap { ($0 as? CanvasView).map { [$0] } ?? canvases(in: $0) }
    }

    private func view(for kind: PanelNodeKind) -> NSView {
        switch kind {
        case .vStack, .hStack:
            let s = NSStackView()
            s.orientation = kind == .vStack ? .vertical : .horizontal
            s.alignment = kind == .vStack ? .leading : .centerY
            s.spacing = 8
            return s
        case let .text(text, tone, mono, bold):
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = mono ? Draw.mono(12) : Draw.ui(13, bold ? .semibold : .regular)
            l.textColor = Self.color(tone)
            l.preferredMaxLayoutWidth = PluginPanels.rightWidth
            return l
        case let .row(label, sub, right, tone):
            return PanelRow(label: label, sub: sub, right: right, color: Self.color(tone))
        case let .button(label, action, _, surface):
            // No key equivalent, even for `primary`: Return never presses a plugin's button.
            let b = ActionButton(title: label, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.onPress = { [weak self] in
                if let surface { self?.openTab?(surface) }
                self?.send(action)
            }
            // A plugin opens a link only from the button whose action is that link, so it is shown first.
            if action.hasPrefix("https://") { b.toolTip = action }
            return b
        case .divider:
            let b = NSBox()
            b.boxType = .separator
            return b
        case let .grid(rows, columns, cell, cells, marked):
            return GridView(rows: Int(rows), columns: Int(columns), cell: CGFloat(cell), cells: cells, marked: Set(marked.map(Int.init)))
        case let .canvas(width, height, shapes, easeMs):
            return CanvasView(size: NSSize(width: CGFloat(width), height: CGFloat(height)), shapes: shapes, from: previous,
                              ease: CFTimeInterval(easeMs) / 1000)
        }
    }

    static func color(_ t: PanelTone) -> NSColor {
        switch t {
        case .text: return Tok.Color.textPrimary
        case .dim: return Tok.Color.textSub
        case .faint: return Tok.Color.textMeta
        case .warn: return Tok.App.pluginWarn
        }
    }

    /// 0 is the background, 1 the text colour, in five steps.
    static func shade(_ s: Float) -> NSColor {
        let step = CGFloat((max(0, min(1, s)) * 4).rounded() / 4)
        return Tok.Color.windowBg.blended(withFraction: 0.12 + 0.88 * step, of: Tok.Color.textPrimary) ?? Tok.Color.textPrimary
    }
}

private final class ActionButton: NSButton {
    var onPress: (() -> Void)?
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        onPress?()
        return true
    }
}

/// A label with an optional line under it, and a right-hand value.
private final class PanelRow: NSStackView {
    init(label: String, sub: String?, right: String?, color: NSColor) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 1
        let l = NSTextField(labelWithString: label)
        l.font = Draw.ui(13)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        left.addArrangedSubview(l)
        if let sub {
            let s = NSTextField(labelWithString: sub)
            s.font = Draw.ui(11.5)
            s.textColor = Tok.Color.textMeta
            s.lineBreakMode = .byTruncatingTail
            left.addArrangedSubview(s)
        }
        addArrangedSubview(left)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let right {
            let r = NSTextField(labelWithString: right)
            r.font = Draw.mono(11)
            r.textColor = Tok.Color.textMeta
            r.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(NSView())
            addArrangedSubview(r)
        }
    }

    required init(coder: NSCoder) { fatalError() }
}

/// Square cells shaded by value; an empty cell (below 0) is left out, a marked one gets a warn outline.
private final class GridView: NSView {
    private let rows: Int, columns: Int, cell: CGFloat, cells: [Float], marked: Set<Int>
    private static let gap: CGFloat = 2

    init(rows: Int, columns: Int, cell: CGFloat, cells: [Float], marked: Set<Int>) {
        (self.rows, self.columns, self.cell, self.cells, self.marked) = (rows, columns, cell, cells, marked)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(columns) * (cell + Self.gap), height: CGFloat(rows) * (cell + Self.gap))
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, v) in cells.enumerated() where v >= 0 {
            let r = NSRect(x: CGFloat(i % columns) * (cell + Self.gap), y: CGFloat(i / columns) * (cell + Self.gap), width: cell, height: cell)
            PanelFrame.shade(v).setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
        Tok.App.pluginWarn.setStroke()
        for i in marked where i < cells.count {
            let r = NSRect(x: CGFloat(i % columns) * (cell + Self.gap), y: CGFloat(i / columns) * (cell + Self.gap), width: cell, height: cell)
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            p.lineWidth = 1
            p.stroke()
        }
    }
}

/// A fixed-size drawing; a pulsing dot breathes unless the user asked for less motion.
private final class CanvasView: NSView {
    /// A shape's geometry: dot (x, y, r), rect (x, y, w, h), line (x1, y1, x2, y2), label (x, y).
    struct Place: Equatable {
        let kind: Int
        let v: [CGFloat]
    }

    private let size: NSSize
    private let shapes: [PanelShape]
    /// Shape index to where it eases from.
    private var from: [Int: Place] = [:]
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    /// Seconds a keyed shape takes to move (the canvas's `ease-ms`).
    private let ease: CFTimeInterval

    init(size: NSSize, shapes: [PanelShape], from previous: [String: Place], ease: CFTimeInterval) {
        self.size = size
        self.shapes = shapes
        self.ease = ease
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.masksToBounds = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for (i, s) in shapes.enumerated() {
            let (key, place) = Self.geometry(s)
            if let key, let old = previous[key], old.kind == place.kind, old != place { from[i] = old }
        }
        if !from.isEmpty {
            start = CACurrentMediaTime()
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                guard let self else { return t.invalidate() }
                if self.progress >= 1 {
                    self.from = [:]
                    t.invalidate()
                }
                self.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        for case let .dot(x, y, r, shade, warn, true, _) in shapes {
            let l = CAShapeLayer()
            let rr = CGFloat(r)
            l.path = CGPath(ellipseIn: CGRect(x: CGFloat(x) - rr * 2, y: CGFloat(y) - rr * 2, width: rr * 4, height: rr * 4), transform: nil)
            l.fillColor = (warn ? Tok.App.pluginWarn : PanelFrame.shade(shade)).withAlphaComponent(0.25).cgColor
            let a = CABasicAnimation(keyPath: "opacity")
            (a.fromValue, a.toValue, a.duration, a.autoreverses, a.repeatCount) = (0.0, 1.0, 0.8, true, .infinity)
            l.add(a, forKey: "pulse")
            layer?.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { size }

    private var progress: CGFloat { CGFloat(min(1, (CACurrentMediaTime() - start) / ease)) }

    private static func geometry(_ s: PanelShape) -> (String?, Place) {
        let f = { (a: [Float]) in a.map { CGFloat($0) } }
        switch s {
        case let .dot(x, y, r, _, _, _, key): return (key, Place(kind: 0, v: f([x, y, r])))
        case let .rect(x, y, w, h, _, _, _, _, key): return (key, Place(kind: 1, v: f([x, y, w, h])))
        case let .line(x1, y1, x2, y2, _, key): return (key, Place(kind: 2, v: f([x1, y1, x2, y2])))
        case let .label(x, y, _, _, key): return (key, Place(kind: 3, v: f([x, y])))
        }
    }

    /// Shape `i`'s geometry now: part way from where it was while easing (smoothstep), else its own.
    private func place(_ i: Int) -> [CGFloat] {
        let to = Self.geometry(shapes[i]).1.v
        guard let old = from[i] else { return to }
        let t = progress, e = t * t * (3 - 2 * t)
        return zip(old.v, to).map { $0 + ($1 - $0) * e }
    }

    /// Every keyed shape where it is drawn now, so a newer show eases on from mid-way.
    var places: [String: Place] {
        var out: [String: Place] = [:]
        for (i, s) in shapes.enumerated() {
            let (key, p) = Self.geometry(s)
            if let key { out[key] = Place(kind: p.kind, v: place(i)) }
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = { (shade: Float, warn: Bool) in warn ? Tok.App.pluginWarn : PanelFrame.shade(shade) }
        for (i, s) in shapes.enumerated() {
            let v = place(i)
            switch s {
            case let .dot(_, _, _, shade, warn, _, _):
                fill(shade, warn).setFill()
                NSBezierPath(ovalIn: NSRect(x: v[0] - v[2], y: v[1] - v[2], width: v[2] * 2, height: v[2] * 2)).fill()
            case let .rect(_, _, _, _, shade, warn, label, sub, _):
                let r = NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
                fill(shade, warn).setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
                let dark = shade > 0.6 && !warn
                let ctx = NSGraphicsContext.current!.cgContext
                let top = sub == nil ? r.midY - 8 : r.midY - 15
                if let label {
                    let t = Draw.line(label, Draw.ui(11), dark ? Tok.Color.windowBg : Tok.Color.textPrimary)
                    Draw.text(Draw.truncated(t, r.width - 8, Draw.ui(11), Tok.Color.textPrimary), font: Draw.ui(11), x: r.minX + 4,
                              top: top, lineHeight: 16, in: ctx)
                }
                if let sub, r.height >= 30 {
                    let color = dark ? Tok.Color.windowBg.withAlphaComponent(0.7) : PanelFrame.color(.dim)
                    let t = Draw.line(sub, Draw.ui(10), color)
                    Draw.text(Draw.truncated(t, r.width - 8, Draw.ui(10), color), font: Draw.ui(10), x: r.minX + 4,
                              top: top + 15, lineHeight: 14, in: ctx)
                }
            case let .line(_, _, _, _, shade, _):
                fill(shade, false).setStroke()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: v[0], y: v[1]))
                p.line(to: NSPoint(x: v[2], y: v[3]))
                p.lineWidth = 1
                p.stroke()
            case let .label(_, _, text, tone, _):
                let t = Draw.line(text, Draw.ui(11), PanelFrame.color(tone))
                Draw.text(t, font: Draw.ui(11), x: v[0], top: v[1], lineHeight: 16, in: NSGraphicsContext.current!.cgContext)
            }
        }
    }
}

/// The right pane: a plugin's panel with a grip on its left edge that sets its width, 280 to 480 pt.
final class RightPane: NSView {
    private(set) var width: CGFloat
    /// The user let go of the grip at this width.
    var onResized: ((CGFloat) -> Void)?
    private let grip = Grip()
    private static let gripW: CGFloat = 6

    override var isFlipped: Bool { true }

    init(_ content: NSView, width: CGFloat) {
        self.width = min(max(width, PluginPanels.rightWidths.lowerBound), PluginPanels.rightWidths.upperBound)
        super.init(frame: .zero)
        addSubview(content)
        addSubview(grip)
        grip.onDrag = { [weak self] dx in self?.drag(dx) }
        grip.onEnd = { [weak self] in if let self { self.onResized?(self.width) } }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        subviews.first { $0 !== grip }?.frame = bounds
        grip.frame = NSRect(x: 0, y: 0, width: Self.gripW, height: bounds.height)
    }

    /// Dragging left widens the pane.
    private func drag(_ dx: CGFloat) {
        let w = min(max(width - dx, PluginPanels.rightWidths.lowerBound), PluginPanels.rightWidths.upperBound)
        guard w != width else { return }
        width = w
        superview?.needsLayout = true
    }

    /// A hairline divider with a small handle at 40% of its height, as in the mockup.
    private final class Grip: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var lastX: CGFloat?

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            Tok.Color.floatBorder.setFill()
            NSRect(x: 0, y: 0, width: Tok.App.hairline, height: bounds.height).fill()
            Tok.Color.textMeta.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.height * 0.4, width: 4, height: 18), xRadius: 2, yRadius: 2).fill()
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

        override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x }

        override func mouseDragged(with event: NSEvent) {
            guard let x = lastX else { return }
            onDrag?(event.locationInWindow.x - x)
            lastX = event.locationInWindow.x
        }

        override func mouseUp(with event: NSEvent) {
            lastX = nil
            onEnd?()
        }
    }
}
