import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

let text = "Doneness of the build"
let whole = TitleBarView.pluginLine(text, room: 1000).map(Draw.width) ?? 0
check(whole > 0, "a line with room is drawn")
check(TitleBarView.pluginLine(text, room: whole) != nil, "exactly its width is room enough")
check(TitleBarView.pluginLine(text, room: whole - 1) == nil, "a narrow window draws nothing, never \"Done…\"")
check(TitleBarView.pluginLine("", room: 1000) == nil, "nothing to draw")

// Diamond lights are filled with the window's colour, so the bar's layers never show inside them, and the bar's
// layers are held to the ornament ink over the lights.
do {
    Theme.current.effects.lightsShape = "diamond"
    let bar = TitleBarView(frame: NSRect(x: 0, y: 0, width: 600, height: Tok.Size.titlebarH))
    func shown(_ fill: String) -> NSBitmapImageRep {
        let specs = [LayerSpec(id: "bar", slot: "titlebar", prims: [PrimSpec(kind: "rect", fill: fill)])]
        Layers.set(Layers.resolve(specs, images: [], theme: Theme.current).0, source: LayerSource(specs: specs))
        let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
        bar.cacheDisplay(in: bar.bounds, to: rep)
        Layers.endFrame()
        return rep
    }
    func same(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02
    }
    let rep = shown("#2a1030"), scale = rep.pixelsWide / 600
    let x = Int((Tok.Size.titlebarPadx + Tok.Size.lightsD / 2) * CGFloat(scale))
    check((0..<rep.pixelsHigh).contains { same(rep.colorAt(x: x, y: $0), Tok.Color.windowBg) }, "a diamond light is filled with the window's colour")
    // A see-through window colour still fills the diamond solid.
    Theme.current.color.windowBg = Tok.Color.windowBg.withAlphaComponent(0.5)
    let clear = shown("#2a1030")
    check((0..<clear.pixelsHigh).contains { same(clear.colorAt(x: x, y: $0), Tok.Color.windowBg.withAlphaComponent(1)) },
          "a see-through window colour fills the diamond opaque")
    Theme.current.color.windowBg = Tok.Color.windowBg.withAlphaComponent(1)
    _ = shown(Tok.App.ornament.themeHex)
    check(Layers.skipped.contains { $0.hasPrefix("layers on titlebar ") }, "a bar layer in the ornament's colour is skipped: \(Layers.skipped)")
    Layers.set([], source: LayerSource())
    Theme.current = Theme()
}

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("titlebar: ok")
