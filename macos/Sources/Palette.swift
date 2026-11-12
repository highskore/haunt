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
        /// A theme in the `theme` mode: previewed while selected, kept on ↵.
        case theme(String)
    }

    var left = ""
    var mark: Mark?
    /// The tab's kind, for `[effects] palette.icons`; other rows get the shell glyph.
    var icon: RowKind?
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
    var paletteThemes: [HauntConfig.ThemeChoice] { get }
    /// The theme on screen when no preview runs.
    var paletteTheme: String { get }
    /// Shows `id` live; nil goes back to config.toml's theme.
    func palettePreviewTheme(_ id: String?)
    func paletteChooseTheme(_ id: String)
}

/// ⌘K: fuzzy jump to tabs, app commands, and plugin commands and modes (`log` is the decision-log plugin's).
/// Its own `theme` mode previews the selected theme; ↵ keeps it, anything else puts the old one back.
final class PaletteController: NSObject, NSWindowDelegate {
    /// Entries shown before the list scrolls; a fixture trims it to its mockup's.
    var maxRows = 8
    static let themeMode = "theme"

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
    /// In the `theme` mode: the theme to go back to, and the one on screen now.
    private var themeBefore: String?
    private var previewed: String?
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
        panel.appearance = Tok.App.appearance
        let content = NSView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        for v in [material, view] as [NSView] {
            v.autoresizingMask = [.width, .height]
            content.addSubview(v)
        }
        panel.contentView = content
        setMaterial()
        panel.delegate = self
        panel.initialFirstResponder = view
        view.controller = self
        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive(_:)),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    var isOpen: Bool { panel.isVisible }

    func themeDidChange() {
        panel.appearance = Tok.App.appearance
        setMaterial()
        if isOpen { resize() }
        view.needsDisplay = true
    }

    /// `[effects] palette.material = "glass"`: the desktop, blurred, inside the palette's rounded shape.
    private let material = NSVisualEffectView()

    private func setMaterial() {
        material.isHidden = Theme.current.effects.paletteMaterial != "glass"
        material.material = Effects.blurs[Theme.current.effects.paletteBlur] ?? .hudWindow
        material.layer?.cornerRadius = Tok.Size.paletteRadius
        material.layer?.masksToBounds = true
    }

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

    /// `[layout]`'s palette keys; read at the next open or resize.
    var layout = PaletteLayout() {
        didSet { view.singleLine = layout.singleLine && !view.plainMode }
    }
    /// The cards' bottom-right palette sits this far in from the window's right and bottom edges.
    static var cornerInset: CGFloat { Theme.current.effects.paletteInset }
    private var top: CGFloat = 0

    /// Centred on `parent`, `top` points below its top edge, or in its bottom-right corner growing upwards; the
    /// height follows the rows shown. It keeps a margin below, scrolling rows that don't fit.
    func position(over parent: NSWindow, top: CGFloat) {
        self.top = top
        view.panelW = layout.width ?? Tok.Size.paletteW
        let f = parent.frame
        switch layout.position {
        case .centerTop:
            view.heightLimit = f.height - top - Tok.Size.paletteTop
            let size = view.fittingSize
            panel.setFrame(NSRect(x: (f.midX - size.width / 2).rounded(), y: f.maxY - top - size.height,
                                  width: size.width, height: size.height), display: true)
        case .bottomRight:
            view.heightLimit = f.height - top - Self.cornerInset
            let size = view.fittingSize
            panel.setFrame(NSRect(x: f.maxX - Self.cornerInset - size.width + Theme.current.app.paletteOffsetX, y: f.minY + Self.cornerInset,
                                  width: size.width, height: size.height), display: true)
        }
    }

    private func resize() {
        guard isOpen, let parent = panel.parent else { return }
        position(over: parent, top: top)
    }

    func close() {
        leaveThemeMode()
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
            enter(mode: word)
        }
    }

    private func enter(mode word: String) {
        mode = word
        query = ""
        if word == Self.themeMode { themeBefore = host?.paletteTheme }
    }

    /// Puts the theme from before the mode back unless one was kept.
    private func leaveThemeMode() {
        guard themeBefore != nil else { return }
        themeBefore = nil
        if previewed != nil { host?.palettePreviewTheme(nil) }
        previewed = nil
    }

    private func previewSelection() {
        guard let before = themeBefore, case let .theme(id)? = view.selectedRow?.action, id != (previewed ?? before) else { return }
        previewed = id
        host?.palettePreviewTheme(id)
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
                leaveThemeMode()
                mode = nil
                query = m
                tabFilter = nil
            }
            reload()
        case .up:
            view.moveSelection(-1)
            resize()
            previewSelection()
        case .down:
            view.moveSelection(1)
            resize()
            previewSelection()
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
            enter(mode: word)
            reload()
        case let .plugin(pluginId, itemId):
            close()
            host.paletteInvoke(pluginId: pluginId, itemId: itemId)
        case let .command(a):
            close()
            host.paletteRun(a)
        case let .theme(id):
            themeBefore = nil
            previewed = nil
            close()
            host.paletteChooseTheme(id)
        }
    }

    private func modes() -> [String] {
        [Self.themeMode] + (host?.palettePlugins?.paletteItems(mode: nil, query: "").filter(\.isMode).map(\.id) ?? [])
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
        case Self.themeMode?:
            rows = themeRows()
            rowsNameTabs = false
            foot = ["↵ use theme", "esc keep the old one"]
        case let m?:
            let items = host?.palettePlugins?.paletteItems(mode: m, query: query) ?? []
            host?.drainPluginRequests()
            rows = items.filter { tabFilter == nil || $0.surfaceId == tabFilter }.map(pluginRow)
            rowsNameTabs = items.contains { $0.surfaceId != nil }
            foot = rowsNameTabs
                ? ["↵ jump to tab", tabFilter == nil ? "⇥ filter by tab" : "⇥ all tabs"] : ["↵ run"]
        }
        if rows.isEmpty { foot = [] }
        view.plainMode = mode != nil && Theme.current.effects.paletteModes == "plain"
        view.singleLine = layout.singleLine && !view.plainMode
        view.update(chip: mode, query: query, placeholder: mode == nil ? "Jump to a tab or command, or type log" : "",
                    rows: rows.isEmpty ? [PaletteRow(title: "No matches", sub: "", dim: true)] : rows,
                    foot: foot, maxRows: maxRows)
        if let before = themeBefore, previewed == nil { view.select { $0.action == .theme(before) } }
        resize()
        previewSelection()
    }

    private func themeRows() -> [PaletteRow] {
        guard let host else { return [] }
        let saved = themeBefore
        var scored: [(Int, Int, PaletteRow)] = []
        for t in host.paletteThemes {
            guard let s = Fuzzy.score(query, t.name) ?? Fuzzy.score(query, t.id).map({ $0 - 50 }) else { continue }
            let row = PaletteRow(title: t.name, sub: t.id == saved ? "\(t.id) · in use" : t.id, action: .theme(t.id))
            scored.append((query.isEmpty ? 0 : s, scored.count, row))
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
    }

    private func defaultRows() -> [PaletteRow] {
        guard let host else { return [] }
        var scored: [(Int, Int, PaletteRow)] = []
        for (i, r) in host.paletteTabs.enumerated() {
            guard let s = Fuzzy.score(query, r.name) ?? Fuzzy.score(query, r.meta).map({ $0 - 50 }) else { continue }
            // A shell has no task, so it keeps its meta.
            let sub = Theme.current.effects.paletteTabSub == "task" && !r.task.isEmpty ? r.task : r.meta
            let row = PaletteRow(left: i < 9 ? "⌘\(i + 1)" : "", mark: nil, icon: r.kind, title: r.name, sub: sub,
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
        if let s = Fuzzy.score(query, "Pick theme…") {
            scored.append((s, scored.count, PaletteRow(title: "Pick theme…", sub: host.paletteTheme, action: .enterMode(Self.themeMode))))
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
    var panelW = Tok.Size.paletteW { didSet { needsDisplay = true } }
    /// A row's sub follows its title on the same line.
    var singleLine = false { didSet { clampScroll(); needsDisplay = true } }
    /// `[effects] palette.modes = "plain"` in a plugin mode: the black-and-white rows inside the theme's panel.
    var plainMode = false
    /// The entry under the pointer, for `[effects] row.hover`.
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

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
        self.foot = Theme.current.effects.paletteFoot || plainMode ? foot : []
        self.maxRows = maxRows
        selected = keep.flatMap { k in rows.firstIndex { $0 == k } } ?? rows.firstIndex { $0.action != .none } ?? 0
        clampScroll()
        needsDisplay = true
    }

    func select(where match: (PaletteRow) -> Bool) {
        guard let i = rows.firstIndex(where: match) else { return }
        selected = i
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
        let fixed = 2 * edge + headH + inputH + footH + Tok.Size.paletteListPad[0] * 2
        let entry = Tok.Size.paletteEntryPad[0] * 2 + textLines + (pill ? 0 : border)
        let fit = heightLimit.isFinite ? Int(((heightLimit - fixed) / entry).rounded(.down)) : maxRows
        return max(Self.minRows, min(maxRows, fit))
    }

    // MARK: Geometry (pt, inside the border); rules are as thick as the border

    private var lh: CGFloat { Tok.Font.baseLine }
    private var border: CGFloat { Tok.App.hairline }
    /// A glass palette's ring is drawn over its content, which starts at its edge; otherwise inside the border.
    private var glass: Bool { Theme.current.effects.paletteMaterial == "glass" }
    private var edge: CGFloat { glass ? 0 : rings.isEmpty ? border : rings.reduce(0) { $0 + $1.width } }
    /// `app.palette.rings`, parsed; empty when any ring isn't "#rrggbb width".
    private var rings: [(color: NSColor, width: CGFloat)] {
        let r = Theme.current.app.paletteRings.compactMap { s -> (NSColor, CGFloat)? in
            let p = s.split(separator: " ")
            guard p.count == 2, let c = NSColor(themeHex: String(p[0])), let w = Double(p[1]), w > 0, w <= 8 else { return nil }
            return (c, CGFloat(w))
        }
        return r.count == Theme.current.app.paletteRings.count ? r : []
    }
    private var pill: Bool { !plainMode && Theme.current.effects.paletteSelection == "pill" }
    private var icons: Bool { !plainMode && Theme.current.effects.paletteIcons }
    private var width: CGFloat { panelW - 2 * edge }
    private var padX: CGFloat { Tok.Size.paletteInputPad[1] }
    /// An entry's side margin: the input's, and `app.palette.row.inset` more.
    private var entryX: CGFloat { padX + Theme.current.app.paletteRowInset }
    private var inputH: CGFloat {
        if dialog { return Self.fieldH + 8 }
        return Tok.Size.paletteInputPad[0] * 2 + Tok.Size.paletteInputFont * lh + border + (inputRules ? 2 * Self.ruleMargin + border : 0)
    }
    /// `[effects] palette.header`: the header's height, its type set solid with 10 pt above and 4 below.
    private var headH: CGFloat {
        if dialog { return 3 + Self.captionH + 10 + (message == nil ? 0 : Self.messageH + 8) - edge }
        return header == nil ? 0 : 10 + Theme.current.app.paletteHeaderFont + 4
    }
    /// `palette.frame = "dialog"`: a raised dialog with a caption, a sunken field and list, and OK / Cancel.
    private var dialog: Bool { !plainMode && Theme.current.effects.paletteFrame == "dialog" }
    private static let captionH: CGFloat = 18, buttonSize = NSSize(width: 75, height: 23), fieldH: CGFloat = 21, messageH: CGFloat = 32
    // A theme's words are drawn whole or not at all: clipped, they could read as a status ("Done").
    private static func whole(_ s: String?, _ font: NSFont, kern: CGFloat = 0, room: CGFloat) -> String? {
        s.flatMap { Draw.width(Draw.line($0, font, .black, kern: kern)) <= room ? $0 : nil }
    }
    /// The dialog's `[strings] palette.message`, beside an info icon.
    var message: String? {
        dialog ? Self.whole(Theme.current.string("palette.message"), Draw.ui(Tok.Size.paletteSmallFont), room: width - 2 * padX - Self.messageH - 10) : nil
    }
    var header: String? {
        guard !plainMode, Theme.current.effects.paletteHeader, let s = Theme.current.string("palette.header") else { return nil }
        if dialog { return Self.whole(s, Draw.ui(Tok.Size.paletteSmallFont, .bold), room: dialogClose.minX - 3 - 8) }
        return Draw.display(Theme.current.app.paletteHeaderFont).flatMap { Self.whole(s, $0, room: width) }
    }
    /// The field's glyph: the theme's when it fits in half the input, else Haunt's.
    var inputGlyph: String {
        guard !plainMode else { return "⌕" }
        return Self.whole(Theme.current.string("palette.input.glyph"), Draw.ui(Tok.Size.paletteInputFont - 1), room: min(width / 2, width - 2 * padX)) ?? "⌕"
    }
    private var inputRules: Bool { !plainMode && Theme.current.effects.paletteInputRules }
    /// `palette.input.rules`: the rules stand this far from the header and the list.
    private static let ruleMargin: CGFloat = 6
    /// The theme's own hints line, in place of the default hints only: a mode's hints are always Haunt's.
    var footText: String? {
        guard !plainMode, chip == nil, !foot.isEmpty else { return nil }
        let size = Tok.Size.paletteSmallFont
        return Self.whole(Theme.current.string("palette.foot"), mono(size), kern: size * 0.25, room: width - 2 * Tok.Size.paletteFootPad[1])
    }
    /// An entry's content height: its text, or its icon when that is taller, as in the mockup's grid.
    private var textLines: CGFloat {
        let text = singleLine ? max(Tok.Size.paletteFont, Tok.Size.paletteSmallFont) * lh : Tok.Size.paletteFont * lh + Tok.Size.paletteSmallFont * lh
        return icons ? max(text, Tok.Size.iconSize) : text
    }
    private var footH: CGFloat {
        if dialog { return 8 + Self.buttonSize.height + 8 + 3 - edge }
        return foot.isEmpty ? 0 : border + Tok.Size.paletteFootPad[0] * 2 + Tok.Size.paletteSmallFont * lh
    }
    private var visible: Range<Int> { scroll..<min(rows.count, scroll + rowsShown) }

    /// The mockup's last-child rule: the selected entry (alone in its `.sel` wrapper) and the last one have no rule.
    private func hasRule(_ i: Int) -> Bool { !pill && i != selected && i != visible.upperBound - 1 }

    private func entryH(_ i: Int) -> CGFloat {
        Tok.Size.paletteEntryPad[0] * 2 + textLines + (hasRule(i) ? border : 0)
    }

    private var listH: CGFloat {
        Tok.Size.paletteListPad[0] * 2 + visible.reduce(0) { $0 + entryH($1) }
    }

    /// Content heights are whole points; the mockup's foot ends at a fractional .25 that its crop drops.
    override var fittingSize: NSSize {
        NSSize(width: panelW, height: (headH + inputH + listH + footH).rounded(.down) + 2 * edge)
    }

    // MARK: Drawing

    /// `[effects] palette.font`: the mono face (the mockup's) or the UI one.
    private func mono(_ s: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        Theme.current.effects.paletteFont == "ui" && !plainMode ? Draw.ui(s, weight) : Draw.mono(s)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = Tok.Size.paletteRadius
        if dialog {
            Draw.fill(bounds, Tok.Color.paletteBg)
            Draw.bevel(bounds, "out")
            drawDialog(ctx)
        } else if glass {
            let shape = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
            Tok.Color.paletteBg.setFill()
            shape.fill()
            shape.addClip()
        } else if !rings.isEmpty {
            var box = bounds
            for ring in rings {
                Draw.fill(box, ring.color)
                box = box.insetBy(dx: ring.width, dy: ring.width)
            }
            Draw.fill(box, Tok.Color.paletteBg)
            ctx.clip(to: box)
        } else {
            let outer = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
            Tok.Color.paletteBorder.setFill()
            outer.fill()
            let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: border, dy: border), xRadius: r - border, yRadius: r - border)
            Tok.Color.paletteBg.setFill()
            inner.fill()
            inner.addClip()
        }

        Layers.draw("palette", bounds, state: Layers.state(self), in: ctx)
        ctx.saveGState()
        ctx.translateBy(x: edge, y: edge)
        if dialog {
            // Drawn by drawDialog.
        } else if let header, let f = Draw.display(Theme.current.app.paletteHeaderFont) {
            let line = Draw.line(header, f, Tok.Color.paletteInk), size = Theme.current.app.paletteHeaderFont
            Draw.chromeText(line, font: f, x: ((width - Draw.width(line)) / 2).rounded(), top: 10, lineHeight: size, in: ctx)
        }
        ctx.translateBy(x: 0, y: headH)
        drawInput(ctx)
        var y = inputH + Tok.Size.paletteListPad[0]
        for i in visible {
            drawEntry(rows[i], index: i, top: y, ctx: ctx)
            y += entryH(i)
        }
        if !foot.isEmpty && !dialog { drawFoot(top: inputH + listH, ctx: ctx) }
        ctx.restoreGState()
        if glass {
            let app = Theme.current.app
            Draw.fill(NSRect(x: 0, y: 0, width: bounds.width, height: border), app.paletteHighlight)
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: border / 2, dy: border / 2), xRadius: r - border / 2, yRadius: r - border / 2)
            ring.lineWidth = border
            app.paletteRing.setStroke()
            ring.stroke()
        }
    }

    /// The dialog's caption and its sunken field, list and buttons, under the content drawn by `draw`.
    private func drawDialog(_ ctx: CGContext) {
        let app = Theme.current.app, x0 = edge, inner = width
        // Inside the 2 pt bevel and a 1 pt gap, as in the card.
        let cap = NSRect(x: 3, y: 3, width: bounds.width - 6, height: Self.captionH)
        let stops = app.titlebarFill.compactMap { NSColor(themeHex: $0) }
        if stops.count > 1, let g = NSGradient(colors: stops) { g.draw(in: cap, angle: 0) } else { Draw.fill(cap, app.rowSelectFill) }
        if let header {
            let f = Draw.ui(Tok.Size.paletteSmallFont, .bold)
            Draw.text(Draw.line(header, f, app.rowSelectInk), font: f, x: cap.minX + 4, top: cap.minY + (cap.height - Tok.Size.paletteSmallFont * lh) / 2,
                      lineHeight: Tok.Size.paletteSmallFont * lh, in: ctx)
        }
        let top = edge + headH, pad = padX
        if let message {
            let mt = 3 + Self.captionH + 10
            drawInfoIcon(NSRect(x: x0 + pad, y: mt, width: Self.messageH, height: Self.messageH))
            let f = Draw.ui(Tok.Size.paletteSmallFont), h = Tok.Size.paletteSmallFont * lh
            Draw.text(Draw.line(message, f, Tok.Color.paletteInk), font: f, x: x0 + pad + Self.messageH + 10, top: mt + (Self.messageH - h) / 2,
                      lineHeight: h, in: ctx)
        }
        // The input glyph labels the field from outside it, like the card's "Open:".
        var fx = x0 + pad
        if Theme.current.effects.paletteInputIcon {
            fx = x0 + padX + Draw.width(Draw.line(inputGlyph, Draw.ui(Tok.Size.paletteInputFont - 1), Tok.Color.paletteMute)) + 6
        }
        let field = NSRect(x: fx, y: top, width: max(x0 + inner - pad - fx, 0), height: Self.fieldH)
        Draw.fill(field, app.paletteField)
        Draw.bevel(field, "in")
        let list = NSRect(x: x0 + pad, y: top + inputH, width: inner - 2 * pad, height: listH)
        Draw.fill(list, app.paletteField)
        Draw.bevel(list, "in")
        let f = Draw.ui(Tok.Size.paletteSmallFont)
        for (label, r, key) in dialogButtons {
            // OK is the default button: a black ring outside its bevel and a dotted focus around its label.
            let isDefault: Bool = if case .enter = key { true } else { false }
            Draw.bevel(isDefault ? r.insetBy(dx: 1, dy: 1) : r, "button")
            if isDefault {
                let ring = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
                NSColor.black.setStroke()
                ring.stroke()
            }
            let line = Draw.line(label, f, Tok.Color.paletteInk), lineH = Tok.Size.paletteSmallFont * lh
            let tx = (r.midX - Draw.width(line) / 2).rounded(), ty = r.minY + (r.height - lineH) / 2
            if isDefault { Draw.dottedRing(NSRect(x: tx - 3, y: ty - 1, width: Draw.width(line) + 6, height: lineH + 2).integral, .black) }
            Draw.text(line, font: f, x: tx, top: ty, lineHeight: lineH, in: ctx)
        }
        let close = dialogClose
        Draw.bevel(close, "button")
        let x = NSBezierPath(), c = close.insetBy(dx: 4.5, dy: 4)
        x.move(to: NSPoint(x: c.minX, y: c.minY)); x.line(to: NSPoint(x: c.maxX, y: c.maxY))
        x.move(to: NSPoint(x: c.maxX, y: c.minY)); x.line(to: NSPoint(x: c.minX, y: c.maxY))
        x.lineWidth = 1.5
        NSColor.black.setStroke()
        x.stroke()
    }

    /// The caption's close box, which does what Escape does.
    private var dialogClose: NSRect { NSRect(x: bounds.width - 3 - 2 - 16, y: 3 + 2, width: 16, height: Self.captionH - 4) }

    /// The dialog's buttons, right-aligned under the list; each does what its key does.
    private var dialogButtons: [(String, NSRect, Key)] {
        guard dialog else { return [] }
        let b = Self.buttonSize, by = edge + headH + inputH + listH + 8, right = edge + width - padX
        return [("Cancel", Key.escape), ("OK", Key.enter)].enumerated().map { i, k in
            (k.0, NSRect(x: right - b.width - CGFloat(i) * (b.width + 6), y: by, width: b.width, height: b.height), k.1)
        }
    }

    /// The card's 32 pt information icon: a white disc with a navy "i".
    private func drawInfoIcon(_ r: NSRect) {
        let disc = NSBezierPath(ovalIn: r.insetBy(dx: 2.5, dy: 2.5))
        NSColor.white.setFill()
        disc.fill()
        NSColor.black.setStroke()
        disc.lineWidth = 1
        disc.stroke()
        let navy = NSColor(srgbRed: 0, green: 0, blue: 0.5, alpha: 1)
        for (x, y, w, h) in [(14.0, 7.0, 4.0, 4.0), (14, 13, 4, 12), (12, 23, 8, 2)] {
            Draw.fill(NSRect(x: r.minX + x, y: r.minY + y, width: w, height: h), navy)
        }
    }

    private func drawInput(_ ctx: CGContext) {
        let ruleX = Tok.Size.paletteListPad[1]
        if inputRules {
            Draw.fill(NSRect(x: ruleX, y: Self.ruleMargin, width: width - 2 * ruleX, height: border), Tok.Color.paletteRule)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: Self.ruleMargin + border)
        }
        defer { if inputRules { ctx.restoreGState() } }
        let padY = Tok.Size.paletteInputPad[0], gap = Tok.Size.paletteInputGap
        let lineH = Tok.Size.paletteInputFont * lh
        let mid = padY + lineH / 2
        Layers.draw("palette.field", NSRect(x: 0, y: 0, width: width, height: inputH), state: Layers.state(self), in: ctx)
        var x = padX
        if Theme.current.effects.paletteInputIcon {
            let f = Draw.ui(Tok.Size.paletteInputFont - 1)
            // The dialog's field label ("Open:") is text, so in ink; elsewhere the glyph is a mark.
            let glyph = Draw.line(inputGlyph, f,
                                  dialog ? Tok.Color.paletteInk : Tok.Color.paletteMute)
            Draw.text(glyph, font: f, x: x, top: padY, lineHeight: lineH, in: ctx)
            x += Draw.width(glyph) + Tok.Size.paletteInputGap
        }
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
        let f = mono(Tok.Size.paletteInputFont, Theme.current.effects.paletteInputWeight == "light" ? .light : .regular)
        if !query.isEmpty {
            let line = Draw.line(query, f, Tok.Color.paletteInk)
            Draw.text(line, font: f, x: x, top: padY, lineHeight: lineH, in: ctx)
            x += Draw.width(line) + Tok.App.paletteCaretGap
        }
        let ch = Tok.Size.paletteCursorH
        Draw.fill(NSRect(x: x, y: mid - ch / 2, width: Tok.App.caretW, height: ch), Tok.Color.paletteInk)
        if query.isEmpty && chip == nil && !placeholder.isEmpty {
            let line = Draw.line(placeholder, f, Tok.Color.paletteMute)
            Draw.text(line, font: f, x: x + gap, top: padY, lineHeight: lineH, in: ctx)
        }
        if !dialog { drawKey("esc", right: width - padX, mid: mid, font: Tok.Size.paletteSmallFont, ctx: ctx) }
        let bottom = padY * 2 + lineH
        if dialog {
            // The field's bevel is its edge.
        } else if inputRules {
            Draw.fill(NSRect(x: ruleX, y: bottom, width: width - 2 * ruleX, height: border), Tok.Color.paletteRule)
        } else {
            Draw.fill(NSRect(x: 0, y: bottom, width: width, height: border), Tok.Color.paletteRule)
        }
    }

    /// The mockup's `.kbd` (and `.jmp` with its own font and line height), right-aligned at `right`.
    @discardableResult
    private func drawKey(_ label: String, right: CGFloat, mid: CGFloat? = nil, top: CGFloat? = nil, font size: CGFloat,
                         lineHeight: CGFloat? = nil, color: NSColor? = nil, ctx: CGContext) -> NSRect {
        let f = mono(size)
        if Theme.current.effects.paletteKeys == "plain" && !plainMode {
            let line = Draw.line(label, f, color ?? Tok.Color.paletteMute)
            let lineH = lineHeight ?? size * lh, w = Draw.width(line)
            let box = NSRect(x: right - w, y: top ?? (mid! - lineH / 2), width: w, height: lineH)
            Draw.text(line, font: f, x: box.minX, top: box.minY, lineHeight: lineH, in: ctx)
            return box
        }
        let line = Draw.line(label, f, color ?? Tok.Color.paletteMute)
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
        let isSel = index == selected && row.action != .none
        let app = Theme.current.app
        if !isSel && index == hovered && Theme.current.effects.rowHover && row.action != .none {
            let inset = pill ? app.palettePillInset : 0, r = pill ? app.palettePillRadius : 0
            app.rowHover.setFill()
            NSBezierPath(roundedRect: NSRect(x: inset, y: top, width: width - 2 * inset, height: h), xRadius: r, yRadius: r).fill()
        }
        if isSel && pill {
            let box = NSRect(x: app.palettePillInset, y: top, width: width - 2 * app.palettePillInset, height: h)
            let shape = NSBezierPath(roundedRect: box, xRadius: app.palettePillRadius, yRadius: app.palettePillRadius)
            Tok.Color.paletteSel.setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let stops = Theme.current.chromeStops
            if !stops.isEmpty { Draw.chrome(box, stops, in: ctx) }
            Draw.fill(NSRect(x: box.minX, y: top, width: box.width, height: border), app.palettePillHighlight)
            NSGraphicsContext.restoreGraphicsState()
            if dialog { Draw.dottedRing(box, app.palettePillInk) }
        } else if isSel && plainMode {
            Draw.fill(NSRect(x: 0, y: top, width: width, height: h), Tok.Color.paletteInk)
        } else if isSel && !plainMode && Theme.current.effects.paletteSelection == "cursor" {
            Draw.fill(NSRect(x: 0, y: top, width: width, height: h), Tok.Color.paletteSel)
            Tok.Color.paletteInk.setFill()
            Draw.cursor(at: NSPoint(x: Tok.Size.paletteSelBar, y: top + Tok.Size.paletteEntryPad[0] + (textLines - 8) / 2))
        } else if isSel {
            Draw.fill(NSRect(x: 0, y: top, width: width, height: h), Tok.Color.paletteSel)
            Draw.fill(NSRect(x: 0, y: top, width: Tok.Size.paletteSelBar, height: h), Tok.Color.paletteInk)
        }
        if isSel || index == hovered && row.action != .none {
            let inset = pill ? app.palettePillInset : 0
            let slot = isSel ? "palette.row.selected" : "palette.row.hover"
            Layers.draw(slot, NSRect(x: inset, y: top, width: width - 2 * inset, height: h),
                        within: NSRect(x: -edge, y: -edge, width: bounds.width, height: bounds.height),
                        state: Layers.state(self, selected: isSel, hover: index == hovered), in: ctx)
        }
        // A plain mode's selection is inverted: its row is ink, its text whichever of black or white reads on it.
        let inverted = isSel && plainMode ? Tok.Color.paletteInk.readable : nil
        let mute = inverted ?? (isSel && pill ? app.palettePillMute : Tok.Color.paletteMute)
        let ink = inverted ?? (isSel && pill ? app.palettePillInk : Tok.Color.paletteInk)
        let gap = Tok.Size.paletteEntryGap
        let y = top + Tok.Size.paletteEntryPad[0]
        let small = mono(Tok.Size.paletteSmallFont), smallH = Tok.Size.paletteSmallFont * lh
        let body = mono(Tok.Size.paletteFont), bodyH = Tok.Size.paletteFont * lh
        let timeX = entryX
        let markX = timeX + Tok.Size.paletteEntryTimeW + gap
        let textX = icons ? entryX + Tok.Size.iconSize + Tok.Size.rowGap[1] : markX + Tok.Size.paletteEntryMarkW + gap
        let right = width - entryX

        if icons {
            let s = Tok.Size.iconSize
            drawIcon(row.icon ?? .shell, in: NSRect(x: entryX, y: y + (textLines - s) / 2, width: s, height: s), ctx: ctx)
        } else if !row.left.isEmpty {
            Draw.text(Draw.line(row.left, small, mute), font: small, x: timeX, top: y, lineHeight: smallH, in: ctx)
        }
        if let mark = row.mark, !icons {
            let s = Tok.Size.paletteMark
            let box = NSRect(x: markX, y: y + Tok.Size.paletteMarkMt, width: s, height: s)
            let path = mark == .round ? NSBezierPath(ovalIn: box.insetBy(dx: border / 2, dy: border / 2))
                : NSBezierPath(rect: box.insetBy(dx: border / 2, dy: border / 2))
            if mark == .filled {
                ink.setFill()
                NSBezierPath(rect: box).fill()
            } else {
                path.lineWidth = border
                ink.setStroke()
                path.stroke()
            }
        }
        var textRight = right
        let keyMid: CGFloat? = singleLine ? y + textLines / 2 : nil
        switch icons && !row.left.isEmpty ? .key(row.left) : row.right {
        case .none: break
        case .jump where icons: break
        case .jump:
            let box = drawKey("↗", right: right, top: y, font: Tok.Size.paletteJmpFont, lineHeight: Tok.Size.paletteJmpLine, color: inverted, ctx: ctx)
            textRight = box.minX - gap
        case let .key(k):
            let box = drawKey(k, right: right, mid: keyMid, top: keyMid == nil ? y : nil, font: Tok.Size.paletteSmallFont, color: mute, ctx: ctx)
            textRight = box.minX - gap
        }
        let titleColor = row.dim ? mute : ink
        let title = Draw.truncated(Draw.line(row.title, body, titleColor), textRight - textX, body, titleColor)
        if singleLine {
            Draw.text(title, font: body, x: textX, top: y + (textLines - bodyH) / 2, lineHeight: bodyH, in: ctx)
            let subX = textX + Draw.width(title) + gap
            if !row.sub.isEmpty, textRight - subX > 0 {
                let sub = Draw.truncated(Draw.line(row.sub, small, mute), textRight - subX, small, mute)
                Draw.text(sub, font: small, x: subX, top: y + (textLines - smallH) / 2, lineHeight: smallH, in: ctx)
            }
        } else {
            Draw.text(title, font: body, x: textX, top: y, lineHeight: bodyH, in: ctx)
            if !row.sub.isEmpty {
                let sub = Draw.truncated(Draw.line(row.sub, small, mute), textRight - textX, small, mute)
                Draw.text(sub, font: small, x: textX, top: y + bodyH, lineHeight: smallH, in: ctx)
            }
        }
        if hasRule(index) {
            Draw.fill(NSRect(x: padX, y: top + h - border, width: width - 2 * padX, height: border), Tok.Color.paletteEntryRule)
        }
    }

    /// `[effects] palette.icons`: the sidebar's icons, a tab's kind or the shell glyph.
    private func drawIcon(_ kind: RowKind, in r: NSRect, ctx: CGContext) {
        if kind != .codex, Draw.pixelIcon(claude: kind == .claude, in: r) { return }
        switch kind {
        case .claude:
            let s = Tok.Size.claudeIcon
            Draw.claudeMark(in: NSRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s))
        case .codex:
            let s = Draw.openAIMarkSize
            Draw.codexMark(in: backingAlignedRect(NSRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s), options: .alignAllEdgesNearest),
                           color: Tok.Color.paletteInk, ctx: ctx)
        case .shell:
            Tok.Color.iconBg.setFill()
            NSBezierPath(roundedRect: r, xRadius: Tok.Size.iconRadius, yRadius: Tok.Size.iconRadius).fill()
            let f = Draw.mono(Tok.Size.iconGlyph), glyphH = Tok.Size.iconGlyph * lh
            let glyph = Draw.line(">_", f, Tok.Color.iconFg)
            Draw.text(glyph, font: f, x: r.midX - Draw.width(glyph) / 2, top: r.midY - glyphH / 2, lineHeight: glyphH, in: ctx)
        }
    }

    private func drawFoot(top: CGFloat, ctx: CGContext) {
        let f = mono(Tok.Size.paletteSmallFont), h = Tok.Size.paletteSmallFont * lh
        if let footText {
            let line = Draw.line(footText, f, Tok.Color.paletteMute, kern: Tok.Size.paletteSmallFont * 0.25)
            Draw.fill(NSRect(x: 0, y: top, width: width, height: border), Theme.current.app.paletteFootRule)
            Draw.text(line, font: f, x: ((width - Draw.width(line)) / 2).rounded(), top: top + border + Tok.Size.paletteFootPad[0], lineHeight: h, in: ctx)
            return
        }
        Draw.fill(NSRect(x: 0, y: top, width: width, height: border), Tok.Color.paletteRule)
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

    /// The visible entry at `p`, in view coordinates.
    private func entry(at p: NSPoint) -> Int? {
        var y = edge + headH + inputH + Tok.Size.paletteListPad[0]
        for i in visible {
            let h = entryH(i)
            if p.y >= y && p.y < y + h { return i }
            y += h
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (_, _, key) = dialogButtons.first(where: { $0.1.contains(p) }) { return send(key) }
        if dialog && dialogClose.contains(p) { return send(Key.escape) }
        guard let i = entry(at: p), rows[i].action != .none else { return }
        selected = i
        needsDisplay = true
        controller?.activate(rows[i])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = entry(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func scrollWheel(with event: NSEvent) {
        let d = event.scrollingDeltaY > 0 ? -1 : event.scrollingDeltaY < 0 ? 1 : 0
        scroll = max(0, min(scroll + d, max(0, rows.count - rowsShown)))
        hovered = entry(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
}
