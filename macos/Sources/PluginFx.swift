import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The Dock tile the owning plugin asked for (`HostRequest.dockShow`); the core lets one plugin at a time
/// send these. `blink` is flashed every few seconds, never under Reduce Motion.
final class PluginDock {
    private static let blinkEvery: TimeInterval = 4
    private static let blinkFor: TimeInterval = 0.4
    private static let pixelsMax = 1024

    var enabled = true {
        didSet { if enabled != oldValue { apply() } }
    }
    private struct Shown { let image: NSImage?, badge: UInt32?, blink: NSImage? }
    private var shown: Shown?
    private var timer: Timer?
    /// Decoded images by their bytes; a plugin has at most 8.
    private var decoded: [Data: NSImage] = [:]

    func show(image: DockImage?, badge: UInt32?, blink: DockImage?) {
        shown = image == nil && badge == nil ? nil : Shown(image: image.flatMap(decode), badge: badge, blink: blink.flatMap(decode))
        apply()
    }

    /// Haunt's own icon and no badge, as when the owner lets go or the plugins reload.
    func reset() {
        shown = nil
        decoded = [:]
        apply()
    }

    private func apply() {
        timer?.invalidate()
        timer = nil
        let s = enabled ? shown : nil
        // nil puts the bundle's icon back.
        NSApp.applicationIconImage = s?.image
        NSApp.dockTile.badgeLabel = s?.badge.map(String.init)
        guard let image = s?.image, let blink = s?.blink else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.blinkEvery, repeats: true) { [weak self] t in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            NSApp.applicationIconImage = blink
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.blinkFor) {
                if self?.timer === t { NSApp.applicationIconImage = image }
            }
        }
    }

    /// A still PNG that decodes whole, at most 1024 pixels each way; anything else is dropped and logged.
    private func decode(_ d: DockImage) -> NSImage? {
        if let img = decoded[d.png] { return img }
        guard let src = CGImageSourceCreateWithData(d.png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(src) as String? == UTType.png.identifier, CGImageSourceGetCount(src) == 1,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              (1...Self.pixelsMax).contains(cg.width), (1...Self.pixelsMax).contains(cg.height)
        else {
            AppDelegate.logger.error("plugin dock image \(d.id, privacy: .public) does not decode as a still PNG; dropped")
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if decoded.count >= 16 { decoded = [:] }
        decoded[d.png] = img
        return img
    }
}

/// The owning plugin's glow (`HostRequest.glowShow`): a 3 pt warn-orange hairline along the top of the screen
/// Haunt's window is on, breathing unless Reduce Motion is on, and its label at the top right, under the menu
/// bar. A borderless panel above other apps' windows that ignores the mouse and never takes focus.
final class PluginGlow {
    static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    var enabled = true {
        didSet { if enabled != oldValue { apply() } }
    }
    var showsLabel = true {
        didSet { if showsLabel != oldValue { apply() } }
    }
    /// The window whose screen the glow follows.
    weak var anchor: NSWindow? {
        didSet {
            if let o = anchorObserver { NotificationCenter.default.removeObserver(o) }
            anchorObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: anchor,
                                                                    queue: .main) { [weak self] _ in self?.apply() }
        }
    }
    /// Shown while set; the label inside may still be nil.
    private var label: String??
    private var panel: GlowPanel?
    private var anchorObserver: NSObjectProtocol?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                              queue: .main) { [weak self] _ in self?.apply() }),
            (workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
                                              queue: .main) { [weak self] _ in self?.apply() }),
        ]
    }

    deinit {
        for (center, o) in observers { center.removeObserver(o) }
        if let o = anchorObserver { NotificationCenter.default.removeObserver(o) }
    }

    func show(label: String?) {
        self.label = .some(label)
        apply()
    }

    func hide() {
        label = nil
        apply()
    }

    private func apply() {
        guard enabled, let label, let screen = anchor?.screen ?? NSScreen.main else {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? GlowPanel()
        panel = p
        let f = screen.frame
        // The label sits under the menu bar, never on its items.
        let menuBar = f.maxY - screen.visibleFrame.maxY
        let height = menuBar + ceil(Self.font.ascender - Self.font.descender) + 8
        p.setFrame(NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height), display: false)
        p.glow.update(label: showsLabel ? label : nil, below: menuBar + 4, scale: screen.backingScaleFactor,
                      breathe: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        p.orderFrontRegardless()
    }
}

/// Never key or main, ignores the mouse, on every Space and over full-screen apps.
private final class GlowPanel: NSPanel {
    let glow = GlowView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = glow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class GlowView: NSView {
    private static let line: CGFloat = 3
    private static let halo: CGFloat = 12
    private static let inset: CGFloat = 12
    private let line = CALayer()
    private let halo = CAGradientLayer()
    private let text = CATextLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let warn = Tok.App.pluginWarn
        line.backgroundColor = warn.cgColor
        halo.colors = [warn.withAlphaComponent(0.4).cgColor, warn.withAlphaComponent(0).cgColor]
        halo.startPoint = CGPoint(x: 0.5, y: 1)
        halo.endPoint = CGPoint(x: 0.5, y: 0)
        text.font = PluginGlow.font
        text.fontSize = PluginGlow.font.pointSize
        text.foregroundColor = warn.cgColor
        text.alignmentMode = .right
        text.truncationMode = .end
        for l in [halo, line, text] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `below`: how far under the top edge the label starts.
    func update(label: String?, below: CGFloat, scale: CGFloat, breathe: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        line.frame = NSRect(x: 0, y: b.maxY - Self.line, width: b.width, height: Self.line)
        halo.frame = NSRect(x: 0, y: b.maxY - Self.line - Self.halo, width: b.width, height: Self.halo)
        let h = ceil(PluginGlow.font.ascender - PluginGlow.font.descender) + 2
        text.frame = NSRect(x: b.width / 2, y: b.maxY - below - h, width: b.width / 2 - Self.inset, height: h)
        text.contentsScale = scale
        text.string = label ?? ""
        text.isHidden = label == nil
        CATransaction.commit()
        for l in [line, halo] {
            l.removeAnimation(forKey: "breathe")
            guard breathe else { continue }
            let a = CABasicAnimation(keyPath: "opacity")
            (a.fromValue, a.toValue, a.duration, a.autoreverses, a.repeatCount) = (1.0, 0.35, 2.4, true, .infinity)
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(a, forKey: "breathe")
        }
    }
}
