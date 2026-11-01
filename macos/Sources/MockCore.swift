import Foundation

/// Stand-in for haunt-core until the UniFFI bindings land: shells only, or a mockup fixture.
final class MockCore: CoreAPI {
    private struct Surface {
        var id: String
        var title = ""
        var cwd: String
        var branch: String?
    }

    private let fixture: Fixture?
    private var surfaces: [Surface] = []
    private var nextId = 1
    private var selectedId: String?
    private weak var listener: CoreListener?

    init(fixture: Fixture?) {
        self.fixture = fixture
    }

    func start() throws {}

    func registerSurface(cwd: String) -> SurfaceEnv {
        let id = "s\(nextId)"
        nextId += 1
        surfaces.append(Surface(id: id, cwd: cwd))
        notify()
        let sock = (NSHomeDirectory() as NSString).appendingPathComponent(".haunt/sock")
        return SurfaceEnv(surfaceId: id, nonce: UUID().uuidString, socketPath: sock)
    }

    func unregisterSurface(surfaceId: String) {
        surfaces.removeAll { $0.id == surfaceId }
        notify()
    }

    func setSurfaceInfo(surfaceId: String, title: String, cwd: String, gitBranch: String?) {
        guard let i = surfaces.firstIndex(where: { $0.id == surfaceId }) else { return }
        let next = Surface(id: surfaceId, title: title, cwd: cwd, branch: gitBranch)
        guard surfaces[i].title != next.title || surfaces[i].cwd != next.cwd || surfaces[i].branch != next.branch else { return }
        surfaces[i] = next
        notify()
    }

    func selectSurface(surfaceId: String) {
        selectedId = surfaceId
        notify()
    }

    func onOscNotification(surfaceId: String, title: String, body: String) {
        AppDelegate.logger.notice("mock core: osc surface=\(surfaceId, privacy: .public) title=\(title, privacy: .public) bytes=\(body.utf8.count)")
    }

    func setListener(listener: CoreListener) {
        self.listener = listener
    }

    func answerPermission(surfaceId: String, allow: Bool) -> Data? { nil }

    func snapshot() -> SidebarSnapshot {
        if let fixture { return fixture.snapshot(surfaceIds: surfaces.map(\.id), selected: selectedId) }
        let shell = ((ProcessInfo.processInfo.environment["SHELL"] ?? "zsh") as NSString).lastPathComponent
        let rows = surfaces.map { s in
            Row(surfaceId: s.id, kind: .shell, name: (s.cwd as NSString).lastPathComponent,
                meta: "\((s.cwd as NSString).abbreviatingWithTildeInPath) · \(shell)",
                statusText: "", needsYou: false, progress: nil, subagents: [], selected: s.id == selectedId)
        }
        return SidebarSnapshot(groups: rows.isEmpty ? [] : [SidebarGroup(label: "IDLE", rows: rows)])
    }

    private func notify() {
        listener?.changed()
    }
}
