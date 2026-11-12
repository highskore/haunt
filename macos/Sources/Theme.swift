import AppKit

extension Theme {
    /// Where a token lives in `Theme`, by the type a theme file must give it.
    enum Key {
        case color(WritableKeyPath<Theme, NSColor>)
        case number(WritableKeyPath<Theme, CGFloat>)
        case numbers(WritableKeyPath<Theme, [CGFloat]>)
        case string(WritableKeyPath<Theme, String>)
        case strings(WritableKeyPath<Theme, [String]>)
    }

    /// The tokens on screen. Main thread only; set by `HauntConfig.reload`.
    static var current = Theme()

    /// The tables a theme file may override, each prefixing its keys to make a tokens.json name.
    static let tables = ["color", "size", "font", "app"]
    /// Sizes outside this are refused: a typo shouldn't push the window off the screen.
    static let sizeRange: ClosedRange<CGFloat> = 0...400
    /// Numbers with a range of their own instead of `sizeRange`.
    static let numberRanges: [String: ClosedRange<CGFloat>] = ["app.ornament.alpha": 0...0.12]
    /// Kept in every theme: Claude's mark is always its own orange.
    static let locked: Set<String> = ["color.claude"]

    private static let allKeys = keys.merging(AppTokens.keys) { a, _ in a }

    /// Sets each token in `toml`'s token tables; returns what it refused, naming `file`. `uiOnly` are the font
    /// names (normalised) only a user-installed theme plugin provides: they may draw the UI, never the terminal.
    mutating func override(with toml: [String: [String: TOML.Value]], file: String, uiOnly: Set<String> = []) -> [String] {
        var problems: [String] = []
        for table in Self.tables {
            for (k, v) in (toml[table] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let name = "\(table).\(k)"
                if name.hasPrefix("font."), name != "font.ui", v.strings.contains(where: { ThemeFonts.names(in: $0).contains(where: uiOnly.contains) }) {
                    problems.append("\(file): \(name): \(Self.uiOnlyWhy), ignored")
                    continue
                }
                if let why = set(name, v) { problems.append("\(file): \(name): \(why), ignored") }
            }
        }
        for (k, v) in (toml["effects"] ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let why = effects.set(k, v) { problems.append("\(file): effects.\(k): \(why), ignored") }
        }
        for (k, v) in (toml["strings"] ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let why = setString(k, v) { problems.append("\(file): strings.\(k): \(why), ignored") }
        }
        return problems
    }

    /// The places a theme may word, each one plain line; `{day.roman}`, `{month.roman}`, `{year.roman}`,
    /// `{agents}` and `{agents.roman}` fill in when drawn.
    static let stringKeys: Set<String> = ["row.sub.prefix", "titlebar.right", "palette.header", "palette.foot", "palette.input.glyph", "palette.message", "sidebar.foot"]
    static let maxStringScalars = 64
    /// Haunt's own status words: a theme's text may not pass for an agent's state or a decision.
    static let statusWords = #"(?i)\b(needs you|allow|deny|approved|permission|request|waiting|done)"#
    /// More marks than this on one character stack it above and below its line ("zalgo").
    static let maxCombiningMarks = 2

    private mutating func setString(_ name: String, _ value: TOML.Value) -> String? {
        guard Self.stringKeys.contains(name) else { return "unknown string" }
        guard case let .scalar(s) = value else { return "not a string" }
        guard s.unicodeScalars.count <= Self.maxStringScalars else { return "longer than \(Self.maxStringScalars) code points" }
        guard s.allSatisfy({ c in
            c.unicodeScalars.filter { [.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory) }.count
                <= Self.maxCombiningMarks
        }) else { return "more than \(Self.maxCombiningMarks) combining marks on a character" }
        guard s.unicodeScalars.allSatisfy({ !TitleFormat.hidden($0) }) else { return "not one plain line" }
        if s.range(of: Self.statusWords, options: .regularExpression) != nil { return "uses one of Haunt's status words" }
        if name == "sidebar.foot", !s.contains("{agents}"), !s.contains("{agents.roman}") { return "must show {agents} or {agents.roman}" }
        app.strings[name] = s
        return nil
    }

    /// The theme's words for `key` with its tokens filled in, or nil when it has none.
    func string(_ key: String, agents: Int = 0, now: Date = Date()) -> String? {
        guard var s = app.strings[key] else { return nil }
        let d = Calendar(identifier: .gregorian).dateComponents([.day, .month, .year], from: now)
        for (token, n) in [("{day.roman}", d.day ?? 0), ("{month.roman}", d.month ?? 0), ("{year.roman}", d.year ?? 0),
                           ("{agents.roman}", agents)] {
            s = s.replacingOccurrences(of: token, with: Self.roman(n))
        }
        return s.replacingOccurrences(of: "{agents}", with: String(agents))
    }

    /// 1–3999 in Roman numerals; anything else in digits.
    static func roman(_ n: Int) -> String {
        guard (1...3999).contains(n) else { return String(n) }
        let table = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                     (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (v, r) in table { while n >= v { out += r; n -= v } }
        return out
    }

    /// `app.text.chrome`'s stops, or none if any isn't a colour.
    var chromeStops: [NSColor] {
        let c = app.textChrome.compactMap { NSColor(themeHex: $0) }
        return c.count == app.textChrome.count ? c : []
    }

    /// nil when `name` took `value`; otherwise why not.
    private mutating func set(_ name: String, _ value: TOML.Value) -> String? {
        guard let key = Self.allKeys[name] else { return "unknown token" }
        if Self.locked.contains(name) { return "can't be changed by a theme" }
        let s = value.strings
        if s.contains(where: { $0.contains(where: \.isNewline) }) { return "line break" }
        switch key {
        case let .color(path):
            guard case .scalar = value, let c = NSColor(themeHex: s[0]) else { return "not #rrggbb or #rrggbbaa" }
            if Self.seeThrough.contains(name), c.alphaComponent < Self.minAlpha {
                return "must be at least \(Int(Self.minAlpha * 100))% opaque"
            }
            if Self.opaque(name), c.alphaComponent < 1 { return "must be opaque: text and indicators can't be faded" }
            self[keyPath: path] = c
        case let .number(path):
            guard case .scalar = value, let n = Double(s[0]) else { return "not a number" }
            let range = Self.numberRanges[name] ?? Self.sizeRange
            guard range.contains(CGFloat(n)) else { return "outside \(String(format: "%g", range.lowerBound))–\(String(format: "%g", range.upperBound))" }
            self[keyPath: path] = CGFloat(n)
        case let .numbers(path):
            let want = self[keyPath: path].count
            let ns = s.compactMap(Double.init).map { CGFloat($0) }
            guard case .array = value, ns.count == s.count, ns.count == want else { return "needs \(want) numbers" }
            guard ns.allSatisfy(Self.sizeRange.contains) else { return "outside \(Int(Self.sizeRange.lowerBound))–\(Int(Self.sizeRange.upperBound))" }
            self[keyPath: path] = ns
        case let .string(path):
            guard case .scalar = value, !s[0].isEmpty else { return "not a string" }
            if name.hasPrefix("font.") || name == "app.display.font", name != "font.mono.css", !Self.installed(s[0]) {
                return "font \(s[0]) isn't installed"
            }
            self[keyPath: path] = s[0]
        case let .strings(path):
            guard case .array = value else { return "not a list" }
            self[keyPath: path] = s
        }
        return nil
    }

    /// A colour a theme must leave readable, the backgrounds it is drawn over (bottom first), and the least
    /// contrast it needs: 3:1 for content, 1.5:1 for guides such as line numbers.
    struct Readable {
        let fg: String, over: [String], min: CGFloat
    }

    /// Every colour token is here as text or an indicator, or in `decorative`; a test keeps it that way, so a new
    /// token can't slip past the opacity and contrast rules.
    static let readable: [Readable] = {
        let content: [(String, [String])] = [
            ("color.needs", ["color.window.bg", "color.sidebar.bg"]),
            ("color.diff.add.ink", ["color.window.bg", "color.diff.add.bg"]),
            ("color.diff.add.mark", ["color.window.bg", "color.diff.add.bg"]),
            ("color.diff.del.ink", ["color.window.bg", "color.diff.del.bg"]),
            ("color.diff.text", ["color.window.bg"]),
            ("color.inbox.diff.add.ink", ["color.window.bg", "color.inbox.diff.add.bg"]),
            ("color.inbox.diff.add.mark", ["color.window.bg", "color.inbox.diff.add.bg"]),
            ("color.inbox.diff.del.ink", ["color.window.bg"]),
            ("color.inbox.diff.del.mark", ["color.window.bg"]),
            ("color.inbox.diff.text", ["color.window.bg"]),
            ("color.inbox.diff.kw", ["color.window.bg"]),
            ("color.inbox.diff.kw", ["color.window.bg", "color.inbox.diff.add.bg"]),
            ("color.inbox.diff.str", ["color.window.bg"]),
            ("color.inbox.diff.str", ["color.window.bg", "color.inbox.diff.add.bg"]),
            ("color.inbox.diff.hunk.ink", ["color.window.bg", "color.inbox.diff.hunk.bg"]),
            ("color.inbox.file.ink", ["color.window.bg"]),
            ("color.inbox.prompt", ["color.window.bg"]),
            ("color.review.body", ["color.window.bg"]),
            ("color.text.primary", ["color.window.bg"]),
            ("color.text.primary", ["color.window.bg", "color.sidebar.bg"]),
            ("color.text.sub", ["color.window.bg", "color.sidebar.bg"]),
            ("color.text.meta", ["color.window.bg", "color.sidebar.bg"]),
            ("color.text.label", ["color.window.bg", "color.sidebar.bg"]),
            ("color.text.hi", ["color.window.bg"]),
            ("color.text.ok", ["color.window.bg"]),
            ("color.palette.ink", ["color.palette.bg"]),
            ("color.palette.mute", ["color.palette.bg"]),
            ("color.statusmenu.ink", ["color.statusmenu.bg"]),
            ("color.statusmenu.hl.fg", ["color.statusmenu.bg", "color.statusmenu.ink"]),
            ("color.palette.chip.fg", ["color.palette.bg", "color.palette.ink"]),
            ("color.btn.fg", ["color.window.bg"]),
            ("color.btn.fg", ["color.window.bg", "color.review.panel.bg"]),
            ("color.btn.primary.fg", ["color.window.bg", "color.btn.primary.bg"]),
            ("color.btn.primary.fg", ["color.window.bg", "color.review.panel.bg", "color.btn.primary.bg"]),
            ("app.title.fg", ["color.window.bg"]),
            ("app.title.meta", ["color.window.bg"]),
            ("app.sidebar.foot.fg", ["color.window.bg", "color.sidebar.bg"]),
            ("app.pill.fg", ["color.window.bg", "color.sidebar.bg", "app.pill.bg"]),
            ("app.palette.pill.ink", ["color.palette.bg", "color.palette.sel"]),
            ("app.row.select.ink", ["color.sidebar.bg", "color.row.selected"]),
        ]
        let guides: [(String, [String])] = [
            ("color.diff.mark", ["color.window.bg"]),
            ("color.diff.num", ["color.window.bg"]),
            ("color.diff.num", ["color.window.bg", "color.diff.hunk.bg"]),
            ("color.diff.add.num", ["color.window.bg", "color.diff.add.bg"]),
            ("color.inbox.diff.add.num", ["color.window.bg", "color.inbox.diff.add.bg"]),
            ("color.inbox.diff.num", ["color.window.bg"]),
            ("color.inbox.diff.cm", ["color.window.bg"]),
            ("color.inbox.diff.cm", ["color.window.bg", "color.inbox.diff.add.bg"]),
            ("color.text.placeholder", ["color.window.bg"]),
            ("color.statusmenu.mute", ["color.statusmenu.bg"]),
            // A primary button's shortcut, and an unticked overview mark.
            ("color.review.mark.off", ["color.window.bg"]),
            ("color.review.mark.off", ["color.window.bg", "color.btn.primary.bg"]),
            ("color.review.mark.off", ["color.window.bg", "color.review.panel.bg", "color.btn.primary.bg"]),
            // The shell glyph on its tile, in the sidebar and the palette.
            ("color.icon.fg", ["color.window.bg", "color.sidebar.bg", "color.icon.bg"]),
            ("color.icon.fg", ["color.palette.bg", "color.icon.bg"]),
        ]
        return content.map { Readable(fg: $0.0, over: $0.1, min: 3) } + guides.map { Readable(fg: $0.0, over: $0.1, min: 1.5) }
    }()

    /// Fills, borders and rules: a theme may fade them as it likes.
    static let decorative: Set<String> = [
        // Checked against the terminal's own background, which [ghostty] may set, by enforceContrast.
        "color.text.terminal",
        "color.bar.fill", "color.bar.track", "color.btn.primary.bg", "color.card.bg",
        "color.card.border", "color.claude", "color.diff.add.bg", "color.diff.del.bg", "color.diff.hunk.bg", "color.diff.rule",
        "color.diff.sel", "color.diff.sq.add", "color.dot", "color.dot.hollow", "color.float.border", "color.focus.expanded.bg",
        "color.focus.term.border", "color.hairline", "color.icon.bg", "color.inbox.blocks.del",
        "color.inbox.btn.key.border", "color.inbox.ck.border", "color.inbox.diff.add.bar", "color.inbox.diff.add.bg",
        "color.inbox.diff.del.bar", "color.inbox.diff.hunk.bg", "color.inbox.diff.hunk.rule", "color.inbox.fh.bg",
        "color.inbox.file.sel", "color.kbd.border", "color.lights", "color.monitor.bg", "color.palette.bg", "color.palette.border",
        "color.palette.entry.rule", "color.palette.rule", "color.palette.sel", "color.review.avatar.bg",
        "color.review.input.border", "color.review.note.bg", "color.review.note.border",
        "color.review.panel.bg", "color.row.selected", "color.sidebar.bg", "color.statusmenu.bg", "color.statusmenu.border",
        "color.statusmenu.line", "color.table.rule", "color.ticker.sep", "color.window.bg",
        "color.window.border", "color.zen.track",
        "app.scrim", "app.window.ring", "app.window.highlight", "app.palette.ring", "app.palette.highlight", "app.row.raised.ring",
        "app.row.raised.highlight", "app.row.raised.shadow", "app.row.hover", "app.pill.bg", "app.pill.ring", "app.palette.pill.highlight",
        "app.palette.pill.mute", "app.ornament", "app.ornament.dim", "app.titlebar.rule2", "app.bar.knob", "app.bevel.light", "app.bevel.hi", "app.bevel.shade", "app.bevel.dark", "app.palette.field",
    ]

    /// Secondary text that may be see-through, down to `minAlpha`: its contrast is judged blended.
    static let seeThrough: Set<String> = ["color.text.meta", "color.text.sub", "color.text.label", "app.title.meta", "app.sidebar.foot.fg",
                                          "color.icon.fg", "color.palette.mute"]
    static let minAlpha: CGFloat = 0.4

    /// Text and the indicators that say what an agent did or needs: never see-through, bar `seeThrough`.
    static func opaque(_ name: String) -> Bool {
        !seeThrough.contains(name) && readable.contains { $0.fg == name }
    }

    /// The colour token named `name`; nil if it isn't one.
    static func colorPath(_ name: String) -> WritableKeyPath<Theme, NSColor>? {
        if case let .color(p) = allKeys[name] { return p }
        return nil
    }

    /// Each `readable` colour under its minimum on any of its backgrounds, redrawn in black or white,
    /// whichever reads better on all of them: the token and its worst contrast before.
    mutating func makeReadable() -> [(String, CGFloat)] {
        var fixed: [(String, CGFloat)] = []
        let base: NSColor = app.appearance == "light" ? .white : .black
        var names: [String] = []
        for r in Self.readable where !names.contains(r.fg) { names.append(r.fg) }
        for name in names {
            guard let fg = Self.colorPath(name) else { continue }
            let uses = Self.readable.filter { $0.fg == name }.map { r in
                (bg: r.over.compactMap(Self.colorPath).reduce(base) { self[keyPath: $1].over($0) }, min: r.min)
            }
            // How far `c` is from failing, at its worst: below 1 fails somewhere.
            let margin = { (c: NSColor) in uses.map { c.over($0.bg).contrast($0.bg) / $0.min }.min() ?? 1 }
            let now = margin(self[keyPath: fg])
            guard now < 1 else { continue }
            fixed.append((name, uses.map { self[keyPath: fg].over($0.bg).contrast($0.bg) }.min() ?? 0))
            let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            self[keyPath: fg] = margin(black) >= margin(white) ? black : white
        }
        return fixed
    }

    static let uiOnlyWhy = "a font from a theme plugin that didn't come with Haunt may only set font.ui"

    /// Core Text's list, not NSFontManager's, which keeps a theme font it has seen after it is unregistered.
    static func installed(_ family: String) -> Bool {
        (CTFontManagerCopyAvailableFontFamilyNames() as? [String])?.contains(family) == true || ThemeFonts.isPrivate(family)
    }

    /// Every token by its tokens.json name, colours as #rrggbbaa: the one place plugins read theme colours from.
    func exported() -> [String: String] {
        var out: [String: String] = [:]
        for (name, key) in Self.allKeys {
            switch key {
            case let .color(p): out[name] = self[keyPath: p].themeHex
            case let .number(p): out[name] = HauntConfig.num(self[keyPath: p])
            case let .numbers(p): out[name] = self[keyPath: p].map(HauntConfig.num).joined(separator: " ")
            case let .string(p): out[name] = self[keyPath: p]
            case let .strings(p): out[name] = self[keyPath: p].joined(separator: ", ")
            }
        }
        return out
    }
}

/// A theme an installed theme plugin carries: its file and fonts, inside the plugin's folder.
struct PluginTheme: Equatable {
    var file: URL
    var fonts: [URL]
    /// Installed from the signed app; only then may its fonts draw the terminal.
    var bundled = false
}

/// A theme as loaded: its tokens, the `[layout]` and `[ghostty]` keys it adds under the user's own, and the
/// files whose changes should reload it.
struct LoadedTheme {
    var name = "bw"
    var theme = Theme()
    var layout: [String: TOML.Value] = [:]
    var ghostty: [String: TOML.Value] = [:]
    /// Every path the lookup tried, present or not, so creating a missing theme file reloads too.
    var files: [URL] = []
    /// The bundled plugin fonts the chain uses; registered for the process while it is on screen.
    var fonts: [URL] = []
    /// The user-installed plugin fonts it uses: never registered, only `font.ui` draws with them.
    var uiFonts: [URL] = []
    var problems: [String] = []

    static let maxDepth = 4
    /// The same cap the plugin store puts on a theme plugin's file.
    static let maxBytes = 256 << 10

    /// A theme file's text, or nil when it can't be read or is over `maxBytes`.
    static func readTheme(_ url: URL) -> String? { read(url, max: maxBytes) }

    /// A UTF-8 file's text, or nil when it can't be read or is over `max` bytes.
    static func read(_ url: URL, max: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data: Data
        do {
            // nil is an empty file.
            data = try h.read(upToCount: max + 1) ?? Data()
        } catch {
            return nil
        }
        guard data.count <= max else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `name` from `~/.haunt/themes`, else from a theme plugin, else from the app's bundled themes; `extends`
    /// chains apply ancestors first. `activate` gets the chain's plugin fonts before any font token is checked.
    /// An unknown or broken theme falls back to the default, with the reason in `problems`.
    static func load(_ name: String?, userDir: URL, plugins: [String: PluginTheme] = [:], bundled: URL?,
                     activate: (_ registered: [URL], _ uiOnly: [URL]) -> Void = { _, _ in }) -> LoadedTheme {
        var out = LoadedTheme()
        guard let name, name != "bw" else { return out }
        var chain: [(String, [String: [String: TOML.Value]], String, URL)] = []
        var next: String? = name
        while let n = next, n != "bw" {
            guard n.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
                return out.failed(name, "theme name \"\(n)\" must be lowercase letters, digits and dashes")
            }
            if chain.contains(where: { $0.0 == n }) { return out.failed(name, "theme \(n) extends itself") }
            if chain.count == maxDepth { return out.failed(name, "more than \(maxDepth) themes in the extends chain") }
            let candidates = [userDir.appendingPathComponent("themes/\(n).toml"), plugins[n]?.file,
                              bundled?.appendingPathComponent("\(n).toml")].compactMap { $0 }
            out.files += candidates
            guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                return out.failed(name, "theme \(n) not found in \(candidates[0].deletingLastPathComponent().path)")
            }
            guard let text = readTheme(url) else {
                return out.failed(name, "theme \(n) is unreadable or larger than \(maxBytes >> 10) KB")
            }
            let toml = TOML.parse(text) { out.problems.append("\(url.lastPathComponent): \($0)") }
            chain.append((n, toml, url.lastPathComponent, url))
            next = toml[""]?["extends"]?.strings.first
        }
        out.name = name
        // A plugin's fonts only come with the plugin's own file, not a user file of the same name.
        let used = chain.compactMap { n, _, _, url in plugins[n].flatMap { $0.file == url ? $0 : nil } }
        // A user-installed plugin's font may not take the name of one already on the Mac, the terminal's included.
        let user = used.filter { !$0.bundled }.flatMap(\.fonts)
        let taken = user.isEmpty ? [] : ThemeFonts.installedNames(excluding: ThemeFonts.active)
        for url in user where !ThemeFonts.names(url).isDisjoint(with: taken) {
            out.problems.append("\(url.lastPathComponent): has the name of a font already installed, not loaded")
        }
        out.fonts = used.filter(\.bundled).flatMap(\.fonts)
        out.uiFonts = user.filter { ThemeFonts.names($0).isDisjoint(with: taken) }
        activate(out.fonts, out.uiFonts)
        let uiOnly = Set(out.uiFonts.flatMap(ThemeFonts.names))
        for (_, toml, file, _) in chain.reversed() {
            out.problems += out.theme.override(with: toml, file: file, uiOnly: uiOnly)
            if let a = toml[""]?["appearance"]?.strings.first {
                if a == "dark" || a == "light" { out.theme.app.appearance = a } else { out.problems.append("\(file): appearance must be \"dark\" or \"light\", ignored") }
            }
            out.layout.merge(toml["layout"] ?? [:]) { _, child in child }
            var ghostty = toml["ghostty"] ?? [:]
            for key in ghostty.keys.sorted() where !themeMaySet(key) {
                ghostty[key] = nil
                out.problems.append("\(file): [ghostty] \(key) is not an appearance key a theme may set, ignored")
            }
            for key in ghostty.keys.sorted() where key.hasPrefix("font-family") && ghostty[key]!.strings.contains(where: { ThemeFonts.names(in: $0).contains(where: uiOnly.contains) }) {
                ghostty[key] = nil
                out.problems.append("\(file): [ghostty] \(key): \(Theme.uiOnlyWhy), ignored")
            }
            out.ghostty.merge(ghostty) { _, child in child }
        }
        out.problems += out.enforceContrast()
        let opacity = out.ghostty["background-opacity"]?.strings.first.flatMap(Double.init) ?? 1
        out.theme.app.terminalSeeThrough = opacity < 1 && out.theme.color.windowBg.alphaComponent < 1
        return out
    }

    /// WCAG's ratio for large text and indicators.
    static let minContrast: CGFloat = 3
    static let minBlurTint: CGFloat = 0.5

    /// Redraws in black or white, whichever reads better, any text or indicator a theme left too faint against
    /// its background, the terminal's included: a theme must not hide a needs-you mark, a diff or what the
    /// terminal shows. A colour the theme set itself is reported. See-through backgrounds are judged over black
    /// (white for a light theme).
    private mutating func enforceContrast() -> [String] {
        var problems: [String] = []
        let bw = Theme()
        let base: NSColor = theme.app.appearance == "light" ? .white : .black
        // Behind a blurred palette the desktop shows through; the tint must carry at least half the colour.
        if theme.effects.paletteMaterial == "glass", theme.color.paletteBg.alphaComponent < Self.minBlurTint {
            problems.append("color.palette.bg: a blurred palette needs at least \(Int(Self.minBlurTint * 100))% opacity, raised to it")
            theme.color.paletteBg = theme.color.paletteBg.withAlphaComponent(Self.minBlurTint)
        }
        problems += checkChrome(over: base)
        let before = theme
        for (name, ratio) in theme.makeReadable() {
            if let p = Theme.colorPath(name), before[keyPath: p] != bw[keyPath: p] { problems.append(Self.faint(name, ratio)) }
        }
        func hex(_ k: String) -> NSColor? { ghostty[k]?.strings.first.flatMap { NSColor(themeHex: $0.hasPrefix("#") ? $0 : "#" + $0) } }
        for k in ["foreground", "background"] where ghostty[k] != nil && hex(k) == nil {
            ghostty[k] = nil
            problems.append("[ghostty] \(k): not #rrggbb, ignored")
        }
        let bg = (hex("background") ?? theme.color.windowBg).over(base)
        let ratio = (hex("foreground") ?? theme.color.textTerminal).contrast(bg)
        if ratio < Self.minContrast {
            if ghostty["foreground"] != nil || theme.color.textTerminal != bw.color.textTerminal {
                problems.append(Self.faint("the terminal's text on its background", ratio))
            }
            theme.color.textTerminal = bg.readable
            ghostty["foreground"] = nil
        }
        problems += terminalColors(over: bg)
        return problems
    }

    /// Chrome text must read at every stop on each background it is drawn over, and a pill's text on every stop;
    /// otherwise the text is drawn flat.
    /// The stops and `chromeSampling` points between each pair, mixed in sRGB as `Draw.chrome`'s gradient mixes them.
    static func chromeSamples(_ stops: [NSColor]) -> [NSColor] {
        let rgb = stops.compactMap { $0.usingColorSpace(.sRGB) }
        guard let last = rgb.last else { return [] }
        var out: [NSColor] = []
        for (a, b) in zip(rgb, rgb.dropFirst()) {
            for i in 0..<chromeSampling {
                let t = CGFloat(i) / CGFloat(chromeSampling)
                out.append(NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                                   green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                                   blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1))
            }
        }
        return out + [last]
    }

    static let chromeSampling = 16

    private mutating func checkChrome(over base: NSColor) -> [String] {
        guard !theme.app.textChrome.isEmpty else { return [] }
        let stops = theme.chromeStops
        let c = theme.color
        let grounds = [c.windowBg, c.sidebarBg.over(c.windowBg), c.paletteBg].map { $0.over(base) }
        let pill = theme.app.palettePillInk
        let ok = !stops.isEmpty && stops.allSatisfy { $0.alphaComponent == 1 } && Self.chromeSamples(stops).allSatisfy { s in
            grounds.allSatisfy { s.contrast($0) >= Self.minContrast } && pill.over(s).contrast(s) >= Self.minContrast
        }
        guard !ok else { return [] }
        theme.app.textChrome = []
        return ["app.text.chrome: every stop must be an opaque colour reading \(Int(Self.minContrast)):1 on its backgrounds, drawn flat instead"]
    }

    /// The least contrast a terminal colour needs against the background it is drawn on.
    static let minTerminalContrast: CGFloat = 1.5
    static let minNearBgContrast: CGFloat = 1.3

    /// Refuses the `[ghostty]` palette entries, selection colours and cursor text that would vanish into
    /// their background. Ghostty's own keywords (`cell-foreground`…) are left to Ghostty.
    private mutating func terminalColors(over bg: NSColor) -> [String] {
        var problems: [String] = []
        func color(_ s: String) -> NSColor? { NSColor(themeHex: s.hasPrefix("#") ? s : "#" + s)?.over(bg) }
        func faint(_ c: NSColor, on b: NSColor) -> Bool { c.contrast(b) < Self.minTerminalContrast }
        // Black on a dark background and bright white on a light one are meant to sit on it; bright black (white
        // on light) is real secondary text, so it keeps a lower floor. Ghostty's minimum-contrast still lifts them.
        let dark = bg.contrast(.white) > bg.contrast(.black)
        let (exempt, near) = dark ? ("0", "8") : ("15", "7")
        if let entries = ghostty["palette"]?.strings {
            var kept: [String] = []
            for e in entries {
                let parts = e.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, let c = color(parts[1].trimmingCharacters(in: .whitespaces)) else {
                    problems.append("[ghostty] palette \(e): not <n>=#rrggbb, ignored")
                    continue
                }
                let n = parts[0].trimmingCharacters(in: .whitespaces)
                let floor = n == exempt ? 0 : n == near ? Self.minNearBgContrast : Self.minTerminalContrast
                if c.contrast(bg) < floor {
                    problems.append("[ghostty] palette \(e): too close to the background to read, ignored")
                    continue
                }
                kept.append(e)
            }
            ghostty["palette"] = kept.isEmpty ? nil : .array(kept)
        }
        let selection = ghostty["selection-background"]?.strings.first.flatMap(color)
        let checks: [(String, NSColor)] = [("selection-background", bg), ("selection-foreground", selection ?? bg), ("cursor-text", bg)]
        for (key, against) in checks {
            guard let v = ghostty[key]?.strings.first, !v.hasPrefix("cell-") else { continue }
            if let c = color(v), !faint(c, on: against) { continue }
            ghostty[key] = nil
            problems.append("[ghostty] \(key) = \(v): unreadable or not #rrggbb, ignored")
        }
        // Bold text in its own colour is the terminal's text, so it needs the foreground's contrast.
        if let v = ghostty["bold-color"]?.strings.first, v != "bright", (color(v).map { $0.contrast(bg) < Self.minContrast } ?? true) {
            ghostty["bold-color"] = nil
            problems.append("[ghostty] bold-color = \(v): unreadable or not #rrggbb, ignored")
        }
        return problems
    }

    private static func faint(_ what: String, _ ratio: CGFloat) -> String {
        "\(what): contrast \(String(format: "%.1f", ratio)):1 is under \(Int(minContrast)):1, drawn in black or white instead"
    }

    /// A theme is data: it may only change how the terminal looks, never what it runs, types, reads or binds.
    static func themeMaySet(_ key: String) -> Bool {
        key.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil && themeKeys.contains(key)
    }

    /// Ghostty 1.4.0's appearance keys (src/config/Config.zig), and the compat names it still reads.
    private static let themeKeys: Set<String> = [
        "palette", "background", "foreground", "bold-color", "bold-is-bright", "minimum-contrast",
        "background-opacity", "background-blur", "background-blur-radius",
        "unfocused-split-opacity", "unfocused-split-fill",
        "window-padding-x", "window-padding-y", "window-padding-balance", "window-padding-color",
        "font-size", "font-feature", "font-thicken", "font-thicken-strength", "font-synthetic-style",
        "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic",
        "font-style", "font-style-bold", "font-style-italic", "font-style-bold-italic",
        "font-variation", "font-variation-bold", "font-variation-italic", "font-variation-bold-italic",
        "adjust-cell-width", "adjust-cell-height", "adjust-font-baseline", "adjust-underline-position",
        "adjust-underline-thickness", "adjust-strikethrough-position", "adjust-strikethrough-thickness",
        "adjust-overline-position", "adjust-overline-thickness", "adjust-cursor-thickness", "adjust-cursor-height",
        "adjust-box-thickness", "adjust-icon-height",
        "cursor-color", "cursor-text", "cursor-opacity", "cursor-style", "cursor-style-blink", "cursor-invert-fg-bg",
        "selection-foreground", "selection-background", "selection-invert-fg-bg",
    ]

    private func failed(_ name: String, _ why: String) -> LoadedTheme {
        LoadedTheme(files: files, problems: ["theme \"\(name)\": \(why); using the default"])
    }
}

extension NSColor {
    /// `#rrggbb` or `#rrggbbaa`, in sRGB.
    convenience init?(themeHex s: String) {
        guard s.hasPrefix("#"), s.count == 7 || s.count == 9, let v = UInt64(s.dropFirst(), radix: 16) else { return nil }
        let has = s.count == 9
        let r = has ? v >> 24 : v >> 16, g = has ? v >> 16 : v >> 8, b = has ? v >> 8 : v, a = has ? v : 0xFF
        self.init(srgbRed: CGFloat(r & 0xFF) / 255, green: CGFloat(g & 0xFF) / 255, blue: CGFloat(b & 0xFF) / 255, alpha: CGFloat(a & 0xFF) / 255)
    }

    /// This colour laid over an opaque `bg`, in sRGB.
    func over(_ bg: NSColor) -> NSColor {
        let f = usingColorSpace(.sRGB) ?? self, b = bg.usingColorSpace(.sRGB) ?? bg, a = f.alphaComponent
        return NSColor(srgbRed: f.redComponent * a + b.redComponent * (1 - a), green: f.greenComponent * a + b.greenComponent * (1 - a),
                       blue: f.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
    }

    /// Black or white, whichever contrasts more with this colour.
    var readable: NSColor { contrast(.black) >= contrast(.white) ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }

    /// WCAG contrast ratio against `other`, both taken as opaque.
    func contrast(_ other: NSColor) -> CGFloat {
        func lum(_ c: NSColor) -> CGFloat {
            let c = c.usingColorSpace(.sRGB) ?? c
            let lin = { (v: CGFloat) in v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        let (a, b) = (lum(self), lum(other))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var themeHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        let v = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
        return "#" + v.map { String(format: "%02x", $0) }.joined()
    }
}

/// Theme plugins' fonts, registered for this process only and only while their theme is on screen.
/// Theme plugins' fonts, only while their theme is on screen. A bundled plugin's are registered for this
/// process; a user-installed one's are never registered, so nothing but `uiFont` (font.ui) can draw with them,
/// not the terminal and not Core Text's fallback.
enum ThemeFonts {
    private(set) static var active: [URL] = []
    private static var privateURLs: [URL] = []
    private static var privateFaces: [CTFontDescriptor] = []

    /// A font name as compared: case-folded, quotes dropped, whitespace collapsed.
    static func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[\"']", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The names a font value lists: a family, or a CSS stack split on commas, normalised.
    static func names(in value: String) -> [String] {
        value.split(separator: ",").map { normalized(String($0)) }
    }

    /// A face's family, PostScript and display names, normalised.
    static func names(_ d: CTFontDescriptor) -> Set<String> {
        Set([kCTFontFamilyNameAttribute, kCTFontNameAttribute, kCTFontDisplayNameAttribute]
            .compactMap { CTFontDescriptorCopyAttribute(d, $0) as? String }.map(normalized))
    }

    /// The faces in a font file, read from its bytes without registering anything.
    static func descriptors(_ url: URL) -> [CTFontDescriptor] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] ?? []
    }

    /// Names read from font files, kept until a file changes: theme pickers ask for them on every preview.
    private static var fileNames: [URL: (FileStamp?, Set<String>)] = [:]
    private static var installedFileNames: [URL: (FileStamp?, Set<String>)] = [:]

    static func names(_ url: URL) -> Set<String> {
        let u = url.standardizedFileURL, stamp = FileStamp(u)
        if let (s, n) = fileNames[u], s == stamp { return n }
        let n = Set(descriptors(u).flatMap(names))
        fileNames[u] = (stamp, n)
        return n
    }

    /// Every name of every font on the Mac, leaving out the files `excluding` registered.
    static func installedNames(excluding: [URL]) -> Set<String> {
        let all = CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionCreateFromAvailableFonts(nil)) as? [CTFontDescriptor] ?? []
        let ours = Set(excluding.map(\.standardizedFileURL))
        var byFile: [URL: [CTFontDescriptor]] = [:], out = Set<String>()
        for d in all {
            guard let u = (CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL)?.standardizedFileURL else {
                out.formUnion(names(d))
                continue
            }
            if !ours.contains(u) { byFile[u, default: []].append(d) }
        }
        for (u, faces) in byFile {
            let stamp = FileStamp(u)
            if let (s, n) = installedFileNames[u], s == stamp {
                out.formUnion(n)
            } else {
                let n = Set(faces.flatMap(names))
                installedFileNames[u] = (stamp, n)
                out.formUnion(n)
            }
        }
        return out
    }

    /// Whether `family` is one of the private faces' families.
    static func isPrivate(_ family: String) -> Bool {
        let n = normalized(family)
        return privateFaces.contains { names($0).contains(n) }
    }

    /// `family` from the private faces, at the weight nearest `weight`; nil when none has it.
    static func uiFont(family: String, weight: NSFont.Weight, size: CGFloat) -> NSFont? {
        let n = normalized(family)
        func w(_ d: CTFontDescriptor) -> CGFloat {
            ((CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any])?[kCTFontWeightTrait] as? CGFloat) ?? 0
        }
        let best = privateFaces.filter { names($0).contains(n) }.min { abs(w($0) - weight.rawValue) < abs(w($1) - weight.rawValue) }
        return best.map { CTFontCreateWithFontDescriptor($0, size, nil) as NSFont }
    }

    static func activate(_ urls: [URL], _ uiOnly: [URL]) {
        if uiOnly != privateURLs {
            privateURLs = uiOnly
            privateFaces = uiOnly.flatMap(descriptors)
        }
        guard urls != active else { return }
        let (old, new) = (Set(active), Set(urls))
        for url in old.subtracting(new) { CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil) }
        for url in new.subtracting(old) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                HauntConfig.logger.warning("font \(url.lastPathComponent, privacy: .public) not registered: \(String(describing: error?.takeRetainedValue()), privacy: .public)")
            }
        }
        active = urls
    }
}
