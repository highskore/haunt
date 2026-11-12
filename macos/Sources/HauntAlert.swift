import AppKit

/// Haunt's own icon, copied at launch before any plugin runs: a plugin's Dock picture replaces
/// `applicationIconImage`, which an NSAlert shows unless given an icon.
enum HauntIcon {
    static let image: NSImage = NSApp.applicationIconImage.copy() as? NSImage ?? NSImage()
}

extension NSAlert {
    /// An alert with Haunt's icon, never a plugin's picture.
    static func haunt() -> NSAlert {
        let alert = NSAlert()
        alert.icon = HauntIcon.image
        return alert
    }
}
