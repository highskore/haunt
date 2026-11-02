import Foundation

/// What a held paste will send, with nothing hidden: control and invisible characters are spelled out.
struct PastePreview: Equatable {
    var text: String
    var lines: Int
    /// ESC[201~ ends bracketed paste early: whatever follows runs as if typed.
    var hasPasteEnd: Bool
    var hasControls: Bool

    /// Ghostty only asks about line breaks and ESC[201~, and turns ESC and other controls into spaces as it
    /// pastes, so what reached the shell wouldn't be what was copied. Haunt asks itself before any paste with
    /// an escape, another control or a hidden character; plain text, newlines included, is left to Ghostty.
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
            case "\r":
                // A lone CR ends a line for the shell too, so it counts as one, and stays spelled out.
                out += "\\u{d}\n"
                lines += 1
                controls = true
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
        if let last = s.unicodeScalars.last, last == "\n" || last == "\r", lines > 1 { lines -= 1 }
        self.text = out
        self.lines = lines
        self.hasPasteEnd = pasteEnd
        self.hasControls = controls
    }

    /// The core's `is_hidden` and more: controls, format characters (bidi overrides, zero-width), any
    /// whitespace but the plain space (U+2028/2029, NBSP…), and default-ignorables that draw as nothing
    /// (Hangul fillers, variation selectors), all of which can disguise text or carry it unseen.
    static func hidden(_ c: Unicode.Scalar) -> Bool {
        let p = c.properties
        return c != " " && (p.generalCategory == .control || p.generalCategory == .format || p.isWhitespace
            || p.generalCategory == .lineSeparator || p.generalCategory == .paragraphSeparator
            || p.isDefaultIgnorableCodePoint)
    }
}
