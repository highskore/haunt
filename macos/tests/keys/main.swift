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

print(failures == 0 ? "keys: all passed" : "keys: \(failures) failed")
exit(failures == 0 ? 0 : 1)
