import AppKit

/// A plugin's Dock tile (`HostRequest.dockImages`, `.dockShow`): its whole image per state, the count badge,
/// and a blink image shown briefly every few seconds, never under Reduce Motion. The core lets one plugin
/// have the tile at a time and has already checked each image is a PNG of a sane size.
final class PluginDock {
    private var images: [String: [String: NSImage]] = [:]
    private var blink: Timer?
    private var showing: NSImage?

    func setImages(pluginId: String, images list: [DockImage]) {
        images[pluginId] = Dictionary(list.compactMap { i in NSImage(data: i.png).map { (i.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    func show(pluginId: String, image: String?, badge: UInt32?, blink blinkId: String?) {
        blink?.invalidate()
        blink = nil
        let mine = images[pluginId] ?? [:]
        showing = image.flatMap { mine[$0] }
        NSApp.applicationIconImage = showing
        NSApp.dockTile.badgeLabel = badge.map { $0 > 9999 ? "9999+" : String($0) }
        guard let flash = blinkId.flatMap({ mine[$0] }) else { return }
        blink = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            NSApp.applicationIconImage = flash
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.blink != nil else { return }
                NSApp.applicationIconImage = self.showing
            }
        }
    }

    /// Haunt's own icon, no badge.
    func reset() {
        images = [:]
        show(pluginId: "", image: nil, badge: nil, blink: nil)
    }
}
