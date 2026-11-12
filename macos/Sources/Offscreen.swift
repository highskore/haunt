#if HAUNT_FIXTURES
import AppKit

/// HAUNT_OFFSCREEN=1: every window is fully transparent and lets clicks through from the moment it is ordered
/// in, so a capture never shows on screen. HAUNT_SNAPSHOT=<png> then draws the main window, with the windows
/// over it (the palette), into that file at 2× and quits.
enum Offscreen {
    static let on = ProcessInfo.processInfo.environment["HAUNT_OFFSCREEN"] == "1"

    /// Before any window exists: all ordering goes through `order(_:relativeTo:)`.
    static func install() {
        guard on, let a = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:))),
              let b = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.offscreenOrder(_:relativeTo:))) else { return }
        method_exchangeImplementations(a, b)
    }

    static func snapshot(_ main: NSWindow) {
        guard on, let path = ProcessInfo.processInfo.environment["HAUNT_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let size = main.frame.size
            let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            out.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            let others = NSApp.orderedWindows.reversed().filter { $0 !== main && $0.isVisible && $0.frame.intersects(main.frame) }
            for w in [main] + others {
                guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                let at = NSPoint(x: w.frame.minX - main.frame.minX, y: w.frame.minY - main.frame.minY)
                rep.draw(in: NSRect(origin: at, size: w.frame.size), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: false, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}

extension NSWindow {
    /// Swapped in for `order(_:relativeTo:)` by `Offscreen.install`; calls the original.
    @objc func offscreenOrder(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        alphaValue = 0
        ignoresMouseEvents = true
        offscreenOrder(place, relativeTo: other)
    }
}
#endif
