import AppKit
import AVFoundation
import os

// The app's types PluginFx.swift uses, as the UniFFI bindings shape them.
struct DockImage: Equatable, Hashable {
    var id: String
    var png: Data
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

/// dock-ghost's art when it is checked out next to this repo, else plain squares.
func dockImage(_ id: String, fill: NSColor) -> DockImage {
    let dir = ProcessInfo.processInfo.environment["HAUNT_DOCK_ASSETS"]
        ?? NSHomeDirectory() + "/code/haunt-plugins/haunt-dock-ghost/assets"
    if let png = FileManager.default.contents(atPath: "\(dir)/\(id).png") { return DockImage(id: id, png: png) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    fill.setFill()
    NSRect(x: 0, y: 0, width: 256, height: 256).fill()
    NSGraphicsContext.restoreGraphicsState()
    return DockImage(id: id, png: rep.representation(using: .png, properties: [:])!)
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

dock.show(image: sleepy, badge: nil, blink: nil)
let idle = tile()
check(idle != haunt, "idle sets the plugin's picture")
check(NSApp.dockTile.badgeLabel == nil, "no badge: \(NSApp.dockTile.badgeLabel ?? "nil")")
if let render { renderTile(to: "\(render)/host-b-dock-idle.png") }

dock.show(image: needs, badge: 1, blink: nil)
check(NSApp.dockTile.badgeLabel == "1", "needs-you badge: \(NSApp.dockTile.badgeLabel ?? "nil")")
if let render { renderTile(to: "\(render)/host-b-dock-needs.png") }
dock.show(image: needs, badge: 4_000_000_000, blink: nil)
check(NSApp.dockTile.badgeLabel == "4000000000", "the badge is the number only: \(NSApp.dockTile.badgeLabel ?? "nil")")

dock.show(image: open, badge: nil, blink: blink)
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

dock.show(image: DockImage(id: "bad", png: Data("\u{89}PNG\r\n\u{1a}\nnot really".utf8)), badge: 2, blink: nil)
check(tile() != working && NSApp.dockTile.badgeLabel == "2", "a PNG that doesn't decode shows Haunt's icon")
check(tile() == haunt, "Haunt's own icon exactly")
let gif = DockImage(id: "gif", png: Data(base64Encoded: "R0lGODlhAQABAIAAAP///wAAACwAAAAAAQABAAACAkQBADs=")!)
dock.show(image: gif, badge: nil, blink: nil)
check(tile() != working, "a GIF is refused")

dock.show(image: needs, badge: 3, blink: nil)
dock.reset()
check(NSApp.dockTile.badgeLabel == nil, "reset drops the badge")

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
