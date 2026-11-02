import AppKit

/// One shortcut parsed from the `[keys]` table's "cmd+shift+b" format.
struct Shortcut: Equatable, Hashable {
    var mods: NSEvent.ModifierFlags
    /// Lowercase key name: a letter, digit, punctuation name ("comma") or named key ("enter").
    var key: String

    func hash(into h: inout Hasher) {
        h.combine(mods.rawValue)
        h.combine(key)
    }

    private static let modNames: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command, "super": .command,
        "shift": .shift,
        "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
    ]

    /// Punctuation by name and by character: (menu key equivalent, Ghostty key name).
    private static let punct: [String: (String, String)] = [
        "comma": (",", "comma"), ",": (",", "comma"),
        "period": (".", "period"), ".": (".", "period"),
        "slash": ("/", "slash"), "/": ("/", "slash"),
        "semicolon": (";", "semicolon"), ";": (";", "semicolon"),
        "quote": ("'", "quote"), "'": ("'", "quote"),
        "bracket_left": ("[", "bracket_left"), "[": ("[", "bracket_left"),
        "bracket_right": ("]", "bracket_right"), "]": ("]", "bracket_right"),
        "minus": ("-", "minus"), "-": ("-", "minus"),
        "equal": ("=", "equal"), "=": ("=", "equal"),
        "backquote": ("`", "backquote"), "`": ("`", "backquote"),
        "backslash": ("\\", "backslash"), "\\": ("\\", "backslash"),
    ]

    private static func fn(_ c: Int) -> String { String(UnicodeScalar(UInt16(c)).map(Character.init) ?? " ") }

    /// Named keys: (menu key equivalent, Ghostty key name, display glyph).
    private static let named: [String: (String, String, String)] = {
        var m: [String: (String, String, String)] = [
            "enter": ("\r", "enter", "↩"), "return": ("\r", "enter", "↩"),
            "tab": ("\t", "tab", "⇥"),
            "space": (" ", "space", "Space"),
            "escape": ("\u{1b}", "escape", "⎋"), "esc": ("\u{1b}", "escape", "⎋"),
            "backspace": ("\u{8}", "backspace", "⌫"),
            "delete": (fn(NSDeleteFunctionKey), "delete", "⌦"),
            "up": (fn(NSUpArrowFunctionKey), "arrow_up", "↑"),
            "down": (fn(NSDownArrowFunctionKey), "arrow_down", "↓"),
            "left": (fn(NSLeftArrowFunctionKey), "arrow_left", "←"),
            "right": (fn(NSRightArrowFunctionKey), "arrow_right", "→"),
            "home": (fn(NSHomeFunctionKey), "home", "↖"),
            "end": (fn(NSEndFunctionKey), "end", "↘"),
            "page_up": (fn(NSPageUpFunctionKey), "page_up", "⇞"),
            "page_down": (fn(NSPageDownFunctionKey), "page_down", "⇟"),
        ]
        for n in 1...12 { m["f\(n)"] = (fn(NSF1FunctionKey + n - 1), "f\(n)", "F\(n)") }
        return m
    }()

    /// Other spellings of a named key, stored as one so equal chords compare and hash equal.
    private static let namedAlias = ["return": "enter", "esc": "escape"]

    /// nil for anything malformed: no key, an unknown key or modifier, or a repeated part.
    static func parse(_ text: String) -> Shortcut? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let key = parts.last, !key.isEmpty, parts.count <= 5 else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for p in parts.dropLast() {
            guard let m = modNames[p], !mods.contains(m) else { return nil }
            mods.insert(m)
        }
        let isChar = key.count == 1 && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        guard isChar || punct[key] != nil || named[key] != nil else { return nil }
        // A bare letter or digit would be stolen from the terminal on every keystroke.
        let isFKey = key.hasPrefix("f") && named[key] != nil
        if mods.isDisjoint(with: [.command, .control, .option]) && !isFKey { return nil }
        return Shortcut(mods: mods, key: punct[key]?.1 ?? namedAlias[key] ?? key)
    }

    /// What shift turns punctuation and digits into on a US layout. AppKit matches a menu key equivalent
    /// against the shifted character, so ⇧⌘] must be "}".
    private static let shifted: [String: String] = [
        "[": "{", "]": "}", ",": "<", ".": ">", "/": "?", ";": ":", "'": "\"", "-": "_", "=": "+", "`": "~",
        "\\": "|", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
    ]

    /// The `NSMenuItem.keyEquivalent` string.
    var keyEquivalent: String {
        let base = Self.punct[key]?.0 ?? key
        if mods.contains(.shift), let s = Self.shifted[base] { return s }
        if let p = Self.punct[key] { return p.0 }
        if let n = Self.named[key] { return n.0 }
        return key
    }

    /// Ghostty triggers that would catch this chord before the menu, for `keybind = …=unbind`.
    var ghosttyTriggers: [String] {
        var m: [String] = []
        if mods.contains(.control) { m.append("ctrl") }
        if mods.contains(.option) { m.append("alt") }
        if mods.contains(.shift) { m.append("shift") }
        if mods.contains(.command) { m.append("super") }
        let prefix = m.map { $0 + "+" }.joined()
        if let n = Self.named[key] { return [prefix + n.1] }
        if Self.punct[key] != nil { return [prefix + key] }
        if let d = Int(key) { return [prefix + "digit_\(d)", prefix + key] }
        return [prefix + key]
    }

    /// "⌘⇧B", in the menu's modifier order.
    var display: String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        if let p = Self.punct[key] { return s + p.0 }
        if let n = Self.named[key] { return s + n.2 }
        return s + key.uppercased()
    }
}

/// Every Haunt shortcut, from defaults overlaid with the `[keys]` table.
struct KeyMap: Equatable {
    enum Action: String, CaseIterable {
        case newTab = "new_tab"
        case closeTab = "close_tab"
        case selectTab1 = "select_tab_1", selectTab2 = "select_tab_2", selectTab3 = "select_tab_3"
        case selectTab4 = "select_tab_4", selectTab5 = "select_tab_5", selectTab6 = "select_tab_6"
        case selectTab7 = "select_tab_7", selectTab8 = "select_tab_8", selectTab9 = "select_tab_9"
        case nextTab = "next_tab"
        case previousTab = "prev_tab"
        case renameTab = "rename_tab"
        case palette
        case toggleSidebar = "toggle_sidebar"
        case agentsView = "agents_view"
        case settings
        case fullScreen = "full_screen"
        case hide
        case hideOthers = "hide_others"
        case quit
        case minimize
        case copy, paste
        case selectAll = "select_all"

        /// Warp's defaults where Warp has the action (⌘⇧B is its vertical tabs panel); macOS standards otherwise.
        /// nil: no shortcut unless the table gives one.
        var defaultKey: String? {
            switch self {
            case .newTab: return "cmd+t"
            case .nextTab: return "cmd+shift+]"
            case .previousTab: return "cmd+shift+["
            case .renameTab: return nil
            case .closeTab: return "cmd+w"
            case .palette: return "cmd+k"
            case .toggleSidebar: return "cmd+shift+b"
            case .agentsView: return "cmd+shift+a"
            case .settings: return "cmd+comma"
            case .fullScreen: return "cmd+ctrl+f"
            case .hide: return "cmd+h"
            case .hideOthers: return "cmd+opt+h"
            case .quit: return "cmd+q"
            case .minimize: return "cmd+m"
            case .copy: return "cmd+c"
            case .paste: return "cmd+v"
            case .selectAll: return "cmd+a"
            default: return "cmd+\(tabIndex! + 1)"
            }
        }

        /// 0-based tab for select_tab_N.
        var tabIndex: Int? {
            rawValue.hasPrefix("select_tab_") ? Int(rawValue.dropFirst(11)).map { $0 - 1 } : nil
        }
    }

    private(set) var bindings: [Action: Shortcut] = [:]
    /// Plugin palette commands by "<plugin id>/<item id>", from their default keys and the table.
    private(set) var plugin: [String: Shortcut] = [:]

    subscript(_ a: Action) -> Shortcut? { bindings[a] }

    var all: [Shortcut] { Array(bindings.values) + Array(plugin.values) }

    static let defaults = KeyMap(table: [:], log: { _ in })

    /// "<plugin id>/<item id>", as `[keys]` names a plugin command.
    static func pluginName(_ pluginId: String, _ itemId: String) -> String { "\(pluginId)/\(itemId)" }

    /// Chords a plugin default may never take, even when unbound: Haunt's defaults, the terminal's line
    /// editing and macOS's own. A chord without cmd is refused before this, being terminal input.
    static let reserved: Set<Shortcut> = Set(
        (Action.allCases.compactMap(\.defaultKey) + [
            "cmd+x", "cmd+z", "cmd+shift+z", "cmd+n", "cmd+f", "cmd+g", "cmd+shift+g", "cmd+equal", "cmd+shift+equal",
            "cmd+minus", "cmd+0", "cmd+space", "cmd+tab", "cmd+shift+tab", "cmd+backquote", "cmd+ctrl+q",
            "cmd+ctrl+space", "cmd+shift+3", "cmd+shift+4", "cmd+shift+5", "cmd+opt+escape", "cmd+opt+d",
            "cmd+left", "cmd+right", "cmd+up", "cmd+down", "cmd+backspace", "cmd+delete", "cmd+enter",
        ]).map { Shortcut.parse($0)! }
    )

    /// Invalid, unknown or clashing entries are dropped through `log`, never thrown. `order` is the
    /// table's keys as written, so of two entries with one chord the earlier wins. `pluginDefaults` are the
    /// loaded plugins' commands with a default key; a plugin's default never takes a Haunt chord.
    init(table: [String: TOML.Value], order: [String] = [], pluginDefaults: [String: String] = [:], log: (String) -> Void) {
        var configured: [Action: Shortcut] = [:]
        var configuredPlugin: [String: Shortcut] = [:]
        func owner(_ s: Shortcut) -> String? {
            configured.first(where: { $0.value == s })?.key.rawValue ?? configuredPlugin.first(where: { $0.value == s })?.key
        }
        let names = order.filter { table[$0] != nil } + table.keys.filter { !order.contains($0) }.sorted()
        for name in names {
            let value = table[name]!
            let action = Action(rawValue: name)
            guard action != nil || name.contains("/") else {
                log("[keys] \(name): unknown action, ignored")
                continue
            }
            let fallback = action.map { $0.defaultKey ?? "none" } ?? pluginDefaults[name] ?? "none"
            guard case let .scalar(text) = value, let s = Shortcut.parse(text) else {
                log("[keys] \(name) = \(value.strings.joined(separator: ",")): not a shortcut like \"cmd+shift+b\", using \(fallback)")
                continue
            }
            if let other = owner(s) {
                log("[keys] \(name): \(text) is already \(other), using \(fallback)")
                continue
            }
            if let action { configured[action] = s } else { configuredPlugin[name] = s }
        }
        bindings = configured
        plugin = configuredPlugin
        // A configured chord takes precedence over another action's default, which then has none.
        for a in Action.allCases where configured[a] == nil {
            guard let d = a.defaultKey else { continue }
            let s = Shortcut.parse(d)!
            if let owner = owner(s) {
                log("[keys] \(owner) took \(d); \(a.rawValue) has no shortcut")
                continue
            }
            bindings[a] = s
        }
        for (name, d) in pluginDefaults.sorted(by: { $0.key < $1.key }) where configuredPlugin[name] == nil {
            guard let s = Shortcut.parse(d) else { continue }
            guard s.mods.contains(.command), !Self.reserved.contains(s) else {
                log("[keys] \(name): its default \(d) needs cmd and must not be a chord the terminal or macOS uses, so it has no shortcut")
                continue
            }
            if let other = bindings.first(where: { $0.value == s })?.key.rawValue ?? plugin.first(where: { $0.value == s })?.key {
                log("[keys] \(name): its default \(d) is already \(other), so it has no shortcut")
                continue
            }
            plugin[name] = s
        }
    }
}
