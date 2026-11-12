import AppKit

/// Haunt's own visual measures, which no mockup has; a theme's `[app]` table overrides them.
struct AppTokens: Equatable {
    /// Every rule and border; a stroked outline insets by half of it to land on whole pixels.
    var hairline: CGFloat = 1
    var caretW: CGFloat = 1
    /// Between the palette's query and its caret.
    var paletteCaretGap: CGFloat = 6
    /// The sidebar's drop indicator while a row is dragged.
    var dropLine: CGFloat = 2
    /// Darkens the window behind the palette, at `Tok.Size.paletteScrimAlpha`.
    var scrim = NSColor.black
    /// The row ×, which stands in the status slot while the row is hovered.
    var closeSize: CGFloat = 8
    var closeStroke: CGFloat = 1.2
    var sidebarGlyphRadius: CGFloat = 2
    /// Space above the first group label.
    var sidebarPadtop: CGFloat = 0
    /// `[effects] sidebar.footer`'s agent count: its colour, type size, and padding (top, sides, bottom).
    var sidebarFootFg = NSColor(white: 1, alpha: 0.4)
    var sidebarFootFont: CGFloat = 11
    var sidebarFootPad: [CGFloat] = [10, 16, 12]
    /// `[effects] window.ring`: the ring inside the window's edge and the highlight along its top; the palette's.
    var windowRing = NSColor(white: 1, alpha: 0.14)
    var windowHighlight = NSColor(white: 1, alpha: 0.32)
    var paletteRing = NSColor(white: 1, alpha: 0.18)
    var paletteHighlight = NSColor(white: 1, alpha: 0.3)
    /// `[effects] row.raised`: the selected row's ring, top highlight, and shadow with its blur and drop.
    var rowRaisedRing = NSColor(white: 1, alpha: 0.22)
    var rowRaisedHighlight = NSColor(white: 1, alpha: 0.2)
    var rowRaisedShadow = NSColor(white: 0, alpha: 0.18)
    var rowRaisedBlur: CGFloat = 14
    var rowRaisedDrop: CGFloat = 4
    /// `[effects] row.hover`'s fill.
    var rowHover = NSColor(white: 1, alpha: 0.06)
    /// `[effects] needs.pill`: fill, ring, text, corner radius and padding (vertical, horizontal).
    var pillBg = NSColor(white: 1, alpha: 0.2)
    var pillRing = NSColor(white: 1, alpha: 0.3)
    var pillFg = NSColor.white
    var pillRadius: CGFloat = 10
    var pillPad: [CGFloat] = [1, 8]
    /// `[effects] bar.glow`'s blur.
    var barGlow: CGFloat = 10
    /// `[effects] palette.selection = "pill"`: how far it stands in from the sides, and its corner radius.
    var palettePillInset: CGFloat = 6
    var palettePillRadius: CGFloat = 8
    /// The pill's top highlight, its text, and the sub line and keys on it.
    var palettePillHighlight = NSColor(white: 1, alpha: 0.25)
    var palettePillInk = NSColor.white
    var palettePillMute = NSColor(white: 1, alpha: 0.8)
    /// `[layout] title_format`'s title: the tab name's colour, the rest's, and their type size.
    var titleFg = NSColor(white: 1, alpha: 0.88)
    var titleMeta = NSColor(white: 1, alpha: 0.45)
    var titleFont: CGFloat = 13
    /// A display face for the title's tab part, group labels and the palette header; empty keeps the UI font.
    var displayFont = ""
    /// Gradient stops, top to bottom, filling display text and a pill selection; empty draws them flat.
    var textChrome: [String] = []
    /// The title's other parts: type size (0 follows `title.font`) and letter spacing in em.
    var titleMetaFont: CGFloat = 0
    var titleMetaTracking: CGFloat = 0
    var paletteHeaderFont: CGFloat = 18
    /// `[strings] titlebar.right`'s type size and letter spacing in em, and `[effects] titlebar.double`'s rule.
    var titlebarRightFont: CGFloat = 11
    var titlebarRightTracking: CGFloat = 0
    var titlebarRule2 = NSColor(white: 1, alpha: 0.06)
    /// `[effects] progress.style = "dotted"`'s knob, and the gap between the sigil and the footer text.
    var barKnob = NSColor.white
    var sidebarFootGap: CGFloat = 6
    /// Ornament lines and outlines, and the fainter rules and rings.
    var ornament = NSColor(white: 1, alpha: 0.6)
    var ornamentDim = NSColor(white: 1, alpha: 0.3)
    /// `[effects] ornament`'s artwork opacity in the pane.
    var ornamentAlpha: CGFloat = 0.07
    /// `[strings]`: a theme's words for named places, checked like a title (see `Theme.stringKeys`).
    var strings: [String: String] = [:]
    /// macOS's look for menus, sheets and alerts: "dark" or "light".
    var appearance = "dark"

    static let keys: [String: Theme.Key] = [
        "app.hairline": .number(\.app.hairline),
        "app.caret.w": .number(\.app.caretW),
        "app.palette.caret.gap": .number(\.app.paletteCaretGap),
        "app.drop.line": .number(\.app.dropLine),
        "app.scrim": .color(\.app.scrim),
        "app.close.size": .number(\.app.closeSize),
        "app.close.stroke": .number(\.app.closeStroke),
        "app.sidebar.glyph.radius": .number(\.app.sidebarGlyphRadius),
        "app.sidebar.padtop": .number(\.app.sidebarPadtop),
        "app.sidebar.foot.fg": .color(\.app.sidebarFootFg),
        "app.sidebar.foot.font": .number(\.app.sidebarFootFont),
        "app.sidebar.foot.pad": .numbers(\.app.sidebarFootPad),
        "app.window.ring": .color(\.app.windowRing),
        "app.window.highlight": .color(\.app.windowHighlight),
        "app.palette.ring": .color(\.app.paletteRing),
        "app.palette.highlight": .color(\.app.paletteHighlight),
        "app.row.raised.ring": .color(\.app.rowRaisedRing),
        "app.row.raised.highlight": .color(\.app.rowRaisedHighlight),
        "app.row.raised.shadow": .color(\.app.rowRaisedShadow),
        "app.row.raised.blur": .number(\.app.rowRaisedBlur),
        "app.row.raised.drop": .number(\.app.rowRaisedDrop),
        "app.row.hover": .color(\.app.rowHover),
        "app.pill.bg": .color(\.app.pillBg),
        "app.pill.ring": .color(\.app.pillRing),
        "app.pill.fg": .color(\.app.pillFg),
        "app.pill.radius": .number(\.app.pillRadius),
        "app.pill.pad": .numbers(\.app.pillPad),
        "app.bar.glow": .number(\.app.barGlow),
        "app.palette.pill.inset": .number(\.app.palettePillInset),
        "app.palette.pill.radius": .number(\.app.palettePillRadius),
        "app.palette.pill.highlight": .color(\.app.palettePillHighlight),
        "app.palette.pill.ink": .color(\.app.palettePillInk),
        "app.palette.pill.mute": .color(\.app.palettePillMute),
        "app.title.fg": .color(\.app.titleFg),
        "app.title.meta": .color(\.app.titleMeta),
        "app.title.font": .number(\.app.titleFont),
        "app.display.font": .string(\.app.displayFont),
        "app.text.chrome": .strings(\.app.textChrome),
        "app.title.meta.font": .number(\.app.titleMetaFont),
        "app.title.meta.tracking": .number(\.app.titleMetaTracking),
        "app.palette.header.font": .number(\.app.paletteHeaderFont),
        "app.titlebar.right.font": .number(\.app.titlebarRightFont),
        "app.titlebar.right.tracking": .number(\.app.titlebarRightTracking),
        "app.titlebar.rule2": .color(\.app.titlebarRule2),
        "app.bar.knob": .color(\.app.barKnob),
        "app.sidebar.foot.gap": .number(\.app.sidebarFootGap),
        "app.ornament": .color(\.app.ornament),
        "app.ornament.dim": .color(\.app.ornamentDim),
        "app.ornament.alpha": .number(\.app.ornamentAlpha),
    ]
}

/// Haunt's own measures, which no mockup has. Tokens.swift is generated from the mockups; these are not.
extension Tok {
    enum App {
        static var hairline: CGFloat { Theme.current.app.hairline }
        static var caretW: CGFloat { Theme.current.app.caretW }
        static var paletteCaretGap: CGFloat { Theme.current.app.paletteCaretGap }
        static var dropLine: CGFloat { Theme.current.app.dropLine }
        static var scrim: NSColor { Theme.current.app.scrim }
        static var closeSize: CGFloat { Theme.current.app.closeSize }
        static var closeStroke: CGFloat { Theme.current.app.closeStroke }
        static var sidebarGlyphRadius: CGFloat { Theme.current.app.sidebarGlyphRadius }
        static var sidebarPadtop: CGFloat { Theme.current.app.sidebarPadtop }
        static var sidebarFootFg: NSColor { Theme.current.app.sidebarFootFg }
        static var sidebarFootFont: CGFloat { Theme.current.app.sidebarFootFont }
        static var sidebarFootPad: [CGFloat] { Theme.current.app.sidebarFootPad }
        static var titleFg: NSColor { Theme.current.app.titleFg }
        static var titleMeta: NSColor { Theme.current.app.titleMeta }
        static var titleFont: CGFloat { Theme.current.app.titleFont }
        static var ornament: NSColor { Theme.current.app.ornament }
        static var sidebarFootGap: CGFloat { Theme.current.app.sidebarFootGap }
        static var ornamentDim: NSColor { Theme.current.app.ornamentDim }
        static var appearance: NSAppearance? {
            NSAppearance(named: Theme.current.app.appearance == "light" ? .aqua : .darkAqua)
        }

        /// How far the pointer moves before a row drag starts.
        static let dragSlop: CGFloat = 4
        /// NSTextField's cell insets its text this far, so the rename field sits that much left of the name.
        static let fieldInset: CGFloat = 2
        /// A plugin's `warn` tone (red CI and the like): orange, never the needs-you colour, which plugins can't use.
        static let pluginWarn = NSColor(srgbRed: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255, alpha: 1)
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

        /// The title bar's sidebar glyph: a window outline with its left column split off,
        /// about the ⚙ glyph's size at the icons' font size.
        static let sidebarGlyph = NSSize(width: 12, height: 10)
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
