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

// Fake shells: called as <shell> -l -i -c <command>.
let dir = CommandLine.arguments[1]
func shell(_ name: String, _ body: String) -> String {
    let path = "\(dir)/\(name)"
    try! "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return path
}
func timed(_ f: () -> String?) -> (String?, TimeInterval) {
    let t = Date()
    let r = f()
    return (r, Date().timeIntervalSince(t))
}

let spaced = shell("spaced", "echo 'motd from .zprofile'\nexport PATH='/opt/my tools/bin:/usr/bin:/bin'\nexec /bin/sh -c \"$4\"")
check(LoginPath.fetch(shell: spaced) == "/opt/my tools/bin:/usr/bin:/bin", "fetch through a chatty shell with spaces in PATH")

let lingering = shell("lingering", "export PATH=/lingering/bin:/usr/bin:/bin\n/bin/sh -c \"$4\"\n/bin/sleep 30 &")
let (r1, t1) = timed { LoginPath.fetch(shell: lingering, timeout: 3) }
check(r1 == "/lingering/bin:/usr/bin:/bin" && t1 < 2, "a background child holding the pipe doesn't block or drop the output (\(r1 ?? "nil"), \(t1)s)")

let hanging = shell("hanging", "exec /bin/sleep 30")
let (r2, t2) = timed { LoginPath.fetch(shell: hanging, timeout: 1) }
check(r2 == nil && t2 < 2, "a hanging shell times out (\(t2)s)")

check(LoginPath.fetch(shell: "\(dir)/missing") == nil, "a missing shell")

if failures > 0 { exit(1) }
print("loginpath: ok")
