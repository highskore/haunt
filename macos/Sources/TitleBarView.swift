import AppKit

/// Mockup 03's title bar: grey traffic lights we draw ourselves, and the `[layout] titlebar_buttons` icons on the right.
/// With the sidebar hidden it is mockup 10's: a progress line on top, no hairline, and a shortcut hint.
final class TitleBarView: NSView, NSViewToolTipOwner {
    enum Accessory {
        case icons
        case kbd
        /// Nothing on the right (review version 01).
        case empty
    }

    typealias Icon = TitlebarButton

    enum Hint {
        case agents, search
    }

    var accessory: Accessory = .icons { didSet { needsDisplay = true; updateToolTips() } }
    /// The `.kbd` accessory's shortcut.
    var kbdLabel = "⌘K" { didSet { needsDisplay = true } }
    var onIcon: ((Icon) -> Void)?
    /// A centred breadcrumb (review versions 01 and 09); the last part is the current place.
    var crumb: [String] = [] { didSet { needsDisplay = true } }
    var onCrumb: (() -> Void)?
    /// The icons, left to right.
    var buttons = TitlebarButton.defaults { didSet { if buttons != oldValue { needsDisplay = true; updateToolTips() } } }
    /// Each icon's shortcut from `[keys]`, shown in its tooltip.
    var shortcuts: [Icon: String] = [:] { didSet { if shortcuts != oldValue { updateToolTips() } } }
    var onHint: ((Hint) -> Void)?

    /// Mockup 10's layout, used while the sidebar is hidden.
    var zen = false { didSet { needsDisplay = true; updateToolTips() } }
    /// Mockup 10's "⌘B agents · ⌘K search", with the configured shortcuts.
    var hints: [(Hint, String)] = [] { didSet { needsDisplay = true } }
    /// `[layout] title_format`, and the selected tab it names; a review crumb takes its place.
    var titleFormat = "" { didSet { if titleFormat != oldValue { needsDisplay = true } } }
    var tab: (name: String, meta: String)? { didSet { if tab?.name != oldValue?.name || tab?.meta != oldValue?.meta { needsDisplay = true } } }
    /// The selected agent's progress for the zen line; nil leaves the line out.
    var progress: CGFloat? { didSet { if progress != oldValue { needsDisplay = true } } }
    /// A plugin's line (`HostRequest.titleSet`), dim mono to the left of the icons; plain text from the core.
    var pluginLine: String? { didSet { if pluginLine != oldValue { needsDisplay = true } } }

    /// The zen layout adds the progress line above the title bar.
    static func height(zen: Bool) -> CGFloat { Tok.Size.titlebarH + (zen ? Tok.Size.zenBar : menuH) }

    /// `[effects] titlebar.menu`'s row under the caption: the title's type with 2 pt above and 5 below.
    static var menuH: CGFloat { Theme.current.effects.titlebarMenu ? Tok.App.titleFont * Tok.Font.baseLine + 7 : 0 }
    private var caption: Bool { Theme.current.effects.titlebarStyle == "caption" && !zen }
    private var boxes: Bool { Theme.current.effects.lightsShape == "boxes" }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Where the title row starts and the height its contents centre in: the hairline is the bar's last
    /// point, and zen drops it (mockup 10's `border: none`).
    private var rowTop: CGFloat { zen ? Tok.Size.zenBar : 0 }
    private var rowH: CGFloat { zen ? Tok.Size.titlebarH : Tok.Size.titlebarH - Tok.App.hairline }
    private var lightsY: CGFloat { rowTop + (rowH - Tok.Size.lightsD) / 2 }

    private func lightRect(_ i: Int) -> NSRect {
        if boxes {
            // Window buttons, right-aligned: minimise, maximise, then close after a 2 pt gap.
            let w: CGFloat = 16, h: CGFloat = 14, right = bounds.width - 2
            let x = [right - w, right - 2 - 3 * w, right - 2 - 2 * w][i]
            return NSRect(x: x, y: rowTop + (Tok.Size.titlebarH - h) / 2, width: w, height: h)
        }
        let d = Tok.Size.lightsD
        return NSRect(x: Tok.Size.titlebarPadx + CGFloat(i) * (d + Tok.Size.lightsGap), y: lightsY, width: d, height: d)
    }

    // MARK: Traffic-light hover

    /// Grey at rest (the mockups); hovering the group shows macOS's own colours and glyphs.
    /// HAUNT_LIGHTS=hover or hover-option pins that state for a launch capture.
    #if HAUNT_FIXTURES
    private static let pinned = ProcessInfo.processInfo.environment["HAUNT_LIGHTS"]
    #else
    private static let pinned: String? = nil
    #endif
    private var lightsHover = TitleBarView.pinned?.hasPrefix("hover") == true { didSet { needsDisplay = true } }
    private var optionDown = TitleBarView.pinned == "hover-option" { didSet { if optionDown != oldValue { needsDisplay = true } } }
    private var lightsArea: NSTrackingArea?
    private var flagsMonitor: Any?

    private var lightsGroup: NSRect {
        lightRect(0).union(lightRect(1)).union(lightRect(2)).insetBy(dx: -Tok.App.lightsSlop, dy: -Tok.App.lightsSlop)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = lightsArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: lightsGroup, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(a)
        lightsArea = a
    }

    override func mouseEntered(with event: NSEvent) {
        lightsHover = true
        optionDown = event.modifierFlags.contains(.option)
        flagsMonitor = flagsMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.optionDown = e.modifierFlags.contains(.option)
            return e
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard Self.pinned == nil else { return }
        lightsHover = false
        optionDown = false
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
    }

    private func drawLights() {
        if boxes { return drawBoxes() }
        for i in 0..<3 {
            let r = lightRect(i)
            // Around the light, never inside it: a theme can frame it but never hide or recolour it.
            if let ctx = NSGraphicsContext.current?.cgContext {
                Layers.draw("lights", r, within: bounds, exclude: r, state: Layers.state(self, hover: lightsHover), index: i, in: ctx)
            }
            if Theme.current.effects.lightsShape == "diamond" && !lightsHover {
                // An outlined diamond on the window's colour, so no layer shows through; the close light's carries an ×.
                // Drawn by Haunt: layers never paint inside a light.
                Tok.App.ornament.setStroke()
                Draw.diamond(center: NSPoint(x: r.midX, y: r.midY), size: r.width * 0.61, stroke: 1, fill: Tok.Color.windowBg.withAlphaComponent(1))
                if i == 0 {
                    let k = r.width / 6, p = NSBezierPath()
                    p.move(to: NSPoint(x: r.midX - k, y: r.midY - k)); p.line(to: NSPoint(x: r.midX + k, y: r.midY + k))
                    p.move(to: NSPoint(x: r.midX + k, y: r.midY - k)); p.line(to: NSPoint(x: r.midX - k, y: r.midY + k))
                    p.lineWidth = 1
                    p.stroke()
                }
                continue
            }
            if Theme.current.effects.lightsShape == "squares" && !lightsHover {
                // Squares in the window's colour edged in the lights'; the close light's filled with it.
                let hl = Tok.App.hairline, sq = NSBezierPath(rect: r.insetBy(dx: hl / 2, dy: hl / 2))
                Draw.fill(r, i == 0 ? Tok.Color.lights : Tok.Color.windowBg)
                Tok.Color.lights.setStroke()
                sq.lineWidth = hl
                sq.stroke()
                continue
            }
            (lightsHover || Theme.current.effects.titlebarLights == "color" ? Tok.Lights.fill[i] : Tok.Color.lights).setFill()
            NSBezierPath(ovalIn: r).fill()
            guard lightsHover else { continue }
            Tok.Lights.glyph[i].set()
            let c = NSPoint(x: r.midX, y: r.midY), k = r.width * Tok.Lights.glyphHalf, bar = k * Tok.Lights.barScale
            let p = NSBezierPath()
            p.lineWidth = Tok.Lights.glyphStroke
            p.lineCapStyle = .round
            switch i {
            case 0:
                p.move(to: NSPoint(x: c.x - k, y: c.y - k)); p.line(to: NSPoint(x: c.x + k, y: c.y + k))
                p.move(to: NSPoint(x: c.x - k, y: c.y + k)); p.line(to: NSPoint(x: c.x + k, y: c.y - k))
                p.stroke()
            case 1:
                p.move(to: NSPoint(x: c.x - bar, y: c.y)); p.line(to: NSPoint(x: c.x + bar, y: c.y))
                p.stroke()
            default:
                if optionDown {
                    p.move(to: NSPoint(x: c.x - bar, y: c.y)); p.line(to: NSPoint(x: c.x + bar, y: c.y))
                    p.move(to: NSPoint(x: c.x, y: c.y - bar)); p.line(to: NSPoint(x: c.x, y: c.y + bar))
                    p.stroke()
                } else {
                    // Full-screen arrows: two corner triangles pointing out along the diagonal (flipped view, y down).
                    let a = r.width * Tok.Lights.arrowHalf, g = r.width * Tok.Lights.arrowGap
                    let tl = NSBezierPath()
                    tl.move(to: NSPoint(x: c.x - a, y: c.y - a)); tl.line(to: NSPoint(x: c.x + a - g * 2, y: c.y - a))
                    tl.line(to: NSPoint(x: c.x - a, y: c.y + a - g * 2)); tl.close(); tl.fill()
                    let br = NSBezierPath()
                    br.move(to: NSPoint(x: c.x + a, y: c.y + a)); br.line(to: NSPoint(x: c.x - a + g * 2, y: c.y + a))
                    br.line(to: NSPoint(x: c.x + a, y: c.y - a + g * 2)); br.close(); br.fill()
                }
            }
        }
    }

    /// `lights.shape = "boxes"`: raised window buttons with pixel glyphs.
    private func drawBoxes() {
        let glyphs: [[String]] = [
            ["kk....kk", ".kk..kk.", "..kkkk..", "...kk...", "..kkkk..", ".kk..kk.", "kk....kk"],
            [".......", ".......", ".......", ".......", ".......", ".kkkkkk", ".kkkkkk"],
            ["kkkkkkkkk", "kkkkkkkkk", "k.......k", "k.......k", "k.......k", "k.......k", "k.......k", "k.......k", "kkkkkkkkk"],
        ]
        for i in 0..<3 {
            let r = lightRect(i)
            Draw.fill(r, Tok.Color.windowBg)
            Draw.bevel(r, "button")
            let g = glyphs[i], w = CGFloat(g[0].count), h = CGFloat(g.count)
            Draw.pixels(g, ["k": Tok.Color.textPrimary], at: NSPoint(x: (r.midX - w / 2).rounded(.down), y: (r.midY - h / 2).rounded(.down)))
        }
    }

    /// `titlebar.style = "caption"`: the gradient bar, the ghost and a left-aligned title; then the menu row.
    private func drawCaption(_ ctx: CGContext) {
        let bar = NSRect(x: 0, y: rowTop, width: bounds.width, height: Tok.Size.titlebarH)
        let stops = Theme.current.app.titlebarFill.compactMap { NSColor(themeHex: $0) }
        if stops.count >= 2, let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.cgColor) as CFArray,
                                               locations: stops.indices.map { CGFloat($0) / CGFloat(stops.count - 1) }) {
            ctx.saveGState()
            ctx.clip(to: bar)
            ctx.drawLinearGradient(g, start: CGPoint(x: bar.minX, y: 0), end: CGPoint(x: bar.maxX, y: 0), options: [])
            ctx.restoreGState()
        } else if let c = stops.first {
            Draw.fill(bar, c)
        }
        var x = Tok.Size.titlebarPadx
        if Theme.current.effects.titlebarIcon {
            Draw.pixels(Draw.ghostPixels, ["k": .black, "w": .white], at: NSPoint(x: x, y: bar.minY + ((bar.height - 16) / 2).rounded()))
            x += 16 + 4
        }
        if let tab, !titleFormat.isEmpty {
            let size = Tok.App.titleFont, font = Draw.ui(size, .bold), lh = size * Tok.Font.baseLine
            let text = TitleFormat.parts(titleFormat, tab: tab.name, meta: tab.meta).map(\.text).joined()
            // The selection's ink: the caption shares its fill.
            let ink = Theme.current.app.rowSelectInk
            let line = Draw.truncated(Draw.line(text, font, ink), lightRect(1).minX - 4 - x, font, ink)
            Draw.text(line, font: font, x: x, top: bar.minY + (bar.height - lh) / 2, lineHeight: lh, in: ctx)
        }
        for (_, line, r) in menuLayout() {
            Draw.text(line, font: Draw.ui(Tok.App.titleFont), x: r.minX + 7, top: r.minY + 2, lineHeight: Tok.App.titleFont * Tok.Font.baseLine, in: ctx)
        }
    }

    /// The app's own menus as a row under the caption, their first letters underlined; each opens its menu.
    private func menuLayout() -> [(NSMenu, CTLine, NSRect)] {
        guard Theme.current.effects.titlebarMenu, !zen, let items = NSApp.mainMenu?.items else { return [] }
        let font = Draw.ui(Tok.App.titleFont)
        var x: CGFloat = 0
        return items.compactMap { item -> (NSMenu, CTLine, NSRect)? in
            guard let menu = item.submenu else { return nil }
            let title = menu.title.isEmpty ? "Haunt" : menu.title
            let s = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: Tok.Color.textPrimary])
            s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 1))
            let line = CTLineCreateWithAttributedString(s)
            let r = NSRect(x: x, y: rowTop + Tok.Size.titlebarH + 1, width: Draw.width(line) + 14, height: Self.menuH - 3)
            x = r.maxX
            return (menu, line, r)
        }
    }

    private func iconLayout() -> [(Icon, CTLine?, NSRect)] {
        let font = Draw.ui(Tok.Size.titlebarIconsFont)
        let lh = Tok.Size.titlebarIconsFont * Tok.Font.baseLine
        let top = rowTop + (rowH - lh) / 2
        var x = bounds.width - Tok.Size.titlebarPadx
        var out: [(Icon, CTLine?, NSRect)] = []
        for icon in buttons.reversed() {
            let line = icon == .sidebar ? nil : Draw.line(icon.glyph, font, Tok.Color.textLabel)
            let w = line.map(Draw.width) ?? Tok.App.sidebarGlyph.width
            x -= w
            out.append((icon, line, NSRect(x: x, y: top, width: w, height: lh)))
            x -= Tok.Size.titlebarIconsGap
        }
        return out.reversed()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolTips()
    }

    private func updateToolTips() {
        removeAllToolTips()
        guard !zen, accessory == .icons else { return }
        for (_, _, r) in iconLayout() { addToolTip(r.insetBy(dx: -Tok.App.hitSlop, dy: -Tok.App.hitSlop), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let icon = iconLayout().first(where: { $0.2.insetBy(dx: -Tok.App.hitSlop, dy: -Tok.App.hitSlop).contains(point) })?.0 else { return "" }
        return shortcuts[icon].map { "\(icon.title) (\($0))" } ?? icon.title
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
        Draw.fill(bounds, Theme.current.app.titlebarBg)
        if zen {
            if let p = progress {
                Draw.fill(NSRect(x: 0, y: 0, width: bounds.width, height: Tok.Size.zenBar), Tok.Color.zenTrack)
                let w = (bounds.width * min(max(p, 0), 1)).rounded()
                Draw.fill(NSRect(x: 0, y: 0, width: w, height: Tok.Size.zenBar), Tok.Color.barFill)
            }
        } else if Theme.current.effects.titlebarRule {
            Draw.fill(NSRect(x: 0, y: bounds.height - Tok.App.hairline, width: bounds.width, height: Tok.App.hairline), Tok.Color.hairline)
        }
        Layers.draw("titlebar", bounds, text: titleRuns(), state: Layers.state(self), in: ctx)

        if caption { drawCaption(ctx) }
        drawLights()

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
            drawPluginLine(rightOf: iconLayout().first?.2.minX ?? bounds.width - Tok.Size.titlebarPadx, in: ctx)
        case .kbd:
            drawKbd(kbdLabel, in: ctx)
        case .empty:
            break
        }
        if caption { return }
        if let (line, font, r) = rightLayout() {
            Draw.text(line, font: font, x: r.minX, top: r.minY, lineHeight: r.height, in: ctx)
        }
        if let (line, r) = crumbLayout() {
            Draw.text(line, font: Draw.ui(Tok.Size.crumbFont), x: r.minX, top: r.minY, lineHeight: r.height, in: ctx)
        } else if Draw.display(Tok.App.titleFont) != nil {
            drawDisplayTitle(ctx)
        } else if let (line, r) = titleLayout() {
            Draw.text(line, font: Draw.ui(Tok.App.titleFont, .semibold), x: r.minX, top: r.minY, lineHeight: r.height, in: ctx)
        }
    }

    /// The theme's `[strings] titlebar.right`, where the icons would sit.
    private func rightLayout() -> (CTLine, NSFont, NSRect)? {
        guard !zen, crumb.isEmpty, buttons.isEmpty || accessory != .icons,
              let text = Theme.current.string("titlebar.right") else { return nil }
        let app = Theme.current.app, font = Draw.ui(app.titlebarRightFont, .light)
        let line = Draw.line(text, font, Tok.Color.textSub, kern: app.titlebarRightFont * app.titlebarRightTracking)
        let w = Draw.width(line), lh = app.titlebarRightFont * Tok.Font.baseLine
        guard w <= bounds.width - 2 * Tok.Size.titlebarPadx else { return nil }
        return (line, font, NSRect(x: bounds.width - Tok.Size.titlebarPadx - w, y: rowTop + (rowH - lh) / 2, width: w, height: lh))
    }

    /// With a display face: the tab part in it, chrome-filled, the rest small and tracked, all centred.
    private func drawDisplayTitle(_ ctx: CGContext) {
        guard crumb.isEmpty, !zen, !titleFormat.isEmpty, let tab, let big = Draw.display(Tok.App.titleFont) else { return }
        let app = Theme.current.app
        let smallSize = app.titleMetaFont > 0 ? app.titleMetaFont : Tok.App.titleFont
        let small = Draw.ui(smallSize, .light)
        let parts = TitleFormat.parts(titleFormat, tab: tab.name, meta: tab.meta).map { text, isTab in
            isTab ? (Draw.line(text, big, Tok.App.titleFg), big, true)
                : (Draw.line(text, small, Tok.App.titleMeta, kern: smallSize * app.titleMetaTracking), small, false)
        }
        let total = parts.reduce(0) { $0 + Draw.width($1.0) }
        var x = ((bounds.width - total) / 2).rounded()
        let lh = Tok.App.titleFont * Tok.Font.baseLine, top = rowTop + (rowH - lh) / 2
        for (line, font, isTab) in parts {
            if isTab {
                Draw.chromeText(line, font: font, x: x, top: top, lineHeight: lh, in: ctx)
            } else {
                Draw.text(line, font: font, x: x, top: top + (lh - smallSize * Tok.Font.baseLine) / 2,
                          lineHeight: smallSize * Tok.Font.baseLine, in: ctx)
            }
            x += Draw.width(line)
        }
    }

    /// The bar's text, in the colours it's drawn in.
    private func titleRuns() -> [Layers.Run] {
        // Diamond lights are drawn in the ornament's colour over the bar's layers, so they're held to it like text.
        let lights = Theme.current.effects.lightsShape == "diamond" && !boxes ? (0..<3).map { Layers.Run(rect: lightRect($0), ink: Tok.App.ornament) } : []
        return lights + titleTextRuns()
    }

    private func titleTextRuns() -> [Layers.Run] {
        func runs(_ r: NSRect, _ inks: [NSColor]) -> [Layers.Run] { inks.map { Layers.Run(rect: r, ink: $0) } }
        if zen { return hintLayout().parts.flatMap { runs($0.2, [Tok.Color.textLabel]) } }
        if caption {
            // The caption's title, in the selection's ink, and the menu row under it.
            let x = Tok.Size.titlebarPadx, title = NSRect(x: x, y: rowTop, width: max(lightRect(1).minX - 4 - x, 0), height: Tok.Size.titlebarH)
            return runs(title, [Theme.current.app.rowSelectInk]) + menuLayout().flatMap { runs($0.2, [Tok.Color.textPrimary]) }
        }
        if let (_, r) = crumbLayout() { return runs(r, [Tok.Color.textLabel, Tok.Color.textPrimary, Tok.Color.textSub]) }
        if let (_, r) = titleLayout() { return runs(r, [Tok.App.titleFg, Tok.App.titleMeta]) }
        return []
    }

    /// Centred on the bar and cut short of the lights and the icons.
    private func titleLayout() -> (CTLine, NSRect)? {
        guard crumb.isEmpty, !zen, !titleFormat.isEmpty, let tab else { return nil }
        let size = Tok.App.titleFont
        let s = NSMutableAttributedString()
        for (text, isTab) in TitleFormat.parts(titleFormat, tab: tab.name, meta: tab.meta) {
            s.append(NSAttributedString(string: text, attributes: [
                .font: Draw.ui(size, isTab ? .semibold : .medium),
                .foregroundColor: isTab ? Tok.App.titleFg : Tok.App.titleMeta,
            ]))
        }
        guard s.length > 0 else { return nil }
        let left = lightRect(2).maxX + Tok.Size.titlebarIconsGap
        let right = accessory == .icons ? (iconLayout().first?.2.minX ?? bounds.width) - Tok.Size.titlebarIconsGap
            : bounds.width - Tok.Size.titlebarPadx
        let half = min(bounds.width / 2 - left, right - bounds.width / 2)
        guard half > 0 else { return nil }
        let line = Draw.truncated(CTLineCreateWithAttributedString(s), 2 * half, Draw.ui(size, .medium), Tok.App.titleMeta)
        let w = Draw.width(line), lh = size * Tok.Font.baseLine
        return (line, NSRect(x: ((bounds.width - w) / 2).rounded(), y: rowTop + (rowH - lh) / 2, width: w, height: lh))
    }

    /// `a › b › c`: parts in the sub grey, separators muted, the last part in the primary ink.
    private func crumbLayout() -> (CTLine, NSRect)? {
        guard !crumb.isEmpty, !zen else { return nil }
        let font = Draw.ui(Tok.Size.crumbFont)
        let s = NSMutableAttributedString()
        for (i, part) in crumb.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: " › ", attributes: [.font: font, .foregroundColor: Tok.Color.textLabel])) }
            // A lone part is a title, not a place (version 11's "Review").
            let color = i == crumb.count - 1 && crumb.count > 1 ? Tok.Color.textPrimary : Tok.Color.textSub
            s.append(NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: color]))
        }
        let line = CTLineCreateWithAttributedString(s)
        let w = Draw.width(line), lh = Tok.Size.crumbFont * Tok.Font.baseLine
        return (line, NSRect(x: (bounds.width - w) / 2, y: rowTop + (rowH - lh) / 2, width: w, height: lh))
    }

    /// Right-aligned up to `right`, cut before it reaches the centred breadcrumb or the lights.
    private func drawPluginLine(rightOf right: CGFloat, in ctx: CGContext) {
        guard let text = pluginLine, !text.isEmpty else { return }
        let gap = Tok.Size.titlebarIconsGap
        let left = crumbLayout().map { $0.1.maxX } ?? lightRect(2).maxX
        guard let line = Self.pluginLine(text, room: right - gap - left - gap) else { return }
        let w = Draw.width(line), lh = Tok.Size.crumbFont * Tok.Font.baseLine
        Draw.text(line, font: Draw.mono(Tok.Size.crumbFont), x: right - gap - w, top: rowTop + (rowH - lh) / 2, lineHeight: lh, in: ctx)
    }

    /// The plugin's line whole, or nil when it doesn't fit `room`: a cut could leave a word that reads as Haunt's
    /// ("Doneness" to "Done…").
    static func pluginLine(_ text: String, room: CGFloat) -> CTLine? {
        let line = Draw.line(text, Draw.mono(Tok.Size.crumbFont), Tok.Color.textLabel)
        let w = Draw.width(line)
        return w > 0 && w <= room ? line : nil
    }

    private func drawSidebarGlyph(centeredIn r: NSRect) {
        let s = Tok.App.sidebarGlyph
        let box = NSRect(x: r.minX, y: (r.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        let rad = Tok.App.sidebarGlyphRadius
        let hl = Tok.App.hairline
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: hl / 2, dy: hl / 2), xRadius: rad, yRadius: rad)
        outline.lineWidth = hl
        Tok.Color.textLabel.setStroke()
        outline.stroke()
        Draw.fill(NSRect(x: box.minX + Tok.App.sidebarGlyphColumn, y: box.minY, width: hl, height: box.height), Tok.Color.textLabel)
    }

    private func drawKbd(_ label: String, in ctx: CGContext) {
        let font = Draw.ui(Tok.Size.kbdFont)
        let line = Draw.line(label, font, Tok.Color.textSub)
        let pad = Tok.Size.kbdPad[1], hl = Tok.App.hairline
        let w = Draw.width(line) + pad * 2 + hl * 2
        let h = Tok.Size.kbdLine + hl * 2
        let box = NSRect(x: bounds.width - Tok.Size.titlebarPadx - w, y: rowTop + (rowH - h) / 2, width: w, height: h)
        let r = Tok.Size.kbdRadius
        let border = NSBezierPath(roundedRect: box.insetBy(dx: hl / 2, dy: hl / 2), xRadius: r - hl / 2, yRadius: r - hl / 2)
        border.lineWidth = hl
        Tok.Color.kbdBorder.setStroke()
        border.stroke()
        Draw.text(line, font: font, x: box.minX + hl + pad, top: box.minY + hl, lineHeight: Tok.Size.kbdLine, in: ctx)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        // As macOS: green enters full screen, and zooms with ⌥, matching the glyph it shows.
        let green = event.modifierFlags.contains(.option) ? #selector(NSWindow.performZoom(_:))
            : #selector(NSWindow.toggleFullScreen(_:))
        let actions: [Selector] = [#selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:)), green]
        for i in 0..<3 where lightRect(i).insetBy(dx: -Tok.App.lightsSlop, dy: -Tok.App.lightsSlop).contains(p) {
            NSApp.sendAction(actions[i], to: window, from: self)
            return
        }
        if let (menu, _, r) = menuLayout().first(where: { $0.2.contains(p) }) {
            menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY), in: self)
            return
        }
        if zen, let hit = hintLayout().parts.first(where: { $0.2.insetBy(dx: -Tok.App.hitSlop, dy: -Tok.App.hitSlop).contains(p) }) {
            onHint?(hit.0)
            return
        }
        if let (_, r) = crumbLayout(), r.insetBy(dx: -4, dy: -4).contains(p), let onCrumb {
            onCrumb()
            return
        }
        if !zen, accessory == .icons, let hit = iconLayout().first(where: { $0.2.insetBy(dx: -Tok.App.hitSlop, dy: -Tok.App.hitSlop).contains(p) }) {
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

extension TitlebarButton {
    var glyph: String {
        switch self {
        case .search: return "⌕"
        case .newTab: return "+"
        case .settings: return "⚙"
        case .sidebar: return ""
        }
    }

    /// The icons only show while the sidebar does, so the sidebar one always hides it.
    var title: String {
        switch self {
        case .search: return "Search"
        case .newTab: return "New Tab"
        case .settings: return "Settings"
        case .sidebar: return "Hide Sidebar"
        }
    }
}
