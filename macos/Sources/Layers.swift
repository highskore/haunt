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
            "row.selected": (sidebar + ["color.row.selected"], ["color.text.primary", "color.text.sub", "color.text.meta", "color.needs"]),
            "palette.row.selected": (palette + ["color.palette.sel"], ["color.palette.ink", "app.palette.pill.ink"]),
        ]
        for s in ["sidebar", "sidebar.footer", "label.group", "row", "row.hover", "status.needs"] { t[s] = (sidebar, sidebarText) }
        for s in ["palette", "palette.caption", "palette.field", "palette.row.hover", "button", "button.default"] { t[s] = (palette, paletteText) }
        return t
    }()

    /// Rows may shadow past their box by this much, still inside the sidebar.
    static let bleed: [String: CGFloat] = ["row": 6, "row.selected": 6, "row.hover": 6, "palette.row.selected": 6, "palette.row.hover": 6]
    /// Bitmaps under text, and anything behind the terminal, are kept this faint.
    static let faintAlpha: CGFloat = 0.12
    /// A stroke this thin can't hide a glyph, so its colour isn't held to the text's contrast.
    static let thinStroke: CGFloat = 2

    /// The theme on screen's layers, by slot, in drawing order.
    private(set) static var current: [String: [ResolvedLayer]] = [:]
    /// Whether Ghostty's background lets `pane.backdrop` show; set with the theme.
    static var terminalSeeThrough = false
    /// Tests: called with each slot drawn and the clip it was drawn in, before its layers.
    static var recorder: ((String, CGRect) -> Void)?

    private(set) static var source = LayerSource()

    static func set(_ layers: [ResolvedLayer], source: LayerSource) {
        current = Dictionary(grouping: layers, by: \.slot)
        self.source = source
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
    /// `exclude` (the terminal). `textRun` is the slot's text, for text anchors. The caller draws its own text after.
    static func draw(_ slot: String, _ bounds: NSRect, within: NSRect? = nil, exclude: NSRect? = nil, textRun: NSRect? = nil,
                     state: Set<String> = [], index: Int? = nil, in ctx: CGContext) {
        guard let layers = current[slot] else { return }
        if slot == "pane.backdrop" && !terminalSeeThrough { return }
        let b = bleed[slot] ?? 0
        var clip = bounds.insetBy(dx: -b, dy: -b)
        if let within { clip = clip.intersection(within) }
        guard !clip.isEmpty else { return }
        recorder?(slot, clip)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let exclude, exclude.intersects(clip) {
            ctx.addRect(clip)
            ctx.addRect(exclude)
            ctx.clip(using: .evenOdd)
        } else {
            ctx.clip(to: clip)
        }
        let textSlot = text[slot] != nil
        for layer in layers where layer.when.isSubset(of: state) && (layer.index == nil || layer.index == index) {
            var alpha = layer.opacity
            if slot == "pane.backdrop" { alpha = min(alpha, faintAlpha) }
            for p in layer.prims {
                let bitmap = p.spec.kind == "image" || p.spec.kind == "pattern"
                ctx.saveGState()
                ctx.setAlpha(textSlot && bitmap ? min(alpha, faintAlpha) : alpha)
                paint(p, in: bounds, textRun: textRun ?? bounds, ctx: ctx)
                ctx.restoreGState()
            }
        }
    }

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
        guard s.repeatMode == "corners" else {
            ctx.saveGState()
            draw(f)
            ctx.restoreGState()
            return
        }
        let local = NSRect(x: f.minX - slot.minX, y: f.minY - slot.minY, width: f.width, height: f.height)
        let pins = [CGPoint(x: slot.minX, y: slot.minY), CGPoint(x: slot.maxX, y: slot.minY), CGPoint(x: slot.maxX, y: slot.maxY), CGPoint(x: slot.minX, y: slot.maxY)]
        for (i, pin) in pins.enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: pin.x, y: pin.y)
            ctx.rotate(by: CGFloat(i) * .pi / 2)
            draw(local)
            ctx.restoreGState()
        }
    }

    // MARK: - Resolving

    /// `specs` with colours resolved against `theme`, each checked against the text it lies under. A colour
    /// that isn't a colour token, or a layer that would leave text unreadable, is skipped and named in the result.
    static func resolve(_ specs: [LayerSpec], images: [CGImage?], theme: Theme) -> ([ResolvedLayer], [String]) {
        var problems: [String] = []
        let base: NSColor = theme.app.appearance == "light" ? .white : .black
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
        layers: for (i, l) in specs.enumerated() {
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
            if let t = text[l.slot] {
                let under = t.over.compactMap(Theme.colorPath).reduce(base) { theme[keyPath: $1].over($0) }
                for p in prims {
                    var flat: [NSColor] = []
                    if let f = p.fill { flat.append(f) }
                    if let s = p.stroke, p.spec.width > thinStroke { flat.append(s) }
                    flat += p.stops.map(\.0)
                    flat += zip(p.stops, p.stops.dropFirst()).map { a, b in a.0.blended(withFraction: 0.5, of: b.0) ?? a.0 }
                    for c in flat {
                        let bg = c.withAlphaComponent(c.alphaComponent * CGFloat(l.opacity)).over(under)
                        for name in t.fg {
                            guard let fg = Theme.colorPath(name) else { continue }
                            let ratio = theme[keyPath: fg].over(bg).contrast(bg)
                            if ratio < LoadedTheme.minContrast {
                                problems.append("\(at): \(name) would read at \(String(format: "%.1f", ratio)):1 over \(c.themeHex), under \(Int(LoadedTheme.minContrast)):1; layer skipped")
                                continue layers
                            }
                        }
                    }
                }
            }
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
