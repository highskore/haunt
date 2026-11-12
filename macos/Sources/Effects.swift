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

    // Ornament hooks, all off by default: each draws one named element in the theme's own colours.
    /// Square window corners instead of the system's, and a 1 pt `color.window.border` inside the edge.
    var windowSquare = false
    var windowBorder = false
    /// A second, darker rule just above the title bar's (`app.ornament.dim`).
    var titlebarDouble = false
    /// The traffic lights as "circle"s or outlined "diamond"s.
    var lightsShape = "circle"
    /// Group labels with a short rule, a diamond and a rule running out to the edge.
    var labelRule = "none"
    /// The selected row as a "fill", or as two corner "brackets" over a glow from its left edge.
    var rowSelect = "fill"
    /// Rings around the agent icons, and the shell glyph's tile as a "tile" or a turned "diamond".
    var iconRing = false
    var iconShell = "tile"
    /// The progress bar as a solid "bar", or a "dotted" track with a gradient fill and a diamond knob.
    var progressStyle = "bar"
    /// A glow behind the needs-you status, in its own colour.
    var needsGlow = false
    /// The needs-you status's weight when it isn't a pill.
    var needsWeight = "regular"
    /// Artwork drawn in code: "sigil" puts a star in the pane and the sidebar's foot and marks the window's corners.
    var ornament = "none"
    /// How far the bottom-right palette stands in from the window's edges.
    var paletteInset: CGFloat = 22
    /// The palette's `[strings] palette.header` above its input, and rules above and below the input.
    var paletteHeader = false
    var paletteInputRules = false
    /// A "bevel"led window frame (`app.window.pad` in from its edge), and a sunken pane.
    var windowFrame = "none"
    var paneFrame = "none"
    /// The title bar "plain", or a "caption": `app.titlebar.fill` behind a left-aligned title and the lights as
    /// window buttons on the right; with a ghost icon before the title, and a row of the app's menus under it.
    var titlebarStyle = "plain"
    var titlebarIcon = false
    var titlebarMenu = false
    /// The progress bar as "segments" in a sunken track; the agent icons as pixel art.
    var iconStyle = "vector"
    /// The palette as a "panel" or a "dialog": a caption with `[strings] palette.header`, a sunken field and list.
    var paletteFrame = "panel"
    /// The theme UI face's regular text drawn "light" (CSS 300), as a card sets it.
    var uiWeight = "regular"
    /// The tab names in `app.display.font` instead of the UI face.
    var nameFont = "ui"

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
        "needs.pill": .bool(\.needsPill),
        "bar.radius": .number(\.barRadius, 0...10),
        "bar.glow": .bool(\.barGlow),
        "bar.done": .bool(\.barDone),
        "palette.material": .choice(\.paletteMaterial, ["none", "glass"]),
        "palette.tab.sub": .choice(\.paletteTabSub, ["meta", "task"]),
        "palette.blur": .choice(\.paletteBlur, Array(Effects.blurs.keys).sorted()),
        "palette.font": .choice(\.paletteFont, ["mono", "ui"]),
        "palette.icons": .bool(\.paletteIcons),
        "palette.selection": .choice(\.paletteSelection, ["bar", "pill", "cursor"]),
        "palette.foot": .bool(\.paletteFoot),
        "palette.scrim": .bool(\.paletteScrim),
        "palette.keys": .choice(\.paletteKeys, ["box", "plain"]),
        "palette.input.icon": .bool(\.paletteInputIcon),
        "palette.input.weight": .choice(\.paletteInputWeight, ["regular", "light"]),
        "palette.modes": .choice(\.paletteModes, ["styled", "plain"]),
        "window.square": .bool(\.windowSquare),
        "window.border": .bool(\.windowBorder),
        "titlebar.double": .bool(\.titlebarDouble),
        "lights.shape": .choice(\.lightsShape, ["circle", "diamond", "boxes", "squares"]),
        "label.rule": .choice(\.labelRule, ["none", "diamond", "groupbox", "block"]),
        "row.select": .choice(\.rowSelect, ["fill", "brackets", "name", "cursor"]),
        "icon.ring": .bool(\.iconRing),
        "icon.shell": .choice(\.iconShell, ["tile", "diamond"]),
        "progress.style": .choice(\.progressStyle, ["bar", "dotted", "segments"]),
        "needs.glow": .bool(\.needsGlow),
        "needs.weight": .choice(\.needsWeight, ["regular", "bold"]),
        "ornament": .choice(\.ornament, ["none", "sigil", "lcd"]),
        "palette.inset": .number(\.paletteInset, 0...80),
        "palette.header": .bool(\.paletteHeader),
        "palette.input.rules": .bool(\.paletteInputRules),
        "window.frame": .choice(\.windowFrame, ["none", "bevel"]),
        "pane.frame": .choice(\.paneFrame, ["none", "bevel"]),
        "titlebar.style": .choice(\.titlebarStyle, ["plain", "caption"]),
        "titlebar.icon": .bool(\.titlebarIcon),
        "titlebar.menu": .bool(\.titlebarMenu),
        "icon.style": .choice(\.iconStyle, ["vector", "pixel"]),
        "palette.frame": .choice(\.paletteFrame, ["panel", "dialog"]),
        "ui.weight": .choice(\.uiWeight, ["regular", "light"]),
        "name.font": .choice(\.nameFont, ["ui", "display"]),
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
