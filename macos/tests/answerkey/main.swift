import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

// The table: Claude's 1, Codex's y, and ESC for Deny.
check(AnswerKey(Data("1".utf8))?.action == "text:1", "Claude allow")
check(AnswerKey(Data("y".utf8))?.action == "text:y", "Codex allow")
check(AnswerKey(Data([0x1B]))?.action == "text:\\x1b", "deny")

// The same keys as the core's, through the table both sides are tested against.
let shared = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "core/answer-keys.json"))) as! [String: [String: String]]
let coreKeys = Set(shared.values.flatMap(\.values).map { Data($0.utf8) })
check(coreKeys == Set(AnswerKey.table.keys), "the table matches core/answer-keys.json: \(coreKeys) vs \(AnswerKey.table.keys)")

// Nothing else is a key: no longer text, no Return, no escape sequence, no case change.
for s in ["", "11", "1\r", "1\n", "y\r", "Y", "2", "n", "\u{1B}[201~", "\u{1B}\u{1B}", "\\x1b", "text:1", "rm -rf ~"] {
    check(AnswerKey(Data(s.utf8)) == nil, "not a key: \(s.debugDescription)")
}

let w = { (s: String) in PtyWrite(surfaceId: "s1", bytes: Data(s.utf8), enter: false) }

// A plugin's answer that the gate let through is pressed.
let answer = HostRequest.ptyAnswer(pluginId: "p", surface: "s1", allow: true, requestId: 7)
check(PtyRoute(answer, w("1")) == .press(AnswerKey(Data("1".utf8))!, surfaceId: "s1"), "answer pressed")
check(PtyRoute(answer, w("rm -rf ~")) == nil, "an answer that isn't a key writes nothing")
check(PtyRoute(answer, PtyWrite(surfaceId: "s1", bytes: Data("1".utf8), enter: true)) == nil, "an answer never presses Return")

// Typed text is pasted, even when it spells a key.
for s in ["1", "y", "\u{1B}", "npm test"] {
    for enter in [false, true] {
        let typed = HostRequest.ptyType(pluginId: "p", surface: "s1", text: s, enter: enter)
        let tw = PtyWrite(surfaceId: "s1", bytes: Data(s.utf8), enter: enter)
        check(PtyRoute(typed, tw) == .paste(tw), "typed text pasted: \(s.debugDescription)")
    }
}
check(PtyRoute(.notify(pluginId: "p", title: "t", body: "b", actions: [], binding: nil), w("1")) == nil, "notify writes nothing")

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("answerkey: ok")
