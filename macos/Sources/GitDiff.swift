import Foundation

/// One line of a hunk, with its old and new line numbers.
struct DiffLine: Equatable {
    enum Kind: Equatable { case context, add, del }
    var kind: Kind
    var text: String
    var old: Int?
    var new: Int?
}

struct Hunk: Equatable {
    var oldStart: Int
    var newStart: Int
    /// The `@@ -a,b +c,d @@ label` line as git wrote it.
    var header: String
    var lines: [DiffLine]
}

/// One file of a unified diff.
struct FileDiff: Equatable {
    enum Status: Equatable { case added, deleted, modified, renamed(from: String) }
    var path: String
    var status: Status = .modified
    var binary = false
    var hunks: [Hunk] = []
    var additions = 0
    var deletions = 0
    /// Diff lines past the per-file limit, counted but not kept.
    var droppedLines = 0

    var name: String { (path as NSString).lastPathComponent }
    /// "Sources/Haunt/Notify/", or "" at the top level.
    var dir: String {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? "" : d + "/"
    }
}

/// Parses `git diff` patch output. Lines past `maxLines` per file are counted, not kept.
enum DiffParser {
    static let defaultMaxLines = 2000

    static func parse(_ text: String, maxLines: Int = defaultMaxLines) -> [FileDiff] {
        var files: [FileDiff] = []
        var cur: FileDiff?
        var kept = 0
        var old = 0, new = 0
        var inHunk = false

        func finish() {
            if let f = cur { files.append(f) }
            cur = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                finish()
                cur = FileDiff(path: gitLinePath(String(line.dropFirst(11))))
                kept = 0
                inHunk = false
                continue
            }
            guard var f = cur else { continue }
            defer { cur = f }
            if inHunk, let c = line.first, c == " " || c == "+" || c == "-" {
                let body = String(line.dropFirst())
                var dl: DiffLine
                switch c {
                case "+":
                    dl = DiffLine(kind: .add, text: body, old: nil, new: new)
                    new += 1
                    f.additions += 1
                case "-":
                    dl = DiffLine(kind: .del, text: body, old: old, new: nil)
                    old += 1
                    f.deletions += 1
                default:
                    dl = DiffLine(kind: .context, text: body, old: old, new: new)
                    old += 1
                    new += 1
                }
                if kept < maxLines {
                    dl.text = expandTabs(dl.text)
                    f.hunks[f.hunks.count - 1].lines.append(dl)
                    kept += 1
                } else {
                    f.droppedLines += 1
                }
                continue
            }
            if line.hasPrefix("@@ "), let (o, n) = hunkStarts(line) {
                inHunk = true
                old = o
                new = n
                if kept < maxLines { f.hunks.append(Hunk(oldStart: o, newStart: n, header: line, lines: [])) }
                continue
            }
            if line.hasPrefix("\\") { continue }
            inHunk = false
            if line.hasPrefix("new file mode") {
                f.status = .added
            } else if line.hasPrefix("deleted file mode") {
                f.status = .deleted
            } else if line.hasPrefix("rename from ") {
                f.status = .renamed(from: unquote(String(line.dropFirst(12))))
            } else if line.hasPrefix("rename to ") {
                f.path = unquote(String(line.dropFirst(10)))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                f.binary = true
            } else if line.hasPrefix("+++ ") {
                let p = unquote(String(line.dropFirst(4)))
                if p != "/dev/null" { f.path = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p }
            } else if line.hasPrefix("--- ") {
                let p = unquote(String(line.dropFirst(4)))
                if p != "/dev/null", f.status == .deleted { f.path = p.hasPrefix("a/") ? String(p.dropFirst(2)) : p }
            }
        }
        finish()
        return files
    }

    /// `@@ -18,7 +18,16 @@ label` → (18, 18).
    static func hunkStarts(_ line: String) -> (Int, Int)? {
        let parts = line.split(separator: " ", maxSplits: 3)
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func start(_ s: Substring) -> Int? { Int(s.dropFirst().split(separator: ",").first ?? "") }
        guard let o = start(parts[1]), let n = start(parts[2]) else { return nil }
        return (o, n)
    }

    /// The path from `a/<p> b/<p>` on a `diff --git` line; exact when both sides are the same, which is
    /// the case whenever no `+++`/`rename to` line follows to correct it.
    static func gitLinePath(_ rest: String) -> String {
        if rest.hasPrefix("\"") { return String(unquote(rest).dropFirst(2).split(separator: "\"").first ?? "") }
        let half = (rest.count - 1) / 2
        let a = rest.prefix(half), b = rest.suffix(rest.count - half - 1)
        if a.hasPrefix("a/"), b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2) { return String(b.dropFirst(2)) }
        if let r = rest.range(of: " b/") { return String(rest[r.upperBound...]) }
        return rest
    }

    /// Git's C-style quoting (`"a\tb"`, octal UTF-8 bytes); anything else is returned as is.
    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        var bytes: [UInt8] = []
        var it = Array(s.utf8.dropFirst().dropLast())[...]
        while let c = it.popFirst() {
            guard c == UInt8(ascii: "\\"), let e = it.popFirst() else { bytes.append(c); continue }
            switch e {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var v = Int(e - 48)
                for _ in 0..<2 {
                    guard let d = it.first, (48...55).contains(d) else { break }
                    v = v * 8 + Int(d - 48)
                    it.removeFirst()
                }
                bytes.append(UInt8(v & 0xFF))
            default: bytes.append(e)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func expandTabs(_ s: String, width: Int = 4) -> String {
        guard s.contains("\t") else { return s }
        var out = ""
        var col = 0
        for ch in s {
            if ch == "\t" {
                let n = width - col % width
                out += String(repeating: " ", count: n)
                col += n
            } else {
                out.append(ch)
                col += 1
            }
        }
        return out
    }
}

/// Runs git without a shell, with options that keep repo config from running anything but git itself.
enum GitRunner {
    struct Output {
        var status: Int32
        var data: Data
        var truncated: Bool
        var timedOut: Bool
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// No external diff or textconv driver, no fsmonitor hook, no pager, no network.
    static let safeConfig = [
        "core.fsmonitor=false", "core.untrackedCache=false", "core.pager=cat", "core.quotePath=false",
        "core.hooksPath=/dev/null", "diff.external=", "diff.noprefix=false", "diff.mnemonicPrefix=false",
        "diff.relative=false", "color.ui=false", "submodule.recurse=false", "protocol.allow=never",
    ]

    static let gitPath: String? = {
        let fm = FileManager.default
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: p) { return p }
        // /usr/bin/git is a shim that pops an install dialog when the developer tools are missing.
        let tools = ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return tools.contains(where: fm.isExecutableFile(atPath:)) ? "/usr/bin/git" : nil
    }()

    static func environment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0",
                   "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "PAGER": "cat", "GIT_CONFIG_NOSYSTEM": "1"]
        if let home = env["HOME"] { out["HOME"] = home }
        return out
    }

    /// Blocks the calling thread; call it off the main thread. Output past `maxBytes` is cut and the process killed.
    static func run(_ args: [String], cwd: String, timeout: TimeInterval = 10, maxBytes: Int = 16 << 20) -> Output? {
        guard let git = gitPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = safeConfig.flatMap { ["-c", $0] } + ["--no-pager"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = environment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        var data = Data()
        var truncated = false
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let h = pipe.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                if data.count + chunk.count > maxBytes {
                    data.append(chunk.prefix(maxBytes - data.count))
                    truncated = true
                    p.terminate()
                    break
                }
                data.append(chunk)
            }
            reader.signal()
        }
        let timedOut = reader.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            kill(p.processIdentifier, SIGKILL)
            _ = reader.wait(timeout: .now() + 1)
        }
        p.waitUntilExit()
        return Output(status: p.terminationStatus, data: data, truncated: truncated, timedOut: timedOut)
    }
}

/// The working tree (index included) plus any commits made during the turn, against the turn's base.
struct ReviewDiff: Equatable {
    var root: String
    var files: [FileDiff]
    var branch: String?
    /// The upstream branch, e.g. "origin/main"; nil when there is none.
    var upstream: String?
    /// Commits on top of the turn's starting commit; 0 when it is unknown or HEAD didn't move.
    var commits: Int
    /// What the diff is against, said plainly ("HEAD", "the commit the turn started on").
    var baseNote: String
    var uncommitted: Bool
    /// A linked worktree (`git worktree add`), not the main checkout.
    var isWorktree = false
    /// Honest notes for the screen: cut output, timeouts, skipped untracked files.
    var notes: [String] = []
}

enum ReviewLoader {
    static let maxUntracked = 100
    static let maxUntrackedBytes = 1 << 20

    enum LoadError: Error, Equatable { case noGit, notARepo(String), failed(String) }

    /// Runs several git commands; call it off the main thread.
    static func load(cwd: String, headAtStart: String?) -> Result<ReviewDiff, LoadError> {
        guard GitRunner.gitPath != nil else { return .failure(.noGit) }
        guard let top = GitRunner.run(["rev-parse", "--show-toplevel"], cwd: cwd), top.status == 0 else {
            return .failure(.notARepo(cwd))
        }
        let root = top.text.trimmingCharacters(in: .newlines)
        func git(_ args: [String]) -> GitRunner.Output? { GitRunner.run(args, cwd: root) }
        func line(_ args: [String]) -> String? {
            guard let o = git(args), o.status == 0 else { return nil }
            let s = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        var notes: [String] = []
        let head = line(["rev-parse", "--verify", "-q", "HEAD^{commit}"])
        var base = head ?? emptyTree
        var baseNote = head == nil ? "an empty tree (no commits yet)" : "HEAD"
        var commits = 0
        if let start = headAtStart, let head, start != head {
            if git(["merge-base", "--is-ancestor", start, "HEAD"])?.status == 0 {
                base = start
                commits = Int(line(["rev-list", "--count", "\(start)..HEAD"]) ?? "") ?? 0
                baseNote = "the commit the turn started on"
            } else {
                notes.append("HEAD moved off the commit the turn started on, so this is against HEAD only.")
            }
        } else if headAtStart == nil, head != nil {
            notes.append("Haunt doesn't know where the turn started, so commits made during it aren't included.")
        }

        let diffArgs = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/",
                        "--submodule=short", "-M", base, "--"]
        guard let out = git(diffArgs), out.status == 0 || out.truncated else {
            return .failure(.failed("git diff didn't finish"))
        }
        if out.timedOut { notes.append("git diff timed out; the list may be incomplete.") }
        if out.truncated { notes.append("The diff is over 16 MB and was cut.") }
        var files = DiffParser.parse(out.text)
        let tracked = Set(files.map(\.path))
        let dirty = head.map { git(["diff", "--quiet", "--no-ext-diff", "--no-textconv", $0, "--"])?.status == 1 } ?? !files.isEmpty

        if let u = git(["ls-files", "--others", "--exclude-standard", "-z"]), u.status == 0 {
            let paths = u.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !tracked.contains($0) }
            for (i, p) in paths.enumerated() {
                if i >= maxUntracked {
                    notes.append("\(paths.count - maxUntracked) more untracked files aren't shown.")
                    break
                }
                var st = stat()
                let full = (root as NSString).appendingPathComponent(p)
                if lstat(full, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Int(st.st_size) > maxUntrackedBytes {
                    files.append(FileDiff(path: p, status: .added, binary: true))
                    notes.append("\(p) is over 1 MB and isn't shown.")
                    continue
                }
                // Exit status 1 means "differs", the normal case here.
                guard let d = git(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/",
                                   "--dst-prefix=b/", "--", "/dev/null", p]), d.status <= 1 else { continue }
                var parsed = DiffParser.parse(d.text)
                for k in parsed.indices { parsed[k].status = .added; parsed[k].path = p }
                files += parsed.isEmpty ? [FileDiff(path: p, status: .added)] : parsed
            }
        }
        let branch = line(["rev-parse", "--abbrev-ref", "HEAD"]).flatMap { $0 == "HEAD" ? nil : $0 }
        let upstream = line(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        let dirs = line(["rev-parse", "--git-dir", "--git-common-dir"])?.split(separator: "\n")
        let worktree = dirs.map { $0.count == 2 && $0[0] != $0[1] } ?? false
        return .success(ReviewDiff(root: root, files: files, branch: branch, upstream: upstream, commits: commits,
                                   baseNote: baseNote, uncommitted: dirty || files.count > tracked.count, isWorktree: worktree, notes: notes))
    }

    /// Git's well-known empty tree, for a repository without commits.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
}
