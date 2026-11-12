import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

func row(_ title: String) -> PaletteRow { PaletteRow(title: title, sub: "", action: .tab(title)) }
let view = PaletteView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
func show(_ query: String, _ rows: [PaletteRow], chip: String? = nil) {
    view.update(chip: chip, query: query, placeholder: "", rows: rows, foot: [], maxRows: 8)
}

show("", [row("web-api"), row("billing"), row("Run tests")])
view.moveSelection(1)
check(view.selectedRow?.title == "billing", "moved to billing")

// The same query, refreshed or reordered: the selection follows its row.
show("", [row("Run tests"), row("web-api"), row("billing")])
check(view.selectedRow?.title == "billing", "a refresh keeps the row: \(view.selectedRow?.title ?? "-")")

// New text: the best match, even when the old row still matches.
show("run te", [row("Run tests"), row("billing"), row("web-api")])
check(view.selectedRow?.title == "Run tests", "new text selects the first row: \(view.selectedRow?.title ?? "-")")

// A status row isn't selected; the first row that does something is.
show("run tes", [PaletteRow(title: "Plugin failed", sub: "", dim: true), row("Run tests")])
check(view.selectedRow?.title == "Run tests", "skips a row without an action")

// A mode switch with the same text is new too.
view.moveSelection(-1)
show("run tes", [row("a"), row("Run tests")], chip: "log")
check(view.selectedRow?.title == "a", "a new mode starts from the first row")

// A theme's words are drawn whole or Haunt's are: at 400 pt nothing of the theme's fits.
Theme.statusCheck = { _ in false }
Theme.current.app.strings = ["palette.header": "Doneness", "palette.message": "Doneness", "palette.foot": "Doneness", "palette.input.glyph": "Doneness"]
Theme.current.effects.paletteHeader = true
Theme.current.effects.paletteFrame = "dialog"
Theme.current.effects.paletteInputIcon = true
view.update(chip: nil, query: "", placeholder: "", rows: [row("a")], foot: ["↵ open"], maxRows: 8)
check(view.header == "Doneness" && view.message == "Doneness" && view.footText == "Doneness" && view.inputGlyph == "Doneness",
      "at the theme's size they fit: \(view.header ?? "-") \(view.message ?? "-") \(view.footText ?? "-") \(view.inputGlyph)")
Theme.current.size.paletteSmallFont = 400
Theme.current.size.paletteInputFont = 400
check(view.header == nil && view.message == nil && view.footText == nil, "too wide, the header, message and foot are left out")
check(view.inputGlyph == "⌕", "and the field's glyph is Haunt's")
Theme.current = Theme()
Theme.statusCheck = { _ in true }

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("palette: ok")
