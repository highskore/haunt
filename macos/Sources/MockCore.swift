import Foundation

#if HAUNT_FIXTURES
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
    /// Bumped on every change, as the core's is.
    private var version: UInt64 = 1

    init(fixture: Fixture?) {
        self.fixture = fixture
    }

    func start() throws {}

    func registerSurface(cwd: String) throws -> SurfaceEnv {
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

    /// Called off the main queue, as the real core is; the mock's state lives on main.
    func setSurfaceInfo(surfaceId: String, title: String, cwd: String, gitBranch: String?) {
        DispatchQueue.main.async { self.applySurfaceInfo(surfaceId: surfaceId, title: title, cwd: cwd, gitBranch: gitBranch) }
    }

    private func applySurfaceInfo(surfaceId: String, title: String, cwd: String, gitBranch: String?) {
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

    func answerPermission(surfaceId: String, requestKey: UInt64, allow: Bool) -> Data? { nil }

    func onUserInput(surfaceId: String) {}

    func gatePluginRequest(request: HostRequest) -> PtyWrite? { nil }

    func snapshotIfNewer(version: UInt64) -> SidebarSnapshot? {
        version == self.version ? nil : snapshot()
    }

    func snapshot() -> SidebarSnapshot {
        var snap = rawSnapshot()
        snap.version = version
        return snap
    }

    private func rawSnapshot() -> SidebarSnapshot {
        if let fixture { return fixture.snapshot(surfaceIds: surfaces.map(\.id), selected: selectedId) }
        let shell = ((ProcessInfo.processInfo.environment["SHELL"] ?? "zsh") as NSString).lastPathComponent
        let rows = surfaces.map { s in
            Row(surfaceId: s.id, kind: .shell, name: (s.cwd as NSString).lastPathComponent,
                meta: "\((s.cwd as NSString).abbreviatingWithTildeInPath) · \(shell)",
                statusText: "", needsYou: false, progress: nil, subagents: [], selected: s.id == selectedId, pending: nil, color: nil)
        }
        return SidebarSnapshot(groups: rows.isEmpty ? [] : [SidebarGroup(id: "idle", label: "IDLE", rows: rows)], colorStyle: .dot)
    }

    private func notify() {
        version += 1
        listener?.changed()
    }
}
#endif
