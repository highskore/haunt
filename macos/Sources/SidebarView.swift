import AppKit

/// Mockup 06's grouped flat sidebar, drawn from a core `SidebarSnapshot`.
final class SidebarView: NSView, NSTextFieldDelegate {
    var snapshot = SidebarSnapshot(groups: [], colorStyle: .dot) { didSet { snapshotChanged(from: oldValue) } }
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
    /// The row under the pointer changed.
    var onHover: ((String?) -> Void)?
    /// A drag dropped the row into a group (`SidebarGroup.id`) above a row, or at its end; nil turns dragging off.
    var onRowMoved: ((_ surfaceId: String, _ groupId: String, _ before: String?) -> Void)?

    // No mockup has row hover: a × in the status slot, meta grey, primary while the pointer is on it.
    // HAUNT_ROW_HOVER=<n> pins hover on the nth row (1-based); <n>x also pins it on the ×.
    private static let pinned: (index: Int, onClose: Bool)? = {
        #if HAUNT_FIXTURES
        guard var v = ProcessInfo.processInfo.environment["HAUNT_ROW_HOVER"] else { return nil }
        let x = v.hasSuffix("x")
        if x { v.removeLast() }
        return Int(v).map { ($0 - 1, x) }
        #else
        return nil
        #endif
    }()
    private var hoverId: String? {
        didSet {
            guard hoverId != oldValue else { return }
            onHover?(hoverId)
            invalidateRow(oldValue)
            invalidateRow(hoverId)
            // Other plugins' labels that lost the row to `row_labels` order.
            let others = snapshot.groups.lazy.flatMap(\.rows).first { $0.surfaceId == self.hoverId }?.otherLabels ?? []
            toolTip = others.isEmpty ? nil : others.joined(separator: "\n")
        }
    }
    private var hoverClose = false { didSet { if hoverClose != oldValue { invalidateRow(hoverId) } } }

    private enum Item {
        case label(String, top: CGFloat, group: String)
        case row(Row, top: CGFloat, height: CGFloat, group: String)

        enum Shape: Equatable {
            case label(String, CGFloat, String)
            case row(String, CGFloat, CGFloat, String)
        }

        /// What decides the layout; rows with the same shape can be redrawn alone.
        var shape: Shape {
            switch self {
            case let .label(text, top, g): return .label(text, top, g)
            case let .row(r, top, h, g): return .row(r.surfaceId, top, h, g)
            }
        }
    }

    private var items: [Item] = []

    static let suspiciousHint = "check terminal"

    override var isFlipped: Bool { true }

    /// Rows in display order, which ⌘1–9 follow.
    var orderedIds: [String] { snapshot.groups.flatMap { $0.rows.map(\.surfaceId) } }

    // CSS px → pt 1:1; line boxes use body's 1.5 line-height.
    private var lh: CGFloat { Tok.Font.baseLine }
    private var rowLine1: CGFloat { max(Tok.Size.iconSize, Tok.Size.rowName * lh, Tok.Size.rowRight * lh) }
    private var labelHeight: CGFloat { Tok.Size.labelPad[0] + Tok.Size.labelFont * lh + Tok.Size.labelPad[2] }
    private var contentWidth: CGFloat { panel ? bounds.width : bounds.width - Tok.App.hairline }
    /// A row's text starts `[effects] row.inset` plus its padding in from the side.
    private var rowPadX: CGFloat { Theme.current.effects.rowInset + Tok.Size.rowPad[1] }

    private func bar(_ r: Row) -> Progress? {
        guard let p = r.progress, Theme.current.effects.barDone || p.total == 0 || p.done < p.total else { return nil }
        return p
    }

    private func rowHeight(_ r: Row) -> CGFloat {
        let gap = Tok.Size.rowGap[0]
        var h = rowLine1 + gap + Tok.Size.rowMeta * lh
        if bar(r) != nil || r.decoration?.barPermille != nil { h += gap + Tok.Size.barMt + Tok.Size.barH }
        h += CGFloat(r.subagents.count) * (gap + Tok.Size.subMt + Tok.Size.subFont * lh)
        return Tok.Size.rowPad[0] * 2 + h
    }

    private func relayout() {
        items = []
        let flat = snapshot.groups.first.map { $0.label.isEmpty } ?? false
        var y: CGFloat = flat ? Tok.Size.sidebarPadtopIconOnly : Tok.App.sidebarPadtop
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
        pruneLineCaches()
        positionEditor()
    }

    /// Same layout: only rows whose content changed are redrawn. Otherwise everything is.
    private func snapshotChanged(from oldSnapshot: SidebarSnapshot) {
        let old = items
        if snapshot.colorStyle != oldSnapshot.colorStyle { rowLines = [:] }
        relayout()
        if snapshot.colorStyle == oldSnapshot.colorStyle, old.map(\.shape) == items.map(\.shape),
           Self.agentCount(snapshot) == Self.agentCount(oldSnapshot) {
            for (a, b) in zip(old, items) {
                if case let .row(ra, top, h, _) = a, case let .row(rb, _, _, _) = b, ra != rb {
                    setNeedsDisplay(NSRect(x: 0, y: top - shadowReach, width: bounds.width, height: h + 2 * shadowReach))
                }
            }
        } else {
            needsDisplay = true
        }
        if let p = Self.pinned {
            let ids = orderedIds
            hoverId = ids.indices.contains(p.index) ? ids[p.index] : nil
            hoverClose = p.onClose
        }
    }

    private func invalidateRow(_ id: String?) {
        guard let id else { return }
        for case let .row(r, top, h, _) in items where r.surfaceId == id {
            setNeedsDisplay(NSRect(x: 0, y: top - shadowReach, width: bounds.width, height: h + 2 * shadowReach))
        }
    }

    /// The × in a row's status slot, centred on line 1.
    private func closeRect(top: CGFloat) -> NSRect {
        let d = Tok.App.closeSize
        return NSRect(x: contentWidth - rowPadX - d, y: top + Tok.Size.rowPad[0] + (rowLine1 - d) / 2,
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
        hoverClose = hit.map { closeRect(top: $0.1).insetBy(dx: -Tok.App.hitSlop, dy: -Tok.App.hitSlop).contains(p) } ?? false
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
        let col2 = rowPadX + Tok.Size.iconSize + Tok.Size.rowGap[1]
        let h = Tok.Size.rowName * lh
        return NSRect(x: col2, y: top + Tok.Size.rowPad[0] + (rowLine1 - h) / 2,
                      width: contentWidth - rowPadX - col2, height: h)
    }

    /// Edits the row's title in place, starting from `text` or the name it shows.
    func beginRename(_ id: String, text: String? = nil) {
        endRename(save: false)
        guard let row = snapshot.groups.lazy.flatMap(\.rows).first(where: { $0.surfaceId == id }) else { return }
        let field = NSTextField(string: text ?? row.name)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.font = Fonts.name
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
        // The field's cell sizes its own line; centre that on the drawn name.
        let r = nameRect(top: top)
        let h = field.cell?.cellSize.height ?? r.height
        field.frame = NSRect(x: r.minX - Tok.App.fieldInset, y: (r.midY - h / 2).rounded(), width: r.width + Tok.App.fieldInset, height: h)
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
        if !panel { Draw.fill(NSRect(x: bounds.width - Tok.App.hairline, y: 0, width: Tok.App.hairline, height: bounds.height), Tok.Color.hairline) }
        for item in items {
            switch item {
            case let .label(text, top, _):
                guard top < dirtyRect.maxY, top + labelHeight > dirtyRect.minY else { continue }
                drawLabel(text, top: top, ctx: ctx)
            case let .row(row, top, height, _):
                guard top - shadowReach < dirtyRect.maxY, top + height + shadowReach > dirtyRect.minY else { continue }
                drawRow(row, top: top, height: height, ctx: ctx)
            }
        }
        if Theme.current.effects.sidebarFooter, !panel { drawFooter(ctx) }
        if let d = drop {
            Draw.fill(NSRect(x: rowPadX, y: d.y - Tok.App.dropLine / 2,
                             width: contentWidth - 2 * rowPadX, height: Tok.App.dropLine), Tok.Color.textPrimary)
        }
    }

    static func agentCount(_ s: SidebarSnapshot) -> Int {
        s.groups.reduce(0) { $0 + $1.rows.filter { $0.kind != .shell }.count }
    }

    /// `[effects] sidebar.footer`: the live agent count, bottom left.
    private func drawFooter(_ ctx: CGContext) {
        let n = Self.agentCount(snapshot), pad = Tok.App.sidebarFootPad, size = Tok.App.sidebarFootFont
        let f = Draw.ui(size), lineH = size * lh
        let line = Draw.truncated(Draw.line(n == 1 ? "1 agent" : "\(n) agents", f, Tok.App.sidebarFootFg),
                                  contentWidth - 2 * pad[1], f, Tok.App.sidebarFootFg)
        Draw.text(line, font: f, x: pad[1], top: bounds.height - pad[2] - lineH, lineHeight: lineH, in: ctx)
    }

    /// Names for the row fonts; Draw keeps the only cache.
    private enum Fonts {
        static var label: NSFont {
            let w: [String: NSFont.Weight] = ["medium": .medium, "semibold": .semibold]
            return Draw.ui(Tok.Size.labelFont, w[Theme.current.effects.labelWeight] ?? .regular)
        }
        static var status: NSFont { Draw.uiTabular(Tok.Size.rowRight) }
        static var name: NSFont { Draw.ui(Tok.Size.rowName) }
        static var meta: NSFont { Draw.ui(Tok.Size.rowMeta) }
        static var sub: NSFont { Draw.ui(Tok.Size.subFont) }
        static var glyph: NSFont { Draw.mono(Tok.Size.iconGlyph) }
    }

    private lazy var shellGlyph = Draw.line(">_", Fonts.glyph, Tok.Color.iconFg)

    /// The caches hold lines in the old theme's fonts and colours.
    func themeDidChange() {
        rowLines = [:]
        labelLines = [:]
        shellGlyph = Draw.line(">_", Fonts.glyph, Tok.Color.iconFg)
        relayout()
        needsDisplay = true
    }
    private var labelLines: [String: CTLine] = [:]

    /// "NEEDS YOU" as "Needs you"; a label someone wrote in mixed case stays as written.
    static func labelCase(_ s: String) -> String {
        guard s == s.uppercased(), let first = s.first else { return s }
        return String(first) + s.dropFirst().lowercased()
    }

    private func drawLabel(_ text: String, top: CGFloat, ctx: CGContext) {
        let line = labelLines[text] ?? {
            let upper = Theme.current.effects.labelCase == "upper"
            let l = Draw.line(upper ? text.uppercased() : Self.labelCase(text), Fonts.label, Tok.Color.textLabel,
                              kern: upper ? Tok.Size.labelFont * Tok.Size.labelTrackingEm : 0)
            labelLines[text] = l
            return l
        }()
        Draw.text(line, font: Fonts.label, x: Tok.Size.labelPad[1], top: top + Tok.Size.labelPad[0],
                  lineHeight: Tok.Size.labelFont * lh, in: ctx)
    }

    /// A row's text, laid out once per change of the row, the width, or its hover (the × narrows the name).
    private struct RowLines {
        let row: Row, width: CGFloat, hovered: Bool
        let status: CTLine, statusW: CGFloat
        let name: CTLine
        /// The tab colour's dot after the name, in the dot style.
        let dot: TabColor?
        let hint: CTLine?
        let meta: CTLine
        let subs: [(label: CTLine, meta: CTLine, metaW: CGFloat)]
        let decor: RowDecor?
    }

    private var rowLines: [String: RowLines] = [:]
    /// The rows and labels the caches were last pruned to; most snapshots keep both.
    private var cachedIds: [String] = [], cachedLabels: [String] = []

    private func pruneLineCaches() {
        let ids = orderedIds, labels = snapshot.groups.map(\.label)
        if ids != cachedIds {
            let live = Set(ids)
            rowLines = rowLines.filter { live.contains($0.key) }
            cachedIds = ids
        }
        if labels != cachedLabels {
            let live = Set(labels)
            labelLines = labelLines.filter { live.contains($0.key) }
            cachedLabels = labels
        }
    }

    private func lines(for row: Row) -> RowLines {
        let hovered = row.surfaceId == hoverId
        if let c = rowLines[row.surfaceId], c.row == row, c.width == contentWidth, c.hovered == hovered { return c }
        let padX = rowPadX, gapX = Tok.Size.rowGap[1]
        let right = contentWidth - padX
        let col2 = padX + Tok.Size.iconSize + gapX

        let pill = row.needsYou && Theme.current.effects.needsPill
        let status = pill ? Draw.line(row.statusText, Draw.uiTabular(Tok.Size.rowRight, .semibold), Theme.current.app.pillFg)
            : Draw.line(row.statusText, Fonts.status, row.needsYou ? Tok.Color.needs : Tok.Color.textMeta)
        let decor = RowDecor(row.decoration, statusWins: row.needsYou || row.pending != nil)
        let statusW = hovered ? Tok.App.closeSize
            : pill ? Draw.width(status) + 2 * Theme.current.app.pillPad[1] : decor?.rightWidth ?? Draw.width(status)
        let dot = snapshot.colorStyle == .dot ? row.color : nil
        let dotW = dot == nil ? 0 : gapX + Tok.Size.tabDot
        let name = Draw.truncated(Draw.line(row.name, Fonts.name, Tok.Color.textPrimary), right - gapX - statusW - col2 - dotW,
                                  Fonts.name, Tok.Color.textPrimary)

        // A suspicious request shows its preview (⏎ and all) and is answered only in the terminal,
        // so the hint stands where Allow/Deny would.
        var metaRight = right
        var hint: CTLine?
        if let p = row.pending, p.suspicious {
            let h = Draw.line(Self.suspiciousHint, Fonts.meta, Tok.Color.textMeta)
            metaRight -= Draw.width(h) + gapX
            hint = h
        }
        let preview = row.pending.flatMap { $0.suspicious ? $0.preview : nil }
        let metaLine = preview == nil && decor?.suffix != nil
            ? CTLineCreateWithAttributedString(decor!.meta(row.meta, font: Fonts.meta))
            : Draw.line(preview ?? row.meta, Fonts.meta, Tok.Color.textMeta)
        let meta = Draw.truncated(metaLine, metaRight - col2, Fonts.meta, Tok.Color.textMeta)

        let subs = row.subagents.map { s in
            let m = Draw.line(s.meta, Fonts.sub, Tok.Color.textSub)
            let mw = Draw.width(m)
            let label = Draw.truncated(Draw.line("↳ " + s.label, Fonts.sub, Tok.Color.textSub),
                                       right - col2 - mw - Tok.Size.subGap, Fonts.sub, Tok.Color.textSub)
            return (label: label, meta: m, metaW: mw)
        }
        let l = RowLines(row: row, width: contentWidth, hovered: hovered, status: status, statusW: statusW,
                         name: name, dot: dot, hint: hint, meta: meta, subs: subs, decor: decor)
        rowLines[row.surfaceId] = l
        return l
    }

    private func drawRow(_ row: Row, top: CGFloat, height: CGFloat, ctx: CGContext) {
        let fx = Theme.current.effects
        let box = NSRect(x: fx.rowInset, y: top, width: contentWidth - 2 * fx.rowInset, height: height)
        let shape = NSBezierPath(roundedRect: box, xRadius: fx.rowRadius, yRadius: fx.rowRadius)
        if row.selected {
            if fx.rowRaised { drawRaised(shape, box) } else {
                Tok.Color.rowSelected.setFill()
                shape.fill()
            }
        } else if fx.rowHover && hoverId == row.surfaceId {
            Theme.current.app.rowHover.setFill()
            shape.fill()
        }
        if let c = row.color, snapshot.colorStyle == .tint {
            Tok.Color.tab(c).withAlphaComponent(Tok.Color.tabTintAlpha).setFill()
            shape.fill()
        }
        let l = lines(for: row)
        let padY = Tok.Size.rowPad[0], padX = rowPadX
        let gapY = Tok.Size.rowGap[0], gapX = Tok.Size.rowGap[1]
        let left = padX, right = contentWidth - padX
        let col2 = left + Tok.Size.iconSize + gapX
        var y = top + padY

        // Line 1: icon, name, status.
        let icon = NSRect(x: left, y: y + (rowLine1 - Tok.Size.iconSize) / 2, width: Tok.Size.iconSize, height: Tok.Size.iconSize)
        drawIcon(row.kind, in: icon, ctx: ctx)

        if l.hovered {
            let r = closeRect(top: top)
            let x = NSBezierPath()
            x.move(to: NSPoint(x: r.minX, y: r.minY)); x.line(to: NSPoint(x: r.maxX, y: r.maxY))
            x.move(to: NSPoint(x: r.minX, y: r.maxY)); x.line(to: NSPoint(x: r.maxX, y: r.minY))
            x.lineWidth = Tok.App.closeStroke
            x.lineCapStyle = .round
            (hoverClose ? Tok.Color.textPrimary : Tok.Color.textMeta).setStroke()
            x.stroke()
        } else if row.needsYou && fx.needsPill {
            let app = Theme.current.app, textH = Tok.Size.rowRight * lh, hl = Tok.App.hairline
            let r = NSRect(x: right - l.statusW, y: y + (rowLine1 - textH) / 2 - app.pillPad[0], width: l.statusW,
                           height: textH + 2 * app.pillPad[0])
            let rad = min(app.pillRadius, r.height / 2)
            app.pillBg.setFill()
            NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: hl / 4, dy: hl / 4), xRadius: rad - hl / 4, yRadius: rad - hl / 4)
            ring.lineWidth = hl / 2
            app.pillRing.setStroke()
            ring.stroke()
            Draw.text(l.status, font: Draw.uiTabular(Tok.Size.rowRight, .semibold), x: r.minX + app.pillPad[1],
                      top: r.minY + app.pillPad[0], lineHeight: textH, in: ctx)
        } else if let d = l.decor, d.rightWidth != nil {
            d.drawRight(right: right, top: y, height: rowLine1, lineHeight: Tok.Size.rowRight * lh, ctx: ctx)
        } else {
            Draw.text(l.status, font: Fonts.status, x: right - l.statusW, top: y + (rowLine1 - Tok.Size.rowRight * lh) / 2,
                      lineHeight: Tok.Size.rowRight * lh, in: ctx)
        }
        Draw.text(l.name, font: Fonts.name, x: col2, top: y + (rowLine1 - Tok.Size.rowName * lh) / 2,
                  lineHeight: Tok.Size.rowName * lh, in: ctx)
        if let dot = l.dot {
            let d = Tok.Size.tabDot
            Tok.Color.tab(dot).setFill()
            NSBezierPath(ovalIn: NSRect(x: col2 + Draw.width(l.name) + gapX, y: y + (rowLine1 - d) / 2, width: d, height: d)).fill()
        }
        y += rowLine1 + gapY

        // Line 2: meta, spanning columns 2–3.
        if let hint = l.hint {
            Draw.text(hint, font: Fonts.meta, x: right - Draw.width(hint), top: y, lineHeight: Tok.Size.rowMeta * lh, in: ctx)
        }
        Draw.text(l.meta, font: Fonts.meta, x: col2, top: y, lineHeight: Tok.Size.rowMeta * lh, in: ctx)
        y += Tok.Size.rowMeta * lh

        if let frac = l.decor?.bar ?? bar(row).map({ $0.total == 0 ? 0 : min(CGFloat($0.done) / CGFloat($0.total), 1) }) {
            y += gapY + Tok.Size.barMt
            let track = NSRect(x: col2, y: y, width: right - col2, height: Tok.Size.barH)
            drawBar(track, fill: NSRect(x: col2, y: y, width: track.width * frac, height: Tok.Size.barH))
            y += Tok.Size.barH
        }

        for s in l.subs {
            y += gapY + Tok.Size.subMt
            Draw.text(s.label, font: Fonts.sub, x: col2, top: y, lineHeight: Tok.Size.subFont * lh, in: ctx)
            Draw.text(s.meta, font: Fonts.sub, x: right - s.metaW, top: y, lineHeight: Tok.Size.subFont * lh, in: ctx)
            y += Tok.Size.subFont * lh
        }
    }

    /// `[effects] row.raised`: the fill with a soft shadow under it, a ring, and a highlight along the top.
    private func drawRaised(_ shape: NSBezierPath, _ box: NSRect) {
        let app = Theme.current.app, hl = Tok.App.hairline, r = Theme.current.effects.rowRadius
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = app.rowRaisedShadow
        shadow.shadowBlurRadius = app.rowRaisedBlur
        shadow.shadowOffset = NSSize(width: 0, height: -app.rowRaisedDrop)
        shadow.set()
        Tok.Color.rowSelected.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        Draw.fill(NSRect(x: box.minX, y: box.minY, width: box.width, height: hl), app.rowRaisedHighlight)
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(roundedRect: box.insetBy(dx: hl / 4, dy: hl / 4), xRadius: max(r - hl / 4, 0), yRadius: max(r - hl / 4, 0))
        ring.lineWidth = hl / 2
        app.rowRaisedRing.setStroke()
        ring.stroke()
    }

    /// The progress bar, with `[effects] bar.radius` and `bar.glow`.
    private func drawBar(_ track: NSRect, fill: NSRect) {
        let fx = Theme.current.effects, r = min(fx.barRadius, track.height / 2)
        guard r > 0 || fx.barGlow else {
            Draw.fill(track, Tok.Color.barTrack)
            Draw.fill(fill, Tok.Color.barFill)
            return
        }
        Tok.Color.barTrack.setFill()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
        guard fill.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        if fx.barGlow {
            let glow = NSShadow()
            glow.shadowColor = Tok.Color.barFill.withAlphaComponent(0.7)
            glow.shadowBlurRadius = Theme.current.app.barGlow
            glow.set()
        }
        Tok.Color.barFill.setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// How far a raised row's shadow reaches past it, for redrawing.
    private var shadowReach: CGFloat {
        Theme.current.effects.rowRaised ? Theme.current.app.rowRaisedBlur + Theme.current.app.rowRaisedDrop : 0
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
            let glyphLH = Tok.Size.iconGlyph * lh
            Draw.text(shellGlyph, font: Fonts.glyph, x: r.midX - Draw.width(shellGlyph) / 2, top: r.midY - glyphLH / 2,
                      lineHeight: glyphLH, in: ctx)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (row, top) = row(at: p) else { return }
        // Only where the × is drawn: on the hovered row.
        if row.surfaceId == hoverId, closeRect(top: top).insetBy(dx: -Tok.App.hitSlop, dy: -Tok.App.hitSlop).contains(p) {
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
        if !dragging, hypot(p.x - press.at.x, p.y - press.at.y) < Tok.App.dragSlop { return }
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
