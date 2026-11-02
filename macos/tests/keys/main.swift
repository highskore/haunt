import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

// Parsing.
let b = Shortcut.parse("cmd+shift+b")
check(b == Shortcut(mods: [.command, .shift], key: "b"), "cmd+shift+b parses")
check(b?.display == "⇧⌘B", "display \(b?.display ?? "nil")")
check(b?.keyEquivalent == "b", "key equivalent")
check(b?.ghosttyTriggers == ["shift+super+b"], "ghostty \(b?.ghosttyTriggers ?? [])")
check(Shortcut.parse(" Cmd + K ") == Shortcut(mods: .command, key: "k"), "case and spaces")
check(Shortcut.parse("cmd+comma")?.display == "⌘,", "comma display")
check(Shortcut.parse("cmd+,")?.ghosttyTriggers == ["super+comma"], "comma by character")
check(Shortcut.parse("cmd+1")?.ghosttyTriggers == ["super+digit_1", "super+1"], "digit triggers")
check(Shortcut.parse("ctrl+opt+enter")?.ghosttyTriggers == ["ctrl+alt+enter"], "named key")
check(Shortcut.parse("f5") != nil, "a bare function key")
for bad in ["", "b", "shift+b", "cmd+", "+b", "cmd+cmd+b", "hyper+b", "cmd+ü", "cmd+shift", "escape", "cmd+b+c"] {
    check(Shortcut.parse(bad) == nil, "\(bad.debugDescription) must not parse")
}

// The [keys] table.
var logs: [String] = []
let toml = TOML.parse("""
[keys]
toggle_sidebar = "cmd+k"
palette = "cmd+p"
new_tab = "nonsense"
close_tab = 5
launch_rockets = "cmd+r"
select_tab_1 = "cmd+p"
""")
let keys = KeyMap(table: toml["keys"] ?? [:]) { logs.append($0) }
check(keys[.toggleSidebar] == Shortcut.parse("cmd+k"), "configured toggle_sidebar")
check(keys[.palette] == Shortcut.parse("cmd+p"), "configured palette")
check(keys[.newTab] == Shortcut.parse("cmd+t"), "invalid new_tab keeps its default")
check(keys[.closeTab] == Shortcut.parse("cmd+w"), "non-string close_tab keeps its default")
check(keys[.selectTab1] == Shortcut.parse("cmd+1"), "select_tab_1 clashing with palette keeps its default")
check(logs.contains { $0.contains("launch_rockets") }, "unknown action logged")
check(logs.contains { $0.contains("new_tab") }, "invalid entry logged")
check(logs.contains { $0.contains("select_tab_1") }, "clash logged")

let defaults = KeyMap.defaults
check(defaults[.palette] == Shortcut.parse("cmd+k"), "palette defaults to cmd+k")
check(defaults[.toggleSidebar] == Shortcut.parse("cmd+shift+b"), "toggle_sidebar defaults to cmd+shift+b")
let unbound: Set<KeyMap.Action> = [.renameTab]
check(KeyMap.Action.allCases.allSatisfy { (defaults[$0] == nil) == unbound.contains($0) }, "every action but rename_tab has a default")
check(Set(KeyMap.Action.allCases.compactMap { defaults[$0] }).count == KeyMap.Action.allCases.count - unbound.count, "defaults are distinct")
check(defaults[.nextTab]?.keyEquivalent == "}" && defaults[.nextTab]?.display == "⇧⌘]", "next_tab is ⇧⌘], matched as }")
check(defaults[.previousTab]?.keyEquivalent == "{" && defaults[.previousTab]?.display == "⇧⌘[", "previous_tab is ⇧⌘[")
check(Shortcut.parse("cmd+,")?.keyEquivalent == ",", "unshifted punctuation unchanged")
let renamed = KeyMap(table: TOML.parse("[keys]\nrename_tab = \"cmd+shift+r\"\n")["keys"] ?? [:], log: { _ in })
check(renamed[.renameTab] == Shortcut.parse("cmd+shift+r"), "rename_tab can be bound")

// Ghostty loses every chord haunt uses.
let conf = HauntConfig.ghosttyConfig([:], defaultSize: 11, keys: defaults)
for line in ["keybind = shift+super+bracket_right=unbind", "keybind = super+k=unbind", "keybind = shift+super+b=unbind", "keybind = super+comma=unbind", "keybind = super+t=unbind"] {
    check(conf.contains(line + "\n"), "ghostty config has \(line)")
}
check(conf.components(separatedBy: "keybind = super+t=unbind").count == 2, "unbinds are not repeated")
let custom = HauntConfig.ghosttyConfig([:], defaultSize: 11, keys: keys)
check(custom.contains("keybind = super+p=unbind\n"), "configured chord unbound")

// Agents-only view: its shortcut, [layout] agents_view, and the persisted state.
check(defaults[.agentsView] == Shortcut.parse("cmd+shift+a"), "agents_view defaults to cmd+shift+a")
check(conf.contains("keybind = shift+super+a=unbind\n"), "ghostty loses cmd+shift+a")
check(KeyMap(table: TOML.parse("[keys]\nagents_view = \"cmd+opt+a\"")["keys"]!) { _ in }[.agentsView] == Shortcut.parse("cmd+opt+a"),
      "agents_view is configurable")
var layoutLogs: [String] = []
check(AgentsViewStyle.parse(nil) { layoutLogs.append($0) } == .narrowList && layoutLogs.isEmpty, "agents_view defaults to narrow-list")
check(AgentsViewStyle.parse(TOML.parse("[layout]\nagents_view = \"narrow-list\"")["layout"]?["agents_view"]) { layoutLogs.append($0) } == .narrowList
      && layoutLogs.isEmpty, "narrow-list parses")
check(AgentsViewStyle.parse(.scalar("dashboard")) { layoutLogs.append($0) } == .narrowList, "unknown view falls back")
check(layoutLogs.count == 1 && layoutLogs[0].contains("dashboard"), "unknown view logged")

// [layout] titlebar_buttons
var tbLogs: [String] = []
check(TitlebarButton.parse(nil) { tbLogs.append($0) } == [.search, .newTab, .sidebar] && tbLogs.isEmpty, "titlebar_buttons default")
let tb = TOML.parse("[layout]\ntitlebar_buttons = [\"sidebar\", \"bogus\", \"search\", \"sidebar\"]")["layout"]?["titlebar_buttons"]
check(TitlebarButton.parse(tb) { tbLogs.append($0) } == [.sidebar, .search], "titlebar_buttons keeps order, drops unknown and repeats")
check(tbLogs.count == 2 && tbLogs[0].contains("bogus") && tbLogs[1].contains("twice"), "titlebar_buttons problems logged")
check(TitlebarButton.parse(.array([])) { _ in } == [], "empty titlebar_buttons leaves the bar bare")
let old = try! JSONDecoder().decode(HauntConfig.State.self, from: Data(#"{"sidebar_hidden":true}"#.utf8))
check(old.sidebarHidden && !old.agentsView, "older state.json keeps sidebar_hidden")
var st = HauntConfig.State()
st.agentsView = true
let round = try! JSONDecoder().decode(HauntConfig.State.self, from: JSONEncoder().encode(st))
check(round.agentsView && !round.sidebarHidden, "agents_view round-trips")
check(String(data: try! JSONEncoder().encode(st), encoding: .utf8)!.contains("\"agents_view\":true"), "stored as agents_view")
// The app's state is read once and merged on save, so agents written by `haunt setup` meanwhile survive.
let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("haunt-state-\(getpid())")
try! FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
let sc = HauntConfig(dir: stateDir)
check(!sc.state.sidebarHidden && sc.state.agents == nil, "missing state.json reads as defaults")
sc.updateState { $0.sidebarHidden = true }
check(!FileManager.default.fileExists(atPath: sc.stateURL.path), "state is not written on every change")
try! Data(#"{"agents":["codex"]}"#.utf8).write(to: sc.stateURL)
sc.flushState()
let merged = HauntConfig(dir: stateDir).loadState()
check(merged.sidebarHidden && merged.agents == ["codex"], "flush merges the app's keys into the file")
check(sc.state.agents == ["codex"], "flush picks up the file's agents")
try? FileManager.default.removeItem(at: stateDir)
// Shifted digits and punctuation match as the shifted character; delete is forward delete.
check(Shortcut.parse("cmd+shift+1")?.keyEquivalent == "!", "cmd+shift+1 matches as !")
check(Shortcut.parse("cmd+shift+comma")?.keyEquivalent == "<", "cmd+shift+comma matches as <")
check(Shortcut.parse("cmd+delete")?.keyEquivalent == String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!), "delete is forward delete")
check(Shortcut.parse("cmd+backspace")?.keyEquivalent == "\u{8}", "backspace")

// Of two entries with one chord, the one written first wins, whatever the names.
let clashText = "[keys]\nsettings = \"cmd+j\"\nclose_tab = \"cmd+j\"\n"
var clashLogs: [String] = []
let clash = KeyMap(table: TOML.parse(clashText)["keys"] ?? [:], order: TOML.keyOrder(clashText, table: "keys")) { clashLogs.append($0) }
check(clash[.settings] == Shortcut.parse("cmd+j"), "first written wins")
check(clash[.closeTab] == Shortcut.parse("cmd+w"), "later clash keeps its default")
check(TOML.keyOrder(clashText, table: "keys") == ["settings", "close_tab"], "key order")

// CRLF files parse like LF ones.
let crlf = TOML.parse("font_size = 13\r\n[keys]\r\npalette = \"cmd+p\"\r\n")
check(crlf[""]?["font_size"] == .scalar("13"), "CRLF top-level value")
check(crlf["keys"]?["palette"] == .scalar("cmd+p"), "CRLF table value")
check(TOML.parse("a = 1\rb = 2")[""]?["b"] == .scalar("2"), "lone CR line break")

// A right-click paste would bypass Haunt's paste checks.
let rc = HauntConfig.ghosttyConfig(TOML.parse("[ghostty]\nright-click-action = copy-or-paste\ncursor-style = bar\n"), defaultSize: 11, keys: defaults)
check(!rc.contains("right-click-action"), "right-click paste refused")
check(rc.contains("cursor-style = bar\n"), "other passthrough kept")
let rcOK = HauntConfig.ghosttyConfig(TOML.parse("[ghostty]\nright-click-action = copy\n"), defaultSize: 11, keys: defaults)
check(rcOK.contains("right-click-action = copy\n"), "right-click copy allowed")

// Plugin commands: their default keys bind unless taken, `[keys]` overrides them, and Ghostty lets them through.
let up = KeyMap.pluginName("dev.haunt.tabs", "move-up"), down = KeyMap.pluginName("dev.haunt.tabs", "move-down")
let pluginDefaults = [up: "alt+cmd+up", down: "alt+cmd+down", "dev.x.y/steal": "cmd+t"]
var pluginLogs: [String] = []
let withPlugins = KeyMap(table: TOML.parse("[keys]\n\"dev.haunt.tabs/move-down\" = \"ctrl+opt+j\"\n")["keys"] ?? [:],
                         pluginDefaults: pluginDefaults) { pluginLogs.append($0) }
check(withPlugins.plugin[up] == Shortcut.parse("cmd+opt+up"), "plugin default binds")
check(withPlugins.plugin[down] == Shortcut.parse("ctrl+opt+j"), "[keys] overrides a plugin default")
check(withPlugins.plugin["dev.x.y/steal"] == nil && withPlugins[.newTab] == Shortcut.parse("cmd+t"), "a plugin default never takes a Haunt chord")
check(pluginLogs.contains { $0.contains("dev.x.y/steal") }, "the refused default is logged")
let taken = KeyMap(table: TOML.parse("[keys]\n\"dev.haunt.tabs/move-up\" = \"cmd+k\"\n")["keys"] ?? [:], pluginDefaults: pluginDefaults) { _ in }
check(taken.plugin[up] == Shortcut.parse("cmd+k") && taken[.palette] == nil, "a configured plugin chord beats a Haunt default, as for actions")
// Plugin defaults need cmd and stay off reserved chords; a chord the user sets in [keys] is unrestricted.
var guardLogs: [String] = []
let guarded = KeyMap(table: TOML.parse("[keys]\n\"dev.x.y/user\" = \"ctrl+r\"\ncopy = \"cmd+shift+c\"\n")["keys"] ?? [:],
                     pluginDefaults: ["dev.x.y/c": "ctrl+c", "dev.x.y/b": "opt+b", "dev.x.y/copy": "cmd+c",
                                      "dev.x.y/home": "cmd+left", "dev.x.y/up": "cmd+opt+up", "dev.x.y/user": "cmd+j"]) { guardLogs.append($0) }
check(guarded.plugin["dev.x.y/c"] == nil, "a plugin default of ctrl+c is refused")
check(guarded.plugin["dev.x.y/b"] == nil, "a plugin default of opt+b is refused")
check(guarded.plugin["dev.x.y/copy"] == nil && guarded[.copy] == Shortcut.parse("cmd+shift+c"), "a plugin default can't take a Haunt default chord the user moved")
check(guarded.plugin["dev.x.y/home"] == nil, "a plugin default can't take terminal line editing")
check(guarded.plugin["dev.x.y/up"] == Shortcut.parse("cmd+opt+up"), "cmd+opt+up is accepted")
check(guarded.plugin["dev.x.y/user"] == Shortcut.parse("ctrl+r"), "a user-configured ctrl chord is honoured")
check(guardLogs.filter { $0.contains("needs cmd") }.count == 4, "each refused default is logged")
// One chord, however it's spelled, is one Shortcut, so an alias can't slip past `reserved`.
for (a, b) in [("cmd+return", "cmd+enter"), ("cmd+opt+esc", "cmd+opt+escape"), ("cmd+,", "cmd+comma"),
               ("cmd+=", "cmd+equal"), ("cmd+`", "cmd+backquote"), ("command+alt+escape", "cmd+opt+escape")] {
    check(Shortcut.parse(a) == Shortcut.parse(b) && Set([Shortcut.parse(a)!, Shortcut.parse(b)!]).count == 1, "\(a) is \(b)")
}
check(Shortcut.parse("cmd+return")?.display == "⌘↩" && Shortcut.parse("cmd+esc")?.ghosttyTriggers == ["super+escape"], "aliases keep their glyph and trigger")
let aliased = ["dev.x.y/r": "cmd+return", "dev.x.y/e": "cmd+opt+esc", "dev.x.y/p": "cmd+,", "dev.x.y/q": "cmd+=", "dev.x.y/g": "cmd+`"]
let viaAlias = KeyMap(table: [:], pluginDefaults: aliased) { _ in }
check(viaAlias.plugin.isEmpty, "reserved chords are refused under any spelling: \(viaAlias.plugin.keys.sorted())")
let pg = HauntConfig.ghosttyConfig([:], defaultSize: 11, keys: withPlugins)
check(pg.contains("keybind = alt+super+arrow_up=unbind\n"), "plugin chords are unbound in Ghostty")

print(failures == 0 ? "keys: all passed" : "keys: \(failures) failed")
exit(failures == 0 ? 0 : 1)
