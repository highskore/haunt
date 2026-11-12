import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL \(what)") }
}

let m = LoginPath.marker
check(LoginPath.parse("Last login: today\nwelcome\n\(m)/opt/my tools/bin:/usr/bin\n") == "/opt/my tools/bin:/usr/bin", "parse keeps spaces")
check(LoginPath.parse("\(m)/a:/b\r\n") == "/a:/b", "parse stops at CR")
check(LoginPath.parse("no marker here\n") == nil, "parse without marker")
check(LoginPath.parse("\n\(m)\n") == nil, "parse empty")

let composed = LoginPath.compose(found: "/opt/my tools/bin", inherited: "/x", home: "/Users/u")
check(composed.hasPrefix("/opt/my tools/bin:/Users/u/.local/bin:"), "compose leads with the shell's PATH")
check(composed.hasSuffix(":/usr/bin:/bin"), "compose always ends in /usr/bin:/bin")
check(LoginPath.compose(found: nil, inherited: nil, home: "/h").hasSuffix(":/usr/bin:/bin"), "compose with nothing found")

// Fake shells: called as <shell> -l -c <command>, then <shell> -l -i -c <command> if that found no PATH.
let dir = CommandLine.arguments[1]
func shell(_ name: String, _ body: String) -> String {
    let path = "\(dir)/\(name)"
    try! "#!/bin/sh\nfor last; do :; done\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return path
}
func timed(_ f: () -> String?) -> (String?, TimeInterval) {
    let t = Date()
    let r = f()
    return (r, Date().timeIntervalSince(t))
}

let spaced = shell("spaced", "echo 'motd from .zprofile'\nexport PATH='/opt/my tools/bin:/usr/bin:/bin'\nexec /bin/sh -c \"$last\"")
check(LoginPath.fetch(shell: spaced) == "/opt/my tools/bin:/usr/bin:/bin", "fetch through a chatty shell with spaces in PATH")

let lingering = shell("lingering", "export PATH=/lingering/bin:/usr/bin:/bin\n/bin/sh -c \"$last\"\n/bin/sleep 30 &")
let (r1, t1) = timed { LoginPath.fetch(shell: lingering, timeout: 3) }
check(r1 == "/lingering/bin:/usr/bin:/bin" && t1 < 2, "a background child holding the pipe doesn't block or drop the output (\(r1 ?? "nil"), \(t1)s)")

let hanging = shell("hanging", "exec /bin/sleep 30")
let (r2, t2) = timed { LoginPath.fetch(shell: hanging, timeout: 1) }
check(r2 == nil && t2 < 3, "a hanging shell times out, login then interactive (\(t2)s)")

func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
func pids(_ file: String) -> [pid_t] {
    ((try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
}

// One that ignores TERM and HUP and leaves a child: both are killed, every time.
let stubborn = shell("stubborn", "trap '' TERM HUP\necho $$ >> \(dir)/stubborn.pids\n/bin/sleep 1000 &\necho $! >> \(dir)/stubborn.pids\nwhile :; do /bin/sleep 1; done")
let (r3, t3) = timed { LoginPath.fetch(shell: stubborn, timeout: 1) }
let killed = pids("stubborn.pids")
check(r3 == nil && t3 < 3, "a stubborn shell times out (\(t3)s)")
check(killed.count == 4, "both tries ran, each with a child: \(killed)")
check(!killed.contains(where: alive), "no shell or child outlives the lookup: \(killed.filter(alive))")

// A login shell is enough when it has the PATH; -i only when it hasn't.
let login = shell("login", "echo \"$1 $2\" >> \(dir)/login.args\nexport PATH=/login/bin:/usr/bin:/bin\nexec /bin/sh -c \"$last\"")
check(LoginPath.fetch(shell: login) == "/login/bin:/usr/bin:/bin", "login shell PATH")
let loginArgs = (try? String(contentsOfFile: "\(dir)/login.args", encoding: .utf8)) ?? ""
check(loginArgs == "-l -c\n", "no interactive shell when the login one answers: \(loginArgs)")

let rcOnly = shell("rconly", "echo \"$1 $2\" >> \(dir)/rconly.args\ncase \"$2\" in -i) export PATH=/rc/bin:/usr/bin:/bin; exec /bin/sh -c \"$last\" ;; esac\nexit 0")
check(LoginPath.fetch(shell: rcOnly) == "/rc/bin:/usr/bin:/bin", "falls back to -i when the login shell finds no PATH")
let rcArgs = ((try? String(contentsOfFile: "\(dir)/rconly.args", encoding: .utf8)) ?? "").split(separator: "\n")
check(rcArgs == ["-l -c", "-l -i"], "login, then interactive: \(rcArgs)")

// It runs from an empty folder of its own, removed afterwards: never / or the user's home.
let whereabouts = shell("where", "pwd -P > \(dir)/where.txt\nls -A | wc -l | tr -d ' ' >> \(dir)/where.txt\nexport PATH=/w:/usr/bin:/bin\nexec /bin/sh -c \"$last\"")
check(LoginPath.fetch(shell: whereabouts) == "/w:/usr/bin:/bin", "where: PATH")
let place = ((try? String(contentsOfFile: "\(dir)/where.txt", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
check(place.count == 2 && place[0].contains("haunt-path-") && place[1] == "0", "an empty folder of its own: \(place)")
check(place.first.map { !FileManager.default.fileExists(atPath: $0) } ?? false, "the folder is removed")

check(LoginPath.fetch(shell: "\(dir)/missing") == nil, "a missing shell")

if failures > 0 { exit(1) }
print("loginpath: ok")
