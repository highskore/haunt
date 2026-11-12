import AppKit

/// A plugin's row above every sidebar group (`SidebarSnapshot.top`), laid out like a tab row as in the
/// Focus block mockup: a hollow dot in the icon column, the title, a right-hand text, a sub line and a bar.
final class TopRowView: NSView {
    var row: TopRow? {
        didSet {
            guard row != oldValue else { return }
            needsDisplay = true
            superview?.needsLayout = true
        }
    }
    /// A click on a row whose plugin asked for one.
    var onClick: ((String) -> Void)?

    private let lh = Tok.Font.baseLine
    private static let dot: CGFloat = 7

    override var isFlipped: Bool { true }

    private var line1: CGFloat { max(Tok.Size.iconSize, Tok.Size.rowName * lh, Tok.Size.rowRight * lh) }

    /// Zero with no row.
    var height: CGFloat {
        guard let row else { return 0 }
        var h = line1
        if row.sub != nil { h += Tok.Size.rowGap[0] + Tok.Size.rowMeta * lh }
        if row.barPermille != nil { h += Tok.Size.rowGap[0] + Tok.Size.barMt + Tok.Size.barH }
        return Tok.Size.rowPad[0] * 2 + h
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(bounds, Tok.Color.sidebarBg)
        Draw.fill(NSRect(x: bounds.width - Tok.App.hairline, y: 0, width: Tok.App.hairline, height: bounds.height), Tok.Color.hairline)
        let padX = Tok.Size.rowPad[1], gapX = Tok.Size.rowGap[1], gapY = Tok.Size.rowGap[0]
        let right = bounds.width - Tok.App.hairline - padX
        let col2 = padX + Tok.Size.iconSize + gapX
        var y = Tok.Size.rowPad[0]

        let d = Self.dot
        let ring = NSBezierPath(ovalIn: NSRect(x: padX + (Tok.Size.iconSize - d) / 2 + 0.5, y: y + (line1 - d) / 2 + 0.5, width: d - 1, height: d - 1))
        ring.lineWidth = 1
        Tok.Color.textMeta.setStroke()
        ring.stroke()

        var rightW: CGFloat = 0
        if let r = row.right {
            let t = Draw.line(r, Draw.mono(Tok.Size.rowRight), RowDecor.color(row.tone))
            rightW = Draw.width(t) + gapX
            Draw.text(t, font: Draw.mono(Tok.Size.rowRight), x: right - Draw.width(t), top: y + (line1 - Tok.Size.rowRight * lh) / 2,
                      lineHeight: Tok.Size.rowRight * lh, in: ctx)
        }
        let nameFont = Draw.ui(Tok.Size.rowName)
        let name = Draw.truncated(Draw.line(row.title, nameFont, Tok.Color.textPrimary), right - rightW - col2, nameFont, Tok.Color.textPrimary)
        Draw.text(name, font: nameFont, x: col2, top: y + (line1 - Tok.Size.rowName * lh) / 2, lineHeight: Tok.Size.rowName * lh, in: ctx)
        y += line1

        if let sub = row.sub {
            y += gapY
            let font = Draw.ui(Tok.Size.rowMeta)
            let t = Draw.truncated(Draw.line(sub, font, Tok.Color.textMeta), right - col2, font, Tok.Color.textMeta)
            Draw.text(t, font: font, x: col2, top: y, lineHeight: Tok.Size.rowMeta * lh, in: ctx)
            y += Tok.Size.rowMeta * lh
        }
        if let p = row.barPermille {
            y += gapY + Tok.Size.barMt
            let track = NSRect(x: col2, y: y, width: right - col2, height: Tok.Size.barH)
            Draw.fill(track, Tok.Color.barTrack)
            Draw.fill(NSRect(x: col2, y: y, width: track.width * CGFloat(min(p, 1000)) / 1000, height: Tok.Size.barH), Tok.Color.barFill)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let row, row.clickable { onClick?(row.pluginId) }
    }
}
