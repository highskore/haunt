import Foundation

extension Unicode.Scalar {
    /// `event::is_blank`: drawn as a gap but not ignorable (core/hidden-chars.json "blank"), so text made plain shows a space.
    var drawsBlank: Bool {
        switch value {
        case 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x2800, 0x3000, 0x1D159: return true
        default: return false
        }
    }
}
