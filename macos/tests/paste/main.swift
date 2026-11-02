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
check(PastePreview("a\rb").text == "a\\u{d}b", "lone CR spelled out")
check(PastePreview("x\u{1B}[31my").text == "x^[[31my", "ESC as ^[")
check(PastePreview("\u{7}\u{7F}\u{9B}").text == "\\u{7}\\u{7f}\\u{9b}", "C0, DEL, C1")
check(PastePreview("ab\u{202E}cd\u{200B}").text == "ab\\u{202e}cd\\u{200b}", "bidi override and zero-width")
check(PastePreview("a\tb").text == "a\tb", "tab kept")

let end = PastePreview("ls\u{1B}[201~rm -rf ~\n")
check(end.hasPasteEnd && end.hasControls, "paste end flagged")
check(end.text == "ls⟦^[[201~ bracketed paste end⟧rm -rf ~⏎\n", "paste end called out: \(end.text.debugDescription)")
check(end.lines == 1, "one line")
check(PastePreview("\u{1B}[200~").text == "^[[200~", "a paste start is just ESC")

if failures > 0 { print("paste: \(failures) failed"); exit(1) }
print("paste: all passed")
