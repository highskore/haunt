import AppKit

/// A plugin's `Row.decoration`, laid out for the sidebar: a label or sparkline in the status slot,
/// a suffix after the meta line, and a bar in place of the task bar. The core already made the text plain.
struct RowDecor {
    static let sparkSize = NSSize(width: 56, height: 14)
    private static let sparkStroke: CGFloat = 1.5

    let label: CTLine?
    let spark: Spark?
    let suffix: String?
    let suffixColor: NSColor
    let bar: CGFloat?

    static var labelFont: NSFont { Draw.mono(Tok.Size.rowRight) }

    /// `statusWins`: the row needs you or has a request, so haunt's status owns it and only the bar
    /// is kept (the core drops the rest there too).
    init?(_ d: Decoration?, statusWins: Bool) {
        guard let d else { return nil }
        spark = statusWins ? nil : d.spark
        label = spark == nil && !statusWins ? d.label.map { Draw.line($0, Self.labelFont, Self.color(d.labelTone)) } : nil
        suffix = statusWins ? nil : d.suffix
        suffixColor = Self.color(d.suffixTone)
        bar = d.barPermille.map { CGFloat(min($0, 1000)) / 1000 }
    }

    /// Never haunt's needs-you colour: `warn` is its own orange.
    static func color(_ t: Tone) -> NSColor {
        switch t {
        case .dim: return Tok.Color.textMeta
        case .text: return Tok.Color.textPrimary
        case .warn: return Tok.App.pluginWarn
        }
    }

    /// Width of the status slot, or nil when the decoration leaves the status text there.
    var rightWidth: CGFloat? {
        if spark != nil { return Self.sparkSize.width }
        return label.map(Draw.width)
    }

    /// `meta` and the suffix as one line, " · " between them.
    func meta(_ meta: String, font: NSFont) -> NSAttributedString {
        let s = NSMutableAttributedString(string: meta, attributes: [.font: font, .foregroundColor: Tok.Color.textMeta])
        if let suffix {
            if !meta.isEmpty { s.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: Tok.Color.textMeta])) }
            s.append(NSAttributedString(string: suffix, attributes: [.font: font, .foregroundColor: suffixColor]))
        }
        return s
    }

    /// `meta(_:font:)` cut to `room`: the meta gives way first, so the suffix stays whole while it fits alone; a
    /// suffix too wide even alone keeps its end, where a ticker's newest step is.
    func meta(_ meta: String, font: NSFont, room: CGFloat) -> NSAttributedString {
        let whole = self.meta(meta, font: font)
        guard let suffix, Self.tooWide(whole, room) else { return whole }
        let head = Array(meta), tail = Array(suffix)
        if let s = Self.longest(head.count, room, { k in
            let h = String(head[..<k]).trimmingCharacters(in: .whitespaces)
            return self.meta(h.isEmpty ? "" : h + "…", font: font)
        }) { return s }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: suffixColor]
        return Self.longest(tail.count, room) { k in
            NSAttributedString(string: "…" + String(tail[(tail.count - k)...]).trimmingCharacters(in: .whitespaces), attributes: attrs)
        } ?? whole
    }

    private static func tooWide(_ s: NSAttributedString, _ room: CGFloat) -> Bool {
        Draw.width(CTLineCreateWithAttributedString(s)) > room
    }

    /// The widest `make(k)`, k under `n`, that fits `room`; widths grow with k.
    private static func longest(_ n: Int, _ room: CGFloat, _ make: (Int) -> NSAttributedString) -> NSAttributedString? {
        var lo = 0, hi = n - 1, best: NSAttributedString?
        while lo <= hi {
            let mid = (lo + hi) / 2, s = make(mid)
            if !tooWide(s, room) { best = s; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    /// Draws the label or sparkline right-aligned at `right`, centred in a line box `height` tall at `top`.
    func drawRight(right: CGFloat, top: CGFloat, height: CGFloat, lineHeight: CGFloat, ctx: CGContext) {
        guard let w = rightWidth else { return }
        let x = right - w
        if let spark {
            drawSpark(spark, in: NSRect(x: x, y: top + (height - Self.sparkSize.height) / 2,
                                        width: Self.sparkSize.width, height: Self.sparkSize.height))
        } else if let label {
            Draw.text(label, font: Self.labelFont, x: x, top: top + (height - lineHeight) / 2, lineHeight: lineHeight, in: ctx)
        }
    }

    /// A polyline over the points, oldest at the left; 0 is the bottom (the view is flipped).
    private func drawSpark(_ s: Spark, in r: NSRect) {
        let pts = s.points
        guard !pts.isEmpty else { return }
        let inset = Self.sparkStroke / 2
        let h = r.height - 2 * inset
        let y = { (v: UInt8) in r.maxY - inset - CGFloat(v) / 255 * h }
        let path = NSBezierPath()
        if pts.count == 1 {
            path.move(to: NSPoint(x: r.minX, y: y(pts[0])))
            path.line(to: NSPoint(x: r.maxX, y: y(pts[0])))
        } else {
            let step = r.width / CGFloat(pts.count - 1)
            for (i, v) in pts.enumerated() {
                let p = NSPoint(x: r.minX + CGFloat(i) * step, y: y(v))
                i == 0 ? path.move(to: p) : path.line(to: p)
            }
        }
        path.lineWidth = Self.sparkStroke
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        Self.color(s.tone).setStroke()
        path.stroke()
    }
}
