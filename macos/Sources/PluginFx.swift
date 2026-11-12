import AppKit
import AVFoundation

/// Who holds the Dock tile, the glow and the title-bar line. The core lets one plugin at a time hold each, but
/// the bridge drains plugins in turn, so an older plugin's let-go can arrive after a newer one's claim: carry out
/// nothing older (`seq`) than what is on screen, and a let-go only from the holder.
struct PluginSlots {
    enum Slot { case dock, glow, title }
    private var owner: [Slot: String] = [:]
    private var last: [Slot: UInt64] = [:]

    /// Whether to carry out `plugin`'s claim of `slot`, or its let-go.
    mutating func admit(_ slot: Slot, _ plugin: String, seq: UInt64, letGo: Bool) -> Bool {
        guard seq > last[slot, default: 0] else { return false }
        if letGo {
            guard owner[slot] == plugin else { return false }
            owner[slot] = nil
        } else {
            owner[slot] = plugin
        }
        last[slot] = seq
        return true
    }
}

/// The Dock tile the owning plugin asked for (`HostRequest.dockShow`), from the images each plugin registered
/// (`dockImages`); the core lets one plugin at a time show. `blink` is flashed every few seconds, never under
/// Reduce Motion.
final class PluginDock {
    private static let blinkEvery: TimeInterval = 4
    private static let blinkFor: TimeInterval = 0.4
    private static let pixelsMax = 512

    var enabled = true {
        didSet { if enabled != oldValue { apply() } }
    }
    private struct Shown { let plugin: String, image: String?, badge: UInt32?, blink: String? }
    private var shown: Shown?
    private var timer: Timer?
    /// Each plugin's images by id, at most 8 a plugin.
    private var images: [String: [String: NSImage]] = [:]

    /// Replaces `pluginId`'s images; none drops them.
    func register(pluginId: String, images list: [DockImage]) {
        var byId: [String: NSImage] = [:]
        for d in list { byId[d.id] = Self.image(d) }
        images[pluginId] = byId.isEmpty ? nil : byId
        if shown?.plugin == pluginId { apply() }
    }

    func show(pluginId: String, image: String?, badge: UInt32?, blink: String?) {
        shown = image == nil && badge == nil ? nil : Shown(plugin: pluginId, image: image, badge: badge, blink: blink)
        apply()
    }

    /// Haunt's own icon and no badge, and no plugin's images, as when the plugins reload.
    func reset() {
        shown = nil
        images = [:]
        apply()
    }

    private func apply() {
        timer?.invalidate()
        timer = nil
        let s = enabled ? shown : nil
        let byId = s.flatMap { images[$0.plugin] }
        let image = s?.image.flatMap { byId?[$0] }
        // nil puts the bundle's icon back.
        NSApp.applicationIconImage = image
        NSApp.dockTile.badgeLabel = s?.badge.map(String.init)
        guard let image, let blink = s?.blink.flatMap({ byId?[$0] }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.blinkEvery, repeats: true) { [weak self] t in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            NSApp.applicationIconImage = blink
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.blinkFor) {
                if self?.timer === t { NSApp.applicationIconImage = image }
            }
        }
    }

    /// The pixels the core decoded, as an image; no ImageIO. One whose size doesn't add up is dropped and logged.
    static func image(_ d: DockImage) -> NSImage? {
        let (w, h) = (Int(d.width), Int(d.height))
        guard (1...pixelsMax).contains(w), (1...pixelsMax).contains(h), d.rgba.count == w * h * 4,
              let provider = CGDataProvider(data: d.rgba as CFData), let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: srgb,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            AppDelegate.logger.error("plugin dock image \(d.id, privacy: .public) is not \(w)×\(h) RGBA pixels; dropped")
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
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
    private enum Shown { case noLabel, needs, row(surface: String, head: String, since: Date) }
    /// Shown while set.
    private var shown: Shown?
    /// The tabs that need you, as of the last sidebar snapshot.
    private var needing: Set<String> = []
    private var panel: GlowPanel?
    /// Counts a row label's waiting time on.
    private var ticker: Timer?
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
        ticker?.invalidate()
        for (center, o) in observers { center.removeObserver(o) }
        if let o = anchorObserver { NotificationCenter.default.removeObserver(o) }
    }

    func show(_ label: GlowLabel) {
        switch label {
        case .noLabel: shown = .noLabel
        case .needs: shown = .needs
        case let .row(surface, head, waitedSecs):
            shown = .row(surface: surface, head: head, since: Date(timeIntervalSinceNow: -TimeInterval(waitedSecs)))
        }
        apply()
    }

    /// The tabs that need you, from each sidebar snapshot: the count follows it, and a row label whose tab no
    /// longer needs you becomes the count.
    func needYou(_ surfaces: Set<String>) {
        guard surfaces != needing else { return }
        needing = surfaces
        switch shown {
        case let .row(surface, _, _) where !surfaces.contains(surface):
            shown = .needs
            apply()
        case .needs where enabled && showsLabel:
            panel?.glow.setLabel(text)
        default: break
        }
    }

    func hide() {
        shown = nil
        apply()
    }

    /// Haunt's words, never the plugin's, cut to 32 characters.
    static func label(count: Int) -> String? {
        switch count {
        case ...0: nil
        case 1: "1 needs you"
        case 100...: "99+ need you"
        default: "\(count) need you"
        }
    }

    static func label(head: String, waited: TimeInterval) -> String {
        String("\(head) · \(elapsed(waited))".prefix(32))
    }

    /// "42s", "1m12s", "2h05m".
    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h\(String(format: "%02d", s / 60 % 60))m"
    }

    private var text: String? {
        switch shown {
        case .noLabel: nil
        case .needs: Self.label(count: needing.count)
        case let .row(_, head, since): Self.label(head: head, waited: Date().timeIntervalSince(since))
        case nil: nil
        }
    }

    private func apply() {
        ticker?.invalidate()
        ticker = nil
        guard enabled, shown != nil, let screen = anchor?.screen ?? NSScreen.main else {
            panel?.orderOut(nil)
            return
        }
        if case .row = shown, showsLabel {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.showsLabel else { return }
                self.panel?.glow.setLabel(self.text)
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        }
        let p = panel ?? GlowPanel()
        panel = p
        let f = screen.frame
        // The label sits under the menu bar, never on its items.
        let menuBar = f.maxY - screen.visibleFrame.maxY
        let height = menuBar + ceil(Self.font.ascender - Self.font.descender) + 8
        p.setFrame(NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height), display: false)
        p.glow.update(label: showsLabel ? text : nil, below: menuBar + 4, scale: screen.backingScaleFactor,
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
    /// Only the text, so the breathing carries on.
    func setLabel(_ label: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.string = label ?? ""
        text.isHidden = label == nil
        CATransaction.commit()
    }

    func update(label: String?, below: CGFloat, scale: CGFloat, breathe: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        line.frame = NSRect(x: 0, y: b.maxY - Self.line, width: b.width, height: Self.line)
        halo.frame = NSRect(x: 0, y: b.maxY - Self.line - Self.halo, width: b.width, height: Self.halo)
        let h = ceil(PluginGlow.font.ascender - PluginGlow.font.descender) + 2
        text.frame = NSRect(x: b.width / 2, y: b.maxY - below - h, width: b.width / 2 - Self.inset, height: h)
        text.contentsScale = scale
        CATransaction.commit()
        setLabel(label)
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
