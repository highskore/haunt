import AVFoundation

/// Plugins' sounds and speech (`HostRequest.playSound`, `.ambient`, `.say`, `.stopSpeech`). Chime and bell
/// are the system's Glass and Ping; rain is made here. `[sound] plugins = false` silences all of it.
final class PluginSound {
    var enabled = true {
        didSet { if !enabled { stopAll() } }
    }
    private let engine = AVAudioEngine()
    private var buffers: [SoundName: AVAudioPCMBuffer] = [:]
    /// Each plugin's one loop.
    private var loops: [String: AVAudioPlayerNode] = [:]
    private var shots = 0
    private var idle: DispatchWorkItem?
    private let speaker = AVSpeechSynthesizer()
    private var speaking: String?

    func play(pluginId: String, sound: SoundName, pitch: Int32, volume: Float) {
        guard enabled, let buf = buffer(sound), start() else { return }
        let (player, shift) = (AVAudioPlayerNode(), AVAudioUnitTimePitch())
        shift.pitch = Float(pitch) * 100
        attach(player, shift, format: buf.format)
        player.volume = volume
        shots += 1
        player.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.engine.detach(player)
                self.engine.detach(shift)
                self.shots -= 1
                self.stopWhenIdle()
            }
        }
        player.play()
    }

    func ambient(pluginId: String, sound: SoundName, level: Float) {
        if let old = loops.removeValue(forKey: pluginId) {
            old.stop()
            engine.detach(old)
        }
        guard enabled, level > 0, let buf = buffer(sound), start() else { return stopWhenIdle() }
        let player = AVAudioPlayerNode()
        attach(player, nil, format: buf.format)
        player.volume = level
        player.scheduleBuffer(buf, at: nil, options: .loops)
        player.play()
        loops[pluginId] = player
    }

    /// Cuts off whatever is being said.
    func say(pluginId: String, text: String) {
        guard enabled else { return }
        speaker.stopSpeaking(at: .immediate)
        speaker.speak(AVSpeechUtterance(string: text))
        speaking = pluginId
    }

    func stopSpeech(pluginId: String) {
        guard speaking == pluginId else { return }
        speaker.stopSpeaking(at: .immediate)
        speaking = nil
    }

    func stopAll() {
        for id in Array(loops.keys) { ambient(pluginId: id, sound: .rain, level: 0) }
        speaker.stopSpeaking(at: .immediate)
        speaking = nil
    }

    private func attach(_ player: AVAudioPlayerNode, _ shift: AVAudioUnitTimePitch?, format: AVAudioFormat) {
        engine.attach(player)
        if let shift {
            engine.attach(shift)
            engine.connect(player, to: shift, format: format)
            engine.connect(shift, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    private func start() -> Bool {
        idle?.cancel()
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            AppDelegate.logger.error("plugin sound: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The output device stays awake while the engine runs, so it stops once nothing plays.
    private func stopWhenIdle() {
        guard shots == 0, loops.isEmpty, engine.isRunning else { return }
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.shots == 0, self.loops.isEmpty else { return }
            self.engine.stop()
        }
        idle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func buffer(_ sound: SoundName) -> AVAudioPCMBuffer? {
        if let b = buffers[sound] { return b }
        let b: AVAudioPCMBuffer?
        switch sound {
        case .chime: b = Self.load("/System/Library/Sounds/Glass.aiff")
        case .bell: b = Self.load("/System/Library/Sounds/Ping.aiff")
        case .rain: b = Self.rain()
        }
        buffers[sound] = b
        return b
    }

    private static func load(_ path: String) -> AVAudioPCMBuffer? {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil else { return nil }
        return b
    }

    /// Four seconds of soft low-passed noise with sparse droplets, seamless when looped.
    static func rain(seconds: Double = 4, rate: Double = 44_100) -> AVAudioPCMBuffer? {
        let n = Int(seconds * rate)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)),
              let out = b.floatChannelData?[0] else { return nil }
        b.frameLength = AVAudioFrameCount(n)
        var rng = SystemRandomNumberGenerator()
        var low: Float = 0
        for i in 0..<n {
            low += 0.08 * (Float.random(in: -1...1, using: &rng) - low)
            out[i] = low * 0.5
        }
        // Fades the start into the end so the loop has no seam.
        let fade = Int(rate * 0.05)
        for i in 0..<fade {
            let t = Float(i) / Float(fade)
            out[i] = out[i] * t + out[n - fade + i] * (1 - t)
        }
        let drops = Int(seconds * 14)
        for _ in 0..<drops {
            let len = Int(rate * 0.03)
            let at = Int.random(in: 0..<(n - fade - len), using: &rng)
            let freq = Float.random(in: 1800...4200, using: &rng), amp = Float.random(in: 0.04...0.14, using: &rng)
            for j in 0..<len {
                let t = Float(j) / Float(rate)
                out[at + j] += amp * sin(2 * .pi * freq * t) * exp(-t * 160)
            }
        }
        b.frameLength = AVAudioFrameCount(n - fade)
        return b
    }
}
