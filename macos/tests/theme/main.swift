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
// Built without the core, every theme string is refused; these tests judge the words with a permissive fake.
let builtInCheck = Theme.statusCheck
Theme.statusCheck = { _ in false }
let bw = Theme()

/// A 100×100 pt canvas drawn top-down, like Haunt's flipped views, at 1 px per pt.
struct Canvas {
    let ctx: CGContext
    func alpha(x: Int, y: Int) -> Int {
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Int(d[(y * ctx.bytesPerRow) + x * 4 + 3])
    }
    func painted() -> Int { (0..<100).reduce(0) { n, y in n + (0..<100).filter { alpha(x: $0, y: y) > 0 }.count } }
    func maxAlpha() -> Int { (0..<100).flatMap { y in (0..<100).map { alpha(x: $0, y: y) } }.max() ?? 0 }
}
func canvas() -> Canvas {
    let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Row 0 of the buffer is the top, as in a flipped view.
    ctx.translateBy(x: 0, y: 100)
    ctx.scaleBy(x: 1, y: -1)
    return Canvas(ctx: ctx)
}
extension PrimSpec {
    func withFrame(of other: PrimSpec) -> PrimSpec { var p = self; p.x = other.x; p.y = other.y; return p }
}


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
write(user, "fxlcd", """
[effects]
ornament = "lcd"
label.rule = "block"
row.select = "cursor"
palette.selection = "cursor"
lights.shape = "squares"
name.font = "display"
[app]
palette.rings = ["#0f380f 2", "#9bbc0f 4"]
bar.segment = [6, 2]
label.space = 3
palette.offset.x = -4
palette.foot.rule = "#0f380f"
""")
let lcd = load("fxlcd")
check(lcd.problems.isEmpty && lcd.theme.effects.ornament == "lcd" && lcd.theme.effects.rowSelect == "cursor" && lcd.theme.effects.nameFont == "display"
      && lcd.theme.app.paletteRings.count == 2 && lcd.theme.app.barSegment == [6, 2] && lcd.theme.app.labelSpace == 3
      && lcd.theme.app.paletteOffsetX == -4 && lcd.theme.app.paletteFootRule.alphaComponent == 1, "the LCD elements load: \(lcd.problems)")
write(user, "fxbad", "[effects]\nwindow.material = \"chrome\"\nwindow.radius = 99\nscript = \"x\"\nwindow.radius.x = [1]\n")
let fxbad = load("fxbad")
check(fxbad.theme.effects == Effects() && fxbad.problems.count == 4, "bad effects refused: \(fxbad.problems)")
check(load("child").theme.effects == Effects(), "no [effects] keeps every element off")
write(user, "fxglass", "[effects]\ntitlebar.rule = false\nlabel.case = \"sentence\"\nrow.radius = 9\npalette.selection = \"pill\"\npalette.foot = false\npalette.modes = \"plain\"\nbar.done = false\npalette.blur = \"sheet\"\npalette.tab.sub = \"task\"\n[app]\npill.radius = 6\nsidebar.padtop = 2\npalette.caret.gap = 1\n[font]\nbase.line = 1.4\n")
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
      && !fxg.effects.barDone && fxg.app.sidebarPadtop == 2 && fxg.app.paletteCaretGap == 1
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
      && bwfx.iconStyle == "vector" && bwfx.paletteFrame == "panel" && bwapp.titlebarFill.isEmpty && bwapp.paletteOffsetX == 0 && bwapp.paletteRowInset == 0,
      "and every bevel effect")
check(bwfx.uiWeight == "regular" && bwfx.needsWeight == "regular", "and the UI's and needs-you's weights")
check(bwfx.nameFont == "ui" && bwapp.sidebarEdge == 0 && bwapp.sidebarFootFrame.alphaComponent == 0 && bwapp.paletteRings.isEmpty
      && bwapp.titlebarBg.alphaComponent == 0 && bwapp.barFrame.alphaComponent == 0 && bwapp.barSegment == [8, 2] && bwapp.labelSpace == 0
      && bwapp.paletteFootRule.alphaComponent == 0,
      "and every LCD effect")
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
// The words themselves are core's label check (its tests hold the probes); here, that a theme goes through it.
var asked: [String] = []
Theme.statusCheck = { asked.append($0); return $0.hasPrefix("Needs") }
write(user, "status", "[strings]\npalette.header = \"Needs You\"\nsidebar.foot = \"SPIRITS\"\ntitlebar.right = \"Undone\"\n")
let status = load("status")
Theme.statusCheck = { _ in false }
check(status.theme.app.strings == ["titlebar.right": "Undone"], "what core's check flags is refused, and a foot without the count: \(status.problems)")
check(status.problems.filter { $0.contains("status words") }.count == 1 && status.problems.contains { $0.contains("must show {agents}") }, "each for its reason")
check(asked.contains("Needs You") && asked.contains("Undone"), "each string is asked about as written: \(asked)")
check(builtInCheck("Invoke") && builtInCheck(""), "without the core, every string is refused")
Theme.statusCheck = { $0 == "AGENTS IV (4)" }
check(words.theme.string("sidebar.foot", agents: 4) == nil && words.theme.string("sidebar.foot", agents: 3) == "AGENTS III (3)",
      "the words are checked again once the count is filled in, and drawn as Haunt's own when they fail")
Theme.statusCheck = { _ in false }
check(Theme.roman(0) == "0" && Theme.roman(3999) == "MMMCMXCIX" && Theme.roman(1994) == "MCMXCIV", "roman numerals")

// Chrome text is drawn flat unless every stop reads on every background it is drawn over.
write(user, "chromeok", "[color]\nwindow.bg = \"#040405\"\nsidebar.bg = \"#060607\"\npalette.bg = \"#050506\"\n[app]\npalette.pill.ink = \"#050506\"\ntext.chrome = [\"#ffffff\", \"#5b5b62\", \"#e8e8ec\"]\n")
write(user, "chromedim", "[color]\nwindow.bg = \"#040405\"\n[app]\ntext.chrome = [\"#ffffff\", \"#3a3a40\"]\n")
write(user, "chromebad", "[app]\ntext.chrome = [\"#ffffff\", \"nope\"]\n")
check(load("chromeok").theme.chromeStops.count == 3, "readable stops are kept: \(load("chromeok").problems)")
check(load("chromedim").theme.app.textChrome.isEmpty && load("chromedim").problems.contains { $0.contains("app.text.chrome") }, "a dim stop drops the gradient")
check(load("chromebad").theme.app.textChrome.isEmpty, "so does a stop that isn't a colour")
// Between two stops that each read on the window, a mid-grey that doesn't.
write(user, "chromemid", "[color]\nwindow.bg = \"#777777\"\nsidebar.bg = \"#777777\"\npalette.bg = \"#777777\"\n[app]\npalette.pill.ink = \"#777777\"\ntext.chrome = [\"#000000\", \"#ffffff\"]\n")
check(load("chromemid").theme.app.textChrome.isEmpty, "a blend between stops must read too")
check(LoadedTheme.chromeSamples([NSColor.black, NSColor.white]).count == 17, "sixteen samples a segment")

// A selected row's text reads on its fill.
write(user, "selfill", "[color]\nwindow.bg = \"#000000\"\nsidebar.bg = \"#000000\"\nrow.selected = \"#555555\"\ntext.primary = \"#999999\"\n")
check(load("selfill").theme.color.textPrimary.hex == "#ffffff" && load("selfill").problems.contains { $0.contains("color.text.primary") },
      "grey that reads on the sidebar but not on its selection is fixed: \(load("selfill").problems)")

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
// Layers: core checks the tables (cargo test); here, what the app does with them.
do {
    // Black and white has none, so nothing is drawn and nothing recorded.
    check(load(nil).layers.isEmpty && load(nil).layerSource == LayerSource(), "bw has no layers")
    Layers.set([], source: LayerSource())
    var recorded: [(String, CGRect)] = []
    Layers.recorder = { recorded.append(($0, $1)) }
    let probe = canvas(); for slot in Layers.slots { Layers.draw(slot, CGRect(x: 0, y: 0, width: 40, height: 40), in: probe.ctx) }
    check(recorded.isEmpty && probe.painted() == 0, "with no layers no slot draws")

    // The chain goes to core ancestors first, with the PNGs each file names from its own folder.
    var seen: [(name: String, toml: String, files: [(String, Data)])] = []
    LoadedTheme.layerParser = { chain in
        seen = chain
        let fill = LayerSpec(id: "a", slot: "sidebar", prims: [PrimSpec(kind: "rect", fill: "@row.selected")])
        let bad = LayerSpec(slot: "sidebar", prims: [PrimSpec(kind: "rect", fill: "@no.such.token")])
        return (LayerSource(specs: [fill, bad], images: []), ["from core"])
    }
    write(user, "lp", "extends = \"lc\"\n[[layer]]\nslot = \"sidebar\"\n  [[layer.draw]]\n  kind = \"image\"\n  file = \"mark.png\"\n")
    write(user, "lc", "[color]\nrow.selected = \"#0a0a0a\"\n")
    try! Data([1, 2, 3]).write(to: user.appendingPathComponent("mark.png"))
    try! Data([9]).write(to: user.appendingPathComponent("other.png"))
    let lp = load("lp")
    check(seen.map(\.name) == ["lc.toml", "lp.toml"], "ancestors first: \(seen.map(\.name))"); guard seen.count == 2 else { fatalError("no chain") }
    check(seen[1].files.map(\.0) == ["mark.png"] && seen[1].files[0].1 == Data([1, 2, 3]) && seen[0].files.isEmpty, "only named PNGs are read")
    check(lp.layers.count == 1 && lp.layers[0].prims[0].fill?.themeHex == "#0a0a0aff", "@tokens resolve against the finished theme")
    check(lp.problems.contains("from core") && lp.problems.contains { $0.contains("no.such.token") }, "problems: \(lp.problems)")
    seen = []
    let swatch = LoadedTheme.load("lp", userDir: home, bundled: bundled, layers: false)
    check(seen.isEmpty && swatch.layers.isEmpty, "a swatch neither parses layers nor reads PNGs")
    LoadedTheme.layerParser = nil

    // A theme's PNGs are read only as regular files: not through a link, never blocking on a FIFO.
    try! FileManager.default.createSymbolicLink(at: user.appendingPathComponent("link.png"), withDestinationURL: user.appendingPathComponent("mark.png"))
    mkfifo(user.appendingPathComponent("pipe.png").path, 0o600)
    write(user, "lf", "[[layer]]\nslot = \"sidebar\"\n  [[layer.draw]]\n  kind = \"image\"\n  file = \"link.png\"\n  # \"pipe.png\" \"mark.png\"\n")
    check(LoadedTheme.layerFiles(user.appendingPathComponent("lf.toml")).map(\.0) == ["mark.png"], "links and FIFOs are skipped")

    // The text must read on what the layers actually paint under it, whatever they are; edges away from the
    // text may be any colour.
    let white = Theme()
    func resolved(_ slot: String, _ p: PrimSpec) -> ([ResolvedLayer], [String]) {
        Layers.resolve([LayerSpec(slot: slot, prims: [p])], images: [], theme: white)
    }
    let primary = white.color.textPrimary.themeHex
    func drawn(_ slot: String, _ prims: [PrimSpec], text: [CGRect]?, ink: NSColor = white.color.textPrimary, on: NSColor? = nil,
               layers: Int = 1, bounds: CGRect = CGRect(x: 10, y: 10, width: 80, height: 40)) -> Int {
        let specs = (0..<layers).map { LayerSpec(id: "probe\($0)", slot: slot, prims: prims) }
        let (l, _) = Layers.resolve(specs, images: [], theme: white)
        Layers.set(l, source: LayerSource())
        let c = canvas()
        Layers.draw(slot, bounds, textRun: bounds, text: text?.map { Layers.Run(rect: $0, ink: ink, on: on) }, in: c.ctx)
        return c.painted()
    }
    let inner = [CGRect(x: 20, y: 20, width: 60, height: 20)]
    check(drawn("row.selected", [PrimSpec(kind: "rect", fill: primary)], text: inner) == 0
          && Layers.skipped.contains { $0.contains("row.selected") && $0.contains("text in \(primary)") },
          "a fill in the text's own colour is skipped over the text, and logged with why")
    // The text is held to the colour it's drawn in, not the slot's usual ink: a caption title in white.
    check(drawn("titlebar", [PrimSpec(kind: "rect", fill: "#ffffff")], text: inner, ink: .white) == 0, "white text can't go on a white layer")
    check(drawn("titlebar", [PrimSpec(kind: "rect", fill: "#ffffff")], text: inner, ink: .black) > 0, "black text can")
    check(drawn("titlebar", [PrimSpec(kind: "rect", fill: "#ffffff")], text: [], ink: .black) > 0, "and a bar with no text may be any colour")
    check(drawn("row.selected", [PrimSpec(kind: "rect", stroke: primary)], text: [CGRect(x: 5, y: 30, width: 40, height: 10)]) == 0,
          "a 1 pt stroke across the text too")
    check(drawn("row.selected", [PrimSpec(kind: "rect", stroke: primary, width: 0.5)], text: [CGRect(x: 30, y: 25, width: 40, height: 10)]) > 0,
          "but an edge clear of the text is drawn")
    check(drawn("row.selected", [PrimSpec(kind: "rect", y: SpanSpec(mode: "top", b: 1), fill: "#ffffff33")], text: inner) > 0,
          "so is a top highlight above it")
    check(drawn("row.selected", [PrimSpec(kind: "gradient", stops: [.init(color: "#00000000", at: 0), .init(color: primary, at: 1)])], text: [CGRect(x: 10, y: 10, width: 80, height: 40)]) == 0,
          "a gradient is held to it where it reaches the ink")
    check(drawn("row.selected", [PrimSpec(kind: "shadow", radius: 4, blur: 12, color: primary)], text: [CGRect(x: 30, y: 25, width: 40, height: 10)]) > 0,
          "a shadow paints only outside its shape")
    check(drawn("row.selected", [PrimSpec(kind: "shadow", x: SpanSpec(mode: "left", b: 4), radius: 2, blur: 2, offset: [20, 0], color: primary)], text: inner) == 0,
          "and is held to the text it reaches")
    check(drawn("row.selected", [PrimSpec(kind: "bevel", rings: [[primary, primary, primary, primary]])], text: [CGRect(x: 10, y: 10, width: 80, height: 40)]) == 0,
          "bevel edges too")
    let rings = (0..<8).map { i in PrimSpec(kind: "rect", x: SpanSpec(a: Double(i), b: Double(i)), y: SpanSpec(a: Double(i) / 2, b: Double(i) / 2),
                                            stroke: "@needs", width: 2) }
    check(drawn("status.needs", rings, text: nil) == 0, "stacked thin strokes can't hide a needs-you status")
    check(drawn("window.bg", [PrimSpec(kind: "rect", fill: primary)], text: nil) > 0, "a slot without text may use any colour")
    let glassLike = [PrimSpec(kind: "shadow", radius: 9, blur: 12, offset: [0, 4], color: "#00000007"),
                     PrimSpec(kind: "rect", x: SpanSpec(a: 6, b: 6), y: SpanSpec(mode: "top", b: 1), fill: "#ffffff33"),
                     PrimSpec(kind: "rect", radius: 9, stroke: "#ffffff38", width: 0.5)]
    _ = drawn("row.selected", glassLike, text: inner)
    check(Layers.skipped.isEmpty, "Glass's raised row draws: \(Layers.skipped)")
    // The review's probes. Faint fills that each pass alone, stacked 64 deep.
    check(drawn("row.selected", [PrimSpec(kind: "rect", fill: String(primary.prefix(7)) + "10")], text: inner, layers: 64) == 0, "64 faint fills stacked are judged together")
    check(drawn("row.selected", [PrimSpec(kind: "rect", fill: String(primary.prefix(7)) + "10")], text: inner) > 0, "while one alone is fine")
    // A square traced twice: nonzero fills it, whatever an even-odd reading says.
    let twice: [PrimSpec.Cmd] = (0..<2).flatMap { _ in [.init(op: "M", pts: [0, 0]), .init(op: "L", pts: [10, 0]), .init(op: "L", pts: [10, 10]),
                                                         .init(op: "L", pts: [0, 10]), .init(op: "Z", pts: [])] }
    check(drawn("row.selected", [PrimSpec(kind: "path", fill: primary, path: twice, view: [10, 10])], text: inner) == 0, "a path traced twice still covers the text")
    // A pill: its text is pill.fg on pill.bg over whatever the layer leaves.
    let pillFg = white.app.pillFg, pillBg = white.app.pillBg
    check(drawn("status.needs", [PrimSpec(kind: "rect", fill: pillFg.themeHex)], text: inner, ink: pillFg, on: pillBg) == 0, "a layer in the pill's ink hides the pill's word")
    check(drawn("status.needs", [PrimSpec(kind: "rect", fill: "#000000")], text: inner, ink: pillFg, on: pillBg) > 0, "a dark one doesn't")
    // Review 2: a slot's text is judged over the layers of the slots drawn under it too, as they stack.
    let veil = PrimSpec(kind: "rect", fill: "#ffffff8a"), needs = white.color.needs
    func stacked(_ under: String, _ over: String, ink: NSColor, veil: PrimSpec = veil) -> (under: Bool, over: Bool) {
        let (l, _) = Layers.resolve([LayerSpec(id: "u", slot: under, prims: [veil]), LayerSpec(id: "o", slot: over, prims: [veil])], images: [], theme: white)
        Layers.set(l, source: LayerSource())
        let c = canvas(), box = CGRect(x: 10, y: 10, width: 80, height: 40), run = [Layers.Run(rect: inner[0], ink: ink)]
        Layers.draw(under, box, text: run, in: c.ctx)
        Layers.draw(over, box, text: run, state: ["selected"], in: c.ctx)
        Layers.endFrame()
        return (!Layers.skipped.contains { $0.hasPrefix("layers on \(under) ") }, !Layers.skipped.contains { $0.hasPrefix("layers on \(over) ") })
    }
    check(drawn("row", [veil], text: inner, ink: needs) > 0 && drawn("status.needs", [veil], text: inner, ink: needs) > 0, "one veil alone is fine")
    check(stacked("row", "status.needs", ink: needs) == (true, false), "a veil on the row and one on the needs word are judged together")
    let faint = PrimSpec(kind: "rect", fill: "#ffffff60")
    check(drawn("row.selected", [faint], text: inner) > 0, "a fainter veil alone is fine on a row")
    check(stacked("row", "row.selected", ink: white.color.textPrimary, veil: faint) == (true, false), "and a row's veil under a selected row's")
    // At the screen's scale: half-point rules every point read as a grey at 1x, as solid lines on a Retina screen.
    var rules: [PrimSpec.Cmd] = []
    for y in 0..<40 {
        let top = Double(y), bottom = Double(y) + 0.5
        rules += [PrimSpec.Cmd(op: "M", pts: [0, top]), PrimSpec.Cmd(op: "L", pts: [80, top]), PrimSpec.Cmd(op: "L", pts: [80, bottom]),
                  PrimSpec.Cmd(op: "L", pts: [0, bottom]), PrimSpec.Cmd(op: "Z", pts: [])]
    }
    check(drawn("status.needs", [PrimSpec(kind: "path", fill: "#ffffffc0", path: rules, view: [80, 40])], text: inner, ink: .white) == 0,
          "half-point rules across the needs word are judged at 2x")
    // Fails closed: text it can't measure is not called readable.
    check(drawn("row.selected", [PrimSpec(kind: "rect", fill: "#000000")], text: [CGRect(x: 20, y: 20.1, width: 60, height: 0.3)]) == 0
          && Layers.skipped.contains { $0.contains("too small to check") }, "a run with no whole pixel skips the layers")

    // Clipped to the slot (bleed included), never into the excluded terminal, and states pick layers.
    func layer(_ slot: String, _ p: PrimSpec, when: [String] = [], opacity: Double = 1) -> ResolvedLayer {
        Layers.resolve([LayerSpec(slot: slot, when: when, opacity: opacity, prims: [p])], images: [], theme: white).0[0]
    }
    let everywhere = PrimSpec(kind: "rect", x: SpanSpec(a: -400, b: -400), y: SpanSpec(a: -400, b: -400), fill: "#000000")
    Layers.set([layer("window.bg", everywhere), layer("row.selected", everywhere), layer("sidebar", everywhere, when: ["focused"])], source: LayerSource())
    var c = canvas()
    Layers.draw("window.bg", CGRect(x: 0, y: 0, width: 100, height: 100), exclude: CGRect(x: 50, y: 0, width: 50, height: 100), in: c.ctx)
    check(c.alpha(x: 10, y: 10) == 255 && c.alpha(x: 60, y: 10) == 0 && c.alpha(x: 99, y: 99) == 0, "window.bg skips the terminal")
    c = canvas()
    Layers.draw("row.selected", CGRect(x: 20, y: 20, width: 40, height: 20), within: CGRect(x: 0, y: 0, width: 64, height: 100), in: c.ctx)
    check(c.alpha(x: 30, y: 30) == 255 && c.alpha(x: 30, y: 19) == 0 && c.alpha(x: 30, y: 41) == 0, "a row's layer stays in its box, over no label")
    check(c.alpha(x: 59, y: 30) == 255 && c.alpha(x: 61, y: 30) == 0, "on every side")
    c = canvas()
    Layers.draw("sidebar", CGRect(x: 0, y: 0, width: 40, height: 40), state: ["inactive"], in: c.ctx)
    check(c.painted() == 0, "a focused-only layer stays off in an inactive window")
    Layers.draw("sidebar", CGRect(x: 0, y: 0, width: 40, height: 40), state: ["focused"], in: c.ctx)
    check(c.alpha(x: 5, y: 5) == 255 && c.alpha(x: 45, y: 5) == 0, "and draws, clipped, in a focused one")

    // Bitmaps under text, and the backdrop behind the terminal, are kept faint; the backdrop only shows through.
    let dots = PrimSpec(kind: "pattern", cell: [1, 1], dots: [.init(color: "#000000", x: 0, y: 0)])
    Layers.set([layer("sidebar", dots), layer("pane.backdrop", everywhere), layer("bar.track", dots)], source: LayerSource())
    c = canvas()
    Layers.draw("sidebar", CGRect(x: 0, y: 0, width: 40, height: 40), in: c.ctx)
    check((1...32).contains(c.alpha(x: 5, y: 5)), "a pattern under text is at most 12% opaque: \(c.alpha(x: 5, y: 5))")
    c = canvas()
    Layers.draw("bar.track", CGRect(x: 0, y: 0, width: 40, height: 40), in: c.ctx)
    check(c.alpha(x: 5, y: 5) == 255, "but not where there's no text")
    recorded = []
    c = canvas()
    Layers.terminalSeeThrough = false
    Layers.draw("pane.backdrop", CGRect(x: 0, y: 0, width: 40, height: 40), in: c.ctx)
    check(c.painted() == 0 && recorded.isEmpty, "the backdrop is never drawn behind an opaque terminal")
    Layers.terminalSeeThrough = true
    Layers.draw("pane.backdrop", CGRect(x: 0, y: 0, width: 40, height: 40), in: c.ctx)
    check((1...32).contains(c.alpha(x: 5, y: 5)) && c.alpha(x: 45, y: 5) == 0, "behind a see-through one, at most 12%: \(c.alpha(x: 5, y: 5))")
    // However many shapes stack, a faint slot stays faint as a whole.
    Layers.set([LayerSpec(slot: "pane.backdrop", prims: Array(repeating: everywhere, count: 16)),
                LayerSpec(slot: "pane.backdrop", prims: Array(repeating: everywhere, count: 16)),
                LayerSpec(slot: "sidebar", prims: Array(repeating: dots, count: 16))].flatMap { Layers.resolve([$0], images: [], theme: white).0 },
               source: LayerSource())
    c = canvas()
    Layers.draw("pane.backdrop", CGRect(x: 0, y: 0, width: 100, height: 100), in: c.ctx)
    check(c.maxAlpha() <= 31, "32 stacked backdrop fills stay at most 12%: \(c.maxAlpha())")
    c = canvas()
    Layers.draw("sidebar", CGRect(x: 0, y: 0, width: 100, height: 100), in: c.ctx)
    check((1...31).contains(c.maxAlpha()), "16 stacked patterns under text too: \(c.maxAlpha())")
    Layers.terminalSeeThrough = false

    // Geometry: anchors, text anchors, and corners turning inward.
    let slot = CGRect(x: 10, y: 20, width: 100, height: 40), run = CGRect(x: 30, y: 25, width: 20, height: 10)
    check(Layers.frame(PrimSpec(kind: "rect", x: SpanSpec(mode: "right", a: -2, b: 6), y: SpanSpec(mode: "center", b: 4)), in: slot, textRun: run)
          == CGRect(x: 102, y: 38, width: 6, height: 4), "anchored frame")
    check(Layers.frame(PrimSpec(kind: "line", x: SpanSpec(a: 4, b: 0, fromText: true)), in: slot, textRun: run) == CGRect(x: 54, y: 20, width: 56, height: 40),
          "from the text's end to the edge")
    let mark = PrimSpec(kind: "rect", x: SpanSpec(mode: "left", b: 4), y: SpanSpec(mode: "top", b: 4), fill: "#ffffff")
    var corner = mark
    corner.repeatMode = "corners"
    Layers.set([layer("window.bg", PrimSpec(kind: "path", fill: "#ffffff", repeatMode: "corners", path: [.init(op: "M", pts: [0, 0]), .init(op: "L", pts: [4, 0]),
                                            .init(op: "L", pts: [0, 4]), .init(op: "Z", pts: [])], view: [4, 4]).withFrame(of: mark))], source: LayerSource())
    c = canvas()
    Layers.draw("window.bg", CGRect(x: 0, y: 0, width: 64, height: 64), in: c.ctx)
    check(c.alpha(x: 0, y: 0) == 255 && c.alpha(x: 63, y: 0) == 255 && c.alpha(x: 63, y: 63) == 255 && c.alpha(x: 0, y: 63) == 255,
          "a corner mark in each corner")
    check(c.alpha(x: 3, y: 3) == 0 && c.alpha(x: 60, y: 3) == 0 && c.alpha(x: 32, y: 32) == 0, "pointing into each corner, nowhere else")
    Layers.set([], source: LayerSource())
    Layers.recorder = nil

    // The costliest theme core lets through: 256 shapes, each slot's 4 shadows and 4 gradients, the rest
    // 256-command paths at the widest stroke.
    let zigzag = (0..<255).map { i in PrimSpec.Cmd(op: i == 0 ? "M" : "L", pts: [Double(i % 2) * 400, Double(i) * 1.5]) } + [.init(op: "Z", pts: [])]
    var worst: [LayerSpec] = []
    for slot in Layers.slots {
        worst.append(LayerSpec(slot: slot, prims: Array(repeating: PrimSpec(kind: "shadow", radius: 8, blur: 12, offset: [6, 6], color: "#00000040"), count: 4)
                               + Array(repeating: PrimSpec(kind: "gradient", angle: 45, stops: [.init(color: "#ffffff10", at: 0), .init(color: "#00000010", at: 1)]), count: 4)))
    }
    let paths = 256 - worst.count * 8
    for k in 0..<paths { worst.append(LayerSpec(slot: Layers.slots[k % Layers.slots.count], prims: [PrimSpec(kind: "path", stroke: "#ffffff08", width: 8, path: zigzag, view: [400, 400])])) }
    let worstSource = LayerSource(specs: worst)
    Layers.set(Layers.resolve(worst, images: [], theme: white).0, source: worstSource)
    Layers.terminalSeeThrough = true
    // A window's own backing format.
    let big = CGContext(data: nil, width: 2200, height: 1400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    big.scaleBy(x: 2, y: 2)
    let window = CGRect(x: 0, y: 0, width: 1100, height: 700), pane = CGRect(x: 262, y: 44, width: 838, height: 656)
    func drawWindow() {
    Layers.draw("window.bg", window, exclude: pane, in: big)
    Layers.draw("pane.backdrop", pane, within: pane, in: big)
    Layers.draw("pane.frame", pane.insetBy(dx: -4, dy: -4), exclude: pane, in: big)
    Layers.draw("titlebar", CGRect(x: 0, y: 0, width: 1100, height: 44), in: big)
    for i in 0..<3 { Layers.draw("lights", CGRect(x: 20 + 20 * i, y: 16, width: 12, height: 12), index: i, in: big) }
    Layers.draw("sidebar", CGRect(x: 0, y: 44, width: 262, height: 656), in: big)
    Layers.draw("sidebar.footer", CGRect(x: 0, y: 650, width: 262, height: 50), in: big)
    for g in 0..<3 { Layers.draw("label.group", CGRect(x: 0, y: 50 + 200 * g, width: 261, height: 40), in: big) }
    for r in 0..<12 {
        let box = CGRect(x: 8, y: 90 + 46 * r, width: 245, height: 44)
        for slot in ["row", r == 0 ? "row.selected" : "row.hover", "status.needs"] { Layers.draw(slot, box, in: big) }
        Layers.draw("icon", CGRect(x: 16, y: box.minY + 8, width: 18, height: 18), in: big)
        Layers.draw("bar.track", CGRect(x: 40, y: box.maxY - 6, width: 200, height: 2), in: big)
        Layers.draw("bar.fill", CGRect(x: 40, y: box.maxY - 6, width: 120, height: 2), in: big)
    }
    Layers.draw("palette", CGRect(x: 700, y: 300, width: 380, height: 380), in: big)
    Layers.draw("palette.field", CGRect(x: 700, y: 300, width: 380, height: 40), in: big)
    for r in 0..<8 { Layers.draw(r == 0 ? "palette.row.selected" : "palette.row.hover", CGRect(x: 704, y: 344 + 40 * r, width: 372, height: 36), in: big) }
    }
    // Slow means over 60 ms: two 50 ms redraws, a cold check of a busy theme, leave layers on; two over 60 turn them off.
    let paced = [LayerSpec(id: "watchdog", slot: "sidebar", prims: [PrimSpec(kind: "rect", fill: "#000000")])]
    Layers.set(Layers.resolve(paced, images: [], theme: white).0, source: LayerSource(specs: paced))
    Layers.judge(50); Layers.judge(50)
    check(!Layers.current.isEmpty, "two 50 ms redraws leave layers on")
    Layers.judge(61); Layers.judge(61)
    check(Layers.current.isEmpty, "two over 60 ms turn them off")
    Layers.set(Layers.resolve(worst, images: [], theme: white).0, source: worstSource)
    // A live resize never turns layers off, though its redraws are still timed.
    Layers.liveResize = { true }
    for _ in 0..<2 { drawWindow(); Layers.endFrame() }
    check(!Layers.current.isEmpty && Layers.lastFrameMs > Layers.slowMs, "slow redraws in a live resize leave layers on: \(Int(Layers.lastFrameMs)) ms")
    Layers.liveResize = { false }
    // Too slow to draw: the theme's layers are turned off for the session, said once, and the next redraw is fast.
    var said: [String] = []
    Layers.report = { said.append($0) }
    var started = Date()
    drawWindow()
    let first = Date().timeIntervalSince(started) * 1000
    Layers.endFrame()
    if first <= Layers.stopMs {
        drawWindow()
        Layers.endFrame()
    }
    started = Date()
    drawWindow()
    let ms = Date().timeIntervalSince(started) * 1000
    check(Layers.current.isEmpty && said.contains { $0.hasPrefix("layers off: too slow to draw") }, "the costliest theme is turned off: \(said)")
    check(ms < 5, "and the next redraw takes \(Int(ms)) ms")
    Layers.set(Layers.resolve(worst, images: [], theme: white).0, source: worstSource)
    check(Layers.current.isEmpty, "it stays off for the session")
    print("worst-case window: \(Int(first)) ms, then \(String(format: "%.1f", ms)) ms with layers off")
    // Layers the check refuses still cost their check, and that time counts: 256-segment paths in the text's colour.
    let refused = Layers.slots.filter { Layers.text[$0] != nil }.map { LayerSpec(slot: $0, prims: Array(repeating: PrimSpec(kind: "path", fill: primary, path: zigzag, view: [400, 400]), count: 16)) }
    Layers.set(Layers.resolve(refused, images: [], theme: white).0, source: LayerSource(specs: refused))
    drawWindow()
    Layers.endFrame()
    check(Layers.lastFrameMs > 0 && said.contains { $0.contains("skipped") }, "a refused layer's check is timed: \(Layers.lastFrameMs) ms")
    Layers.report = { _ in }
    Layers.set([], source: LayerSource())
    Layers.terminalSeeThrough = false

    // Under text by construction: in every function that draws slots, every slot's layers come before any text,
    // and layers are clipped to their slot, so none reaches text drawn earlier in another.
    var sites = 0
    for file in ["SidebarView", "TitleBarView", "Palette", "MainWindow"] {
        let src = try! String(contentsOfFile: "macos/Sources/\(file).swift", encoding: .utf8)
        for body in src.components(separatedBy: "func ").dropFirst() where body.contains("Layers.draw(") {
            sites += 1
            let lastLayer = body.range(of: "Layers.draw(", options: .backwards)!.lowerBound
            let text = ["Draw.text(", "Draw.chromeText(", "CTLineDraw("].compactMap { body.range(of: $0)?.lowerBound }.min()
            check(text.map { $0 > lastLayer } ?? true, "\(file): text drawn before a layer in func \(body.prefix(40))")
        }
    }
    check(sites >= 8, "found the drawing sites: \(sites)")
    let slotsDrawn = ["SidebarView", "TitleBarView", "Palette", "MainWindow"].map { try! String(contentsOfFile: "macos/Sources/\($0).swift", encoding: .utf8) }.joined()
    let missing = Layers.slots.filter { !slotsDrawn.contains("\"\($0)\"") }
    check(missing.isEmpty, "every slot has a site: \(missing)")
}

print(failures == 0 ? "theme: all passed" : "theme: \(failures) failed")
exit(failures == 0 ? 0 : 1)
