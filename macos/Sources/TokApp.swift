import AppKit

/// Haunt's own measures, which no mockup has. Tokens.swift is generated from the mockups; these are not.
extension Tok {
    enum App {
        /// How far past a small control a click or tooltip still lands on it.
        static let hitSlop: CGFloat = 4
        /// The traffic lights' slop, smaller since they sit close together.
        static let lightsSlop: CGFloat = 2

        /// The row ×, which stands in the status slot while the row is hovered.
        static let closeSize: CGFloat = 8
        static let closeStroke: CGFloat = 1.2

        /// The title bar's sidebar glyph: a window outline with its left column split off,
        /// about the ⚙ glyph's size at the icons' font size.
        static let sidebarGlyph = NSSize(width: 12, height: 10)
        static let sidebarGlyphRadius: CGFloat = 2
        static let sidebarGlyphColumn: CGFloat = 4

        /// The paste sheet's preview: its width, the lines it shows before scrolling, and its text inset.
        static let pastePreviewW: CGFloat = 420
        static let pastePreviewLines: CGFloat = 10
        static let pastePreviewInset = NSSize(width: 2, height: 4)
    }

    /// macOS's own traffic lights, shown while the pointer is on them. Glyph sizes are shares of a light's diameter.
    enum Lights {
        static let fill = [NSColor(srgbRed: 1, green: 0x5F / 255, blue: 0x57 / 255, alpha: 1),
                           NSColor(srgbRed: 0xFE / 255, green: 0xBC / 255, blue: 0x2E / 255, alpha: 1),
                           NSColor(srgbRed: 0x28 / 255, green: 0xC8 / 255, blue: 0x40 / 255, alpha: 1)]
        static let glyph = [NSColor(srgbRed: 0x4D / 255, green: 0, blue: 0, alpha: 1),
                            NSColor(srgbRed: 0x99 / 255, green: 0x57 / 255, blue: 0, alpha: 1),
                            NSColor(srgbRed: 0, green: 0x65 / 255, blue: 0, alpha: 1)]
        static let glyphStroke: CGFloat = 1.1
        /// The × arm's half-length; − and + reach `barScale` times further.
        static let glyphHalf: CGFloat = 0.22
        static let barScale: CGFloat = 1.2
        /// The full-screen arrows: each triangle's half-size and the gap cut from its long edges.
        static let arrowHalf: CGFloat = 0.25
        static let arrowGap: CGFloat = 0.07
    }
}
