import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

// MARK: Parser

let patch = """
diff --git a/Sources/A.swift b/Sources/A.swift
index 1111111..2222222 100644
--- a/Sources/A.swift
+++ b/Sources/A.swift
@@ -18,4 +18,5 @@ final class A {
   let a = 1
-  init() {}
+  init(x: Int) {
+\tself.x = x
   }
\\ No newline at end of file
diff --git a/new file.txt b/new file.txt
new file mode 100644
--- /dev/null
+++ b/new file.txt
@@ -0,0 +1,2 @@
+one
+two
diff --git a/old.txt b/old.txt
deleted file mode 100644
--- a/old.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone
diff --git a/img.png b/img.png
Binary files a/img.png and b/img.png differ
diff --git a/x.rs b/y.rs
similarity index 90%
rename from x.rs
rename to y.rs
diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
--- "a/caf\\303\\251.txt"
+++ "b/caf\\303\\251.txt"
@@ -1 +1 @@
-a
+b

"""
let files = DiffParser.parse(patch)
check(files.map(\.path) == ["Sources/A.swift", "new file.txt", "old.txt", "img.png", "y.rs", "café.txt"], "paths \(files.map(\.path))")
let a = files[0]
check((a.additions, a.deletions, a.hunks.count) == (2, 1, 1), "A counts")
check(a.hunks[0].header == "@@ -18,4 +18,5 @@ final class A {", "header kept")
let nums = a.hunks[0].lines.map { "\($0.old.map(String.init) ?? "_")/\($0.new.map(String.init) ?? "_")" }
check(nums == ["18/18", "19/_", "_/19", "_/20", "20/21"], "line numbers \(nums)")
check(a.hunks[0].lines[3].text == "    self.x = x", "tabs expanded: \(a.hunks[0].lines[3].text.debugDescription)")
check(files[1].status == .added && files[1].additions == 2, "added")
check(files[2].status == .deleted && files[2].deletions == 1, "deleted")
check(files[3].binary && files[3].hunks.isEmpty, "binary listed, not rendered")
check(files[4].status == .renamed(from: "x.rs"), "rename")
check(a.dir == "Sources/" && a.name == "A.swift", "dir/name")

let long = "diff --git a/l b/l\n--- a/l\n+++ b/l\n@@ -1,0 +1,10 @@\n" + (0..<10).map { "+\($0)" }.joined(separator: "\n")
let cut = DiffParser.parse(long, maxLines: 4)[0]
check(cut.hunks[0].lines.count == 4 && cut.droppedLines == 6 && cut.additions == 10, "per-file cut counts the rest")
check(DiffParser.hunkStarts("@@ -5 +7,2 @@") ?? (0, 0) == (5, 7), "hunk without counts")
let minified = DiffParser.parse("diff --git a/m b/m\n--- a/m\n+++ b/m\n@@ -0,0 +1 @@\n+" + String(repeating: "x", count: 5000) + "\n")[0]
check(minified.hunks[0].lines[0].text == String(repeating: "x", count: 2000) + " … 3000 more", "long lines are cut with a count")

let crlf = DiffParser.parse("diff --git a/w b/w\r\n--- a/w\r\n+++ b/w\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n")
check(crlf.first?.hunks.first?.lines.map(\.text) == ["a", "b"] && crlf.first?.hiddenChars == false, "CRLF lines split cleanly")
let trojan = DiffParser.parse("diff --git a/t\u{200B}.rs b/t\u{200B}.rs\n--- a/t\u{200B}.rs\n+++ b/t\u{200B}.rs\n@@ -1 +1 @@ fn \u{202E}x\n-a\n+if ok {\u{202E} }\u{1B}[2J\n")[0]
check(trojan.path == "t\u{200B}.rs" && trojan.shown == "t⟨U+200B⟩.rs" && trojan.hiddenChars, "a path keeps its raw key, is drawn spelled out, flagged")
check(trojan.hunks[0].header.contains("⟨U+202E⟩"), "and in a hunk header")
check(trojan.hunks[0].lines.map { "\($0.hidden)" } == ["false", "true"], "only the line with them is flagged")
check(trojan.hunks[0].lines[1].text == "if ok {⟨U+202E⟩ }⟨U+001B⟩[2J", "bidi and escape spelled out")
check(Visible.text("a\u{2067}b\u{00AD}c\u{FEFF}") == "a⟨U+2067⟩b⟨U+00AD⟩c⟨U+FEFF⟩", "isolates, soft hyphen, BOM")
check(Visible.text("a\u{2028}b\u{3164}c\u{FE0F}d\u{E0100}") == "a⟨U+2028⟩b⟨U+3164⟩c⟨U+FE0F⟩d⟨U+E0100⟩", "separators, fillers, variation selectors")
// A literal placeholder can't pass for a real one: every ⟨ drawn starts an escape.
check(Visible.text("⟨U+202E⟩") == "⟨U+27E8⟩U+202E⟩" && Visible.text("⟨U+202E⟩") != Visible.text("\u{202E}"), "literal ⟨ escaped")
let fake = DiffParser.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+see ⟨U+202E⟩ here\n")[0]
check(!fake.hiddenChars && fake.hunks[0].lines.allSatisfy { !$0.hidden }, "a literal ⟨ isn't flagged as hidden")

// MARK: Tree

let tree = FileTree(paths: ["Sources/Haunt/Notify/FocusTracker.swift", "Sources/Haunt/Notify/HauntNotifier.swift",
                            "Sources/Haunt/Settings/Settings.swift", "Tests/HauntTests/NotifyTests.swift", "Resources/defaults.toml"])
let shape = tree.items.map { i in i.dir.map { "\(i.depth)\($0)" } ?? "\(i.depth)#\(i.file!)" }
check(shape == ["0Sources/Haunt/", "1Notify/", "2#0", "2#1", "1Settings/", "2#2", "0Tests/HauntTests/", "1#3", "0Resources/", "1#4"],
      "mockup tree \(shape)")

// MARK: Checks

check(Checks.isCheck("swift test --filter NotifyTests"), "swift test")
check(Checks.isCheck("cd macos && ./build.sh"), "build script")
check(Checks.isCheck("FOO=1 cargo test --workspace 2>&1 | tail"), "env and pipe")
check(Checks.isCheck("npm run lint"), "npm run lint")
check(Checks.isCheck("uv run pytest -q"), "uv run pytest")
check(!Checks.isCheck("npm run dev"), "dev server is no check")
check(!Checks.isCheck("git status"), "git status")
check(!Checks.isCheck("cat Cargo.toml"), "cat")
check(!Checks.isCheck("cargo"), "bare cargo")

let turnChecks = Checks.fromTurn([
    TurnCommand(command: "swift build", outcome: .failed), TurnCommand(command: "ls", outcome: .passed),
    TurnCommand(command: "swift build", outcome: .passed), TurnCommand(command: "swift test --filter NotifyTests", outcome: .unknown),
])
check(turnChecks == [Check(command: "swift build", state: .passed), Check(command: "swift test --filter NotifyTests", state: .unknown)],
      "latest run wins: \(turnChecks)")
// A pass is the check's only when nothing after it decides the exit status.
for (cmd, passed) in [("cargo test", true), ("cd core && cargo test --workspace", true), ("cargo test 2>&1", true),
                      ("cargo test;", true), ("cargo test -- 'a|b'", true), ("FOO=1 cargo test &>log", true),
                      ("cargo test | tail -5", false), ("cargo test |& tee log", false), ("cargo test || true", false),
                      ("cargo test; echo done", false), ("cargo test &", false), ("cargo test && echo ok", false)] {
    let got = Checks.fromTurn([TurnCommand(command: cmd, outcome: .passed)]).first?.state
    check(got == (passed ? .passed : .unknown), "\(cmd): \(String(describing: got))")
}
check(Checks.fromTurn([TurnCommand(command: "cargo test | tail", outcome: .failed)]).first?.state == .failed, "a failure still counts")
check(Checks.checkSegment("cd macos && FOO=1 swift test --filter X 2>&1 | tail -5") == "FOO=1 swift test --filter X 2>&1", "the check itself")
let rr = ReviewState(surfaceId: "r")
rr.checks = Checks.fromTurn([TurnCommand(command: "cd core && cargo test -p haunt-core 2>&1 | tail -20", outcome: .passed)])
check(rr.checks.first?.state == .unknown && rr.rerun == "cargo test -p haunt-core 2>&1", "Rerun names only the check: \(rr.rerun ?? "nil")")
let spelled = Visible.turn(turn(1, finished: true, [TurnCommand(command: "cargo test ⟨x⟩", outcome: .unknown)]))
check(Checks.fromTurn(spelled.commands).first?.command == "cargo test ⟨U+27E8⟩x⟩", "spelled out once, not twice")

let exp = Checks.expected(files: ["Package.swift", ".swiftlint.yml", "package.json", "yarn.lock"], packageScripts: ["test"])
check(exp.map(\.0) == ["swift test", "yarn test", "swiftlint"], "expected \(exp)")
let merged = Checks.merge(turn: turnChecks, expected: exp)
check(merged.dropFirst(2).map { "\($0.command)|\($0.result)|\($0.source ?? "")" }
      == ["swift test|not run|full suite", "yarn test|not run|package.json", "swiftlint|not run|.swiftlint.yml"], "merged \(merged)")
check(Checks.merge(turn: [Check(command: "cargo test --workspace", state: .passed)], expected: [("cargo test", "Cargo.toml")]).count == 1,
      "a full run covers the expected check")
check(Checks.expected(files: ["package.json"], packageScripts: []).isEmpty, "no test script, no npm test")

// MARK: Draft and send-back

let draft = Draft.build(comments: [
    ReviewComment(path: "Sources/HauntNotifier.swift", line: 64, deleted: false, text: "Keep \"Tink\" as the default."),
    ReviewComment(path: "Settings.swift", line: 14, deleted: false, text: "Same here, revert this line.\n"),
], rerun: "swift test --filter NotifyTests")
check(draft == """
    Two changes from review:

    1. HauntNotifier.swift:64
    Keep "Tink" as the default.

    2. Settings.swift:14
    Same here, revert this line.

    Keep everything else. Rerun swift test --filter NotifyTests.
    """, "draft \(draft)")
check(Draft.build(comments: [], note: "Looks fine", rerun: nil) == "Looks fine", "note only")

// Newlines would act as Return without bracketed paste, which libghostty can't report: one line.
check(SendBack.check(draft + "\n\n") == .ok(SendBack.oneLine(draft)), "trailing newlines are dropped, never sent as Return")
if case let .ok(t) = SendBack.check(draft) { check(!t.contains("\n") && t.hasPrefix("Two changes from review: 1. HauntNotifier.swift:64 Keep"), "one line \(t)") }
check(SendBack.check("a\r\nb") == .ok("a b"), "CRLF")

func row(_ id: String, kind: RowKind = .claude, needsYou: Bool = false, pending: PendingRequest? = nil) -> Row {
    Row(surfaceId: id, kind: kind, name: id, meta: "", statusText: "", needsYou: needsYou, progress: nil, subagents: [],
        selected: true, pending: pending)
}
func refusal(_ r: Row?, selected: String = "a", unresolved: Bool = false) -> String? {
    SendBack.refusal(surfaceId: "a", row: r, selected: selected, unresolved: unresolved)
}
check(refusal(row("a")) == nil, "the reviewed agent tab, selected, nothing unresolved")
check(refusal(nil) != nil, "tab gone")
check(refusal(row("a"), selected: "b") != nil, "another tab selected")
check(refusal(row("a", kind: .shell)) != nil, "shell tab")
check(refusal(row("a", needsYou: true)) == SendBack.waiting, "needs you")
check(refusal(row("a", pending: PendingRequest(key: 1, tool: "Bash", preview: "rm", suspicious: false))) == SendBack.waiting,
      "a pending request")
check(refusal(row("a", needsYou: false), unresolved: true) == SendBack.waiting, "unresolved with needsYou false")
check(SendBack.check("  \n") == .blocked("The prompt is empty."), "empty")
if case .blocked = SendBack.check("ok\u{1B}[201~rm -rf ~") {} else { check(false, "paste end blocks") }
if case .blocked = SendBack.check("x\u{1B}[31m") {} else { check(false, "escape blocks") }
if case .blocked = SendBack.check("a\u{202E}b") {} else { check(false, "bidi override blocks") }
if case .blocked = SendBack.check("a\rb") {} else { check(false, "lone CR blocks") }
if case .blocked = SendBack.check("a\u{7}") {} else { check(false, "BEL blocks") }
check(SendBack.check("a\tb") == .ok("a\tb"), "tab allowed")

// MARK: Inbox

func turn(_ n: UInt32, finished: Bool, _ cmds: [TurnCommand]) -> ReviewTurn {
    ReviewTurn(agent: .claude, number: n, prompt: "p", cwd: "/x/haunt", startedMs: 1, finishedMs: finished ? 2 : nil, failed: false,
               headAtStart: nil, toolCount: 0, editCount: 0, tasks: [], commands: cmds, files: [], subagents: [])
}
func entry(_ name: String, _ t: ReviewTurn) -> InboxEntry {
    let s = ReviewState(surfaceId: name)
    s.turn = t
    s.diff = ReviewDiff(root: "/x/haunt", files: [FileDiff(path: "a"), FileDiff(path: "b")], branch: name, upstream: nil, commits: 0,
                        baseNote: "HEAD", uncommitted: true, repo: "haunt")
    return InboxEntry(surfaceId: name, row: Row(surfaceId: name, kind: .claude, name: "tab-" + name, meta: "", statusText: "",
                                                 needsYou: false, progress: nil, subagents: [], selected: false, pending: nil), state: s)
}
let ready = entry("ready", turn(3, finished: true, [TurnCommand(command: "swift test", outcome: .passed)]))
let waiting = entry("waiting", turn(1, finished: false, [TurnCommand(command: "cargo test -p core", outcome: .running)]))
let busy = entry("busy", turn(1, finished: false, [TurnCommand(command: "ls", outcome: .running)]))
let sent = entry("sent", turn(5, finished: false, []))
sent.sentBack = Inbox.sentBack(notes: 2, sentTurn: 4, turn: sent.state.turn)
let approved = entry("approved", turn(2, finished: true, [TurnCommand(command: "swift test", outcome: .unknown)]))
approved.state.approved = true
let named = entry("n", turn(1, finished: true, []))
named.row.name = "tab\u{202E}evil"
check(named.meta.contains("tab⟨U+202E⟩evil") && named.tabName == "tab⟨U+202E⟩evil", "a tab name is spelled out \(named.meta)")
let treeState = ReviewState(surfaceId: "t")
treeState.diff = ReviewDiff(root: "/r", files: [FileDiff(path: "a/x")], branch: nil, upstream: nil, commits: 0, baseNote: "HEAD", uncommitted: false)
_ = treeState.tree
treeState.diff?.files.append(FileDiff(path: "b"))
check(treeState.tree.fileOrder.count == 2, "the cached tree follows a new diff")
check(ready.status == .ready && ready.meta == "haunt · tab-ready · 2 files · tests ✓", "ready \(ready.meta)")
check(waiting.status == .waiting && waiting.meta == "haunt · tab-waiting · cargo test -p core running", "waiting \(waiting.meta)")
check(busy.status == .ready, "a running non-check isn't waiting on checks")
check(sent.status == .changesRequested && sent.meta == "haunt · tab-sent · agent working on 2 notes", "sent \(sent.meta)")
check(approved.status == .approved && approved.tests == "tests ran", "approved, codex-style unknown result isn't a pass")
check(Inbox.sentBack(notes: 2, sentTurn: 4, turn: turn(4, finished: true, [])).map { $0.pickedUp } == false, "not picked up yet")
check(Inbox.sentBack(notes: 2, sentTurn: 4, turn: turn(5, finished: true, [])) == nil, "the next turn finished: ready again")
check(Inbox.grouped([approved, sent, ready, waiting, busy]).map(\.label)
      == ["Ready for review · 2", "Changes requested · 1", "Waiting on checks · 1", "Approved · 1"], "groups")

let hs = Highlight.spans(#"  let q = DispatchQueue(label: "haunt") // why"#).filter { $0.1 != .plain }.map { $0.1 }
check(hs == [.keyword, .string, .comment], "highlight \(hs)")
check(Highlight.spans("letter = selfish").allSatisfy { $0.1 == .plain }, "keywords only as whole words")

// MARK: A real repository

// The app takes only a root-owned git (GitRunner.trusted); the tests use a newer one if there is one,
// so the working-tree paths that need git 2.40 run too.
let appGit = GitRunner.gitPath
if let newer = ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first(where: FileManager.default.isExecutableFile(atPath:)) {
    GitRunner.gitPath = newer
}

func sh(_ args: [String], _ dir: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "HOME": dir,
                     "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}

let repo = FileManager.default.temporaryDirectory.appendingPathComponent("haunt-review-test-\(getpid())").path
try? FileManager.default.removeItem(atPath: repo)
try! FileManager.default.createDirectory(atPath: repo + "/sub", withIntermediateDirectories: true)
func write(_ path: String, _ s: String) { try! s.write(toFile: repo + "/" + path, atomically: true, encoding: .utf8) }
write("a.txt", "one\ntwo\n")
write("gone.txt", "bye\n")
sh(["git", "init", "-q", "-b", "main"], repo)
sh(["git", "add", "a.txt", "gone.txt"], repo)
sh(["git", "commit", "-q", "-m", "one"], repo)
let start = GitRunner.run(["rev-parse", "HEAD"], cwd: repo)!.text.trimmingCharacters(in: .newlines)
write("a.txt", "one\nTWO\n")
sh(["git", "commit", "-q", "-am", "during the turn"], repo)
write("a.txt", "one\nTWO\nthree\n")
write("sub/new.txt", "fresh\n")
try! FileManager.default.removeItem(atPath: repo + "/gone.txt")
// A hostile fsmonitor hook, set up last so the setup's own git runs don't trip it.
write("evil.sh", "#!/bin/sh\ntouch \(repo)/PWNED\n")
sh(["chmod", "+x", "evil.sh"], repo)
sh(["git", "config", "core.fsmonitor", repo + "/evil.sh"], repo)

switch ReviewLoader.load(cwd: repo + "/sub", headAtStart: start) {
case let .success(d):
    let byPath = Dictionary(uniqueKeysWithValues: d.files.map { ($0.path, $0) })
    check(Set(byPath.keys) == ["a.txt", "gone.txt", "sub/new.txt", "evil.sh"], "files \(byPath.keys.sorted())")
    check(byPath["a.txt"].map { ($0.additions, $0.deletions) } ?? (0, 0) == (2, 1), "commit during the turn and the working tree")
    check(byPath["gone.txt"]?.status == .deleted, "deleted file")
    check(byPath["sub/new.txt"]?.status == .added, "untracked shown as new")
    check(d.commits == 1 && d.baseNote == "the commit the turn started on", "base \(d.commits) \(d.baseNote)")
    check(d.branch == "main" && d.uncommitted && d.root.hasSuffix(repo.split(separator: "/").last.map(String.init) ?? ""), "repo info")
    check(d.repo == (repo as NSString).lastPathComponent && d.base == start && d.head != nil && d.head != start, "repo \(d.repo ?? "nil"), base and head")
case let .failure(e):
    check(false, "load failed: \(e)")
}
if case let .success(d) = ReviewLoader.load(cwd: repo, headAtStart: nil) {
    check(d.files.first { $0.path == "a.txt" }.map { ($0.additions, $0.deletions) } ?? (0, 0) == (1, 0), "without a start, vs HEAD")
    check(d.notes.contains { $0.contains("doesn't know where the turn started") }, "and says so")
}
// An external diff driver turns the working tree off: only the turn's commit is shown.
sh(["git", "config", "diff.external", repo + "/evil.sh"], repo)
if case let .success(d) = ReviewLoader.load(cwd: repo, headAtStart: start) {
    check(d.files.map(\.path) == ["a.txt"] && d.files[0].additions == 1 && !d.uncommitted, "committed range only \(d.files.map(\.path))")
} else {
    check(false, "load with diff.external failed")
}
check(!FileManager.default.fileExists(atPath: repo + "/PWNED"), "no external diff or fsmonitor hook ran")
check(ReviewLoader.load(cwd: "/", headAtStart: nil) == .failure(.notARepo("/")), "not a repo")
try? FileManager.default.removeItem(atPath: repo)

func fresh() {
    try? FileManager.default.removeItem(atPath: repo)
    try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
}
func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: repo + "/" + name) }
func elapsed(_ f: () -> Void) -> TimeInterval { let t = Date(); f(); return Date().timeIntervalSince(t) }

// Hostile filter drivers named by .gitattributes, including names a `-c filter.<name>...` string would misparse.
fresh()
for f in ["a.txt", "b.md", "c.cfg", "d.ini"] { write(f, "one\n") }
write(".gitattributes", "*.txt filter=evil\n*.md filter=Ev.il\n*.cfg filter=proc\n*.ini filter=x=y.z\n")
sh(["git", "init", "-q", "-b", "main"], repo)
sh(["git", "add", "-A"], repo)
sh(["git", "commit", "-q", "-m", "one"], repo)
let filterStart = GitRunner.run(["rev-parse", "HEAD"], cwd: repo)!.text.trimmingCharacters(in: .newlines)
write("a.txt", "one\ncommitted\n")
sh(["git", "commit", "-q", "-am", "two"], repo)
write("evil.sh", "#!/bin/sh\ntouch \(repo)/FILTERED\ncat\n")
sh(["chmod", "+x", "evil.sh"], repo)
let cfg = try! String(contentsOfFile: repo + "/.git/config", encoding: .utf8)
try! (cfg + """
[filter "evil"]
\tclean = \(repo)/evil.sh
[filter "Ev.il"]
\tclean = \(repo)/evil.sh
[filter "proc"]
\tprocess = \(repo)/evil.sh
\trequired = true
[filter "x=y.z"]
\tclean = \(repo)/evil.sh

""").write(toFile: repo + "/.git/config", atomically: true, encoding: .utf8)
sleep(1)
for f in ["a.txt", "b.md", "c.cfg", "d.ini"] { write(f, "one\ntwo\n") }
// The fixture really is hostile: plain git runs the filter.
sh(["git", "diff"], repo)
check(exists("FILTERED"), "plain git diff runs the hostile filter (test is live)")
try? FileManager.default.removeItem(atPath: repo + "/FILTERED")
sh(["touch", "a.txt", "b.md", "c.cfg", "d.ini"], repo)
check(GitRunner.definesDrivers(cwd: repo) == true, "filters are seen")
switch ReviewLoader.load(cwd: repo, headAtStart: filterStart) {
case let .success(d):
    check(d.files.map(\.path) == ["a.txt"], "only the committed range \(d.files.map(\.path))")
    check(d.files.first.map { ($0.additions, $0.deletions) } ?? (0, 0) == (1, 0), "committed lines only")
    check(d.notes.contains { $0.contains("defines git filters or diff drivers") }, "and says why")
case let .failure(e):
    check(false, "load with filters failed: \(e)")
}
check(!exists("FILTERED"), "no filter driver ran")
// A filter that appears after the check: the attributes come from the empty tree, so the worktree's don't apply.
if GitRunner.supportsAttrSource {
    _ = GitRunner.run(["diff", "--no-ext-diff", "--no-textconv"], cwd: repo)
    _ = GitRunner.run(["diff", "--quiet", "--no-ext-diff", "--no-textconv", "HEAD", "--"], cwd: repo)
    check(!exists("FILTERED"), "GIT_ATTR_SOURCE keeps the worktree's .gitattributes out")
} else {
    print("review: git < 2.40, skipping the GIT_ATTR_SOURCE check")
}

// A textconv or external diff driver alone also keeps the working tree out; harmless diff settings don't.
for (k, v) in [("diff.evil.textconv", "true"), ("diff.evil.command", "true"), ("diff.external", "true"), ("diff.renames", "true")] {
    fresh()
    sh(["git", "init", "-q", "-b", "main"], repo)
    sh(["git", "config", k, v], repo)
    check(GitRunner.definesDrivers(cwd: repo) == (k != "diff.renames"), "\(k) counts as a driver: \(k != "diff.renames")")
}
fresh()
sh(["git", "init", "-q", "-b", "main"], repo)
check(GitRunner.definesDrivers(cwd: repo) == false, "Haunt's own -c pins don't count")

// A partial clone missing a blob, with a promisor remote that would run a command.
fresh()
write("a.txt", "one\n")
sh(["git", "init", "-q", "-b", "main"], repo)
sh(["git", "add", "-A"], repo)
sh(["git", "commit", "-q", "-m", "one"], repo)
let pcStart = GitRunner.run(["rev-parse", "HEAD"], cwd: repo)!.text.trimmingCharacters(in: .newlines)
let blob = GitRunner.run(["rev-parse", "HEAD:a.txt"], cwd: repo)!.text.trimmingCharacters(in: .newlines)
write("a.txt", "two\n")
sh(["git", "commit", "-q", "-am", "two"], repo)
try! FileManager.default.removeItem(atPath: repo + "/.git/objects/" + blob.prefix(2) + "/" + blob.dropFirst(2))
for (k, v) in [("core.repositoryformatversion", "1"), ("extensions.partialClone", "origin"),
               ("remote.origin.promisor", "true"), ("remote.origin.url", "ext::sh -c touch% \(repo)/FETCHED")] {
    sh(["git", "config", k, v], repo)
}
sh(["git", "-c", "protocol.ext.allow=always", "diff", pcStart, "HEAD"], repo)
check(exists("FETCHED"), "plain git fetches the missing blob through the promisor (test is live)")
try? FileManager.default.removeItem(atPath: repo + "/FETCHED")
let pcTime = elapsed { _ = ReviewLoader.load(cwd: repo, headAtStart: pcStart) }
check(!exists("FETCHED") && pcTime < 10, "no lazy fetch ran (\(pcTime)s)")

// A FIFO in the untracked files: git diff --no-index would block reading it.
fresh()
write("a.txt", "one\n")
sh(["git", "init", "-q", "-b", "main"], repo)
sh(["git", "add", "-A"], repo)
sh(["git", "commit", "-q", "-m", "one"], repo)
check(mkfifo(repo + "/pipe", 0o600) == 0, "mkfifo")
write("link", "")
try! FileManager.default.removeItem(atPath: repo + "/link")
try! FileManager.default.createSymbolicLink(atPath: repo + "/link", withDestinationPath: "a.txt")
// Trojan Source: a bidi override in a line, a zero-width space in a name.
write("trojan.txt", "ok\nif (admin) {\u{202E} } \u{2066}// check\n")
write("zero\u{200B}width.txt", "x\n")
if GitRunner.supportsAttrSource {
    var loaded: Result<ReviewDiff, ReviewLoader.LoadError>?
    let fifoTime = elapsed { loaded = ReviewLoader.load(cwd: repo, headAtStart: nil) }
    check(fifoTime < 5, "a FIFO doesn't stall the review (\(fifoTime)s)")
    if case let .success(d)? = loaded {
        let byPath = Dictionary(uniqueKeysWithValues: d.files.map { ($0.path, $0) })
        // git's own listing skips FIFOs; the lstat check catches one that replaces a file after the listing.
        check(byPath["pipe"].map { $0.special && $0.hunks.isEmpty } ?? true, "a FIFO is never diffed")
        check(byPath["link"]?.hunks.first?.lines.map(\.text) == ["a.txt"], "a symlink shows its target")
        let t = byPath["trojan.txt"]
        check(t?.hiddenChars == true, "the file with a bidi override is flagged")
        let bad = t?.hunks.flatMap(\.lines).filter(\.hidden).map(\.text)
        check(bad == ["if (admin) {⟨U+202E⟩ } ⟨U+2066⟩// check"], "bidi spelled out \(bad ?? [])")
        check(t?.hunks.flatMap(\.lines).filter { !$0.hidden }.map(\.text) == ["ok"], "clean lines aren't flagged")
        let z = byPath["zero\u{200B}width.txt"]
        check(z?.hiddenChars == true && z?.shown == "zero⟨U+200B⟩width.txt" && z?.hunks.first?.lines.map(\.text) == ["x"],
              "zero-width name spelled out \(byPath.keys.sorted())")
    } else {
        check(false, "load with a FIFO failed")
    }
} else {
    print("review: git < 2.40, skipping the untracked-file checks")
}
try? FileManager.default.removeItem(atPath: repo)

// A file named with a literal placeholder next to one with the real character: two files, two keys.
fresh()
let literal = "a⟨U+202E⟩b.txt", real = "a\u{202E}b.txt"
write(literal, "one\n")
sh(["git", "init", "-q", "-b", "main"], repo)
sh(["git", "add", "-A"], repo)
sh(["git", "commit", "-q", "-m", "one"], repo)
write(literal, "one\ntwo\n")
write(real, "impostor\n")
if GitRunner.supportsAttrSource, case let .success(d) = ReviewLoader.load(cwd: repo, headAtStart: nil) {
    let lit = d.files.first { $0.path == literal }, imp = d.files.first { $0.path == real }
    check(d.files.count == 2 && lit?.status == .modified && imp?.status == .added, "both listed \(d.files.map(\.path))")
    check(lit?.shown == "a⟨U+27E8⟩U+202E⟩b.txt" && imp?.shown == "a⟨U+202E⟩b.txt", "drawn differently")
    check(lit?.hiddenChars == false && imp?.hiddenChars == true, "only the real one is flagged")
    let st = ReviewState(surfaceId: "s")
    st.viewed.insert(literal)
    check(!st.viewed.contains(real), "viewed state doesn't carry over")
} else {
    check(GitRunner.supportsAttrSource == false, "load with look-alike names failed")
}
try? FileManager.default.removeItem(atPath: repo)

// MARK: The runner

// A timeout kills the whole process group, including a child that would keep the pipe open.
let t0 = Date()
let hung = GitRunner.spawn("/bin/sh", ["-c", "sleep 30 & echo $!; sleep 30"], cwd: "/", env: [:], timeout: 1, maxBytes: 1 << 20)
let bgPid = pid_t(hung?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
check(hung?.timedOut == true && Date().timeIntervalSince(t0) < 4, "timed out promptly")
usleep(200_000)
check(bgPid > 0 && kill(bgPid, 0) != 0, "the background child was killed with its group")
let t1 = Date()
let orphan = GitRunner.spawn("/bin/sh", ["-c", "sleep 30 & echo started"], cwd: "/", env: [:], timeout: 1, maxBytes: 1 << 20)
check(orphan?.text == "started\n" && orphan?.status == 0 && Date().timeIntervalSince(t1) < 4, "a child left holding the pipe is killed")
let big = GitRunner.spawn("/bin/sh", ["-c", "yes | head -c 5000000"], cwd: "/", env: [:], timeout: 5, maxBytes: 1000)
check(big?.truncated == true && big?.data.count == 1000, "output cut at the cap")
check(GitRunner.spawn("/bin/sh", ["-c", "pwd; echo $HOME"], cwd: "/tmp", env: ["HOME": "/h"], timeout: 5, maxBytes: 100)?.text
      == "/private/tmp\n/h\n", "cwd and env reach the child")

// A git is used only if it and every folder above it belong to root or the user, writable by no one else
// but admin or wheel; links resolved.
check(GitRunner.trusted("/usr/bin/git") == "/usr/bin/git", "/usr/bin/git is trusted")
func real(_ p: String) -> String { let c = realpath(p, nil)!; defer { free(c) }; return String(cString: c) }
let tmp = real(NSTemporaryDirectory())
let gdir = tmp + "/haunt-git-\(getpid())", fakeGit = gdir + "/git"
try! FileManager.default.createDirectory(atPath: gdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
FileManager.default.createFile(atPath: fakeGit, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
check(GitRunner.trusted(fakeGit) == fakeGit, "a git the user owns, in folders only the user can write, is trusted")
chmod(fakeGit, 0o757)
check(GitRunner.trusted(fakeGit) == nil, "a world-writable git isn't")
chmod(fakeGit, 0o775)
chown(fakeGit, getuid(), 20)
check(GitRunner.trusted(fakeGit) == nil, "a git staff can write isn't")
chown(fakeGit, getuid(), 80)
check(GitRunner.trusted(fakeGit) == fakeGit, "a git admin can write is, like /opt/homebrew/bin")
chmod(fakeGit, 0o755)
chmod(gdir, 0o775)
chown(gdir, getuid(), 20)
check(GitRunner.trusted(fakeGit) == nil, "a folder staff can write isn't")
chmod(gdir, 0o755)
let inTmp = "/private/tmp/haunt-git-\(getpid())"
FileManager.default.createFile(atPath: inTmp, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
check(GitRunner.trusted(inTmp) == nil, "a git in a world-writable folder isn't")
try? FileManager.default.removeItem(atPath: inTmp)
let link = gdir + "/link"
try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/usr/bin/git")
check(GitRunner.trusted(link) == "/usr/bin/git", "a link is judged, and run, by its target")
try? FileManager.default.removeItem(atPath: gdir)
check(GitRunner.trusted("/sbin/../usr/sbin/nonexistent-git") == nil, "a missing path is skipped")
// This Mac's Homebrew: /usr/local/bin is the user's and admin-group, the Cellar admin-writable.
for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where FileManager.default.fileExists(atPath: p) {
    check(GitRunner.trusted(p) == real(p), "Homebrew's git as installed here is trusted: \(p) -> \(real(p))")
}
if let g = appGit { check(GitRunner.trusted(g) == g || g == "/usr/bin/git", "the app's own pick is trusted: \(g)") }

// A submodule with its own filter: the parent's config is clean, so only never looking inside keeps it from running.
fresh()
let inner = repo + "-inner"
try? FileManager.default.removeItem(atPath: inner)
try! FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
try! "a\n".write(toFile: inner + "/f", atomically: true, encoding: .utf8)
sh(["git", "init", "-q", "-b", "main"], inner)
sh(["git", "add", "f"], inner)
sh(["git", "commit", "-q", "-m", "i"], inner)
sh(["git", "init", "-q", "-b", "main"], repo)
sh(["git", "-c", "protocol.file.allow=always", "submodule", "add", "-q", inner, "sub"], repo)
sh(["git", "commit", "-q", "-m", "o"], repo)
let subGit = GitRunner.run(["rev-parse", "--absolute-git-dir"], cwd: repo + "/sub")!.text.trimmingCharacters(in: .newlines)
sh(["git", "config", "filter.evil.clean", "sh -c 'touch \(repo)/SUBPWNED; cat'"], repo + "/sub")
try! FileManager.default.createDirectory(atPath: subGit + "/info", withIntermediateDirectories: true)
try! "* filter=evil\n".write(toFile: subGit + "/info/attributes", atomically: true, encoding: .utf8)
try! "b\n".write(toFile: repo + "/sub/f", atomically: true, encoding: .utf8)
sh(["git", "diff", "HEAD"], repo)
check(exists("SUBPWNED"), "plain git runs the submodule's filter (test is live)")
try? FileManager.default.removeItem(atPath: repo + "/SUBPWNED")
check(GitRunner.definesDrivers(cwd: repo) == false, "the parent's own config is clean")
if case .failure = ReviewLoader.load(cwd: repo, headAtStart: nil) { check(false, "load with a submodule failed") }
check(!exists("SUBPWNED"), "no submodule filter ran")
// Moving the submodule's commit is a change the agent made, so it must still be listed.
sh(["git", "-c", "filter.evil.clean=cat", "commit", "-qam", "moved"], repo + "/sub")
try! "c\n".write(toFile: repo + "/sub/f", atomically: true, encoding: .utf8)
if case let .success(d) = ReviewLoader.load(cwd: repo, headAtStart: nil) {
    check(d.files.map(\.path) == ["sub"], "a moved submodule commit is listed: \(d.files.map(\.path))")
} else { check(false, "load after moving the submodule failed") }
check(!exists("SUBPWNED"), "no submodule filter ran with the gitlink moved")
try? FileManager.default.removeItem(atPath: repo)
try? FileManager.default.removeItem(atPath: inner)

if failures > 0 { print("review: \(failures) failed"); exit(1) }
print("review: ok")
