import AppKit

/// A theme's `[[layer]]` tables as core checked them (`theme_layers` in haunt-core), still naming colours by
/// hex or `@token`. Core caps every count and size; see docs/themes.md, "Layers".
struct LayerSpec: Equatable {
    var id: String?
    var slot: String
    var when: [String] = []
    var opacity: Double = 1
    var index: Int?
    var prims: [PrimSpec]
}

struct SpanSpec: Equatable {
    /// "inset", or an anchor: "left", "center", "right", "text.left", "text.right"; "top", "center", "bottom".
    var mode = "inset"
    var a: Double = 0
    var b: Double = 0
    var fromText = false
}

struct PrimSpec: Equatable {
    struct Dot: Equatable { var color: String; var x: Double; var y: Double }
    struct Stop: Equatable { var color: String; var at: Double }
    struct Cmd: Equatable { var op: String; var pts: [Double] }
    var kind: String
    var x = SpanSpec(), y = SpanSpec()
    var radius: Double = 0
    var fill: String?
    var stroke: String?
    var width: Double = 1
    var dash: [Double] = []
    var along = "hmid"
    var angle: Double = 90
    var stops: [Stop] = []
    var rings: [[String]] = []
    var cell: [Double] = []
    var dots: [Dot] = []
    /// Into the theme's images.
    var image: Int?
    var repeatMode = "none"
    var path: [Cmd] = []
    var view: [Double] = []
    var blur: Double = 0
    var offset: [Double] = [0, 0]
    var color: String?
}

/// What a theme's layers were built from, to tell when they changed.
struct LayerSource: Equatable {
    struct Image: Equatable {
        var name: String
        var data: Data
        var width: Int, height: Int
        var image: CGImage? { Layers.image(width: width, height: height, rgba: data) }
    }
    var specs: [LayerSpec] = []
    var images: [Image] = []
}

/// A layer ready to draw: colours resolved against the theme on screen, paths and images built.
struct ResolvedLayer {
    var id: String?
    var slot: String
    var when: Set<String>
    var opacity: CGFloat
    var index: Int?
    var prims: [Prim]

    struct Prim {
        var spec: PrimSpec
        var fill: NSColor?
        var stroke: NSColor?
        var color: NSColor?
        var stops: [(NSColor, CGFloat)] = []
        var rings: [[NSColor]] = []
        var dots: [(NSColor, CGPoint)] = []
        var image: CGImage?
        var path: CGPath?
        /// A pattern's cell, drawn once.
        var tile: CGImage?
    }
}

enum Layers {
    /// Every slot core knows. Bounds and clips are the drawing site's; none of them covers the terminal.
    static let slots: [String] = [
        "window.bg", "pane.backdrop", "pane.frame", "titlebar", "lights", "sidebar", "sidebar.footer", "label.group", "row",
        "row.selected", "row.hover", "icon", "bar.track", "bar.fill", "status.needs", "palette", "palette.caption",
        "palette.field", "palette.row.selected", "palette.row.hover", "button", "button.default",
    ]

    /// The text Haunt draws in each slot that has some, and the backgrounds under it, bottom first: a layer's
    /// flat colours are laid over these and the text must still read.
    static let text: [String: (over: [String], fg: [String])] = {
        let sidebar = ["color.window.bg", "color.sidebar.bg"]
        let sidebarText = ["color.text.primary", "color.text.sub", "color.text.meta", "color.text.label", "color.needs", "app.sidebar.foot.fg"]
        let palette = ["color.palette.bg"]
        let paletteText = ["color.palette.ink", "color.palette.mute"]
        var t: [String: (over: [String], fg: [String])] = [
            "titlebar": (["color.window.bg"], ["app.title.fg", "app.title.meta"]),
            "row.selected": (sidebar, ["color.text.primary", "color.text.sub", "color.text.meta", "color.needs"]),
            "palette.row.selected": (palette + ["color.palette.sel"], ["color.palette.ink", "app.palette.pill.ink"]),
            "palette.caption": (palette + ["app.row.select.fill"], ["app.row.select.ink"]),
        ]
        for s in ["sidebar", "sidebar.footer", "label.group", "row", "row.hover", "status.needs"] { t[s] = (sidebar, sidebarText) }
        for s in ["palette", "palette.field", "palette.row.hover", "button", "button.default"] { t[s] = (palette, paletteText) }
        return t
    }()

    /// A light may be ringed past its circle. Rows get no bleed: each is clipped to its own box, so it never
    /// reaches the text of the row or label next to it.
    static let bleed: [String: CGFloat] = ["lights": 4]
    /// The slots drawn under each slot's text, bottom first, in the order they are drawn: their layers are in the
    /// pixels the slot's text is checked against.
    static let below: [String: [String]] = [
        "row": ["sidebar"], "row.selected": ["sidebar", "row"], "row.hover": ["sidebar", "row"],
        "status.needs": ["sidebar", "row", "row.selected", "row.hover"], "label.group": ["sidebar"], "sidebar.footer": ["sidebar"],
        "palette.field": ["palette"], "palette.row.selected": ["palette", "palette.field"], "palette.row.hover": ["palette", "palette.field"],
    ]
    /// Bitmaps under text, and anything behind the terminal, are kept this faint, all of a slot's together.
    static let faintAlpha: CGFloat = 0.12

    /// The theme on screen's layers, by slot, in drawing order.
    private(set) static var current: [String: [ResolvedLayer]] = [:]
    /// Whether Ghostty's background lets `pane.backdrop` show; set with the theme.
    static var terminalSeeThrough = false
    /// Tests: called with each slot drawn and the clip it was drawn in, before its layers.
    static var recorder: ((String, CGRect) -> Void)?
    /// Layers skipped while drawing because they would paint an unreadable colour over text, each said once.
    private(set) static var skipped: Set<String> = []
    /// Where a skip is said: the theme log.
    static var report: (String) -> Void = { _ in }

    private(set) static var source = LayerSource()

    static func set(_ layers: [ResolvedLayer], source: LayerSource) {
        current = tooSlow.contains(source) ? [:] : Dictionary(grouping: layers, by: \.slot)
        skipped = []
        verdicts = [:]
        drawn = [:]
        self.source = source
        frame = (0, false)
    }

    /// Text a slot draws: where, and in the colour it's drawn in.
    struct Run {
        var rect: NSRect
        var ink: NSColor
        /// What the caller fills under this text after the layers, e.g. a pill.
        var on: NSColor? = nil
    }

    /// A redraw whose layers take longer than this counts as slow; two slow ones, or one over `stopMs`, turn the
    /// theme's layers off for the session.
    static let slowMs = 60.0, stopMs = 200.0
    /// Layer sources turned off this session for being too slow to draw.
    private static var tooSlow: [LayerSource] = []
    private static var slowFrames = 0
    /// Milliseconds spent drawing layers in this redraw, and whether its end is queued.
    private static var frame: (ms: Double, open: Bool) = (0, false)

    /// Ends a redraw: every view drawn in one pass of the run loop is one redraw. Tests call it themselves.
    /// The last redraw's layer time, checks included.
    private(set) static var lastFrameMs = 0.0

    /// Whether a window is being resized live: its redraws are many and cheap to lose, so they never turn layers off.
    static var liveResize: () -> Bool = { NSApp?.windows.contains { $0.inLiveResize } ?? false }

    static func endFrame() {
        drawn = [:]
        guard frame.open else { return }
        let ms = frame.ms
        frame = (0, false)
        judge(ms)
    }

    /// Counts a redraw whose layers took `ms`.
    static func judge(_ ms: Double) {
        lastFrameMs = ms
        guard !current.isEmpty, !liveResize() else { return }
        if ms > slowMs { slowFrames += 1 }
        guard ms > stopMs || slowFrames >= 2 else { return }
        tooSlow.append(source)
        current = [:]
        slowFrames = 0
        report("layers off: too slow to draw (\(Int(ms)) ms for one redraw)")
    }

    static func has(_ slot: String) -> Bool { current[slot] != nil }

    /// The states a slot in `view` is in: its window's focus, plus the row's own.
    static func state(_ view: NSView, selected: Bool = false, hover: Bool = false, pressed: Bool = false) -> Set<String> {
        var s: Set<String> = [view.window?.isKeyWindow == true ? "focused" : "inactive"]
        if selected { s.insert("selected") }
        if hover { s.insert("hover") }
        if pressed { s.insert("pressed") }
        return s
    }

    /// Draws `slot`'s layers into `bounds`, clipped to them (plus the slot's bleed, inside `within`), never into
    /// `exclude` (the terminal). `textRun` is the slot's text, for text anchors; `text` is the text the caller
    /// draws after, each run in its own colour, and `base` what it fills under the layers beyond the slot's own
    /// background (a tint). Without `text` the text run (or the whole slot) is checked in every colour the slot's
    /// text may take. If the layers, as painted, leave any run unreadable, none of the slot's layers are drawn.
    static func draw(_ slot: String, _ bounds: NSRect, within: NSRect? = nil, exclude: NSRect? = nil, textRun: NSRect? = nil,
                     text: [Run]? = nil, base: [NSColor] = [], state: Set<String> = [], index: Int? = nil, in ctx: CGContext) {
        guard let layers = current[slot] else { return }
        if slot == "pane.backdrop" && !terminalSeeThrough { return }
        let b = bleed[slot] ?? 0
        var clip = bounds.insetBy(dx: -b, dy: -b)
        if let within { clip = clip.intersection(within) }
        guard !clip.isEmpty else { return }
        recorder?(slot, clip)
        let shown = layers.filter { l in l.when.isSubset(of: state) && (l.index == nil || l.index == index) }
        guard !shown.isEmpty else { return }
        if !frame.open {
            frame.open = true
            DispatchQueue.main.async { endFrame() }
        }
        // The check is timed with the drawing: a theme that is slow to check is slow to draw.
        let start = DispatchTime.now().uptimeNanoseconds
        defer { frame.ms += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
        let run = textRun ?? bounds
        let runs = Self.text[slot].map { t in text ?? t.fg.compactMap(Theme.colorPath).map { Run(rect: run, ink: Theme.current[keyPath: $0]) } } ?? []
        // Never under 2x: a hairline that 1x would blend away is a solid line on a Retina screen.
        let scale = max(2, abs(ctx.userSpaceToDeviceSpaceTransform.a).rounded(.up))
        if !runs.isEmpty, let why = verdict(shown, slot: slot, bounds: bounds, clip: clip, exclude: exclude, run: run, runs: runs, base: base,
                                            state: state, index: index, scale: scale, ctm: ctx.ctm) {
            let said = "layers on \(slot) skipped: \(why)"
            if skipped.insert(said).inserted { report(said) }
            return
        }
        drawn[slot] = Drawn(shown: shown, bounds: bounds, clip: clip, exclude: exclude, run: run, ctm: ctx.ctm)
        paint(drawn[slot]!, slot: slot, in: ctx)
    }

    /// A slot's layers as last drawn in this redraw, for the checks of the slots drawn over it.
    private struct Drawn {
        var shown: [ResolvedLayer]
        var bounds, clip: NSRect
        var exclude: NSRect?
        var run: NSRect
        var ctm: CGAffineTransform
    }
    private static var drawn: [String: Drawn] = [:]

    private static func paint(_ d: Drawn, slot: String, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let exclude = d.exclude, exclude.intersects(d.clip) {
            ctx.addRect(d.clip)
            ctx.addRect(exclude)
            ctx.clip(using: .evenOdd)
        } else {
            ctx.clip(to: d.clip)
        }
        render(d.shown, slot: slot, bounds: d.bounds, run: d.run, ctx: ctx)
    }

    /// Verdicts already reached, by slot, size, state and text; emptied with the theme, or when it holds 512.
    /// nil means readable.
    private static var verdicts: [String: String?] = [:]

    /// Renders `shown`, over the slot's real background and the layers of the slots drawn under it, at `scale`, as
    /// painted (stacking, winding, every kind), and says which run, if any, it leaves under 3:1. Fails closed: a
    /// run it can't measure is unreadable.
    static func verdict(_ shown: [ResolvedLayer], slot: String, bounds: NSRect, clip: NSRect, exclude: NSRect? = nil, run: NSRect, runs: [Run],
                        base: [NSColor], state: Set<String>, index: Int?, scale: CGFloat = 2, ctm: CGAffineTransform = .identity) -> String? {
        let inside = runs.map { $0.rect.intersection(clip) }.filter { !$0.isEmpty }
        guard !inside.isEmpty else { return nil }
        let area = inside.dropFirst().reduce(inside[0]) { $0.union($1) }.integral
        func rel(_ r: NSRect) -> String { String(format: "%.1f,%.1f,%.1f,%.1f", r.minX - clip.minX, r.minY - clip.minY, r.width, r.height) }
        // The lower slots, mapped from where they were drawn into this slot's space.
        let lower: [(String, Drawn, CGAffineTransform)] = (below[slot] ?? []).compactMap { s in
            guard let d = drawn[s] else { return nil }
            let to = d.ctm.concatenating(ctm.inverted())
            return d.clip.applying(to).intersects(area) ? (s, d, to) : nil
        }
        var key = "\(slot)|\(shown.map { $0.id ?? "" })|\(shown.count)|\(rel(clip))|\(exclude.map(rel) ?? "")|\(rel(bounds))|\(rel(run))|\(state.sorted())|"
            + "\(index ?? -1)|\(scale)|" + runs.map { "\(rel($0.rect))\($0.ink.themeHex)\($0.on?.themeHex ?? "")" }.joined(separator: ";") + "|"
            + base.map(\.themeHex).joined()
        for (s, d, to) in lower {
            key += "|\(s):\(d.shown.map { $0.id ?? "" })\(d.shown.count)\(rel(d.clip.applying(to)))\(rel(d.bounds.applying(to)))\(d.exclude.map(rel) ?? "")"
        }
        if let v = verdicts[key] { return v }
        if verdicts.count >= 512 { verdicts = [:] }
        let v = measure(shown, slot: slot, bounds: bounds, clip: clip, exclude: exclude, run: run, runs: runs, base: base, area: area,
                        lower: lower, scale: scale)
        verdicts[key] = v
        return v
    }

    private static func measure(_ shown: [ResolvedLayer], slot: String, bounds: NSRect, clip: NSRect, exclude: NSRect?, run: NSRect, runs: [Run],
                                base: [NSColor], area: NSRect, lower: [(String, Drawn, CGAffineTransform)], scale: CGFloat) -> String? {
        let w = Int((area.width * scale).rounded(.up)), h = Int((area.height * scale).rounded(.up))
        guard w > 0, h > 0, w * h <= 4 << 20 else { return "its text is too large to check (\(w)x\(h) px)" }
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "its text could not be checked" }
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: scale, y: -scale)
        c.translateBy(x: -area.minX, y: -area.minY)
        let theme = Theme.current
        let ground = (text[slot]?.over ?? []).compactMap(Theme.colorPath).map { theme[keyPath: $0] }
        c.setFillColor((ground.reduce(theme.app.appearance == "light" ? NSColor.white : .black) { $1.over($0) }).cgColor)
        c.fill(area)
        // Real order: the panel's own slot, then what the site fills under its layers, then the slots over it.
        let root = below[slot]?.first
        if root == nil || lower.first?.0 != root { fill(base, area, c) }
        for (s, d, to) in lower {
            c.saveGState()
            c.concatenate(to)
            paint(d, slot: s, in: c)
            c.restoreGState()
            if s == root { fill(base, area, c) }
        }
        paint(Drawn(shown: shown, bounds: bounds, clip: clip, exclude: exclude, run: run, ctm: .identity), slot: slot, in: c)
        for r in runs where r.rect.intersects(clip) {
            if let on = r.on {
                c.setFillColor(on.cgColor)
                c.fill(r.rect)
            }
            guard let ratio = worst(r, in: c, area: area, scale: scale) else { return "text at \(rel(r.rect, area)) is too small to check" }
            if ratio < LoadedTheme.minContrast {
                return "text in \(r.ink.themeHex) reads at \(String(format: "%.1f", ratio)):1 over them, under \(Int(LoadedTheme.minContrast)):1"
            }
        }
        return nil
    }

    private static func fill(_ colors: [NSColor], _ r: NSRect, _ c: CGContext) {
        for color in colors {
            c.setFillColor(color.cgColor)
            c.fill(r)
        }
    }

    private static func rel(_ r: NSRect, _ to: NSRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", r.minX - to.minX, r.minY - to.minY, r.width, r.height)
    }

    /// The contrast `r`'s ink gets on the worst pixel wholly inside its box: any of them may sit under a glyph's
    /// stroke, so a hairline across the text fails it, while antialiasing that only grazes the box's edge doesn't.
    private static func worst(_ r: Run, in c: CGContext, area: NSRect, scale: CGFloat) -> Double? {
        guard let data = c.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = c.bytesPerRow
        let x0 = max(Int(((r.rect.minX - area.minX) * scale).rounded(.up)), 0), x1 = min(Int(((r.rect.maxX - area.minX) * scale).rounded(.down)), c.width)
        let y0 = max(Int(((r.rect.minY - area.minY) * scale).rounded(.up)), 0), y1 = min(Int(((r.rect.maxY - area.minY) * scale).rounded(.down)), c.height)
        guard x1 > x0, y1 > y0 else { return nil }
        let ink = r.ink.usingColorSpace(.sRGB) ?? r.ink
        let a = Double(ink.alphaComponent), keep = 1 - a
        let (ir, ig, ib) = (Double(ink.redComponent) * a * 255, Double(ink.greenComponent) * a * 255, Double(ink.blueComponent) * a * 255)
        let lut = linear
        var low = Double.infinity
        for y in y0..<y1 {
            var p = data + y * row + x0 * 4
            for _ in x0..<x1 {
                // The bitmap is opaque (its ground is), so premultiplied is plain.
                let (br, bg, bb) = (Int(p[0]), Int(p[1]), Int(p[2]))
                let lb = 0.2126 * lut[br] + 0.7152 * lut[bg] + 0.0722 * lut[bb]
                let lt = 0.2126 * lut[Int(ir + Double(br) * keep + 0.5)] + 0.7152 * lut[Int(ig + Double(bg) * keep + 0.5)]
                    + 0.0722 * lut[Int(ib + Double(bb) * keep + 0.5)]
                low = min(low, (max(lb, lt) + 0.05) / (min(lb, lt) + 0.05))
                p += 4
            }
        }
        return low
    }

    /// sRGB's 8-bit values, linear.
    private static let linear: [Double] = (0..<256).map { i in
        let v = Double(i) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// `shown` into `ctx`, already clipped.
    private static func render(_ shown: [ResolvedLayer], slot: String, bounds: NSRect, run: NSRect, ctx: CGContext) {
        func paintAll(_ bitmaps: Bool?) {
            for layer in shown {
                for p in layer.prims where bitmaps == nil || isBitmap(p) == bitmaps {
                    ctx.saveGState()
                    ctx.setAlpha(layer.opacity)
                    paint(p, in: bounds, textRun: run, ctx: ctx)
                    ctx.restoreGState()
                }
            }
        }
        // A faint slot is one group at `faintAlpha`, however many shapes it stacks; so are a text slot's bitmaps,
        // drawn first, under its shapes.
        func faint(_ bitmaps: Bool?) {
            ctx.saveGState()
            ctx.setAlpha(faintAlpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            paintAll(bitmaps)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        if slot == "pane.backdrop" { return faint(nil) }
        guard text[slot] != nil else { return paintAll(nil) }
        if shown.contains(where: { $0.prims.contains(where: isBitmap) }) { faint(true) }
        paintAll(false)
    }

    private static func isBitmap(_ p: ResolvedLayer.Prim) -> Bool { p.spec.kind == "image" || p.spec.kind == "pattern" }

    // MARK: - Geometry

    /// One axis of a primitive's frame, in the slot's top-down coordinates.
    static func span(_ s: SpanSpec, lo: CGFloat, hi: CGFloat, textLo: CGFloat, textHi: CGFloat) -> (CGFloat, CGFloat) {
        let a = CGFloat(s.a), b = CGFloat(s.b)
        if s.mode == "inset" { return ((s.fromText ? textHi : lo) + a, hi - b) }
        let base: CGFloat = switch s.mode {
        case "right", "bottom": hi - b
        case "center": (lo + hi - b) / 2
        case "text.left": textLo
        case "text.right": textHi
        default: lo
        }
        return (base + a, base + a + b)
    }

    static func frame(_ p: PrimSpec, in r: NSRect, textRun t: NSRect) -> NSRect {
        let (x0, x1) = span(p.x, lo: r.minX, hi: r.maxX, textLo: t.minX, textHi: t.maxX)
        let (y0, y1) = span(p.y, lo: r.minY, hi: r.maxY, textLo: t.minY, textHi: t.maxY)
        return NSRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    // MARK: - Painting (flipped, top-down coordinates)

    private static func paint(_ p: ResolvedLayer.Prim, in slot: NSRect, textRun: NSRect, ctx: CGContext) {
        let s = p.spec
        let f = frame(s, in: slot, textRun: textRun)
        guard f.width > 0 || f.height > 0 || s.kind == "line" else { return }
        switch s.kind {
        case "rect":
            let shape = CGPath(roundedRect: f, cornerWidth: min(s.radius, f.width / 2), cornerHeight: min(s.radius, f.height / 2), transform: nil)
            if let fill = p.fill { ctx.addPath(shape); ctx.setFillColor(fill.cgColor); ctx.fillPath() }
            if let stroke = p.stroke {
                let w = CGFloat(s.width), i = f.insetBy(dx: w / 2, dy: w / 2)
                let r = max(0, min(s.radius - w / 2, i.width / 2, i.height / 2))
                ctx.addPath(CGPath(roundedRect: i, cornerWidth: r, cornerHeight: r, transform: nil))
                strokePath(stroke, s, ctx)
            }
        case "line":
            guard let stroke = p.stroke else { return }
            let w = CGFloat(s.width)
            let (a, b): (CGPoint, CGPoint) = switch s.along {
            case "top": (CGPoint(x: f.minX, y: f.minY + w / 2), CGPoint(x: f.maxX, y: f.minY + w / 2))
            case "bottom": (CGPoint(x: f.minX, y: f.maxY - w / 2), CGPoint(x: f.maxX, y: f.maxY - w / 2))
            case "left": (CGPoint(x: f.minX + w / 2, y: f.minY), CGPoint(x: f.minX + w / 2, y: f.maxY))
            case "right": (CGPoint(x: f.maxX - w / 2, y: f.minY), CGPoint(x: f.maxX - w / 2, y: f.maxY))
            case "vmid": (CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.midX, y: f.maxY))
            default: (CGPoint(x: f.minX, y: f.midY), CGPoint(x: f.maxX, y: f.midY))
            }
            ctx.move(to: a)
            ctx.addLine(to: b)
            strokePath(stroke, s, ctx)
        case "gradient":
            guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: p.stops.map(\.0.cgColor) as CFArray, locations: p.stops.map(\.1)) else { return }
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: f, cornerWidth: min(s.radius, f.width / 2), cornerHeight: min(s.radius, f.height / 2), transform: nil))
            ctx.clip()
            let t = CGFloat(s.angle) * .pi / 180, d = CGVector(dx: cos(t), dy: sin(t))
            let half = (abs(d.dx) * f.width + abs(d.dy) * f.height) / 2
            let c = CGPoint(x: f.midX, y: f.midY)
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x - d.dx * half, y: c.y - d.dy * half),
                                   end: CGPoint(x: c.x + d.dx * half, y: c.y + d.dy * half), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        case "bevel":
            for (k, ring) in p.rings.enumerated() {
                let r = f.insetBy(dx: CGFloat(k), dy: CGFloat(k))
                guard r.width >= 2, r.height >= 2 else { break }
                let edges = [NSRect(x: r.minX, y: r.minY, width: r.width, height: 1), NSRect(x: r.minX, y: r.minY, width: 1, height: r.height),
                             NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height)]
                for (e, c) in zip(edges, ring) { ctx.setFillColor(c.cgColor); ctx.fill(e) }
            }
        case "pattern":
            guard let tile = p.tile ?? p.image else { return }
            let cell = s.cell.count == 2 ? CGSize(width: s.cell[0], height: s.cell[1]) : CGSize(width: CGFloat(tile.width) / 2, height: CGFloat(tile.height) / 2)
            ctx.saveGState()
            ctx.clip(to: f)
            ctx.translateBy(x: f.minX, y: f.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(tile, in: CGRect(origin: .zero, size: cell), byTiling: true)
            ctx.restoreGState()
        case "image":
            guard let img = p.image else { return }
            if s.repeatMode == "tile" {
                ctx.saveGState()
                ctx.clip(to: f)
                ctx.translateBy(x: f.minX, y: f.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2), byTiling: true)
                ctx.restoreGState()
            } else {
                corners(s, f, slot, ctx) { r in
                    ctx.translateBy(x: r.minX, y: r.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
                }
            }
        case "path":
            guard let path = p.path, s.view.count == 2 else { return }
            corners(s, f, slot, ctx) { r in
                // Scaled as a path, not through the CTM, so the stroke's width stays in points.
                var t = CGAffineTransform(translationX: r.minX, y: r.minY).scaledBy(x: r.width / s.view[0], y: r.height / s.view[1])
                guard let placed = path.copy(using: &t) else { return }
                if let fill = p.fill { ctx.addPath(placed); ctx.setFillColor(fill.cgColor); ctx.fillPath() }
                if let stroke = p.stroke { ctx.addPath(placed); strokePath(stroke, s, ctx) }
            }
        case "shadow":
            guard let color = p.color else { return }
            let shape = CGPath(roundedRect: f, cornerWidth: min(s.radius, f.width / 2), cornerHeight: min(s.radius, f.height / 2), transform: nil)
            ctx.saveGState()
            // Only the shadow shows: the shape itself is clipped out.
            ctx.addRect(f.insetBy(dx: -40, dy: -40))
            ctx.addPath(shape)
            ctx.clip(using: .evenOdd)
            // Shadow offsets ignore the CTM; these views are flipped, so down is negative.
            ctx.setShadow(offset: CGSize(width: s.offset[0], height: -s.offset[1]), blur: CGFloat(s.blur), color: color.cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        default:
            break
        }
    }

    private static func strokePath(_ c: NSColor, _ s: PrimSpec, _ ctx: CGContext) {
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(CGFloat(s.width))
        if !s.dash.isEmpty { ctx.setLineDash(phase: 0, lengths: s.dash.map { CGFloat($0) }) }
        ctx.strokePath()
    }

    /// Runs `draw` with the frame `f` in place, or, for `repeat = "corners"`, once per corner of `slot`: turned a
    /// quarter more at each, clockwise from the top left, so a top-left ornament faces inward everywhere.
    private static func corners(_ s: PrimSpec, _ f: NSRect, _ slot: NSRect, _ ctx: CGContext, _ draw: (NSRect) -> Void) {
        for (t, r) in placements(s, f, slot) {
            ctx.saveGState()
            ctx.concatenate(t)
            draw(r)
            ctx.restoreGState()
        }
    }

    /// Where `corners` puts the frame `f`: a transform and the frame under it.
    static func placements(_ s: PrimSpec, _ f: NSRect, _ slot: NSRect) -> [(CGAffineTransform, NSRect)] {
        guard s.repeatMode == "corners" else { return [(.identity, f)] }
        let local = NSRect(x: f.minX - slot.minX, y: f.minY - slot.minY, width: f.width, height: f.height)
        let pins = [CGPoint(x: slot.minX, y: slot.minY), CGPoint(x: slot.maxX, y: slot.minY), CGPoint(x: slot.maxX, y: slot.maxY), CGPoint(x: slot.minX, y: slot.maxY)]
        return pins.enumerated().map { i, pin in
            (CGAffineTransform(rotationAngle: CGFloat(i) * .pi / 2).concatenating(CGAffineTransform(translationX: pin.x, y: pin.y)), local)
        }
    }

    // MARK: - Resolving

    /// `specs` with colours resolved against `theme`; a slot's text is checked against them as drawn. A colour
    /// that isn't a colour token is skipped and named in the result.
    static func resolve(_ specs: [LayerSpec], images: [CGImage?], theme: Theme) -> ([ResolvedLayer], [String]) {
        var problems: [String] = []
        func color(_ s: String?) -> NSColor?? {
            guard let s else { return .some(nil) }
            if s.hasPrefix("@") {
                let name = String(s.dropFirst())
                let path = Theme.colorPath("color." + name) ?? Theme.colorPath(name)
                return path.map { theme[keyPath: $0] }
            }
            return NSColor(themeHex: s).map { $0 }
        }
        var out: [ResolvedLayer] = []
        for (i, l) in specs.enumerated() {
            let at = "layer \(i + 1) (\(l.slot))"
            var prims: [ResolvedLayer.Prim] = []
            for s in l.prims {
                var p = ResolvedLayer.Prim(spec: s)
                var bad: String?
                func c(_ v: String?) -> NSColor? {
                    switch color(v) {
                    case let .some(c): return c
                    case .none: bad = v; return nil
                    }
                }
                p.fill = c(s.fill)
                p.stroke = c(s.stroke)
                p.color = c(s.color)
                p.stops = s.stops.map { (c($0.color) ?? .clear, CGFloat($0.at)) }
                p.rings = s.rings.map { $0.map { c($0) ?? .clear } }
                p.dots = s.dots.map { (c($0.color) ?? .clear, CGPoint(x: $0.x, y: $0.y)) }
                if let bad {
                    problems.append("\(at): \(bad) isn't a colour token; that \(s.kind) is skipped")
                    continue
                }
                if let i = s.image { p.image = i < images.count ? images[i] : nil }
                if !s.path.isEmpty { p.path = cgPath(s.path) }
                if s.kind == "pattern", p.image == nil { p.tile = tile(p) }
                prims.append(p)
            }
            if prims.isEmpty { continue }
            out.append(ResolvedLayer(id: l.id, slot: l.slot, when: Set(l.when), opacity: CGFloat(l.opacity), index: l.index, prims: prims))
        }
        return (out, problems)
    }

    static func cgPath(_ cmds: [PrimSpec.Cmd]) -> CGPath {
        let p = CGMutablePath()
        for c in cmds {
            let v = c.pts.map { CGFloat($0) }
            switch c.op {
            case "M" where v.count == 2: p.move(to: CGPoint(x: v[0], y: v[1]))
            case "L" where v.count == 2 && !p.isEmpty: p.addLine(to: CGPoint(x: v[0], y: v[1]))
            case "Q" where v.count == 4 && !p.isEmpty: p.addQuadCurve(to: CGPoint(x: v[2], y: v[3]), control: CGPoint(x: v[0], y: v[1]))
            case "C" where v.count == 6 && !p.isEmpty:
                p.addCurve(to: CGPoint(x: v[4], y: v[5]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
            case "Z" where !p.isEmpty: p.closeSubpath()
            default: break
            }
        }
        return p
    }

    /// A pattern's cell at 2×, its dots 1 pt squares from its top left.
    static func tile(_ p: ResolvedLayer.Prim) -> CGImage? {
        guard p.spec.cell.count == 2 else { return nil }
        let w = Int(p.spec.cell[0] * 2), h = Int(p.spec.cell[1] * 2)
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (color, pt) in p.dots {
            c.setFillColor(color.cgColor)
            // Bitmap rows run bottom up; the cell is drawn flipped back by `paint`.
            c.fill(CGRect(x: pt.x * 2, y: CGFloat(h) - pt.y * 2 - 2, width: 2, height: 2))
        }
        return c.makeImage()
    }

    /// Straight-alpha RGBA from core as an image.
    static func image(width: Int, height: Int, rgba: Data) -> CGImage? {
        guard rgba.count == width * height * 4, let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
