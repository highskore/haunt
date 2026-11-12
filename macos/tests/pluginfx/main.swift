import AppKit
import AVFoundation
import os

// The app's types PluginFx.swift uses, as the UniFFI bindings shape them.
struct DockImage: Equatable, Hashable {
    var id: String
    var width: UInt32
    var height: UInt32
    var rgba: Data
}

enum GlowLabel: Equatable, Hashable {
    case count(n: UInt8)
    case row(surface: String, head: String, waitedSecs: UInt64)
}

enum SoundName: Equatable, Hashable {
    case chime, bell, rain
}

enum AppDelegate {
    static let logger = Logger(subsystem: "dev.haunt.test", category: "pluginfx")
}

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

func run(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// dock-ghost's art when it is checked out next to this repo, else plain squares, as the straight-alpha RGBA
/// the core hands over (the test decodes the art itself; the app never does).
func dockImage(_ id: String, fill: NSColor) -> DockImage {
    let dir = ProcessInfo.processInfo.environment["HAUNT_DOCK_ASSETS"]
        ?? NSHomeDirectory() + "/code/haunt-plugins/haunt-dock-ghost/assets"
    let art = NSImage(contentsOfFile: "\(dir)/\(id).png")
    let side = min(512, art.map { Int($0.representations.first?.pixelsWide ?? 256) } ?? 256)
    var px = [UInt8](repeating: 0, count: side * side * 4)
    let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let r = NSRect(x: 0, y: 0, width: side, height: side)
    if let art { art.draw(in: r) } else { fill.setFill(); r.fill() }
    NSGraphicsContext.restoreGraphicsState()
    for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
        for c in 0..<3 { px[i + c] = UInt8(min(255, Int(px[i + c]) * 255 / Int(px[i + 3]))) }
    }
    return DockImage(id: id, width: UInt32(side), height: UInt32(side), rgba: Data(px))
}

/// What the Dock is handed, drawn offscreen: the tile image, and `badgeLabel` in a red pill at the top right
/// the way the Dock draws it (the Dock's own drawing can't be captured without showing it).
func renderTile(to path: String) {
    let side = 512
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(x: 0, y: 0, width: side, height: side)
    NSApp.applicationIconImage?.draw(in: r)
    if let badge = NSApp.dockTile.badgeLabel {
        let font = NSFont.systemFont(ofSize: 64, weight: .medium)
        let text = NSAttributedString(string: badge, attributes: [.font: font, .foregroundColor: NSColor.white])
        let w = max(110, text.size().width + 48)
        let pill = NSRect(x: CGFloat(side) - w - 8, y: CGFloat(side) - 118, width: w, height: 110)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 55, yRadius: 55).fill()
        text.draw(at: NSPoint(x: pill.midX - text.size().width / 2, y: pill.midY - text.size().height / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// The tile image as 32×32 pixels: AppKit hands back its own copy, so compare what it draws.
func tile() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSApp.applicationIconImage?.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    NSGraphicsContext.restoreGraphicsState()
    return Data(bytes: rep.bitmapData!, count: 32 * 128)
}

// MARK: Dock tile

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let render = ProcessInfo.processInfo.environment["HAUNT_DOCK_RENDER"]
let haunt = tile()
let (sleepy, open, needs, blink) = (dockImage("sleepy", fill: .darkGray), dockImage("open", fill: .gray),
                                    dockImage("needs", fill: .lightGray), dockImage("blink", fill: .white))
let dock = PluginDock()
let p = "dev.haunt.dock-ghost"
dock.register(pluginId: p, images: [sleepy, open, needs, blink])

dock.show(pluginId: p, image: "sleepy", badge: nil, blink: nil)
let idle = tile()
check(idle != haunt, "idle sets the plugin's picture")
check(NSApp.dockTile.badgeLabel == nil, "no badge: \(NSApp.dockTile.badgeLabel ?? "nil")")
if let render { renderTile(to: "\(render)/host-b-dock-idle.png") }

dock.show(pluginId: p, image: "needs", badge: 1, blink: nil)
check(NSApp.dockTile.badgeLabel == "1", "needs-you badge: \(NSApp.dockTile.badgeLabel ?? "nil")")
if let render { renderTile(to: "\(render)/host-b-dock-needs.png") }
dock.show(pluginId: p, image: "needs", badge: 4_000_000_000, blink: nil)
check(NSApp.dockTile.badgeLabel == "4000000000", "the badge is the number only: \(NSApp.dockTile.badgeLabel ?? "nil")")

dock.show(pluginId: p, image: "open", badge: nil, blink: "blink")
let working = tile()
check(NSApp.dockTile.badgeLabel == nil, "working drops the badge")
if let render { renderTile(to: "\(render)/host-b-dock-working.png") }
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    run(4.15)
    check(tile() != working, "blink shows its frame after 4 s")
    if let render { renderTile(to: "\(render)/host-b-dock-working-blink.png") }
    run(0.5)
    check(tile() == working, "and goes back")
}

dock.enabled = false
check(NSApp.dockTile.badgeLabel == nil && tile() == haunt, "[plugin_fx] dock = false puts Haunt's back")
dock.enabled = true
check(tile() == working, "and turning it on again shows the plugin's")

dock.register(pluginId: p, images: [sleepy, needs, blink, DockImage(id: "open", width: needs.width, height: needs.height, rgba: needs.rgba)])
check(tile() != working, "new pixels under the shown id show at once")
dock.register(pluginId: p, images: [sleepy, needs, blink, open])

let other = "dev.haunt.other"
dock.register(pluginId: other, images: [DockImage(id: "short", width: 64, height: 64, rgba: Data(count: 64 * 64 * 4 - 1)),
                                        DockImage(id: "wide", width: 513, height: 1, rgba: Data(count: 513 * 4)),
                                        DockImage(id: "empty", width: 0, height: 1, rgba: Data())])
check(tile() == working, "another plugin's images leave the shown tile alone")
dock.show(pluginId: other, image: "short", badge: 2, blink: nil)
check(NSApp.dockTile.badgeLabel == "2" && tile() == haunt, "pixels that don't fill the size show Haunt's own icon")
for id in ["wide", "empty", "sleepy"] {
    dock.show(pluginId: other, image: id, badge: nil, blink: nil)
    check(tile() == haunt, "\(id) is not \(other)'s to show")
}

dock.show(pluginId: p, image: "needs", badge: 3, blink: nil)
dock.register(pluginId: p, images: [])
check(tile() == haunt && NSApp.dockTile.badgeLabel == "3", "dropped images go, the badge stays")
dock.register(pluginId: p, images: [needs])
dock.reset()
check(NSApp.dockTile.badgeLabel == nil && tile() == haunt, "reset drops the badge")
dock.show(pluginId: p, image: "needs", badge: nil, blink: nil)
check(tile() == haunt, "and the images")

// MARK: Who holds a spot, as the bridge drains plugins in turn

do {
    var slots = PluginSlots()
    let (old, new) = ("dev.haunt.old", "dev.haunt.new")
    check(slots.admit(.dock, new, seq: 1, letGo: false), "new claims the tile")
    // One drain: new let go (2), then old claimed (3); the bridge reads old's outbox first.
    check(slots.admit(.dock, old, seq: 3, letGo: false), "old's claim is carried out")
    check(!slots.admit(.dock, new, seq: 2, letGo: true), "new's earlier let-go doesn't reset old's tile")
    check(!slots.admit(.dock, new, seq: 9, letGo: true), "nor does a let-go from anyone but the holder")
    // Old shows, lets go and new claims, all in one drain, new's outbox read first.
    check(slots.admit(.glow, new, seq: 12, letGo: false), "new claims the glow")
    check(!slots.admit(.glow, old, seq: 10, letGo: false) && !slots.admit(.glow, old, seq: 11, letGo: true), "old's stale show and hide go")
    check(slots.admit(.glow, new, seq: 13, letGo: true) && slots.admit(.glow, old, seq: 14, letGo: false), "the holder lets go, then another claims")
    check(slots.admit(.title, old, seq: 15, letGo: false) && slots.admit(.title, old, seq: 16, letGo: false), "spots are counted apart")
}

// MARK: The glow's words

check(PluginGlow.label(count: 0) == nil && PluginGlow.label(count: 1) == "1 needs you" && PluginGlow.label(count: 3) == "3 need you", "counts")
check(PluginGlow.label(head: "api · git push?", waited: 72) == "api · git push? · 1m12s", PluginGlow.label(head: "api · git push?", waited: 72))
check(PluginGlow.elapsed(0) == "0s" && PluginGlow.elapsed(3599) == "59m59s" && PluginGlow.elapsed(7500) == "2h05m" && PluginGlow.elapsed(-5) == "0s", "elapsed")
let longest = PluginGlow.label(head: String(repeating: "x", count: 23), waited: 3599)
check(longest.count == 32 && longest.hasSuffix(" · 59m59s"), "a full head still shows its time: \(longest)")
check(PluginGlow.label(head: String(repeating: "x", count: 40), waited: 1).count == 32, "never past 32")

// MARK: Speech, rendered to buffers and never played

var frames = 0
var peak: Float = 0
var done = false
let writer = AVSpeechSynthesizer()
writer.write(PluginSpeech.utterance("Tests passed on main.")) { buffer in
    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
        done = true
        return
    }
    frames += Int(pcm.frameLength)
    if let f = pcm.floatChannelData {
        for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(f[0][i])) }
    } else if let s = pcm.int16ChannelData {
        for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(Float(s[0][i]) / 32768)) }
    }
}
let deadline = Date().addingTimeInterval(20)
while !done && Date() < deadline { run(0.05) }
check(done, "the voice finished rendering")
check(frames > 8000 && peak > 0.01, "the system voice renders real speech: \(frames) frames, peak \(peak)")

// MARK: Sounds

for sound in [SoundName.chime, .bell, .rain] {
    for loop in [false, true] {
        let s = PluginSound.synth(sound, ratio: 1, loop: loop)
        let peak = s.map(abs).max() ?? 0
        check(peak > 0.05 && peak <= 1, "\(sound) loop=\(loop) is audible and never clips: \(peak)")
        if loop {
            check(s.count == 176_400, "\(sound) loops every 4 s: \(s.count)")
            check(abs(s[0] - s[s.count - 1]) < 0.2, "\(sound) loop seam has no jump: \(s[0]) → \(s[s.count - 1])")
        } else {
            check(abs(s[0]) < 0.01, "\(sound) starts from silence: \(s[0])")
        }
    }
}
let up = PluginSound.synth(.chime, ratio: pow(2, 12.0 / 12), loop: false)
let base = PluginSound.synth(.chime, ratio: 1, loop: false)
check(up.count == base.count && up != base, "pitch changes the tone, not its length")

print(failures == 0 ? "pluginfx: all passed" : "pluginfx: \(failures) failed")
exit(failures == 0 ? 0 : 1)
