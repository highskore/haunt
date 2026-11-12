import Foundation

/// An Allow or Deny for an agent's prompt, as the keystroke its adapter's key table names (the core's
/// `Agent::answer_bytes`). Only these reach a terminal as keystrokes: a prompt ignores a pasted answer.
/// Every other write (plugin text, the user's pastes, the review's Send) stays a bracketed paste.
struct AnswerKey: Equatable {
    let bytes: Data
    /// The Ghostty `text:` binding action that sends it.
    let action: String

    private static let table: [Data: String] = [
        Data("1".utf8): "text:1",
        Data("y".utf8): "text:y",
        Data([0x1B]): "text:\\x1b",
    ]

    /// None unless `bytes` is exactly one of the table's answers.
    init?(_ bytes: Data) {
        guard let action = Self.table[bytes] else { return nil }
        self.bytes = bytes
        self.action = action
    }
}

/// How a gated plugin write reaches the pty.
enum PtyRoute: Equatable {
    case press(AnswerKey, surfaceId: String)
    case paste(PtyWrite)

    /// A plugin's answer is pressed, and only as an `AnswerKey`; typed text is always pasted.
    init?(_ request: HostRequest, _ w: PtyWrite) {
        switch request {
        case .ptyAnswer:
            guard let key = AnswerKey(w.bytes), !w.enter else { return nil }
            self = .press(key, surfaceId: w.surfaceId)
        case .ptyType:
            self = .paste(w)
        case .notify:
            return nil
        }
    }
}
