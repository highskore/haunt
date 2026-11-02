import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

let plain = PastePreview("echo a\necho b\n")
check(plain.text == "echo a⏎\necho b⏎\n", "newlines \(plain.text.debugDescription)")
check(plain.lines == 2, "trailing newline isn't a line: \(plain.lines)")
check(!plain.hasControls && !plain.hasPasteEnd, "plain text has no controls")

check(PastePreview("a\r\nb").text == "a⏎\nb", "CRLF is one newline")
check(PastePreview("a\r\nb\r\n").lines == 2, "CRLF trailing newline")
check(PastePreview("a\rb").text == "a\\u{d}\nb", "lone CR spelled out and breaks the line")
let cr = PastePreview("ls\rrm -rf ~")
check(cr.lines == 2 && cr.needsConfirmation, "a lone CR is a second line, and held: \(cr.lines)")
check(PastePreview("a\u{2028}b\u{2029}c").text == "a\\u{2028}b\\u{2029}c", "line and paragraph separators")
check(PastePreview("a\u{A0}b\u{3000}c").needsConfirmation, "NBSP and ideographic space held")
check(!PastePreview("a b").needsConfirmation, "plain space")
check(PastePreview("x\u{1B}[31my").text == "x^[[31my", "ESC as ^[")
check(PastePreview("\u{7}\u{7F}\u{9B}").text == "\\u{7}\\u{7f}\\u{9b}", "C0, DEL, C1")
check(PastePreview("ab\u{202E}cd\u{200B}").text == "ab\\u{202e}cd\\u{200b}", "bidi override and zero-width")
check(PastePreview("a\tb").text == "a\tb", "tab kept")

let end = PastePreview("ls\u{1B}[201~rm -rf ~\n")
check(end.hasPasteEnd && end.hasControls, "paste end flagged")
check(end.text == "ls⟦^[[201~ bracketed paste end⟧rm -rf ~⏎\n", "paste end called out: \(end.text.debugDescription)")
check(end.lines == 1, "one line")
check(PastePreview("\u{1B}[200~").text == "^[[200~", "a paste start is just ESC")

// What Haunt holds back itself; plain text, newlines and tabs stay with Ghostty.
check(!PastePreview("echo a\necho b\n").needsConfirmation, "multi-line plain text left to Ghostty")
check(!PastePreview("a\tb").needsConfirmation, "tab left to Ghostty")
check(!PastePreview("héllo wörld 日本").needsConfirmation, "non-ASCII text left to Ghostty")
check(PastePreview("ls\u{1B}[201~rm -rf ~\n").needsConfirmation, "bracketed paste end held")
check(PastePreview("x\u{1B}[31m").needsConfirmation, "any escape held")
check(PastePreview("a\u{7}b").needsConfirmation, "C0 control held")
check(PastePreview("a\u{9B}b").needsConfirmation, "C1 control held")
check(PastePreview("ab\u{202E}cd").needsConfirmation, "bidi override held")
check(PastePreview("ab\u{200B}cd").needsConfirmation, "zero-width held")

if failures > 0 { print("paste: \(failures) failed"); exit(1) }
print("paste: all passed")
