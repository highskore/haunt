import AppKit
import GhosttyKit

/// Our surface: it reports every user write path into the pty, so the core can retire a request the user
/// may already have answered at the terminal. A subclass, so the vendored Ghostty sources stay unpatched;
/// Ghostty's own bindings that it handles in performKeyEquivalent also arrive here through keyDown.
/// libghostty has no single write choke point the app can hook, so each entry is overridden; see docs/core-api.md.
final class HauntSurfaceView: Ghostty.SurfaceView {
    var onInput: (() -> Void)?
    /// A paste that Ghostty's paste protection holds for confirmation; nil when it resolves or is replaced.
    var onPasteConfirmation: ((Ghostty.ClipboardConfirmationRequest?) -> Void)?
    /// A paste Haunt holds itself (PastePreview.needsConfirmation); the host asks, then calls `sendPaste`.
    var onRiskyPaste: ((String) -> Void)?

    /// True when `text` was held for confirmation instead of going to Ghostty.
    private func holdIfRisky(_ text: String?) -> Bool {
        guard let text, let ask = onRiskyPaste, PastePreview(text).needsConfirmation else { return false }
        ask(text)
        return true
    }

    /// Pastes the very text that was checked, so the clipboard isn't read a second time: held for Haunt's
    /// sheet if risky, else through Ghostty's paste protection. False when there is no text, for `super`.
    private func pasteChecked(_ text: String?) -> Bool {
        guard let text else { return false }
        if !holdIfRisky(text) { surfaceModel?.pasteText(text) }
        return true
    }

    /// Writes a paste the user confirmed, encoded as Ghostty pastes: ESC and other controls become spaces,
    /// and LF becomes CR outside a bracketed paste.
    func sendPaste(_ text: String) {
        onInput?()
        surfaceModel?.sendText(text)
    }

    override func keyDown(with event: NSEvent) {
        onInput?()
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        onInput?()
        if pasteChecked(NSPasteboard.general.getOpinionatedStringContents()) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        onInput?()
        if pasteChecked(NSPasteboard.general.getOpinionatedStringContents()) { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteSelection(_ sender: Any?) {
        onInput?()
        if pasteChecked(NSPasteboard.ghosttySelection.getOpinionatedStringContents()) { return }
        super.pasteSelection(sender)
    }

    /// IME commits, the Character Viewer and dictation can insert text without a keyDown.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        onInput?()
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Middle click pastes the selection clipboard. Ghostty's own middle-click-action is "ignore" (HauntConfig),
    /// so the paste is Haunt's, and only while the app isn't taking the mouse; the click itself always goes on.
    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        if event.buttonNumber == 2, surfaceModel?.mouseCaptured == false {
            onInput?()
            _ = pasteChecked(NSPasteboard.ghosttySelection.getOpinionatedStringContents())
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onInput?()
        if holdIfRisky(sender.draggingPasteboard.getOpinionatedStringContents()) { return true }
        return super.performDragOperation(sender)
    }

    /// Services such as "Send to Terminal" write the pasteboard straight into the pty.
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        onInput?()
        if holdIfRisky(pboard.getOpinionatedStringContents()) { return true }
        return super.readSelection(from: pboard)
    }

    /// A confirmed paste writes when its request resolves, possibly long after the paste action itself.
    /// The request's outcome is private, so retire on every resolution, including a cancel.
    override var pendingClipboardConfirmation: Ghostty.ClipboardConfirmationRequest? {
        didSet {
            guard oldValue !== pendingClipboardConfirmation else { return }
            if let old = oldValue, old.kind == .paste { onInput?() }
            let new = pendingClipboardConfirmation
            onPasteConfirmation?(new?.kind == .paste ? new : nil)
        }
    }
}

