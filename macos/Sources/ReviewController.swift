import AppKit

/// What the review screen needs from the main window, kept narrow so it lives outside MainWindow.swift.
protocol ReviewHost: AnyObject {
    var reviewCore: CoreAPI { get }
    var reviewFixture: Fixture? { get }
    var reviewWindow: NSWindow? { get }
    /// The selected tab: its surface, its sidebar row, and the shell's pwd.
    var reviewSelection: (surfaceId: String, row: Row?)? { get }
    /// Puts the view over the terminal pane, or removes it (nil).
    func showReviewView(_ view: NSView?)
    /// A crumb and accessory while reviewing; nil puts the title bar back.
    func setReviewTitle(crumb: [String], accessory: TitleBarView.Accessory?)
    /// Types `text` into the surface as a paste (`ghostty_surface_text`), after calling `onUserInput`.
    func pasteIntoSurface(_ text: String, surfaceId: String) -> Bool
    func focusTerminal()
}

/// Opens, fills and closes the review screen. Reviews are kept per tab, in memory, until a new turn.
final class ReviewCoordinator {
    private unowned let host: ReviewHost
    private var reviews: [String: ReviewState] = [:]
    private var view: ReviewView?
    private static let queue = DispatchQueue(label: "dev.haunt.review", qos: .userInitiated)

    init(host: ReviewHost) {
        self.host = host
    }

    var isOpen: Bool { view != nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard let sel = host.reviewSelection else { return NSSound.beep() }
        let fixture = host.reviewFixture
        let turn = fixture?.reviewTurn ?? host.reviewCore.reviewTurn(surfaceId: sel.surfaceId)
        let state: ReviewState
        if let old = reviews[sel.surfaceId], old.turn?.number == turn?.number, old.turn?.startedMs == turn?.startedMs,
           old.turn?.finishedMs == turn?.finishedMs {
            state = old
        } else {
            state = ReviewState(surfaceId: sel.surfaceId)
            state.turn = turn
            reviews[sel.surfaceId] = state
        }
        let v = ReviewView(state: state)
        v.crumbName = sel.row?.name
        v.onClose = { [weak self] in self?.close() }
        v.onModeChange = { [weak self] in self?.updateTitle() }
        v.onSend = { [weak self] text, keep in self?.send(text, keepReviewing: keep) }
        view = v
        host.showReviewView(v)
        host.reviewWindow?.makeFirstResponder(v)
        updateTitle()

        if let fixture {
            state.diff = fixture.reviewDiff
            let (files, scripts) = fixture.reviewProject
            state.checks = Checks.merge(turn: Checks.fromTurn(turn?.commands ?? []),
                                        expected: Checks.expected(files: files, packageScripts: scripts))
            fixture.setUpReview(state)
            v.reload(editing: fixture.reviewEditingComment)
            updateTitle()
            return
        }
        load(state)
    }

    /// git runs off the main thread; the verified agent cwd is the only place it runs.
    private func load(_ state: ReviewState) {
        guard let cwd = state.turn?.cwd else {
            state.loadError = "Haunt has no verified agent working directory for this tab, so there is nothing to review."
            view?.dataChanged()
            return
        }
        let start = state.turn?.headAtStart
        let commands = state.turn?.commands ?? []
        Self.queue.async { [weak self] in
            let result = ReviewLoader.load(cwd: cwd, headAtStart: start)
            var checks: [Check] = Checks.fromTurn(commands)
            if case let .success(d) = result {
                let (files, scripts) = Checks.projectFiles(root: d.root)
                checks = Checks.merge(turn: checks, expected: Checks.expected(files: files, packageScripts: scripts))
            }
            DispatchQueue.main.async {
                switch result {
                case let .success(d):
                    state.diff = d
                    state.loadError = nil
                    if !state.files.indices.contains(state.selectedFile) { state.selectedFile = state.tree.fileOrder.first ?? 0 }
                case .failure(.noGit):
                    state.loadError = "git isn't installed (looked in /opt/homebrew/bin, /usr/local/bin and the developer tools)."
                case let .failure(.notARepo(p)):
                    state.loadError = "\((p as NSString).abbreviatingWithTildeInPath) isn't in a git repository."
                case let .failure(.failed(why)):
                    state.loadError = why
                }
                state.checks = checks
                guard let self, self.view?.state === state else { return }
                self.view?.dataChanged()
            }
        }
    }

    func close() {
        guard view != nil else { return }
        view = nil
        host.showReviewView(nil)
        host.setReviewTitle(crumb: [], accessory: nil)
        host.focusTerminal()
    }

    private func updateTitle() {
        guard let v = view else { return }
        let s = v.state
        let name = v.crumbName ?? "review"
        let branch = s.diff?.branch
        let fixture = host.reviewFixture
        switch s.mode {
        case .files:
            host.setReviewTitle(crumb: [name] + (branch.map { [$0] } ?? []) + ["Review"], accessory: fixture == nil ? nil : .empty)
        case .overview:
            host.setReviewTitle(crumb: [name] + (branch.map { [$0] } ?? []) + ["Overview"], accessory: fixture == nil ? nil : .kbd)
        case .sendBack:
            // Version 06 has no crumb.
            host.setReviewTitle(crumb: [], accessory: fixture == nil ? nil : .icons)
        }
    }

    /// Only into an agent tab that isn't waiting on a prompt, only text that passes SendBack, never with a Return.
    private func send(_ text: String, keepReviewing: Bool) {
        guard let v = view, let window = host.reviewWindow else { return }
        let sel = host.reviewSelection
        let refusal: String?
        var clean = ""
        switch SendBack.check(text) {
        case let .blocked(why): refusal = why
        case let .ok(t):
            clean = t
            if sel?.surfaceId != v.state.surfaceId {
                refusal = "The reviewed tab isn't selected any more."
            } else if sel?.row.map({ $0.kind == .shell }) ?? true {
                refusal = "This tab isn't running an agent, so there's nothing to send the prompt to."
            } else if sel?.row?.needsYou == true {
                refusal = "The agent is waiting on a prompt in the terminal. Answer it there first, then send."
            } else {
                refusal = nil
            }
        }
        if let refusal {
            let alert = NSAlert()
            alert.messageText = "Not sent"
            alert.informativeText = refusal
            alert.beginSheetModal(for: window)
            return
        }
        guard host.pasteIntoSurface(clean, surfaceId: v.state.surfaceId) else { return NSSound.beep() }
        v.state.comments = []
        v.state.editedDraft = nil
        v.state.note = ""
        if keepReviewing {
            v.setMode(.files)
        } else {
            close()
        }
    }
}
