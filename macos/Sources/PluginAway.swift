import AppKit
import CoreGraphics

/// For plugins granted `away`: every few seconds, and when the screen locks, unlocks, sleeps or wakes,
/// tells the core whether the screen is locked or asleep and how long since the user's last input.
final class Presence {
    static let every: TimeInterval = 5
    /// (locked or asleep, seconds since the last input)
    var report: ((Bool, UInt64) -> Void)?
    /// Haunt became the active app: a sheet a plugin asked for on the user's return is due a second later.
    var activated: (() -> Void)?
    /// That second later, with whether the user typed into Haunt meanwhile (then the sheet is dropped).
    var returnSheetsDue: ((Bool) -> Void)?
    static let returnSheetDelay: TimeInterval = 1
    private var typedMonitor: Any?
    private var due: DispatchWorkItem?
    private var typed = false
    private var locked = false, asleep = false
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard timer == nil else { return }
        let dnc = DistributedNotificationCenter.default(), ws = NSWorkspace.shared.notificationCenter
        let on = { (c: NotificationCenter, name: String, f: @escaping (Presence) -> Void) in
            (c, c.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                f(self)
                self.tick()
            })
        }
        observers = [
            on(dnc, "com.apple.screenIsLocked") { $0.locked = true },
            on(dnc, "com.apple.screenIsUnlocked") { $0.locked = false },
            on(ws, NSWorkspace.screensDidSleepNotification.rawValue) { $0.asleep = true },
            on(ws, NSWorkspace.screensDidWakeNotification.rawValue) { $0.asleep = false },
            (NotificationCenter.default, NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.becameActive() }),
        ]
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endDue()
        for (c, o) in observers { c.removeObserver(o) }
        observers = []
    }

    private func becameActive() {
        activated?()
        endDue()
        typed = false
        // Watches only: the keys still reach whatever has focus.
        typedMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.typed = true
            return e
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let typed = self.typed
            self.endDue()
            self.returnSheetsDue?(typed)
        }
        due = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnSheetDelay, execute: item)
    }

    private func endDue() {
        due?.cancel()
        due = nil
        if let m = typedMonitor { NSEvent.removeMonitor(m) }
        typedMonitor = nil
    }

    private func tick() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        report?(locked || asleep, UInt64(max(0, idle)))
    }
}
