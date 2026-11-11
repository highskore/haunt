import AppKit

/// Haunt's own measures, which no mockup has. Tokens.swift is generated from the mockups; these are not.
extension Tok {
    enum App {
        /// Every rule and border; a stroked outline insets by half of it to land on whole pixels.
        static let hairline: CGFloat = 1
        static let caretW: CGFloat = 1
        /// The sidebar's drop indicator while a row is dragged, and how far the pointer moves before a drag starts.
        static let dropLine: CGFloat = 2
        static let dragSlop: CGFloat = 4
        /// NSTextField's cell insets its text this far, so the rename field sits that much left of the name.
        static let fieldInset: CGFloat = 2
        /// Darkens the window behind the palette, at `Tok.Size.paletteScrimAlpha`.
        static let scrim = NSColor.black
        /// The OpenAI mark's size if its image failed to load.
        static let openAIMarkFallback: CGFloat = 18

        /// The window's first width and the smallest it goes: the terminal keeps `minPaneW` beside the sidebar.
        static let windowW: CGFloat = 900
        static let minPaneW: CGFloat = 300
        static let minWindowH: CGFloat = 240
        static let narrowMinH: CGFloat = 200

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

        /// The paste sheet's preview: its width and the lines it shows before scrolling.
        static let pastePreviewW: CGFloat = 420
        static let pastePreviewLines: CGFloat = 10
        /// The text inset of the paste preview and the setup diff.
        static let textBoxInset = NSSize(width: 2, height: 4)

        /// Native sheets (paste, setup) keep macOS's own type and label colour.
        static var sheetFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
        static var sheetMono: NSFont { .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) }
        static var sheetText: NSColor { .labelColor }

        /// The setup sheet: the agent checkboxes, the icon's drop below the baseline, and the diff box
        /// (its width, the lines it shows from and to before scrolling, and the room for its border and inset).
        static let setupChoicesW: CGFloat = 340
        static let setupChoiceGap: CGFloat = 8
        /// A plugin's one-line description under its checkbox: its type, colour, indent to the title, and
        /// the space above the plugins' heading.
        static var sheetDetailFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }
        static var sheetDetail: NSColor { .secondaryLabelColor }
        static let setupDetailIndent: CGFloat = 20
        static let setupGroupGap: CGFloat = 14
        static let setupDetailGap: CGFloat = 2
        /// The plugin list scrolls to keep the sheet this far above the window's bottom, showing at least `setupPluginsMinH`.
        static let setupSheetMargin: CGFloat = 12
        static let setupPluginsMinH: CGFloat = 60
        /// Room a scrolling list's text leaves for the scroller.
        static let scrollerGutter: CGFloat = 16
        static let setupIconDrop: CGFloat = 3
        static let setupDiffW: CGFloat = 520
        static let setupDiffLines = 3...14
        static let setupDiffChrome: CGFloat = 24

        /// The Settings window: width, first height, gaps, edge insets, and the space after a rule and a section.
        static let settingsW: CGFloat = 440
        static let settingsH: CGFloat = 200
        static let settingsGap: CGFloat = 10
        static let settingsRowGap: CGFloat = 8
        static let settingsInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        static let settingsAfterRule: CGFloat = 14
        static let settingsAfterSection: CGFloat = 18
        /// Settings' plugin list scrolls past this height.
        static let settingsPluginsMaxH: CGFloat = 220
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
