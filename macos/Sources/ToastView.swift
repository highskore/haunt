import AppKit

/// A line at the foot of the window that fades after a few seconds; a new line replaces the old.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private static let pad = NSSize(width: 14, height: 8)
    private static let shown: TimeInterval = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Tok.Color.cardBg.cgColor
        layer?.borderColor = Tok.Color.cardBorder.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        label.font = Draw.ui(12, .medium)
        label.textColor = Tok.Color.btnFg
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Centred near the bottom of `bounds` (a flipped view's), as wide as its text allows.
    func frame(in bounds: NSRect) -> NSRect {
        let text = label.intrinsicContentSize
        let w = min(text.width + 2 * Self.pad.width, bounds.width - 40), h = text.height + 2 * Self.pad.height
        return NSRect(x: ((bounds.width - w) / 2).rounded(), y: bounds.height - h - 20, width: w, height: h)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.pad.width, dy: Self.pad.height)
    }

    func show(_ text: String) {
        label.stringValue = text
        if let parent = superview { frame = frame(in: parent.bounds) }
        isHidden = false
        alphaValue = 1
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self?.animator().alphaValue = 0 }) { self?.isHidden = true }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shown, execute: work)
    }
}
