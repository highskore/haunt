import AppKit
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
