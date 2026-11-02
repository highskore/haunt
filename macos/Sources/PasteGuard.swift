import AppKit

/// Asks before a paste reaches a pty: Ghostty's own unsafe-paste requests and the ones Haunt holds
/// (PastePreview.needsConfirmation). One sheet at a time per window; asks from other surfaces wait their turn.
final class PasteGuard {
    /// One paste waiting for the user. `request` is Ghostty's, when it raised the question; it can be
    /// withdrawn (replaced or cleared) before the sheet is answered.
    private struct Ask {
        weak var view: HauntSurfaceView?
        let text: String
        let request: Ghostty.ClipboardConfirmationRequest?
        let finish: (Bool) -> Void
    }

    private weak var window: NSWindow?
    /// Brings the asking surface's tab forward before its sheet shows.
    private let reveal: (HauntSurfaceView) -> Void
    private var queue: [Ask] = []
    private var shown: (ask: Ask, alert: NSAlert)?

    init(window: NSWindow?, reveal: @escaping (HauntSurfaceView) -> Void) {
        self.window = window
        self.reveal = reveal
    }

    /// Ghostty's paste protection asks before an unsafe paste; nil withdraws what this surface had asked.
    func confirm(_ request: Ghostty.ClipboardConfirmationRequest?, on view: HauntSurfaceView) {
        let stale = { (a: Ask) in a.view === view && a.request != nil && a.request !== request }
        queue.removeAll(where: stale)
        if let shown, stale(shown.ask) || shown.ask.view == nil {
            self.shown = nil
            window?.endSheet(shown.alert.window, returnCode: .abort)
        }
        if let request {
            enqueue(Ask(view: view, text: request.contents, request: request) { [weak view] ok in
                if ok { request.complete() } else { request.cancel() }
                if view?.pendingClipboardConfirmation === request { view?.pendingClipboardConfirmation = nil }
            })
        }
        showNext()
    }

    /// A paste Haunt held itself; it is written, exactly as shown, only if the user says so.
    func hold(_ text: String, on view: HauntSurfaceView) {
        enqueue(Ask(view: view, text: text, request: nil) { [weak view] ok in
            if ok { view?.sendPaste(text) }
        })
    }

    private func enqueue(_ ask: Ask) {
        queue.append(ask)
        showNext()
    }

    private func showNext() {
        guard shown == nil, let window else { return }
        queue.removeAll { $0.view == nil }
        guard !queue.isEmpty else { return }
        let ask = queue.removeFirst()
        if let view = ask.view { reveal(view) }
        let alert = Self.alert(ask.text)
        shown = (ask, alert)
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self, self.shown?.alert === alert else { return }
            self.shown = nil
            ask.finish(r == .alertSecondButtonReturn)
            // The next sheet can't begin until this one has finished ending.
            DispatchQueue.main.async { self.showNext() }
        }
    }

    /// The whole paste, read-only and scrollable, with every control character spelled out (PastePreview).
    /// Cancel is the default; pasting takes an explicit click.
    static func alert(_ text: String) -> NSAlert {
        let preview = PastePreview(text)
        let alert = NSAlert()
        alert.messageText = preview.lines == 1 ? "Paste 1 line?" : "Paste \(preview.lines) lines?"
        var notes: [String] = []
        if preview.hasPasteEnd {
            notes.append("It contains a bracketed paste end (^[[201~): the text after it would run as typed commands.")
        }
        if preview.hasControls { notes.append("Control characters are shown as ^[ and \\u{…}.") }
        alert.informativeText = notes.joined(separator: "\n")

        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let lineH = NSLayoutManager().defaultLineHeight(for: font)
        let inset = Tok.App.pastePreviewInset
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Tok.App.pastePreviewW,
                                                height: (lineH * Tok.App.pastePreviewLines).rounded(.up) + inset.height * 2))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = font
        tv.textContainerInset = inset
        tv.isVerticallyResizable = true
        tv.autoresizingMask = .width
        tv.textContainer?.widthTracksTextView = true
        tv.string = preview.text
        scroll.documentView = tv
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Cancel")
        let paste = alert.addButton(withTitle: "Paste")
        paste.keyEquivalent = ""
        return alert
    }
}
