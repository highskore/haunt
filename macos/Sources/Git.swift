import Foundation

/// Branch name from the nearest .git/HEAD above `path`, or the short hash when detached.
/// OSC 7 lets anything in the pty pick `path`, so files are read only if regular, unfollowed, and small.
enum Git {
    static let maxRead = 4096

    static func branch(at path: String) -> String? {
        let fm = FileManager.default
        var dir = (path as NSString).standardizingPath
        while !dir.isEmpty {
            let git = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                var gitDir = git
                if !isDir.boolValue {
                    guard let s = readSmall(git), s.hasPrefix("gitdir:") else { return nil }
                    let p = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDir = p.hasPrefix("/") ? p : (dir as NSString).appendingPathComponent(p)
                }
                guard let head = readSmall((gitDir as NSString).appendingPathComponent("HEAD")) else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                return h.hasPrefix("ref: refs/heads/") ? String(h.dropFirst(16)) : String(h.prefix(7))
            }
            if dir == "/" { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Never blocks on a FIFO or follows a symlink to /dev/zero: regular files only, at most `maxRead` bytes.
    static func readSmall(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        var buf = [UInt8](repeating: 0, count: maxRead)
        let n = read(fd, &buf, maxRead)
        guard n >= 0 else { return nil }
        return String(decoding: buf[..<n], as: UTF8.self)
    }
}
