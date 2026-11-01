import AppKit
import Foundation

/// The only file that turns Ghostty notifications into haunt-core events.
final class HauntBridge {
    private let log: FileHandle?
    private let plugin: PluginHandle?
    private(set) var intake: HauntIntake?

    init() {
        let dir = (("~/.haunt/logs") as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/events.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        log = FileHandle(forWritingAtPath: path)
        log?.seekToEndOfFile()

        var loaded: PluginHandle?
        if let wasm = Bundle.main.url(forResource: "hello", withExtension: "wasm", subdirectory: "plugins") {
            let cache = ("~/.haunt/cache" as NSString).expandingTildeInPath
            do {
                loaded = try PluginHandle.load(wasmPath: wasm.path, cacheDir: cache)
            } catch {
                loaded = nil
            }
        }
        plugin = loaded
        write("start plugin=\(plugin.map { String(describing: $0.stats()) } ?? "none")")

        do {
            intake = try HauntIntake.bind(dir: ("~/.haunt" as NSString).expandingTildeInPath, listener: IntakeLog(bridge: self))
            write("intake listening at \(intake!.path())")
        } catch {
            write("intake failed: \(error)")
        }

        Ghostty.App.desktopNotificationHook = { [weak self] view, title, body in
            self?.handle(surface: view.id, title: title, body: body) ?? false
        }
    }

    private func handle(surface: UUID, title: String, body: String) -> Bool {
        do {
            let event = try parseOsc(title: title, body: body)
            let deco = try plugin?.onEvent(event: event)
            write("event surface=\(surface) bytes=\(body.utf8.count) kind=\(eventName(event: event)) decoration=\(String(describing: deco)) plugin_logs=\(plugin?.takeLogs() ?? [])")
            return true
        } catch ParseError.NotAgentTitle {
            write("notify surface=\(surface) title=\(title) bytes=\(body.utf8.count)")
            return false
        } catch {
            write("reject surface=\(surface) bytes=\(body.utf8.count) error=\(error) tail=\(body.suffix(40))")
            return true
        }
    }

    /// Socket deliveries; `verified` gates everything beyond status.
    fileprivate func handle(_ d: Delivery) {
        if let event = d.event {
            let deco = try? plugin?.onEvent(event: event)
            // Spike-only visible proof that Swift got the event.
            NSApp.windows.first { $0.contentView is Ghostty.SurfaceView }?.title = "haunt · \(eventName(event: event)) · \(d.verified ? "verified" : "status-only")"
            write("sock surface=\(d.surfaceId) verified=\(d.verified) bytes=\(d.bytes) dropped_before=\(d.droppedBefore) kind=\(eventName(event: event)) decoration=\(String(describing: deco ?? nil))")
        } else {
            write("sock-reject surface=\(d.surfaceId) bytes=\(d.bytes) error=\(d.error ?? "?")")
        }
    }

    func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        log?.write("\(stamp) \(line)\n".data(using: .utf8)!)
    }
}

private final class IntakeLog: IntakeListener, @unchecked Sendable {
    private weak var bridge: HauntBridge?
    init(bridge: HauntBridge) { self.bridge = bridge }

    func onDelivery(delivery: Delivery) {
        DispatchQueue.main.async { [weak bridge] in bridge?.handle(delivery) }
    }
}
