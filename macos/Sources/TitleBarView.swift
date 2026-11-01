import AppKit

/// Mockup 03's title bar: grey traffic lights we draw ourselves, and ⌕ + ⚙ on the right.
final class TitleBarView: NSView {
    enum Accessory {
        case icons
        case kbd
    }

    enum Icon: CaseIterable {
        case search, newTab, settings

        var glyph: String {
            switch self {
            case .search: return "⌕"
            case .newTab: return "+"
            case .settings: return "⚙"
            }
        }
    }

    var accessory: Accessory = .icons { didSet { needsDisplay = true } }
    var onIcon: ((Icon) -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var height: CGFloat { Tok.Size.titlebarH }
    private var lightsY: CGFloat { ((height - 1) - Tok.Size.lightsD) / 2 }

    private func lightRect(_ i: Int) -> NSRect {
        let d = Tok.Size.lightsD
        return NSRect(x: Tok.Size.titlebarPadx + CGFloat(i) * (d + Tok.Size.lightsGap), y: lightsY, width: d, height: d)
    }

    private func iconLayout() -> [(Icon, CTLine, NSRect)] {
        let font = Draw.ui(Tok.Size.titlebarIconsFont)
        let lh = Tok.Size.titlebarIconsFont * Tok.Font.baseLine
        var x = bounds.width - Tok.Size.titlebarPadx
        var out: [(Icon, CTLine, NSRect)] = []
        for icon in Icon.allCases.reversed() {
            let line = Draw.line(icon.glyph, font, Tok.Color.textLabel)
            let w = Draw.width(line)
            x -= w
            out.append((icon, line, NSRect(x: x, y: ((height - 1) - lh) / 2, width: w, height: lh)))
            x -= Tok.Size.titlebarIconsGap
        }
        return out.reversed()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(bounds, Tok.Color.windowBg)
        Draw.fill(NSRect(x: 0, y: height - 1, width: bounds.width, height: 1), Tok.Color.hairline)

        Tok.Color.lights.setFill()
        for i in 0..<3 { NSBezierPath(ovalIn: lightRect(i)).fill() }

        switch accessory {
        case .icons:
            let font = Draw.ui(Tok.Size.titlebarIconsFont)
            for (_, line, r) in iconLayout() {
                Draw.text(line, font: font, x: r.minX, top: r.minY, lineHeight: r.height, in: ctx)
            }
        case .kbd:
            drawKbd("⌘K", in: ctx)
        }
    }

    private func drawKbd(_ label: String, in ctx: CGContext) {
        let font = Draw.ui(Tok.Size.kbdFont)
        let line = Draw.line(label, font, Tok.Color.textSub)
        let pad = Tok.Size.kbdPad[1]
        let w = Draw.width(line) + pad * 2 + 2
        let h = Tok.Size.kbdLine + 2
        let box = NSRect(x: bounds.width - Tok.Size.titlebarPadx - w, y: ((height - 1) - h) / 2, width: w, height: h)
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
        if accessory == .icons, let hit = iconLayout().first(where: { $0.2.insetBy(dx: -4, dy: -4).contains(p) }) {
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
