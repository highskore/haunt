import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

func row(_ id: String) -> Row {
    Row(surfaceId: id, kind: .shell, name: id, meta: "", statusText: "", needsYou: false, progress: nil, subagents: [],
        selected: false, pending: nil, color: nil)
}

let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
view.snapshot = SidebarSnapshot(groups: [
    SidebarGroup(id: "needs-you", label: "NEEDS YOU", rows: [row("n")]),
    SidebarGroup(id: "pinned", label: "PINNED", rows: [row("p1"), row("p2")]),
    SidebarGroup(id: "idle", label: "IDLE", rows: [row("i")]),
], colorStyle: .dot)

// Walk down the view and record every distinct drop target.
var seen: [String] = []
for y in stride(from: CGFloat(0), to: 600, by: 1) {
    let t = view.target(at: NSPoint(x: 50, y: y))
    let s = t.map { "\($0.group):\($0.before ?? "end")" } ?? "none"
    if seen.last != s { seen.append(s) }
}
check(seen == ["none", "pinned:p1", "pinned:p2", "pinned:end", "idle:i", "idle:end"], "drop targets top to bottom: \(seen)")
check(!seen.contains { $0.hasPrefix("needs-you") }, "nothing lands in NEEDS YOU")

// The footer counts agent tabs, not shells.
var agent = row("a")
agent.kind = .claude
var codex = row("c")
codex.kind = .codex
check(SidebarView.agentCount(SidebarSnapshot(groups: [SidebarGroup(id: "g", label: "", rows: [agent, row("s"), codex])], colorStyle: .dot)) == 2,
      "two agents beside a shell")

// Leaving the agents view: the old frame comes back only if a screen still shows it.
let main = NSRect(x: 0, y: 0, width: 1440, height: 875), gone = NSRect(x: 1440, y: 0, width: 1200, height: 800)
check(AgentsView.restoredFrame(NSRect(x: 100, y: 100, width: 900, height: 600), screens: [main], current: main)
      == NSRect(x: 100, y: 100, width: 900, height: 600), "an on-screen frame is kept")
check(AgentsView.restoredFrame(NSRect(x: 1500, y: 100, width: 900, height: 600), screens: [main], current: main)
      == NSRect(x: 270, y: 137.5, width: 900, height: 600), "a frame on a lost screen is centred on the current one")
check(AgentsView.restoredFrame(gone.insetBy(dx: -200, dy: -200), screens: [], current: NSRect(x: 0, y: 0, width: 800, height: 600))
      == NSRect(x: 0, y: 0, width: 800, height: 600), "and capped to it")

// A decoration's label or spark never takes the status slot from a row that needs you.
let deco = Decoration(label: "CI 9/9", labelTone: .warn, suffix: "ok", suffixTone: .dim, scroll: false, barPermille: 500,
                      spark: Spark(points: [1, 2], tone: .text))
let calm = RowDecor(deco, statusWins: false)
check(calm?.rightWidth == RowDecor.sparkSize.width, "a calm row shows the spark")
let needs = RowDecor(deco, statusWins: true)
check(needs?.rightWidth == nil && needs?.label == nil && needs?.spark == nil, "a needs-you row keeps Haunt's status")
check(needs?.suffix == nil && needs?.bar == 0.5, "only the bar stays")
check(RowDecor.color(.warn) != Tok.Color.needs, "warn is not the needs colour")

// A long prompt gives way to a plugin's suffix.
let ticker = RowDecor(Decoration(label: nil, labelTone: .dim, suffix: "▲ 3 tests", suffixTone: .text, scroll: false, barPermille: nil,
                                 spark: nil), statusWins: false)!
let metaFont = Draw.ui(Tok.Size.rowMeta)
let prompt = "main · TODO.md has three boxes; tick them off one by one and run the tests"
let fit = { (room: CGFloat) in ticker.meta(prompt, font: metaFont, room: room) }
let markW = Draw.width(CTLineCreateWithAttributedString(ticker.meta("…", font: metaFont)))
for room in [markW, markW + 30, 160, 240] {
    let s = fit(room)
    check(s.string.hasSuffix("▲ 3 tests"), "the suffix stays whole in \(room) pt: \(s.string)")
    check(Draw.width(CTLineCreateWithAttributedString(s)) <= room, "and the line fits \(room) pt")
}
check(fit(markW).string == "… · ▲ 3 tests", "with none of the prompt left, its \"…\" stays: \(fit(markW).string)")
check(fit(160).string.hasPrefix("main · TODO") && fit(160).string.contains("… · ▲"), "the prompt is cut, then the suffix")
check(fit(2000).string == prompt + " · ▲ 3 tests", "room for all: nothing cut")
let narrow = fit(markW - 1)
check(narrow.string.hasPrefix("…") && narrow.string.hasSuffix("tests") && !narrow.string.contains("main") && !narrow.string.contains(" · "),
      "too narrow for the marked suffix: the prompt goes and the suffix keeps its end: \(narrow.string)")
check(Draw.width(CTLineCreateWithAttributedString(narrow)) <= markW - 1, "and fits")
let dotsW = Draw.width(Draw.line("…", metaFont, .black))
check(fit(dotsW - 1).string == prompt + " · ▲ 3 tests", "narrower than \"…\": left whole for the caller's end-cut")
let longTicker = RowDecor(Decoration(label: nil, labelTone: .dim, suffix: "Read session.ts → Edit session.ts → Bash npm test → Read refresh.ts →",
                                     suffixTone: .dim, scroll: false, barPermille: nil, spark: nil), statusWins: false)!
let bare = longTicker.meta("", font: metaFont, room: 150)
check(bare.string.hasPrefix("…") && bare.string.hasSuffix("Read refresh.ts →") && Draw.width(CTLineCreateWithAttributedString(bare)) <= 150,
      "no meta and a long ticker: its end stays: \(bare.string)")

// A theme's words are drawn whole and checked as drawn, or Haunt's own are.
Theme.statusCheck = { $0 == "Done" }
Theme.current.app.strings = ["sidebar.foot": "Doneness {agents}", "row.sub.prefix": "D"]
Theme.current.app.sidebarFootFont = 400
check(SidebarView.footText(agents: 3, room: 200) == "3 agents", "a foot too wide for the sidebar is Haunt's, never cut to \"Done…\"")
Theme.current.app.sidebarFootFont = 9
check(SidebarView.footText(agents: 3, room: 200) == "Doneness 3", "and the theme's when it fits")
check(SidebarView.subText("one", room: 200) == "↳ one", "a prefix that spells a status with its label falls back to Haunt's")
check(SidebarView.subText("builder", room: 200) == "Dbuilder", "otherwise the theme's prefix stays")
Theme.statusCheck = { $0.hasPrefix("Done") }
let doneW = Draw.width(Draw.line("Done…", Draw.ui(Tok.Size.subFont), .black))
check(SidebarView.subText("onerous task", room: doneW) == "↳ onerous task", "a label cut to fit is checked as drawn (\"Done…\")")
check(SidebarView.subText("builder", room: 5) == "↳ builder", "and the theme's prefix needs room for itself")
Theme.current = Theme()
Theme.statusCheck = { _ in true }

// A row's icon and bar layers stay in their own bands; a selection or bar left to the layers falls back to Haunt's.
func render(_ v: SidebarView) -> NSBitmapImageRep {
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    Layers.endFrame()
    return rep
}
func changed(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    var n = 0
    for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { n += 1 } }
    return n
}
var busy = row("agent")
busy.kind = .claude
busy.meta = "main · Writing tests"
busy.progress = Progress(done: 1, total: 2)
busy.selected = true
let rows = SidebarView(frame: NSRect(x: 0, y: 0, width: 250, height: 200))
rows.snapshot = SidebarSnapshot(groups: [SidebarGroup(id: "g", label: "", rows: [busy, row("next")])], colorStyle: .dot)
do {
    // Tight, so a 6 pt glow would reach the meta line.
    Theme.current.size.barMt = 0
    Theme.current.size.rowGap[0] = 2
    let far = PrimSpec(kind: "rect", x: SpanSpec(a: -20, b: -20), y: SpanSpec(a: -20, b: -20), fill: "#000000")
    let specs = ["row", "icon", "bar.track", "bar.fill"].map { LayerSpec(id: $0, slot: $0, prims: [$0 == "row" ? PrimSpec(kind: "rect", fill: "#00000001") : far]) }
    Layers.set(Layers.resolve(specs, images: [], theme: Theme.current).0, source: LayerSource(specs: specs))
    var clips: [String: [CGRect]] = [:]
    Layers.recorder = { clips[$0, default: []].append($1) }
    _ = render(rows)
    Layers.recorder = nil
    Layers.set([], source: LayerSource())
    let lh = Tok.Font.baseLine, gapY = Tok.Size.rowGap[0], line1 = max(Tok.Size.iconSize, Tok.Size.rowName * lh, Tok.Size.rowRight * lh)
    if let box = clips["row"]?.first, let icon = clips["icon"]?.first, let bar = clips["bar.fill"]?.first {
        let col2 = Theme.current.effects.rowInset + Tok.Size.rowPad[1] + Tok.Size.iconSize + Tok.Size.rowGap[1], top = box.minY + Tok.Size.rowPad[0]
        check(icon.maxX <= col2 + 0.01 && icon.minY >= box.minY - 0.01 && icon.maxY <= box.maxY + 0.01, "the icon's layers stay in the row, left of column 2: \(icon)")
        check(icon.height > Tok.Size.iconSize, "with room for a ring past the icon: \(icon)")
        check(bar.minY >= top + line1 + gapY + Tok.Size.rowMeta * lh - 0.01 && bar.maxY <= box.maxY + 0.01, "the bar's stay under the meta line, in the row: \(bar)")
    } else {
        check(false, "drew the row, icon and bar: \(clips.keys.sorted())")
    }
    Theme.current = Theme()
}
do {
    Theme.current.effects.rowSelect = "fill"
    Theme.current.effects.progressStyle = "bar"
    let haunt = render(rows)
    Theme.current.effects.rowSelect = "none"
    Theme.current.effects.progressStyle = "none"
    check(changed(render(rows), haunt) == 0, "with no layers, a theme's \"none\" selection and bar are drawn as Haunt's")
    Theme.current = Theme()
}
do {
    // A track that drew, with no fill layer: Haunt's bar stands in, and the track's layers are drawn once.
    Theme.current.effects.progressStyle = "none"
    let track = [LayerSpec(id: "t", slot: "bar.track", prims: [PrimSpec(kind: "rect", fill: "#ffffff20")])]
    Layers.set(Layers.resolve(track, images: [], theme: Theme.current).0, source: LayerSource(specs: track))
    var tracks = 0
    Layers.recorder = { slot, _ in if slot == "bar.track" { tracks += 1 } }
    _ = render(rows)
    Layers.recorder = nil
    check(tracks == 1, "the track's layers are drawn once: \(tracks)")
    // The fallback selection is under the needs word too: in its own colour, the needs word's layers are skipped.
    Theme.current.effects.rowSelect = "none"
    Theme.current.color.rowSelected = Tok.Color.needs
    var waiting = busy
    waiting.needsYou = true
    waiting.statusText = "needs you"
    let one = SidebarView(frame: NSRect(x: 0, y: 0, width: 250, height: 200))
    one.snapshot = SidebarSnapshot(groups: [SidebarGroup(id: "g", label: "", rows: [waiting])], colorStyle: .dot)
    let needsLayer = [LayerSpec(id: "n", slot: "status.needs", prims: [PrimSpec(kind: "rect", fill: "#00000001")])]
    Layers.set(Layers.resolve(needsLayer, images: [], theme: Theme.current).0, source: LayerSource(specs: needsLayer))
    _ = render(one)
    check(Layers.skipped.contains { $0.hasPrefix("layers on status.needs ") }, "the fallback fill is under the needs word: \(Layers.skipped)")
    Layers.set([], source: LayerSource())
    Theme.current = Theme()
}

// The cursor's triangle is drawn over the icon's layers, so an opaque one reaching it can't hide it.
do {
    Theme.current.effects.rowSelect = "cursor"
    // Narrow, so the icon's 4 pt bleed reaches the cursor at the row's edge.
    Theme.current.size.rowPad[1] = 8
    let ink = Theme.current.app.rowSelectInk.usingColorSpace(.sRGB)!
    func cursorPixels(_ rep: NSBitmapImageRep) -> Int {
        let s = rep.pixelsWide / Int(rows.bounds.width), right = Int(Theme.current.effects.rowInset + Tok.Size.rowPad[1]) * s
        var n = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<right {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), abs(c.redComponent - ink.redComponent) < 0.02,
               abs(c.greenComponent - ink.greenComponent) < 0.02, abs(c.blueComponent - ink.blueComponent) < 0.02 { n += 1 }
        } }
        return n
    }
    let bare = cursorPixels(render(rows))
    let cover = Theme.current.app.rowSelectFill.withAlphaComponent(1).themeHex
    let ring = [LayerSpec(id: "i", slot: "icon", prims: [PrimSpec(kind: "rect", x: SpanSpec(a: -20, b: -20), y: SpanSpec(a: -20, b: -20), fill: cover)])]
    Layers.set(Layers.resolve(ring, images: [], theme: Theme.current).0, source: LayerSource(specs: ring))
    let covered = cursorPixels(render(rows))
    Layers.set([], source: LayerSource())
    check(bare > 0 && covered == bare, "the cursor shows over an opaque icon layer: \(covered) of \(bare) px")
    Theme.current = Theme()
}

print(failures == 0 ? "sidebar: all passed" : "sidebar: \(failures) failed")
exit(failures == 0 ? 0 : 1)
