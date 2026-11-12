import AppKit
import os

/// ~/.haunt/config.toml: `font`, `font_size`, `[keys]`, `[notifications]` and a raw `[ghostty]` table, turned into a Ghostty config file.
final class HauntConfig {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.haunt.Haunt", category: "config")

    let dir: URL
    var tomlURL: URL { dir.appendingPathComponent("config.toml") }
    var ghosttyURL: URL { dir.appendingPathComponent("ghostty.generated.conf") }
    private(set) var keys = KeyMap.defaults
    private(set) var notifications = NotificationSettings()
    /// The loaded plugins' commands that come with a key, as "<plugin id>/<item id>": default key; set before `reload`.
    var pluginKeyDefaults: [String: String] = [:]
    private(set) var agentsView = AgentsViewStyle.narrowList
    private(set) var titlebarButtons = TitlebarButton.defaults
    private(set) var paletteLayout = PaletteLayout()
    private(set) var titleFormat = ""
    /// Haunt's own middle-click paste; `[ghostty] middle-click-action = ignore` turns it off.
    private(set) var middleClickPaste = true

    /// The theme on screen: `theme` from config.toml, unless a preview or a fixture says otherwise.
    private(set) var themeName = "bw"
    /// While the theme picker previews one; nil goes back to config.toml's.
    var previewTheme: String?
    /// A fixture's theme, from HAUNT_THEME; fixtures otherwise stay black and white.
    var fixtureTheme: String?
    var themesDir: URL { dir.appendingPathComponent("themes") }
    /// Themes from installed theme plugins, by theme id; nil until the plugins load, when a plugin's theme
    /// can't be found yet and that isn't worth a warning.
    var pluginThemes: [String: PluginTheme]? {
        didSet { choices = nil }
    }
    /// `themeChoices()` until the themes folder or the plugin themes change.
    private var choices: [ThemeChoice]?
    static var bundledThemesDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("themes") }

    /// What a reload changed.
    struct Changes {
        var ghostty = false, keys = false, layout = false, theme = false, notifications = false, text = false
        var any: Bool { ghostty || keys || layout || theme || notifications || text }
    }

    private var source: DispatchSourceFileSystemObject?
    private var themesSource: DispatchSourceFileSystemObject?
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var onChange: ((Changes) -> Void)?
    /// config.toml as last read (empty for fixtures), whose `[plugins."<id>"]` tables the plugin host reads.
    private(set) var text = ""
    /// Seeded from disk, so a launch with an unchanged config doesn't rewrite the file.
    private var lastWritten: String?
    /// config.toml's and the theme files' identities at the last read; events that leave them unchanged
    /// (state.json, our own generated Ghostty file) skip the reload. A missing file is nil.
    private var lastSeen: [URL: FileStamp?] = [:]
    private var lastThemeProblems: [String] = []
    private var lastKeyProblems: [String] = []
    private var lastLayoutProblems: [String] = []
    private var lastNotificationProblems: [String] = []

    /// HAUNT_CONFIG_DIR, else HAUNT_HOME, else ~/.haunt: the same order as `haunt setup`.
    init(dir: URL? = nil) {
        let e = ProcessInfo.processInfo.environment
        let env = (e["HAUNT_CONFIG_DIR"] ?? e["HAUNT_HOME"]).map { URL(fileURLWithPath: $0) }
        self.dir = dir ?? env ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".haunt")
        lastWritten = try? String(contentsOf: ghosttyURL, encoding: .utf8)
    }

    /// Re-reads config.toml and its theme into `keys`, `[layout]`, `[notifications]`, `text` and `Theme.current`,
    /// and rewrites the Ghostty file; says which changed. `text` is whether config.toml changed at all: the
    /// plugin host works out whether its `[plugins]` did.
    @discardableResult
    func reload(useUserConfig: Bool = true) -> Changes {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = useUserConfig ? readConfig() : ""
        let textChanged = text != self.text
        self.text = text
        usingUserConfig = useUserConfig
        var r = apply()
        r.text = textChanged
        return r
    }

    static let maxConfigBytes = 1 << 20

    /// config.toml's text; empty when there is none, or when it is unreadable or over `maxConfigBytes`, which is logged.
    private func readConfig() -> String {
        guard FileManager.default.fileExists(atPath: tomlURL.path) else { return "" }
        if let text = LoadedTheme.read(tomlURL, max: Self.maxConfigBytes) { return text }
        Self.logger.error("config.toml is unreadable or larger than \(Self.maxConfigBytes >> 20, privacy: .public) MB, ignored")
        return ""
    }

    /// Rebuilds `keys`, the theme and the Ghostty file from `text` as last read, without reading config.toml
    /// again: for plugin commands that came or went.
    @discardableResult
    func rebuildKeys() -> Changes {
        apply()
    }

    private var usingUserConfig = true

    private func apply() -> Changes {
        var toml = TOML.parse(text) { Self.logger.warning("config.toml: \($0, privacy: .public)") }
        let name = previewTheme ?? fixtureTheme ?? (usingUserConfig ? toml[""]?["theme"]?.strings.first : nil)
        let loaded = LoadedTheme.load(name, userDir: dir, plugins: pluginThemes ?? [:], bundled: Self.bundledThemesDir, activate: ThemeFonts.activate)
        // Also drops the fonts when the theme is black and white or failed to load.
        ThemeFonts.activate(loaded.fonts, loaded.uiFonts)
        if pluginThemes != nil, loaded.problems != lastThemeProblems {
            for p in loaded.problems { Self.logger.warning("\(p, privacy: .public)") }
            lastThemeProblems = loaded.problems
        }
        let seen = Dictionary(([tomlURL] + loaded.files).map { ($0, FileStamp($0)) }, uniquingKeysWith: { a, _ in a })
        // A preview or a new `theme =` changes the files to watch, not only an event.
        if seen != lastSeen {
            lastSeen = seen
            if onChange != nil { watchFiles() }
        }
        // The user's own [layout] and [ghostty] keys win over the theme's.
        toml["layout"] = loaded.layout.merging(toml["layout"] ?? [:]) { _, user in user }
        // Ghostty raises any cell's text to this contrast; a theme can raise it but never turn it off.
        var ghostty = loaded.ghostty
        if toml["ghostty"]?["minimum-contrast"] == nil {
            let theirs = ghostty["minimum-contrast"]?.strings.first.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } ?? 0
            ghostty["minimum-contrast"] = .scalar(Self.num(CGFloat(min(max(theirs, Self.minimumContrast), 21))))
        }
        toml["ghostty"] = ghostty.merging(toml["ghostty"] ?? [:]) { _, user in user }
        let themeChanged = loaded.theme != Theme.current
        Theme.current = loaded.theme
        themeName = loaded.name
        var problems: [String] = []
        let newKeys = KeyMap(table: toml["keys"] ?? [:], order: TOML.keyOrder(text, table: "keys"), pluginDefaults: pluginKeyDefaults) {
            problems.append($0)
        }
        problems += Self.refusedGhostty(toml["ghostty"] ?? [:]).map { "[ghostty] \($0.key) = \($0.value): not allowed, ignored" }
        // One save can fire several events; each problem is logged once per edit.
        if problems != lastKeyProblems {
            for p in problems { Self.logger.error("\(p, privacy: .public)") }
            lastKeyProblems = problems
        }
        middleClickPaste = Self.middleClickPaste(toml["ghostty"] ?? [:])
        let keysChanged = newKeys != keys
        keys = newKeys
        var notifyProblems: [String] = []
        let newNotifications = NotificationSettings(table: toml["notifications"] ?? [:]) { notifyProblems.append($0) }
        if notifyProblems != lastNotificationProblems {
            for p in notifyProblems { Self.logger.error("\(p, privacy: .public)") }
            lastNotificationProblems = notifyProblems
        }
        let notificationsChanged = newNotifications != notifications
        notifications = newNotifications
        var layoutProblems: [String] = []
        agentsView = AgentsViewStyle.parse(toml["layout"]?["agents_view"]) { layoutProblems.append($0) }
        let buttons = TitlebarButton.parse(toml["layout"]?["titlebar_buttons"]) { layoutProblems.append($0) }
        let palette = PaletteLayout.parse(toml["layout"]) { layoutProblems.append($0) }
        let title = TitleFormat.parse(toml["layout"]?["title_format"]) { layoutProblems.append($0) }
        let layoutChanged = buttons != titlebarButtons || palette != paletteLayout || title != titleFormat
        titleFormat = title
        titlebarButtons = buttons
        paletteLayout = palette
        if layoutProblems != lastLayoutProblems {
            for p in layoutProblems { Self.logger.warning("\(p, privacy: .public)") }
            lastLayoutProblems = layoutProblems
        }
        let generated = Self.ghosttyConfig(toml, defaultSize: usingUserConfig ? Self.defaultFontSize : Tok.Size.paneFont, keys: keys)
        var changes = Changes(keys: keysChanged, layout: layoutChanged, theme: themeChanged, notifications: notificationsChanged)
        guard generated != lastWritten else { return changes }
        try? generated.write(to: ghosttyURL, atomically: true, encoding: .utf8)
        lastWritten = generated
        changes.ghostty = true
        return changes
    }

    static let minimumContrast = 1.1

    /// The user's Warp size; fixtures keep the mockup's `Tok.Size.paneFont` so fidelity still compares.
    static let defaultFontSize: CGFloat = 11

    static func ghosttyConfig(_ toml: [String: [String: TOML.Value]], defaultSize: CGFloat, keys: KeyMap) -> String {
        let top = toml[""] ?? [:]
        func line(_ k: String) -> String? { top[k]?.strings.first.flatMap { $0.contains(where: \.isNewline) ? nil : $0 } }
        let font = line("font") ?? Tok.Font.monoFamily
        let size = line("font_size") ?? Self.num(defaultSize)
        let cellAdjust = num((Tok.Size.paneLine / naturalLineHeight - 1) * 100)
        var lines: [String] = ["# Generated by haunt from ~/.haunt/config.toml. Edits here are overwritten."]
        lines.append("font-family = \(font)")
        lines += Tok.Font.monoFallback.map { "font-family = \($0)" }
        lines += [
            "font-size = \(size)",
            // Ghostty's cell is the font's natural line height; the mockup's pane uses 1.65.
            "adjust-cell-height = \(cellAdjust)%",
            "background = \(Tok.Color.windowBg.hex)",
            "foreground = \(Tok.Color.textTerminal.hex)",
            "window-padding-x = \(num(Tok.Size.panePad[1]))",
            "window-padding-y = \(num(Tok.Size.panePad[0]))",
            "window-padding-balance = false",
            "window-padding-color = background",
            "window-colorspace = srgb",
            "confirm-close-surface = true",
            "resize-overlay = never",
            // Haunt pastes on middle click itself, the text it checked (HauntSurfaceView).
            "middle-click-action = ignore",
        ]
        // haunt owns tabs and windows, and its shortcuts must reach the menu instead of Ghostty.
        var unbind: [String] = (["t", "w", "n", "d", "shift+d"] + (1...9).flatMap { ["digit_\($0)", "\($0)"] }).map { "super+" + $0 }
        // Ghostty's own paste bindings would write to the pty past Haunt's paste checks, whatever [keys] says.
        unbind += ["cmd+v", "cmd+shift+v"].flatMap { Shortcut.parse($0)!.ghosttyTriggers } + ["paste"]
        for a in KeyMap.Action.allCases { unbind += keys[a]?.ghosttyTriggers ?? [] }
        for (_, s) in keys.plugin.sorted(by: { $0.key < $1.key }) { unbind += s.ghosttyTriggers }
        var seen = Set<String>()
        lines += unbind.filter { seen.insert($0).inserted }.map { "keybind = \($0)=unbind" }
        let refused = Set(refusedGhostty(toml["ghostty"] ?? [:]).map { "\($0.key) = \($0.value)" })
        let raw = (toml["ghostty"] ?? [:]).sorted { $0.key < $1.key }
            .flatMap { k, v in v.strings.map { "\(k) = \($0)" } }.filter { !refused.contains($0) }
        return (lines + raw).joined(separator: "\n") + "\n"
    }

    /// Passthrough values Haunt can't allow: a paste libghostty starts itself (a click, a keybind) writes to
    /// the pty past Haunt's paste checks, another config file is never checked, and a line break would
    /// smuggle in a line of its own.
    static func refusedGhostty(_ table: [String: TOML.Value]) -> [(key: String, value: String)] {
        table.sorted { $0.key < $1.key }.flatMap { k, v in v.strings.filter { refused(k, $0) }.map { (k, $0) } }
    }

    /// False when the table sets `middle-click-action = ignore`; Haunt's paste values for it are refused.
    static func middleClickPaste(_ table: [String: TOML.Value]) -> Bool {
        !(table["middle-click-action"]?.strings ?? []).contains { !$0.contains(where: \.isNewline) && ghosttyValue($0) == "ignore" }
    }

    /// A value as Ghostty reads it (cli/args.zig): spaces and tabs trimmed and one pair of double quotes
    /// dropped; then trimmed again and lowercased, to compare loosely.
    private static func ghosttyValue(_ raw: String) -> String {
        let ws = CharacterSet(charactersIn: " \t")
        var value = raw.trimmingCharacters(in: ws)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return value.trimmingCharacters(in: ws).lowercased()
    }

    private static func refused(_ key: String, _ raw: String) -> Bool {
        if raw.contains(where: \.isNewline) { return true }
        // A key Ghostty reads must already be bare; it trims the key the same way.
        guard key.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { return true }
        let value = ghosttyValue(raw)
        switch key {
        case "right-click-action": return ["paste", "copy-or-paste"].contains(value)
        // Ghostty's is always ignore; the paste is Haunt's, and ignore turns it off (middleClickPaste).
        case "middle-click-action": return value != "ignore"
        case "keybind": return ["paste_from_clipboard", "paste_from_selection"].contains { value.lowercased().contains($0) }
        case "config-file", "config-default-files": return true
        default: return false
        }
    }

    /// Berkeley Mono Variable's (ascent + descent + lineGap) / unitsPerEm from hhea: (956 + 244 + 0) / 1000.
    static let naturalLineHeight: CGFloat = 1.2

    /// A finite number as config text; a non-finite one, which no caller should pass, is "0".
    static func num(_ v: CGFloat) -> String {
        guard v.isFinite else { return "0" }
        return v.rounded() == v && abs(v) < 1e15 ? String(Int(v)) : String(format: "%g", Double(v))
    }

    /// UI state kept across launches in `<dir>/state.json`, beside the config it belongs to.
    struct State: Codable {
        var sidebarHidden = false
        var agentsView = false
        /// Written by `haunt setup`; nil until it has run, which is when the first-launch picker shows.
        var agents: [String]?
        /// The right pane's width per plugin id, in points.
        var rightPaneWidths: [String: Double] = [:]

        enum CodingKeys: String, CodingKey {
            case sidebarHidden = "sidebar_hidden"
            case agentsView = "agents_view"
            case agents
            case rightPaneWidths = "right_pane_widths"
        }

        init() {}

        // Every key is optional: `haunt setup` may write the file before the app ever has.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sidebarHidden = try c.decodeIfPresent(Bool.self, forKey: .sidebarHidden) ?? false
            agentsView = try c.decodeIfPresent(Bool.self, forKey: .agentsView) ?? false
            agents = try c.decodeIfPresent([String].self, forKey: .agents)
            rightPaneWidths = try c.decodeIfPresent([String: Double].self, forKey: .rightPaneWidths) ?? [:]
        }
    }

    var stateURL: URL { dir.appendingPathComponent("state.json") }

    func loadState() -> State {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    func saveState(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    /// state.json as read at launch, with the app's own changes since.
    private(set) lazy var state = loadState()
    private var stateDirty = false

    /// Changes the app's keys in memory; they are written a second later or at quit, whichever comes first.
    func updateState(_ change: (inout State) -> Void) {
        change(&state)
        guard !stateDirty else { return }
        stateDirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flushState() }
    }

    /// Merges into the file rather than overwriting it, so `agents` from a `haunt setup` run meanwhile survives.
    func flushState() {
        guard stateDirty else { return }
        stateDirty = false
        var file = loadState()
        file.sidebarHidden = state.sidebarHidden
        file.agentsView = state.agentsView
        file.rightPaneWidths = state.rightPaneWidths
        state.agents = file.agents
        saveState(file)
    }

    /// Calls `onChange` on the main queue after config.toml or its theme changes. The directories catch atomic
    /// saves, which replace a file, and new theme files; the files themselves catch editors that write in place.
    func watch(_ onChange: @escaping (Changes) -> Void) {
        self.onChange = onChange
        source = Self.observe(dir.path, [.write, .rename, .delete]) { [weak self] in self?.changed() }
        try? FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        themesSource = Self.observe(themesDir.path, [.write, .rename, .delete]) { [weak self] in
            self?.choices = nil
            self?.changed()
        }
        watchFiles()
    }

    private func changed() {
        guard lastSeen.contains(where: { FileStamp($0.key) != $0.value }) else { return }
        let r = reload()
        if r.any { onChange?(r) }
    }

    /// Re-armed whenever `lastSeen` changes: an atomic save leaves the old watch on a deleted file.
    private func watchFiles() {
        fileSources.forEach { $0.cancel() }
        fileSources = lastSeen.keys.filter { lastSeen[$0] != .some(nil) }.compactMap {
            Self.observe($0.path, [.write, .extend, .rename, .delete]) { [weak self] in self?.changed() }
        }
    }

    /// A theme the pickers offer: `id` as config.toml names it, `name` from the file's own `name`.
    struct ThemeChoice: Equatable {
        var id: String
        var name: String
    }

    /// Black and white first, then every theme Haunt can find by id, in lookup order: the user's own, then
    /// theme plugins', then bundled ones, each hiding a later one with the same id.
    func themeChoices() -> [ThemeChoice] {
        if let choices { return choices }
        var seen: Set<String> = ["bw"]
        var out = [ThemeChoice(id: "bw", name: "Black and white")]
        let listed = { (folder: URL?) -> [(String, URL)] in
            let files = folder.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
            return files.filter { $0.pathExtension == "toml" }.map { ($0.deletingPathExtension().lastPathComponent, $0) }.sorted { $0.0 < $1.0 }
        }
        let sources = [listed(themesDir), (pluginThemes ?? [:]).map { ($0.key, $0.value.file) }.sorted { $0.0 < $1.0 }, listed(Self.bundledThemesDir)]
        for source in sources {
            for (id, url) in source {
                guard id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil, seen.insert(id).inserted else { continue }
                let text = LoadedTheme.readTheme(url) ?? ""
                let name = TOML.parse(text)[""]?["name"]?.strings.first.flatMap { $0.contains(where: \.isNewline) ? nil : $0 }
                out.append(ThemeChoice(id: id, name: name ?? id))
            }
        }
        choices = out
        return out
    }

    /// `id`'s tokens, for drawing a preview without switching to it.
    func theme(_ id: String) -> Theme {
        LoadedTheme.load(id, userDir: dir, plugins: pluginThemes ?? [:], bundled: Self.bundledThemesDir).theme
    }

    /// Reloads with a previewed theme, or with config.toml's again for nil; says what changed.
    func preview(_ name: String?) -> Changes {
        previewTheme = name
        return apply()
    }

    /// Saves `name` as the theme, ends any preview and reloads config.toml with it.
    func choose(_ name: String) -> Changes {
        saveTheme(name)
        previewTheme = nil
        return reload(useUserConfig: usingUserConfig)
    }

    /// Writes `theme = "<name>"` into config.toml, replacing a top-level `theme` line or adding one above the
    /// first table, and leaves everything else as it is.
    func saveTheme(_ name: String) {
        // An atomic write replaces a symlink with a file; write through to what it points at instead.
        let url = tomlURL.resolvingSymlinksInPath()
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            guard let t = LoadedTheme.read(url, max: Self.maxConfigBytes) else {
                return Self.logger.error("theme not saved: config.toml is unreadable or larger than \(Self.maxConfigBytes >> 20, privacy: .public) MB")
            }
            text = t
        }
        do {
            try Self.settingTheme(name, in: text).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("theme not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func settingTheme(_ name: String, in text: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let entry = "theme = \"\(name)\""
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        if let i = lines[..<firstTable].firstIndex(where: { $0.range(of: #"^\s*"?theme"?\s*="#, options: .regularExpression) != nil }) {
            lines[i] = entry
        } else {
            lines.insert(entry, at: 0)
        }
        let out = lines.joined(separator: "\n")
        return out.hasSuffix("\n") ? out : out + "\n"
    }

    private static func observe(_ path: String, _ mask: DispatchSource.FileSystemEvent,
                                _ handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        src.setEventHandler(handler: handler)
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }
}

/// `[notifications]`: every switch defaults to on; a value that isn't `true` or `false` is logged and ignored.
struct NotificationSettings: Equatable {
    var enabled = true
    var onPermission = true
    var onDone = true
    var menuBar = true

    static let keys: [String: WritableKeyPath<NotificationSettings, Bool>] = [
        "enabled": \.enabled, "on_permission": \.onPermission, "on_done": \.onDone, "menu_bar": \.menuBar,
    ]

    init() {}

    init(table: [String: TOML.Value], problem: (String) -> Void) {
        for (k, v) in table.sorted(by: { $0.key < $1.key }) {
            guard let path = Self.keys[k] else {
                problem("[notifications] \(k): unknown setting")
                continue
            }
            guard case let .scalar(s) = v, s == "true" || s == "false" else {
                problem("[notifications] \(k): expected true or false")
                continue
            }
            self[keyPath: path] = s == "true"
        }
    }
}

/// A file's inode, modification time and size; nil when it doesn't exist.
struct FileStamp: Equatable {
    let inode: UInt64, mtimeSec: Int, mtimeNsec: Int, size: Int64

    init?(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        inode = UInt64(st.st_ino)
        mtimeSec = st.st_mtimespec.tv_sec
        mtimeNsec = st.st_mtimespec.tv_nsec
        size = Int64(st.st_size)
    }
}

/// `[layout] agents_view`: the view ⌘⇧A toggles. Views 02–09 arrive later as plugins.
enum AgentsViewStyle: String {
    case narrowList = "narrow-list"

    /// Unknown values fall back to the narrow list through `log`.
    static func parse(_ value: TOML.Value?, log: (String) -> Void) -> AgentsViewStyle {
        guard let value else { return .narrowList }
        if case let .scalar(s) = value, let style = AgentsViewStyle(rawValue: s) { return style }
        log("[layout] agents_view = \(value.strings.joined(separator: ",")): unknown view, using \"narrow-list\"")
        return .narrowList
    }
}

/// `[layout] palette_position`, `palette_width` and `palette_rows`: where ⌘K opens, how wide it is, and whether
/// a row's sub line sits under its title or beside it.
struct PaletteLayout: Equatable {
    enum Position: String { case centerTop = "center-top", bottomRight = "bottom-right" }
    var position = Position.centerTop
    /// nil: `Tok.Size.paletteW`.
    var width: CGFloat?
    var singleLine = false

    static let widths: ClosedRange<CGFloat> = 240...600

    /// A bad value keeps that key's default, through `log`.
    static func parse(_ layout: [String: TOML.Value]?, log: (String) -> Void) -> PaletteLayout {
        var out = PaletteLayout()
        func scalar(_ key: String) -> (TOML.Value, String?)? {
            guard let v = layout?[key] else { return nil }
            if case let .scalar(s) = v { return (v, s) }
            return (v, nil)
        }
        func refuse(_ key: String, _ v: TOML.Value, _ why: String) {
            log("[layout] \(key) = \(v.strings.joined(separator: ",")): \(why), using the default")
        }
        if let (v, s) = scalar("palette_position") {
            if let p = s.flatMap(Position.init) { out.position = p } else { refuse("palette_position", v, "not center-top or bottom-right") }
        }
        if let (v, s) = scalar("palette_width") {
            if let n = s.flatMap(Double.init).map({ CGFloat($0) }), widths.contains(n) {
                out.width = n
            } else {
                refuse("palette_width", v, "not a number from \(Int(widths.lowerBound)) to \(Int(widths.upperBound))")
            }
        }
        if let (v, s) = scalar("palette_rows") {
            switch s {
            case "two-line"?: out.singleLine = false
            case "single-line"?: out.singleLine = true
            default: refuse("palette_rows", v, "not two-line or single-line")
            }
        }
        return out
    }
}

/// `[layout] title_format`: the title bar's centred title, from the selected tab's `{tab}` name and `{meta}`, the
/// first part of its meta line. Empty, the default, shows none.
enum TitleFormat {
    static let maxLength = 80

    /// A bad value shows no title, through `log`.
    static func parse(_ value: TOML.Value?, log: (String) -> Void) -> String {
        guard let value else { return "" }
        guard case let .scalar(s) = value, s.count <= maxLength, s.unicodeScalars.allSatisfy({ !hidden($0) }) else {
            log("[layout] title_format: not one plain line of up to \(maxLength) characters, showing no title")
            return ""
        }
        return s
    }

    /// The title's parts: the tab's name in the title colour, the rest in the meta colour. An empty meta takes the
    /// text just before `{meta}` with it, so "{tab} — {meta}" is just the name.
    static func parts(_ format: String, tab: String, meta: String) -> [(text: String, isTab: Bool)] {
        let meta = meta.components(separatedBy: " · ").first ?? ""
        var out: [(String, Bool)] = []
        var rest = Substring(format)
        while !rest.isEmpty {
            if rest.hasPrefix("{tab}") {
                out.append((tab, true))
                rest = rest.dropFirst(5)
            } else if rest.hasPrefix("{meta}") {
                if meta.isEmpty, let last = out.last, !last.1 { out.removeLast() }
                if !meta.isEmpty { out.append((meta, false)) }
                rest = rest.dropFirst(6)
            } else {
                let next = rest.dropFirst().firstIndex(of: "{") ?? rest.endIndex
                out.append((String(rest[..<next]), false))
                rest = rest[next...]
            }
        }
        return out.map { (String(String.UnicodeScalarView($0.0.unicodeScalars.filter { !hidden($0) })), $0.1) }.filter { !$0.0.isEmpty }
    }

    /// The core's `plain_line` test, character for character: a control, format (bidi, zero-width, BOM),
    /// default-ignorable (fillers, variation selectors) or line-separator character, which could hide or
    /// reorder what the title shows. Both are tested against core/hidden-chars.json.
    static func hidden(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0...0x1F, 0x7F...0x9F, 0x2028, 0x2029,
             // Format (Cf).
             0xAD, 0x600...0x605, 0x61C, 0x6DD, 0x70F, 0x890...0x891, 0x8E2, 0x180E, 0x200B...0x200F,
             0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF, 0xFFF9...0xFFFB, 0x110BD, 0x110CD,
             0x13430...0x1343F, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0001, 0xE0020...0xE007F,
             // Default_Ignorable_Code_Point not already above.
             0x34F, 0x115F...0x1160, 0x17B4...0x17B5, 0x180B...0x180D, 0x180F, 0x2065, 0x3164,
             0xFE00...0xFE0F, 0xFFA0, 0xFFF0...0xFFF8, 0xE0000, 0xE0002...0xE001F, 0xE0080...0xE0FFF:
            return true
        default:
            return false
        }
    }
}

/// `[layout] titlebar_buttons`: the title bar's icons, drawn left to right in this order.
enum TitlebarButton: String, CaseIterable {
    case search
    case newTab = "new_tab"
    case settings
    case sidebar

    static let defaults: [TitlebarButton] = [.search, .newTab, .sidebar]

    /// The `[keys]` action the button runs, for its tooltip.
    var action: KeyMap.Action {
        switch self {
        case .search: return .palette
        case .newTab: return .newTab
        case .settings: return .settings
        case .sidebar: return .toggleSidebar
        }
    }

    /// Unknown and repeated names are skipped through `log`; an empty list leaves the bar bare.
    static func parse(_ value: TOML.Value?, log: (String) -> Void) -> [TitlebarButton] {
        guard let value else { return defaults }
        var out: [TitlebarButton] = []
        for name in value.strings {
            guard let b = TitlebarButton(rawValue: name) else {
                log("[layout] titlebar_buttons: unknown button \"\(name)\", ignored (search, new_tab, settings, sidebar)")
                continue
            }
            if out.contains(b) { log("[layout] titlebar_buttons: \"\(name)\" listed twice, ignored"); continue }
            out.append(b)
        }
        return out
    }
}

/// The TOML subset haunt's config needs: tables, strings, numbers, booleans, and arrays of those.
enum TOML {
    enum Value: Equatable {
        case scalar(String)
        case array([String])

        var strings: [String] {
            switch self {
            case let .scalar(s): return [s]
            case let .array(a): return a
            }
        }
    }

    /// `problems` gets what is dropped: an array over the caps, or one never closed.
    static func parse(_ text: String, problems: (String) -> Void = { _ in }) -> [String: [String: Value]] {
        var out: [String: [String: Value]] = [:]
        entries(text, problems: problems) { table, key, value in out[table, default: [:]][key] = parseValue(value) }
        return out
    }

    /// The keys of `table` in the order they are written.
    static func keyOrder(_ text: String, table name: String) -> [String] {
        var keys: [String] = []
        entries(text, problems: { _ in }) { table, key, _ in if table == name { keys.append(key) } }
        return keys
    }

    /// A value running over several lines stops gathering here, so a hostile file can't hold the parse.
    static let maxPendingBytes = 64 << 10
    static let maxPendingLines = 512

    private static func entries(_ text: String, problems: (String) -> Void, _ body: (String, String, String) -> Void) {
        var table = ""
        // An array running over several lines: its lines so far, their size and its open brackets.
        var pending: [Substring] = [], pendingBytes = 0, depth = 0, skipping = false
        func key(_ line: Substring) -> String {
            line.firstIndex(of: "=").map { unquote(line[..<$0].trimmingCharacters(in: .whitespaces)) } ?? ""
        }
        // By Character, "\r\n" is one newline, which splitting on "\n" alone would never find.
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let (content, open) = scan(raw)
            var line = content.trimmingCharacters(in: .whitespaces)[...]
            if !pending.isEmpty || skipping {
                // An array never closed ends at the next table, which it must not swallow.
                if isTableHeader(line) {
                    if !skipping { problems("\(table.isEmpty ? "" : table + ".")\(key(pending[0])): array not closed, ignored") }
                    pending = []
                    skipping = false
                } else {
                    depth += open
                    if skipping {
                        if depth <= 0 { skipping = false }
                        continue
                    }
                    pending.append(line)
                    pendingBytes += line.utf8.count + 1
                    if depth > 0 {
                        if pendingBytes > maxPendingBytes || pending.count > maxPendingLines {
                            problems("\(table.isEmpty ? "" : table + ".")\(key(pending[0])): array over \(maxPendingBytes >> 10) KB or \(maxPendingLines) lines, ignored")
                            pending = []
                            skipping = true
                        }
                        continue
                    }
                    line = pending.joined(separator: " ")[...]
                    pending = []
                }
            } else if line.contains("="), !line.hasPrefix("["), open > 0 {
                pending = [line]
                pendingBytes = line.utf8.count
                depth = open
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                table = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            body(table, key(line), line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
        if let first = pending.first { problems("\(table.isEmpty ? "" : table + ".")\(key(first)): array not closed, ignored") }
    }

    /// `[name]` alone on its line.
    private static func isTableHeader(_ line: Substring) -> Bool {
        let b = line.utf8
        guard b.first == UInt8(ascii: "["), b.last == UInt8(ascii: "]") else { return false }
        let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).utf8
        guard let first = name.first, first == UInt8(ascii: "_") || (first | 0x20) >= UInt8(ascii: "a") && (first | 0x20) <= UInt8(ascii: "z") else { return false }
        return name.allSatisfy { c in
            let l = c | 0x20
            return l >= UInt8(ascii: "a") && l <= UInt8(ascii: "z") || c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") || c == UInt8(ascii: "_") || c == UInt8(ascii: ".") || c == UInt8(ascii: "-")
        }
    }

    /// One pass over a line's bytes: its content before any comment, and its `[` less `]`, outside strings.
    /// A basic string's `\"` doesn't end it; a literal ('…') string has no escapes.
    private static func scan(_ line: Substring) -> (Substring, Int) {
        var depth = 0, quote: UInt8 = 0, escaped = false
        let bytes = line.utf8
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let c = bytes[i]
            if quote != 0 {
                if escaped { escaped = false } else if quote == UInt8(ascii: "\"") && c == UInt8(ascii: "\\") { escaped = true } else if c == quote { quote = 0 }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == UInt8(ascii: "#") {
                return (line[..<i], depth)
            } else if c == UInt8(ascii: "[") {
                depth += 1
            } else if c == UInt8(ascii: "]") {
                depth -= 1
            }
            i = bytes.index(after: i)
        }
        return (line, depth)
    }

    private static func parseValue(_ v: String) -> Value {
        guard v.hasPrefix("["), v.hasSuffix("]") else { return .scalar(unquote(v)) }
        let inner = v.dropFirst().dropLast()
        return .array(splitTopLevel(String(inner)).map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
    }

    private static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = [], cur = "", quote: Character?, escaped = false
        for c in s {
            if let q = quote {
                if escaped { escaped = false } else if q == "\"" && c == "\\" { escaped = true } else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "," {
                parts.append(cur)
                cur = ""
                continue
            }
            cur.append(c)
        }
        parts.append(cur)
        return parts
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") { return String(s.dropFirst().dropLast()) }
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

extension NSColor {
    var hex: String {
        let c = usingColorSpace(.sRGB)!
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
