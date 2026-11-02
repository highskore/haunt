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

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        cached(.ui, size, weight) { NSFont.systemFont(ofSize: size, weight: weight) }
    }

    static func uiTabular(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        cached(.tabular, size, weight) { NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) }
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
    private static var ellipses: [[ObjectIdentifier]: (NSFont, NSColor, CTLine)] = [:]

    private static func ellipsis(_ font: NSFont, _ color: NSColor) -> CTLine {
        let key = [ObjectIdentifier(font), ObjectIdentifier(color)]
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

    static func fill(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        rect.fill()
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
    static var openAIMarkSize: CGFloat { openAIMark?.size.width ?? 18 }

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
