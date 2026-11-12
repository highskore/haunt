import Foundation
import GhosttyKit

/// `terminal.read`: a tab's visible lines, only on the main thread, where the plugin calls run.
final class TabScreenReader: TabScreen, @unchecked Sendable {
    private let text: (String) -> String?

    init(_ text: @escaping (String) -> String?) {
        self.text = text
    }

    func read(surfaceId: String, lines: UInt32) -> [String]? {
        guard Thread.isMainThread, let t = text(surfaceId) else { return nil }
        return Self.lastLines(t, lines)
    }

    /// The last `n` lines of `text`, blank ones below the last text dropped.
    static func lastLines(_ text: String, _ n: UInt32) -> [String] {
        var all = text.components(separatedBy: "\n")
        while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
        return Array(all.suffix(Int(n)))
    }
}

extension TabStore {
    /// What tab `surfaceId` shows now, as Ghostty reads its viewport.
    func visibleText(_ surfaceId: String) -> String? {
        guard let surface = tab(surfaceId)?.view.surface else { return nil }
        let corner = { (c: ghostty_point_coord_e) in ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: c, x: 0, y: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, ghostty_selection_s(top_left: corner(GHOSTTY_POINT_COORD_TOP_LEFT),
                                                                     bottom_right: corner(GHOSTTY_POINT_COORD_BOTTOM_RIGHT),
                                                                     rectangle: false), &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
}
