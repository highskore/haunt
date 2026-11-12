import Foundation

/// Keeps a key the user is holding from typing into a tab it wasn't pressed in, and a plugin's tab switch
/// from turning a held or quick Return into the answer to the new tab's prompt.
final class KeyGuard {
    static let shared = KeyGuard()
    /// How long after a plugin switches tabs a Return on a tab with a request is dropped.
    static let settle: TimeInterval = 0.4

    /// The terminal that got the press the current repeats belong to; nil once focus moves.
    private var pressedIn: AnyHashable?
    private var pluginSwitch: (surfaceId: String, at: TimeInterval)?

    /// Return and keypad Enter.
    static func isReturn(keyCode: UInt16) -> Bool { keyCode == 36 || keyCode == 76 }

    /// A terminal became first responder: no key held before counts as pressed in it.
    func focusMoved() {
        pressedIn = nil
    }

    /// A plugin brought `surfaceId` forward (focusTab, a panel button's or hold summary's tab).
    func pluginSwitched(to surfaceId: String, at now: TimeInterval) {
        pluginSwitch = (surfaceId, now)
    }

    /// Whether a keyDown in terminal `view` (tab `surfaceId`) goes on. `awaitsAnswer` is the core's
    /// `hasUnresolved`, the request half of what keeps a plugin from typing there.
    func allows(view: AnyHashable, surfaceId: String, isRepeat: Bool, isReturn: Bool,
                awaitsAnswer: () -> Bool, now: TimeInterval) -> Bool {
        if isRepeat, pressedIn != view { return false }
        if isReturn, let s = pluginSwitch, s.surfaceId == surfaceId, now - s.at < Self.settle, awaitsAnswer() {
            // The whole hold is dropped, not only this press.
            pressedIn = nil
            return false
        }
        if !isRepeat { pressedIn = view }
        return true
    }
}
