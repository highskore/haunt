import AppKit

/// The inbox's sizes are all tokens; the short name keeps layout code readable.
private typealias TS = Tok.Size

/// Drawing for the inbox, laid out like haunt-review-2/index.html's CSS (version 11).
private enum IB {
    static let lh = Tok.Font.baseLine

    /// `.stat`: "+a" in ink, " −d" muted.
    @discardableResult
    static func stat(_ add: Int, _ del: Int, x: CGFloat, mid: CGFloat, in ctx: CGContext) -> CGFloat {
        let f = Draw.mono(TS.inboxStatFont), l = TS.inboxStatFont * lh
        var w = RV.text("+\(add)", f, Tok.Color.textPrimary, x: x, top: mid - l / 2, lineHeight: l, in: ctx)
        w += RV.text(" −\(del)", f, Tok.Color.textMeta, x: x + w, top: mid - l / 2, lineHeight: l, in: ctx)
        return w
    }

    static func statWidth(_ add: Int, _ del: Int) -> CGFloat { RV.width("+\(add) −\(del)", Draw.mono(TS.inboxStatFont)) }

    /// `.blocks`: five squares, the added share in ink.
    static func blocks(_ add: Int, _ del: Int, x: CGFloat, mid: CGFloat) {
        let t = add + del, n = 5
        let a = t == 0 ? n : Int((Double(add) / Double(t) * Double(n)).rounded())
        let s = TS.inboxBlocksSize, r = TS.inboxBlocksRadius
        for i in 0..<n {
            let rect = NSRect(x: x + CGFloat(i) * (s + TS.inboxBlocksGap), y: RV.px(mid - s / 2), width: s, height: s)
            (i < a ? Tok.Color.textPrimary : Tok.Color.inboxBlocksDel).setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        }
    }

    static var blocksWidth: CGFloat { 5 * TS.inboxBlocksSize + 4 * TS.inboxBlocksGap }

    /// `.kbd`: the window's shortcut box.
    @discardableResult
    static func kbd(_ s: String, x: CGFloat, mid: CGFloat, in ctx: CGContext) -> CGFloat {
        let f = Draw.ui(TS.kbdFont), w = RV.width(s, f) + TS.kbdPad[1] * 2 + 2, h = TS.kbdLine + 2
        let r = NSRect(x: x, y: RV.px(mid - h / 2), width: w, height: h)
        RV.rounded(r, radius: TS.kbdRadius, fill: nil, stroke: Tok.Color.kbdBorder)
        RV.text(s, f, Tok.Color.textSub, x: x + 1 + TS.kbdPad[1], top: r.minY + 1, lineHeight: TS.kbdLine, in: ctx)
        return w
    }

    static func kbdWidth(_ s: String) -> CGFloat { RV.width(s, Draw.ui(TS.kbdFont)) + TS.kbdPad[1] * 2 + 2 }

    /// `.ck`: a 13 pt box, filled with a tick when on.
    static func check(_ r: NSRect, on: Bool, in ctx: CGContext) {
        let rad = TS.inboxCkRadius
        if on {
            Tok.Color.textPrimary.setFill()
            NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
            let f = Draw.ui(TS.reviewChkFont)
            RV.text("✓", f, Tok.Color.windowBg, x: r.midX - RV.width("✓", f) / 2, top: r.minY, lineHeight: r.height, in: ctx)
        } else {
            RV.rounded(r, radius: rad, fill: nil, stroke: Tok.Color.inboxCkBorder)
        }
    }

    /// Where `Draw.text` puts the baseline of a line box.
    static func baseline(_ font: NSFont, top: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let a = font.ascender.rounded(), d = (-font.descender).rounded()
        return top + (lineHeight - a - d) / 2 + a
    }

    static func ago(_ ms: UInt64) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970) - Int(ms / 1000))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    static func statusLetter(_ f: FileDiff) -> String {
        switch f.status {
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .modified: return "M"
        }
    }

    /// The file list shows the last two path parts, as the mockup does.
    static func shortPath(_ p: String) -> String {
        let parts = p.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

/// `.btn` in version 11: 11 pt label and a small boxed shortcut.
final class InboxButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    let key: String
    let primary: Bool
    var action: (() -> Void)?

    init(_ title: String, key: String, primary: Bool = false) {
        self.title = title
        self.key = key
        self.primary = primary
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static var height: CGFloat { TS.inboxBtnLine + TS.inboxBtnPad[0] * 2 + 2 }
    private var font: NSFont { Draw.ui(TS.inboxBtnFont) }
    private var keyFont: NSFont { Draw.ui(TS.inboxBtnKeyFont) }
    private var keyW: CGFloat { RV.width(key, keyFont) + TS.inboxBtnKeyPad[1] * 2 + 2 }

    var fittingWidth: CGFloat { 2 + TS.inboxBtnPad[1] * 2 + RV.width(title, font) + TS.inboxBtnGap + keyW }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        RV.rounded(bounds, radius: TS.inboxBtnRadius, fill: primary ? Tok.Color.btnPrimaryBg : nil,
                   stroke: primary ? Tok.Color.btnPrimaryBg : Tok.Color.kbdBorder)
        let top = 1 + TS.inboxBtnPad[0]
        var x = 1 + TS.inboxBtnPad[1]
        x += RV.text(title, font, primary ? Tok.Color.btnPrimaryFg : Tok.Color.btnFg, x: x, top: top, lineHeight: TS.inboxBtnLine, in: ctx)
        x += TS.inboxBtnGap
        let kh = TS.inboxBtnKeyLine + 2
        let kr = NSRect(x: x, y: RV.px(bounds.midY - kh / 2), width: keyW, height: kh)
        RV.rounded(kr, radius: TS.inboxBtnKeyRadius, fill: nil, stroke: primary ? Tok.Color.inboxBtnKeyBorder : Tok.Color.kbdBorder)
        RV.text(key, keyFont, primary ? Tok.Color.btnPrimaryFg : Tok.Color.textSub, x: kr.minX + 1 + TS.inboxBtnKeyPad[1], top: kr.minY + 1,
                lineHeight: TS.inboxBtnKeyLine, in: ctx)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

/// Version 11: every agent tab's latest turn in one queue, the selected one's prompt, checks, files and diff
/// beside it. Enter opens the full review (01, 06, 09) for it.
final class InboxView: NSView {
    private(set) var entries: [InboxEntry] = []
    private(set) var selectedId: String?
    var onOpen: ((InboxEntry) -> Void)?
    var onRequestChanges: ((InboxEntry) -> Void)?
    var onClose: (() -> Void)?

    private let list = InboxList()
    private let detail = InboxDetail()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Tok.Color.windowBg.cgColor
        addSubview(list)
        addSubview(detail)
        list.onSelect = { [weak self] id, open in
            self?.select(id)
            if open, let e = self?.selected { self?.onOpen?(e) }
        }
        detail.onApprove = { [weak self] in self?.approveSelected() }
        detail.onRequestChanges = { [weak self] in if let e = self?.selected { self?.onRequestChanges?(e) } }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var selected: InboxEntry? { entries.first { $0.surfaceId == selectedId } }

    /// The entries in the order the list shows them, for j/k.
    private var ordered: [InboxEntry] { Inbox.grouped(entries).flatMap(\.entries) }

    func update(_ entries: [InboxEntry], select id: String?) {
        self.entries = entries
        selectedId = id.flatMap { i in entries.contains { $0.surfaceId == i } ? i : nil } ?? ordered.first?.surfaceId
        refresh()
    }

    /// Something in an entry changed (its diff arrived, it was approved).
    func refresh() {
        list.entries = entries
        list.selectedId = selectedId
        detail.entry = selected
        needsLayout = true
    }

    func select(_ id: String) {
        guard id != selectedId else { return }
        selectedId = id
        refresh()
    }

    private func step(_ d: Int) {
        let o = ordered
        guard !o.isEmpty else { return }
        let i = o.firstIndex { $0.surfaceId == selectedId } ?? -d
        select(o[min(max(i + d, 0), o.count - 1)].surfaceId)
    }

    private func approveSelected() {
        guard let e = selected else { return }
        e.state.approved = true
        refresh()
    }

    override func layout() {
        super.layout()
        list.frame = NSRect(x: 0, y: 0, width: TS.inboxSideW, height: bounds.height)
        detail.frame = NSRect(x: TS.inboxSideW, y: 0, width: bounds.width - TS.inboxSideW, height: bounds.height)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53 { return onClose?() ?? () }
        guard mods.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: if let e = selected { onOpen?(e) }; return
        case 125: return step(1)
        case 126: return step(-1)
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "j": step(1)
        case "k": step(-1)
        case "a": approveSelected()
        case "r": if let e = selected { onRequestChanges?(e) }
        default: super.keyDown(with: event)
        }
    }
}

/// The inbox's left column: grouped entries, then the open/ready count.
private final class InboxList: NSView {
    var entries: [InboxEntry] = [] { didSet { needsDisplay = true } }
    var selectedId: String? { didSet { needsDisplay = true } }
    var onSelect: ((String, Bool) -> Void)?

    override var isFlipped: Bool { true }

    private var labelH: CGFloat { TS.labelPad[0] + TS.labelFont * IB.lh + TS.labelPad[2] }
    private var line1: CGFloat { max(TS.iconSize, TS.rowName * IB.lh, TS.rowRight * IB.lh) }
    private var rowH: CGFloat { TS.rowPad[0] * 2 + line1 + TS.rowGap[0] + TS.rowMeta * IB.lh }

    private func layoutRows() -> [(InboxEntry, CGFloat)] {
        var y: CGFloat = 0, out: [(InboxEntry, CGFloat)] = []
        for g in Inbox.grouped(entries) {
            y += labelH
            for e in g.entries {
                out.append((e, y))
                y += rowH
            }
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(bounds, Tok.Color.sidebarBg)
        Draw.fill(NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Tok.Color.hairline)
        let w = bounds.width - 1
        var y: CGFloat = 0
        for g in Inbox.grouped(entries) {
            let f = Draw.ui(TS.labelFont)
            RV.text(g.label.uppercased(), f, Tok.Color.textLabel, x: TS.labelPad[1], top: y + TS.labelPad[0],
                    lineHeight: TS.labelFont * IB.lh, kern: TS.labelFont * TS.labelTrackingEm, in: ctx)
            y += labelH
            for e in g.entries {
                drawRow(e, top: y, width: w, ctx: ctx)
                y += rowH
            }
        }
        if entries.isEmpty {
            RV.text("No agent turns to review yet.", Draw.ui(TS.rowMeta), Tok.Color.textLabel, x: TS.labelPad[1], top: TS.labelPad[0], in: ctx)
        }
        drawFoot(width: w, ctx: ctx)
    }

    private func drawRow(_ e: InboxEntry, top: CGFloat, width: CGFloat, ctx: CGContext) {
        if e.surfaceId == selectedId { Draw.fill(NSRect(x: 0, y: top, width: width, height: rowH), Tok.Color.rowSelected) }
        let left = TS.rowPad[1], right = width - TS.rowPad[1]
        let col2 = left + TS.iconSize + TS.rowGap[1]
        let y = top + TS.rowPad[0], mid = y + line1 / 2
        let s = TS.claudeIcon
        let icon = NSRect(x: left + (TS.iconSize - s) / 2, y: mid - s / 2, width: s, height: s)
        if e.row.kind == .codex { Draw.codexMark(in: icon, color: Tok.Color.textPrimary, ctx: ctx) } else { Draw.claudeMark(in: icon) }
        var rightW: CGFloat = 0
        if e.status == .waiting {
            let d = TS.inboxDotSize
            rightW = d
            RV.rounded(NSRect(x: right - d, y: RV.px(mid - d / 2), width: d, height: d), radius: d / 2, fill: nil, stroke: Tok.Color.textSub)
        } else if let d = e.state.diff {
            let (a, r) = d.files.reduce((0, 0)) { ($0.0 + $1.additions, $0.1 + $1.deletions) }
            rightW = IB.statWidth(a, r)
            IB.stat(a, r, x: right - rightW, mid: mid, in: ctx)
        }
        let nf = Draw.ui(TS.rowName)
        RV.text(e.name, nf, Tok.Color.textPrimary, x: col2, top: mid - TS.rowName * IB.lh / 2, lineHeight: TS.rowName * IB.lh,
                maxWidth: right - TS.rowGap[1] - rightW - col2, in: ctx)
        RV.text(e.meta, Draw.ui(TS.rowMeta), Tok.Color.textMeta, x: col2, top: y + line1 + TS.rowGap[0], lineHeight: TS.rowMeta * IB.lh,
                maxWidth: right - col2, in: ctx)
    }

    private func drawFoot(width: CGFloat, ctx: CGContext) {
        let h = TS.footH, top = bounds.height - h
        Draw.fill(NSRect(x: 0, y: top, width: width, height: 1), Tok.Color.hairline)
        let mid = top + 1 + (h - 1) / 2
        let open = entries.filter { $0.status != .approved }.count, ready = entries.filter { $0.status == .ready }.count
        let f = Draw.ui(TS.footFont), l = TS.footFont * IB.lh
        RV.text("\(open) open · \(ready) ready", f, Tok.Color.textLabel, x: TS.footPadx, top: mid - l / 2, lineHeight: l, in: ctx)
        var x = width - TS.footPadx - IB.kbdWidth("k")
        IB.kbd("k", x: x, mid: mid, in: ctx)
        x -= TS.footGap + IB.kbdWidth("j")
        IB.kbd("j", x: x, mid: mid, in: ctx)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (e, top) in layoutRows() where p.y >= top && p.y < top + rowH {
            onSelect?(e.surfaceId, event.clickCount == 2)
            return
        }
    }
}

/// The selected entry: title and verdict buttons, the prompt and turn facts, files and checks, the diff.
private final class InboxDetail: NSView {
    var entry: InboxEntry? { didSet { update(changed: entry !== oldValue) } }
    var onApprove: (() -> Void)?
    var onRequestChanges: (() -> Void)?

    private let requestBtn = InboxButton("Request changes", key: "r")
    private let approveBtn = InboxButton("Approve", key: "a", primary: true)
    private let files = InboxFiles()
    private let scroll = NSScrollView()
    private let diff = InboxDiffView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        requestBtn.action = { [weak self] in self?.onRequestChanges?() }
        approveBtn.action = { [weak self] in self?.onApprove?() }
        scroll.documentView = diff
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        files.onSelect = { [weak self] i in self?.selectFile(i) }
        diff.onToggleViewed = { [weak self] i in self?.toggleViewed(i) }
        for v in [requestBtn, approveBtn, files, scroll] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// `min-height:58px` with border-box sizing: the hairline is inside.
    private var hdH: CGFloat { TS.inboxHdH }
    /// Snapped like Blink snaps the box edge.
    private var stripH: CGFloat { RV.px(hdH + TS.inboxStripPad[0] * 2 + TS.inboxStripFont * IB.lh + 1) - hdH }

    private func update(changed: Bool) {
        files.state = entry?.state
        diff.state = entry?.state
        approveBtn.title = entry?.state.approved == true ? "Approved" : "Approve"
        for v in [requestBtn, approveBtn, files, scroll] as [NSView] { v.isHidden = entry == nil }
        if changed { scroll.contentView.scroll(to: .zero) }
        needsLayout = true
        needsDisplay = true
    }

    private func selectFile(_ i: Int) {
        guard let s = entry?.state else { return }
        s.selectedFile = i
        files.needsDisplay = true
        diff.needsDisplay = true
        if let y = diff.top(of: i) { diff.scroll(NSPoint(x: 0, y: y)) }
    }

    private func toggleViewed(_ i: Int) {
        guard let s = entry?.state, s.files.indices.contains(i) else { return }
        let p = s.files[i].path
        if s.viewed.contains(p) { s.viewed.remove(p) } else { s.viewed.insert(p) }
        diff.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        var x = w - TS.inboxHdPadx
        let bh = InboxButton.height, by = RV.px((TS.inboxHdH - 1 - bh) / 2)
        for b in [approveBtn, requestBtn] {
            x -= b.fittingWidth
            b.frame = NSRect(x: x, y: by, width: b.fittingWidth, height: bh)
            x -= TS.inboxHdGap
        }
        let top = hdH + stripH
        files.frame = NSRect(x: 0, y: top, width: TS.inboxFilesW, height: bounds.height - top)
        scroll.frame = NSRect(x: TS.inboxFilesW, y: top, width: w - TS.inboxFilesW, height: bounds.height - top)
        diff.width = scroll.contentSize.width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(bounds, Tok.Color.windowBg)
        guard let e = entry else {
            RV.text("Nothing to review.", Draw.ui(TS.rowMeta), Tok.Color.textLabel, x: TS.inboxHdPadx, top: TS.inboxHdPadx, in: ctx)
            return
        }
        let w = bounds.width, s = e.state, t = s.turn
        Draw.fill(NSRect(x: 0, y: TS.inboxHdH - 1, width: w, height: 1), Tok.Color.hairline)
        Draw.fill(NSRect(x: 0, y: hdH + stripH - 1, width: w, height: 1), Tok.Color.hairline)

        // Header: the prompt's first line as the title (no agent summary exists), then where and when.
        let tf = Draw.ui(TS.inboxHdTitleFont), tl = TS.inboxHdTitleFont * IB.lh
        let mf = Draw.ui(TS.inboxHdMetaFont), ml = TS.inboxHdMetaFont * IB.lh
        let blockTop = (TS.inboxHdH - 1 - tl - TS.inboxHdRowgap - ml) / 2
        let textRight = requestBtn.frame.minX - TS.inboxHdGap
        let x0 = TS.inboxHdPadx
        let title = t?.prompt?.split(separator: "\n").first.map(String.init) ?? "No prompt recorded"
        RV.text(title, tf, Tok.Color.textPrimary, x: x0, top: blockTop, lineHeight: tl, maxWidth: textRight - x0, in: ctx)
        let mt = blockTop + tl + TS.inboxHdRowgap
        var lead = e.repo + (s.diff?.branch.map { "/" + $0 } ?? "")
        if let u = s.diff?.upstream { lead += " → " + u }
        lead += " · "
        var x = x0 + RV.text(lead, mf, Tok.Color.textMeta, x: x0, top: mt, lineHeight: ml, in: ctx)
        let ms = TS.inboxClaudeSmall
        // `vertical-align:-2px`: the mark's bottom sits 2 pt below the baseline.
        let bl = IB.baseline(mf, top: mt, lineHeight: ml)
        RV.agentMark(t?.agent ?? .claude, in: NSRect(x: x, y: bl + 2 - ms, width: ms, height: ms), ctx: ctx)
        x += ms
        var tail = [" " + e.tabName]
        if let c = s.diff?.commits, c > 0 { tail.append(RVText.plural(c, "commit")) }
        if let f = t?.finishedMs { tail.append("finished " + IB.ago(f)) } else if t != nil { tail.append("running") }
        RV.text(tail.joined(separator: " · "), mf, Tok.Color.textMeta, x: x, top: mt, lineHeight: ml, maxWidth: textRight - x, in: ctx)

        // Strip: the prompt, then turn facts pushed right.
        let sf = Draw.ui(TS.inboxStripFont), sl = TS.inboxStripFont * IB.lh
        let st = hdH + TS.inboxStripPad[0]
        var facts: [String] = []
        if let tasks = t?.tasks, !tasks.isEmpty {
            facts.append("tasks \(tasks.filter { $0.status == "completed" }.count)/\(tasks.count)")
        }
        let ran = Checks.fromTurn(t?.commands ?? [])
        // The test run, if there was one; otherwise the latest check.
        if let last = ran.last(where: { $0.command.contains("test") }) ?? ran.last {
            let mark = ["passed": "✓", "failed": "✗", "running": "running", "result unknown": "result unknown"][last.result] ?? last.result
            facts.append("\(last.command) \(mark)")
        } else {
            facts.append("no tests run")
        }
        if let n = t?.subagents.count, n > 0 { facts.append(RVText.plural(n, "subagent")) }
        if let a = t?.startedMs, let b = t?.finishedMs, b >= a { facts.append(RV.duration(b - a)) }
        var rx = w - TS.inboxStripPad[1]
        for f in facts.reversed() {
            let fw = RV.width(f, sf)
            rx -= fw
            RV.text(f, sf, Tok.Color.textSub, x: rx, top: st, lineHeight: sl, in: ctx)
            rx -= TS.inboxStripGap
        }
        var px = TS.inboxStripPad[1]
        px += RV.text("Prompt", sf, Tok.Color.textLabel, x: px, top: st, lineHeight: sl, in: ctx)
        px += RV.width("\u{00A0} ", sf)
        let prompt = (t?.prompt ?? "").replacingOccurrences(of: "\n", with: " ")
        RV.text(prompt, sf, Tok.Color.inboxPrompt, x: px, top: st, lineHeight: sl, maxWidth: max(rx - px, 0), in: ctx)
    }
}

/// Files and the turn's checks, the column beside the diff.
private final class InboxFiles: NSView {
    var state: ReviewState? { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    private var labelLine: CGFloat { TS.labelFont * IB.lh }
    private var rowH: CGFloat { TS.inboxFilePad[0] * 2 + TS.inboxFileFont * IB.lh }
    private var filesTop: CGFloat { TS.inboxFilesPadtop + TS.inboxFilesLabelPadtop + labelLine + TS.labelPad[2] }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(bounds, Tok.Color.windowBg)
        Draw.fill(NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Tok.Color.hairline)
        guard let s = state else { return }
        let w = bounds.width - 1
        label("Files · \(s.files.count)", top: TS.inboxFilesPadtop + TS.inboxFilesLabelPadtop, ctx: ctx)
        var y = filesTop
        if let err = s.loadError {
            RV.text(err, Draw.ui(TS.rowMeta), Tok.Color.textLabel, x: TS.inboxFilePad[1], top: y, maxWidth: w - TS.inboxFilePad[1] * 2, in: ctx)
            y += rowH
        } else if s.diff == nil {
            RV.text("Reading git…", Draw.ui(TS.rowMeta), Tok.Color.textLabel, x: TS.inboxFilePad[1], top: y, in: ctx)
            y += rowH
        }
        for (i, f) in s.files.enumerated() {
            let sel = i == s.selectedFile
            if sel { Draw.fill(NSRect(x: 0, y: y, width: w, height: rowH), Tok.Color.rowSelected) }
            let sf = Draw.mono(TS.inboxStatFont), sl = TS.inboxStatFont * IB.lh
            let flag = f.hiddenChars ? "hidden " : ""
            let word = f.special ? "special" : f.binary ? "binary" : nil
            let right = RV.width(flag, sf) + (word.map { RV.width($0, sf) } ?? IB.statWidth(f.additions, f.deletions))
            row(IB.statusLetter(f), IB.shortPath(f.shown), ink: sel ? Tok.Color.inboxFileSel : Tok.Color.inboxFileInk, top: y, width: w,
                rightW: right, ctx: ctx) { x, mid in
                let fx = x + (flag.isEmpty ? 0 : RV.text(flag, sf, Tok.Color.textPrimary, x: x, top: mid - sl / 2, lineHeight: sl, in: ctx))
                if let word {
                    RV.text(word, sf, Tok.Color.textMeta, x: fx, top: mid - sl / 2, lineHeight: sl, in: ctx)
                } else {
                    IB.stat(f.additions, f.deletions, x: fx, mid: mid, in: ctx)
                }
            }
            y += rowH
        }
        let checks = s.checks
        guard !checks.isEmpty else { return }
        label("Checks", top: y + TS.inboxChecksLabelPadtop, ctx: ctx)
        y += TS.inboxChecksLabelPadtop + labelLine + TS.labelPad[2]
        let mf = Draw.mono(TS.inboxFileFont), ml = TS.inboxFileFont * IB.lh
        for c in checks {
            let mark: String
            switch c.state {
            case .passed: mark = "✓"
            case .failed: mark = "✗"
            case .running: mark = "…"
            case .unknown: mark = "?"
            case .notRun: mark = "○"
            }
            let res = c.result + (c.source.map { " · " + $0 } ?? "")
            let rw = RV.width(res, mf)
            row(mark, c.command, ink: Tok.Color.inboxFileInk, top: y, width: w, rightW: rw, ctx: ctx) { x, mid in
                RV.text(res, mf, Tok.Color.textMeta, x: x, top: mid - ml / 2, lineHeight: ml, in: ctx)
            }
            y += rowH
        }
    }

    private func label(_ s: String, top: CGFloat, ctx: CGContext) {
        RV.text(s.uppercased(), Draw.ui(TS.labelFont), Tok.Color.textLabel, x: TS.labelPad[1], top: top, lineHeight: labelLine,
                kern: TS.labelFont * TS.labelTrackingEm, in: ctx)
    }

    /// `.f`: a status mark, the name filling the row, and something right-aligned.
    private func row(_ st: String, _ name: String, ink: NSColor, top: CGFloat, width: CGFloat, rightW: CGFloat, ctx: CGContext,
                     right: (CGFloat, CGFloat) -> Void) {
        let mid = top + rowH / 2
        let pad = TS.inboxFilePad[1], gap = TS.inboxFileGap
        let sf = Draw.mono(TS.inboxFileStFont), sl = TS.inboxFileStFont * IB.lh
        RV.text(st, sf, Tok.Color.textMeta, x: pad + (TS.inboxFileStW - RV.width(st, sf)) / 2, top: mid - sl / 2, lineHeight: sl, in: ctx)
        let nx = pad + TS.inboxFileStW + gap
        let rx = width - pad - rightW
        let nf = Draw.mono(TS.inboxFileFont), nl = TS.inboxFileFont * IB.lh
        RV.text(name, nf, ink, x: nx, top: mid - nl / 2, lineHeight: nl, maxWidth: rx - gap - nx, in: ctx)
        right(rx, mid)
    }

    override func mouseDown(with event: NSEvent) {
        guard let s = state else { return }
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(floor((p.y - filesTop) / rowH))
        if p.y >= filesTop, s.files.indices.contains(i) { onSelect?(i) }
    }
}

/// Every file's hunks in one scroll, monochrome with the mockup's light keyword colouring. Read-only:
/// comments are written in the full review.
private final class InboxDiffView: NSView {
    var state: ReviewState? { didSet { rebuild() } }
    var width: CGFloat = 0 { didSet { if width != oldValue { rebuild() } } }
    var onToggleViewed: ((Int) -> Void)?

    private enum Item {
        case header(Int)
        case hunk(Int, Int)
        case line(DiffLine)
        case note(String)
    }

    private var items: [(Item, NSRect)] = []

    override var isFlipped: Bool { true }

    private var lineH: CGFloat { TS.inboxDiffFont * TS.inboxDiffLine }
    private var numLine: CGFloat { TS.inboxDiffNumFont * TS.inboxDiffLine }
    private var hunkH: CGFloat { numLine + 2 }
    /// The tallest item in the flex row: the 11 pt labels' line box (the mono path and stat reset to `normal`).
    private var fhLine: CGFloat { TS.inboxFhRightFont * IB.lh }
    private var fhH: CGFloat { TS.inboxFhPad[0] * 2 + fhLine + 1 }
    private var textX: CGFloat { TS.inboxDiffNumW * 2 + TS.inboxDiffMarkW }

    func top(of file: Int) -> CGFloat? {
        for case let (.header(i), r) in items where i == file { return r.minY }
        return nil
    }

    private func rebuild() {
        items = []
        var y: CGFloat = 0
        func add(_ i: Item, _ h: CGFloat) {
            items.append((i, NSRect(x: 0, y: y, width: width, height: h)))
            y += h
        }
        if let s = state {
            for n in s.diff?.notes ?? [] { add(.note(n), hunkH) }
            for (fi, f) in s.files.enumerated() {
                add(.header(fi), fhH)
                if f.binary || f.special || (f.hunks.isEmpty && f.droppedLines == 0) {
                    add(.note(f.special ? "Special file (not a regular file or link), not shown"
                              : f.binary ? f.binaryNote : "No changes to show"), hunkH)
                    continue
                }
                for (hi, h) in f.hunks.enumerated() {
                    add(.hunk(fi, hi), hunkH)
                    for l in h.lines { add(.line(l), lineH) }
                }
                if f.droppedLines > 0 { add(.note("\(f.droppedLines) more lines not shown"), hunkH) }
            }
        }
        let visible = enclosingScrollView?.contentSize.height ?? 0
        frame = NSRect(x: 0, y: 0, width: width, height: max(y, visible))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(dirtyRect, Tok.Color.windowBg)
        guard let s = state else { return }
        for (item, r) in items where r.intersects(dirtyRect) {
            switch item {
            case let .header(fi): drawHeader(fi, s, in: r, ctx: ctx)
            case let .hunk(fi, hi): band(s.files[fi].hunks[hi].header, in: r, ctx: ctx)
            case let .note(t): band(t, in: r, ctx: ctx)
            case let .line(l): drawLine(l, in: r, ctx: ctx)
            }
        }
    }

    private func viewedRect(_ r: NSRect) -> NSRect {
        let f = Draw.ui(TS.inboxFhRightFont)
        let w = RV.width("Viewed", f), c = TS.inboxCkSize
        let mid = r.minY + (r.height - 1) / 2
        return NSRect(x: r.maxX - TS.inboxFhPad[1] - w - TS.inboxFhGap - c, y: RV.px(mid - c / 2), width: c + TS.inboxFhGap + w, height: c)
    }

    /// `.fh`: path, stat, blocks; then "i of N" and Viewed for the selected file, "new file" for an added one.
    private func drawHeader(_ fi: Int, _ s: ReviewState, in r: NSRect, ctx: CGContext) {
        let f = s.files[fi]
        Draw.fill(r, Tok.Color.inboxFhBg)
        Draw.fill(NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), Tok.Color.hairline)
        let mid = r.minY + TS.inboxFhPad[0] + fhLine / 2
        let rf = Draw.ui(TS.inboxFhRightFont), rl = TS.inboxFhRightFont * IB.lh
        var right = r.maxX - TS.inboxFhPad[1]
        if fi == s.selectedFile {
            let vr = viewedRect(r)
            IB.check(NSRect(x: vr.minX, y: vr.minY, width: TS.inboxCkSize, height: TS.inboxCkSize), on: s.viewed.contains(f.path), in: ctx)
            RV.text("Viewed", rf, Tok.Color.textMeta, x: vr.minX + TS.inboxCkSize + TS.inboxFhGap, top: mid - rl / 2, lineHeight: rl, in: ctx)
            right = vr.minX - TS.inboxFhGap
        }
        var tag = f.status == .added ? "new file" : f.status == .deleted ? "deleted" : fi == s.selectedFile ? "\(fi + 1) of \(s.files.count)" : nil
        if f.hiddenChars { tag = "hidden chars" + (tag.map { " · " + $0 } ?? "") }
        if let tag {
            let tw = RV.width(tag, rf)
            RV.text(tag, rf, Tok.Color.textMeta, x: right - tw, top: mid - rl / 2, lineHeight: rl, in: ctx)
            right -= tw + TS.inboxFhGap
        }
        let pf = Draw.mono(TS.inboxFhPathFont), pl = TS.inboxFhPathFont * IB.lh
        var x = r.minX + TS.inboxFhPad[1]
        let tailW = (f.binary || f.special ? 0 : TS.inboxFhGap + IB.statWidth(f.additions, f.deletions) + TS.inboxFhGap + IB.blocksWidth)
        let room = max(right - x - tailW, 40)
        let dirW = min(RV.width(f.dir, pf), max(room - RV.width(f.name, pf), 0))
        if dirW > 0 { x += RV.text(f.dir, pf, Tok.Color.textMeta, x: x, top: mid - pl / 2, lineHeight: pl, maxWidth: dirW, in: ctx) }
        x += RV.text(f.name, pf, Tok.Color.textPrimary, x: x, top: mid - pl / 2, lineHeight: pl, maxWidth: room - dirW, in: ctx)
        guard !f.binary, !f.special else { return }
        x += TS.inboxFhGap
        x += IB.stat(f.additions, f.deletions, x: x, mid: mid, in: ctx) + TS.inboxFhGap
        IB.blocks(f.additions, f.deletions, x: x, mid: mid)
    }

    /// `.r.h`: hunk headers and notes, small and muted on a ruled band.
    private func band(_ text: String, in r: NSRect, ctx: CGContext) {
        Draw.fill(r, Tok.Color.inboxDiffHunkBg)
        Draw.fill(NSRect(x: r.minX, y: r.minY, width: r.width, height: 1), Tok.Color.inboxDiffHunkRule)
        Draw.fill(NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), Tok.Color.inboxDiffHunkRule)
        RV.text(text, Draw.mono(TS.inboxDiffNumFont), Tok.Color.inboxDiffHunkInk, x: textX, top: r.minY + 1, lineHeight: numLine,
                maxWidth: r.width - textX - TS.inboxDiffTextPadr, in: ctx)
    }

    private func drawLine(_ l: DiffLine, in r: NSRect, ctx: CGContext) {
        let rr = NSRect(x: 0, y: RV.px(r.minY), width: r.width, height: RV.px(r.maxY) - RV.px(r.minY))
        let ink: NSColor, num: NSColor, mark: NSColor
        switch l.kind {
        case .add:
            Draw.fill(rr, Tok.Color.inboxDiffAddBg)
            Draw.fill(NSRect(x: 0, y: rr.minY, width: TS.inboxDiffBarW, height: rr.height), Tok.Color.inboxDiffAddBar)
            (ink, num, mark) = (Tok.Color.inboxDiffAddInk, Tok.Color.inboxDiffAddNum, Tok.Color.inboxDiffAddMark)
        case .del:
            hatch(rr, ctx: ctx)
            Draw.fill(NSRect(x: 0, y: rr.minY, width: TS.inboxDiffBarW, height: rr.height), Tok.Color.inboxDiffDelBar)
            (ink, num, mark) = (Tok.Color.inboxDiffDelInk, Tok.Color.inboxDiffNum, Tok.Color.inboxDiffDelMark)
        case .context:
            (ink, num, mark) = (Tok.Color.inboxDiffText, Tok.Color.inboxDiffNum, Tok.Color.inboxDiffNum)
        }
        let nf = Draw.mono(TS.inboxDiffNumFont), nw = TS.inboxDiffNumW, pr = TS.inboxDiffNumPadr
        for (n, x) in [(l.old, nw), (l.new, nw * 2)] {
            guard let n else { continue }
            let s = String(n)
            RV.text(s, nf, num, x: x - pr - RV.width(s, nf), top: r.minY, lineHeight: numLine, in: ctx)
        }
        let mono = Draw.mono(TS.inboxDiffFont)
        let m = l.kind == .add ? "+" : l.kind == .del ? "−" : ""
        if !m.isEmpty { RV.text(m, mono, mark, x: nw * 2 + (TS.inboxDiffMarkW - RV.width(m, mono)) / 2, top: r.minY, lineHeight: lineH, in: ctx) }
        var line = CTLineCreateWithAttributedString(Highlight.attributed(l.text, mono, ink: ink, deleted: l.kind == .del))
        line = Draw.truncated(line, r.width - textX - TS.inboxDiffTextPadr, mono, ink)
        Draw.text(line, font: mono, x: textX, top: r.minY, lineHeight: lineH, in: ctx)
    }

    /// `repeating-linear-gradient(135deg, transparent 0 5px, white .018 5px 6px)` on removed lines.
    private func hatch(_ r: NSRect, ctx: CGContext) {
        let p = TS.inboxDiffHatchPeriod
        let step = p[1] * 2.squareRoot(), w = (p[1] - p[0])
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setStrokeColor(NSColor(white: 1, alpha: TS.inboxDiffHatchAlpha).cgColor)
        ctx.setLineWidth(w)
        var x = r.minX - r.height
        while x < r.maxX {
            ctx.move(to: CGPoint(x: x, y: r.maxY))
            ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += step
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        guard let s = state else { return }
        let p = convert(event.locationInWindow, from: nil)
        for case let (.header(fi), r) in items where r.contains(p) && fi == s.selectedFile {
            if viewedRect(r).insetBy(dx: -4, dy: -6).contains(p) { onToggleViewed?(fi) }
        }
    }
}

extension Highlight {
    static func attributed(_ s: String, _ font: NSFont, ink: NSColor, deleted: Bool) -> NSAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: ink])
        for (r, k) in spans(s) {
            switch k {
            case .plain: break
            case .keyword: a.addAttribute(.foregroundColor, value: deleted ? Tok.Color.inboxDiffDelMark : Tok.Color.inboxDiffKw, range: r)
            case .string: a.addAttribute(.foregroundColor, value: deleted ? Tok.Color.inboxDiffDelInk : Tok.Color.inboxDiffStr, range: r)
            case .comment:
                a.addAttributes([.foregroundColor: Tok.Color.inboxDiffCm,
                                 .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)], range: r)
            }
        }
        return a
    }
}
