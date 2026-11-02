import Foundation

/// The haunt-core UniFFI object as the UI uses it; `HauntCore` (real) and `MockCore` both conform.
protocol CoreAPI: AnyObject {
    func start() throws
    func registerSurface(cwd: String) throws -> SurfaceEnv
    func unregisterSurface(surfaceId: String)
    func setSurfaceInfo(surfaceId: String, title: String, cwd: String, gitBranch: String?)
    func selectSurface(surfaceId: String)
    func onOscNotification(surfaceId: String, title: String, body: String)
    func snapshot() -> SidebarSnapshot
    func setListener(listener: CoreListener)
    func answerPermission(surfaceId: String, requestKey: UInt64, allow: Bool) -> Data?
    func onUserInput(surfaceId: String)
    func decisions(query: String, limit: UInt32) -> [Decision]
    func gatePluginRequest(request: HostRequest) -> PtyWrite?
}

/// `HauntPlugins` as the UI uses it; the mock build has no plugin host.
protocol PluginsAPI: AnyObject {
    func loadErrors() -> [String]
    func paletteItems(mode: String?, query: String) -> [PaletteItem]
    func invokePaletteItem(pluginId: String, itemId: String) throws
    func takeRequests() -> [HostRequest]
}

#if HAUNT_REAL_CORE
extension HauntCore: CoreAPI {}
extension HauntPlugins: PluginsAPI {}

func loadPlugins(hauntDir: String) throws -> PluginsAPI { try HauntPlugins.load(hauntDir: hauntDir) }
#else
func loadPlugins(hauntDir: String) throws -> PluginsAPI { NoPlugins() }

final class NoPlugins: PluginsAPI {
    func loadErrors() -> [String] { [] }
    func paletteItems(mode: String?, query: String) -> [PaletteItem] { [] }
    func invokePaletteItem(pluginId: String, itemId: String) throws {}
    func takeRequests() -> [HostRequest] { [] }
}

// Mirrors of the records UniFFI generates from the shared contract; the real bindings replace them.

struct SurfaceEnv: Equatable, Hashable {
    var surfaceId: String
    var nonce: String
    var socketPath: String
}

enum CoreError: Error {
    case Insecure(reason: String)
    case Io(reason: String)
    case Invalid(reason: String)
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
    case codex
}

enum Agent: Equatable, Hashable {
    case claude
    case codex
    case other(id: String)
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
    var pending: PendingRequest?
}

struct PendingRequest: Equatable, Hashable {
    var key: UInt64
    var tool: String
    var preview: String
    var suspicious: Bool
}

struct Decision: Equatable, Hashable {
    var atMs: UInt64
    var surfaceId: String
    var tool: String
    var preview: String
    var command: String?
    var cwd: String?
    var outcome: Outcome
    var agent: Agent
}

enum Outcome: Equatable, Hashable {
    case allowedInHaunt
    case deniedInHaunt
    case allowedByPlugin(pluginId: String)
    case deniedByPlugin(pluginId: String)
    case answeredInTerminal
    case superseded
}

struct PaletteItem: Equatable, Hashable {
    var pluginId: String
    var id: String
    var title: String
    var subtitle: String?
    var defaultKey: String?
    var isMode: Bool
}

struct NotifyAction: Equatable, Hashable {
    var id: String
    var title: String
}

enum HostRequest: Equatable, Hashable {
    case notify(pluginId: String, title: String, body: String, actions: [NotifyAction], binding: String?)
    case ptyAnswer(pluginId: String, surface: String, allow: Bool, requestId: UInt64)
}

struct PtyWrite: Equatable, Hashable {
    var surfaceId: String
    var bytes: Data
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
