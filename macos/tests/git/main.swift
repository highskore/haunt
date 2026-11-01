import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("haunt-git-test-\(getpid())").path
let fm = FileManager.default
try? fm.removeItem(atPath: root)
var failed = 0

func check(_ name: String, _ got: String?, _ want: String?) {
    let ok = got == want
    if !ok { failed += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name): got \(got ?? "nil"), want \(want ?? "nil")")
}

func repo(_ name: String) -> String {
    let p = "\(root)/\(name)"
    try! fm.createDirectory(atPath: "\(p)/.git", withIntermediateDirectories: true)
    return p
}

let plain = repo("plain")
try! "ref: refs/heads/main\n".write(toFile: "\(plain)/.git/HEAD", atomically: true, encoding: .utf8)
try! fm.createDirectory(atPath: "\(plain)/sub", withIntermediateDirectories: true)
check("branch above", Git.branch(at: "\(plain)/sub"), "main")

let fifo = repo("fifo")
mkfifo("\(fifo)/.git/HEAD", 0o600)
let start = Date()
check("fifo HEAD", Git.branch(at: fifo), nil)
check("fifo HEAD returns at once", Date().timeIntervalSince(start) < 1 ? "fast" : "slow", "fast")

let zero = repo("zero")
try! fm.createSymbolicLink(atPath: "\(zero)/.git/HEAD", withDestinationPath: "/dev/zero")
check("/dev/zero HEAD symlink", Git.branch(at: zero), nil)

let zeroGit = "\(root)/zero-gitfile"
try! fm.createDirectory(atPath: zeroGit, withIntermediateDirectories: true)
try! fm.createSymbolicLink(atPath: "\(zeroGit)/.git", withDestinationPath: "/dev/zero")
check("/dev/zero .git symlink", Git.branch(at: zeroGit), nil)

let big = repo("big")
try! ("ref: refs/heads/" + String(repeating: "x", count: 10_000)).write(toFile: "\(big)/.git/HEAD", atomically: true, encoding: .utf8)
check("read capped at 4 KB", Git.branch(at: big).map { "\($0.utf8.count + 16)" }, "\(Git.maxRead)")

try? fm.removeItem(atPath: root)
print(failed == 0 ? "all passed" : "\(failed) failed")
exit(failed == 0 ? 0 : 1)
