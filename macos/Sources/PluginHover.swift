import AppKit

/// `keys.hover-hold("alt")`: holding ⌥ alone, with the pointer on a sidebar row in the key window, for
/// `delay` calls the owner's `on-hover-hold(true, row)`; letting go, leaving the row, any key-down or the
/// window losing key calls `(false, row)`. It only watches: every event goes on to the terminal.
final class HoverHold {
    static let delay: TimeInterval = 0.15
    /// (plugin id, held, surface id)
    var onHold: ((String, Bool, String) -> Void)?
    /// Haunt's window is key with its sidebar showing.
    var canHold: () -> Bool = { false }
    /// Runs the closure after `delay`; tests run it by hand.
    var after: (TimeInterval, @escaping () -> Void) -> Void = { d, f in DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }
    var owner: String? {
        didSet {
            guard owner != oldValue else { return }
            end()
            watch(owner != nil)
        }
    }

    private var altAlone = false
    /// A key went down or another modifier joined while ⌥ was held: no hold until ⌥ comes up again.
    private var spoiled = false
    private var row: String?
    private var started: (plugin: String, row: String)?
    private var pending = 0
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// The sidebar row under the pointer.
    func pointer(over row: String?) {
        self.row = row
        update()
    }

    /// Returns `e` untouched, always.
    @discardableResult
    func handle(_ e: NSEvent) -> NSEvent {
        switch e.type {
        case .flagsChanged: flags(e.modifierFlags)
        case .keyDown: keyDown()
        default: break
        }
        return e
    }

    func flags(_ mods: NSEvent.ModifierFlags) {
        let m = mods.intersection([.command, .shift, .control, .option, .function])
        if !m.contains(.option) { spoiled = false } else if m != .option { spoiled = true }
        altAlone = m == .option
        update()
    }

    func keyDown() {
        if altAlone { spoiled = true }
        update()
    }

    /// Re-checks the window's key state, as when it changes.
    func update() {
        let ready = owner != nil && altAlone && !spoiled && canHold() ? row : nil
        if let s = started, s.row != ready { end() }
        pending += 1
        guard let r = ready, started == nil, let p = owner else { return }
        let ticket = pending
        after(Self.delay) { [weak self] in
            guard let self, ticket == self.pending, self.started == nil else { return }
            self.started = (p, r)
            self.onHold?(p, true, r)
        }
    }

    private func end() {
        pending += 1
        guard let s = started else { return }
        started = nil
        onHold?(s.plugin, false, s.row)
    }

    private func watch(_ on: Bool) {
        if on, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in self?.handle(e) ?? e }
            let nc = NotificationCenter.default
            observers = [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSApplication.didResignActiveNotification].map {
                nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.update() }
            }
        } else if !on, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            altAlone = false
            spoiled = false
        }
    }
}
