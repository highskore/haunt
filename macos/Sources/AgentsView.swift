import AppKit

/// Agents-only view 01, Narrow list (pawr-agents-view): the title bar with the shortcut, "Agents · N",
/// the agent rows as the sidebar draws them, and a foot counting the hidden shell tabs.
final class AgentsView: NSView {
    let titleBar = TitleBarView()
    let list = SidebarView()
    private(set) var snapshot = SidebarSnapshot(groups: [])
    private var hiddenShells = 0
    /// The frame and minimum size the window had before it shrank; nil while the view is off.
    var restore: (frame: NSRect, minSize: NSSize)?

    /// The shortcut as the mockup writes it, "⌘⇧A".
    var shortcut = "⌘⇧A" {
        didSet {
            titleBar.kbdLabel = shortcut
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    // Holds first responder while the terminals are hidden, so typing can't reach one.
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleBar.accessory = .kbd
        titleBar.kbdLabel = shortcut
        list.panel = true
        list.clipsToBounds = true
        addSubview(titleBar)
        addSubview(list)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Agent rows only, in sidebar order, under one label; shell tabs are counted, not shown.
    func update(_ snap: SidebarSnapshot) {
        let rows = snap.groups.flatMap(\.rows)
        let agents = rows.filter { $0.kind != .shell }
        let next = SidebarSnapshot(groups: [SidebarGroup(label: "Agents · \(agents.count)", rows: agents)])
        if rows.count - agents.count != hiddenShells {
            hiddenShells = rows.count - agents.count
            needsDisplay = true
        }
        guard next != snapshot else { return }
        snapshot = next
        list.snapshot = next
    }

    override func layout() {
        super.layout()
        let top = TitleBarView.height(zen: false)
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        list.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top - Tok.Size.footH, 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let top = bounds.height - Tok.Size.footH
        Draw.fill(NSRect(x: 0, y: top, width: bounds.width, height: Tok.Size.footH), Tok.Color.windowBg)
        Draw.fill(NSRect(x: 0, y: top, width: bounds.width, height: 1), Tok.Color.hairline)
        let font = Draw.ui(Tok.Size.footFont)
        let lh = Tok.Size.footFont * Tok.Font.baseLine
        let y = top + 1 + (Tok.Size.footH - 1 - lh) / 2
        if hiddenShells > 0 {
            let text = hiddenShells == 1 ? "1 shell tab hidden" : "\(hiddenShells) shell tabs hidden"
            Draw.text(Draw.line(text, font, Tok.Color.textLabel), font: font, x: Tok.Size.footPadx, top: y, lineHeight: lh, in: ctx)
        }
        let expand = Draw.line("\(shortcut) expand", font, Tok.Color.textLabel)
        Draw.text(expand, font: font, x: bounds.width - Tok.Size.footPadx - Draw.width(expand), top: y, lineHeight: lh, in: ctx)
    }

    /// The mockup's order, ⌘ before ⇧, where the menu puts ⇧ first.
    static func mockupDisplay(_ s: Shortcut?) -> String {
        guard let s else { return "" }
        let order: [(NSEvent.ModifierFlags, String)] = [(.command, "⌘"), (.shift, "⇧"), (.option, "⌥"), (.control, "⌃")]
        let mods = order.filter { s.mods.contains($0.0) }.map(\.1).joined()
        let plain = Shortcut(mods: [], key: s.key).display
        return mods + plain
    }

    /// A strip of the mockup's width, the full height of the screen's visible area, docked to its right edge.
    /// The mockup's 280 is its border box; the window draws its own border, so the content is 278.
    static func dockedFrame(on screen: NSScreen?, height: CGFloat? = nil) -> NSRect {
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = Tok.Size.narrowW - 2
        let h = min(height ?? area.height, area.height)
        return NSRect(x: area.maxX - w, y: area.maxY - h, width: w, height: h)
    }
}
