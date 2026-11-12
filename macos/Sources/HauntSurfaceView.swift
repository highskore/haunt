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
    /// The text, and the plugin that copied it (`PluginCopy`) if one did.
    var onRiskyPaste: ((String, String?) -> Void)?
    /// Whether a plugin-copy tag naming this id is believed (`PluginCopy.source`).
    var isPluginCopy: (String) -> Bool = { _ in false }
    /// Whether a middle click pastes the selection, read at each click so config changes apply.
    var middleClickPastes: () -> Bool = { true }
    /// This tab's surface id, and whether it has a request a stray Return could answer (`KeyGuard`).
    var surfaceId = ""
    var awaitsAnswer: () -> Bool = { false }

    /// True when `text` was held for confirmation instead of going to Ghostty.
    private func holdIfRisky(_ text: String?, from pb: NSPasteboard) -> Bool {
        let plugin = PluginCopy.source(pb, isPlugin: isPluginCopy)
        guard let text, let ask = onRiskyPaste, PastePreview(text, fromPlugin: plugin).needsConfirmation else { return false }
        ask(text, plugin)
        return true
    }

    /// Pastes the very text that was checked, so the clipboard isn't read a second time: held for Haunt's
    /// sheet if risky, else through Ghostty's paste protection. False when there is no text, for `super`.
    private func pasteChecked(_ text: String?, from pb: NSPasteboard) -> Bool {
        guard let text else { return false }
        if !holdIfRisky(text, from: pb) { surfaceModel?.pasteText(text) }
        return true
    }

    /// Writes a paste the user confirmed, encoded as Ghostty pastes: ESC and other controls become spaces,
    /// and LF becomes CR outside a bracketed paste.
    func sendPaste(_ text: String) {
        onInput?()
        surfaceModel?.sendText(text)
    }

    override func keyDown(with event: NSEvent) {
        // Neither this view nor Ghostty's filters isARepeat: a Return still held from the palette or
        // another tab would otherwise type into whatever tab took focus.
        guard KeyGuard.shared.allows(view: ObjectIdentifier(self), surfaceId: surfaceId, isRepeat: event.isARepeat,
                                     isReturn: KeyGuard.isReturn(keyCode: event.keyCode), awaitsAnswer: awaitsAnswer,
                                     now: ProcessInfo.processInfo.systemUptime) else { return }
        onInput?()
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { KeyGuard.shared.focusMoved() }
        return took
    }

    override func paste(_ sender: Any?) {
        onInput?()
        if pasteChecked(NSPasteboard.general.getOpinionatedStringContents(), from: .general) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        onInput?()
        if pasteChecked(NSPasteboard.general.getOpinionatedStringContents(), from: .general) { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteSelection(_ sender: Any?) {
        onInput?()
        if pasteChecked(NSPasteboard.ghosttySelection.getOpinionatedStringContents(), from: .ghosttySelection) { return }
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
        if event.buttonNumber == 2, middleClickPastes(), surfaceModel?.mouseCaptured == false {
            onInput?()
            _ = pasteChecked(NSPasteboard.ghosttySelection.getOpinionatedStringContents(), from: .ghosttySelection)
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onInput?()
        if holdIfRisky(sender.draggingPasteboard.getOpinionatedStringContents(), from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Services such as "Send to Terminal" write the pasteboard straight into the pty.
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        onInput?()
        if holdIfRisky(pboard.getOpinionatedStringContents(), from: pboard) { return true }
        return super.readSelection(from: pboard)
    }

    /// A confirmed paste writes when its request resolves, possibly long after the paste action itself.
    /// The request's outcome is private, so retire on every resolution, including a cancel.
    override var pendingClipboardConfirmation: Ghostty.ClipboardConfirmationRequest? {
        didSet {
            guard oldValue !== pendingClipboardConfirmation else { return }
            if let old = oldValue, old.kind == .paste { onInput?() }
            let new = pendingClipboardConfirmation
            // Only pastes get a sheet. Any other access Ghostty asks about (an OSC 52 read under
            // clipboard-read = ask) is denied now rather than left waiting forever.
            if let new, new.kind != .paste {
                AppDelegate.logger.warning("clipboard \(String(describing: new.kind), privacy: .public) request denied")
                new.cancel()
                DispatchQueue.main.async { [weak self] in
                    if self?.pendingClipboardConfirmation === new { self?.pendingClipboardConfirmation = nil }
                }
            }
            onPasteConfirmation?(new?.kind == .paste ? new : nil)
        }
    }
}

