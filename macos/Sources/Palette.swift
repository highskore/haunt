import AppKit

/// One palette entry, laid out like the decision-log mockup's `.e`: a time column, a marker, two lines of
/// text and a jump chip or key on the right.
struct PaletteRow: Equatable {
    enum Mark: Equatable { case open, filled, round }
    enum Right: Equatable { case none, jump, key(String) }
    enum Action: Equatable {
        case none
        case tab(String)
        case enterMode(String)
        case plugin(pluginId: String, itemId: String)
        /// An app command, run through its menu item.
        case command(KeyMap.Action)
    }

    var left = ""
    var mark: Mark?
    var title: String
    var sub: String
    var right = Right.none
    var action = Action.none
    /// Status lines ("No matches", a plugin that didn't load) rather than entries.
    var dim = false
}

/// What the palette reads and drives; `MainWindowController` provides it.
protocol PaletteHost: AnyObject {
    var paletteTabs: [Row] { get }
    var selectedSurfaceId: String? { get }
    var palettePlugins: PluginsAPI? { get }
    var pluginLoadErrors: [String] { get }
    func paletteSelectTab(_ surfaceId: String)
    func paletteInvoke(pluginId: String, itemId: String)
    /// After plugin code ran for a query: carries out whatever it asked for.
    func drainPluginRequests()
    var paletteKeys: KeyMap { get }
    var isSidebarHidden: Bool { get }
    var isFullScreen: Bool { get }
    func paletteRun(_ action: KeyMap.Action)
    func paletteDidClose()
}

/// ⌘K: fuzzy jump to tabs, app commands, and plugin commands and modes (`log` is the decision-log plugin's).
final class PaletteController: NSObject, NSWindowDelegate {
    private static let maxRows = 8

    private weak var host: PaletteHost?
    private let panel: PalettePanel
    private let view = PaletteView()
    private(set) var mode: String?
    private var query = ""
    /// ⇥ in a mode whose rows name tabs (`log`): only the selected tab's rows.
    private var tabFilter: String?
    /// The start of the day the rows were last built, for their times.
    private var today = Date()
    private var rowsNameTabs = false
    /// Fixture captures keep it open when focus moves to another app mid-capture.
    var sticky = false

    init(host: PaletteHost) {
        self.host = host
        panel = PalettePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // It closes when it stops being key; hiding on deactivate as well would leave it open but invisible.
        panel.hidesOnDeactivate = false
        panel.colorSpace = .sRGB
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        panel.delegate = self
        panel.initialFirstResponder = view
        view.controller = self
        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive(_:)),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    var isOpen: Bool { panel.isVisible }

    /// Opens over `parent`, `top` points below its content top; `text` is typed in as if by the user.
    func open(over parent: NSWindow, top: CGFloat, text: String = "") {
        mode = nil
        query = ""
        tabFilter = nil
        for c in text { type(String(c)) }
        reload()
        position(over: parent, top: top)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    /// Centred on `parent`, `top` points below its top edge; the height follows the rows shown.
    /// It keeps the same margin below as above, scrolling rows that don't fit.
    func position(over parent: NSWindow, top: CGFloat) {
        view.heightLimit = parent.frame.height - top - Tok.Size.paletteTop
        let size = view.fittingSize
        let x = (parent.frame.midX - size.width / 2).rounded()
        panel.setFrame(NSRect(x: x, y: parent.frame.maxY - top - size.height, width: size.width, height: size.height), display: true)
    }

    private func resize() {
        guard isOpen, let parent = panel.parent else { return }
        position(over: parent, top: parent.frame.maxY - panel.frame.maxY)
    }

    func close() {
        guard isOpen else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        host?.paletteDidClose()
    }

    /// Clicking elsewhere in Haunt closes it, and so does switching apps (below); a panel that never
    /// had an active app around it, as in a launch check, stays.
    func windowDidResignKey(_ notification: Notification) {
        if NSApp.isActive && !sticky { close() }
    }

    @objc private func appDidResignActive(_ n: Notification) {
        if !sticky { close() }
    }

    // MARK: Input

    /// Typing a mode word and a space turns it into the mode chip.
    func type(_ s: String) {
        query += s
        if mode == nil, query.hasSuffix(" "), let word = query.split(separator: " ").first.map(String.init),
           query == word + " ", modes().contains(word) {
            mode = word
            query = ""
        }
    }

    func edit(_ key: PaletteView.Key) {
        switch key {
        case let .text(s):
            type(s)
            reload()
        case .backspace:
            if !query.isEmpty {
                query.removeLast()
            } else if let m = mode {
                // Back into the word, so one more backspace edits it.
                mode = nil
                query = m
                tabFilter = nil
            }
            reload()
        case .up:
            view.moveSelection(-1)
            resize()
        case .down:
            view.moveSelection(1)
            resize()
        case .tab:
            guard rowsNameTabs else { return }
            tabFilter = tabFilter == nil ? host?.selectedSurfaceId : nil
            reload()
        case .enter: activate(view.selectedRow)
        case .escape: close()
        }
    }

    func activate(_ row: PaletteRow?) {
        guard let row, let host else { return }
        switch row.action {
        case .none: return
        case let .tab(id):
            close()
            host.paletteSelectTab(id)
        case let .enterMode(word):
            mode = word
            query = ""
            reload()
        case let .plugin(pluginId, itemId):
            close()
            host.paletteInvoke(pluginId: pluginId, itemId: itemId)
        case let .command(a):
            close()
            host.paletteRun(a)
        }
    }

    private func modes() -> [String] {
        host?.palettePlugins?.paletteItems(mode: nil, query: "").filter(\.isMode).map(\.id) ?? []
    }

    // MARK: Rows

    private func reload() {
        today = Calendar.current.startOfDay(for: Date())
        let rows: [PaletteRow]
        var foot: [String]
        switch mode {
        case nil:
            rows = defaultRows()
            rowsNameTabs = false
            foot = ["↵ open"]
        case let m?:
            let items = host?.palettePlugins?.paletteItems(mode: m, query: query) ?? []
            host?.drainPluginRequests()
            rows = items.filter { tabFilter == nil || $0.surfaceId == tabFilter }.map(pluginRow)
            rowsNameTabs = items.contains { $0.surfaceId != nil }
            foot = rowsNameTabs
                ? ["↵ jump to tab", tabFilter == nil ? "⇥ filter by tab" : "⇥ all tabs"] : ["↵ run"]
        }
        if rows.isEmpty { foot = [] }
        view.update(chip: mode, query: query, placeholder: mode == nil ? "Jump to a tab or command, or type log" : "",
                    rows: rows.isEmpty ? [PaletteRow(title: "No matches", sub: "", dim: true)] : rows,
                    foot: foot, maxRows: Self.maxRows)
        resize()
    }

    private func defaultRows() -> [PaletteRow] {
        guard let host else { return [] }
        var scored: [(Int, Int, PaletteRow)] = []
        for (i, r) in host.paletteTabs.enumerated() {
            guard let s = Fuzzy.score(query, r.name) ?? Fuzzy.score(query, r.meta).map({ $0 - 50 }) else { continue }
            let row = PaletteRow(left: i < 9 ? "⌘\(i + 1)" : "", mark: nil, title: r.name, sub: r.meta,
                                 right: .jump, action: .tab(r.surfaceId))
            scored.append((s, scored.count, row))
        }
        // App commands: after the tabs with an empty query, ranked with them otherwise. The sub line names the
        // menu each lives in.
        let commands: [(KeyMap.Action, String, String)] = [
            (.toggleSidebar, host.isSidebarHidden ? "Show Sidebar" : "Hide Sidebar", "View"),
            (.review, "Review Changes", "View · the selected tab's latest turn"),
            (.newTab, "New Tab", "Window"),
            (.closeTab, "Close Tab", "Window"),
            (.nextTab, "Next Tab", "Window"),
            (.previousTab, "Previous Tab", "Window"),
            (.renameTab, "Rename Tab", "Window"),
            (.settings, "Open Settings", "Haunt · config.toml"),
            (.fullScreen, host.isFullScreen ? "Exit Full Screen" : "Enter Full Screen", "View"),
        ]
        for (a, title, sub) in commands {
            guard let s = Fuzzy.score(query, title) else { continue }
            let row = PaletteRow(title: title, sub: sub, right: host.paletteKeys[a].map { .key($0.display) } ?? .none,
                                 action: .command(a))
            scored.append((s, scored.count, row))
        }
        for item in host.palettePlugins?.paletteItems(mode: nil, query: query) ?? [] {
            scored.append((Fuzzy.score(query, item.title) ?? 0, scored.count, pluginRow(item)))
        }
        var rows = scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
        if query.isEmpty {
            rows += host.pluginLoadErrors.map { PaletteRow(title: "Plugin not loaded", sub: $0, dim: true) }
        }
        return rows
    }

    /// A row naming an open tab (`surfaceId`) jumps to it; one with a time or mark is a log line, laid out as such.
    private func pluginRow(_ item: PaletteItem) -> PaletteRow {
        let tab = item.surfaceId.flatMap { s in host?.paletteTabs.contains { $0.surfaceId == s } == true ? s : nil }
        let logLine = item.atMs != nil || item.mark != nil || item.surfaceId != nil
        // The binding `[keys]` gave it, which may differ from, or have refused, the plugin's default.
        let key = host?.paletteKeys.plugin[KeyMap.pluginName(item.pluginId, item.id)].map { PaletteRow.Right.key($0.display) } ?? .none
        return PaletteRow(left: item.atMs.map { Self.time($0, today: today) } ?? "", mark: item.mark.map(Self.mark),
                          title: item.title, sub: item.subtitle ?? (logLine ? "" : item.pluginId),
                          right: tab == nil ? key : .jump,
                          action: tab.map { .tab($0) } ?? (item.isMode ? .enterMode(item.id) : .plugin(pluginId: item.pluginId, itemId: item.id)))
    }

    static func mark(_ m: Mark) -> PaletteRow.Mark {
        switch m {
        case .open: return .open
        case .filled: return .filled
        case .round: return .round
        }
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let clock = formatter("HH:mm"), weekday = formatter("EEE"), monthDay = formatter("M/d")

    /// "14:02" today, "Sat" this week, "10/3" before that. `today` is the start of the current day.
    static func time(_ ms: UInt64, today: Date) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: today).day ?? .max
        return (days == 0 ? clock : days < 7 ? weekday : monthDay).string(from: date)
    }
}

/// A borderless panel still has to take keys for typing.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Subsequence match: consecutive letters and word starts score higher; nil when `query` isn't in `text`.
enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        if q.isEmpty { return 0 }
        var score = 0, qi = 0, prev = -2
        for (i, c) in t.enumerated() where qi < q.count && c == q[qi] {
            score += 1
            if i == prev + 1 { score += 5 }
            if i == 0 || !t[i - 1].isLetter && !t[i - 1].isNumber { score += 8 }
            prev = i
            qi += 1
        }
        return qi == q.count ? score - t.count / 8 : nil
    }
}

/// Draws the palette at the decision-log mockup's sizes (pawr-declog 04's `.pal`) and takes its keys.
final class PaletteView: NSView {
    enum Key {
        case text(String), backspace, up, down, tab, enter, escape
    }

    weak var controller: PaletteController?
    private var chip: String?
    private var query = ""
    private var placeholder = ""
    private var rows: [PaletteRow] = []
    private var foot: [String] = []
    private var maxRows = 8
    private var selected = 0
    private var scroll = 0
    /// The most the panel may be tall; rows past it scroll, but at least `minRows` stay.
    var heightLimit = CGFloat.infinity { didSet { if heightLimit != oldValue { clampScroll(); needsDisplay = true } } }
    private static let minRows = 3

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var selectedRow: PaletteRow? { rows.indices.contains(selected) ? rows[selected] : nil }

    func update(chip: String?, query: String, placeholder: String, rows: [PaletteRow], foot: [String], maxRows: Int) {
        // A refresh or reorder keeps the selected row; new text starts again from the best match.
        let keep = query == self.query && chip == self.chip ? selectedRow : nil
        self.chip = chip
        self.query = query
        self.placeholder = placeholder
        self.rows = rows
        self.foot = foot
        self.maxRows = maxRows
        selected = keep.flatMap { k in rows.firstIndex { $0 == k } } ?? rows.firstIndex { $0.action != .none } ?? 0
        clampScroll()
        needsDisplay = true
    }

    func moveSelection(_ d: Int) {
        var i = selected
        repeat {
            i += d
            guard rows.indices.contains(i) else { return }
        } while rows[i].action == .none
        selected = i
        clampScroll()
        needsDisplay = true
    }

    private func clampScroll() {
        let n = rowsShown
        if selected < scroll { scroll = selected }
        if selected >= scroll + n { scroll = selected - n + 1 }
        scroll = max(0, min(scroll, max(0, rows.count - n)))
    }

    /// `maxRows`, cut to what fits in `heightLimit` with every entry at its full (ruled) height.
    private var rowsShown: Int {
        let fixed = 2 * border + inputH + footH + Tok.Size.paletteListPad[0] * 2
        let entry = Tok.Size.paletteEntryPad[0] * 2 + textLines + border
        let fit = heightLimit.isFinite ? Int(((heightLimit - fixed) / entry).rounded(.down)) : maxRows
        return max(Self.minRows, min(maxRows, fit))
    }

    // MARK: Geometry (pt, inside the border); rules are as thick as the border

    private let lh = Tok.Font.baseLine
    private var border: CGFloat { Tok.App.hairline }
    private var width: CGFloat { Tok.Size.paletteW - 2 * border }
    private var padX: CGFloat { Tok.Size.paletteInputPad[1] }
    private var inputH: CGFloat { Tok.Size.paletteInputPad[0] * 2 + Tok.Size.paletteInputFont * lh + border }
    private var textLines: CGFloat { Tok.Size.paletteFont * lh + Tok.Size.paletteSmallFont * lh }
    private var footH: CGFloat {
        foot.isEmpty ? 0 : border + Tok.Size.paletteFootPad[0] * 2 + Tok.Size.paletteSmallFont * lh
    }
    private var visible: Range<Int> { scroll..<min(rows.count, scroll + rowsShown) }

    /// The mockup's last-child rule: the selected entry (alone in its `.sel` wrapper) and the last one have no rule.
    private func hasRule(_ i: Int) -> Bool { i != selected && i != visible.upperBound - 1 }

    private func entryH(_ i: Int) -> CGFloat {
        Tok.Size.paletteEntryPad[0] * 2 + textLines + (hasRule(i) ? border : 0)
    }

    private var listH: CGFloat {
        Tok.Size.paletteListPad[0] * 2 + visible.reduce(0) { $0 + entryH($1) }
    }

    /// Content heights are whole points; the mockup's foot ends at a fractional .25 that its crop drops.
    override var fittingSize: NSSize {
        NSSize(width: Tok.Size.paletteW, height: (inputH + listH + footH).rounded(.down) + 2 * border)
    }

    // MARK: Drawing

    private func mono(_ s: CGFloat) -> NSFont { Draw.mono(s) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = Tok.Size.paletteRadius
        let outer = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
        Tok.Color.paletteBorder.setFill()
        outer.fill()
        let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: border, dy: border), xRadius: r - border, yRadius: r - border)
        Tok.Color.paletteBg.setFill()
        inner.fill()
        inner.addClip()

        ctx.saveGState()
        ctx.translateBy(x: border, y: border)
        drawInput(ctx)
        var y = inputH + Tok.Size.paletteListPad[0]
        for i in visible {
            drawEntry(rows[i], index: i, top: y, ctx: ctx)
            y += entryH(i)
        }
        if !foot.isEmpty { drawFoot(top: inputH + listH, ctx: ctx) }
        ctx.restoreGState()
    }

    private func drawInput(_ ctx: CGContext) {
        let padY = Tok.Size.paletteInputPad[0], gap = Tok.Size.paletteInputGap
        let lineH = Tok.Size.paletteInputFont * lh
        let mid = padY + lineH / 2
        var x = padX
        if let chip {
            let f = mono(Tok.Size.paletteChipFont)
            let line = Draw.line(chip, f, Tok.Color.paletteChipFg)
            let h = Tok.Size.paletteChipFont * lh
            let box = NSRect(x: x, y: mid - h / 2, width: Draw.width(line) + Tok.Size.paletteChipPad[1] * 2, height: h)
            let cr = Tok.Size.paletteChipRadius
            Tok.Color.paletteInk.setFill()
            NSBezierPath(roundedRect: box, xRadius: cr, yRadius: cr).fill()
            Draw.text(line, font: f, x: box.minX + Tok.Size.paletteChipPad[1], top: box.minY, lineHeight: h, in: ctx)
            x = box.maxX + gap
        }
        let f = mono(Tok.Size.paletteInputFont)
        if !query.isEmpty {
            let line = Draw.line(query, f, Tok.Color.paletteInk)
            Draw.text(line, font: f, x: x, top: padY, lineHeight: lineH, in: ctx)
            x += Draw.width(line) + gap
        }
        let ch = Tok.Size.paletteCursorH
        Draw.fill(NSRect(x: x, y: mid - ch / 2, width: Tok.App.caretW, height: ch), Tok.Color.paletteInk)
        if query.isEmpty && chip == nil && !placeholder.isEmpty {
            let line = Draw.line(placeholder, f, Tok.Color.paletteMute)
            Draw.text(line, font: f, x: x + gap, top: padY, lineHeight: lineH, in: ctx)
        }
        drawKey("esc", right: width - padX, mid: mid, font: Tok.Size.paletteSmallFont, ctx: ctx)
        Draw.fill(NSRect(x: 0, y: inputH - border, width: width, height: border), Tok.Color.paletteRule)
    }

    /// The mockup's `.kbd` (and `.jmp` with its own font and line height), right-aligned at `right`.
    @discardableResult
    private func drawKey(_ label: String, right: CGFloat, mid: CGFloat? = nil, top: CGFloat? = nil, font size: CGFloat,
                         lineHeight: CGFloat? = nil, ctx: CGContext) -> NSRect {
        let f = mono(size)
        let line = Draw.line(label, f, Tok.Color.paletteMute)
        let pad = Tok.Size.paletteKbdPad[1]
        let lineH = lineHeight ?? size * lh
        let w = Draw.width(line) + pad * 2 + border * 2, h = lineH + border * 2
        let box = NSRect(x: right - w, y: top ?? (mid! - h / 2), width: w, height: h)
        let kr = Tok.Size.paletteKbdRadius
        let path = NSBezierPath(roundedRect: box.insetBy(dx: border / 2, dy: border / 2), xRadius: kr - border / 2, yRadius: kr - border / 2)
        path.lineWidth = border
        Tok.Color.paletteRule.setStroke()
        path.stroke()
        Draw.text(line, font: f, x: box.minX + border + pad, top: box.minY + border, lineHeight: lineH, in: ctx)
        return box
    }

    private func drawEntry(_ row: PaletteRow, index: Int, top: CGFloat, ctx: CGContext) {
        let h = entryH(index)
        if index == selected && row.action != .none {
            Draw.fill(NSRect(x: 0, y: top, width: width, height: h), Tok.Color.paletteSel)
            Draw.fill(NSRect(x: 0, y: top, width: Tok.Size.paletteSelBar, height: h), Tok.Color.paletteInk)
        }
        let gap = Tok.Size.paletteEntryGap
        let y = top + Tok.Size.paletteEntryPad[0]
        let small = mono(Tok.Size.paletteSmallFont), smallH = Tok.Size.paletteSmallFont * lh
        let body = mono(Tok.Size.paletteFont), bodyH = Tok.Size.paletteFont * lh
        let timeX = padX
        let markX = timeX + Tok.Size.paletteEntryTimeW + gap
        let textX = markX + Tok.Size.paletteEntryMarkW + gap
        let right = width - padX

        if !row.left.isEmpty {
            Draw.text(Draw.line(row.left, small, Tok.Color.paletteMute), font: small, x: timeX, top: y, lineHeight: smallH, in: ctx)
        }
        if let mark = row.mark {
            let s = Tok.Size.paletteMark
            let box = NSRect(x: markX, y: y + Tok.Size.paletteMarkMt, width: s, height: s)
            let path = mark == .round ? NSBezierPath(ovalIn: box.insetBy(dx: border / 2, dy: border / 2))
                : NSBezierPath(rect: box.insetBy(dx: border / 2, dy: border / 2))
            if mark == .filled {
                Tok.Color.paletteInk.setFill()
                NSBezierPath(rect: box).fill()
            } else {
                path.lineWidth = border
                Tok.Color.paletteInk.setStroke()
                path.stroke()
            }
        }
        var textRight = right
        switch row.right {
        case .none: break
        case .jump:
            let box = drawKey("↗", right: right, top: y, font: Tok.Size.paletteJmpFont, lineHeight: Tok.Size.paletteJmpLine, ctx: ctx)
            textRight = box.minX - gap
        case let .key(k):
            let box = drawKey(k, right: right, top: y, font: Tok.Size.paletteSmallFont, ctx: ctx)
            textRight = box.minX - gap
        }
        let titleColor = row.dim ? Tok.Color.paletteMute : Tok.Color.paletteInk
        let title = Draw.truncated(Draw.line(row.title, body, titleColor), textRight - textX, body, titleColor)
        Draw.text(title, font: body, x: textX, top: y, lineHeight: bodyH, in: ctx)
        if !row.sub.isEmpty {
            let sub = Draw.truncated(Draw.line(row.sub, small, Tok.Color.paletteMute), textRight - textX, small, Tok.Color.paletteMute)
            Draw.text(sub, font: small, x: textX, top: y + bodyH, lineHeight: smallH, in: ctx)
        }
        if hasRule(index) {
            Draw.fill(NSRect(x: padX, y: top + h - border, width: width - 2 * padX, height: border), Tok.Color.paletteEntryRule)
        }
    }

    private func drawFoot(top: CGFloat, ctx: CGContext) {
        Draw.fill(NSRect(x: 0, y: top, width: width, height: border), Tok.Color.paletteRule)
        let f = mono(Tok.Size.paletteSmallFont), h = Tok.Size.paletteSmallFont * lh
        var x = Tok.Size.paletteFootPad[1]
        for hint in foot {
            let line = Draw.line(hint, f, Tok.Color.paletteMute)
            Draw.text(line, font: f, x: x, top: top + border + Tok.Size.paletteFootPad[0], lineHeight: h, in: ctx)
            x += Draw.width(line) + Tok.Size.paletteFootGap
        }
    }

    // MARK: Events

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 53: return send(.escape)
        case 36, 76: return send(.enter)
        case 51: return send(.backspace)
        case 48: return send(.tab)
        case 126: return send(.up)
        case 125: return send(.down)
        default: break
        }
        if mods == .control, let c = event.charactersIgnoringModifiers {
            if c == "p" { return send(.up) }
            if c == "n" { return send(.down) }
        }
        guard mods.isEmpty, let s = event.characters, !s.isEmpty else { return super.keyDown(with: event) }
        let clean = Self.printable(s)
        if !clean.isEmpty { send(.text(clean)) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.modifierFlags.intersection([.command, .control, .option]) == .command,
              event.charactersIgnoringModifiers == "v" else { return super.performKeyEquivalent(with: event) }
        let first = NSPasteboard.general.string(forType: .string)?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = Self.printable(first)
        if !clean.isEmpty { send(.text(clean)) }
        return true
    }

    /// Only visible text reaches the query: no controls, format characters or newlines.
    static func printable(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
                && !(0xF700...0xF8FF).contains($0.value)
        }))
    }

    private func send(_ k: Key) { controller?.edit(k) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var y = border + inputH + Tok.Size.paletteListPad[0]
        for i in visible {
            let h = entryH(i)
            if p.y >= y && p.y < y + h {
                guard rows[i].action != .none else { return }
                selected = i
                needsDisplay = true
                controller?.activate(rows[i])
                return
            }
            y += h
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let d = event.scrollingDeltaY > 0 ? -1 : event.scrollingDeltaY < 0 ? 1 : 0
        scroll = max(0, min(scroll + d, max(0, rows.count - rowsShown)))
        needsDisplay = true
    }
}
