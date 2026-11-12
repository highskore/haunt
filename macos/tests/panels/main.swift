import AppKit

// The app's types PluginPanels.swift uses, as the UniFFI bindings shape them.
enum PanelPlacement: Equatable, Hashable { case sheet, right, card, window }
enum PanelTone: Equatable, Hashable { case text, dim, faint, warn }
enum PanelShape: Equatable, Hashable {
    case dot(x: Float, y: Float, r: Float, shade: Float, warn: Bool, pulse: Bool, key: String?)
    case rect(x: Float, y: Float, w: Float, h: Float, shade: Float, warn: Bool, label: String?, sub: String?, key: String?)
    case line(x1: Float, y1: Float, x2: Float, y2: Float, shade: Float, key: String?)
    case label(x: Float, y: Float, text: String, tone: PanelTone, key: String?)
}
enum PanelNodeKind: Equatable, Hashable {
    case vStack, hStack
    case text(text: String, tone: PanelTone, mono: Bool, bold: Bool)
    case row(label: String, sub: String?, right: String?, tone: PanelTone)
    case button(label: String, action: String, primary: Bool, surface: String?)
    case divider
    case grid(rows: UInt32, columns: UInt32, cell: UInt32, cells: [Float], marked: [UInt32])
    case canvas(width: UInt32, height: UInt32, shapes: [PanelShape], easeMs: UInt32)
}
struct PanelNode: Equatable, Hashable { var parent: UInt32?; var kind: PanelNodeKind }
struct Panel: Equatable, Hashable {
    var id: String
    var generation: UInt64
    var placement: PanelPlacement
    var title: String
    var nodes: [PanelNode]
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
enum TitleBarView {
    static func height(zen: Bool) -> CGFloat { Tok.Size.titlebarH + (zen ? Tok.Size.zenBar : 0) }
}

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

/// `view` drawn offscreen at 2x, the way the window would show it; nothing is put on screen.
func png(_ view: NSView) -> NSBitmapImageRep {
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["HAUNT_PANEL_RENDER"] else { return }
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}

/// The colour at view point `p` (flipped: y down), from a rep drawn of a view of `size`.
func color(_ rep: NSBitmapImageRep, _ p: NSPoint, in size: NSSize) -> NSColor {
    let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
    return rep.colorAt(x: Int(p.x * sx), y: Int(p.y * sy))!.usingColorSpace(.deviceRGB)!
}

func brightness(_ c: NSColor) -> CGFloat { (c.redComponent + c.greenComponent + c.blueComponent) / 3 }

func panel(_ shapes: [PanelShape], easeMs: UInt32 = 2000, generation: UInt64) -> Panel {
    Panel(id: "map", generation: generation, placement: .window, title: "Code map",
          nodes: [PanelNode(parent: nil, kind: .canvas(width: 320, height: 160, shapes: shapes, easeMs: easeMs))])
}

func frameView() -> PanelFrame {
    let f = PanelFrame(from: "Code map", card: false) { _ in }
    f.frame = NSRect(x: 0, y: 0, width: 360, height: 260)
    f.appearance = NSAppearance(named: .darkAqua)
    return f
}

_ = NSApplication.shared

// 1. A rect with a sub line: the label, then a dim second line under it.
let tile = PanelShape.rect(x: 10, y: 10, w: 140, h: 60, shade: 0.3, warn: false, label: "src/api", sub: "24 edits · 38 files", key: "src/api")
let still = frameView()
still.update(panel([tile, .rect(x: 170, y: 10, w: 140, h: 24, shade: 0.8, warn: false, label: "docs", sub: "hidden: too short", key: "docs")], generation: 1))
let a = png(still)
save(a, "rect-sub")

// 2. A keyed rect moved by a new show, snapshot halfway through a 2 s ease: it sits between the old and new spots.
let moving = frameView()
let at = { (x: Float) in PanelShape.rect(x: x, y: 80, w: 60, h: 40, shade: 1, warn: false, label: nil, sub: nil, key: "star") }
moving.update(panel([at(10)], generation: 1))
_ = png(moving)
moving.update(panel([at(250)], generation: 2))
let start = Date()
RunLoop.main.run(until: start.addingTimeInterval(1.0))
let mid = png(moving)
save(mid, "canvas-mid-ease")
RunLoop.main.run(until: start.addingTimeInterval(2.3))
let end = png(moving)
save(end, "canvas-eased")

// Where the canvas sits in the frame: find the moving rect's row by scanning for its bright pixels.
func brightXs(_ rep: NSBitmapImageRep, row y: CGFloat) -> [CGFloat] {
    let size = moving.bounds.size
    return stride(from: CGFloat(0), to: size.width, by: 2).filter { brightness(color(rep, NSPoint(x: $0, y: y), in: size)) > 0.8 }
}
// The title is bright too; the rect's row is the first whose bright pixels all sit right of it.
let rowY = (0..<Int(moving.bounds.height)).map(CGFloat.init).first { brightXs(end, row: $0).first.map { $0 > 200 } ?? false } ?? 0
let midXs = brightXs(mid, row: rowY + 5), endXs = brightXs(end, row: rowY + 5)
check(!endXs.isEmpty, "the eased rect is drawn")
if let m = midXs.first, let e = endXs.first {
    check(m < e - 40, "halfway, the rect is well short of its new spot: \(m) vs \(e)")
    check(m > 40, "halfway, the rect has left its old spot: \(m)")
}

// 3. A notification action whose id is a link: the button title the core builds ("Open PR (github.com)",
// asserted in plugins::tests::a_click_on_a_notification_action_may_open_its_link_and_copy_once), drawn
// the way macOS lists a notification's actions under Options. The system's own banner can't be drawn offscreen.
func notificationMock(title: String, subtitle: String, actions: [String]) -> NSBitmapImageRep {
    let size = NSSize(width: 360, height: 96 + CGFloat(actions.count) * 28)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let plain = NSGraphicsContext(bitmapImageRep: rep)!
    plain.cgContext.translateBy(x: 0, y: size.height * 2)
    plain.cgContext.scaleBy(x: 2, y: -2)
    // Flipped, so the layout below reads top down and text still draws upright.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: plain.cgContext, flipped: true)
    NSColor(white: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size.width, height: 80), xRadius: 14, yRadius: 14).fill()
    let text = { (s: String, font: NSFont, color: NSColor, x: CGFloat, y: CGFloat) in
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            .draw(with: NSRect(x: x, y: y, width: size.width - x - 12, height: 20), options: [.usesLineFragmentOrigin])
    }
    NSColor(white: 0.3, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 12, y: 18, width: 40, height: 40), xRadius: 9, yRadius: 9).fill()
    text(title, .boldSystemFont(ofSize: 13), .white, 64, 16)
    text(subtitle, .systemFont(ofSize: 12), NSColor(white: 0.7, alpha: 1), 64, 36)
    NSColor(white: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 180, y: 84, width: 170, height: CGFloat(actions.count) * 28 + 8), xRadius: 8, yRadius: 8).fill()
    for (i, a) in actions.enumerated() { text(a, .systemFont(ofSize: 13), .white, 192, 90 + CGFloat(i) * 28) }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
save(notificationMock(title: "api · #142 checks failed", subtitle: "dev.haunt.ci-lights", actions: ["Open PR (github.com)", "Snooze"]),
     "notify-action-title")

if failures > 0 { print("panels: \(failures) failed"); exit(1) }
print("panels: all passed")
