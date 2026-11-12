import AppKit

extension Shortcut {
    /// As the core spells a chord (`chord::canonical_with_cmd`): "cmd+ctrl+opt+shift+" then the key.
    var canonical: String {
        let names: [(NSEvent.ModifierFlags, String)] = [(.command, "cmd+"), (.control, "ctrl+"), (.option, "opt+"), (.shift, "shift+")]
        return names.filter { mods.contains($0.0) }.map(\.1).joined() + key
    }

    /// Whether key event `e` is this chord, as AppKit would match it to a menu item.
    func matches(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .shift, .control, .option]) == mods else { return false }
        if key == "backspace" { return e.keyCode == 51 }
        return e.charactersIgnoringModifiers?.lowercased() == keyEquivalent.lowercased()
    }
}

/// Keys plugins bound with `keys.bind`, where `[keys]` left them: a press and a release reach the plugin as
/// `on-action(id, "key-down")` and `"key-up"`. Lifting one of the chord's modifiers, or the app losing focus,
/// counts as the release, so a plugin never sees a key stuck down.
final class PluginKeys {
    /// (plugin id, key id, down)
    var onKey: ((String, String, Bool) -> Void)?
    private var bound: [(chord: Shortcut, plugin: String, id: String)] = []
    /// By key code, while down.
    private var held: [UInt16: (chord: Shortcut, plugin: String, id: String)] = [:]
    private var monitor: Any?
    private var resign: NSObjectProtocol?

    /// `keys` from the core; `map` says which chord each has now, if any.
    func update(keys: [PluginKey], map: KeyMap) {
        bound = keys.compactMap { k in map.plugin[KeyMap.pluginName(k.pluginId, k.id)].map { ($0, k.pluginId, k.id) } }
        for (code, h) in held where !bound.contains(where: { $0.plugin == h.plugin && $0.id == h.id && $0.chord == h.chord }) {
            release(code)
        }
        if bound.isEmpty, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            resign.map(NotificationCenter.default.removeObserver)
            resign = nil
        } else if !bound.isEmpty, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
                self?.handle(e) ?? e
            }
            resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in self?.releaseAll()
            }
        }
    }

    /// nil when the event was a plugin key's, so neither the menu nor the terminal sees it.
    func handle(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .keyDown:
            if held[e.keyCode] != nil { return nil }
            guard let b = bound.first(where: { $0.chord.matches(e) }) else { return e }
            held[e.keyCode] = b
            onKey?(b.plugin, b.id, true)
            return nil
        case .keyUp:
            guard held[e.keyCode] != nil else { return e }
            release(e.keyCode)
            return nil
        case .flagsChanged:
            let now = e.modifierFlags.intersection([.command, .shift, .control, .option])
            for (code, h) in held where !now.isSuperset(of: h.chord.mods) { release(code) }
            return e
        default:
            return e
        }
    }

    func releaseAll() {
        for code in held.keys { release(code) }
    }

    private func release(_ code: UInt16) {
        guard let h = held.removeValue(forKey: code) else { return }
        onKey?(h.plugin, h.id, false)
    }
}
