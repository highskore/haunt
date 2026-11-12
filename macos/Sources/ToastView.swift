import AppKit

/// A note that fades after a few seconds, kept off the terminal; a new note replaces the old.
final class ToastView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
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
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// At the foot of `area` (in a flipped parent) and never outside it, its full width less a margin,
    /// wrapping to fit.
    func frame(in area: NSRect) -> NSRect {
        let w = max(area.width - 16, 1)
        label.preferredMaxLayoutWidth = w - 2 * Self.pad.width
        let h = min(label.intrinsicContentSize.height + 2 * Self.pad.height, area.height)
        let margin = min(8, (area.height - h) / 2)
        return NSRect(x: area.minX + 8, y: area.maxY - h - margin, width: w, height: h)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.pad.width, dy: min(Self.pad.height, bounds.height / 4))
    }

    func show(_ text: String) {
        label.stringValue = text
        superview?.needsLayout = true
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
