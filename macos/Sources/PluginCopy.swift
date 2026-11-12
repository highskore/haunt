import AppKit

/// What a plugin put on the clipboard (`clipboard.write`): the item carries a private type naming the
/// plugin, so Haunt's paste check can always show a multi-line one before it reaches a terminal.
enum PluginCopy {
    static let type = NSPasteboard.PasteboardType("dev.haunt.plugin-copy")

    static func write(_ text: String, pluginId: String, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(pluginId, forType: type)
        pb.writeObjects([item])
    }

    /// The plugin that wrote what `pb` holds, if a plugin did (anything copied since clears the tag).
    static func source(_ pb: NSPasteboard) -> String? {
        pb.string(forType: type).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The note at the sidebar's foot after a write.
    static func toast(name: String, text: String) -> String {
        let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(name) copied \(n) \(n == 1 ? "line" : "lines")"
    }
}
