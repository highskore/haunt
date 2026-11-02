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
    /// nil while nothing changed since the snapshot with `version`.
    func snapshotIfNewer(version: UInt64) -> SidebarSnapshot?
    func setListener(listener: CoreListener)
    func answerPermission(surfaceId: String, requestKey: UInt64, allow: Bool) -> Data?
    func onUserInput(surfaceId: String)
    func reviewTurn(surfaceId: String) -> ReviewTurn?
    func gatePluginRequest(request: HostRequest) -> PtyWrite?
}

/// `HauntPlugins` as the UI uses it.
protocol PluginsAPI: AnyObject {
    func loadErrors() -> [String]
    func paletteItems(mode: String?, query: String) -> [PaletteItem]
    func invokePaletteItem(pluginId: String, itemId: String) throws
    func takeRequests() -> [HostRequest]
    func rowMenuItems(surfaceId: String) -> [RowMenuItem]
    func invokeRowMenuItem(pluginId: String, itemId: String, surfaceId: String) throws
    func rowMoved(surfaceId: String, groupId: String, beforeSurfaceId: String?)
}

#if HAUNT_REAL_CORE
extension HauntCore: CoreAPI {}
extension HauntPlugins: PluginsAPI {}

/// Installs the app's own plugins from `bundledDir`, then loads them all over `core`; call after `core.start()`.
func loadPlugins(hauntDir: String, core: CoreAPI, bundledDir: String?) throws -> PluginsAPI? {
    guard let core = core as? HauntCore else { return nil }
    return try HauntPlugins.load(hauntDir: hauntDir, core: core, bundledDir: bundledDir)
}

#if HAUNT_FIXTURES
private var fixtureCore: HauntCore?

/// The log palettes in the real build: the bundled decision-log plugin over a throwaway core that holds
/// the fixture's decisions, so the rows come through the real plugin host.
func fixturePlugins(_ fixture: Fixture, bundledDir: String?) throws -> PluginsAPI? {
    guard fixture.hasLog else { return nil }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("haunt-fixture-plugins-\(getpid())")
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // The log file is oldest first.
    let lines = try fixture.decisions().reversed().map { d in
        var o: [String: Any] = ["at_ms": d.atMs, "surface_id": d.surfaceId, "tool": d.tool, "preview": d.preview]
        o["command"] = d.command
        o["cwd"] = d.cwd
        switch d.agent {
        case .claude: o["agent"] = "claude"
        case .codex: o["agent"] = "codex"
        case let .other(id): o["agent"] = id
        }
        switch d.outcome {
        case .allowedInHaunt: o["outcome"] = "allowed_in_haunt"
        case .deniedInHaunt: o["outcome"] = "denied_in_haunt"
        case let .allowedByPlugin(id): o["outcome"] = ["allowed_by_plugin": ["plugin_id": id]]
        case let .deniedByPlugin(id): o["outcome"] = ["denied_by_plugin": ["plugin_id": id]]
        case .answeredInTerminal: o["outcome"] = "answered_in_terminal"
        case .superseded: o["outcome"] = "superseded"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    fm.createFile(atPath: dir.appendingPathComponent("decisions.jsonl").path,
                  contents: Data((lines.joined(separator: "\n") + "\n").utf8), attributes: [.posixPermissions: 0o600])
    let core = HauntCore(configDir: dir.path)
    try core.start()
    fixtureCore = core
    return try HauntPlugins.load(hauntDir: dir.path, core: core, bundledDir: bundledDir)
}
#endif
#else
func loadPlugins(hauntDir: String, core: CoreAPI, bundledDir: String?) throws -> PluginsAPI? { NoPlugins() }

func fixturePlugins(_ fixture: Fixture, bundledDir: String?) throws -> PluginsAPI? {
    fixture.hasLog ? FixturePlugins(fixture: fixture) : nil
}

final class NoPlugins: PluginsAPI {
    func loadErrors() -> [String] { [] }
    func paletteItems(mode: String?, query: String) -> [PaletteItem] { [] }
    func invokePaletteItem(pluginId: String, itemId: String) throws {}
    func takeRequests() -> [HostRequest] { [] }
    func rowMenuItems(surfaceId: String) -> [RowMenuItem] { [] }
    func invokeRowMenuItem(pluginId: String, itemId: String, surfaceId: String) throws {}
    func rowMoved(surfaceId: String, groupId: String, beforeSurfaceId: String?) {}
}

/// The decision-log plugin's `log` mode over the fixture's decisions, worded as the plugin words them.
final class FixturePlugins: PluginsAPI {
    private static let id = "dev.haunt.decision-log"
    private let fixture: Fixture

    init(fixture: Fixture) {
        self.fixture = fixture
    }

    func loadErrors() -> [String] { [] }
    func invokePaletteItem(pluginId: String, itemId: String) throws {}
    func takeRequests() -> [HostRequest] { [] }
    func rowMenuItems(surfaceId: String) -> [RowMenuItem] { [] }
    func invokeRowMenuItem(pluginId: String, itemId: String, surfaceId: String) throws {}
    func rowMoved(surfaceId: String, groupId: String, beforeSurfaceId: String?) {}

    func paletteItems(mode: String?, query: String) -> [PaletteItem] {
        guard let mode else {
            return [PaletteItem(pluginId: Self.id, id: "log", title: "log", subtitle: "Search the decision log",
                                defaultKey: nil, isMode: true, atMs: nil, mark: nil, surfaceId: nil)]
        }
        guard mode == "log" else { return [] }
        return fixture.decisions().enumerated().map { i, d in
            let what = d.tool == "Bash" ? d.preview : "\(d.tool) \(d.preview)"
            let agent: String? = switch d.agent {
            case .claude: nil
            case .codex: "Codex"
            case let .other(id): id
            }
            let place = [d.cwd.map { ($0 as NSString).lastPathComponent }, agent].compactMap { $0 }.joined(separator: " · ")
            return PaletteItem(pluginId: Self.id, id: "\(d.atMs)-\(i)", title: "\(Self.phrase(d.outcome)) \(what)",
                               subtitle: place.isEmpty ? nil : place, defaultKey: nil, isMode: false,
                               atMs: d.atMs, mark: Self.mark(d.outcome), surfaceId: d.surfaceId)
        }
    }

    private static func phrase(_ o: Outcome) -> String {
        switch o {
        case .allowedInHaunt: return "You approved"
        case .deniedInHaunt: return "You denied"
        case let .allowedByPlugin(id): return "\(id) approved"
        case let .deniedByPlugin(id): return "\(id) denied"
        case .answeredInTerminal: return "Allowed in terminal:"
        case .superseded: return "Superseded:"
        }
    }

    private static func mark(_ o: Outcome) -> Mark {
        switch o {
        case .allowedInHaunt, .deniedInHaunt, .answeredInTerminal: return .open
        case .allowedByPlugin, .deniedByPlugin: return .filled
        case .superseded: return .round
        }
    }
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
    var colorStyle: ColorStyle
    var version: UInt64 = 0
    var nextTickMs: UInt64?
}

struct SidebarGroup: Equatable, Hashable {
    var id: String
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
    var color: TabColor?
}

enum TabColor: Equatable, Hashable {
    case red, orange, yellow, green, blue, purple, gray
}

enum ColorStyle: Equatable, Hashable {
    case dot, tint
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
    var atMs: UInt64?
    var mark: Mark?
    var surfaceId: String?
}

struct RowMenuItem: Equatable, Hashable {
    var pluginId: String
    var id: String
    var title: String
    var checked: Bool
    var parent: String?
}

enum Mark: Equatable, Hashable {
    case open, filled, round
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

enum CommandOutcome: Equatable, Hashable {
    case running
    case passed
    case failed
    case unknown
}

struct TurnCommand: Equatable, Hashable {
    var command: String
    var outcome: CommandOutcome
}

struct TurnTask: Equatable, Hashable {
    var subject: String
    var status: String
}

struct TurnSubagent: Equatable, Hashable {
    var label: String
    var toolCount: UInt64?
    var durationMs: UInt64?
}

struct ReviewTurn: Equatable, Hashable {
    var agent: Agent
    var number: UInt32
    var prompt: String?
    var cwd: String?
    var startedMs: UInt64?
    var finishedMs: UInt64?
    var failed: Bool
    var headAtStart: String?
    var toolCount: UInt32
    var editCount: UInt32
    var tasks: [TurnTask]
    var commands: [TurnCommand]
    var files: [String]
    var subagents: [TurnSubagent]
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
