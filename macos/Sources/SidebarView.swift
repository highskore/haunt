import AppKit

/// Mockup 06's grouped flat sidebar, drawn from a core `SidebarSnapshot`.
final class SidebarView: NSView {
    var snapshot = SidebarSnapshot(groups: []) { didSet { relayout() } }
    var onSelect: ((String) -> Void)?

    private enum Item {
        case label(String, top: CGFloat)
        case row(Row, top: CGFloat, height: CGFloat)
    }

    private var items: [Item] = []

    override var isFlipped: Bool { true }

    /// Rows in display order, which ⌘1–9 follow.
    var orderedIds: [String] { snapshot.groups.flatMap { $0.rows.map(\.surfaceId) } }

    // CSS px → pt 1:1; line boxes use body's 1.5 line-height.
    private let lh = Tok.Font.baseLine
    private var rowLine1: CGFloat { max(Tok.Size.iconSize, Tok.Size.rowName * lh, Tok.Size.rowRight * lh) }
    private var labelHeight: CGFloat { Tok.Size.labelPad[0] + Tok.Size.labelFont * lh + Tok.Size.labelPad[2] }
    private var contentWidth: CGFloat { bounds.width - 1 }

    private func rowHeight(_ r: Row) -> CGFloat {
        let gap = Tok.Size.rowGap[0]
        var h = rowLine1 + gap + Tok.Size.rowMeta * lh
        if r.progress != nil { h += gap + Tok.Size.barMt + Tok.Size.barH }
        h += CGFloat(r.subagents.count) * (gap + Tok.Size.subMt + Tok.Size.subFont * lh)
        return Tok.Size.rowPad[0] * 2 + h
    }

    private func relayout() {
        items = []
        let flat = snapshot.groups.first.map { $0.label.isEmpty } ?? false
        var y: CGFloat = flat ? Tok.Size.sidebarPadtopIconOnly : 0
        for g in snapshot.groups {
            if !g.label.isEmpty {
                items.append(.label(g.label, top: y))
                y += labelHeight
            }
            for r in g.rows {
                let h = rowHeight(r)
                items.append(.row(r, top: y, height: h))
                y += h
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(bounds, Tok.Color.sidebarBg)
        Draw.fill(NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Tok.Color.hairline)
        for item in items {
            switch item {
            case let .label(text, top):
                drawLabel(text, top: top, ctx: ctx)
            case let .row(row, top, height):
                drawRow(row, top: top, height: height, ctx: ctx)
            }
        }
    }

    private func drawLabel(_ text: String, top: CGFloat, ctx: CGContext) {
        let font = Draw.ui(Tok.Size.labelFont)
        let line = Draw.line(text.uppercased(), font, Tok.Color.textLabel, kern: Tok.Size.labelFont * Tok.Size.labelTrackingEm)
        Draw.text(line, font: font, x: Tok.Size.labelPad[1], top: top + Tok.Size.labelPad[0],
                  lineHeight: Tok.Size.labelFont * lh, in: ctx)
    }

    private func drawRow(_ row: Row, top: CGFloat, height: CGFloat, ctx: CGContext) {
        if row.selected {
            Draw.fill(NSRect(x: 0, y: top, width: contentWidth, height: height), Tok.Color.rowSelected)
        }
        let padY = Tok.Size.rowPad[0], padX = Tok.Size.rowPad[1]
        let gapY = Tok.Size.rowGap[0], gapX = Tok.Size.rowGap[1]
        let left = padX, right = contentWidth - padX
        let col2 = left + Tok.Size.iconSize + gapX
        var y = top + padY

        // Line 1: icon, name, status.
        let icon = NSRect(x: left, y: y + (rowLine1 - Tok.Size.iconSize) / 2, width: Tok.Size.iconSize, height: Tok.Size.iconSize)
        drawIcon(row.kind, in: icon, ctx: ctx)

        let statusFont = row.needsYou ? Draw.uiTabular(Tok.Size.rowRight, .bold) : Draw.uiTabular(Tok.Size.rowRight)
        let statusColor = row.needsYou ? Tok.Color.needs : Tok.Color.textMeta
        let status = Draw.line(row.statusText, statusFont, statusColor)
        let statusW = Draw.width(status)
        Draw.text(status, font: statusFont, x: right - statusW, top: y + (rowLine1 - Tok.Size.rowRight * lh) / 2,
                  lineHeight: Tok.Size.rowRight * lh, in: ctx)

        let nameFont = Draw.ui(Tok.Size.rowName)
        let nameMax = right - gapX - statusW - col2
        let name = Draw.truncated(Draw.line(row.name, nameFont, Tok.Color.textPrimary), nameMax, nameFont, Tok.Color.textPrimary)
        Draw.text(name, font: nameFont, x: col2, top: y + (rowLine1 - Tok.Size.rowName * lh) / 2,
                  lineHeight: Tok.Size.rowName * lh, in: ctx)
        y += rowLine1 + gapY

        // Line 2: meta, spanning columns 2–3.
        let metaFont = Draw.ui(Tok.Size.rowMeta)
        let meta = Draw.truncated(Draw.line(row.meta, metaFont, Tok.Color.textMeta), right - col2, metaFont, Tok.Color.textMeta)
        Draw.text(meta, font: metaFont, x: col2, top: y, lineHeight: Tok.Size.rowMeta * lh, in: ctx)
        y += Tok.Size.rowMeta * lh

        if let p = row.progress {
            y += gapY + Tok.Size.barMt
            let track = NSRect(x: col2, y: y, width: right - col2, height: Tok.Size.barH)
            Draw.fill(track, Tok.Color.barTrack)
            let frac = p.total == 0 ? 0 : min(CGFloat(p.done) / CGFloat(p.total), 1)
            Draw.fill(NSRect(x: col2, y: y, width: track.width * frac, height: Tok.Size.barH), Tok.Color.barFill)
            y += Tok.Size.barH
        }

        let subFont = Draw.ui(Tok.Size.subFont)
        for s in row.subagents {
            y += gapY + Tok.Size.subMt
            let metaLine = Draw.line(s.meta, subFont, Tok.Color.textSub)
            let mw = Draw.width(metaLine)
            let label = Draw.truncated(Draw.line("↳ " + s.label, subFont, Tok.Color.textSub),
                                       right - col2 - mw - Tok.Size.subGap, subFont, Tok.Color.textSub)
            Draw.text(label, font: subFont, x: col2, top: y, lineHeight: Tok.Size.subFont * lh, in: ctx)
            Draw.text(metaLine, font: subFont, x: right - mw, top: y, lineHeight: Tok.Size.subFont * lh, in: ctx)
            y += Tok.Size.subFont * lh
        }
    }

    private func drawIcon(_ kind: RowKind, in r: NSRect, ctx: CGContext) {
        switch kind {
        case .claude:
            let s = Tok.Size.claudeIcon
            Draw.claudeMark(in: NSRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s))
        case .shell:
            Tok.Color.iconBg.setFill()
            NSBezierPath(roundedRect: r, xRadius: Tok.Size.iconRadius, yRadius: Tok.Size.iconRadius).fill()
            let font = Draw.mono(Tok.Size.iconGlyph)
            let line = Draw.line(">_", font, Tok.Color.iconFg)
            let glyphLH = Tok.Size.iconGlyph * lh
            Draw.text(line, font: font, x: r.midX - Draw.width(line) / 2, top: r.midY - glyphLH / 2,
                      lineHeight: glyphLH, in: ctx)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for case let .row(row, top, height) in items where p.y >= top && p.y < top + height {
            onSelect?(row.surfaceId)
            return
        }
    }
}
