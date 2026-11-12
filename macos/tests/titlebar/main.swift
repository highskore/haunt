import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

let text = "Doneness of the build"
let whole = TitleBarView.pluginLine(text, room: 1000).map(Draw.width) ?? 0
check(whole > 0, "a line with room is drawn")
check(TitleBarView.pluginLine(text, room: whole) != nil, "exactly its width is room enough")
check(TitleBarView.pluginLine(text, room: whole - 1) == nil, "a narrow window draws nothing, never \"Done…\"")
check(TitleBarView.pluginLine("", room: 1000) == nil, "nothing to draw")

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("titlebar: ok")
