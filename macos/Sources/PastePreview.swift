import Foundation

/// What a held paste will send, with nothing hidden: control and invisible characters are spelled out.
struct PastePreview: Equatable {
    var text: String
    var lines: Int
    /// ESC[201~ ends bracketed paste early: whatever follows runs as if typed.
    var hasPasteEnd: Bool
    var hasControls: Bool

    /// Ghostty treats a bracketed paste as safe however it ends, so Haunt asks itself before any paste
    /// that carries an escape, another control or a hidden character. Plain text, newlines included,
    /// is left to Ghostty's own paste protection.
    var needsConfirmation: Bool { hasControls }

    static let pasteEnd = "\u{1B}[201~"

    init(_ s: String) {
        var out = ""
        var lines = 1
        var controls = false
        var pasteEnd = false
        let scalars = Array(s.unicodeScalars)
        let end = Array(Self.pasteEnd.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}", scalars[i...].starts(with: end) {
                out += "⟦^[[201~ bracketed paste end⟧"
                controls = true
                pasteEnd = true
                i += end.count
                continue
            }
            switch c {
            case "\n":
                out += "⏎\n"
                lines += 1
            case "\r" where i + 1 < scalars.count && scalars[i + 1] == "\n":
                out += "⏎\n"
                lines += 1
                i += 1
            case "\t":
                out.unicodeScalars.append(c)
            case "\u{1B}":
                out += "^["
                controls = true
            default:
                if Self.hidden(c) {
                    out += "\\u{" + String(c.value, radix: 16) + "}"
                    controls = true
                } else {
                    out.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        // A trailing newline ends the last line rather than starting one.
        if s.unicodeScalars.last == "\n", lines > 1 { lines -= 1 }
        self.text = out
        self.lines = lines
        self.hasPasteEnd = pasteEnd
        self.hasControls = controls
    }

    /// C0/C1 controls and DEL, plus format characters (bidi overrides, zero-width) that can disguise text.
    private static func hidden(_ c: Unicode.Scalar) -> Bool {
        c.value < 0x20 || (0x7F...0x9F).contains(c.value) || c.properties.generalCategory == .format
    }
}
