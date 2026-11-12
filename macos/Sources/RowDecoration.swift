import AppKit

/// A plugin's `Row.decoration`, laid out for the sidebar: a label or sparkline in the status slot,
/// a suffix after the meta line, and a bar in place of the task bar. The core already made the text plain.
struct RowDecor {
    static let sparkSize = NSSize(width: 56, height: 14)
    private static let sparkStroke: CGFloat = 1.5

    let label: CTLine?
    let kbd: Bool
    let spark: Spark?
    let suffix: String?
    let suffixColor: NSColor
    let bar: CGFloat?

    static var labelFont: NSFont { Draw.mono(Tok.Size.rowRight) }

    init?(_ d: Decoration?) {
        guard let d else { return nil }
        kbd = d.labelTone == .kbd && d.spark == nil
        label = d.spark == nil ? d.label.map { Draw.line($0, Self.labelFont, Self.color(d.labelTone, kbd: Tok.Color.textPrimary)) } : nil
        spark = d.spark
        suffix = d.suffix
        suffixColor = Self.color(d.suffixTone, kbd: Tok.Color.textPrimary)
        bar = d.barPermille.map { CGFloat(min($0, 1000)) / 1000 }
    }

    static func color(_ t: Tone, kbd: NSColor) -> NSColor {
        switch t {
        case .dim: return Tok.Color.textMeta
        case .text: return Tok.Color.textPrimary
        case .needs: return Tok.Color.needs
        case .kbd: return kbd
        }
    }

    /// Width of the status slot, or nil when the decoration leaves the status text there.
    var rightWidth: CGFloat? {
        if spark != nil { return Self.sparkSize.width }
        guard let label else { return nil }
        return Draw.width(label) + (kbd ? 2 * Tok.Size.paletteKbdPad[1] : 0)
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

    /// Draws the label or sparkline right-aligned at `right`, centred in a line box `height` tall at `top`.
    func drawRight(right: CGFloat, top: CGFloat, height: CGFloat, lineHeight: CGFloat, ctx: CGContext) {
        guard let w = rightWidth else { return }
        let x = right - w
        if let spark {
            drawSpark(spark, in: NSRect(x: x, y: top + (height - Self.sparkSize.height) / 2,
                                        width: Self.sparkSize.width, height: Self.sparkSize.height))
            return
        }
        guard let label else { return }
        let lt = top + (height - lineHeight) / 2
        if kbd {
            let box = NSRect(x: x, y: lt, width: w, height: lineHeight).insetBy(dx: 0.5, dy: 0.5)
            let p = NSBezierPath(roundedRect: box, xRadius: Tok.Size.paletteKbdRadius, yRadius: Tok.Size.paletteKbdRadius)
            p.lineWidth = 1
            Tok.Color.kbdBorder.setStroke()
            p.stroke()
        }
        Draw.text(label, font: Self.labelFont, x: x + (kbd ? Tok.Size.paletteKbdPad[1] : 0), top: lt, lineHeight: lineHeight, in: ctx)
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
        Self.color(s.tone, kbd: Tok.Color.textPrimary).setStroke()
        path.stroke()
    }
}
