#if HAUNT_FIXTURES
import AppKit

/// HAUNT_CHECK_THEME=<id>=<theme.toml>: loads a theme as a plugin theme, draws every layer slot at a window's
/// sizes with its text where Haunt puts it, and prints each layer problem; exits 1 if there was one. No window.
enum ThemeCheck {
    static func run(_ arg: String) -> Int32 {
        guard let eq = arg.firstIndex(of: "=") else { return 2 }
        let id = String(arg[..<eq]), file = URL(fileURLWithPath: String(arg[arg.index(after: eq)...]))
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("haunt-theme-check-\(getpid())")
        let loaded = LoadedTheme.load(id, userDir: empty, plugins: [id: PluginTheme(file: file, fonts: [])], bundled: nil)
        var problems = loaded.problems.filter { $0.contains("layer") }
        Theme.current = loaded.theme
        Layers.report = { problems.append($0) }
        Layers.set(loaded.layers, source: loaded.layerSource)
        Layers.terminalSeeThrough = true
        let ctx = CGContext(data: nil, width: 2200, height: 1400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: 1400)
        ctx.scaleBy(x: 2, y: -2)
        // Each state is one redraw, so a theme too slow to draw is turned off here as in the app.
        for state in states {
            drawWindow(ctx, state: state)
            Layers.endFrame()
        }
        for p in problems { print("\(id): \(p)") }
        print("\(id): \(loaded.layers.count) layers, \(problems.count) problems")
        return problems.isEmpty ? 0 : 1
    }

    /// Every slot in every state, at the sizes and with the text the views give it.
    private static let states: [Set<String>] = [["focused"], ["inactive"], ["focused", "hover"], ["focused", "selected"], ["focused", "pressed"]]

    private static func drawWindow(_ ctx: CGContext, state: Set<String>) {
        let w = Tok.Size.sidebarW, top = Tok.Size.titlebarH
        let window = CGRect(x: 0, y: 0, width: 1100, height: 700), pane = CGRect(x: w, y: top, width: 1100 - w, height: 700 - top)
        func runs(_ r: CGRect, _ inks: NSColor...) -> [Layers.Run] { inks.map { Layers.Run(rect: r, ink: $0) } }
        do {
            Layers.draw("window.bg", window, exclude: pane, state: state, in: ctx)
            Layers.draw("pane.backdrop", pane, within: pane, state: state, in: ctx)
            Layers.draw("pane.frame", pane.insetBy(dx: -4, dy: -4), exclude: pane, state: state, in: ctx)
            let bar = CGRect(x: 0, y: 0, width: 1100, height: top)
            Layers.draw("titlebar", bar, text: Theme.current.effects.titlebarStyle == "caption"
                            ? runs(CGRect(x: 24, y: 0, width: 300, height: Tok.Size.titlebarH), Theme.current.app.rowSelectInk)
                            : runs(CGRect(x: 400, y: 0, width: 300, height: top), Tok.App.titleFg, Tok.App.titleMeta), state: state, in: ctx)
            for i in 0..<3 {
                let d = Tok.Size.lightsD
                Layers.draw("lights", CGRect(x: Tok.Size.titlebarPadx + CGFloat(i) * (d + Tok.Size.lightsGap), y: (top - d) / 2, width: d, height: d),
                            within: bar, state: state, index: i, in: ctx)
            }
            let side = CGRect(x: 0, y: top, width: w, height: 700 - top), cw = w - 1
            Layers.draw("sidebar", side, state: state, in: ctx)
            Layers.draw("sidebar.footer", CGRect(x: 0, y: 640, width: cw, height: 60), textRun: CGRect(x: 14, y: 672, width: 80, height: 14),
                        text: runs(CGRect(x: 14, y: 672, width: 80, height: 14), Tok.App.sidebarFootFg), state: state, in: ctx)
            let lp = Tok.Size.labelPad, lineH = Tok.Size.labelFont * Tok.Font.baseLine
            let label = CGRect(x: lp[1], y: top + 4 + lp[0], width: 70, height: lineH)
            Layers.draw("label.group", CGRect(x: 0, y: top + 4, width: cw, height: lp[0] + lineH + lp[2]),
                        textRun: label, text: runs(label, Tok.Color.textLabel), state: state, in: ctx)
            let pad = Tok.Size.rowPad, inset = Theme.current.effects.rowInset
            for r in 0..<3 {
                let y = top + 60 + CGFloat(r) * 52, box = CGRect(x: inset, y: y, width: cw - 2 * inset, height: 48)
                let line1 = CGRect(x: inset + pad[1], y: y + pad[0], width: cw - 2 * (inset + pad[1]), height: 20)
                let rest = CGRect(x: line1.minX, y: line1.maxY, width: line1.width, height: 48 - 2 * pad[0] - 20)
                let text = runs(line1, Tok.Color.textPrimary, Tok.Color.textMeta, Tok.Color.needs) + runs(rest, Tok.Color.textMeta, Tok.Color.textSub)
                for slot in ["row", "row.selected", "row.hover"] { Layers.draw(slot, box, within: side, text: text, state: state, in: ctx) }
                let icon = CGRect(x: inset + pad[1], y: y + pad[0], width: Tok.Size.iconSize, height: Tok.Size.iconSize)
                Layers.draw("icon", icon, state: state, index: r, in: ctx)
                let run = CGRect(x: cw - inset - pad[1] - 50, y: y + pad[0], width: 50, height: Tok.Size.rowRight * Tok.Font.baseLine)
                Layers.draw("status.needs", run, within: side, textRun: run, text: runs(run, Tok.Color.needs), state: state, in: ctx)
                Layers.draw("bar.track", CGRect(x: 44, y: y + 40, width: 180, height: Tok.Size.barH), state: state, in: ctx)
                Layers.draw("bar.fill", CGRect(x: 44, y: y + 40, width: 90, height: Tok.Size.barH), state: state, in: ctx)
            }
            let pal = CGRect(x: 700, y: 300, width: 380, height: 380)
            Layers.draw("palette", pal, state: state, in: ctx)
            Layers.draw("palette.field", CGRect(x: 700, y: 300, width: 380, height: 40), state: state, in: ctx)
            Layers.draw("palette.caption", CGRect(x: 703, y: 303, width: 374, height: 18), text: runs(CGRect(x: 707, y: 305, width: 120, height: 14), Theme.current.app.rowSelectInk),
                        state: state, in: ctx)
            let entry = CGRect(x: 704, y: 360, width: 372, height: 36)
            Layers.draw("palette.row.selected", entry, text: Theme.current.effects.paletteSelection == "pill"
                        ? runs(entry.insetBy(dx: 12, dy: 0), Theme.current.app.palettePillInk, Theme.current.app.palettePillMute)
                        : runs(entry.insetBy(dx: 12, dy: 0), Tok.Color.paletteInk, Tok.Color.paletteMute),
                        state: state, in: ctx)
            Layers.draw("palette.row.hover", entry, text: runs(entry.insetBy(dx: 12, dy: 0), Tok.Color.paletteInk, Tok.Color.paletteMute), state: state, in: ctx)
            for slot in ["button", "button.default"] {
                Layers.draw(slot, CGRect(x: 980, y: 640, width: 75, height: 23), text: runs(CGRect(x: 1006, y: 644, width: 24, height: 15), Tok.Color.paletteInk),
                            state: state, in: ctx)
            }
        }
    }
}
#endif
