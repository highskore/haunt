import Foundation

/// Branch name from the nearest .git/HEAD above `path`, or the short hash when detached.
enum Git {
    static func branch(at path: String) -> String? {
        let fm = FileManager.default
        var dir = (path as NSString).standardizingPath
        while !dir.isEmpty {
            let git = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                var gitDir = git
                if !isDir.boolValue {
                    guard let s = try? String(contentsOfFile: git, encoding: .utf8), s.hasPrefix("gitdir:") else { return nil }
                    let p = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDir = p.hasPrefix("/") ? p : (dir as NSString).appendingPathComponent(p)
                }
                let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
                guard let head = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                return h.hasPrefix("ref: refs/heads/") ? String(h.dropFirst(16)) : String(h.prefix(7))
            }
            if dir == "/" { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
