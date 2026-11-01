import AppKit
import GhosttyKit

if let res = Bundle.main.resourceURL {
    setenv("GHOSTTY_RESOURCES_DIR", res.appendingPathComponent("ghostty").path, 1)
}

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    FileHandle.standardError.write("ghostty_init failed\n".data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
