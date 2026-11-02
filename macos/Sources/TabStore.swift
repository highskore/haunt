import AppKit
import Combine
import GhosttyKit

/// One sidebar row: a libghostty surface registered with the core.
final class Tab {
    let env: SurfaceEnv
    let view: Ghostty.SurfaceView
    /// Ghostty's scroll wrapper; it is what tells the surface its size.
    let host: SurfaceScrollView
    var subscriptions: [AnyCancellable] = []

    init(env: SurfaceEnv, view: Ghostty.SurfaceView, size: CGSize) {
        self.env = env
        self.view = view
        host = SurfaceScrollView(contentSize: size, surfaceView: view)
    }
}

/// The window's tabs, which one is selected, and the names given with Rename Tab.
final class TabStore {
    private(set) var tabs: [Tab] = []
    var selectedId: String?
    /// Names given with Rename Tab, for the life of the tab. They replace only the row title.
    var customNames: [String: String] = [:]

    var selected: Tab? { selectedId.flatMap(tab) }

    func tab(_ id: String) -> Tab? { tabs.first { $0.env.surfaceId == id } }

    func tab(for view: Ghostty.SurfaceView) -> Tab? { tabs.first { $0.view === view } }

    func add(_ tab: Tab) { tabs.append(tab) }

    func remove(_ tab: Tab) {
        tabs.removeAll { $0 === tab }
        customNames[tab.env.surfaceId] = nil
    }

    func removeAll() { tabs.removeAll() }

    /// `snap` with the custom names in place of the rows' own.
    func named(_ snap: SidebarSnapshot) -> SidebarSnapshot {
        guard !customNames.isEmpty else { return snap }
        var snap = snap
        for g in snap.groups.indices {
            for r in snap.groups[g].rows.indices {
                if let n = customNames[snap.groups[g].rows[r].surfaceId] { snap.groups[g].rows[r].name = n }
            }
        }
        return snap
    }

    /// Writes bytes the core handed back for a surface, as `ghostty_surface_text` does for typed text.
    func write(_ bytes: Data, to surfaceId: String) {
        guard !bytes.isEmpty, let surface = tab(surfaceId)?.view.surface else { return }
        bytes.withUnsafeBytes { buf in
            guard let p = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, p, UInt(buf.count))
        }
    }
}
