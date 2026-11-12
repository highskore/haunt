import Foundation

/// Keeps a key the user is holding from typing into a tab it wasn't pressed in, and a plugin's tab switch
/// from turning a held or quick key into the answer to the new tab's prompt.
final class KeyGuard {
    static let shared = KeyGuard()
    /// How long after a plugin brings a tab forward every key on it is dropped while it has a request.
    static let settle: TimeInterval = 0.4

    /// The terminal that got the press the current repeats belong to; nil once focus moves.
    private var pressedIn: AnyHashable?
    /// When a plugin last brought each tab forward; one switch never shortens another tab's window.
    private var switched: [String: TimeInterval] = [:]

    /// A terminal became first responder, or a window became key: no key held before counts as pressed in it.
    func focusMoved() {
        pressedIn = nil
    }

    /// Any keyDown in the app: one a terminal doesn't get (the palette's Return, a sheet's) ends the hold.
    func sawKeyDown(inTerminal: Bool) {
        if !inTerminal { pressedIn = nil }
    }

    /// A plugin asks for `surfaceId` (focusTab, a panel button's or hold summary's tab, a notification's
    /// binding). The settle window starts only if `open` really brought it forward.
    func pluginOpen(_ surfaceId: String, at now: TimeInterval, open: (String) -> Bool) {
        guard open(surfaceId) else { return }
        switched = switched.filter { now - $0.value < Self.settle }
        switched[surfaceId] = now
    }

    /// Whether a keyDown in terminal `view` (tab `surfaceId`) goes on. Inside a settle window every key
    /// is dropped, not only the answer keys (core/answer-keys.json) and Return: a prompt's other options
    /// ("2", arrows then Return) answer it too. `awaitsAnswer` is the core's `hasUnresolved`, the request
    /// half of what keeps a plugin from typing there.
    func allows(view: AnyHashable, surfaceId: String, isRepeat: Bool, awaitsAnswer: () -> Bool, now: TimeInterval) -> Bool {
        if isRepeat, pressedIn != view { return false }
        if let at = switched[surfaceId], now - at < Self.settle, awaitsAnswer() {
            // The whole hold is dropped, not only this press.
            pressedIn = nil
            return false
        }
        if !isRepeat { pressedIn = view }
        return true
    }
}
