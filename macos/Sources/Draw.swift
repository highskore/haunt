import AppKit

/// Text and shapes laid out the way the mockup's CSS does it, so geometry matches the reference.
enum Draw {
    private enum FontKind: Hashable { case ui, tabular, mono }
    private struct FontKey: Hashable {
        let kind: FontKind, size: CGFloat, weight: CGFloat
    }

    /// Drawing runs on the main thread only, so these caches need no lock.
    private static var fonts: [FontKey: NSFont] = [:]

    private static func cached(_ kind: FontKind, _ size: CGFloat, _ weight: NSFont.Weight, _ make: () -> NSFont) -> NSFont {
        let key = FontKey(kind: kind, size: size, weight: weight.rawValue)
        if let f = fonts[key] { return f }
        let f = make()
        fonts[key] = f
        return f
    }

    /// After a theme change: fonts and ellipses are rebuilt from the new tokens.
    static func flushCaches() {
        fonts = [:]
        ellipses = [:]
    }

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        cached(.ui, size, weight) { themeUI(size, weight) ?? NSFont.systemFont(ofSize: size, weight: weight) }
    }

    static func uiTabular(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        cached(.tabular, size, weight) {
            guard let f = themeUI(size, weight) else { return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) }
            let digits: [NSFontDescriptor.FeatureKey: Int] = [.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]
            return NSFont(descriptor: f.fontDescriptor.addingAttributes([.featureSettings: [digits]]), size: size) ?? f
        }
    }

    /// `font.ui`'s first family, when a theme names one; the default's CSS stack starts with the system font.
    private static func themeUI(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont? {
        guard let first = Tok.Font.ui.split(separator: ",").first?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")),
              !["-apple-system", "BlinkMacSystemFont", "system-ui"].contains(first) else { return nil }
        let weight = weight == .regular && Theme.current.effects.uiWeight == "light" ? NSFont.Weight.light : weight
        if let f = ThemeFonts.uiFont(family: first, weight: weight, size: size) { return f }
        // NSFontManager weights: 3 light, 5 regular, 6 medium, 8 semibold, 9 bold.
        let w = weight >= .bold ? 9 : weight >= .semibold ? 8 : weight >= .medium ? 6 : weight <= .light ? 3 : 5
        return NSFontManager.shared.font(withFamily: first, traits: [], weight: w, size: size)
    }

    static func mono(_ size: CGFloat) -> NSFont {
        cached(.mono, size, .regular) {
            for name in [Tok.Font.monoFamily] + Tok.Font.monoFallback {
                if let f = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { return f }
            }
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    static func line(_ s: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attrs[.kern] = kern }
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// `line` cut to `maxWidth` with a trailing ellipsis, like `text-overflow: ellipsis`.
    static func truncated(_ line: CTLine, _ maxWidth: CGFloat, _ font: NSFont, _ color: NSColor) -> CTLine {
        guard width(line) > maxWidth else { return line }
        return CTLineCreateTruncatedLine(line, Double(max(maxWidth, 0)), .end, ellipsis(font, color)) ?? line
    }

    /// One "…" per font and colour; the entry keeps both alive, so their identities stay unique.
    private struct EllipsisKey: Hashable {
        let font: ObjectIdentifier, color: ObjectIdentifier
    }
    private static var ellipses: [EllipsisKey: (NSFont, NSColor, CTLine)] = [:]

    private static func ellipsis(_ font: NSFont, _ color: NSColor) -> CTLine {
        let key = EllipsisKey(font: ObjectIdentifier(font), color: ObjectIdentifier(color))
        if let e = ellipses[key] { return e.2 }
        let token = line("…", font, color)
        ellipses[key] = (font, color, token)
        return token
    }

    /// Draws `line` in a CSS line box starting at `top`. Like Blink: integer ascent/descent, half-leading,
    /// baseline snapped to a device pixel.
    static func text(_ line: CTLine, font: NSFont, x: CGFloat, top: CGFloat, lineHeight: CGFloat, in ctx: CGContext) {
        let ascent = font.ascender.rounded(), descent = (-font.descender).rounded()
        let scale = ctx.userSpaceToDeviceSpaceTransform.d.magnitude
        let raw = top + (lineHeight - ascent - descent) / 2 + ascent
        let baseline = scale > 0 ? (raw * scale).rounded() / scale : raw
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// `app.display.font`, when a theme names one.
    static func display(_ size: CGFloat) -> NSFont? {
        let family = Theme.current.app.displayFont
        guard !family.isEmpty else { return nil }
        return ThemeFonts.uiFont(family: family, weight: .regular, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    /// Like `text`, filled with `app.text.chrome` top to bottom over the glyphs when the theme has one: the
    /// line is drawn into an alpha mask, and the gradient through it.
    static func chromeText(_ line: CTLine, font: NSFont, x: CGFloat, top: CGFloat, lineHeight: CGFloat, in ctx: CGContext) {
        let stops = Theme.current.chromeStops
        guard !stops.isEmpty else { return text(line, font: font, x: x, top: top, lineHeight: lineHeight, in: ctx) }
        let ascent = font.ascender.rounded(), descent = (-font.descender).rounded()
        let box = NSRect(x: x.rounded(.down), y: top, width: (width(line) + 2).rounded(.up), height: lineHeight)
        let scale = max(ctx.userSpaceToDeviceSpaceTransform.d.magnitude, 1)
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard w > 0, h > 0, let mask = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        // The mask is y-up; its baseline sits as `text` would put it in the y-down view.
        mask.scaleBy(x: scale, y: scale)
        let baseline = (lineHeight - ascent - descent) / 2 + ascent
        mask.textPosition = CGPoint(x: x - box.minX, y: lineHeight - baseline)
        // Each glyph run drawn white, whatever colour the line was made in: the mask takes coverage only.
        mask.setFillColor(gray: 1, alpha: 1)
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attrs[kCTFontAttributeName] else { continue }
            // Positions are relative to the text position, which CTFontDrawGlyphs adds.
            CTFontDrawGlyphs(runFont as! CTFont, glyphs, pos, n, mask)
        }
        guard let image = mask.makeImage() else { return }
        ctx.saveGState()
        // Flipped view: draw the y-up mask upside down so it lands the right way round.
        ctx.translateBy(x: box.minX, y: box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(origin: .zero, size: box.size), mask: image)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -box.minX, y: -box.maxY)
        chrome(NSRect(x: box.minX, y: top + (lineHeight - ascent - descent) / 2, width: box.width, height: ascent + descent), stops, in: ctx)
        ctx.restoreGState()
    }

    /// `rect` filled with `stops`, top to bottom, inside the current clip.
    static func chrome(_ rect: NSRect, _ stops: [NSColor], in ctx: CGContext) {
        let at = Theme.current.chromeLocations
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.cgColor) as CFArray,
                                 locations: at.count == stops.count ? at : stops.indices.map { CGFloat($0) / CGFloat(max(stops.count - 1, 1)) })
        else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    /// A square turned 45°, `size` across its sides, stroked or filled in the current colour.
    static func diamond(center c: NSPoint, size: CGFloat, stroke: CGFloat? = nil) {
        let k = size / 2 * 2.squareRoot()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y - k)); p.line(to: NSPoint(x: c.x + k, y: c.y))
        p.line(to: NSPoint(x: c.x, y: c.y + k)); p.line(to: NSPoint(x: c.x - k, y: c.y)); p.close()
        if let stroke { p.lineWidth = stroke; p.stroke() } else { p.fill() }
    }

    /// The haunt-themes card's sigil, `size` across with its top-left at `origin`: rings, ticks, a seven-point
    /// star, a triangle, a hub and nodes, stroked in the current colour.
    static func sigil(at origin: NSPoint, size: CGFloat, stroke: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let paths = sigilPaths(size)
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.setLineWidth(stroke)
        ctx.addPath(paths.solid)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [1, 4])
        ctx.addPath(paths.dashed)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Unit directions for `n` points around a circle from `rot` degrees.
    private static func spokes(_ n: Int, _ rot: CGFloat = -90) -> [CGVector] {
        (0..<n).map { i in
            let a = (rot + CGFloat(i) * 360 / CGFloat(n)) * .pi / 180
            return CGVector(dx: cos(a), dy: sin(a))
        }
    }

    private static let spokes72 = spokes(72), spokes7 = spokes(7), spokes3 = spokes(3, 90)
    private static var sigilCache: [CGFloat: (solid: CGPath, dashed: CGPath)] = [:]

    /// The sigil's strokes at `size`, its top-left at the origin; built once a size.
    private static func sigilPaths(_ size: CGFloat) -> (solid: CGPath, dashed: CGPath) {
        if let p = sigilCache[size] { return p }
        let c = CGPoint(x: size / 2, y: size / 2)
        let big = size * 0.46, mid = size * 0.41, tri = size * 0.28
        func at(_ v: CGVector, _ r: CGFloat) -> CGPoint { CGPoint(x: c.x + r * v.dx, y: c.y + r * v.dy) }
        func circle(_ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }
        let solid = CGMutablePath()
        solid.addEllipse(in: circle(big))
        solid.addEllipse(in: circle(mid))
        for (i, v) in spokes72.enumerated() {
            solid.move(to: at(v, big))
            solid.addLine(to: at(v, big - (i % 6 == 0 ? 8 : 3)))
        }
        let seven = spokes7.map { at($0, mid) }
        solid.addLines(between: (0..<7).map { seven[($0 * 3) % 7] })
        solid.closeSubpath()
        solid.addLines(between: spokes3.map { at($0, tri) })
        solid.closeSubpath()
        solid.addEllipse(in: circle(size * 0.07))
        solid.move(to: CGPoint(x: c.x, y: c.y - mid)); solid.addLine(to: CGPoint(x: c.x, y: c.y + mid))
        solid.move(to: CGPoint(x: c.x - size * 0.1, y: c.y + size * 0.12)); solid.addLine(to: CGPoint(x: c.x + size * 0.1, y: c.y + size * 0.12))
        let r = size * 0.016
        for p in seven { solid.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        let dashed = CGMutablePath()
        dashed.addEllipse(in: circle(big - 10))
        sigilCache[size] = (solid, dashed)
        return (solid, dashed)
    }

    /// The card's 46 pt corner ornament for the top-left corner at `origin`, turned by `quarterTurns` × 90°
    /// about its centre; `bright` strokes the outer frame and flourishes, `dim` the inner frame.
    static func cornerOrnament(at origin: NSPoint, quarterTurns: Int, bright: NSColor, dim: NSColor, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x + 23, y: origin.y + 23)
        ctx.rotate(by: CGFloat(quarterTurns) * .pi / 2)
        ctx.translateBy(x: -23, y: -23)
        func path(_ build: (NSBezierPath) -> Void, _ color: NSColor) {
            let p = NSBezierPath()
            build(p)
            p.lineWidth = 1
            color.setStroke()
            p.stroke()
        }
        path({ $0.move(to: NSPoint(x: 3, y: 43)); $0.line(to: NSPoint(x: 3, y: 3)); $0.line(to: NSPoint(x: 43, y: 3)) }, bright)
        path({ $0.move(to: NSPoint(x: 8, y: 38)); $0.line(to: NSPoint(x: 8, y: 8)); $0.line(to: NSPoint(x: 38, y: 8)) }, dim)
        path({ $0.move(to: NSPoint(x: 3, y: 14)); $0.curve(to: NSPoint(x: 14, y: 3), controlPoint1: NSPoint(x: 9, y: 14), controlPoint2: NSPoint(x: 14, y: 9)) }, bright)
        path({ $0.appendOval(in: NSRect(x: 11.5, y: 11.5, width: 5, height: 5)) }, bright)
        path({
            $0.move(to: NSPoint(x: 14, y: 14)); $0.line(to: NSPoint(x: 23, y: 23))
            $0.move(to: NSPoint(x: 18, y: 9)); $0.line(to: NSPoint(x: 21, y: 6))
            $0.move(to: NSPoint(x: 9, y: 18)); $0.line(to: NSPoint(x: 6, y: 21))
            $0.move(to: NSPoint(x: 28, y: 3)); $0.line(to: NSPoint(x: 31, y: 6)); $0.line(to: NSPoint(x: 34, y: 3))
            $0.move(to: NSPoint(x: 3, y: 28)); $0.line(to: NSPoint(x: 6, y: 31)); $0.line(to: NSPoint(x: 3, y: 34))
        }, bright)
        ctx.restoreGState()
    }

    /// A 1 or 2 pt bevel inside `r` in `app.bevel.*`: "out" raised (a window), "in" sunken (a field), "button",
    /// "etched" (a group box) or "thin" (a 1 pt sunken edge).
    static func bevel(_ r: NSRect, _ style: String) {
        let a = Theme.current.app
        let (light, hi, shade, dark) = (a.bevelLight, a.bevelHi, a.bevelShade, a.bevelDark)
        // Each ring's top-left colour, then its bottom-right one, which wins at the corners as in the CSS.
        let rings: [(NSColor, NSColor)] = switch style {
        case "out": [(hi, dark), (light, shade)]
        case "in": [(shade, light), (dark, hi)]
        case "button": [(light, dark), (hi, shade)]
        case "etched": [(shade, light), (light, shade)]
        default: [(shade, light)]
        }
        for (i, (tl, br)) in rings.enumerated() {
            let b = r.insetBy(dx: CGFloat(i), dy: CGFloat(i))
            fill(NSRect(x: b.minX, y: b.minY, width: b.width, height: 1), tl)
            fill(NSRect(x: b.minX, y: b.minY, width: 1, height: b.height), tl)
            fill(NSRect(x: b.minX, y: b.maxY - 1, width: b.width, height: 1), br)
            fill(NSRect(x: b.maxX - 1, y: b.minY, width: 1, height: b.height), br)
        }
    }

    /// `icon.style = "pixel"`: the claude icon, or else the shell's, as pixel art; false for the vector style.
    static func pixelIcon(claude: Bool, in r: NSRect) -> Bool {
        guard Theme.current.effects.iconStyle == "pixel" else { return false }
        if claude { pixelStar(in: r); return true }
        pixels(dosPixels, ["k": .black, "b": NSColor(srgbRed: 0, green: 0, blue: 0.5, alpha: 1), "g": NSColor(white: 0.75, alpha: 1)],
               at: NSPoint(x: r.minX, y: r.minY), scale: r.width / 16)
        return true
    }

    /// The haunt-themes card's 9×9 pixel Claude star, scaled into `rect` in Claude orange.
    static func pixelStar(in rect: NSRect) {
        let rows = ["#...#...#", ".#..#..#.", "..#.#.#..", "...###...", "#########", "...###...", "..#.#.#..", ".#..#..#.", "#...#...#"]
        let k = rect.width / 9
        Tok.Color.claude.setFill()
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                NSRect(x: rect.minX + CGFloat(x) * k, y: rect.minY + CGFloat(y) * k, width: k, height: k).fill()
            }
        }
    }

    /// Pixel art from rows of characters, `colors` naming each one's fill; anything else is left clear.
    static func pixels(_ rows: [String], _ colors: [Character: NSColor], at o: NSPoint, scale k: CGFloat = 1) {
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let c = colors[ch] else { continue }
                c.setFill()
                NSRect(x: o.x + CGFloat(x) * k, y: o.y + CGFloat(y) * k, width: k, height: k).fill()
            }
        }
    }

    /// The card's 16 pt pixel ghost and MS-DOS box.
    static let ghostPixels = [
        ".....kkkkkk.....", "....kwwwwwwk....", "...kwwwwwwwwk...", "..kwwwwwwwwwwk..", "..kwwwwwwwwwwk..", "..kwwkkwwkkwwk..",
        "..kwwkkwwkkwwk..", "..kwwkkwwkkwwk..", "..kwwwwwwwwwwk..", "..kwwwwwwwwwwk..", "..kwwwwwwwwwwk..", "..kwwwwwwwwwwk..",
        "..kwwwwwwwwwwk..", "....w.w..w.w....",
    ]
    static let dosPixels = [
        "................", "kkkkkkkkkkkkkkkk", "kbbbbbbbbbbbbbbk", "kbbbbbbbbbbbbbbk", "kkkkkkkkkkkkkkkk", "kkkkkkkkkkkkkkkk",
        "kkgkkkkkkkkkkkkk", "kkkgkkkkkkkkkkkk", "kkgkkkkkkkkkkkkk", "kkkkkggggkkkkkkk", "kkkkkkkkkkkkkkkk", "kkkkkkkkkkkkkkkk",
        "kkkkkkkkkkkkkkkk", "kkkkkkkkkkkkkkkk", "kkkkkkkkkkkkkkkk", "................",
    ]

    /// Over what is there, so a theme's see-through colours layer as they do in the mockups.
    static func fill(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        rect.fill(using: .sourceOver)
    }

    /// The Claude mark from the mockup's 24×24 SVG path, scaled into `rect`.
    static func claudeMark(in rect: NSRect) {
        let pts: [(CGFloat, CGFloat)] = [
            (12, 2), (13.6, 8.1), (19.8, 4), (15.9, 9.6), (22, 12), (15.9, 13.6), (19.8, 19.2), (13.6, 15.1),
            (12, 22), (10.4, 15.1), (4.2, 19.2), (8.1, 13.6), (2, 12), (8.1, 9.6), (4.2, 4), (10.4, 8.1),
        ]
        let s = rect.width / 24
        let path = NSBezierPath()
        for (i, p) in pts.enumerated() {
            let q = NSPoint(x: rect.minX + p.0 * s, y: rect.minY + p.1 * s)
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        path.close()
        Tok.Color.claude.setFill()
        path.fill()
    }

    /// The OpenAI mark from Codex.app (see macos/Resources/README.md): 1x and 2x reps, a template image.
    static let openAIMark: NSImage? = {
        let img = Bundle.main.image(forResource: "openai-mark")
        img?.isTemplate = true
        return img
    }()

    /// The mark's native size; drawn at it on whole pixels, neither rep is resampled.
    static var openAIMarkSize: CGFloat { openAIMark?.size.width ?? Tok.App.openAIMarkFallback }

    /// The Codex icon: the OpenAI mark tinted `color`. `rect` should be backing-aligned and mark-sized.
    static func codexMark(in rect: NSRect, color: NSColor, ctx: CGContext) {
        guard let img = openAIMark else { return }
        // Tinted off to the side: a transparency layer in the view's own context dithers everything it draws.
        let mark = tintedMarks[color] ?? {
            let t = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                color.setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tintedMarks[color] = t
            return t
        }()
        mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static var tintedMarks: [NSColor: NSImage] = [:]
}
