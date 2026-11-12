import AppKit

/// An agent notification (pawr-notif concept 01): `answer` carries Allow / Deny / Open tab, `open` only Open tab.
struct AgentNote: Equatable {
    enum Kind: Equatable { case answer, open }

    var id: String
    var title: String
    var body: String
    var kind: Kind
    var surfaceId: String
    /// The request key the answer actions hand back to the core; nil for `open`.
    var requestKey: UInt64?

    /// The notification's userInfo; the key goes as a string, since userInfo has no UInt64.
    var userInfo: [String: String] {
        var info = ["surfaceId": surfaceId]
        if let requestKey { info["requestKey"] = String(requestKey) }
        return info
    }

    static func target(_ info: [AnyHashable: Any]) -> (surfaceId: String?, requestKey: UInt64?) {
        (info["surfaceId"] as? String, (info["requestKey"] as? String).flatMap { UInt64($0) })
    }
}

enum NoteAction: Equatable { case allow, deny, open }

/// Where notes go: macOS's notification center in the app, a recorder in tests.
protocol NoteCenter: AnyObject {
    /// Replaces a delivered note with the same id.
    func post(_ note: AgentNote)
    func remove(ids: [String])
}

/// Posts a note when an agent needs you or finishes a turn, and takes it back once that is no longer true.
/// Answers go through the core: the pty gets only the bytes `answerPermission` returns for a still-live key.
final class AgentNotifier {
    var settings = NotificationSettings() { didSet { sweep() } }
    /// The menu bar's "Pause all notifications"; not saved.
    var paused = false { didSet { sweep() } }

    private let center: NoteCenter
    private let core: CoreAPI
    private let press: (AnswerKey, String) -> Void
    private let open: (String) -> Void
    private let isFocused: (String) -> Bool

    /// The core's view of the prompt: its key and whether it is terminal-only (`suspicious`), or no request at all.
    private enum Need: Equatable { case key(UInt64, suspicious: Bool), wait }
    private var needs: [String: Need] = [:]
    private var done: Set<String> = []
    private var known: Set<String> = []
    private var posted: Set<String> = []

    init(center: NoteCenter, core: CoreAPI, press: @escaping (AnswerKey, String) -> Void,
         open: @escaping (String) -> Void, isFocused: @escaping (String) -> Bool) {
        self.center = center
        self.core = core
        self.press = press
        self.open = open
        self.isFocused = isFocused
    }

    static func needsId(_ surfaceId: String) -> String { "needs.\(surfaceId)" }
    static func doneId(_ surfaceId: String) -> String { "done.\(surfaceId)" }

    func update(_ snapshot: SidebarSnapshot) {
        let rows = snapshot.groups.flatMap(\.rows).filter { $0.kind != .shell }
        let ids = Set(rows.map(\.surfaceId))
        for gone in known.subtracting(ids) {
            drop(Self.needsId(gone))
            drop(Self.doneId(gone))
            needs[gone] = nil
            done.remove(gone)
        }
        for row in rows {
            let s = row.surfaceId
            let focused = isFocused(s)
            let need: Need? = row.needsYou ? (row.pending.map { .key($0.key, suspicious: $0.suspicious) } ?? .wait) : nil
            if need != needs[s] {
                let old = needs[s]
                needs[s] = need
                switch (old, need) {
                case (_, nil), (.key, .wait):
                    // Answered, or retired by typing at the terminal: the prompt is the terminal's now.
                    drop(Self.needsId(s))
                case (_, .some):
                    if allowed(settings.onPermission, focused) { post(Self.needsNote(row)) } else { drop(Self.needsId(s)) }
                }
            }
            let isDone = row.statusText == "done"
            if isDone != done.contains(s) {
                if isDone {
                    done.insert(s)
                    if known.contains(s), allowed(settings.onDone, focused) { post(Self.doneNote(row)) }
                } else {
                    done.remove(s)
                    drop(Self.doneId(s))
                }
            }
            if focused {
                drop(Self.needsId(s))
                drop(Self.doneId(s))
            }
        }
        known = ids
    }

    /// A click on a note's action. Allow and Deny write only what the core returns; a stale key writes nothing.
    func respond(_ action: NoteAction, surfaceId: String?, requestKey: UInt64?) {
        guard let s = surfaceId else { return }
        switch action {
        case .open:
            open(s)
        case .allow, .deny:
            guard settings.enabled, settings.onPermission, !paused, let key = requestKey,
                  let bytes = core.answerPermission(surfaceId: s, requestKey: key, allow: action == .allow),
                  let answer = AnswerKey(bytes) else { return }
            press(answer, s)
        }
    }

    private func allowed(_ kind: Bool, _ focused: Bool) -> Bool {
        settings.enabled && kind && !paused && !focused
    }

    private func post(_ note: AgentNote) {
        posted.insert(note.id)
        center.post(note)
    }

    private func drop(_ id: String) {
        if posted.remove(id) != nil { center.remove(ids: [id]) }
    }

    /// Takes back every note a settings change or pause has turned off.
    private func sweep() {
        let on = settings.enabled && !paused
        for id in posted where !on || (id.hasPrefix("needs.") && !settings.onPermission) || (id.hasPrefix("done.") && !settings.onDone) {
            drop(id)
        }
    }

    func removeAll() {
        center.remove(ids: Array(posted))
        posted = []
    }

    /// Concept 01's banner: "name · needs approval", then "Tool: preview". Allow/Deny only for what the core marks
    /// answerable; terminal-only (`suspicious`) requests and ones it can't answer at all only open the tab.
    /// `suspicious` can change under the same key, and the note is replaced when it does.
    static func needsNote(_ row: Row) -> AgentNote {
        let name = visible(row.name)
        guard let p = row.pending else {
            return AgentNote(id: needsId(row.surfaceId), title: "\(name) · needs you", body: visible(row.task),
                             kind: .open, surfaceId: row.surfaceId, requestKey: nil)
        }
        let tool = visible(p.tool), preview = visible(p.preview)
        // The core's preview of a non-Bash tool already starts with its name: "Edit /w/a.rs". A Bash preview is the
        // command itself, so "Bash foo" keeps its prefix and never reads as the Bash tool running foo.
        let named = tool != "Bash" && (preview == tool || preview.hasPrefix(tool + " "))
        let full = named ? preview : "\(tool): \(preview)"
        let fits = fitsOneLine(full)
        let answerable = !p.suspicious && fits
        var body = fits ? full : String(full.prefix(clipLength - moreSuffix.count)) + moreSuffix
        if p.suspicious { body += "\nAnswer it in the terminal." }
        return AgentNote(id: needsId(row.surfaceId), title: "\(name) · needs approval", body: body,
                         kind: answerable ? .answer : .open, surfaceId: row.surfaceId,
                         requestKey: answerable ? p.key : nil)
    }

    /// A collapsed banner shows about two 260 pt lines and wraps at words, so a wide or long run can push the end
    /// of a command out of sight. Allow is offered only for printable ASCII that fits on one 240 pt line.
    static let lineWidth: CGFloat = 240
    static let clipLength = 80
    static let moreSuffix = "… (open to see all)"

    /// Measured in semibold, wider than the banner's regular body text, to stay on the safe side.
    static func fitsOneLine(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) }
            && (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width <= lineWidth
    }

    /// `event::visible` in Swift: a newline shows as ⏎, a tab as ⇥, any other hidden character as `\u{…}`.
    static func visible(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            switch c {
            case "\n": out.append("⏎")
            case "\t": out.append("⇥")
            case _ where isHidden(c): out.append(contentsOf: "\\u{\(String(c.value, radix: 16))}".unicodeScalars)
            default: out.append(c)
            }
        }
        return String(out)
    }

    /// `event::is_hidden`: anything but a plain space that is a control, format, whitespace or default-ignorable.
    static func isHidden(_ c: Unicode.Scalar) -> Bool {
        let p = c.properties
        return c != " " && (p.generalCategory == .control || p.generalCategory == .format || p.isWhitespace
            || p.isDefaultIgnorableCodePoint || c.drawsBlank)
    }

    static func doneNote(_ row: Row) -> AgentNote {
        AgentNote(id: doneId(row.surfaceId), title: "\(visible(row.name)) · done", body: visible(row.task), kind: .open,
                  surfaceId: row.surfaceId, requestKey: nil)
    }
}
