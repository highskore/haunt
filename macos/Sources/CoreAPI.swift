import Foundation

/// The haunt-core UniFFI object as the UI uses it; `HauntCore` (real) and `MockCore` both conform.
protocol CoreAPI: AnyObject {
    func start() throws
    func registerSurface(cwd: String) -> SurfaceEnv
    func unregisterSurface(surfaceId: String)
    func setSurfaceInfo(surfaceId: String, title: String, cwd: String, gitBranch: String?)
    func selectSurface(surfaceId: String)
    func onOscNotification(surfaceId: String, title: String, body: String)
    func snapshot() -> SidebarSnapshot
    func setListener(listener: CoreListener)
    func answerPermission(surfaceId: String, allow: Bool) -> Data?
}

#if HAUNT_REAL_CORE
extension HauntCore: CoreAPI {}
#else
// Mirrors of the records UniFFI generates from the shared contract; the real bindings replace them.

struct SurfaceEnv: Equatable, Hashable {
    var surfaceId: String
    var nonce: String
    var socketPath: String
}

enum CoreError: Error {
    case Insecure(reason: String)
    case Io(reason: String)
}

struct SidebarSnapshot: Equatable, Hashable {
    var groups: [SidebarGroup]
}

struct SidebarGroup: Equatable, Hashable {
    var label: String
    var rows: [Row]
}

enum RowKind: Equatable, Hashable {
    case shell
    case claude
}

struct Progress: Equatable, Hashable {
    var done: UInt64
    var total: UInt64
}

struct Subrow: Equatable, Hashable {
    var label: String
    var meta: String
}

struct Row: Equatable, Hashable {
    var surfaceId: String
    var kind: RowKind
    var name: String
    var meta: String
    var statusText: String
    var needsYou: Bool
    var progress: Progress?
    var subagents: [Subrow]
    var selected: Bool
}

protocol CoreListener: AnyObject, Sendable {
    func changed()
}
#endif

/// Bridges core change callbacks, which arrive on any thread, onto the main queue.
final class MainQueueListener: CoreListener, @unchecked Sendable {
    private let onChange: () -> Void

    init(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func changed() {
        DispatchQueue.main.async(execute: onChange)
    }
}
