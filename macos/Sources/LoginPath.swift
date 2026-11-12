import Foundation

/// The login shell's PATH, for an app opened from Finder with launchd's bare PATH, which misses claude.
enum LoginPath {
    static let marker = "__HAUNT_PATH__"

    /// printenv keeps PATH colon-joined in any shell; fish's own $PATH would print space-separated.
    /// A login shell first; an interactive one only if that finds no PATH, since an interactive rc that
    /// touches a protected folder makes macOS ask the user on Haunt's behalf.
    static func fetch(shell: String, timeout: TimeInterval = 3) -> String? {
        let command = "printf '\\n\(marker)'; /usr/bin/printenv PATH"
        return run(shell, ["-l", "-c", command], timeout: timeout).flatMap(parse)
            ?? run(shell, ["-l", "-i", "-c", command], timeout: timeout).flatMap(parse)
    }

    /// Runs `shell` in its own process group, from an empty folder, with no input. After `timeout`, or as
    /// soon as it has answered, the whole group is killed and reaped, so nothing it started outlives it.
    static func run(_ shell: String, _ args: [String], timeout: TimeInterval) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("haunt-path-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: dir) }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        defer { close(fds[0]) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Its own group, so one kill reaches everything it started; no fd of ours but the pipe leaks in.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, dir.path)

        let argv = ([shell] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, shell, &actions, &attr, argv, environ)
        close(fds[1])
        guard spawned == 0 else { return nil }

        let fd = fds[0]
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var exited = false
        let deadline = Date().addingTimeInterval(timeout)
        // Until EOF, or EAGAIN once the shell has exited: a daemon it started may keep the pipe open.
        while Date() < deadline {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                data.append(buf, count: n)
                continue
            }
            if n == 0 || errno != EAGAIN && errno != EINTR { break }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                break
            }
            usleep(10_000)
        }
        // The group outlives a leader that has exited, so this also reaches what it left running.
        kill(-pid, SIGKILL)
        if !exited {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The line after the marker; anything the shell's startup files print comes before it.
    static func parse(_ output: String) -> String? {
        guard let r = output.range(of: marker, options: .backwards) else { return nil }
        let line = output[r.upperBound...].prefix { !$0.isNewline }
        return line.isEmpty ? nil : String(line)
    }

    /// The shell's PATH (else the inherited one), then the usual install folders, always ending in /usr/bin:/bin.
    static func compose(found: String?, inherited: String?, home: String) -> String {
        let extra = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return ([found ?? inherited].compactMap { $0 } + extra).joined(separator: ":")
    }
}
