import AppKit

/// Muted shades for `Row.color`, kept by hand: the generated tokens come from the mockups, which have none.
extension Tok.Color {
    static func tab(_ c: TabColor) -> NSColor {
        switch c {
        case .red: return rgb(0xb0, 0x7a, 0x7a)
        case .orange: return rgb(0xb0, 0x8f, 0x72)
        case .yellow: return rgb(0xad, 0xa2, 0x7a)
        case .green: return rgb(0x84, 0xa0, 0x83)
        case .blue: return rgb(0x7f, 0x93, 0xad)
        case .purple: return rgb(0x9a, 0x87, 0xad)
        case .gray: return rgb(0x8a, 0x8a, 0x8a)
        }
    }

    /// `Tint` draws the shade at this opacity over the row's background.
    static let tabTintAlpha: CGFloat = 0.12

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

extension Tok.Size {
    static let tabDot: CGFloat = 6
}
