import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

let home = URL(fileURLWithPath: CommandLine.arguments[1])
let user = home.appendingPathComponent("themes"), bundled = home.appendingPathComponent("bundled")
for d in [user, bundled] { try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
func write(_ dir: URL, _ name: String, _ text: String) {
    try! text.write(to: dir.appendingPathComponent("\(name).toml"), atomically: true, encoding: .utf8)
}
func load(_ name: String?) -> LoadedTheme { LoadedTheme.load(name, userDir: home, bundled: bundled) }
let bw = Theme()

// The default.
check(load(nil).theme == bw && load(nil).problems.isEmpty, "no theme is the default")
check(load("bw").theme == bw && load("bw").files.isEmpty, "bw is the default and reads no file")

// Tokens, appearance, layout and ghostty from one file.
write(bundled, "aero", """
appearance = "light"
[color]
window.bg = "#e9f4fb"
row.selected = "#bfe0f280"
[size]
sidebar.w = 248
row.pad = [6, 12]
[app]
hairline = 2
[layout]
titlebar_buttons = ["search"]
[ghostty]
palette = ["0=#000000", "1=#ff0000"]
cursor-color = "#ffffff"
""")
let aero = load("aero")
check(aero.problems.isEmpty, "aero loads cleanly: \(aero.problems)")
check(aero.theme.color.windowBg.themeHex == "#e9f4fbff", "window.bg \(aero.theme.color.windowBg.themeHex)")
check(aero.theme.color.rowSelected.themeHex == "#bfe0f280", "alpha kept \(aero.theme.color.rowSelected.themeHex)")
check(aero.theme.size.sidebarW == 248 && aero.theme.size.rowPad == [6, 12], "sizes")
check(aero.theme.app.hairline == 2 && aero.theme.app.appearance == "light", "app table and appearance")
check(aero.theme.color.dot == bw.color.dot, "untouched tokens keep the default")
check(aero.theme.color.textPrimary != bw.color.textPrimary, "default text a light theme would hide is redrawn, quietly")
check(aero.layout["titlebar_buttons"]?.strings == ["search"], "layout keys come through")
check(aero.ghostty["palette"]?.strings.count == 2 && aero.ghostty["cursor-color"]?.strings == ["#ffffff"], "ghostty keys come through")
check(aero.files.map(\.lastPathComponent) == ["aero.toml", "aero.toml"], "both candidate paths are watched")

// A theme may only set appearance keys in [ghostty]; anything that runs, types, reads or binds is dropped.
write(bundled, "evil", """
[ghostty]
cursor-color = "#ff0000"
command = "/bin/sh -c 'touch /tmp/pwned'"
initial-command = "/bin/sh"
env = "PATH=/tmp"
keybind = "a=text:rm -rf ~\\r"
custom-shader = "/tmp/x.glsl"
working-directory = "/"
theme = "/tmp/other"
""")
let evil = load("evil")
check(evil.ghostty.keys.sorted() == ["cursor-color"], "only appearance keys survive: \(evil.ghostty.keys.sorted())")
for k in ["command", "initial-command", "env", "keybind", "custom-shader", "working-directory", "theme"] {
    check(evil.problems.contains { $0.contains("[ghostty] \(k) ") }, "\(k) is reported")
}
for k in ["adjust-cell-height", "font-family-bold", "cursor-invert-fg-bg", "selection-background", "bold-is-bright", "bold-color"] {
    check(LoadedTheme.themeMaySet(k), "\(k) is an appearance key")
}
for k in ["config-file", "cursor-click-to-move", "selection-clear-on-copy", "selection-clear-on-typing", "selection-word-chars",
          "font-codepoint-map", "adjust-", "cursor-", "font-family-x", "Cursor-color", "cursor-color\ncommand", " cursor-color"] {
    check(!LoadedTheme.themeMaySet(k), "\(k.debugDescription) is refused")
}

// The user's folder wins over the bundled one.
write(user, "aero", "[color]\nwindow.bg = \"#010203\"\n")
check(load("aero").theme.color.windowBg.themeHex == "#010203ff", "the user's theme wins")
check(load("aero").layout.isEmpty, "the bundled file isn't merged under the user's")
try! FileManager.default.removeItem(at: user.appendingPathComponent("aero.toml"))

// extends: ancestors first, the child wins.
write(user, "child", "extends = \"aero\"\n[color]\nrow.selected = \"#111111\"\n[layout]\nagents_view = \"narrow-list\"\n")
let child = load("child")
check(child.problems.isEmpty, "child loads: \(child.problems)")
check(child.theme.color.windowBg.themeHex == "#e9f4fbff", "inherits the parent's token")
check(child.theme.color.rowSelected.themeHex == "#111111ff", "overrides the parent's token")
check(child.layout.count == 2 && child.theme.app.appearance == "light", "merges layout and appearance from the parent")
write(user, "loop-a", "extends = \"loop-b\"\n")
write(user, "loop-b", "extends = \"loop-a\"\n")
check(load("loop-a").theme == bw && load("loop-a").problems.first?.contains("extends itself") == true, "a cycle falls back: \(load("loop-a").problems)")
for (i, n) in ["d1", "d2", "d3", "d4", "d5"].enumerated() { write(user, n, i < 4 ? "extends = \"d\(i + 2)\"\n" : "") }
check(load("d1").theme == bw && load("d1").problems.first?.contains("more than 4") == true, "too deep falls back")
check(load("d2").problems.isEmpty, "four levels load")

// Names and missing files.
check(load("../etc/passwd").theme == bw && load("../etc/passwd").files.isEmpty, "a path is refused before any lookup")
check(load("Aero").problems.first?.contains("lowercase") == true, "uppercase refused")
let missing = load("nope")
check(missing.theme == bw && missing.problems.first?.contains("not found") == true, "missing falls back")
check(missing.files.count == 2, "a missing theme's paths are still watched, so creating it reloads")
write(user, "badparent", "extends = \"nope\"\n[color]\nwindow.bg = \"#123456\"\n")
check(load("badparent").theme == bw, "a broken parent drops the whole theme")

// Validation: each bad key is skipped, the rest applies.
write(user, "bad", """
[color]
claude = "#000000"
window.bg = "red"
row.selected = "#abcdef"
nope.nope = "#000000"
[size]
sidebar.w = 9000
row.pad = [1, 2, 3]
palette.w = "wide"
[font]
ui = "No Such Font Family"
[app]
hairline = -1
""")
let bad = load("bad")
check(bad.theme.color.rowSelected.themeHex == "#abcdefff", "the good key still applies")
check(bad.theme.color.claude == bw.color.claude, "Claude orange is locked")
check(bad.theme.size.sidebarW == bw.size.sidebarW && bad.theme.size.rowPad == bw.size.rowPad, "bad sizes skipped")
check(bad.theme.font.ui == bw.font.ui && bad.theme.app.hairline == bw.app.hairline, "bad font and app value skipped")
check(bad.problems.count == 8, "one problem per bad key: \(bad.problems)")
check(bad.problems.contains { $0.contains("color.claude") && $0.contains("can't be changed") }, "claude reason")
check(bad.problems.contains { $0.contains("nope.nope") && $0.contains("unknown") }, "unknown reason")

// The user's [layout] and [ghostty] keys win over the theme's (HauntConfig.reload).
let cfgDir = home.appendingPathComponent("cfg")
try! FileManager.default.createDirectory(at: cfgDir.appendingPathComponent("themes"), withIntermediateDirectories: true)
write(cfgDir.appendingPathComponent("themes"), "t", """
[color]
window.bg = "#102030"
text.terminal = "#c0d0e0"
[layout]
titlebar_buttons = ["search"]
palette_position = "bottom-right"
palette_width = 340
[ghostty]
cursor-color = "#aaaaaa"
cursor-style = block
selection-background = "#111111\\ncommand = /bin/sh -c pwned"
right-click-action = paste
command = /bin/sh
""")
try! "theme = \"t\"\n[layout]\ntitlebar_buttons = [\"sidebar\"]\npalette_width = 400\n[ghostty]\ncursor-style = bar\n"
    .write(to: cfgDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
let cfg = HauntConfig(dir: cfgDir)
let first = cfg.reload()
let conf = try! String(contentsOf: cfg.ghosttyURL, encoding: .utf8)
check(first.theme && cfg.themeName == "t", "theme loaded")
check(cfg.titlebarButtons == [.sidebar], "the user's titlebar_buttons win: \(cfg.titlebarButtons)")
check(cfg.paletteLayout == PaletteLayout(position: .bottomRight, width: 400), "the theme moves the palette, the user's width wins: \(cfg.paletteLayout)")
check(conf.contains("cursor-style = bar") && !conf.contains("cursor-style = block"), "the user's ghostty key wins")
check(conf.contains("cursor-color = #aaaaaa"), "the theme's ghostty key comes through")
check(!conf.contains("right-click-action = paste"), "the theme's ghostty keys go through the refusals")
check(!conf.contains("command = /bin/sh"), "a theme's non-appearance ghostty key never reaches the generated config")
check(!conf.contains("selection-background") && !conf.contains("pwned"), "a theme value with a line break never reaches the generated config")
check(conf.contains("background = #102030") && conf.contains("foreground = #c0d0e0"), "terminal colours follow the theme")
check(conf.contains("minimum-contrast = 1.1"), "a minimum contrast the theme can't turn off")
write(cfgDir.appendingPathComponent("themes"), "lowc", "[ghostty]\nminimum-contrast = 1\n")
_ = cfg.preview("lowc")
check((try! String(contentsOf: cfg.ghosttyURL, encoding: .utf8)).contains("minimum-contrast = 1.1"), "not even by setting it lower")
for (v, want) in [("nan", "1.1"), ("inf", "1.1"), ("-inf", "1.1"), ("1e400", "1.1"), ("99", "21")] {
    write(cfgDir.appendingPathComponent("themes"), "lowc", "[ghostty]\nminimum-contrast = \(v)\n")
    _ = cfg.preview("lowc")
    check((try! String(contentsOf: cfg.ghosttyURL, encoding: .utf8)).contains("minimum-contrast = \(want)\n"), "minimum-contrast \(v) becomes \(want)")
}
check(HauntConfig.num(.nan) == "0" && HauntConfig.num(.infinity) == "0" && HauntConfig.num(1e20) == "1e+20" && HauntConfig.num(2) == "2",
      "num never traps")
try! "theme = \"lowc\"\n[ghostty]\nminimum-contrast = 1\n".write(to: cfgDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
_ = cfg.preview(nil)
_ = cfg.reload()
check((try! String(contentsOf: cfg.ghosttyURL, encoding: .utf8)).contains("minimum-contrast = 1\n"), "the user's own value wins")
try! "theme = \"t\"\n[layout]\ntitlebar_buttons = [\"sidebar\"]\npalette_width = 400\n[ghostty]\ncursor-style = bar\n"
    .write(to: cfgDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
_ = cfg.reload()

// Text and indicators stay opaque and readable.
write(user, "faint", """
[color]
text.meta = "#ffffff40"
text.sub = "#ffffff80"
palette.mute = "#ffffff80"
text.primary = "#ffffff80"
needs = "#101010"
sidebar.bg = "#0e0e0e"
diff.add.bg = "#ffffff"
[ghostty]
background = "#000000"
foreground = "#050505"
""")
let faint = load("faint")
check(faint.theme.color.textMeta == bw.color.textMeta && faint.problems.contains { $0.contains("text.meta") && $0.contains("40% opaque") }, "too see-through secondary text is refused")
check(faint.theme.color.textSub.themeHex == "#ffffff80" && faint.theme.color.paletteMute.themeHex == "#ffffff80", "secondary text may be half see-through")
check(faint.theme.color.textPrimary == bw.color.textPrimary && faint.problems.contains { $0.contains("text.primary") && $0.contains("must be opaque") },
      "primary text may not")
check(faint.theme.color.needs.themeHex == "#ffffffff" && faint.problems.contains { $0.contains("color.needs:") }, "a faint needs mark is redrawn readable")
check(faint.theme.color.diffAddInk.themeHex == "#000000ff" && !faint.problems.contains { $0.contains("diff.add.ink") },
      "a default ink the theme's background hid is fixed quietly: \(faint.problems)")
check(faint.ghostty["foreground"] == nil && faint.theme.color.textTerminal.themeHex == "#ffffffff"
      && faint.problems.contains { $0.contains("terminal's text") }, "and so is the terminal's text")

// One registry decides what must stay readable: every colour token is in it or named decorative.
let colorNames = Theme.keys.merging(AppTokens.keys) { a, _ in a }.compactMap { k, v -> String? in
    if case .color = v { return k }
    return nil
}
let guarded = Set(Theme.readable.map(\.fg))
check(colorNames.filter { !guarded.contains($0) && !Theme.decorative.contains($0) }.isEmpty
      && guarded.isDisjoint(with: Theme.decorative), "every colour token is classified: \(colorNames.filter { !guarded.contains($0) && !Theme.decorative.contains($0) })")
check(Theme.readable.allSatisfy { r in ([r.fg] + r.over).allSatisfy { Theme.colorPath($0) != nil } }, "the registry names real tokens")

// Every colour token the app draws text in is readable: found where Sources pass one to a text call.
let swiftName = Dictionary(colorNames.map { name -> (String, String) in
    let parts = name.split(separator: ".").map(String.init)
    let camel = parts[1] + parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    return ("Tok.\(parts[0] == "app" ? "App" : "Color").\(camel)", name)
}, uniquingKeysWith: { a, _ in a })
// The overview's tick, cut out of its filled box in the window's colour.
let textExempt: Set<String> = ["color.window.bg"]
var drawnAsText = Set<String>()
for file in try! FileManager.default.contentsOfDirectory(atPath: "macos/Sources") where file.hasSuffix(".swift") {
    let source = try! String(contentsOfFile: "macos/Sources/\(file)", encoding: .utf8)
    for line in source.split(separator: "\n") where line.range(of: #"Draw\.line\(|Draw\.truncated\(|RV\.text\(|\.foregroundColor|let (fg|ink|color) = "#, options: .regularExpression) != nil {
        var rest = line[...]
        while let r = rest.range(of: #"Tok\.(Color|App)\.[A-Za-z]+"#, options: .regularExpression) {
            if let name = swiftName[String(rest[r])] { drawnAsText.insert(name) }
            rest = rest[r.upperBound...]
        }
    }
}
check(drawnAsText.count > 20 && drawnAsText.subtracting(textExempt).isSubset(of: guarded),
      "every token drawn as text is readable: \(drawnAsText.subtracting(textExempt).subtracting(guarded).sorted())")
var defaults = Theme()
check(defaults.makeReadable().isEmpty, "black and white passes its own rules: \(defaults.makeReadable())")
write(user, "inbox", "[color]\ninbox.diff.kw = \"#0b0b0b\"\ninbox.diff.add.mark = \"#161616\"\n")
let inbox = load("inbox")
check(inbox.theme.color.inboxDiffKw.themeHex == "#ffffffff" && inbox.problems.contains { $0.contains("color.inbox.diff.kw:") }
      && inbox.problems.contains { $0.contains("color.inbox.diff.add.mark:") }, "the inbox's diff colours are guarded too: \(inbox.problems)")

// Terminal colours that would vanish into the background are refused.
write(user, "termfaint", """
[ghostty]
background = "#101010"
palette = ["0=#101010", "1=#ff0000", "2=#111111", "3=nope", "7=#121212", "8=#121212"]
selection-background = "#101010"
selection-foreground = "#ffffff"
cursor-text = "#121212"
cursor-color = "#ffffff"
bold-color = "#202020"
""")
let tf = load("termfaint")
check(tf.ghostty["palette"]?.strings == ["0=#101010", "1=#ff0000"],
      "palette entries like the background are dropped, bar black on a dark one: \(String(describing: tf.ghostty["palette"]))")
write(user, "termlight", "appearance = \"light\"\n[ghostty]\nbackground = \"#fafafa\"\npalette = [\"0=#f8f8f8\", \"7=#f8f8f8\", \"15=#ffffff\"]\n")
check(load("termlight").ghostty["palette"]?.strings == ["15=#ffffff"], "and bright white on a light one: \(load("termlight").problems)")
// Bright black (white on light) is secondary text: it keeps a 1.3:1 floor, under the 1.5:1 the rest need.
write(user, "termnear", "[ghostty]\nbackground = \"#101010\"\npalette = [\"1=#2e2e2e\", \"8=#2e2e2e\"]\n")
check(load("termnear").ghostty["palette"]?.strings == ["8=#2e2e2e"], "bright black at 1.4:1 stays: \(load("termnear").problems)")
write(user, "termnearlight", "appearance = \"light\"\n[ghostty]\nbackground = \"#fafafa\"\npalette = [\"1=#d8d8d8\", \"7=#d8d8d8\"]\n")
check(load("termnearlight").ghostty["palette"]?.strings == ["7=#d8d8d8"], "and white at 1.3:1 on light: \(load("termnearlight").problems)")
check(tf.ghostty["selection-background"] == nil && tf.ghostty["cursor-text"] == nil && tf.ghostty["selection-foreground"] != nil,
      "so are a selection and cursor text you can't see")
check(tf.ghostty["bold-color"] == nil, "and bold text in the background's colour")
check(tf.problems.filter { $0.contains("[ghostty]") }.count == 7, "each reported: \(tf.problems)")
write(user, "boldok", "[ghostty]\nbackground = \"#101010\"\nbold-color = \"#f0f0f0\"\n")
write(user, "boldbright", "[ghostty]\nbold-color = \"bright\"\n")
check(load("boldok").ghostty["bold-color"]?.strings == ["#f0f0f0"] && load("boldbright").ghostty["bold-color"]?.strings == ["bright"],
      "a readable bold colour, and Ghostty's `bright`, are kept")
check(!cfg.reload().theme, "an unchanged reload changes no theme")
check(cfg.preview("bw").theme && Theme.current == bw, "a preview applies at once")
check(cfg.preview(nil).theme && Theme.current.color.windowBg.themeHex == "#102030ff", "ending the preview restores config.toml's")

// Live reload follows a previewed theme's file, edited in place.
write(cfgDir.appendingPathComponent("themes"), "u", "[color]\nwindow.bg = \"#111111\"\n")
var reloaded = false
cfg.watch { if $0.theme { reloaded = true } }
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
_ = cfg.preview("u")
// The preview's own Ghostty write fires the folder watch; let it pass before the edit.
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
reloaded = false
let u = try! FileHandle(forWritingTo: cfgDir.appendingPathComponent("themes/u.toml"))
u.seekToEndOfFile()
u.write("[size]\nsidebar.w = 200\n".data(using: .utf8)!)
try! u.close()
let deadline = Date().addingTimeInterval(2)
while !reloaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
check(reloaded && Theme.current.size.sidebarW == 200, "an edit to the previewed theme reloads it")
Theme.current = Theme()

// Writing the choice.
check(HauntConfig.settingTheme("glass", in: "") == "theme = \"glass\"\n", "empty file")
check(HauntConfig.settingTheme("glass", in: "font_size = 12\ntheme = \"aero\"\n[keys]\ntheme = \"x\"\n")
    == "font_size = 12\ntheme = \"glass\"\n[keys]\ntheme = \"x\"\n", "replaces the top-level line only")
check(HauntConfig.settingTheme("glass", in: "[keys]\na = \"cmd+a\"\n") == "theme = \"glass\"\n[keys]\na = \"cmd+a\"\n", "adds above the first table")
let linkDir = home.appendingPathComponent("linked"), dotfiles = home.appendingPathComponent("dotfiles.toml")
try! FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
try! "font_size = 12\n".write(to: dotfiles, atomically: true, encoding: .utf8)
try! FileManager.default.createSymbolicLink(at: linkDir.appendingPathComponent("config.toml"), withDestinationURL: dotfiles)
HauntConfig(dir: linkDir).saveTheme("glass")
check((try? FileManager.default.destinationOfSymbolicLink(atPath: linkDir.appendingPathComponent("config.toml").path)) == dotfiles.path
      && (try! String(contentsOf: dotfiles, encoding: .utf8)) == "theme = \"glass\"\nfont_size = 12\n", "a symlinked config.toml stays a symlink")
let fresh = home.appendingPathComponent("fresh")
try! FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
HauntConfig(dir: fresh).saveTheme("glass")
check((try? String(contentsOf: fresh.appendingPathComponent("config.toml"), encoding: .utf8)) == "theme = \"glass\"\n", "a missing config.toml is created")

// What plugins read.
let ex = aero.theme.exported()
check(ex["color.window.bg"] == "#e9f4fbff" && ex["size.sidebar.w"] == "248" && ex["app.hairline"] == "2", "exported tokens")
check(ex.count == Theme.keys.count + AppTokens.keys.count, "every token exported")

// [effects]: known elements only, typed and ranged; the rest is refused into problems.
write(user, "fx", "[effects]\nwindow.material = \"glass\"\nwindow.radius = 14\nsidebar.footer = true\n[app]\nsidebar.foot.pad = [8, 12, 10]\n")
let fx = load("fx")
check(fx.problems.isEmpty && fx.theme.effects.windowMaterial == "glass" && fx.theme.effects.windowRadius == 14 && fx.theme.effects.sidebarFooter && fx.theme.app.sidebarFootPad == [8, 12, 10], "effects load: \(fx.problems)")
write(user, "fxbad", "[effects]\nwindow.material = \"chrome\"\nwindow.radius = 99\nscript = \"x\"\nwindow.radius.x = [1]\n")
let fxbad = load("fxbad")
check(fxbad.theme.effects == Effects() && fxbad.problems.count == 4, "bad effects refused: \(fxbad.problems)")
check(load("child").theme.effects == Effects(), "no [effects] keeps every element off")
write(user, "fxglass", "[effects]\ntitlebar.rule = false\nlabel.case = \"sentence\"\nrow.radius = 9\npalette.selection = \"pill\"\npalette.foot = false\npalette.modes = \"plain\"\nrow.hover = true\nbar.done = false\npalette.blur = \"sheet\"\npalette.tab.sub = \"task\"\n[app]\npill.radius = 6\nsidebar.padtop = 2\npalette.caret.gap = 1\n[font]\nbase.line = 1.4\n")
let fxg = load("fxglass").theme
// A blurred palette's tint carries at least half its colour; #…80 is exactly that and passes.
write(user, "blurthin", "[color]\npalette.bg = \"#12264c7f\"\n[effects]\npalette.material = \"glass\"\npalette.blur = \"sheet\"\n")
write(user, "blurhalf", "[color]\npalette.bg = \"#12264c80\"\n[effects]\npalette.material = \"glass\"\npalette.blur = \"sheet\"\n")
let thin = load("blurthin"), half = load("blurhalf")
check(thin.theme.color.paletteBg.alphaComponent == 0.5 && thin.problems.contains { $0.contains("color.palette.bg") },
      "a thinner tint is raised to half and reported: \(thin.problems)")
check(half.theme.color.paletteBg.alphaComponent == 128.0 / 255 && !half.problems.contains { $0.contains("color.palette.bg") },
      "0x80 passes: \(half.problems)")
check(!fxg.effects.titlebarRule && fxg.effects.labelCase == "sentence" && fxg.effects.rowRadius == 9 && fxg.effects.paletteSelection == "pill"
      && !fxg.effects.paletteFoot && fxg.effects.paletteScrim && fxg.app.pillRadius == 6 && fxg.effects.paletteModes == "plain"
      && fxg.effects.rowHover && !fxg.effects.barDone && fxg.app.sidebarPadtop == 2 && fxg.app.paletteCaretGap == 1
      && fxg.font.baseLine == 1.4 && fxg.effects.paletteBlur == "sheet" && fxg.effects.paletteTabSub == "task", "the glass elements load: \(load("fxglass").problems)")
write(user, "fxglassbad", "[effects]\nlabel.case = \"lower\"\nbar.radius = 11\npalette.keys = \"/bin/sh\"\n")
check(load("fxglassbad").problems.count == 3, "and refuse what isn't theirs")
write(user, "huge", "name = \"Huge\"\n# " + String(repeating: "x", count: LoadedTheme.maxBytes) + "\n")
let huge = load("huge")
check(huge.name == "bw" && huge.problems.first?.contains("larger than 256 KB") == true, "an oversized theme file isn't read: \(huge.problems)")

// Theme plugins: after the user's folder, before the bundled one; their fonts go to `activate`.
let plug = home.appendingPathComponent("plugin")
try! FileManager.default.createDirectory(at: plug, withIntermediateDirectories: true)
write(plug, "theme", "name = \"Glass\"\nextends = \"aero\"\n[color]\nwindow.bg = \"#203040\"\n")
write(bundled, "glass", "[color]\nwindow.bg = \"#999999\"\n")
let font = plug.appendingPathComponent("A.ttf")
let plugins = ["glass": PluginTheme(file: plug.appendingPathComponent("theme.toml"), fonts: [font])]
var activated: [[URL]] = []
let glass = LoadedTheme.load("glass", userDir: home, plugins: plugins, bundled: bundled) { activated.append($0 + $1) }
check(glass.theme.color.windowBg.themeHex == "#203040ff" && glass.theme.size.sidebarW == 248, "a plugin theme loads, extending a bundled one")
check(activated == [[font]] && glass.uiFonts == [font] && glass.fonts.isEmpty, "its fonts are activated before the tokens apply, kept private: \(activated)")
check(glass.files.map(\.path).contains(plug.appendingPathComponent("theme.toml").path), "the plugin's file is watched")
activated = []
_ = LoadedTheme.load("aero", userDir: home, plugins: plugins, bundled: bundled) { activated.append($0 + $1) }
check(activated == [[]], "a theme without plugin fonts activates none")
write(user, "glass", "[color]\nwindow.bg = \"#010101\"\n")
check(LoadedTheme.load("glass", userDir: home, plugins: plugins, bundled: bundled).theme.color.windowBg.themeHex == "#010101ff", "the user's file wins over a plugin's")
activated = []
_ = LoadedTheme.load("glass", userDir: home, plugins: plugins, bundled: bundled) { activated.append($0 + $1) }
check(activated == [[]], "a user file shadowing a plugin's brings none of the plugin's fonts")
try! FileManager.default.removeItem(at: user.appendingPathComponent("glass.toml"))

// A user-installed plugin's fonts may draw the UI only; a bundled one's may draw the terminal.
let own = home.appendingPathComponent("Own.ttf")
let shadows = ["Shadow.ttf", "menlo.ttf", "MenloSpace.ttf"].map { home.appendingPathComponent($0) }

// A font file's names are read once, and again when the file changes.
let swapped = home.appendingPathComponent("Swapped.ttf")
try! FileManager.default.copyItem(at: own, to: swapped)
check(ThemeFonts.names(swapped).contains("haunt theme test") && ThemeFonts.names(swapped) == ThemeFonts.names(own), "a font's names")
try! FileManager.default.removeItem(at: swapped)
try! FileManager.default.copyItem(at: shadows[0], to: swapped)
check(ThemeFonts.names(swapped).contains("helvetica") && !ThemeFonts.names(swapped).contains("haunt theme test"), "a replaced font is read again")
try! FileManager.default.removeItem(at: swapped)
write(plug, "fonts", """
[font]
ui = "Haunt Theme Test"
mono.family = "haunt  THEME test"
mono.css = "\\"Haunt Theme Test\\", monospace"
mono.fallback = ["Menlo", "HAUNT THEME TEST "]
[ghostty]
font-family = "'haunt theme test'"
font-family-bold = "Menlo"
""")
let fontsFile = plug.appendingPathComponent("fonts.toml")
let userFonts = LoadedTheme.load("fonts", userDir: home, plugins: ["fonts": PluginTheme(file: fontsFile, fonts: [own] + shadows)], bundled: nil,
                                 activate: ThemeFonts.activate)
check(userFonts.theme.font.ui == "Haunt Theme Test", "a user plugin's font sets font.ui: \(userFonts.problems)")
check(userFonts.theme.font.monoFamily == Theme().font.monoFamily && userFonts.theme.font.monoCss == Theme().font.monoCss
      && userFonts.theme.font.monoFallback == Theme().font.monoFallback, "but not the mono fonts, however it is spelt")
check(userFonts.ghostty["font-family"] == nil && userFonts.ghostty["font-family-bold"] != nil, "nor the terminal's")
for k in ["font.mono.family", "font.mono.css", "font.mono.fallback", "[ghostty] font-family:"] {
    check(userFonts.problems.contains { $0.contains(k) && $0.contains(Theme.uiOnlyWhy) }, "\(k) refused as a user plugin's font: \(userFonts.problems)")
}
check(userFonts.uiFonts == [own] && userFonts.fonts.isEmpty, "only its own-named font is kept: \(userFonts.uiFonts)")
for f in ["Shadow.ttf", "menlo.ttf", "MenloSpace.ttf"] {
    check(userFonts.problems.contains { $0.hasPrefix(f) && $0.contains("already installed") }, "\(f), named like an installed font, isn't loaded")
}
// The terminal and Core Text's fallback find fonts by what's registered; a private face never is.
check(ThemeFonts.active.isEmpty && !(CTFontManagerCopyAvailableFontFamilyNames() as! [String]).contains("Haunt Theme Test")
      && NSFontManager.shared.font(withFamily: "Haunt Theme Test", traits: [], weight: 5, size: 12) == nil
      && NSFont(name: "Haunt Theme Test", size: 12) == nil, "a user plugin's font is invisible to the terminal")
check(ThemeFonts.uiFont(family: "Haunt Theme Test", weight: .regular, size: 12).map { ThemeFonts.normalized($0.familyName ?? "") } == "haunt theme test",
      "while the UI can draw with it")
write(plug, "appfonts", "[font]\nmono.family = \"Haunt Theme Test\"\n[ghostty]\nfont-family = \"Haunt Theme Test\"\n")
let appFonts = LoadedTheme.load("appfonts", userDir: home, plugins: ["appfonts": PluginTheme(file: plug.appendingPathComponent("appfonts.toml"), fonts: [own], bundled: true)],
                                bundled: nil, activate: ThemeFonts.activate)
check(appFonts.problems.isEmpty && appFonts.theme.font.monoFamily == "Haunt Theme Test" && appFonts.ghostty["font-family"] != nil,
      "a bundled plugin's font may draw the terminal: \(appFonts.problems)")
check(ThemeFonts.active == [own] && ThemeFonts.uiFont(family: "Haunt Theme Test", weight: .regular, size: 12) == nil, "registered for the process")
ThemeFonts.activate([], [])
// Asked directly: Core Text's family list lags an unregister.
check(ThemeFonts.active.isEmpty && !CTFontManagerUnregisterFontsForURL(own as CFURL, .process, nil), "and unregistered on a switch")

let pickCfg = HauntConfig(dir: home)
pickCfg.pluginThemes = plugins
let choices = pickCfg.themeChoices()
check(choices.first == HauntConfig.ThemeChoice(id: "bw", name: "Black and white"), "black and white comes first")
check(choices.filter { $0.id == "glass" } == [HauntConfig.ThemeChoice(id: "glass", name: "Glass")], "a plugin theme once, by its name, hiding the bundled one: \(choices)")
check(Set(choices.map(\.id)).count == choices.count, "no id twice")
write(user, "later", "name = \"Later\"\n")
check(!pickCfg.themeChoices().contains { $0.id == "later" }, "the list is kept until the themes folder changes")
pickCfg.pluginThemes = plugins
check(pickCfg.themeChoices().contains { $0.id == "later" }, "or the plugin themes do")

// A preview works from config.toml as last read; choosing writes it and reads it again.
try! "theme = \"later\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
_ = pickCfg.reload()
try! "theme = \"bw\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
_ = pickCfg.preview(nil)
check(pickCfg.themeName == "later", "a preview doesn't re-read config.toml")
_ = pickCfg.choose("fxglass")
check(pickCfg.themeName == "fxglass" && (try! String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)) == "theme = \"fxglass\"\n",
      "choosing saves and applies")
Theme.current = Theme()

// Ornament hooks are off in black and white, so it draws exactly as before them.
let bwfx = Effects(), bwapp = AppTokens()
check(!bwfx.windowSquare && !bwfx.windowBorder && !bwfx.titlebarDouble && bwfx.lightsShape == "circle" && bwfx.labelRule == "none"
      && bwfx.rowSelect == "fill" && !bwfx.iconRing && bwfx.iconShell == "tile" && bwfx.progressStyle == "bar" && !bwfx.needsGlow
      && bwfx.ornament == "none" && bwfx.paletteInset == 22 && !bwfx.paletteHeader && !bwfx.paletteInputRules,
      "every ornament effect is off by default")
check(bwfx.windowFrame == "none" && bwfx.paneFrame == "none" && bwfx.titlebarStyle == "plain" && !bwfx.titlebarIcon && !bwfx.titlebarMenu
      && bwfx.iconStyle == "vector" && bwfx.paletteFrame == "panel" && bwapp.titlebarFill.isEmpty && bwapp.paletteOffsetX == 0,
      "and every bevel effect")
check(bwapp.displayFont.isEmpty && bwapp.textChrome.isEmpty && bwapp.strings.isEmpty && Theme().chromeStops.isEmpty,
      "and no display face, chrome or theme words")

// [strings]: known places only, one plain line each, capped; tokens fill in when drawn.
write(user, "words", """
[strings]
palette.header = "Invoke"
titlebar.right = "{day.roman} · {month.roman} · {year.roman}"
sidebar.foot = "AGENTS {agents.roman} ({agents})"
palette.foot = "\u{202E}evil"
row.sub.prefix = "\(String(repeating: "x", count: 65))"
palette.input.glyph = "z\u{0301}\u{0302}\u{0303}"
command = "rm -rf ~"
""")
let words = load("words")
check(words.theme.app.strings["palette.header"] == "Invoke", "a string loads: \(words.problems)")
check(words.theme.app.strings["palette.foot"] == nil && words.problems.contains { $0.contains("strings.palette.foot: not one plain line") },
      "a bidi override is refused")
check(words.theme.app.strings["row.sub.prefix"] == nil && words.problems.contains { $0.contains("strings.row.sub.prefix: longer") }, "so is a long one")
check(words.problems.contains { $0.contains("strings.palette.input.glyph: more than 2 combining marks") }, "and a stack of marks")
write(user, "ignorable", "[strings]\npalette.header = \"In\u{3164}voke\"\nrow.sub.prefix = \"\u{E0041}\"\n")
check(load("ignorable").theme.app.strings.isEmpty && load("ignorable").problems.count == 2, "default-ignorables are hidden too: \(load("ignorable").problems)")
check(words.theme.app.strings["command"] == nil && words.problems.contains { $0.contains("strings.command: unknown string") }, "and an unknown place")
let day = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 4).date!
check(words.theme.string("titlebar.right", now: day) == "IV · XI · MMXXVI", "dates come from the clock, in Roman numerals")
check(words.theme.string("sidebar.foot", agents: 4) == "AGENTS IV (4)" && words.theme.string("palette.foot") == nil, "and the agent count")
write(user, "status", "[strings]\npalette.header = \"Needs You\"\npalette.foot = \"↵ ALLOWED\"\nrow.sub.prefix = \"done \"\nsidebar.foot = \"SPIRITS\"\ntitlebar.right = \"Undone\"\n")
let status = load("status")
check(status.theme.app.strings == ["titlebar.right": "Undone"], "status words are refused, and a foot without the count: \(status.problems)")
check(status.problems.filter { $0.contains("status words") }.count == 3 && status.problems.contains { $0.contains("must show {agents}") }, "each for its reason")
check(Theme.roman(0) == "0" && Theme.roman(3999) == "MMMCMXCIX" && Theme.roman(1994) == "MCMXCIV", "roman numerals")

// Chrome text is drawn flat unless every stop reads on every background it is drawn over.
write(user, "chromeok", "[color]\nwindow.bg = \"#040405\"\nsidebar.bg = \"#060607\"\npalette.bg = \"#050506\"\n[app]\npalette.pill.ink = \"#050506\"\ntext.chrome = [\"#ffffff\", \"#5b5b62\", \"#e8e8ec\"]\n")
write(user, "chromedim", "[color]\nwindow.bg = \"#040405\"\n[app]\ntext.chrome = [\"#ffffff\", \"#3a3a40\"]\n")
write(user, "chromebad", "[app]\ntext.chrome = [\"#ffffff\", \"nope\"]\n")
check(load("chromeok").theme.chromeStops.count == 3, "readable stops are kept: \(load("chromeok").problems)")
check(load("chromedim").theme.app.textChrome.isEmpty && load("chromedim").problems.contains { $0.contains("app.text.chrome") }, "a dim stop drops the gradient")
check(load("chromebad").theme.app.textChrome.isEmpty, "so does a stop that isn't a colour")

// A light window's dark terminal: its text is checked against the terminal's background, not the window's.
write(user, "dosbox", "appearance = \"light\"\n[color]\nwindow.bg = \"#c0c0c0\"\ntext.terminal = \"#c0c0c0\"\n[ghostty]\nbackground = \"#000000\"\n")
write(user, "dosdim", "appearance = \"light\"\n[color]\nwindow.bg = \"#c0c0c0\"\ntext.terminal = \"#c0c0c0\"\n")
check(load("dosbox").problems.isEmpty && load("dosbox").theme.color.textTerminal.hex == "#c0c0c0", "grey on a black terminal: \(load("dosbox").problems)")
check(load("dosdim").problems.contains { $0.contains("terminal") } && load("dosdim").theme.color.textTerminal.hex != "#c0c0c0",
      "grey on a grey terminal is fixed")
check(Theme.stringKeys.contains("palette.message"), "the dialog's message is a theme string")

// Ornaments stay faint, and the watermark shows only through a see-through terminal.
write(user, "faint", "[app]\nornament.alpha = 0.12\n")
write(user, "loud", "[app]\nornament.alpha = 0.5\n")
check(load("faint").theme.app.ornamentAlpha == 0.12, "ornament.alpha up to 0.12")
check(load("loud").theme.app.ornamentAlpha == AppTokens().ornamentAlpha && load("loud").problems.contains { $0.contains("outside 0–0.12") },
      "and no more: \(load("loud").problems)")
write(user, "clear", "[color]\nwindow.bg = \"#0e101680\"\n[ghostty]\nbackground-opacity = 0.55\n")
check(load("clear").theme.app.terminalSeeThrough && !load("faint").theme.app.terminalSeeThrough, "a terminal is see-through only when its window and Ghostty both fade")

print(failures == 0 ? "theme: all passed" : "theme: \(failures) failed")
exit(failures == 0 ? 0 : 1)
