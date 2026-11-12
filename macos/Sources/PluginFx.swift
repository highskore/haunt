import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// The Dock tile the owning plugin asked for (`HostRequest.dockShow`); the core lets one plugin at a time
/// send these. `blink` is flashed every few seconds, never under Reduce Motion.
final class PluginDock {
    private static let blinkEvery: TimeInterval = 4
    private static let blinkFor: TimeInterval = 0.4
    private static let pixelsMax = 1024

    var enabled = true {
        didSet { if enabled != oldValue { apply() } }
    }
    private struct Shown { let image: NSImage?, badge: UInt32?, blink: NSImage? }
    private var shown: Shown?
    private var timer: Timer?
    /// Decoded images by their bytes; a plugin has at most 8.
    private var decoded: [Data: NSImage] = [:]

    func show(image: DockImage?, badge: UInt32?, blink: DockImage?) {
        shown = image == nil && badge == nil ? nil : Shown(image: image.flatMap(decode), badge: badge, blink: blink.flatMap(decode))
        apply()
    }

    /// Haunt's own icon and no badge, as when the owner lets go or the plugins reload.
    func reset() {
        shown = nil
        decoded = [:]
        apply()
    }

    private func apply() {
        timer?.invalidate()
        timer = nil
        let s = enabled ? shown : nil
        // nil puts the bundle's icon back.
        NSApp.applicationIconImage = s?.image
        NSApp.dockTile.badgeLabel = s?.badge.map(String.init)
        guard let image = s?.image, let blink = s?.blink else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.blinkEvery, repeats: true) { [weak self] t in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            NSApp.applicationIconImage = blink
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.blinkFor) {
                if self?.timer === t { NSApp.applicationIconImage = image }
            }
        }
    }

    /// A still PNG that decodes whole, at most 1024 pixels each way; anything else is dropped and logged.
    private func decode(_ d: DockImage) -> NSImage? {
        if let img = decoded[d.png] { return img }
        guard let src = CGImageSourceCreateWithData(d.png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(src) as String? == UTType.png.identifier, CGImageSourceGetCount(src) == 1,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              (1...Self.pixelsMax).contains(cg.width), (1...Self.pixelsMax).contains(cg.height)
        else {
            AppDelegate.logger.error("plugin dock image \(d.id, privacy: .public) does not decode as a still PNG; dropped")
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if decoded.count >= 16 { decoded = [:] }
        decoded[d.png] = img
        return img
    }
}

/// The owning plugin's glow (`HostRequest.glowShow`): a 3 pt warn-orange hairline along the top of the screen
/// Haunt's window is on, breathing unless Reduce Motion is on, and its label at the top right, under the menu
/// bar. A borderless panel above other apps' windows that ignores the mouse and never takes focus.
final class PluginGlow {
    static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    var enabled = true {
        didSet { if enabled != oldValue { apply() } }
    }
    var showsLabel = true {
        didSet { if showsLabel != oldValue { apply() } }
    }
    /// The window whose screen the glow follows.
    weak var anchor: NSWindow? {
        didSet {
            if let o = anchorObserver { NotificationCenter.default.removeObserver(o) }
            anchorObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: anchor,
                                                                    queue: .main) { [weak self] _ in self?.apply() }
        }
    }
    /// Shown while set; the label inside may still be nil.
    private var label: String??
    private var panel: GlowPanel?
    private var anchorObserver: NSObjectProtocol?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                              queue: .main) { [weak self] _ in self?.apply() }),
            (workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
                                              queue: .main) { [weak self] _ in self?.apply() }),
        ]
    }

    deinit {
        for (center, o) in observers { center.removeObserver(o) }
        if let o = anchorObserver { NotificationCenter.default.removeObserver(o) }
    }

    func show(count: UInt8) {
        label = .some(Self.label(count))
        apply()
    }

    /// Haunt's words, never the plugin's.
    static func label(_ count: UInt8) -> String? {
        switch count {
        case 0: nil
        case 1: "1 needs you"
        default: "\(count) need you"
        }
    }

    func hide() {
        label = nil
        apply()
    }

    private func apply() {
        guard enabled, let label, let screen = anchor?.screen ?? NSScreen.main else {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? GlowPanel()
        panel = p
        let f = screen.frame
        // The label sits under the menu bar, never on its items.
        let menuBar = f.maxY - screen.visibleFrame.maxY
        let height = menuBar + ceil(Self.font.ascender - Self.font.descender) + 8
        p.setFrame(NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height), display: false)
        p.glow.update(label: showsLabel ? label : nil, below: menuBar + 4, scale: screen.backingScaleFactor,
                      breathe: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        p.orderFrontRegardless()
    }
}

/// Never key or main, ignores the mouse, on every Space and over full-screen apps.
private final class GlowPanel: NSPanel {
    let glow = GlowView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = glow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class GlowView: NSView {
    private static let line: CGFloat = 3
    private static let halo: CGFloat = 12
    private static let inset: CGFloat = 12
    private let line = CALayer()
    private let halo = CAGradientLayer()
    private let text = CATextLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let warn = Tok.App.pluginWarn
        line.backgroundColor = warn.cgColor
        halo.colors = [warn.withAlphaComponent(0.4).cgColor, warn.withAlphaComponent(0).cgColor]
        halo.startPoint = CGPoint(x: 0.5, y: 1)
        halo.endPoint = CGPoint(x: 0.5, y: 0)
        text.font = PluginGlow.font
        text.fontSize = PluginGlow.font.pointSize
        text.foregroundColor = warn.cgColor
        text.alignmentMode = .right
        text.truncationMode = .end
        for l in [halo, line, text] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `below`: how far under the top edge the label starts.
    func update(label: String?, below: CGFloat, scale: CGFloat, breathe: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        line.frame = NSRect(x: 0, y: b.maxY - Self.line, width: b.width, height: Self.line)
        halo.frame = NSRect(x: 0, y: b.maxY - Self.line - Self.halo, width: b.width, height: Self.halo)
        let h = ceil(PluginGlow.font.ascender - PluginGlow.font.descender) + 2
        text.frame = NSRect(x: b.width / 2, y: b.maxY - below - h, width: b.width / 2 - Self.inset, height: h)
        text.contentsScale = scale
        text.string = label ?? ""
        text.isHidden = label == nil
        CATransaction.commit()
        for l in [line, halo] {
            l.removeAnimation(forKey: "breathe")
            guard breathe else { continue }
            let a = CABasicAnimation(keyPath: "opacity")
            (a.fromValue, a.toValue, a.duration, a.autoreverses, a.repeatCount) = (1.0, 0.35, 2.4, true, .infinity)
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(a, forKey: "breathe")
        }
    }
}

/// Haunt's own sounds for plugins (`HostRequest.soundPlay`, `.soundAmbient`), synthesised here, never a file:
/// a soft sine chime and bell, and rain made from filtered noise. One loop per plugin. The engine plays to the
/// system output and follows it when that changes, and pauses when nothing has played for a while.
final class PluginSound {
    private static let rate = 44_100.0
    /// A plugin's full volume is still a quiet sound.
    private static let gain: Float = 0.25
    private static let voices = 4
    private static let loopSeconds = 4.0

    var enabled = true {
        didSet { if !enabled { stopAll() } }
    }
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    private var shots: [AVAudioPlayerNode] = []
    private var nextShot = 0
    private var loops: [String: (node: AVAudioPlayerNode, sound: SoundName)] = [:]
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var idle: Timer?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) {
            [weak self] _ in self?.outputChanged()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func play(_ sound: SoundName, pitch: Int32, volume: Float) {
        guard enabled, volume > 0 else { return }
        if shots.isEmpty {
            shots = (0..<Self.voices).map { _ in attachNode() }
        }
        guard start() else { return }
        let node = shots[nextShot]
        nextShot = (nextShot + 1) % shots.count
        node.stop()
        node.volume = volume * Self.gain
        node.scheduleBuffer(buffer(sound, pitch: Int(pitch), loop: false))
        node.play()
        armIdle()
    }

    func ambient(pluginId: String, _ sound: SoundName, level: Float) {
        guard enabled, level > 0 else {
            stopLoop(pluginId)
            return
        }
        let loop = loops[pluginId] ?? (attachNode(), sound)
        guard start() else { return }
        if loops[pluginId] == nil || loop.sound != sound || !loop.node.isPlaying {
            loop.node.stop()
            loop.node.scheduleBuffer(buffer(sound, pitch: 0, loop: true), at: nil, options: .loops)
        }
        loop.node.volume = level * Self.gain
        loop.node.play()
        loops[pluginId] = (loop.node, sound)
        idle?.invalidate()
    }

    func stopAll() {
        for id in Array(loops.keys) { stopLoop(id) }
        for node in shots { node.stop() }
        armIdle()
    }

    private func stopLoop(_ pluginId: String) {
        guard let loop = loops.removeValue(forKey: pluginId) else { return }
        loop.node.stop()
        engine.detach(loop.node)
        armIdle()
    }

    private func attachNode() -> AVAudioPlayerNode {
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        return node
    }

    private func start() -> Bool {
        if engine.isRunning { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            AppDelegate.logger.error("plugin sound: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The output device changed and the engine stopped: start again on the new one, loops and all.
    private func outputChanged() {
        guard !loops.isEmpty, start() else { return }
        for (_, loop) in loops {
            loop.node.stop()
            loop.node.scheduleBuffer(buffer(loop.sound, pitch: 0, loop: true), at: nil, options: .loops)
            loop.node.play()
        }
    }

    /// Pauses the engine once no loop plays and the last one-shot (at most 3 s) is over.
    private func armIdle() {
        idle?.invalidate()
        guard loops.isEmpty else { return }
        idle = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, self.loops.isEmpty else { return }
            self.engine.pause()
        }
    }

    private func buffer(_ sound: SoundName, pitch: Int, loop: Bool) -> AVAudioPCMBuffer {
        let key = "\(sound)/\(pitch)/\(loop)"
        if let b = buffers[key] { return b }
        let samples = Self.synth(sound, ratio: pow(2, Double(pitch) / 12), loop: loop)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        b.frameLength = b.frameCapacity
        samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        buffers[key] = b
        return b
    }

    /// Soft sines with a 5 ms attack and an exponential fade; a loop of chime or bell repeats every 4 s.
    static func synth(_ sound: SoundName, ratio: Double, loop: Bool) -> [Float] {
        func tone(_ base: Double, _ partials: [(ratio: Double, amp: Double, decay: Double)], seconds: Double) -> [Float] {
            let n = Int(seconds * rate)
            return (0..<n).map { i in
                let t = Double(i) / rate
                let attack = min(1, t / 0.005)
                let s = partials.reduce(0.0) { $0 + $1.amp * exp(-t * $1.decay) * sin(2 * .pi * base * $1.ratio * t) }
                return Float(attack * s * 0.5)
            }
        }
        var out: [Float]
        switch sound {
        case .chime:
            out = tone(1046.5 * ratio, [(1, 1, 3.5), (2, 0.3, 6), (3, 0.08, 9)], seconds: 1.6)
        case .bell:
            out = tone(523.25 * ratio, [(1, 1, 1.6), (2, 0.5, 2.4), (2.76, 0.3, 3.2), (5.4, 0.12, 6)], seconds: 3)
        case .rain:
            out = rain(seconds: loop ? loopSeconds : 2)
        }
        if loop, sound != .rain {
            out += [Float](repeating: 0, count: max(0, Int(loopSeconds * rate) - out.count))
        }
        if !loop {
            // Rain as a one-shot fades in and out.
            let fade = min(out.count / 4, Int(0.3 * rate))
            for i in 0..<fade {
                let g = Float(i) / Float(fade)
                out[i] *= g
                out[out.count - 1 - i] *= g
            }
        }
        return out
    }

    /// Low-passed noise with a few soft drops, its ends crossfaded so it loops without a click.
    private static func rain(seconds: Double) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        let fade = Int(0.2 * rate)
        let n = Int(seconds * rate)
        var lp: Double = 0
        var drop: Double = 0
        var out = (0..<(n + fade)).map { _ -> Float in
            let white = Double.random(in: -1...1, using: &rng)
            lp += 0.12 * (white - lp)
            if Int.random(in: 0..<9000, using: &rng) == 0 { drop = Double.random(in: 0.2...0.5, using: &rng) }
            drop *= 0.996
            return Float((lp * 0.8 + white * drop * 0.3) * 0.5)
        }
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            out[i] = out[i] * g + out[n + i] * (1 - g)
        }
        out.removeLast(fade)
        return out
    }
}

/// A plugin's `speech.say` in the system voice (`HostRequest.say`): one utterance at a time, a new one cutting
/// off the last. A plugin's `stop` only stops its own.
final class PluginSpeech {
    var enabled = true {
        didSet { if !enabled { stopAll() } }
    }
    private let synth = AVSpeechSynthesizer()
    private var speaker: String?

    func say(pluginId: String, text: String) {
        guard enabled else { return }
        synth.stopSpeaking(at: .immediate)
        speaker = pluginId
        synth.speak(Self.utterance(text))
    }

    /// Plain text in the system voice; the core already made it plain and short.
    static func utterance(_ text: String) -> AVSpeechUtterance {
        AVSpeechUtterance(string: text)
    }

    func stop(pluginId: String) {
        guard speaker == pluginId else { return }
        stopAll()
    }

    func stopAll() {
        synth.stopSpeaking(at: .immediate)
        speaker = nil
    }
}
