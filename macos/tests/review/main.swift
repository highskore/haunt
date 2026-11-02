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

check(SendBack.check(draft + "\n\n") == .ok(draft), "trailing newlines are dropped, never sent as Return")
check(SendBack.check("a\r\nb") == .ok("a\nb"), "CRLF")
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
// A hostile external diff driver and fsmonitor hook, set up last so the setup's own git runs don't trip them.
write("evil.sh", "#!/bin/sh\ntouch \(repo)/PWNED\n")
sh(["chmod", "+x", "evil.sh"], repo)
sh(["git", "config", "diff.external", repo + "/evil.sh"], repo)
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
check(!FileManager.default.fileExists(atPath: repo + "/PWNED"), "no external diff or fsmonitor hook ran")
check(ReviewLoader.load(cwd: "/", headAtStart: nil) == .failure(.notARepo("/")), "not a repo")
try? FileManager.default.removeItem(atPath: repo)

// Hostile filter drivers named by .gitattributes: a working-tree diff would run `clean` or `process`.
try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
write("a.txt", "one\n")
write("b.md", "one\n")
write("c.cfg", "one\n")
write(".gitattributes", "*.txt filter=evil\n*.md filter=Ev.il\n*.cfg filter=proc\n")
sh(["git", "init", "-q", "-b", "main"], repo)
sh(["git", "add", "-A"], repo)
sh(["git", "commit", "-q", "-m", "one"], repo)
write("evil.sh", "#!/bin/sh\ntouch \(repo)/FILTERED\ncat\n")
sh(["chmod", "+x", "evil.sh"], repo)
for (k, v) in [("filter.evil.clean", repo + "/evil.sh"), ("filter.Ev.il.clean", repo + "/evil.sh"),
               ("filter.proc.process", repo + "/evil.sh"), ("filter.proc.required", "true")] {
    sh(["git", "config", k, v], repo)
}
sleep(1)
for f in ["a.txt", "b.md", "c.cfg"] { write(f, "one\ntwo\n") }
// The fixture really is hostile: plain git runs the filter.
sh(["git", "diff"], repo)
check(FileManager.default.fileExists(atPath: repo + "/FILTERED"), "plain git diff runs the hostile filter (test is live)")
try? FileManager.default.removeItem(atPath: repo + "/FILTERED")
sh(["touch", "a.txt", "b.md", "c.cfg"], repo)
switch ReviewLoader.load(cwd: repo, headAtStart: nil) {
case let .success(d):
    check(Set(d.files.map(\.path)).isSuperset(of: ["a.txt", "b.md", "c.cfg"]), "filtered files still diffed \(d.files.map(\.path))")
case let .failure(e):
    check(false, "load with filters failed: \(e)")
}
check(!FileManager.default.fileExists(atPath: repo + "/FILTERED"), "no filter driver ran")
check(GitRunner.filterOverrides(cwd: repo).map(Set.init) == Set(["evil", "Ev.il", "proc"].flatMap { n in
    ["filter.\(n).clean=", "filter.\(n).smudge=", "filter.\(n).process=", "filter.\(n).required=false"] }), "overrides every driver")
try? FileManager.default.removeItem(atPath: repo)

if failures > 0 { print("review: \(failures) failed"); exit(1) }
print("review: ok")
