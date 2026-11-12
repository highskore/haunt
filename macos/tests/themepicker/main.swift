import AppKit

final class Host: PaletteHost {
    var paletteTabs: [Row] = []
    var selectedSurfaceId: String?
    var palettePlugins: PluginsAPI?
    var pluginLoadErrors: [String] = []
    func paletteSelectTab(_ surfaceId: String) {}
    func paletteInvoke(pluginId: String, itemId: String) {}
    func drainPluginRequests() {}
    var paletteKeys = KeyMap(table: [:], order: [], pluginDefaults: [:]) { _ in }
    var isSidebarHidden = false
    var isFullScreen = false
    func paletteRun(_ action: KeyMap.Action) {}
    func paletteDidClose() {}
    var paletteThemes = [("bw", "Black and white"), ("aero", "Frutiger Aero"), ("glass", "Glass")].map { HauntConfig.ThemeChoice(id: $0.0, name: $0.1) }
    var paletteTheme = "bw"
    var log: [String] = []
    func palettePreviewTheme(_ id: String?) { log.append(id.map { "preview \($0)" } ?? "revert") }
    func paletteChooseTheme(_ id: String) { log.append("keep \(id)") }
}

var failures = 0
func check(_ name: String, _ got: [String], _ want: [String]) {
    if got != want {
        failures += 1
        print("FAIL \(name): got \(got), want \(want)")
    }
}

func run(saved: String = "bw", _ keys: [PaletteView.Key]) -> [String] {
    let host = Host()
    host.paletteTheme = saved
    let p = PaletteController(host: host)
    p.edit(.text("theme "))
    for k in keys { p.edit(k) }
    return host.log
}

check("entering previews nothing", run([]), [])
check("arrowing previews, esc reverts", run([.down, .down, .escape]), ["preview aero", "preview glass", "revert"])
check("past the end stays put", run([.down, .down, .down, .escape]), ["preview aero", "preview glass", "revert"])
check("enter keeps it", run([.down, .enter]), ["preview aero", "keep aero"])
check("enter on the saved one keeps it", run([.enter]), ["keep bw"])
check("typing filters and previews", run([.text("gl"), .escape]), ["preview glass", "revert"])
check("backing out of the mode reverts", run([.down, .backspace]), ["preview aero", "revert"])
check("back on the saved one previews it", run([.down, .up, .escape]), ["preview aero", "preview bw", "revert"])
check("starts on the saved theme", run(saved: "aero", [.up, .escape]), ["preview bw", "revert"])
check("esc with nothing previewed reverts nothing", run([.escape]), [])
do {
    let host = Host()
    host.paletteTheme = "glass"
    let p = PaletteController(host: host)
    for k: PaletteView.Key in [.text("pick"), .enter, .up, .escape] { p.edit(k) }
    check("the Pick theme… row enters the mode on the saved theme", host.log, ["preview aero", "revert"])
}

final class Themes: ThemesHost {
    var themeChoices = Host().paletteThemes
    var savedTheme = "bw"
    var log: [String] = []
    func loadTheme(_ id: String) -> Theme { Theme() }
    func previewTheme(_ id: String?) { log.append(id.map { "preview \($0)" } ?? "revert") }
    func chooseTheme(_ id: String) { log.append("keep \(id)") }
}

func window(saved: String = "bw", _ steps: (ThemesWindowController, ThemeGridView) -> Void) -> [String] {
    let host = Themes()
    host.savedTheme = saved
    let w = ThemesWindowController(host: host)
    w.load()
    let grid = w.window!.contentView!.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? ThemeGridView }.first!
    steps(w, grid)
    w.close()
    return host.log
}

check("window: opening previews nothing", window { _, _ in }, [])
check("window: a click previews, closing reverts", window { _, g in g.select(2) }, ["preview glass", "revert"])
check("window: use keeps it", window { w, g in g.select(1); w.keep() }, ["preview aero", "keep aero"])
check("window: back on the saved one", window(saved: "aero") { _, g in g.select(0); g.select(1) },
      ["preview bw", "preview aero", "revert"])
check("window: keeping the saved one", window(saved: "glass") { w, _ in w.keep() }, ["keep glass"])

if failures > 0 { exit(1) }
print("palette: all passed")
