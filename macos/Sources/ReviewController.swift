import AppKit

/// What the review screen needs from the main window, kept narrow so it lives outside MainWindow.swift.
protocol ReviewHost: AnyObject {
    var reviewCore: CoreAPI { get }
    var reviewFixture: Fixture? { get }
    var reviewWindow: NSWindow? { get }
    /// The selected tab: its surface and its sidebar row.
    var reviewSelection: (surfaceId: String, row: Row?)? { get }
    /// Every sidebar row, in sidebar order.
    var reviewRows: [Row] { get }
    /// Puts the view over the terminal pane (or the whole window below the title bar), or removes it (nil).
    func showReviewView(_ view: NSView?, coverSidebar: Bool)
    /// A crumb and accessory while reviewing; nil puts the title bar back.
    func setReviewTitle(crumb: [String], accessory: TitleBarView.Accessory?)
    /// Types `text` into the surface as a paste (`ghostty_surface_text`), after calling `onUserInput`.
    func pasteIntoSurface(_ text: String, surfaceId: String) -> Bool
    func selectTab(_ surfaceId: String)
    func focusTerminal()
}

/// Opens, fills and closes the review screen: the inbox (version 11) first, then a tab's full review
/// (01, 06, 09). Reviews are kept per tab, in memory, until a new turn.
final class ReviewCoordinator {
    private unowned let host: ReviewHost
    private var reviews: [String: ReviewState] = [:]
    /// Notes sent back per tab, with the turn they were sent after.
    private var sent: [String: (turn: UInt32, notes: Int)] = [:]
    private var view: ReviewView?
    private var inbox: InboxView?
    private var fromInbox = false
    /// Set while the review itself switches tabs, which would otherwise close it.
    private var switching = false
    private var loading: Set<ObjectIdentifier> = []
    private static let queue = DispatchQueue(label: "dev.haunt.review", qos: .userInitiated)

    init(host: ReviewHost) {
        self.host = host
    }

    var isOpen: Bool { view != nil || inbox != nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// The inbox with the selected tab's entry selected. Fixtures for 01, 06 and 09 open that version directly.
    func open() {
        guard let sel = host.reviewSelection else { return NSSound.beep() }
        if let f = host.reviewFixture, f.isReview, f != .reviewInbox {
            return openDetail(sel.surfaceId, row: sel.row, mode: nil)
        }
        openInbox(selecting: sel.surfaceId)
    }

    private func turn(for row: Row) -> ReviewTurn? {
        if let f = host.reviewFixture, f.isReview { return f == .reviewInbox ? f.inboxTurn(tab: row.name) : f.reviewTurn }
        return host.reviewCore.reviewTurn(surfaceId: row.surfaceId)
    }

    /// The tab's review, kept while its turn is the same one.
    private func state(for id: String, turn: ReviewTurn?) -> ReviewState {
        if let old = reviews[id], old.turn?.number == turn?.number, old.turn?.startedMs == turn?.startedMs,
           old.turn?.finishedMs == turn?.finishedMs {
            return old
        }
        let s = ReviewState(surfaceId: id)
        s.turn = turn.map(Visible.turn)
        reviews[id] = s
        return s
    }

    // MARK: Inbox

    private func openInbox(selecting id: String?) {
        view = nil
        fromInbox = false
        let fixture = host.reviewFixture
        let entries: [InboxEntry] = host.reviewRows.filter { $0.kind != .shell }.compactMap { row in
            guard let t = turn(for: row), t.cwd != nil else { return nil }
            let e = InboxEntry(surfaceId: row.surfaceId, row: row, state: state(for: row.surfaceId, turn: t))
            if let sb = sent[row.surfaceId] {
                e.sentBack = Inbox.sentBack(notes: sb.notes, sentTurn: sb.turn, turn: t)
                if e.sentBack == nil { sent[row.surfaceId] = nil }
            }
            fixture?.setUpInbox(e)
            return e
        }
        let v = inbox ?? InboxView()
        v.onClose = { [weak self] in self?.close() }
        v.onOpen = { [weak self] e in self?.openDetail(e.surfaceId, row: e.row, mode: .files) }
        v.onRequestChanges = { [weak self] e in self?.openDetail(e.surfaceId, row: e.row, mode: .sendBack) }
        inbox = v
        v.update(entries, select: id)
        host.showReviewView(v, coverSidebar: true)
        host.reviewWindow?.makeFirstResponder(v)
        updateTitle()
        for e in entries where e.state.diff == nil && e.state.loadError == nil { load(e.state) }
    }

    // MARK: A tab's review

    private func openDetail(_ id: String, row: Row?, mode: ReviewState.Mode?) {
        let came = inbox != nil
        if came, host.reviewSelection?.surfaceId != id {
            switching = true
            host.selectTab(id)
            switching = false
        }
        inbox = nil
        fromInbox = came
        let fixture = host.reviewFixture
        let st = state(for: id, turn: row.flatMap { turn(for: $0) })
        if let mode { st.mode = mode }
        let v = ReviewView(state: st)
        v.crumbName = row?.name
        v.onClose = { [weak self] in
            guard let self else { return }
            if self.fromInbox { self.openInbox(selecting: id) } else { self.close() }
        }
        v.onModeChange = { [weak self] in self?.updateTitle() }
        v.onSend = { [weak self] text, keep in self?.send(text, keepReviewing: keep) }
        view = v
        host.showReviewView(v, coverSidebar: false)
        host.reviewWindow?.makeFirstResponder(v)
        updateTitle()

        if let fixture, fixture.isReview, fixture != .reviewInbox {
            st.diff = fixture.reviewDiff
            let (files, scripts) = fixture.reviewProject
            st.checks = Checks.merge(turn: Checks.fromTurn(st.turn?.commands ?? []),
                                     expected: Checks.expected(files: files, packageScripts: scripts))
            fixture.setUpReview(st)
            v.reload(editing: fixture.reviewEditingComment)
            updateTitle()
            return
        }
        if st.diff == nil, st.loadError == nil { load(st) } else { v.dataChanged() }
    }

    /// git runs off the main thread; the verified agent cwd is the only place it runs.
    private func load(_ state: ReviewState) {
        guard !loading.contains(ObjectIdentifier(state)) else { return }
        guard let cwd = state.turn?.cwd else {
            state.loadError = "Haunt has no verified agent working directory for this tab, so there is nothing to review."
            changed(state)
            return
        }
        loading.insert(ObjectIdentifier(state))
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
                self?.loading.remove(ObjectIdentifier(state))
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
                self?.changed(state)
            }
        }
    }

    private func changed(_ state: ReviewState) {
        inbox?.refresh()
        if view?.state === state { view?.dataChanged() }
    }

    func close() {
        guard !switching, isOpen else { return }
        view = nil
        inbox = nil
        fromInbox = false
        host.showReviewView(nil, coverSidebar: false)
        host.setReviewTitle(crumb: [], accessory: nil)
        host.focusTerminal()
    }

    private func updateTitle() {
        let fixture = host.reviewFixture
        if inbox != nil {
            return host.setReviewTitle(crumb: ["Review"], accessory: fixture == nil ? nil : .kbd)
        }
        guard let v = view else { return }
        let s = v.state
        let name = v.crumbName ?? "review"
        let branch = s.diff?.branch
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
        let id = v.state.surfaceId
        let row = host.reviewRows.first { $0.surfaceId == id }
        let refusal: String?
        var clean = ""
        switch SendBack.check(text) {
        case let .blocked(why): refusal = why
        case let .ok(t):
            clean = t
            if row == nil {
                refusal = "The reviewed tab is gone."
            } else if row?.kind == .shell {
                refusal = "This tab isn't running an agent, so there's nothing to send the prompt to."
            } else if row?.needsYou == true {
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
        guard host.pasteIntoSurface(clean, surfaceId: id) else { return NSSound.beep() }
        if let n = v.state.turn?.number { sent[id] = (n, max(v.state.comments.count, 1)) }
        v.state.comments = []
        v.state.editedDraft = nil
        v.state.note = ""
        if host.reviewSelection?.surfaceId != id {
            switching = true
            host.selectTab(id)
            switching = false
        }
        if keepReviewing {
            v.setMode(.files)
        } else {
            close()
        }
    }
}
