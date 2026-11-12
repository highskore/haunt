import AppKit

/// Where plugin panels go: sheets and cards hang off the main window, a right pane sits beside the terminal.
protocol PanelHost: AnyObject {
    var window: NSWindow? { get }
    func setRightPane(_ view: NSView?)
}

/// Shows the panels plugins describe (`HostRequest.showPanel`), drawn natively from the core's checked
/// node tree. A button press or the user closing one goes back through `onAction`.
final class PluginPanels {
    static let rightWidth: CGFloat = 320
    private static let cardWidth: CGFloat = 300
    private static let sheetWidth: CGFloat = 420
    private static let windowWidth: CGFloat = 480
    private static let inset: CGFloat = 16

    weak var host: PanelHost?
    /// (plugin id, panel id, action); an empty action means the user closed it.
    var onAction: ((String, String, String) -> Void)?

    private struct Key: Hashable { let plugin: String, id: String }
    private final class Shown {
        let placement: PanelPlacement
        let window: NSWindow?
        let frame: PanelFrame
        init(placement: PanelPlacement, window: NSWindow?, frame: PanelFrame) {
            self.placement = placement
            self.window = window
            self.frame = frame
        }
    }
    private var shown: [Key: Shown] = [:]
    private var closeObservers: [Key: NSObjectProtocol] = [:]

    func show(pluginId: String, panel: Panel) {
        let key = Key(plugin: pluginId, id: panel.id)
        if let s = shown[key], s.placement == panel.placement {
            s.frame.update(panel, pluginId: pluginId)
            s.window?.title = panel.title
            if let w = s.window { fit(w, s.placement) }
            return
        }
        close(key, byUser: false)
        let frame = PanelFrame(chrome: panel.placement == .right || panel.placement == .card) { [weak self] action in
            guard let self else { return }
            if action.isEmpty { self.close(key, byUser: true) } else { self.onAction?(pluginId, panel.id, action) }
        }
        frame.update(panel, pluginId: pluginId)
        var window: NSWindow?
        switch panel.placement {
        case .right:
            host?.setRightPane(frame)
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
                w.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX - w.frame.width - Self.inset, y: top))
            }
            w.orderFront(nil)
            window = w
        case .window:
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 300),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.title = panel.title
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Tok.Color.windowBg
            w.contentView = frame
            fit(w, .window)
            w.center()
            closeObservers[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) {
                [weak self] _ in self?.close(key, byUser: true)
            }
            w.makeKeyAndOrderFront(nil)
            window = w
        }
        shown[key] = Shown(placement: panel.placement, window: window, frame: frame)
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
        case .right: host?.setRightPane(nil)
        case .sheet: if let w = s.window { w.sheetParent?.endSheet(w) }
        case .card: if let w = s.window { w.parent?.removeChildWindow(w); w.orderOut(nil) }
        case .window: s.window?.close()
        }
        if byUser { onAction?(key.plugin, key.id, "") }
    }

    /// Sizes a window to its content's fitting height, within the screen.
    private func fit(_ w: NSWindow, _ placement: PanelPlacement) {
        guard let v = w.contentView else { return }
        let width: CGFloat = placement == .card ? Self.cardWidth : placement == .sheet ? Self.sheetWidth : max(w.frame.width, Self.windowWidth)
        v.frame.size.width = width
        v.layoutSubtreeIfNeeded()
        let maxH = (w.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let h = min(max(v.fittingSize.height, 60), maxH * 0.8)
        w.setContentSize(NSSize(width: width, height: h))
    }
}

/// Esc closes a sheet or card the way the user's close button would.
private final class PanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A panel's content: an optional header with its title and a close button, then the node tree.
final class PanelFrame: NSView {
    private let chrome: Bool
    private let send: (String) -> Void
    private let title = NSTextField(labelWithString: "")
    private let body = NSStackView()
    private let scroll = NSScrollView()

    override var isFlipped: Bool { true }

    init(chrome: Bool, send: @escaping (String) -> Void) {
        self.chrome = chrome
        self.send = send
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (chrome ? Tok.Color.cardBg : Tok.Color.windowBg).cgColor
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        body.translatesAutoresizingMaskIntoConstraints = false
        title.font = Draw.ui(13, .semibold)
        title.textColor = Tok.Color.textPrimary
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        var constraints = [
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ]
        if chrome {
            let close = NSButton(title: "×", target: self, action: #selector(closePressed))
            close.isBordered = false
            close.font = Draw.ui(15)
            close.contentTintColor = Tok.Color.textMeta
            close.translatesAutoresizingMaskIntoConstraints = false
            close.setAccessibilityLabel("Close")
            addSubview(title)
            addSubview(close)
            constraints += [
                title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
                close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            ]
        } else {
            constraints.append(body.topAnchor.constraint(equalTo: topAnchor, constant: 8))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closePressed() { send("") }

    /// Rebuilds the tree; the core already checked parents, depth and caps.
    func update(_ panel: Panel, pluginId: String) {
        title.stringValue = panel.title
        setAccessibilityLabel("\(panel.title), from \(pluginId)")
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
        case let .button(label, action, primary):
            let b = ActionButton(title: label, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.onPress = { [weak self] in self?.send(action) }
            if primary { b.keyEquivalent = "\r" }
            return b
        case .divider:
            let b = NSBox()
            b.boxType = .separator
            return b
        case let .grid(rows, columns, cell, cells, marked):
            return GridView(rows: Int(rows), columns: Int(columns), cell: CGFloat(cell), cells: cells, marked: Set(marked.map(Int.init)))
        case let .canvas(width, height, shapes):
            return CanvasView(size: NSSize(width: CGFloat(width), height: CGFloat(height)), shapes: shapes)
        }
    }

    static func color(_ t: PanelTone) -> NSColor {
        switch t {
        case .text: return Tok.Color.textPrimary
        case .dim: return Tok.Color.textSub
        case .faint: return Tok.Color.textMeta
        case .accent: return Tok.Color.needs
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

/// Square cells shaded by value; an empty cell (below 0) is left out, a marked one gets an accent outline.
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
        Tok.Color.needs.setStroke()
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
    private let size: NSSize
    private let shapes: [PanelShape]

    init(size: NSSize, shapes: [PanelShape]) {
        self.size = size
        self.shapes = shapes
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.masksToBounds = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for case let .dot(x, y, r, shade, accent, true) in shapes {
            let l = CAShapeLayer()
            let rr = CGFloat(r)
            l.path = CGPath(ellipseIn: CGRect(x: CGFloat(x) - rr * 2, y: CGFloat(y) - rr * 2, width: rr * 4, height: rr * 4), transform: nil)
            l.fillColor = (accent ? Tok.Color.needs : PanelFrame.shade(shade)).withAlphaComponent(0.25).cgColor
            let a = CABasicAnimation(keyPath: "opacity")
            (a.fromValue, a.toValue, a.duration, a.autoreverses, a.repeatCount) = (0.0, 1.0, 0.8, true, .infinity)
            l.add(a, forKey: "pulse")
            layer?.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { size }

    override func draw(_ dirtyRect: NSRect) {
        let fill = { (shade: Float, accent: Bool) in accent ? Tok.Color.needs : PanelFrame.shade(shade) }
        for s in shapes {
            switch s {
            case let .dot(x, y, r, shade, accent, _):
                fill(shade, accent).setFill()
                let rr = CGFloat(r)
                NSBezierPath(ovalIn: NSRect(x: CGFloat(x) - rr, y: CGFloat(y) - rr, width: rr * 2, height: rr * 2)).fill()
            case let .rect(x, y, w, h, shade, accent, label):
                let r = NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
                fill(shade, accent).setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
                if let label {
                    let t = Draw.line(label, Draw.ui(11), shade > 0.6 && !accent ? Tok.Color.windowBg : Tok.Color.textPrimary)
                    Draw.text(Draw.truncated(t, r.width - 8, Draw.ui(11), Tok.Color.textPrimary), font: Draw.ui(11), x: r.minX + 4,
                              top: r.midY - 8, lineHeight: 16, in: NSGraphicsContext.current!.cgContext)
                }
            case let .line(x1, y1, x2, y2, shade):
                fill(shade, false).setStroke()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: CGFloat(x1), y: CGFloat(y1)))
                p.line(to: NSPoint(x: CGFloat(x2), y: CGFloat(y2)))
                p.lineWidth = 1
                p.stroke()
            case let .label(x, y, text, tone):
                let t = Draw.line(text, Draw.ui(11), PanelFrame.color(tone))
                Draw.text(t, font: Draw.ui(11), x: CGFloat(x), top: CGFloat(y), lineHeight: 16, in: NSGraphicsContext.current!.cgContext)
            }
        }
    }
}
