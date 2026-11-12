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
    private var labelHeight: CGFloat { groupBox ? Tok.Size.labelPad[0] : Tok.Size.labelPad[0] + Tok.Size.labelFont * lh + Tok.Size.labelPad[2] }
    /// `label.rule = "groupbox"`: each group in an etched box, its label on the top edge; the label's top padding
    /// is the space above the first row.
    private var groupBox: Bool { Theme.current.effects.labelRule == "groupbox" && !panel }
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
                if g.id != snapshot.groups.first?.id { y += Theme.current.app.labelSpace }
                items.append(.label(g.label, top: y, group: g.id))
                y += labelHeight
            }
            for r in g.rows {
                let h = rowHeight(r)
                items.append(.row(r, top: y, height: h, group: g.id))
                y += h
            }
            if groupBox && !g.label.isEmpty { y += Theme.current.app.groupPad + Theme.current.app.groupGap }
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
        if !panel {
            let w = max(Tok.App.hairline, Theme.current.app.sidebarEdge)
            Draw.fill(NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height), Tok.Color.hairline)
        }
        Layers.draw("sidebar", bounds, state: Layers.state(self), in: ctx)
        if groupBox { drawGroupBoxes() }
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
        if let top = footerTop, rowsBottom <= top {
            drawFooter(ctx)
        }
        if let d = drop {
            Draw.fill(NSRect(x: rowPadX, y: d.y - Tok.App.dropLine / 2,
                             width: contentWidth - 2 * rowPadX, height: Tok.App.dropLine), Tok.Color.textPrimary)
        }
    }

    static func agentCount(_ s: SidebarSnapshot) -> Int {
        s.groups.reduce(0) { $0 + $1.rows.filter { $0.kind != .shell }.count }
    }

    /// Where the footer starts, nil without one; it is drawn only when the rows end above it.
    private var footerTop: CGFloat? {
        guard !panel else { return nil }
        let pad = Tok.App.sidebarFootPad, textTop = bounds.height - pad[2] - Tok.App.sidebarFootFont * lh
        return Theme.current.effects.sidebarFooter ? textTop - pad[0] - Theme.current.app.sidebarFootArt : nil
    }

    private var rowsBottom: CGFloat {
        items.reduce(0) { bottom, item in
            if case let .row(_, top, h, _) = item { return max(bottom, top + h) }
            return bottom
        }
    }

    /// `[effects] sidebar.footer`: the live agent count (or `[strings] sidebar.foot`), at the bottom left or
    /// centred, under `app.sidebar.foot.art` points kept clear for the theme's layers.
    private func drawFooter(_ ctx: CGContext) {
        let n = Self.agentCount(snapshot), pad = Tok.App.sidebarFootPad, size = Tok.App.sidebarFootFont, app = Theme.current.app
        let f = Draw.ui(size), lineH = size * lh
        let text = Self.footText(agents: n, room: contentWidth - 2 * pad[1])
        let line = Draw.truncated(Draw.line(text, f, Tok.App.sidebarFootFg, kern: size * app.sidebarFootTracking),
                                  contentWidth - 2 * pad[1], f, Tok.App.sidebarFootFg)
        let band = app.sidebarFootArt + pad[0] + lineH + pad[2], top = bounds.height - pad[2] - lineH
        let x = app.sidebarFootAlign == "center" ? ((contentWidth - Draw.width(line)) / 2).rounded() : pad[1]
        Layers.draw("sidebar.footer", NSRect(x: 0, y: bounds.height - band, width: contentWidth, height: band),
                    textRun: NSRect(x: x, y: top, width: Draw.width(line), height: lineH),
                    text: [Layers.Run(rect: NSRect(x: x, y: top, width: Draw.width(line), height: lineH), ink: Tok.App.sidebarFootFg)],
                    state: Layers.state(self), in: ctx)
        Draw.text(line, font: f, x: x, top: top, lineHeight: lineH, in: ctx)
        let frame = Theme.current.app.sidebarFootFrame
        if frame.alphaComponent > 0 {
            // Boxed: the frame stands `foot.pad`'s top above the text and as far below it, `rowInset` in from the sides.
            let hl = Tok.App.hairline, inset = Theme.current.effects.rowInset
            let r = NSRect(x: inset, y: top - pad[0], width: contentWidth - 2 * inset, height: lineH + 2 * pad[0])
            let ring = NSBezierPath(rect: r.insetBy(dx: hl / 2, dy: hl / 2))
            ring.lineWidth = hl
            frame.setStroke()
            ring.stroke()
        }
    }

    // A theme's words are drawn whole or not at all: cut short, they could read as a status ("Done…").

    /// The foot's words: the theme's when they fit whole, else Haunt's count (which may be cut).
    static func footText(agents n: Int, room: CGFloat) -> String {
        let size = Tok.App.sidebarFootFont, f = Draw.ui(size)
        if let s = Theme.current.string("sidebar.foot", agents: n),
           Draw.width(Draw.line(s, f, .black, kern: size * Theme.current.app.sidebarFootTracking)) <= room { return s }
        return n == 1 ? "1 agent" : "\(n) agents"
    }

    /// A subagent's label after the theme's prefix, cut to fit here and checked exactly as drawn; if that could
    /// pass for a status, after Haunt's own prefix.
    static func subText(_ label: String, room: CGFloat) -> String {
        guard let p = Theme.current.string("row.sub.prefix") else { return "↳ " + label }
        let fits = { (s: String) in Draw.width(Draw.line(s, Fonts.sub, .black)) <= room }
        var text = p + label, cut = label
        while !fits(text), !cut.isEmpty {
            cut.removeLast()
            text = p + cut + "…"
        }
        return fits(text) && !Theme.statusCheck(text) ? text : "↳ " + label
    }

    /// Names for the row fonts; Draw keeps the only cache.
    private enum Fonts {
        static var label: NSFont {
            let w: [String: NSFont.Weight] = ["medium": .medium, "semibold": .semibold]
            return Draw.display(Tok.Size.labelFont) ?? Draw.ui(Tok.Size.labelFont, w[Theme.current.effects.labelWeight] ?? .regular)
        }
        static var status: NSFont { Draw.uiTabular(Tok.Size.rowRight) }
        static var name: NSFont {
            Theme.current.effects.nameFont == "display" ? Draw.display(Tok.Size.rowName) ?? Draw.ui(Tok.Size.rowName) : Draw.ui(Tok.Size.rowName)
        }
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

    /// Each labelled group's etched box, from its label's top to its last row plus `app.group.pad`.
    private func drawGroupBoxes() {
        var spans: [String: (top: CGFloat, bottom: CGFloat)] = [:]
        for item in items {
            switch item {
            case let .label(_, top, g): spans[g] = (top, top)
            case let .row(_, top, h, g): if let s = spans[g] { spans[g] = (s.top, top + h) }
            }
        }
        let pad = Theme.current.app.groupPad
        for (_, s) in spans {
            Draw.bevel(NSRect(x: pad, y: s.top, width: contentWidth - 2 * pad, height: s.bottom + pad - s.top), "etched")
        }
    }

    private func drawLabel(_ text: String, top: CGFloat, ctx: CGContext) {
        let block = Theme.current.effects.labelRule == "block"
        let line = labelLines[text] ?? {
            let upper = Theme.current.effects.labelCase == "upper"
            let l = Draw.line(upper ? text.uppercased() : Self.labelCase(text), Fonts.label, block ? Theme.current.app.labelInk : Tok.Color.textLabel,
                              kern: upper ? Tok.Size.labelFont * Tok.Size.labelTrackingEm : 0)
            labelLines[text] = l
            return l
        }()
        let run = NSRect(x: Tok.Size.labelPad[1] + Theme.current.app.labelIndent, y: top + Tok.Size.labelPad[0], width: Draw.width(line), height: Tok.Size.labelFont * lh)
        // A boxed label straddles the box's top edge, its lower half over the slot; a block label sits on its own fill.
        let labelH = Tok.Size.labelFont * lh
        let label = groupBox ? Layers.Run(rect: NSRect(x: Theme.current.app.groupPad + Tok.Size.labelPad[1], y: top - labelH / 2, width: Draw.width(line), height: labelH),
                                          ink: Tok.Color.textLabel)
            : block ? Layers.Run(rect: run, ink: Theme.current.app.labelInk, on: Theme.current.app.labelFill) : Layers.Run(rect: run, ink: Tok.Color.textLabel)
        Layers.draw("label.group", NSRect(x: 0, y: top, width: contentWidth, height: labelHeight), within: bounds, textRun: run,
                    text: [label], state: Layers.state(self), in: ctx)
        if groupBox {
            // On the box's top edge, over a gap in it.
            let lineH = Tok.Size.labelFont * lh, x = Theme.current.app.groupPad + Tok.Size.labelPad[1]
            Draw.fill(NSRect(x: x - 3, y: top - 2, width: Draw.width(line) + 6, height: 4), Tok.Color.sidebarBg)
            return Draw.text(line, font: Fonts.label, x: x, top: top - lineH / 2, lineHeight: lineH, in: ctx)
        }
        let lineTop = top + Tok.Size.labelPad[0], lineH = Tok.Size.labelFont * lh
        if block {
            // Inverted: the label on its own fill, `label.pad`'s top above and below it; the rest of the bottom
            // pad is the space under the block.
            let x = Tok.Size.labelPad[1], padX = Theme.current.app.labelBlockPad
            Draw.fill(NSRect(x: x, y: top, width: Draw.width(line) + 2 * padX, height: 2 * Tok.Size.labelPad[0] + lineH), Theme.current.app.labelFill)
            return Draw.text(line, font: Fonts.label, x: x + padX, top: lineTop, lineHeight: lineH, in: ctx)
        }
        Draw.chromeText(line, font: Fonts.label, x: run.minX, top: lineTop, lineHeight: lineH, in: ctx)
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
        // `row.select = "cursor"`: the selected row's text all in the selection's ink.
        let ink: NSColor? = row.selected && Theme.current.effects.rowSelect == "cursor" ? Theme.current.app.rowSelectInk : nil
        let primary = ink ?? Tok.Color.textPrimary, metaInk = ink ?? Tok.Color.textMeta, subInk = ink ?? Tok.Color.textSub
        let status = pill ? Draw.line(row.statusText, Draw.uiTabular(Tok.Size.rowRight, .semibold), Theme.current.app.pillFg)
            : Draw.line(row.statusText, row.needsYou && Theme.current.effects.needsWeight == "bold" ? Draw.uiTabular(Tok.Size.rowRight, .bold) : Fonts.status,
                        row.needsYou ? Tok.Color.needs : metaInk)
        let decor = RowDecor(row.decoration, statusWins: row.needsYou || row.pending != nil)
        let statusW = hovered ? Tok.App.closeSize
            : pill ? Draw.width(status) + 2 * Theme.current.app.pillPad[1] : decor?.rightWidth ?? Draw.width(status)
        let dot = snapshot.colorStyle == .dot ? row.color : nil
        let dotW = dot == nil ? 0 : gapX + Tok.Size.tabDot
        let name = Draw.truncated(Draw.line(row.name, Fonts.name, primary), right - gapX - statusW - col2 - dotW, Fonts.name, primary)

        // A suspicious request shows its preview (⏎ and all) and is answered only in the terminal,
        // so the hint stands where Allow/Deny would.
        var metaRight = right
        var hint: CTLine?
        if let p = row.pending, p.suspicious {
            let h = Draw.line(Self.suspiciousHint, Fonts.meta, metaInk)
            metaRight -= Draw.width(h) + gapX
            hint = h
        }
        let preview = row.pending.flatMap { $0.suspicious ? $0.preview : nil }
        let metaLine = preview == nil && decor?.suffix != nil
            ? CTLineCreateWithAttributedString(decor!.meta(row.meta, font: Fonts.meta, room: metaRight - col2))
            : Draw.line(preview ?? row.meta, Fonts.meta, metaInk)
        let meta = Draw.truncated(metaLine, metaRight - col2, Fonts.meta, metaInk)

        let subs = row.subagents.map { s in
            let m = Draw.line(s.meta, Fonts.sub, subInk)
            let mw = Draw.width(m)
            let room = right - col2 - mw - Tok.Size.subGap
            let label = Draw.truncated(Draw.line(Self.subText(s.label, room: room), Fonts.sub, subInk), room, Fonts.sub, subInk)
            return (label: label, meta: m, metaW: mw)
        }
        let l = RowLines(row: row, width: contentWidth, hovered: hovered, status: status, statusW: statusW,
                         name: name, dot: dot, hint: hint, meta: meta, subs: subs, decor: decor)
        rowLines[row.surfaceId] = l
        return l
    }

    /// A row's text, line by line, in the colours it's drawn in: name and status, then meta and subagents.
    private func rowRuns(_ row: Row, _ l: RowLines, top: CGFloat, height: CGFloat) -> [Layers.Run] {
        let fx = Theme.current.effects, app = Theme.current.app
        let x = rowPadX, w = contentWidth - 2 * rowPadX
        let first = NSRect(x: x, y: top, width: w, height: rowLine1)
        let rest = NSRect(x: x, y: first.maxY, width: w, height: max(height - rowLine1, 0))
        let ink: NSColor? = row.selected && fx.rowSelect == "cursor" ? app.rowSelectInk : nil
        var runs: [Layers.Run] = []
        if row.selected && fx.rowSelect == "name" {
            runs.append(Layers.Run(rect: first, ink: app.rowSelectInk, on: app.rowSelectFill))
        } else {
            runs.append(Layers.Run(rect: first, ink: ink ?? Tok.Color.textPrimary))
        }
        if row.needsYou && fx.needsPill {
            let textH = Tok.Size.rowRight * lh
            let pill = NSRect(x: first.maxX - l.statusW, y: first.minY + (rowLine1 - textH) / 2, width: l.statusW, height: textH)
            runs.append(Layers.Run(rect: pill, ink: app.pillFg, on: app.pillBg))
        } else {
            runs.append(Layers.Run(rect: first, ink: row.needsYou ? Tok.Color.needs : ink ?? Tok.Color.textMeta))
        }
        runs.append(Layers.Run(rect: rest, ink: ink ?? Tok.Color.textMeta))
        if !l.subs.isEmpty { runs.append(Layers.Run(rect: rest, ink: ink ?? Tok.Color.textSub)) }
        if let d = row.decoration, d.labelTone == .warn || d.suffixTone == .warn {
            runs += [first, rest].map { Layers.Run(rect: $0, ink: Tok.App.pluginWarn) }
        }
        return runs
    }

    private func drawRow(_ row: Row, top: CGFloat, height: CGFloat, ctx: CGContext) {
        let fx = Theme.current.effects
        let box = NSRect(x: fx.rowInset, y: top, width: contentWidth - 2 * fx.rowInset, height: height)
        let shape = NSBezierPath(roundedRect: box, xRadius: fx.rowRadius, yRadius: fx.rowRadius)
        if row.selected {
            if fx.rowSelect == "name" || fx.rowSelect == "none" {
                // "name" is drawn with the name, below; "none" by the theme's layers.
            } else if fx.rowSelect == "cursor" {
                Draw.fill(box, Theme.current.app.rowSelectFill)
            } else {
                Tok.Color.rowSelected.setFill()
                shape.fill()
            }
        }
        if let c = row.color, snapshot.colorStyle == .tint {
            Tok.Color.tab(c).withAlphaComponent(Tok.Color.tabTintAlpha).setFill()
            shape.fill()
        }
        let l = lines(for: row)
        let hover = hoverId == row.surfaceId, state = Layers.state(self, selected: row.selected, hover: hover)
        let padY = Tok.Size.rowPad[0], padX = rowPadX
        let text = rowRuns(row, l, top: top + padY, height: height - 2 * padY)
        // What the row is filled with under its layers; each row's layers stay in its own box.
        var base: [NSColor] = []
        if row.selected && fx.rowSelect == "cursor" { base.append(Theme.current.app.rowSelectFill) }
        if row.selected && ["fill", "brackets"].contains(fx.rowSelect) { base.append(Tok.Color.rowSelected) }
        if let c = row.color, snapshot.colorStyle == .tint { base.append(Tok.Color.tab(c).withAlphaComponent(Tok.Color.tabTintAlpha)) }
        let rowClip = box.intersection(bounds)
        Layers.draw("row", box, within: rowClip, text: text, base: base, state: state, in: ctx)
        if row.selected && !Layers.draw("row.selected", box, within: rowClip, text: text, base: base, state: state, in: ctx) && fx.rowSelect == "none" {
            // The theme's layers were the selection; with them off or skipped, Haunt's fill stands in, under the status too.
            Tok.Color.rowSelected.setFill()
            shape.fill()
            base.append(Tok.Color.rowSelected)
        }
        if hover && !row.selected { Layers.draw("row.hover", box, within: rowClip, text: text, base: base, state: state, in: ctx) }
        let gapY = Tok.Size.rowGap[0], gapX = Tok.Size.rowGap[1]
        let left = padX, right = contentWidth - padX
        let col2 = left + Tok.Size.iconSize + gapX
        var y = top + padY

        // Line 1: icon, name, status.
        let icon = NSRect(x: left, y: y + (rowLine1 - Tok.Size.iconSize) / 2, width: Tok.Size.iconSize, height: Tok.Size.iconSize)
        if row.needsYou && !l.hovered {
            let textH = Tok.Size.rowRight * lh
            let run = NSRect(x: right - l.statusW, y: y + (rowLine1 - textH) / 2, width: l.statusW, height: textH)
            // A pill's text sits on the pill, drawn after, over whatever the layer leaves through it.
            let ink = fx.needsPill ? Layers.Run(rect: run, ink: Theme.current.app.pillFg, on: Theme.current.app.pillBg) : Layers.Run(rect: run, ink: Tok.Color.needs)
            Layers.draw("status.needs", run, within: bounds, textRun: run, text: [ink], base: base, state: state, in: ctx)
        }
        // After the row's last layer: the icon's glyph is text. Its layers stay in the row, left of column 2, where
        // no text is: every line but the icon starts at col2.
        drawIcon(row.kind, in: icon, band: NSRect(x: box.minX, y: box.minY, width: col2 - box.minX, height: box.height).intersection(rowClip), ctx: ctx)
        if row.selected && fx.rowSelect == "cursor" {
            // Over the icon's layers, which may reach it.
            Theme.current.app.rowSelectInk.setFill()
            Draw.cursor(at: NSPoint(x: box.minX + 4, y: top + Tok.Size.rowPad[0] + (rowLine1 - 8) / 2))
        }

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
            ctx.saveGState()
            if row.needsYou && fx.needsGlow { ctx.setShadow(offset: .zero, blur: 8, color: Tok.Color.needs.withAlphaComponent(0.6).cgColor) }
            Draw.text(l.status, font: Fonts.status, x: right - l.statusW, top: y + (rowLine1 - Tok.Size.rowRight * lh) / 2,
                      lineHeight: Tok.Size.rowRight * lh, in: ctx)
            ctx.restoreGState()
        }
        if row.selected && fx.rowSelect == "name" {
            // The name alone highlighted, with a dotted focus ring inside it.
            let nameH = Tok.Size.rowName * lh
            let r = NSRect(x: col2 - 2, y: y + (rowLine1 - nameH) / 2, width: Draw.width(l.name) + 4, height: nameH).integral
            Draw.fill(r, Theme.current.app.rowSelectFill)
            Draw.dottedRing(r, Theme.current.app.rowSelectInk)
            let name = Draw.line(row.name, Fonts.name, Theme.current.app.rowSelectInk)
            Draw.text(name, font: Fonts.name, x: col2, top: y + (rowLine1 - nameH) / 2, lineHeight: nameH, in: ctx)
        } else {
            Draw.text(l.name, font: Fonts.name, x: col2, top: y + (rowLine1 - Tok.Size.rowName * lh) / 2,
                      lineHeight: Tok.Size.rowName * lh, in: ctx)
        }
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
            let metaBottom = y
            y += gapY + Tok.Size.barMt
            let track = NSRect(x: col2, y: y, width: right - col2, height: Tok.Size.barH)
            // The bar's layers stay between the meta line and the next line (or the row's end).
            let next = l.subs.isEmpty ? box.maxY : y + Tok.Size.barH + gapY + Tok.Size.subMt
            let band = NSRect(x: box.minX, y: metaBottom, width: box.width, height: max(next - metaBottom, 0)).intersection(rowClip)
            drawBar(track, fill: NSRect(x: col2, y: y, width: track.width * frac, height: Tok.Size.barH), band: band)
            y += Tok.Size.barH
        }

        for s in l.subs {
            y += gapY + Tok.Size.subMt
            Draw.text(s.label, font: Fonts.sub, x: col2, top: y, lineHeight: Tok.Size.subFont * lh, in: ctx)
            Draw.text(s.meta, font: Fonts.sub, x: right - s.metaW, top: y, lineHeight: Tok.Size.subFont * lh, in: ctx)
            y += Tok.Size.subFont * lh
        }
    }

    /// The progress bar, with `[effects] bar.radius` and `bar.glow`.
    private func drawBar(_ track: NSRect, fill: NSRect, band: NSRect) {
        let fx = Theme.current.effects, r = min(fx.barRadius, track.height / 2)
        let ctx = NSGraphicsContext.current?.cgContext
        var trackDrawn = false
        if fx.progressStyle == "none", let ctx {
            // The theme's layers are the bar; if they don't draw, Haunt's plain bar stands in.
            trackDrawn = Layers.draw("bar.track", track, within: band, in: ctx)
            if trackDrawn && (fill.width == 0 || Layers.draw("bar.fill", fill, within: band, in: ctx)) { return }
        }
        defer { if let ctx, fill.width > 0 { Layers.draw("bar.fill", fill, within: band, in: ctx) } }
        if fx.progressStyle == "segments" {
            // A sunken (or `app.bar.frame`d) track, 2 pt in, filled with `app.bar.segment` blocks.
            let app = Theme.current.app, seg = app.barSegment
            Draw.fill(track, Tok.Color.barTrack)
            if app.barFrame.alphaComponent > 0 {
                let hl = Tok.App.hairline, ring = NSBezierPath(rect: track.insetBy(dx: hl / 2, dy: hl / 2))
                ring.lineWidth = hl
                app.barFrame.setStroke()
                ring.stroke()
            } else {
                Draw.bevel(track, "thin")
            }
            let inner = track.insetBy(dx: 2, dy: 2), end = inner.minX + max(fill.width - 4, 0)
            var x = inner.minX
            while x < end, seg[0] > 0 {
                Draw.fill(NSRect(x: x, y: inner.minY, width: min(seg[0], end - x), height: inner.height), Tok.Color.barFill)
                x += seg[0] + seg[1]
            }
            return
        }
        guard r > 0 || fx.barGlow else {
            Draw.fill(track, Tok.Color.barTrack)
            if let ctx, !trackDrawn { Layers.draw("bar.track", track, within: band, in: ctx) }
            Draw.fill(fill, Tok.Color.barFill)
            return
        }
        Tok.Color.barTrack.setFill()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
        if let ctx, !trackDrawn { Layers.draw("bar.track", track, within: band, in: ctx) }
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
        ["row", "row.selected", "row.hover"].contains(where: Layers.has) ? Layers.bleed["row"] ?? 0 : 0
    }

    private func drawIcon(_ kind: RowKind, in r: NSRect, band: NSRect, ctx: CGContext) {
        let fx = Theme.current.effects
        // The plain shell's tile is the icon's background, so its layers go over it; every layer before the glyphs.
        // `index` tells the kinds apart: 0 Claude, 1 Codex, 2 a shell.
        let index = switch kind { case .claude: 0; case .codex: 1; case .shell: 2 }
        let shellTile = kind == .shell && fx.iconStyle != "pixel"
        if shellTile {
            Tok.Color.iconBg.setFill()
            NSBezierPath(roundedRect: r, xRadius: Tok.Size.iconRadius, yRadius: Tok.Size.iconRadius).fill()
        }
        if kind != .shell || shellTile { Layers.draw("icon", r, within: band, state: Layers.state(self), index: index, in: ctx) }
        if kind != .codex, Draw.pixelIcon(claude: kind == .claude, in: r) { return }
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
