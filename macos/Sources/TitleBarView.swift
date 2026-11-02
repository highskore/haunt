import AppKit

/// Mockup 03's title bar: grey traffic lights we draw ourselves, and ⌕ + ⚙ plus the sidebar glyph on the right.
/// With the sidebar hidden it is mockup 10's: a progress line on top, no hairline, and a shortcut hint.
final class TitleBarView: NSView {
    enum Accessory {
        case icons
        case kbd
    }

    enum Icon: CaseIterable {
        case search, newTab, settings, sidebar

        var glyph: String {
            switch self {
            case .search: return "⌕"
            case .newTab: return "+"
            case .settings: return "⚙"
            case .sidebar: return ""
            }
        }
    }

    enum Hint {
        case agents, search
    }

    var accessory: Accessory = .icons { didSet { needsDisplay = true } }
    var onIcon: ((Icon) -> Void)?
    var onHint: ((Hint) -> Void)?

    /// Mockup 10's layout, used while the sidebar is hidden.
    var zen = false { didSet { needsDisplay = true } }
    /// Mockup 10's "⌘B agents · ⌘K search", with the configured shortcuts.
    var hints: [(Hint, String)] = [] { didSet { needsDisplay = true } }
    /// The selected agent's progress for the zen line; nil leaves the line out.
    var progress: CGFloat? { didSet { if progress != oldValue { needsDisplay = true } } }

    /// The zen layout adds the progress line above the title bar.
    static func height(zen: Bool) -> CGFloat { Tok.Size.titlebarH + (zen ? Tok.Size.zenBar : 0) }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Where the title row starts and the height its contents centre in: the hairline is the bar's last
    /// point, and zen drops it (mockup 10's `border: none`).
    private var rowTop: CGFloat { zen ? Tok.Size.zenBar : 0 }
    private var rowH: CGFloat { zen ? Tok.Size.titlebarH : Tok.Size.titlebarH - 1 }
    private var lightsY: CGFloat { rowTop + (rowH - Tok.Size.lightsD) / 2 }

    private func lightRect(_ i: Int) -> NSRect {
        let d = Tok.Size.lightsD
        return NSRect(x: Tok.Size.titlebarPadx + CGFloat(i) * (d + Tok.Size.lightsGap), y: lightsY, width: d, height: d)
    }

    /// No mockup has this glyph; it is drawn as a window outline with its left column split off,
    /// about the ⚙ glyph's size at the icons' font size.
    private static let sidebarGlyph = NSSize(width: 12, height: 10)

    private func iconLayout() -> [(Icon, CTLine?, NSRect)] {
        let font = Draw.ui(Tok.Size.titlebarIconsFont)
        let lh = Tok.Size.titlebarIconsFont * Tok.Font.baseLine
        let top = rowTop + (rowH - lh) / 2
        var x = bounds.width - Tok.Size.titlebarPadx
        var out: [(Icon, CTLine?, NSRect)] = []
        for icon in Icon.allCases.reversed() {
            let line = icon == .sidebar ? nil : Draw.line(icon.glyph, font, Tok.Color.textLabel)
            let w = line.map(Draw.width) ?? Self.sidebarGlyph.width
            x -= w
            out.append((icon, line, NSRect(x: x, y: top, width: w, height: lh)))
            x -= Tok.Size.titlebarIconsGap
        }
        return out.reversed()
    }

    private var hintFont: NSFont { Draw.ui(Tok.Size.zenHintFont) }

    /// Each hint's line and box, right-aligned like mockup 10's `.muted` span, joined by " · ".
    private func hintLayout() -> (parts: [(Hint, CTLine, NSRect)], sep: CTLine, sepX: [CGFloat]) {
        let lh = Tok.Size.zenHintFont * Tok.Font.baseLine
        let top = rowTop + (rowH - lh) / 2
        let sep = Draw.line(" · ", hintFont, Tok.Color.textLabel)
        var x = bounds.width - Tok.Size.titlebarPadx
        var parts: [(Hint, CTLine, NSRect)] = []
        var sepX: [CGFloat] = []
        for (i, (hint, text)) in hints.enumerated().reversed() {
            let line = Draw.line(text, hintFont, Tok.Color.textLabel)
            x -= Draw.width(line)
            parts.append((hint, line, NSRect(x: x, y: top, width: Draw.width(line), height: lh)))
            if i > 0 {
                x -= Draw.width(sep)
                sepX.append(x)
            }
        }
        return (parts.reversed(), sep, sepX)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(bounds, Tok.Color.windowBg)
        if zen {
            if let p = progress {
                Draw.fill(NSRect(x: 0, y: 0, width: bounds.width, height: Tok.Size.zenBar), Tok.Color.zenTrack)
                let w = (bounds.width * min(max(p, 0), 1)).rounded()
                Draw.fill(NSRect(x: 0, y: 0, width: w, height: Tok.Size.zenBar), Tok.Color.barFill)
            }
        } else {
            Draw.fill(NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), Tok.Color.hairline)
        }

        Tok.Color.lights.setFill()
        for i in 0..<3 { NSBezierPath(ovalIn: lightRect(i)).fill() }

        if zen {
            let (parts, sep, sepX) = hintLayout()
            for (_, line, r) in parts {
                Draw.text(line, font: hintFont, x: r.minX, top: r.minY, lineHeight: r.height, in: ctx)
            }
            if let r = parts.first?.2 {
                for x in sepX { Draw.text(sep, font: hintFont, x: x, top: r.minY, lineHeight: r.height, in: ctx) }
            }
            return
        }
        switch accessory {
        case .icons:
            let font = Draw.ui(Tok.Size.titlebarIconsFont)
            for (_, line, r) in iconLayout() {
                if let line {
                    Draw.text(line, font: font, x: r.minX, top: r.minY, lineHeight: r.height, in: ctx)
                } else {
                    drawSidebarGlyph(centeredIn: r)
                }
            }
        case .kbd:
            drawKbd("⌘K", in: ctx)
        }
    }

    private func drawSidebarGlyph(centeredIn r: NSRect) {
        let s = Self.sidebarGlyph
        let box = NSRect(x: r.minX, y: (r.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        Tok.Color.textLabel.setStroke()
        outline.stroke()
        Draw.fill(NSRect(x: box.minX + 4, y: box.minY, width: 1, height: box.height), Tok.Color.textLabel)
    }

    private func drawKbd(_ label: String, in ctx: CGContext) {
        let font = Draw.ui(Tok.Size.kbdFont)
        let line = Draw.line(label, font, Tok.Color.textSub)
        let pad = Tok.Size.kbdPad[1]
        let w = Draw.width(line) + pad * 2 + 2
        let h = Tok.Size.kbdLine + 2
        let box = NSRect(x: bounds.width - Tok.Size.titlebarPadx - w, y: rowTop + (rowH - h) / 2, width: w, height: h)
        let r = Tok.Size.kbdRadius
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        border.lineWidth = 1
        Tok.Color.kbdBorder.setStroke()
        border.stroke()
        Draw.text(line, font: font, x: box.minX + 1 + pad, top: box.minY + 1, lineHeight: Tok.Size.kbdLine, in: ctx)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        let actions: [Selector] = [#selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:)),
                                   #selector(NSWindow.performZoom(_:))]
        for i in 0..<3 where lightRect(i).insetBy(dx: -2, dy: -2).contains(p) {
            NSApp.sendAction(actions[i], to: window, from: self)
            return
        }
        if zen, let hit = hintLayout().parts.first(where: { $0.2.insetBy(dx: -4, dy: -4).contains(p) }) {
            onHint?(hit.0)
            return
        }
        if !zen, accessory == .icons, let hit = iconLayout().first(where: { $0.2.insetBy(dx: -4, dy: -4).contains(p) }) {
            onIcon?(hit.0)
            return
        }
        if event.clickCount == 2 {
            window.performZoom(nil)
        } else {
            window.performDrag(with: event)
        }
    }
}
