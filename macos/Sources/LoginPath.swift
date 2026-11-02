import Foundation

/// The login shell's PATH, for an app opened from Finder with launchd's bare PATH, which misses claude.
enum LoginPath {
    static let marker = "__HAUNT_PATH__"

    /// printenv keeps PATH colon-joined in any shell; fish's own $PATH would print space-separated.
    static func fetch(shell: String, timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", "printf '\\n\(marker)'; /usr/bin/printenv PATH"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        // Until EOF, or EAGAIN once the shell has exited: a daemon it started may keep the pipe open.
        while Date() < deadline {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                data.append(buf, count: n)
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) || !p.isRunning {
                break
            } else {
                usleep(10_000)
            }
        }
        if p.isRunning { p.terminate() }
        return parse(String(decoding: data, as: UTF8.self))
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
