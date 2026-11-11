import Foundation

/// A test or build command, from the turn or expected by the project.
struct Check: Equatable {
    enum State: Equatable { case passed, failed, running, unknown, notRun }
    var command: String
    var state: State
    /// Why a check that didn't run is listed: the project file that asks for it, or "full suite".
    var source: String?

    var result: String {
        switch state {
        case .passed: return "passed"
        case .failed: return "failed"
        case .running: return "running"
        case .unknown: return "result unknown"
        case .notRun: return "not run"
        }
    }
}

/// Test and build commands: the ones the agent ran, and the project's standard ones it didn't.
enum Checks {
    private static let tools: [String: Set<String>?] = [
        "cargo": ["test", "build", "check", "clippy", "nextest", "fmt"],
        "swift": ["build", "test"],
        "go": ["test", "build", "vet"],
        "npm": ["test", "run", "t"], "pnpm": ["test", "run", "t", "build", "lint"], "yarn": ["test", "run", "build", "lint"],
        "bun": ["test", "run"],
        "make": nil, "xcodebuild": nil, "swiftlint": nil, "pytest": nil, "tsc": nil, "jest": nil, "vitest": nil,
        "eslint": nil, "ruff": nil, "mypy": nil, "tox": nil, "gradle": nil, "./gradlew": nil, "mvn": nil,
    ]
    private static let runScripts: Set<String> = ["test", "build", "lint", "check", "typecheck", "tsc"]
    private static let wrappers: Set<String> = ["npx", "bunx", "uv", "poetry", "env", "time", "nice"]

    /// The command split on `&&`, `||`, `|`, `|&`, `;`, `&` and newlines outside quotes, each piece with
    /// the operator after it. `&` inside a redirect (`2>&1`, `&>f`) doesn't split.
    static func pieces(_ cmd: String) -> [(text: String, op: String?)] {
        var out: [(String, String?)] = []
        var cur = ""
        var quote: Character?
        let cs = Array(cmd)
        var i = 0
        func cut(_ op: String) { out.append((cur, op)); cur = "" }
        while i < cs.count {
            let c = cs[i], next: Character? = i + 1 < cs.count ? cs[i + 1] : nil
            if let q = quote {
                if c == q { quote = nil } else if c == "\\", q == "\"", let n = next { cur.append(c); cur.append(n); i += 2; continue }
                cur.append(c)
            } else if c == "'" || c == "\"" {
                quote = c
                cur.append(c)
            } else if c == "\\", let n = next {
                cur.append(c); cur.append(n); i += 2; continue
            } else if c == "|" {
                if next == "|" { cut("||"); i += 1 } else if next == "&" { cut("|&"); i += 1 } else { cut("|") }
            } else if c == "&", next == "&" {
                cut("&&"); i += 1
            } else if c == "&", next != ">", !(cur.last == ">" || cur.last == "<") {
                cut("&")
            } else if c == ";" || c == "\n" {
                cut(";")
            } else {
                cur.append(c)
            }
            i += 1
        }
        out.append((cur, nil))
        return out.filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A piece's words without leading env assignments.
    private static func words(_ piece: String) -> [String] {
        var w = piece.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let f = w.first, f.contains("="), !f.hasPrefix("-") { w.removeFirst() }
        return w
    }

    /// The command's segments as words, without env assignments and `cd`.
    static func segments(_ cmd: String) -> [[String]] {
        pieces(cmd).map { words($0.text) }.filter { !$0.isEmpty && $0.first != "cd" }
    }

    static func isCheck(_ cmd: String) -> Bool {
        segments(cmd).contains(where: isCheckSegment)
    }

    /// The last check in the command, as written, for "Rerun …".
    static func checkSegment(_ cmd: String) -> String? {
        pieces(cmd).last { isCheckSegment(words($0.text)) }?.text.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the command's exit status is the check's: it is the last piece, with no pipe, `||`, `;`
    /// or `&` after it (`cargo test | tail` exits with tail's status).
    static func exitIsCheck(_ cmd: String) -> Bool {
        guard let last = pieces(cmd).last, isCheckSegment(words(last.text)) else { return false }
        // A trailing `;` or newline has nothing after it; a trailing `&` puts the check in the background.
        return last.op == nil || last.op == ";"
    }

    private static func isCheckSegment(_ seg: [String]) -> Bool {
        var w = seg[...]
        while let f = w.first, wrappers.contains(f) { w = w.dropFirst(); if f == "uv", w.first == "run" { w = w.dropFirst() } }
        if w.first == "python" || w.first == "python3", w.dropFirst().first == "-m" { w = w.dropFirst(2) }
        guard let tool = w.first else { return false }
        let name = (tool as NSString).lastPathComponent
        if tool.hasSuffix(".sh"), ["test", "build", "check", "lint"].contains(where: name.contains) { return true }
        guard let subs = tools[tool] ?? tools[name] else { return false }
        guard let subs else { return true }
        guard let sub = w.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return false }
        if sub == "run", ["npm", "pnpm", "yarn", "bun"].contains(tool) {
            return w.dropFirst(2).first(where: { !$0.hasPrefix("-") }).map(runScripts.contains) ?? false
        }
        return subs.contains(sub)
    }

    /// The turn's checks, once each, with the outcome of their latest run.
    static func fromTurn(_ commands: [TurnCommand]) -> [Check] {
        var out: [Check] = []
        for c in commands where isCheck(c.command) {
            let state: Check.State
            switch c.outcome {
            // A pass only counts when the check's own status is the command's.
            case .passed: state = exitIsCheck(c.command) ? .passed : .unknown
            case .failed: state = .failed
            case .running: state = .running
            case .unknown: state = .unknown
            }
            // Commands arrive already spelled out (Visible.turn).
            let cmd = c.command
            out.removeAll { $0.command == cmd }
            out.append(Check(command: cmd, state: state))
        }
        return out
    }

    /// Standard checks a project's files ask for: (command, file).
    static func expected(files: Set<String>, packageScripts: Set<String>) -> [(String, String)] {
        var out: [(String, String)] = []
        if files.contains("Cargo.toml") { out.append(("cargo test", "Cargo.toml")) }
        if files.contains("Package.swift") { out.append(("swift test", "Package.swift")) }
        if files.contains("go.mod") { out.append(("go test ./...", "go.mod")) }
        if files.contains("package.json"), packageScripts.contains("test") {
            let pm = files.contains("pnpm-lock.yaml") ? "pnpm" : files.contains("yarn.lock") ? "yarn"
                : files.contains("bun.lockb") || files.contains("bun.lock") ? "bun" : "npm"
            out.append(("\(pm) test", "package.json"))
        }
        for lint in [".swiftlint.yml", ".swiftlint.yaml"] where files.contains(lint) {
            out.append(("swiftlint", lint))
            break
        }
        return out
    }

    private static let narrowing: Set<String> = ["--filter", "-k", "--test", "-p", "--package", "-run", "--lib", "--bin"]

    /// The turn's checks followed by the expected ones it didn't run. A narrowed run (`--filter`, `-p`, …)
    /// doesn't count for the full suite.
    static func merge(turn: [Check], expected: [(String, String)]) -> [Check] {
        var out = turn
        for (cmd, file) in expected {
            let want = cmd.split(separator: " ").map(String.init)
            var narrowed = false
            let ran = turn.contains { c in
                segments(c.command).contains { seg in
                    guard seg.starts(with: want) else { return false }
                    if seg.dropFirst(want.count).contains(where: narrowing.contains) { narrowed = true; return false }
                    return true
                }
            }
            if !ran { out.append(Check(command: cmd, state: .notRun, source: narrowed ? "full suite" : file)) }
        }
        return out
    }

    /// Top-level file names and package.json script names in `root`; reads are small and never follow links.
    static func projectFiles(root: String) -> (Set<String>, Set<String>) {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
        var scripts = Set<String>()
        if names.contains("package.json"),
           let data = readSmallFile((root as NSString).appendingPathComponent("package.json"), max: 256 << 10),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["scripts"] as? [String: Any] {
            scripts = Set(s.keys)
        }
        return (names, scripts)
    }

    private static func readSmallFile(_ path: String, max: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Int(st.st_size) <= max else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(st.st_size))
        let n = read(fd, &buf, buf.count)
        return n >= 0 ? Data(buf[..<n]) : nil
    }
}

/// A line comment, on the new side unless the line was deleted.
struct ReviewComment: Equatable {
    var path: String
    var line: Int
    var deleted: Bool
    var text: String
}

/// The follow-up prompt that comments collect into (version 06).
enum Draft {
    private static let counts = ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]

    static func build(comments: [ReviewComment], note: String = "", rerun: String?) -> String {
        var parts: [String] = []
        let n = comments.count
        if n > 0 {
            let count = n <= counts.count ? counts[n - 1] : String(n)
            parts.append("\(count) change\(n == 1 ? "" : "s") from review:")
            for (i, c) in comments.enumerated() {
                let side = c.deleted ? " (removed line)" : ""
                parts.append("\(i + 1). \(Visible.text((c.path as NSString).lastPathComponent)):\(c.line)\(side)\n\(c.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty { parts.append(trimmedNote) }
        if n > 0 { parts.append("Keep everything else." + (rerun.map { " Rerun \($0)." } ?? "")) }
        return parts.joined(separator: "\n\n")
    }
}

/// What "Send to agent" may type. It goes in as a paste, never with a Return of its own, and on one
/// line: libghostty can't say whether bracketed paste is on, and without it each newline is a Return.
enum SendBack {
    enum Verdict: Equatable {
        case ok(String)
        case blocked(String)
    }

    static func check(_ raw: String) -> Verdict {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .blocked("The prompt is empty.") }
        let p = PastePreview(text)
        if p.hasPasteEnd { return .blocked("The prompt contains a bracketed paste end (^[[201~), so it isn't sent.") }
        if p.hasControls { return .blocked("The prompt contains control or invisible characters, so it isn't sent: \(p.text)") }
        return .ok(oneLine(text))
    }

    static func oneLine(_ s: String) -> String {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static let waiting = "The agent is waiting on a prompt in the terminal. Answer it there first, then send."

    /// Why the prompt can't go to `row`'s tab now, or nil. Only the tab being reviewed, still selected,
    /// running an agent, and with no permission request live. `unresolved` is the core's `hasUnresolved`,
    /// which only verified events clear, while an unverified event can clear `needsYou`.
    static func refusal(surfaceId: String, row: Row?, selected: String?, unresolved: Bool) -> String? {
        guard let row else { return "The reviewed tab is gone." }
        if selected != surfaceId { return "The reviewed tab isn't selected any more. Select it, then send." }
        if row.kind == .shell { return "This tab isn't running an agent, so there's nothing to send the prompt to." }
        if row.needsYou || row.pending != nil || unresolved { return waiting }
        return nil
    }
}

/// The changed files as a tree, single-child folders merged ("Sources/Haunt/").
struct FileTree: Equatable {
    struct Item: Equatable {
        var depth: Int
        /// The folder label with its trailing slash, or nil for a file.
        var dir: String?
        /// Index into the review's files, for a file.
        var file: Int?
    }

    var items: [Item]

    init(paths: [String]) {
        final class Node {
            var children: [(String, Node)] = []
            var files: [(String, Int)] = []
            func child(_ name: String) -> Node {
                if let c = children.first(where: { $0.0 == name }) { return c.1 }
                let n = Node()
                children.append((name, n))
                return n
            }
        }
        let root = Node()
        for (i, p) in paths.enumerated() {
            let comps = p.split(separator: "/").map(String.init)
            var n = root
            for c in comps.dropLast() { n = n.child(c) }
            n.files.append((comps.last ?? p, i))
        }
        var items: [Item] = []
        func walk(_ n: Node, depth: Int) {
            for (name, var child) in n.children {
                var label = name + "/"
                while child.files.isEmpty, child.children.count == 1 {
                    label += child.children[0].0 + "/"
                    child = child.children[0].1
                }
                items.append(Item(depth: depth, dir: label, file: nil))
                walk(child, depth: depth + 1)
            }
            for (_, i) in n.files { items.append(Item(depth: depth, dir: nil, file: i)) }
        }
        walk(root, depth: 0)
        self.items = items
    }

    /// Files in tree order, which j/k follow.
    var fileOrder: [Int] { items.compactMap(\.file) }
}

/// One review of a tab's latest turn; kept in memory per tab until the next turn replaces it.
final class ReviewState {
    enum Mode: Equatable { case files, sendBack, overview }
    enum Verdict: Equatable { case approve, requestChanges, commentOnly }

    let surfaceId: String
    var turn: ReviewTurn?
    var diff: ReviewDiff? { didSet { cachedTree = nil } }
    var loadError: String?
    var checks: [Check] = []
    var mode: Mode = .files
    var selectedFile = 0
    var viewed: Set<String> = []
    var comments: [ReviewComment] = []
    var approved = false
    var verdict: Verdict = .approve
    var note = ""
    /// The draft as the user edited it; nil while it follows the comments.
    var editedDraft: String?

    init(surfaceId: String) {
        self.surfaceId = surfaceId
    }

    var files: [FileDiff] { diff?.files ?? [] }
    /// Built once per diff: drawing and j/k ask for it often.
    var tree: FileTree {
        if let t = cachedTree { return t }
        let t = FileTree(paths: files.map(\.shown))
        cachedTree = t
        return t
    }
    private var cachedTree: FileTree?

    var totals: (Int, Int) { files.reduce((0, 0)) { ($0.0 + $1.additions, $0.1 + $1.deletions) } }

    /// The last check the agent ran, for "Rerun …".
    var rerun: String? { checks.last { $0.state != .notRun }.map { Checks.checkSegment($0.command) ?? $0.command } }

    var draft: String { editedDraft ?? Draft.build(comments: comments, note: note, rerun: rerun) }

    func comments(in path: String) -> [ReviewComment] { comments.filter { $0.path == path } }
}

/// One agent tab's latest turn in the review inbox (version 11). Its diff keeps base and head, so a
/// merge-order view can be built on the same entries later.
final class InboxEntry {
    enum Status: Equatable { case ready, changesRequested, waiting, approved }

    let surfaceId: String
    var row: Row
    let state: ReviewState
    /// Notes sent back from this review: still waiting for the agent, or being worked on in its next turn.
    var sentBack: (notes: Int, pickedUp: Bool)?

    init(surfaceId: String, row: Row, state: ReviewState) {
        self.surfaceId = surfaceId
        self.row = row
        self.state = state
    }

    /// A check the unfinished turn is running right now.
    var runningCheck: String? {
        guard let t = state.turn, t.finishedMs == nil else { return nil }
        return t.commands.last { $0.outcome == .running && Checks.isCheck($0.command) }?.command
    }

    var status: Status {
        if sentBack != nil { return .changesRequested }
        if runningCheck != nil { return .waiting }
        return state.approved ? .approved : .ready
    }

    /// The tab's name as drawn: it can come from a title the terminal program set.
    var tabName: String { Visible.text(row.name) }
    var name: String { state.diff?.branch ?? tabName }
    var repo: String { state.diff?.repo ?? state.turn?.cwd.map { Visible.text(($0 as NSString).lastPathComponent) } ?? tabName }

    /// "tests ✓" only when every check the agent ran passed; Haunt never guesses a result.
    var tests: String {
        let ran = Checks.fromTurn(state.turn?.commands ?? [])
        if ran.isEmpty { return "no tests run" }
        if ran.contains(where: { $0.state == .failed }) { return "tests ✗" }
        if ran.contains(where: { $0.state == .running }) { return "tests running" }
        if ran.allSatisfy({ $0.state == .passed }) { return "tests ✓" }
        return "tests ran"
    }

    var meta: String {
        var parts = [repo, tabName]
        switch status {
        case .changesRequested:
            let n = RVText.plural(sentBack?.notes ?? 0, "note")
            parts.append(sentBack?.pickedUp == true ? "agent working on \(n)" : "\(n) sent")
        case .waiting:
            parts.append("\(runningCheck ?? "a check") running")
        case .ready, .approved:
            if state.loadError != nil {
                parts.append("no diff")
            } else if let d = state.diff {
                parts += [RVText.plural(d.files.count, "file"), tests]
            }
        }
        return parts.joined(separator: " · ")
    }
}

enum Inbox {
    static let groups: [(InboxEntry.Status, String)] = [
        (.ready, "Ready for review"), (.changesRequested, "Changes requested"), (.waiting, "Waiting on checks"), (.approved, "Approved"),
    ]

    /// Non-empty groups in the mockup's order, entries in sidebar order within each.
    static func grouped(_ entries: [InboxEntry]) -> [(label: String, entries: [InboxEntry])] {
        groups.compactMap { status, label in
            let es = entries.filter { $0.status == status }
            return es.isEmpty ? nil : ("\(label) · \(es.count)", es)
        }
    }

    /// Whether notes sent after turn `sentTurn` are still outstanding in `turn`: the agent hasn't started,
    /// or its next turn is still running.
    static func sentBack(notes: Int, sentTurn: UInt32, turn: ReviewTurn?) -> (notes: Int, pickedUp: Bool)? {
        guard let t = turn else { return nil }
        if t.number == sentTurn { return (notes, false) }
        if t.number == sentTurn + 1, t.finishedMs == nil { return (notes, true) }
        return nil
    }
}

enum RVText {
    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

/// The mockup's colouring (`hl` in haunt-review-2): keywords bright, strings softer, `//` comments dim italic.
enum Highlight {
    static let keywords: Set<String> = [
        "func", "let", "var", "guard", "return", "struct", "final", "class", "private", "try", "catch", "do", "self", "import",
        "if", "else", "in", "case", "for", "async", "await", "throws", "static", "extension", "enum", "weak", "nil", "true",
        "false", "init", "override",
    ]

    enum Kind: Equatable { case plain, keyword, string, comment }

    /// Ranges of `s` (in UTF-16 offsets) and what they are.
    static func spans(_ s: String) -> [(NSRange, Kind)] {
        let u = Array(s.utf16)
        var out: [(NSRange, Kind)] = []
        var i = 0, plainStart = 0
        func flush(_ end: Int) { if end > plainStart { out.append((NSRange(location: plainStart, length: end - plainStart), .plain)) } }
        func isWord(_ c: UInt16) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        while i < u.count {
            let c = u[i]
            if c == 47, i + 1 < u.count, u[i + 1] == 47 {
                flush(i)
                out.append((NSRange(location: i, length: u.count - i), .comment))
                return out
            }
            if c == 34 {
                var j = i + 1
                while j < u.count, u[j] != 34 { j += 1 }
                if j < u.count {
                    flush(i)
                    out.append((NSRange(location: i, length: j - i + 1), .string))
                    i = j + 1
                    plainStart = i
                    continue
                }
            }
            if isWord(c), i == 0 || !isWord(u[i - 1]) {
                var j = i
                while j < u.count, isWord(u[j]) { j += 1 }
                let w = String(utf16CodeUnits: Array(u[i..<j]), count: j - i)
                if keywords.contains(w) {
                    flush(i)
                    out.append((NSRange(location: i, length: j - i), .keyword))
                    plainStart = j
                }
                i = j
                continue
            }
            i += 1
        }
        flush(u.count)
        return out
    }
}

/// Repo- and agent-derived text with control and format characters (bidi overrides, zero-width, C0/C1)
/// spelled out as ⟨U+202E⟩, so a change can't disguise what it does when drawn.
enum Visible {
    static func text(_ s: String, keepNewlines: Bool = false) -> String {
        // A literal ⟨ is escaped too, so every ⟨ drawn starts a placeholder and none can be faked.
        func hide(_ c: Unicode.Scalar) -> Bool { c == "⟨" || PastePreview.hidden(c) && !(keepNewlines && c == "\n") }
        guard s.unicodeScalars.contains(where: hide) else { return s }
        var out = ""
        for c in s.unicodeScalars {
            if hide(c) { out += String(format: "⟨U+%04X⟩", c.value) } else { out.unicodeScalars.append(c) }
        }
        return out
    }

    static func hasHidden(_ s: String) -> Bool { s.unicodeScalars.contains(where: PastePreview.hidden) }

    /// The turn as the review shows it: prompt, commands, tasks, files and subagents spelled out.
    static func turn(_ t: ReviewTurn) -> ReviewTurn {
        var t = t
        t.prompt = t.prompt.map { text($0, keepNewlines: true) }
        t.commands = t.commands.map { TurnCommand(command: text($0.command), outcome: $0.outcome) }
        t.tasks = t.tasks.map { TurnTask(subject: text($0.subject), status: $0.status) }
        t.files = t.files.map { text($0) }
        t.subagents = t.subagents.map { TurnSubagent(label: text($0.label), toolCount: $0.toolCount, durationMs: $0.durationMs) }
        return t
    }
}
