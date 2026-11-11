import AppKit
import GhosttyKit

// Compile-only stand-ins for Ghostty app-target types the vendored wrapper casts to.
// Shape taken from Gutter's Shims.swift (github.com/akras14/gutter, MIT).

class BaseTerminalController: NSWindowController {
    var surfaceTree = SplitTree<Ghostty.SurfaceView>()
    var focusedSurface: Ghostty.SurfaceView?
    var titleOverride: String?
    var commandPaletteIsShowing = false
    var focusFollowsMouse = false
    func toggleBackgroundOpacity() {}
    func promptTabTitle() {}
    @IBAction func changeTabTitle(_ sender: Any) {}
}

class TerminalController: BaseTerminalController {
    func resizeWindow(_ surfaceView: Ghostty.SurfaceView, to size: NSSize) -> Bool { false }
}

class TerminalWindow: NSWindow {
    func isTabBar(_ childViewController: NSTitlebarAccessoryViewController) -> Bool { false }
}

class HiddenTitlebarTerminalWindow: TerminalWindow {}

enum TerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case windowDidNotLoad
}
