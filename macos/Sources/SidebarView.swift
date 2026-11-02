import AppKit

/// Mockup 06's grouped flat sidebar, drawn from a core `SidebarSnapshot`.
final class SidebarView: NSView, NSTextFieldDelegate {
    var snapshot = SidebarSnapshot(groups: [], colorStyle: .dot) { didSet { relayout() } }
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    /// Agents view 01's list: the window's background and no right hairline.
    var panel = false { didSet { needsDisplay = true } }
    /// A rename saved from the inline editor; an empty name means back to the automatic one.
    var onRename: ((String, String) -> Void)?
    /// The editor closed, saved or not; focus can go back to the terminal.
    var onRenameEnd: (() -> Void)?
    /// Plugin entries for a row's context menu, built when it opens, and the one chosen.
    var rowMenu: ((String) -> [RowMenuItem])?
    var onRowMenu: ((RowMenuItem, String) -> Void)?
    /// A drag dropped the row into a group (`SidebarGroup.id`) above a row, or at its end; nil turns dragging off.
    var onRowMoved: ((_ surfaceId: String, _ groupId: String, _ before: String?) -> Void)?

    // No mockup has row hover: a × in the status slot, meta grey, primary while the pointer is on it.
    // HAUNT_ROW_HOVER=<n> pins hover on the nth row (1-based); <n>x also pins it on the ×.
    private static let pinned: (index: Int, onClose: Bool)? = {
        guard var v = ProcessInfo.processInfo.environment["HAUNT_ROW_HOVER"] else { return nil }
        let x = v.hasSuffix("x")
        if x { v.removeLast() }
        return Int(v).map { ($0 - 1, x) }
    }()
    private var hoverId: String? { didSet { if hoverId != oldValue { needsDisplay = true } } }
    private var hoverClose = false { didSet { if hoverClose != oldValue { needsDisplay = true } } }
    private static let closeSize: CGFloat = 8

    private enum Item {
        case label(String, top: CGFloat, group: String)
        case row(Row, top: CGFloat, height: CGFloat, group: String)
    }

    private var items: [Item] = []

    static let suspiciousHint = "check terminal"

    override var isFlipped: Bool { true }

    /// Rows in display order, which ⌘1–9 follow.
    var orderedIds: [String] { snapshot.groups.flatMap { $0.rows.map(\.surfaceId) } }

    // CSS px → pt 1:1; line boxes use body's 1.5 line-height.
    private let lh = Tok.Font.baseLine
    private var rowLine1: CGFloat { max(Tok.Size.iconSize, Tok.Size.rowName * lh, Tok.Size.rowRight * lh) }
    private var labelHeight: CGFloat { Tok.Size.labelPad[0] + Tok.Size.labelFont * lh + Tok.Size.labelPad[2] }
    private var contentWidth: CGFloat { panel ? bounds.width : bounds.width - 1 }

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
                items.append(.label(g.label, top: y, group: g.id))
                y += labelHeight
            }
            for r in g.rows {
                let h = rowHeight(r)
                items.append(.row(r, top: y, height: h, group: g.id))
                y += h
            }
        }
        positionEditor()
        if let p = Self.pinned {
            let ids = orderedIds
            hoverId = ids.indices.contains(p.index) ? ids[p.index] : nil
            hoverClose = p.onClose
        }
        needsDisplay = true
    }

    /// The × in a row's status slot, centred on line 1.
    private func closeRect(top: CGFloat) -> NSRect {
        let d = Self.closeSize
        return NSRect(x: contentWidth - Tok.Size.rowPad[1] - d, y: top + Tok.Size.rowPad[0] + (rowLine1 - d) / 2,
                      width: d, height: d)
    }

    private func row(at p: NSPoint) -> (Row, CGFloat)? {
        for case let .row(row, top, height, _) in items where p.y >= top && p.y < top + height && p.x < contentWidth {
            return (row, top)
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        guard Self.pinned == nil else { return }
        hoverId = nil
        hoverClose = false
    }

    private func updateHover(_ event: NSEvent) {
        guard Self.pinned == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let hit = row(at: p)
        hoverId = hit?.0.surfaceId
        hoverClose = hit.map { closeRect(top: $0.1).insetBy(dx: -4, dy: -4).contains(p) } ?? false
    }

    /// Haunt's own Rename and Close, then the plugins' entries; an entry with a `parent` goes in that entry's submenu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let (row, _) = row(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let menu = NSMenu()
        // The agents view's list has nowhere to keep a name, so it offers no rename.
        let own = (panel ? [] : [("Rename Tab…", #selector(renameFromMenu(_:)))]) + [("Close Tab", #selector(closeFromMenu(_:)))]
        for (title, action) in own {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = row.surfaceId
            menu.addItem(item)
        }
        let entries = rowMenu?(row.surfaceId) ?? []
        if !entries.isEmpty { menu.addItem(.separator()) }
        let key = { (e: RowMenuItem) in "\(e.pluginId)\u{0}\(e.id)" }
        let parents = Set(entries.compactMap { e in e.parent.map { "\(e.pluginId)\u{0}\($0)" } })
        var submenus: [String: NSMenu] = [:]
        for e in entries.filter({ $0.parent == nil }) + entries.filter({ $0.parent != nil }) {
            let item = NSMenuItem(title: e.title, action: #selector(pluginItemFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.state = e.checked ? .on : .off
            item.representedObject = PluginMenuEntry(item: e, surfaceId: row.surfaceId)
            if parents.contains(key(e)) {
                let sub = NSMenu(title: e.title)
                submenus[key(e)] = sub
                item.submenu = sub
                item.action = nil
            }
            if let p = e.parent, let sub = submenus["\(e.pluginId)\u{0}\(p)"] {
                sub.addItem(item)
            } else if e.parent == nil {
                menu.addItem(item)
            }
        }
        return menu
    }

    private final class PluginMenuEntry: NSObject {
        let item: RowMenuItem, surfaceId: String
        init(item: RowMenuItem, surfaceId: String) {
            self.item = item
            self.surfaceId = surfaceId
        }
    }

    @objc private func pluginItemFromMenu(_ sender: NSMenuItem) {
        if let e = sender.representedObject as? PluginMenuEntry { onRowMenu?(e.item, e.surfaceId) }
    }

    @objc private func renameFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { beginRename(id) }
    }

    // MARK: Rename

    private var editor: (id: String, field: NSTextField)?
    var isRenaming: Bool { editor != nil }

    /// Where a row's name is drawn, widened to the row's right padding for editing.
    private func nameRect(top: CGFloat) -> NSRect {
        let col2 = Tok.Size.rowPad[1] + Tok.Size.iconSize + Tok.Size.rowGap[1]
        let h = Tok.Size.rowName * lh
        return NSRect(x: col2, y: top + Tok.Size.rowPad[0] + (rowLine1 - h) / 2,
                      width: contentWidth - Tok.Size.rowPad[1] - col2, height: h)
    }

    /// Edits the row's title in place, starting from `text` or the name it shows.
    func beginRename(_ id: String, text: String? = nil) {
        endRename(save: false)
        guard let row = snapshot.groups.lazy.flatMap(\.rows).first(where: { $0.surfaceId == id }) else { return }
        let field = NSTextField(string: text ?? row.name)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.font = Draw.ui(Tok.Size.rowName)
        field.textColor = Tok.Color.textPrimary
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byClipping
        field.delegate = self
        addSubview(field)
        editor = (id, field)
        positionEditor()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func positionEditor() {
        guard let (id, field) = editor else { return }
        guard case let .row(row, top, _, _)? = items.first(where: {
            if case let .row(r, _, _, _) = $0 { return r.surfaceId == id } else { return false }
        }) else { return endRename(save: false) }
        // The field's cell insets its text 2 pt and sizes its own line; centre that on the drawn name.
        let r = nameRect(top: top)
        let h = field.cell?.cellSize.height ?? r.height
        field.frame = NSRect(x: r.minX - 2, y: (r.midY - h / 2).rounded(), width: r.width + 2, height: h)
        field.backgroundColor = row.selected ? Tok.Color.rowSelected : Tok.Color.sidebarBg
    }

    private func endRename(save: Bool) {
        guard let (id, field) = editor else { return }
        editor = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        if save { onRename?(id, name) }
        onRenameEnd?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): endRename(save: true)
        case #selector(NSResponder.cancelOperation(_:)): endRename(save: false)
        default: return false
        }
        return true
    }

    /// Clicking away keeps what was typed, as Finder does.
    func controlTextDidEndEditing(_ obj: Notification) { endRename(save: true) }

    @objc private func closeFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onClose?(id) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(bounds, panel ? Tok.Color.windowBg : Tok.Color.sidebarBg)
        if !panel { Draw.fill(NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Tok.Color.hairline) }
        for item in items {
            switch item {
            case let .label(text, top, _):
                drawLabel(text, top: top, ctx: ctx)
            case let .row(row, top, height, _):
                drawRow(row, top: top, height: height, ctx: ctx)
            }
        }
        if let d = drop {
            Draw.fill(NSRect(x: Tok.Size.rowPad[1], y: d.y - 1, width: contentWidth - 2 * Tok.Size.rowPad[1], height: 2), Tok.Color.textPrimary)
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
        if let c = row.color, snapshot.colorStyle == .tint {
            Tok.Color.tab(c).withAlphaComponent(Tok.Color.tabTintAlpha).setFill()
            NSRect(x: 0, y: top, width: contentWidth, height: height).fill(using: .sourceOver)
        }
        let padY = Tok.Size.rowPad[0], padX = Tok.Size.rowPad[1]
        let gapY = Tok.Size.rowGap[0], gapX = Tok.Size.rowGap[1]
        let left = padX, right = contentWidth - padX
        let col2 = left + Tok.Size.iconSize + gapX
        var y = top + padY

        // Line 1: icon, name, status.
        let icon = NSRect(x: left, y: y + (rowLine1 - Tok.Size.iconSize) / 2, width: Tok.Size.iconSize, height: Tok.Size.iconSize)
        drawIcon(row.kind, in: icon, ctx: ctx)

        let statusFont = Draw.uiTabular(Tok.Size.rowRight)
        let statusColor = row.needsYou ? Tok.Color.needs : Tok.Color.textMeta
        let status = Draw.line(row.statusText, statusFont, statusColor)
        var statusW = Draw.width(status)
        if row.surfaceId == hoverId {
            let r = closeRect(top: top)
            statusW = r.width
            let x = NSBezierPath()
            x.move(to: NSPoint(x: r.minX, y: r.minY)); x.line(to: NSPoint(x: r.maxX, y: r.maxY))
            x.move(to: NSPoint(x: r.minX, y: r.maxY)); x.line(to: NSPoint(x: r.maxX, y: r.minY))
            x.lineWidth = 1.2
            x.lineCapStyle = .round
            (hoverClose ? Tok.Color.textPrimary : Tok.Color.textMeta).setStroke()
            x.stroke()
        } else {
            Draw.text(status, font: statusFont, x: right - statusW, top: y + (rowLine1 - Tok.Size.rowRight * lh) / 2,
                      lineHeight: Tok.Size.rowRight * lh, in: ctx)
        }

        let nameFont = Draw.ui(Tok.Size.rowName)
        let dot = snapshot.colorStyle == .dot ? row.color : nil
        let dotW = dot == nil ? 0 : gapX + Tok.Size.tabDot
        let nameMax = right - gapX - statusW - col2 - dotW
        let name = Draw.truncated(Draw.line(row.name, nameFont, Tok.Color.textPrimary), nameMax, nameFont, Tok.Color.textPrimary)
        Draw.text(name, font: nameFont, x: col2, top: y + (rowLine1 - Tok.Size.rowName * lh) / 2,
                  lineHeight: Tok.Size.rowName * lh, in: ctx)
        if let dot {
            let d = Tok.Size.tabDot
            Tok.Color.tab(dot).setFill()
            NSBezierPath(ovalIn: NSRect(x: col2 + Draw.width(name) + gapX, y: y + (rowLine1 - d) / 2, width: d, height: d)).fill()
        }
        y += rowLine1 + gapY

        // Line 2: meta, spanning columns 2–3. A suspicious request shows its preview (⏎ and all) and is
        // answered only in the terminal, so the hint stands where Allow/Deny would.
        let metaFont = Draw.ui(Tok.Size.rowMeta)
        var metaRight = right
        if let p = row.pending, p.suspicious {
            let hint = Draw.line(Self.suspiciousHint, metaFont, Tok.Color.textMeta)
            metaRight -= Draw.width(hint) + gapX
            Draw.text(hint, font: metaFont, x: right - Draw.width(hint), top: y, lineHeight: Tok.Size.rowMeta * lh, in: ctx)
        }
        let metaText = row.pending.flatMap { $0.suspicious ? $0.preview : nil } ?? row.meta
        let meta = Draw.truncated(Draw.line(metaText, metaFont, Tok.Color.textMeta), metaRight - col2, metaFont, Tok.Color.textMeta)
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
        case .codex:
            let s = Draw.openAIMarkSize
            let box = backingAlignedRect(NSRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s),
                                         options: .alignAllEdgesNearest)
            Draw.codexMark(in: box, color: Tok.Color.textPrimary, ctx: ctx)
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
        guard let (row, top) = row(at: p) else { return }
        // Only where the × is drawn: on the hovered row.
        if row.surfaceId == hoverId, closeRect(top: top).insetBy(dx: -4, dy: -4).contains(p) {
            onClose?(row.surfaceId)
        } else if !panel, event.clickCount == 2, nameRect(top: top).contains(p) {
            beginRename(row.surfaceId)
        } else {
            onSelect?(row.surfaceId)
            // A row needing you stays in NEEDS YOU, so it doesn't drag.
            if onRowMoved != nil, group(of: row.surfaceId) != Self.needsYouGroup { press = (row.surfaceId, p) }
        }
    }

    // MARK: Drag to reorder

    static let needsYouGroup = "needs-you"
    private var press: (id: String, at: NSPoint)?
    private var dragging = false
    /// Where the dragged row would land, and the y of the insertion line.
    private var drop: (group: String, before: String?, y: CGFloat)? { didSet { needsDisplay = true } }

    private func group(of id: String) -> String? {
        for case let .row(r, _, _, g) in items where r.surfaceId == id { return g }
        return nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragging, hypot(p.x - press.at.x, p.y - press.at.y) < 4 { return }
        dragging = true
        drop = target(at: p)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging, let id = press?.id, let d = drop { onRowMoved?(id, d.group, d.before) }
        press = nil
        dragging = false
        drop = nil
    }

    /// Above the row under the pointer or below it, by which half it is over; a label means its group's top.
    /// Nothing lands in NEEDS YOU.
    func target(at p: NSPoint) -> (group: String, before: String?, y: CGFloat)? {
        var found: (group: String, before: String?, y: CGFloat)?
        var last: (group: String, y: CGFloat)?
        for (i, item) in items.enumerated() {
            switch item {
            case let .label(_, top, g):
                if p.y >= top && p.y < top + labelHeight {
                    let first = items.dropFirst(i + 1).first.flatMap { if case let .row(r, _, _, rg) = $0, rg == g { r.surfaceId } else { nil } }
                    found = (g, first, top + labelHeight)
                }
            case let .row(r, top, h, g):
                last = (g, top + h)
                guard p.y >= top && p.y < top + h else { continue }
                if p.y < top + h / 2 {
                    found = (g, r.surfaceId, top)
                } else {
                    let next = items.dropFirst(i + 1).first.flatMap { if case let .row(n, _, _, ng) = $0, ng == g { n.surfaceId } else { nil } }
                    found = (g, next, top + h)
                }
            }
        }
        if found == nil, let last, p.y >= last.y { found = (last.group, nil, last.y) }
        return found?.group == Self.needsYouGroup ? nil : found
    }
}
