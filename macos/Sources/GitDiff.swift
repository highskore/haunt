import Foundation

/// One line of a hunk, with its old and new line numbers.
struct DiffLine: Equatable {
    enum Kind: Equatable { case context, add, del }
    var kind: Kind
    var text: String
    var old: Int?
    var new: Int?
    /// The text had control or format characters, now spelled out.
    var hidden = false
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
    /// As git gave it: the key for viewed state, comments and de-duplication. Draw `shown` instead.
    var path: String
    var status: Status = .modified
    var binary = false
    var hunks: [Hunk] = []
    var additions = 0
    var deletions = 0
    /// Diff lines past the per-file limit, counted but not kept.
    var droppedLines = 0
    /// The path or a line had control or format characters (Trojan Source), spelled out where drawn.
    var hiddenChars = false
    /// A FIFO, socket or device among the untracked files: listed, never read.
    var special = false
    /// For a binary file: what changed, since its content isn't shown.
    var blob = BinaryInfo()

    struct BinaryInfo: Equatable {
        var oldHash: String?
        var newHash: String?
        var oldSize: Int?
        var newSize: Int?
        /// Past the review's cap on binaries: its size wasn't looked up.
        var unsized = false
    }

    /// "Binary file, not shown · 12.0 KB → 14.1 KB · 1a2b3c4 → 5d6e7f8", with what's known.
    var binaryNote: String {
        func size(_ n: Int?) -> String {
            guard let n else { return "?" }
            if n < 1024 { return "\(n) B" }
            if n < 1 << 20 { return String(format: "%.1f KB", Double(n) / 1024) }
            return String(format: "%.1f MB", Double(n) / Double(1 << 20))
        }
        var parts = ["Binary file, not shown"]
        let (o, n) = (status == .added ? "none" : size(blob.oldSize), status == .deleted ? "none" : size(blob.newSize))
        if blob.unsized {
            parts.append("size not computed")
        } else if blob.oldSize != nil || blob.newSize != nil {
            parts.append("\(o) → \(n)")
        }
        let short = { (h: String?) in h.map { String($0.prefix(7)) } ?? "none" }
        if blob.oldHash != nil || blob.newHash != nil { parts.append("\(short(blob.oldHash)) → \(short(blob.newHash))") }
        return parts.joined(separator: " · ")
    }

    var shown: String { Visible.text(path) }
    var name: String { (shown as NSString).lastPathComponent }
    /// "Sources/Haunt/Notify/", or "" at the top level.
    var dir: String {
        let d = (shown as NSString).deletingLastPathComponent
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
            // The diff runs with --text, so no attribute can hide a change as binary; a NUL, git's own test, still marks one.
            if var f = cur {
                if f.hunks.contains(where: { $0.lines.contains { $0.text.contains("\u{0}") } }) {
                    (f.binary, f.hunks, f.additions, f.deletions, f.droppedLines) = (true, [], 0, 0, 0)
                }
                files.append(f)
            }
            cur = nil
        }

        // "\r\n" is one Character in Swift, so it has to be a separator of its own.
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
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
                    dl.text = expandTabs(capped(dl.text))
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
            } else if line.hasPrefix("index "), let range = line.dropFirst(6).split(separator: " ").first {
                let ends = range.components(separatedBy: "..")
                if ends.count == 2 {
                    let hash = { (h: String) -> String? in h.allSatisfy { $0 == "0" } || !h.allSatisfy(\.isHexDigit) ? nil : h }
                    (f.blob.oldHash, f.blob.newHash) = (hash(ends[0]), hash(ends[1]))
                }
            } else if line.hasPrefix("+++ ") {
                let p = unquote(String(line.dropFirst(4)))
                if p != "/dev/null" { f.path = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p }
            } else if line.hasPrefix("--- ") {
                let p = unquote(String(line.dropFirst(4)))
                if p != "/dev/null", f.status == .deleted { f.path = p.hasPrefix("a/") ? String(p.dropFirst(2)) : p }
            }
        }
        finish()
        return files.map(visible)
    }

    /// Hunk headers and lines with control and format characters spelled out; those and paths flagged.
    /// Paths stay raw, so two files never merge into one display name's state.
    static func visible(_ f: FileDiff) -> FileDiff {
        var f = f
        if Visible.hasHidden(f.path) { f.hiddenChars = true }
        if case let .renamed(from) = f.status, Visible.hasHidden(from) { f.hiddenChars = true }
        for h in f.hunks.indices {
            let header = Visible.text(f.hunks[h].header)
            if Visible.hasHidden(f.hunks[h].header) { f.hiddenChars = true }
            f.hunks[h].header = header
            for l in f.hunks[h].lines.indices {
                let t = Visible.text(f.hunks[h].lines[l].text)
                if Visible.hasHidden(f.hunks[h].lines[l].text) {
                    f.hunks[h].lines[l].hidden = true
                    f.hiddenChars = true
                }
                f.hunks[h].lines[l].text = t
            }
        }
        return f
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

    static let maxLineChars = 2000

    /// A minified or generated line cut to `maxLineChars`, saying how much is left out.
    static func capped(_ s: String) -> String {
        guard s.utf16.count > maxLineChars else { return s }
        let n = s.count
        return n > maxLineChars ? String(s.prefix(maxLineChars)) + " … \(n - maxLineChars) more" : s
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
        /// Past the cap: bytes read and dropped, and how many `diff --git` headers they held.
        var dropped = 0
        var droppedFiles = 0
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// No external diff or textconv driver, no fsmonitor hook, no pager, no network, no attributes file,
    /// and every other program git could be configured to run pinned empty.
    static let safeConfig = [
        "core.fsmonitor=false", "core.untrackedCache=false", "core.pager=cat", "core.quotePath=false",
        "core.hooksPath=/dev/null", "core.attributesFile=/dev/null", "diff.external=", "diff.noprefix=false",
        "diff.mnemonicPrefix=false", "diff.relative=false", "color.ui=false", "submodule.recurse=false", "diff.ignoreSubmodules=dirty", "status.submoduleSummary=false",
        "protocol.allow=never", "protocol.ext.allow=never", "protocol.file.allow=never", "protocol.ssh.allow=never",
        "protocol.http.allow=never", "protocol.https.allow=never",
        "core.sshCommand=", "core.askPass=", "credential.helper=", "gpg.program=",
        "gpg.openpgp.program=", "gpg.x509.program=", "gpg.ssh.program=", "core.editor=true", "sequence.editor=true",
        "log.showSignature=false", "core.alternateRefsCommand=", "core.gitProxy=",
    ]

    /// Whether the repo's config defines a filter, textconv or external diff driver (a working-tree diff
    /// could run one for paths its attributes name); nil when that can't be told. Reading config runs nothing.
    static func definesDrivers(cwd: String) -> Bool? {
        guard let o = run(["config", "--show-scope", "-z", "--get-regexp", #"^(filter|diff)\."#], cwd: cwd),
              !o.timedOut, !o.truncated else { return nil }
        if o.status == 1 { return false }
        guard o.status == 0 else { return nil }
        // "scope\0key\nvalue\0" per entry; the command scope is safeConfig's own pins.
        let fields = o.data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        return stride(from: 0, to: fields.count - 1, by: 2).contains { i in
            guard fields[i] != "command" else { return false }
            let key = fields[i + 1].prefix { $0 != "\n" }
            return key.hasPrefix("filter.") || key == "diff.external" || key.hasPrefix("diff.") && (key.hasSuffix(".textconv") || key.hasSuffix(".command"))
        }
    }

    /// Set once at first use; the review tests point it at a newer git.
    static var gitPath: String? = defaultGit()

    /// macOS's sandbox runner (deprecated by Apple, still shipped). git runs only inside it; the tests move it.
    static var sandboxExec = "/usr/bin/sandbox-exec"

    private static func defaultGit() -> String? {
        // The tools' git itself: /usr/bin/git is a shim that starts it, which the sandbox wouldn't allow.
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return candidates.lazy.compactMap(trusted).first
    }

    /// `sandbox-exec` arguments that run `git` able to start no process but itself, so no filter, hook,
    /// pager, fsmonitor or other program a repository names can run, whatever its config or attributes say
    /// when git reads them. Nil when that can't be set up, and then git doesn't run at all.
    static func sandboxed(_ git: String) -> [String]? {
        guard let c = realpath(git, nil) else { return nil }
        let real = String(cString: c)
        free(c)
        guard !real.contains("\""), !real.contains("\\"), FileManager.default.isExecutableFile(atPath: sandboxExec) else { return nil }
        let args = ["-p", "(version 1)(allow default)(deny process-fork)(deny process-exec)(allow process-exec (literal \"\(real)\"))", real]
        sandboxLock.lock()
        defer { sandboxLock.unlock() }
        if sandboxWorks?.git != real || sandboxWorks?.runner != sandboxExec {
            let probe = spawn(sandboxExec, args + ["version"], cwd: "/", env: environment(), timeout: 10, maxBytes: 4096)
            sandboxWorks = (real, sandboxExec, probe?.status == 0 && probe?.text.hasPrefix("git version") == true)
        }
        return sandboxWorks?.ok == true ? args : nil
    }
    /// `run` is called from background threads; the probe's cache is read and written only under this.
    private static let sandboxLock = NSLock()
    private static var sandboxWorks: (git: String, runner: String, ok: Bool)?

    /// `path` with links resolved, if it and every folder up to / belong to root or the user and only they,
    /// admin or wheel (who can sudo anyway) can write to them; a git anyone else can replace would run on every review.
    static func trusted(_ path: String) -> String? {
        guard let c = realpath(path, nil) else { return nil }
        let real = String(cString: c)
        free(c)
        func safe(_ p: String) -> Bool {
            var st = stat()
            guard lstat(p, &st) == 0, st.st_uid == 0 || st.st_uid == getuid(), st.st_mode & S_IWOTH == 0 else { return false }
            return st.st_mode & S_IWGRP == 0 || st.st_gid == 0 || st.st_gid == 80
        }
        var st = stat()
        guard stat(real, &st) == 0, st.st_mode & S_IFMT == S_IFREG, access(real, X_OK) == 0, safe(real) else { return nil }
        var dir = real
        repeat {
            dir = (dir as NSString).deletingLastPathComponent
            if !safe(dir) { return nil }
        } while dir != "/"
        return real
    }

    static func environment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0",
                   "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "PAGER": "cat", "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ATTR_NOSYSTEM": "1", "GIT_NO_REPLACE_OBJECTS": "1",
                   // Attributes come from the empty tree, so no .gitattributes written later can pick a filter.
                   "GIT_ATTR_SOURCE": ReviewLoader.emptyTree, "GIT_NO_LAZY_FETCH": "1"]
        if let home = env["HOME"] { out["HOME"] = home }
        return out
    }

    #if DEBUG
    /// Called with each `run`'s arguments; the review tests count processes with it.
    nonisolated(unsafe) static var willRun: (([String]) -> Void)?
    #endif

    /// Blocks the calling thread; call it off the main thread. Output past `maxBytes` is counted, not kept.
    static func run(_ args: [String], cwd: String, timeout: TimeInterval = 10, maxBytes: Int = 16 << 20, input: Data? = nil) -> Output? {
        #if DEBUG
        willRun?(args)
        #endif
        guard let git = gitPath, let sandbox = sandboxed(git) else { return nil }
        return spawn(sandboxExec, sandbox + safeConfig.flatMap { ["-c", $0] } + ["--no-pager"] + args, cwd: cwd,
                     env: environment(), timeout: timeout, maxBytes: maxBytes, input: input)
    }

    /// Runs `exe` without a shell in a process group of its own, so a timeout or the output cap kills
    /// whatever it started too. No other descriptor of the app is inherited.
    static func spawn(_ exe: String, _ args: [String], cwd: String, env: [String: String], timeout: TimeInterval,
                      maxBytes: Int, input: Data? = nil) -> Output? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (rd, wr) = (fds[0], fds[1])
        var inFds: [Int32] = [-1, -1]
        if input != nil, pipe(&inFds) != 0 { close(rd); close(wr); return nil }
        // So a fork on another thread (a shell starting) can't inherit an end and hold the pipe open.
        for fd in [rd, wr, inFds[0], inFds[1]] where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, inFds[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, wr, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var none = sigset_t(), defaults = sigset_t()
        sigemptyset(&none)
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, exe, &actions, &attr, argv, envp)
        close(wr)
        if let input {
            close(inFds[0])
            let inWr = inFds[1]
            if spawned == 0 {
                // A child that exits early must not take the app down with SIGPIPE.
                _ = fcntl(inWr, F_SETNOSIGPIPE, 1)
                DispatchQueue.global(qos: .utility).async {
                    input.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                        var off = 0
                        while off < b.count {
                            let n = write(inWr, b.baseAddress! + off, b.count - off)
                            if n < 0, errno == EINTR { continue }
                            if n <= 0 { break }
                            off += n
                        }
                    }
                    close(inWr)
                }
            } else {
                close(inWr)
            }
        }
        guard spawned == 0 else { close(rd); return nil }

        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var data = Data(), truncated = false, abandoned = false
            var dropped = 0, droppedFiles = 0
            /// The last bytes seen, so a header split across reads is still counted.
            var tail: [UInt8] = []
        }
        let header = Array("\ndiff --git ".utf8)
        let sink = Sink()
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var buf = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let n = read(rd, &buf, buf.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                sink.lock.lock()
                defer { sink.lock.unlock() }
                if sink.abandoned { break }
                let keep = max(0, min(n, maxBytes - sink.data.count))
                sink.data.append(contentsOf: buf[..<keep])
                if keep < n {
                    // Past the cap: read on to the end (or the timeout), counting what isn't kept.
                    sink.truncated = true
                    sink.dropped += n - keep
                    let seen = (sink.tail.isEmpty ? Array(sink.data.suffix(header.count - 1)) : sink.tail) + buf[keep..<n]
                    sink.droppedFiles += (0...max(0, seen.count - header.count)).filter { seen.count >= header.count && seen[$0..<$0 + header.count].elementsEqual(header) }.count
                    sink.tail = Array(seen.suffix(header.count - 1))
                }
            }
            close(rd)
            reader.signal()
        }
        let timedOut = reader.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            kill(-pid, SIGTERM)
            kill(-pid, SIGKILL)
            // A child that left the group may still hold the pipe; its output is dropped, not raced on.
            _ = reader.wait(timeout: .now() + 1)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        sink.lock.lock()
        defer { sink.lock.unlock() }
        sink.abandoned = true
        return Output(status: status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f), data: sink.data,
                      truncated: sink.truncated, timedOut: timedOut, dropped: sink.dropped, droppedFiles: sink.droppedFiles)
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
    /// The repository's name: its main checkout's folder, shared by its worktrees.
    var repo: String?
    /// HEAD and the commit diffed against, so branches can later be ordered for merging.
    var head: String?
    var base: String?
}

enum ReviewLoader {
    static let maxUntracked = 100
    static let maxUntrackedBytes = 1 << 20
    static let maxNoIndexBytes = 2 << 20
    static let maxSizedBinaries = 500

    /// How much a cut diff left out: "1.5 MB more, in 3 more files, isn't shown" ("at least" when git timed out).
    static func cut(_ o: GitRunner.Output) -> String {
        let n = o.dropped
        let size = n < 1 << 20 ? String(format: "%.1f KB", Double(n) / 1024) : String(format: "%.1f MB", Double(n) / Double(1 << 20))
        let files = o.droppedFiles == 0 ? "" : o.droppedFiles == 1 ? ", in 1 more file," : ", in \(o.droppedFiles) more files,"
        return (o.timedOut ? "at least " : "") + size + " more" + files + " isn't shown"
    }

    enum LoadError: Error, Equatable { case noGit, notARepo(String), failed(String) }

    /// Runs several git commands; call it off the main thread.
    static func load(cwd: String, headAtStart: String?) -> Result<ReviewDiff, LoadError> {
        guard let gitPath = GitRunner.gitPath else { return .failure(.noGit) }
        guard GitRunner.sandboxed(gitPath) != nil else {
            return .failure(.failed("git can't start inside \(GitRunner.sandboxExec), and Haunt runs it nowhere else."))
        }
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

        // Reading the working tree can run a filter driver; comparing two commits never does.
        let readTree: Bool
        switch GitRunner.definesDrivers(cwd: root) {
        case false?:
            readTree = true
        case true?:
            readTree = false
            notes.append("This repository defines git filters or diff drivers, so the working-tree diff is skipped "
                         + "and only committed changes are shown.")
        case nil:
            readTree = false
            notes.append("Haunt couldn't read this repository's filter settings, so only committed changes are shown.")
        }
        let range: [String]? = readTree ? [base] : (head.map { base == $0 ? nil : [base, $0] } ?? nil)
        var files: [FileDiff] = []
        if let range {
            let diffArgs = ["diff", "--text", "--full-index", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/",
                            "--submodule=short", "--ignore-submodules=dirty", "-M"] + range + ["--"]
            guard let out = git(diffArgs) else { return .failure(.failed("git diff didn't start.")) }
            guard out.status == 0 || out.truncated || out.timedOut else { return .failure(.failed("git diff failed (exit \(out.status)).")) }
            if out.timedOut { notes.append("git diff timed out; the list may be incomplete.") }
            if out.truncated { notes.append("The diff is over 16 MB and was cut: " + ReviewLoader.cut(out) + "; the last file shown may be incomplete.") }
            files = DiffParser.parse(out.text)
            // Every size from one cat-file, for the first `maxSizedBinaries`; past that none is looked up.
            let binaries = files.indices.filter { files[$0].binary }
            let sized = binaries.prefix(maxSizedBinaries)
            let hashes = Set(sized.flatMap { [files[$0].blob.oldHash, files[$0].blob.newHash].compactMap { $0 } })
            var sizes: [String: Int] = [:]
            if !hashes.isEmpty, let o = GitRunner.run(["cat-file", "--batch-check=%(objectname) %(objectsize)"], cwd: root,
                                                       input: Data(hashes.sorted().map { $0 + "\n" }.joined().utf8)) {
                for l in o.text.split(separator: "\n") {
                    let p = l.split(separator: " ")
                    if p.count == 2, let n = Int(p[1]) { sizes[String(p[0])] = n }
                }
            }
            for i in sized {
                let size = { (h: String?) in h.flatMap { sizes[$0] } }
                files[i].blob.oldSize = files[i].status == .added ? nil : size(files[i].blob.oldHash)
                // A working-tree file's blob isn't in the object database; its size is on disk.
                var st = stat()
                let onDisk = readTree && lstat((root as NSString).appendingPathComponent(files[i].path), &st) == 0 ? Int(st.st_size) : nil
                files[i].blob.newSize = files[i].status == .deleted ? nil : size(files[i].blob.newHash) ?? onDisk
            }
            for i in binaries.dropFirst(maxSizedBinaries) { files[i].blob.unsized = true }
        }
        let tracked = Set(files.map(\.path))
        let dirty = readTree ? (head.map { git(["diff", "--quiet", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty", $0, "--"])?.status == 1 } ?? !files.isEmpty) : false

        if readTree, let u = git(["ls-files", "--others", "--exclude-standard", "-z"]), u.status == 0 || u.truncated || u.timedOut {
            var names = u.data.split(separator: 0, omittingEmptySubsequences: false)
            if u.truncated || u.timedOut {
                // The last name may be cut mid-way.
                if u.data.last != 0 { names = names.dropLast() }
                notes.append("git's list of untracked files was cut, so some aren't shown.")
            }
            let paths = names.filter { !$0.isEmpty }.map { String(decoding: $0, as: UTF8.self) }.filter { !tracked.contains($0) }
            for (i, p) in paths.enumerated() {
                if i >= maxUntracked {
                    notes.append("\(paths.count - maxUntracked) more untracked files aren't shown.")
                    break
                }
                var st = stat()
                let full = (root as NSString).appendingPathComponent(p)
                let shown = Visible.text(p)
                guard lstat(full, &st) == 0 else { continue }
                let type = st.st_mode & S_IFMT
                // git would read (and block on) a FIFO or device; a symlink's target is shown without following it.
                if type == S_IFLNK {
                    let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? ""
                    let line = DiffLine(kind: .add, text: target, old: nil, new: 1)
                    files.append(DiffParser.visible(FileDiff(path: p, status: .added, hunks: [Hunk(oldStart: 0, newStart: 1,
                        header: "@@ -0,0 +1 @@ symbolic link", lines: [line])], additions: 1)))
                    continue
                }
                if type != S_IFREG {
                    var f = DiffParser.visible(FileDiff(path: p, status: .added))
                    f.special = true
                    files.append(f)
                    notes.append("\(shown) is a special file (not a regular file or link) and isn't shown.")
                    continue
                }
                if Int(st.st_size) > maxUntrackedBytes {
                    var big = DiffParser.visible(FileDiff(path: p, status: .added, binary: true))
                    big.blob.newSize = Int(st.st_size)
                    files.append(big)
                    notes.append("\(shown) is over 1 MB and isn't shown.")
                    continue
                }
                // Exit status 1 means "differs", the normal case here.
                guard let d = GitRunner.run(["diff", "--no-index", "--text", "--full-index", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/",
                                             "--dst-prefix=b/", "--", "/dev/null", p], cwd: root, maxBytes: maxNoIndexBytes),
                      d.status <= 1 || d.truncated else { continue }
                if d.truncated { notes.append("\(shown)'s diff is over 2 MB and was cut: " + ReviewLoader.cut(d) + ".") }
                var parsed = DiffParser.parse(d.text)
                for k in parsed.indices {
                    parsed[k].status = .added; parsed[k].path = p; parsed[k].hiddenChars = parsed[k].hiddenChars || Visible.hasHidden(p)
                    parsed[k].blob.newSize = Int(st.st_size)
                }
                files += parsed.isEmpty ? [DiffParser.visible(FileDiff(path: p, status: .added))] : parsed
            }
        }
        let branch = line(["rev-parse", "--abbrev-ref", "HEAD"]).flatMap { $0 == "HEAD" ? nil : Visible.text($0) }
        let upstream = line(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]).map { Visible.text($0) }
        let dirs = line(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"])?.split(separator: "\n").map(String.init)
        let linked = dirs.map { $0.count == 2 && $0[0] != $0[1] } ?? false
        let common = dirs?.count == 2 ? dirs![1] : nil
        let repo = common.map { c -> String in
            let n = c as NSString
            return n.lastPathComponent == ".git" ? (n.deletingLastPathComponent as NSString).lastPathComponent
                : (n.lastPathComponent as NSString).deletingPathExtension
        } ?? (root as NSString).lastPathComponent
        return .success(ReviewDiff(root: root, files: files, branch: branch, upstream: upstream, commits: commits,
                                   baseNote: baseNote, uncommitted: dirty || files.count > tracked.count, isWorktree: linked,
                                   notes: notes, repo: Visible.text(repo), head: head, base: base))
    }

    /// Git's well-known empty tree, for a repository without commits.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
}
