import AppKit

/// A theme's `[effects]`: named elements Haunt knows how to draw, switched on and sized by the theme.
/// Data only: each key is one of a fixed set, with a type and range checked on load.
struct Effects: Equatable {
    /// `palette.blur`'s names for NSVisualEffectView's materials.
    static let blurs: [String: NSVisualEffectView.Material] = [
        "hud": .hudWindow, "window": .windowBackground, "sheet": .sheet, "menu": .menu, "popover": .popover,
        "sidebar": .sidebar, "under-window": .underWindowBackground, "full-screen": .fullScreenUI,
    ]

    /// "none", or "glass": the window shows the desktop through a blurred material.
    var windowMaterial = "none"
    /// The window's corner radius; 0 keeps the system's.
    var windowRadius: CGFloat = 0
    /// A light ring inside the window's edge and a highlight along its top ([app] window.ring, window.highlight).
    var windowRing = false
    /// The rule under the title bar.
    var titlebarRule = true
    /// "grey" traffic lights at rest, or macOS's "color" ones.
    var titlebarLights = "grey"
    /// The sidebar's footer: the live agent count on the left.
    var sidebarFooter = false
    /// Group labels "upper"case and tracked, or in "sentence" case; and their weight.
    var labelCase = "upper"
    var labelWeight = "regular"
    /// How far a row's background stands in from the sidebar's sides, and its corner radius.
    var rowInset: CGFloat = 0
    var rowRadius: CGFloat = 0
    /// The selected row is lifted: a ring, a top highlight and a soft shadow ([app] row.raised.*).
    var rowRaised = false
    /// The row under the pointer, in the sidebar and the palette, gets a faint fill ([app] row.hover) shaped
    /// like the selection.
    var rowHover = false
    /// The needs-you status is a pill ([app] pill.*).
    var needsPill = false
    /// The progress bar's corner radius, and a glow in its fill colour.
    var barRadius: CGFloat = 0
    var barGlow = false
    /// A finished task's full bar stays; off, only work in progress has one.
    var barDone = true
    /// The palette: the desktop blurred behind it, a ring like the window's, its type, each row's tab icon
    /// on the left (keys move right), the selection as a "bar" or a rounded "pill", the hints line, and the
    /// scrim over the window.
    var paletteMaterial = "none"
    /// Which of macOS's blur materials a glass palette uses; each has its own tint under `palette.bg`.
    var paletteBlur = "hud"
    /// What a tab's entry shows after its name: its whole meta line, or only the agent's task.
    var paletteTabSub = "meta"
    var paletteFont = "mono"
    var paletteIcons = false
    var paletteSelection = "bar"
    var paletteFoot = true
    var paletteScrim = true
    /// The palette's keys in a "box" or as "plain" text, a search glyph before the query, and the query's weight.
    var paletteKeys = "box"
    var paletteInputIcon = false
    var paletteInputWeight = "regular"
    /// A plugin mode's rows (the decision log) "styled" like the rest, or "plain": the black-and-white layout,
    /// mono font and boxed keys, with the selection inverted; only the panel and colours follow the theme.
    var paletteModes = "styled"

    enum Key {
        case bool(WritableKeyPath<Effects, Bool>)
        case number(WritableKeyPath<Effects, CGFloat>, ClosedRange<CGFloat>)
        case choice(WritableKeyPath<Effects, String>, [String])
    }

    static let keys: [String: Key] = [
        "window.material": .choice(\.windowMaterial, ["none", "glass"]),
        "window.radius": .number(\.windowRadius, 0...40),
        "window.ring": .bool(\.windowRing),
        "titlebar.rule": .bool(\.titlebarRule),
        "titlebar.lights": .choice(\.titlebarLights, ["grey", "color"]),
        "sidebar.footer": .bool(\.sidebarFooter),
        "label.case": .choice(\.labelCase, ["upper", "sentence"]),
        "label.weight": .choice(\.labelWeight, ["regular", "medium", "semibold"]),
        "row.inset": .number(\.rowInset, 0...40),
        "row.radius": .number(\.rowRadius, 0...40),
        "row.raised": .bool(\.rowRaised),
        "row.hover": .bool(\.rowHover),
        "needs.pill": .bool(\.needsPill),
        "bar.radius": .number(\.barRadius, 0...10),
        "bar.glow": .bool(\.barGlow),
        "bar.done": .bool(\.barDone),
        "palette.material": .choice(\.paletteMaterial, ["none", "glass"]),
        "palette.tab.sub": .choice(\.paletteTabSub, ["meta", "task"]),
        "palette.blur": .choice(\.paletteBlur, Array(Effects.blurs.keys).sorted()),
        "palette.font": .choice(\.paletteFont, ["mono", "ui"]),
        "palette.icons": .bool(\.paletteIcons),
        "palette.selection": .choice(\.paletteSelection, ["bar", "pill"]),
        "palette.foot": .bool(\.paletteFoot),
        "palette.scrim": .bool(\.paletteScrim),
        "palette.keys": .choice(\.paletteKeys, ["box", "plain"]),
        "palette.input.icon": .bool(\.paletteInputIcon),
        "palette.input.weight": .choice(\.paletteInputWeight, ["regular", "light"]),
        "palette.modes": .choice(\.paletteModes, ["styled", "plain"]),
    ]

    /// nil when `name` took `value`; otherwise why not.
    mutating func set(_ name: String, _ value: TOML.Value) -> String? {
        guard let key = Self.keys[name] else { return "unknown effect" }
        guard case .scalar = value, let s = value.strings.first else { return "not a single value" }
        switch key {
        case let .bool(path):
            guard s == "true" || s == "false" else { return "not true or false" }
            self[keyPath: path] = s == "true"
        case let .number(path, range):
            guard let n = Double(s).map({ CGFloat($0) }) else { return "not a number" }
            guard range.contains(n) else { return "outside \(Int(range.lowerBound))–\(Int(range.upperBound))" }
            self[keyPath: path] = n
        case let .choice(path, options):
            guard options.contains(s) else { return "not one of \(options.joined(separator: ", "))" }
            self[keyPath: path] = s
        }
        return nil
    }
}
