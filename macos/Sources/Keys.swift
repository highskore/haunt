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
            "delete": ("\u{7f}", "delete", "⌦"),
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
        return Shortcut(mods: mods, key: punct[key]?.1 ?? key)
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
        case previousTab = "previous_tab"
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

    subscript(_ a: Action) -> Shortcut? { bindings[a] }

    static let defaults = KeyMap(table: [:], log: { _ in })

    /// Invalid, unknown or clashing entries are dropped through `log`, never thrown.
    init(table: [String: TOML.Value], log: (String) -> Void) {
        var configured: [Action: Shortcut] = [:]
        for (name, value) in table.sorted(by: { $0.key < $1.key }) {
            guard let action = Action(rawValue: name) else {
                log("[keys] \(name): unknown action, ignored")
                continue
            }
            guard case let .scalar(text) = value, let s = Shortcut.parse(text) else {
                log("[keys] \(name) = \(value.strings.joined(separator: ",")): not a shortcut like \"cmd+shift+b\", using \(action.defaultKey ?? "none")")
                continue
            }
            if let other = configured.first(where: { $0.value == s })?.key {
                log("[keys] \(name): \(text) is already \(other.rawValue), using \(action.defaultKey ?? "none")")
                continue
            }
            configured[action] = s
        }
        bindings = configured
        // A configured chord takes precedence over another action's default, which then has none.
        for a in Action.allCases where configured[a] == nil {
            guard let d = a.defaultKey else { continue }
            let s = Shortcut.parse(d)!
            if let owner = configured.first(where: { $0.value == s })?.key {
                log("[keys] \(owner.rawValue) took \(d); \(a.rawValue) has no shortcut")
                continue
            }
            bindings[a] = s
        }
    }
}
