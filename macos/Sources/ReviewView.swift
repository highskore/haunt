import AppKit

/// The review screen's sizes are all tokens; the short name keeps layout code readable.
private typealias TS = Tok.Size

/// Drawing shared by the review screen's panes, laid out like haunt-review/index.html's CSS.
enum RV {
    static let lh = Tok.Font.baseLine
    static var mono12: NSFont { Draw.mono(TS.reviewDiffFont) }

    /// Snaps a CSS edge to a device pixel the way Blink paints box edges at 2x.
    static func px(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }

    @discardableResult
    static func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, top: CGFloat, lineHeight: CGFloat? = nil,
                     maxWidth: CGFloat? = nil, kern: CGFloat = 0, in ctx: CGContext) -> CGFloat {
        var line = Draw.line(s, font, color, kern: kern)
        if let m = maxWidth { line = Draw.truncated(line, m, font, color) }
        Draw.text(line, font: font, x: x, top: top, lineHeight: lineHeight ?? font.pointSize * lh, in: ctx)
        return Draw.width(line)
    }

    static func width(_ s: String, _ font: NSFont, kern: CGFloat = 0) -> CGFloat { Draw.width(Draw.line(s, font, .white, kern: kern)) }

    /// `.sec`/`.label`: 10 pt uppercase, tracked .08em, muted.
    @discardableResult
    static func label(_ s: String, x: CGFloat, top: CGFloat, in ctx: CGContext) -> CGFloat {
        text(s.uppercased(), Draw.ui(TS.reviewSecFont), Tok.Color.textLabel, x: x, top: top,
             kern: TS.reviewSecFont * TS.reviewSecTrackingEm, in: ctx)
    }

    static func stat(_ add: Int, _ del: Int) -> String { "+\(add)" + (del > 0 ? " −\(del)" : "") }

    /// `.sq`: five squares split between additions and deletions.
    static func squares(_ add: Int, _ del: Int, x: CGFloat, midY: CGFloat) {
        let t = add + del
        let nd = del > 0 ? max(1, Int((5 * Double(del) / Double(t)).rounded())) : 0
        let s = TS.reviewSqSize
        for i in 0..<5 {
            let r = NSRect(x: x + CGFloat(i) * (s + TS.reviewSqGap), y: px(midY - s / 2), width: s, height: s)
            Draw.fill(r, i < 5 - nd ? Tok.Color.diffSqAdd : Tok.Color.reviewMarkOff)
        }
    }

    static var squaresWidth: CGFloat { 5 * TS.reviewSqSize + 4 * TS.reviewSqGap }

    /// `.chk`: a 12 pt box, filled with a tick when on.
    static func checkbox(_ r: NSRect, on: Bool, in ctx: CGContext) {
        let rad = TS.reviewChkRadius
        if on {
            Tok.Color.textPrimary.setFill()
            NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
            let f = Draw.ui(TS.reviewChkFont)
            let w = width("✓", f)
            text("✓", f, Tok.Color.windowBg, x: r.midX - w / 2, top: r.minY, lineHeight: r.height, in: ctx)
        } else {
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: rad - 0.5, yRadius: rad - 0.5)
            p.lineWidth = 1
            Tok.Color.reviewMarkOff.setStroke()
            p.stroke()
        }
    }

    static func rounded(_ r: NSRect, radius: CGFloat, fill: NSColor?, stroke: NSColor?) {
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }
        if let stroke {
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            p.lineWidth = 1
            stroke.setStroke()
            p.stroke()
        }
    }

    static func agentMark(_ agent: Agent, in r: NSRect, ctx: CGContext) {
        if agent == .codex { Draw.codexMark(in: r, color: Tok.Color.textPrimary, ctx: ctx) } else { Draw.claudeMark(in: r) }
    }

    static func agentName(_ agent: Agent) -> String {
        switch agent {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case let .other(id): return id
        }
    }

    static func clock(_ ms: UInt64) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func duration(_ ms: UInt64) -> String {
        let s = Int(ms / 1000)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h\(String(format: "%02d", s % 3600 / 60))m"
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// Body text in a wrapped CSS line box: `size`/`line` with the given colour.
    static func para(_ s: String, _ font: NSFont, _ color: NSColor, lineHeight: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        let off = (lineHeight - (font.ascender - font.descender)) / 2
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p, .baselineOffset: off])
    }

    /// String drawing shrinks the line box by twice a baseline offset (text views don't), so drawn
    /// paragraphs drop the offset and move up by it instead.
    private static func unshifted(_ s: NSAttributedString) -> (NSAttributedString, CGFloat) {
        guard s.length > 0, let off = s.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? CGFloat else { return (s, 0) }
        let m = NSMutableAttributedString(attributedString: s)
        m.removeAttribute(.baselineOffset, range: NSRange(location: 0, length: m.length))
        return (m, off)
    }

    static func height(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(unshifted(s).0.boundingRect(with: NSSize(width: width, height: 1e6), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    static func draw(_ s: NSAttributedString, in r: NSRect) {
        let (p, off) = unshifted(s)
        p.draw(with: r.offsetBy(dx: 0, dy: -off), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

/// `.btn` and `.btn.pri`: label, then an optional muted shortcut.
final class RVButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    var key: String?
    var primary: Bool
    /// Fills its frame with the label centred (`justify-content:center`), else sized to fit.
    var centred = false
    var action: (() -> Void)?

    init(_ title: String, key: String? = nil, primary: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.key = key
        self.primary = primary
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// `font: 12px` resets line-height to normal: the font's own ascent, descent and leading.
    private static var lineH: CGFloat {
        let f = Draw.ui(TS.reviewBtnFont)
        return (f.ascender - f.descender + f.leading).rounded()
    }
    static var height: CGFloat { TS.reviewBtnPad[0] * 2 + lineH + 2 }
    /// A `.kbd` inside makes the line box 17 pt.
    static var keyedHeight: CGFloat { TS.reviewBtnPad[0] * 2 + max(lineH, TS.kbdLine) + 2 }
    var height: CGFloat { key == nil ? Self.height : Self.keyedHeight }

    private var font: NSFont { Draw.ui(TS.reviewBtnFont) }
    private var keyFont: NSFont { Draw.ui(TS.kbdFont) }

    private var contentWidth: CGFloat {
        RV.width(title, font) + (key.map { TS.reviewBtnGap + RV.width($0, keyFont) } ?? 0)
    }

    var fittingWidth: CGFloat { contentWidth + TS.reviewBtnPad[1] * 2 + 2 }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        RV.rounded(bounds, radius: TS.reviewBtnRadius, fill: primary ? Tok.Color.btnPrimaryBg : nil,
                   stroke: primary ? Tok.Color.btnPrimaryBg : Tok.Color.kbdBorder)
        var x = centred ? (bounds.width - contentWidth) / 2 : 1 + TS.reviewBtnPad[1]
        let lineH = Self.lineH, top = (bounds.height - lineH) / 2
        x += RV.text(title, font, primary ? Tok.Color.btnPrimaryFg : Tok.Color.btnFg, x: x, top: top, lineHeight: lineH, in: ctx)
        if let key {
            // `.btn .kbd` and `.btn.pri .kbd`: borderless, muted (#555 on the light button).
            let color = primary ? Tok.Color.reviewMarkOff : Tok.Color.textLabel
            RV.text(key, keyFont, color, x: x + TS.reviewBtnGap, top: top + (lineH - TS.kbdLine) / 2, lineHeight: TS.kbdLine, in: ctx)
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

/// A plain-text editor with the mockup's placeholder, transparent over its box.
final class RVTextView: NSTextView {
    var placeholder = ""
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onChange: (() -> Void)?

    static func make(font: NSFont, color: NSColor, lineHeight: CGFloat) -> RVTextView {
        let tv = RVTextView(frame: .zero)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.insertionPointColor = Tok.Color.textPrimary
        tv.font = font
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        tv.defaultParagraphStyle = p
        tv.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: p,
                               .baselineOffset: (lineHeight - (font.ascender - font.descender)) / 2]
        tv.textColor = color
        return tv
    }

    override var isFlipped: Bool { true }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 36 || event.keyCode == 76, mods == .command, let f = onCommandReturn { return f() }
        if event.keyCode == 53, let f = onEscape { return f() }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let ctx = NSGraphicsContext.current?.cgContext, let font else { return }
        let lineH = (defaultParagraphStyle?.minimumLineHeight).flatMap { $0 > 0 ? $0 : nil } ?? font.pointSize * RV.lh
        RV.text(placeholder, font, Tok.Color.textPlaceholder, x: 0, top: 0, lineHeight: lineH, in: ctx)
    }
}

/// The review screen: Files (01), Send back (06) and Overview (09) over the selected tab's latest turn.
final class ReviewView: NSView {
    private(set) var state: ReviewState
    var onClose: (() -> Void)?
    var onApprove: (() -> Void)?
    /// (prompt, keep reviewing).
    var onSend: ((String, Bool) -> Void)?
    var onModeChange: (() -> Void)?
    /// The tab's name as the sidebar shows it.
    var crumbName: String?

    private var pane: NSView?
    private var files: FilesPane? { pane as? FilesPane }
    private var send: SendPane? { pane as? SendPane }

    init(state: ReviewState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Tok.Color.windowBg.cgColor
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func replace(_ s: ReviewState) {
        state = s
        reload()
    }

    /// Rebuilds the pane for the current mode, keeping an open note editor's place.
    func reload(editing: Int? = nil) {
        pane?.removeFromSuperview()
        let p: NSView
        switch state.mode {
        case .files: p = FilesPane(review: self)
        case .sendBack: p = SendPane(review: self)
        case .overview: p = OverviewPane(review: self)
        }
        pane = p
        addSubview(p)
        p.frame = bounds
        p.autoresizingMask = [.width, .height]
        if let editing {
            p.layoutSubtreeIfNeeded()
            (p as? DiffHost)?.diff.edit(comment: editing)
        }
        if window?.firstResponder == nil || !(window?.firstResponder is NSTextView) { window?.makeFirstResponder(self) }
    }

    func setMode(_ m: ReviewState.Mode) {
        guard m != state.mode else { return }
        state.mode = m
        reload()
        window?.makeFirstResponder(self)
        onModeChange?()
    }

    /// Diff data arrived or changed under the open pane.
    func dataChanged() {
        reload()
        onModeChange?()
    }

    func approve() {
        state.approved = true
        onApprove?()
        pane?.needsDisplay = true
        pane?.subviews.forEach { $0.needsDisplay = true }
        files?.refresh()
    }

    func requestChanges() { setMode(.sendBack) }

    func sendDraft(keepReviewing: Bool) {
        let text = send?.draftText ?? state.draft
        onSend?(text, keepReviewing)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let enter = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53 { return onClose?() ?? () }
        if enter, mods == .command {
            switch state.mode {
            case .files: return approve()
            case .overview: return (pane as? OverviewPane)?.submit() ?? ()
            case .sendBack: return
            }
        }
        if enter, mods == [.command, .shift], state.mode == .files { return requestChanges() }
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "s", state.mode == .sendBack {
            return sendDraft(keepReviewing: false)
        }
        guard mods.isEmpty || mods == .shift, let c = event.charactersIgnoringModifiers?.lowercased() else {
            return super.keyDown(with: event)
        }
        switch c {
        case "1": setMode(.overview)
        case "2": setMode(.files)
        case "j": files?.step(1)
        case "k": files?.step(-1)
        case "n": (pane as? DiffHost)?.diff.stepHunk(1)
        case "p": (pane as? DiffHost)?.diff.stepHunk(-1)
        case "v": files?.toggleViewed(state.selectedFile)
        case "c": (pane as? DiffHost)?.diff.commentOnSelection()
        default: super.keyDown(with: event)
        }
    }
}

protocol DiffHost: AnyObject {
    var diff: DiffDocView { get }
}

// MARK: Files (version 01)

/// 01: file tree with viewed boxes, the selected file's unified diff, and Approve / Request changes.
final class FilesPane: NSView, DiffHost {
    private unowned let review: ReviewView
    private var state: ReviewState { review.state }
    private let tree = TreeView()
    private let header = FileHeaderView()
    private let scroll = NSScrollView()
    let diff: DiffDocView
    private let bar = NSView()
    private let barLabel = LabelView()
    private let requestBtn: RVButton
    private let approveBtn: RVButton

    init(review: ReviewView) {
        self.review = review
        diff = DiffDocView(review: review, inlineHeaders: false)
        requestBtn = RVButton("Request changes", key: "⌘⇧↵")
        approveBtn = RVButton("Approve", key: "⌘↵", primary: true)
        super.init(frame: .zero)
        tree.state = review.state
        tree.onSelect = { [weak self] i in self?.select(i) }
        tree.onToggle = { [weak self] i in self?.toggleViewed(i) }
        header.onToggle = { [weak self] in
            guard let self else { return }
            self.toggleViewed(self.state.selectedFile)
        }
        scroll.documentView = diff
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        diff.onCommentsChanged = { [weak self] in self?.refresh() }
        requestBtn.action = { [weak review] in review?.requestChanges() }
        approveBtn.action = { [weak review] in review?.approve() }
        for v in [tree, header, scroll, bar, barLabel, requestBtn, approveBtn] as [NSView] { addSubview(v) }
        bar.wantsLayer = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let tw = TS.reviewTreeW
        tree.frame = NSRect(x: 0, y: 0, width: tw, height: h)
        header.frame = NSRect(x: tw, y: 0, width: w - tw, height: TS.reviewFhH)
        let barH = TS.reviewBarH
        scroll.frame = NSRect(x: tw, y: TS.reviewFhH, width: w - tw, height: h - TS.reviewFhH - barH)
        diff.width = w - tw
        bar.frame = NSRect(x: tw, y: h - barH, width: w - tw, height: barH)
        barLabel.frame = NSRect(x: tw + TS.reviewBarPadx, y: h - barH + 1, width: 300, height: barH - 1)
        var x = w - TS.reviewBarPadx
        for b in [approveBtn, requestBtn] {
            let bw = b.fittingWidth, bh = b.height
            x -= bw
            b.frame = NSRect(x: x, y: h - barH + 1 + (barH - 1 - bh) / 2, width: bw, height: bh)
            x -= TS.reviewBarGap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(NSRect(x: TS.reviewTreeW, y: bounds.height - TS.reviewBarH, width: bounds.width, height: 1), Tok.Color.hairline)
    }

    func refresh() {
        let files = state.files
        let i = min(state.selectedFile, max(files.count - 1, 0))
        header.file = files.indices.contains(i) ? files[i] : nil
        header.extra = .viewed(files.indices.contains(i) && state.viewed.contains(files[i].path))
        header.commentCount = files.indices.contains(i) ? state.comments(in: files[i].path).count : 0
        let viewed = files.filter { state.viewed.contains($0.path) }.count
        let label = files.isEmpty ? "" : "\(viewed) of \(files.count) viewed"
        barLabel.text = state.approved ? "Approved · " + label : label
        approveBtn.title = state.approved ? "Approved" : "Approve"
        tree.needsDisplay = true
        diff.files = files.indices.contains(i) ? [i] : []
        diff.message = state.loadError ?? (state.diff == nil ? "Reading the diff…" : files.isEmpty ? "No changes against \(state.diff?.baseNote ?? "HEAD")." : nil)
        diff.rebuild()
        needsLayout = true
    }

    func select(_ i: Int) {
        guard state.files.indices.contains(i) else { return }
        state.selectedFile = i
        diff.selected = nil
        refresh()
        diff.scroll(.zero)
    }

    func step(_ d: Int) {
        let order = state.tree.fileOrder
        guard let at = order.firstIndex(of: state.selectedFile) ?? order.first.map({ _ in 0 }) else { return }
        select(order[min(max(at + d, 0), order.count - 1)])
    }

    func toggleViewed(_ i: Int) {
        guard state.files.indices.contains(i) else { return }
        let p = state.files[i].path
        if state.viewed.contains(p) { state.viewed.remove(p) } else { state.viewed.insert(p) }
        refresh()
    }
}

/// A single muted line of 12 pt text, vertically centred (the action bar's "1 of 5 viewed").
final class LabelView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lineH = TS.reviewRowFont * RV.lh
        RV.text(text, Draw.ui(TS.reviewRowFont), Tok.Color.textLabel, x: 0, top: (bounds.height - lineH) / 2, lineHeight: lineH, in: ctx)
    }
}

/// 01's middle column: "5 files", the tree, and the turn in a footer.
final class TreeView: NSView {
    var state: ReviewState?
    var onSelect: ((Int) -> Void)?
    var onToggle: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    private var rowH: CGFloat { TS.reviewRowPad[0] * 2 + TS.reviewFnFont * RV.lh }
    private var labelH: CGFloat { TS.labelPad[0] + TS.labelFont * RV.lh + TS.labelPad[2] }

    private func rowTop(_ i: Int) -> CGFloat { labelH + CGFloat(i) * rowH }

    private func indent(_ depth: Int) -> CGFloat { TS.reviewRowPad[1] + CGFloat(depth) * TS.reviewTreeIndent }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let state else { return }
        let w = bounds.width - 1
        Draw.fill(NSRect(x: w, y: 0, width: 1, height: bounds.height), Tok.Color.hairline)
        let files = state.files
        // `.label` with the totals on the right, untracked and untransformed.
        RV.label(RV.plural(files.count, "file"), x: TS.labelPad[1], top: TS.labelPad[0], in: ctx)
        let (a, d) = state.totals
        let tot = "+\(a) −\(d)", lf = Draw.ui(TS.labelFont)
        RV.text(tot, lf, Tok.Color.textLabel, x: w - TS.labelPad[1] - RV.width(tot, lf), top: TS.labelPad[0], in: ctx)

        let fnFont = Draw.mono(TS.reviewFnFont), stFont = Draw.mono(TS.reviewStFont)
        let textH = TS.reviewFnFont * RV.lh
        for (i, item) in state.tree.items.enumerated() {
            let top = rowTop(i), x0 = indent(item.depth)
            let mid = top + rowH / 2
            if let dir = item.dir {
                let cf = Draw.ui(TS.reviewTreeCaretFont)
                let cw = RV.text("▾", cf, Tok.Color.textMeta, x: x0, top: mid - TS.reviewTreeCaretFont * RV.lh / 2, in: ctx)
                RV.text(dir, fnFont, Tok.Color.textMeta, x: x0 + cw + TS.reviewRowGap, top: mid - textH / 2, lineHeight: textH, in: ctx)
                continue
            }
            guard let fi = item.file else { continue }
            let f = files[fi]
            if fi == state.selectedFile {
                Draw.fill(NSRect(x: 0, y: RV.px(top), width: w, height: RV.px(top + rowH) - RV.px(top)), Tok.Color.rowSelected)
                Draw.fill(NSRect(x: 0, y: RV.px(top), width: 2, height: RV.px(top + rowH) - RV.px(top)), Tok.Color.textPrimary)
            }
            let s = TS.reviewChkSize
            RV.checkbox(NSRect(x: x0, y: RV.px(mid - s / 2), width: s, height: s), on: state.viewed.contains(f.path), in: ctx)
            let st = (f.hiddenChars ? "hidden · " : "") + (f.special ? "special" : RV.stat(f.additions, f.deletions))
            let stW = RV.width(st, stFont)
            RV.text(st, stFont, Tok.Color.textSub, x: w - TS.reviewRowPad[1] - stW, top: mid - TS.reviewStFont * RV.lh / 2, in: ctx)
            let nx = x0 + s + TS.reviewRowGap
            RV.text(f.name, fnFont, Tok.Color.textPrimary, x: nx, top: mid - textH / 2, lineHeight: textH,
                    maxWidth: w - TS.reviewRowPad[1] - stW - TS.reviewRowGap - nx, in: ctx)
        }

        // The turn: when, how much, and the last check it ran.
        let lines = footerLines(state)
        guard !lines.isEmpty else { return }
        let ff = Draw.ui(TS.reviewTreeFootFont), fl = TS.reviewTreeFootFont * RV.lh
        let fh = 1 + TS.reviewTreeFootPad[0] * 2 + CGFloat(lines.count) * fl + CGFloat(lines.count - 1) * TS.reviewTreeFootGap
        let top = bounds.height - fh
        Draw.fill(NSRect(x: 0, y: RV.px(top), width: w, height: 1), Tok.Color.hairline)
        for (i, l) in lines.enumerated() {
            RV.text(l, ff, i == 0 ? Tok.Color.textSub : Tok.Color.textLabel, x: TS.reviewTreeFootPad[1],
                    top: top + 1 + TS.reviewTreeFootPad[0] + CGFloat(i) * (fl + TS.reviewTreeFootGap), lineHeight: fl,
                    maxWidth: w - TS.reviewTreeFootPad[1] * 2, in: ctx)
        }
    }

    private func footerLines(_ s: ReviewState) -> [String] {
        guard let t = s.turn, t.number > 0 else { return [] }
        var when = "Turn \(t.number)"
        if let a = t.startedMs { when += " · \(RV.clock(a))" + (t.finishedMs.map { " → \(RV.clock($0))" } ?? " → now") }
        var counts = [RV.plural(Int(t.toolCount), "tool")]
        if !t.subagents.isEmpty { counts.append(RV.plural(t.subagents.count, "subagent")) }
        if let a = t.startedMs, let b = t.finishedMs, b >= a { counts.append(RV.duration(b - a)) }
        var out = [when, counts.joined(separator: " · ")]
        if let c = s.checks.last(where: { $0.state != .notRun }) { out.append("\(c.command) · \(c.result)") }
        return out
    }

    override func mouseDown(with event: NSEvent) {
        guard let state else { return }
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(floor((p.y - labelH) / rowH))
        let items = state.tree.items
        guard p.y >= labelH, items.indices.contains(i), let fi = items[i].file else { return }
        let x0 = indent(items[i].depth)
        if p.x >= x0 - 4, p.x <= x0 + TS.reviewChkSize + 4 { onToggle?(fi) } else { onSelect?(fi) }
    }
}

/// `.fh`: the file's path (folder muted), "new", its stat and squares, and Viewed or the comment count.
final class FileHeaderView: NSView {
    enum Extra: Equatable { case viewed(Bool), comments }
    var file: FileDiff? { didSet { needsDisplay = true } }
    var extra: Extra = .viewed(false) { didSet { needsDisplay = true } }
    var commentCount = 0
    var onToggle: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let file else { return }
        FileHeaderView.draw(file, extra: extra, comments: commentCount, in: bounds, topBorder: false, ctx: ctx)
    }

    /// Where the Viewed box sits, for clicks.
    static func viewedRect(in r: NSRect, topBorder: Bool) -> NSRect {
        let f = Draw.ui(TS.reviewNoteHeadFont)
        let w = RV.width("Viewed", f)
        let mid = r.minY + (topBorder ? 1 : 0) + (r.height - 1 - (topBorder ? 1 : 0)) / 2
        let s = TS.reviewChkSize
        return NSRect(x: r.maxX - TS.reviewFhPadx - w - TS.reviewFhGap - s, y: RV.px(mid - s / 2), width: s + TS.reviewFhGap + w, height: s)
    }

    static func draw(_ f: FileDiff, extra: Extra, comments: Int, in r: NSRect, topBorder: Bool, ctx: CGContext) {
        Draw.fill(r, Tok.Color.windowBg)
        if topBorder { Draw.fill(NSRect(x: r.minX, y: r.minY, width: r.width, height: 1), Tok.Color.hairline) }
        Draw.fill(NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), Tok.Color.hairline)
        let mid = r.minY + (topBorder ? 1 : 0) + (r.height - 1 - (topBorder ? 1 : 0)) / 2
        let pf = Draw.mono(TS.reviewFhFont), pl = TS.reviewFhFont * RV.lh
        var x = r.minX + TS.reviewFhPadx
        let right: CGFloat
        let small = Draw.ui(TS.reviewNoteHeadFont), sl = TS.reviewNoteHeadFont * RV.lh
        switch extra {
        case let .viewed(on):
            let vr = viewedRect(in: r, topBorder: topBorder)
            RV.checkbox(NSRect(x: vr.minX, y: vr.minY, width: TS.reviewChkSize, height: TS.reviewChkSize), on: on, in: ctx)
            RV.text("Viewed", small, Tok.Color.textLabel, x: vr.minX + TS.reviewChkSize + TS.reviewFhGap, top: mid - sl / 2, lineHeight: sl, in: ctx)
            right = vr.minX - TS.reviewFhGap
        case .comments:
            let t = RV.plural(comments, "comment")
            let w = RV.width(t, small)
            RV.text(t, small, Tok.Color.textLabel, x: r.maxX - TS.reviewFhPadx - w, top: mid - sl / 2, lineHeight: sl, in: ctx)
            right = r.maxX - TS.reviewFhPadx - w - TS.reviewFhGap
        }
        let tags = (f.status == .added ? ["new"] : []) + (f.hiddenChars ? ["hidden chars"] : [])
        let tagW: CGFloat = tags.reduce(0) { $0 + RV.width($1, Draw.ui(TS.reviewTagFont), kern: TS.reviewTagFont * TS.reviewTagTrackingEm) + TS.reviewTagPad[1] * 2 + 2 + TS.reviewFhGap }
        let st = f.special ? "special" : f.binary ? "binary" : RV.stat(f.additions, f.deletions)
        let stF = Draw.mono(TS.reviewStFont)
        let tail = tagW + RV.width(st, stF) + TS.reviewFhGap + (f.binary || f.special ? 0 : RV.squaresWidth + TS.reviewFhGap)
        let room = max(right - x - tail, 40)
        let dirW = min(RV.width(f.dir, pf), max(room - RV.width(f.name, pf), 0))
        if dirW > 0 { x += RV.text(f.dir, pf, Tok.Color.textLabel, x: x, top: mid - pl / 2, lineHeight: pl, maxWidth: dirW, in: ctx) }
        x += RV.text(f.name, pf, Tok.Color.textPrimary, x: x, top: mid - pl / 2, lineHeight: pl, maxWidth: room - dirW, in: ctx)
        x += TS.reviewFhGap
        for tag in tags {
            let tf = Draw.ui(TS.reviewTagFont), kern = TS.reviewTagFont * TS.reviewTagTrackingEm
            let tw = RV.width(tag, tf, kern: kern) + TS.reviewTagPad[1] * 2 + 2
            let tr = NSRect(x: x, y: RV.px(mid - (TS.reviewTagLine + 2) / 2), width: tw, height: TS.reviewTagLine + 2)
            RV.rounded(tr, radius: TS.reviewTagRadius, fill: nil, stroke: Tok.Color.kbdBorder)
            RV.text(tag, tf, Tok.Color.textSub, x: x + 1 + TS.reviewTagPad[1], top: tr.minY + 1, lineHeight: TS.reviewTagLine, kern: kern, in: ctx)
            x += tw + TS.reviewFhGap
        }
        x += RV.text(st, stF, Tok.Color.textSub, x: x, top: mid - TS.reviewStFont * RV.lh / 2, in: ctx) + TS.reviewFhGap
        if !f.binary, !f.special { RV.squares(f.additions, f.deletions, x: x, midY: mid) }
    }

    override func mouseDown(with event: NSEvent) {
        guard case .viewed = extra else { return }
        if FileHeaderView.viewedRect(in: bounds, topBorder: false).insetBy(dx: -4, dy: -6).contains(convert(event.locationInWindow, from: nil)) {
            onToggle?()
        }
    }
}

// MARK: The diff

/// Unified monochrome diff of some files, with notes under commented lines and the note editor.
final class DiffDocView: NSView {
    private unowned let review: ReviewView
    private var state: ReviewState { review.state }
    /// 06 shows each file's header in the scroll with only its commented hunks; 01 one file under a fixed header.
    let inlineHeaders: Bool
    var files: [Int] = []
    var message: String?
    var width: CGFloat = 0 { didSet { if width != oldValue { rebuild() } } }
    var onCommentsChanged: (() -> Void)?

    struct LineRef: Equatable { var file: Int, hunk: Int, line: Int }
    var selected: LineRef? { didSet { needsDisplay = true } }

    private enum Item {
        case header(file: Int, top: Bool)
        case hunk(file: Int, hunk: Int)
        case line(LineRef)
        case note(comment: Int)
        case editor
        case dropped(Int)
        case binary
        case notice(String)
    }

    private var items: [(Item, NSRect)] = []
    private var editor: NoteEditor?
    private var editingAt: LineRef?

    init(review: ReviewView, inlineHeaders: Bool) {
        self.review = review
        self.inlineHeaders = inlineHeaders
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var lineH: CGFloat { TS.reviewDiffFont * TS.reviewDiffLine }
    private var hunkH: CGFloat { TS.reviewHunkPad[0] + TS.reviewHunkPad[2] + TS.reviewHunkFont * TS.reviewHunkLine + 2 }

    private func line(_ r: LineRef) -> DiffLine { state.files[r.file].hunks[r.hunk].lines[r.line] }

    private func commentIndex(at r: LineRef) -> [Int] {
        let f = state.files[r.file], l = line(r)
        return state.comments.indices.filter { i in
            let c = state.comments[i]
            guard c.path == f.path else { return false }
            return c.deleted ? (l.kind == .del && l.old == c.line) : (l.kind != .del && l.new == c.line)
        }
    }

    private func hunkHasComment(_ file: Int, _ h: Int) -> Bool {
        state.files[file].hunks[h].lines.indices.contains { !commentIndex(at: LineRef(file: file, hunk: h, line: $0)).isEmpty }
    }

    private var noteWidth: CGFloat { width - TS.reviewNoteMargin[1] - TS.reviewNoteMargin[3] }

    private func noteBody(_ text: String) -> NSAttributedString {
        RV.para(text, Draw.ui(TS.reviewNoteFont), Tok.Color.textPrimary, lineHeight: TS.reviewNoteFont * TS.reviewNoteLine)
    }

    private var noteHeadH: CGFloat { TS.reviewNoteHeadPad[0] + TS.reviewNoteHeadFont * RV.lh }

    private func noteHeight(_ text: String) -> CGFloat {
        let bodyW = noteWidth - 2 - TS.reviewNoteBodyPad[1] * 2
        let body = max(RV.height(noteBody(text), width: bodyW), TS.reviewNoteFont * TS.reviewNoteLine)
        return 2 + noteHeadH + TS.reviewNoteBodyPad[0] + body + TS.reviewNoteBodyPad[2]
    }

    func rebuild() {
        items = []
        var y: CGFloat = 0
        func add(_ i: Item, _ h: CGFloat) {
            items.append((i, NSRect(x: 0, y: y, width: width, height: h)))
            y += h
        }
        // What git couldn't do, said where the diff is read.
        if !inlineHeaders { for n in state.diff?.notes ?? [] { add(.notice(n), hunkH) } }
        for (n, fi) in files.enumerated() where state.files.indices.contains(fi) {
            let f = state.files[fi]
            if inlineHeaders {
                if n > 0 { y += TS.reviewFhMt }
                add(.header(file: fi, top: n > 0), TS.reviewFhH)
            }
            if f.binary || f.special || f.hunks.isEmpty, f.droppedLines == 0 {
                add(f.special ? .notice("Special file (not a regular file or link), not shown") : .binary, hunkH)
                continue
            }
            for (hi, h) in f.hunks.enumerated() {
                if inlineHeaders, !hunkHasComment(fi, hi) { continue }
                add(.hunk(file: fi, hunk: hi), hunkH)
                for li in h.lines.indices {
                    let ref = LineRef(file: fi, hunk: hi, line: li)
                    add(.line(ref), lineH)
                    for ci in commentIndex(at: ref) where ci != editor?.comment {
                        y += TS.reviewNoteMargin[0]
                        add(.note(comment: ci), noteHeight(state.comments[ci].text))
                        y += TS.reviewNoteMargin[2]
                    }
                    if editingAt == ref, let editor {
                        y += TS.reviewNoteMargin[0]
                        add(.editor, editor.height(width: noteWidth))
                        y += TS.reviewNoteMargin[2]
                    }
                }
            }
            if f.droppedLines > 0 { add(.dropped(f.droppedLines), hunkH) }
        }
        let visible = enclosingScrollView?.contentSize.height ?? 0
        frame = NSRect(x: 0, y: 0, width: width, height: max(y, visible))
        if let editor, let r = items.first(where: { if case .editor = $0.0 { return true } else { return false } })?.1 {
            editor.frame = NSRect(x: TS.reviewNoteMargin[3], y: r.minY, width: noteWidth, height: r.height)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(dirtyRect, Tok.Color.windowBg)
        if let message {
            RV.text(message, Draw.ui(TS.reviewRowFont), Tok.Color.textLabel, x: TS.reviewFhPadx, top: TS.reviewFhPadx, in: ctx)
            return
        }
        let mono = RV.mono12, hf = Draw.mono(TS.reviewHunkFont)
        let numW = TS.reviewDiffNumW, markW = TS.reviewDiffMarkW
        for (item, r) in items where r.intersects(dirtyRect) {
            switch item {
            case let .header(fi, top):
                FileHeaderView.draw(state.files[fi], extra: .comments, comments: state.comments(in: state.files[fi].path).count,
                                    in: r, topBorder: top, ctx: ctx)
            case let .hunk(fi, hi):
                drawBand(r, ctx)
                let hl = TS.reviewHunkFont * TS.reviewHunkLine
                RV.text(state.files[fi].hunks[hi].header, hf, Tok.Color.diffAddNum, x: TS.reviewHunkPad[3], top: r.minY + 1 + TS.reviewHunkPad[0],
                        lineHeight: hl, maxWidth: r.width - TS.reviewHunkPad[3], in: ctx)
            case .binary, .dropped, .notice:
                drawBand(r, ctx)
                let text: String
                switch item {
                case let .dropped(n): text = "\(n) more lines not shown"
                case let .notice(t): text = t
                default: text = "Binary file, not shown"
                }
                RV.text(text, hf, Tok.Color.diffAddNum, x: TS.reviewHunkPad[3], top: r.minY + 1 + TS.reviewHunkPad[0],
                        lineHeight: TS.reviewHunkFont * TS.reviewHunkLine, in: ctx)
            case let .line(ref):
                let l = line(ref)
                let rr = NSRect(x: 0, y: RV.px(r.minY), width: r.width, height: RV.px(r.maxY) - RV.px(r.minY))
                let (bg, ink, mark, num): (NSColor?, NSColor, NSColor, NSColor) = switch l.kind {
                case .add: (Tok.Color.diffAddBg, Tok.Color.diffAddInk, Tok.Color.diffAddMark, Tok.Color.diffAddNum)
                case .del: (Tok.Color.diffDelBg, Tok.Color.diffDelInk, Tok.Color.diffDelInk, Tok.Color.diffNum)
                case .context: (nil, Tok.Color.diffText, Tok.Color.diffMark, Tok.Color.diffNum)
                }
                if let bg { Draw.fill(rr, bg) }
                let pr = TS.reviewDiffNumPadr
                for (n, x) in [(l.old, numW), (l.new, numW * 2)] {
                    guard let n else { continue }
                    let s = String(n)
                    RV.text(s, mono, num, x: x - pr - RV.width(s, mono), top: r.minY, lineHeight: lineH, in: ctx)
                }
                let m = l.kind == .add ? "+" : l.kind == .del ? "−" : ""
                if !m.isEmpty { RV.text(m, mono, mark, x: numW * 2 + (markW - RV.width(m, mono)) / 2, top: r.minY, lineHeight: lineH, in: ctx) }
                RV.text(l.text, mono, ink, x: numW * 2 + markW, top: r.minY, lineHeight: lineH, in: ctx)
                let commented = inlineHeaders && !commentIndex(at: ref).isEmpty
                if ref == selected || commented || ref == editingAt {
                    let p = NSBezierPath(rect: rr.insetBy(dx: 0.5, dy: 0.5))
                    p.lineWidth = 1
                    Tok.Color.diffSel.setStroke()
                    p.stroke()
                }
            case let .note(ci):
                drawNote(state.comments[ci], in: NSRect(x: TS.reviewNoteMargin[3], y: r.minY, width: noteWidth, height: r.height), ctx: ctx)
            case .editor:
                break
            }
        }
    }

    private func drawBand(_ r: NSRect, _ ctx: CGContext) {
        Draw.fill(r, Tok.Color.diffHunkBg)
        Draw.fill(NSRect(x: r.minX, y: r.minY, width: r.width, height: 1), Tok.Color.diffRule)
        Draw.fill(NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), Tok.Color.diffRule)
    }

    private func drawNote(_ c: ReviewComment, in r: NSRect, ctx: CGContext) {
        RV.rounded(r, radius: TS.reviewNoteRadius, fill: Tok.Color.reviewNoteBg, stroke: Tok.Color.reviewNoteBorder)
        NoteEditor.drawHead(line: c.line, in: r, ctx: ctx)
        let bodyTop = r.minY + 1 + noteHeadH + TS.reviewNoteBodyPad[0]
        RV.draw(noteBody(c.text), in: NSRect(x: r.minX + 1 + TS.reviewNoteBodyPad[1], y: bodyTop,
                                           width: r.width - 2 - TS.reviewNoteBodyPad[1] * 2, height: r.maxY - bodyTop))
    }

    // MARK: Interaction

    private func ref(at p: NSPoint) -> LineRef? {
        for case let (.line(ref), r) in items where r.contains(p) { return ref }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(review)
        for case let (.note(ci), r) in items where r.contains(p) { return edit(comment: ci) }
        guard let r = ref(at: p) else { return }
        selected = r
        if event.clickCount == 2 { commentOnSelection() }
    }

    func commentOnSelection() {
        guard let r = selected ?? editingAt, editor == nil else { return }
        if let ci = commentIndex(at: r).first { return edit(comment: ci) }
        openEditor(at: r, comment: nil, text: "")
    }

    /// Opens the editor on an existing comment.
    func edit(comment ci: Int) {
        guard state.comments.indices.contains(ci) else { return }
        let c = state.comments[ci]
        for (item, _) in items {
            guard case let .line(r) = item, state.files[r.file].path == c.path, commentIndex(at: r).contains(ci) else { continue }
            return openEditor(at: r, comment: ci, text: c.text)
        }
        // A comment on a hunk this pane doesn't show yet.
        for (fi, f) in state.files.enumerated() where f.path == c.path {
            for (hi, h) in f.hunks.enumerated() {
                for li in h.lines.indices where commentIndex(at: LineRef(file: fi, hunk: hi, line: li)).contains(ci) {
                    return openEditor(at: LineRef(file: fi, hunk: hi, line: li), comment: ci, text: c.text)
                }
            }
        }
    }

    private func openEditor(at r: LineRef, comment: Int?, text: String) {
        closeEditor()
        let l = line(r)
        let e = NoteEditor(line: (l.kind == .del ? l.old : l.new) ?? 0, text: text, comment: comment)
        e.onSave = { [weak self] t in self?.save(t) }
        e.onCancel = { [weak self] in self?.closeEditor() }
        e.onResize = { [weak self] in self?.rebuild() }
        editor = e
        editingAt = r
        selected = r
        addSubview(e)
        rebuild()
        window?.makeFirstResponder(e.textView)
        if let er = items.first(where: { if case .editor = $0.0 { return true } else { return false } })?.1 {
            _ = scrollToVisible(er)
        }
    }

    private func closeEditor() {
        editor?.removeFromSuperview()
        editor = nil
        editingAt = nil
        rebuild()
        window?.makeFirstResponder(review)
    }

    /// An empty save removes the comment.
    private func save(_ text: String) {
        guard let r = editingAt, let e = editor else { return }
        let f = state.files[r.file], l = line(r)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ci = e.comment {
            if t.isEmpty { state.comments.remove(at: ci) } else { state.comments[ci].text = t }
        } else if !t.isEmpty {
            let c = ReviewComment(path: f.path, line: (l.kind == .del ? l.old : l.new) ?? 0, deleted: l.kind == .del, text: t)
            state.comments.append(c)
        }
        state.editedDraft = nil
        closeEditor()
        onCommentsChanged?()
    }

    /// n/p: scrolls the next or previous hunk header to the top.
    func stepHunk(_ d: Int) {
        let tops = items.compactMap { item, r -> CGFloat? in if case .hunk = item { return r.minY } else { return nil } }
        let cur = enclosingScrollView?.contentView.bounds.minY ?? 0
        let next = d > 0 ? tops.first { $0 > cur + 1 } : tops.last { $0 < cur - 1 }
        if let y = next { scroll(NSPoint(x: 0, y: y)) }
    }
}

/// `.note` being written: "L You · line 14", the text, then Cancel and Save ⌘↵.
final class NoteEditor: NSView {
    let line: Int
    let comment: Int?
    let textView: RVTextView
    private let cancel = RVButton("Cancel")
    private let saveBtn = RVButton("Save", key: "⌘↵", primary: true)
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onResize: (() -> Void)?
    private var lastHeight: CGFloat = 0

    init(line: Int, text: String, comment: Int?) {
        self.line = line
        self.comment = comment
        textView = RVTextView.make(font: Draw.ui(TS.reviewNoteFont), color: Tok.Color.textPrimary, lineHeight: TS.reviewNoteFont * TS.reviewNoteLine)
        super.init(frame: .zero)
        textView.string = text
        textView.placeholder = "Comment for the agent"
        textView.onCommandReturn = { [weak self] in self?.onSave?(self?.textView.string ?? "") }
        textView.onEscape = { [weak self] in self?.onCancel?() }
        textView.onChange = { [weak self] in
            guard let self, self.height(width: self.bounds.width) != self.lastHeight else { return }
            self.onResize?()
        }
        cancel.action = { [weak self] in self?.onCancel?() }
        saveBtn.action = { [weak self] in self?.onSave?(self?.textView.string ?? "") }
        for v in [textView, cancel, saveBtn] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var headH: CGFloat { TS.reviewNoteHeadPad[0] + TS.reviewNoteHeadFont * RV.lh }
    private var footH: CGFloat { RVButton.keyedHeight + TS.reviewNoteFootPad[2] }

    private func textHeight(width: CGFloat) -> CGFloat {
        let s = RV.para(textView.string.isEmpty ? " " : textView.string, Draw.ui(TS.reviewNoteFont), .white,
                        lineHeight: TS.reviewNoteFont * TS.reviewNoteLine)
        return max(RV.height(s, width: width - 2 - TS.reviewNoteBodyPad[1] * 2), TS.reviewNoteFont * TS.reviewNoteLine)
    }

    func height(width: CGFloat) -> CGFloat {
        2 + headH + TS.reviewNoteBodyPad[0] + textHeight(width: width) + TS.reviewNoteBodyPad[2] + footH
    }

    override func layout() {
        super.layout()
        lastHeight = bounds.height
        let pad = TS.reviewNoteBodyPad
        textView.frame = NSRect(x: 1 + pad[1], y: 1 + headH + pad[0], width: bounds.width - 2 - pad[1] * 2, height: textHeight(width: bounds.width))
        var x = bounds.width - 1 - TS.reviewNoteFootPad[1]
        let y = bounds.height - 1 - TS.reviewNoteFootPad[2] - RVButton.keyedHeight
        for b in [saveBtn, cancel] {
            x -= b.fittingWidth
            b.frame = NSRect(x: x, y: y, width: b.fittingWidth, height: RVButton.keyedHeight)
            x -= TS.reviewNoteFootGap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        RV.rounded(bounds, radius: TS.reviewNoteRadius, fill: Tok.Color.reviewNoteBg, stroke: Tok.Color.diffSel)
        NoteEditor.drawHead(line: line, in: bounds, ctx: ctx)
    }

    /// `.nh`: the avatar with the user's initial, "You" and the line.
    static func drawHead(line: Int, in r: NSRect, ctx: CGContext) {
        let f = Draw.ui(TS.reviewNoteHeadFont), lineH = TS.reviewNoteHeadFont * RV.lh
        let top = r.minY + 1 + TS.reviewNoteHeadPad[0]
        let mid = top + lineH / 2
        let a = TS.reviewAvatarSize
        var x = r.minX + 1 + TS.reviewNoteHeadPad[1]
        let av = NSRect(x: x, y: RV.px(mid - a / 2), width: a, height: a)
        Tok.Color.reviewAvatarBg.setFill()
        NSBezierPath(ovalIn: av).fill()
        let af = Draw.ui(TS.reviewAvatarFont)
        let initial = String((NSFullUserName().first ?? "Y").uppercased())
        RV.text(initial, af, Tok.Color.reviewBody, x: av.midX - RV.width(initial, af) / 2, top: av.minY, lineHeight: a, in: ctx)
        x += a + TS.reviewNoteHeadGap
        x += RV.text("You", f, Tok.Color.textPrimary, x: x, top: top, lineHeight: lineH, in: ctx) + TS.reviewNoteHeadGap
        RV.text("· line \(line)", f, Tok.Color.textLabel, x: x, top: top, lineHeight: lineH, in: ctx)
    }
}

// MARK: Send back (version 06)

/// 06: the commented hunks, and the follow-up prompt they collect into, shown in full and editable.
final class SendPane: NSView, DiffHost {
    private unowned let review: ReviewView
    private var state: ReviewState { review.state }
    private let scroll = NSScrollView()
    let diff: DiffDocView
    private let panel = SendPanel()

    init(review: ReviewView) {
        self.review = review
        diff = DiffDocView(review: review, inlineHeaders: true)
        super.init(frame: .zero)
        scroll.documentView = diff
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        diff.onCommentsChanged = { [weak self] in self?.draftChanged() }
        panel.onSend = { [weak review] keep in review?.sendDraft(keepReviewing: keep) }
        panel.onEdit = { [weak self] text in self?.state.editedDraft = text }
        addSubview(scroll)
        addSubview(panel)
        refreshDiff()
        draftChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var draftText: String { panel.text }

    override func layout() {
        super.layout()
        let pw = TS.reviewSendW
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width - pw, height: bounds.height)
        diff.width = bounds.width - pw
        panel.frame = NSRect(x: bounds.width - pw, y: 0, width: pw, height: bounds.height)
    }

    private func refreshDiff() {
        let commented = Set(state.comments.map(\.path))
        diff.files = state.files.indices.filter { commented.contains(state.files[$0].path) }
        diff.message = diff.files.isEmpty ? "No comments yet. Double-click a line in Files (2) to comment on it, or write the prompt on the right." : nil
        diff.rebuild()
    }

    func draftChanged() {
        refreshDiff()
        panel.update(target: review.targetName, comments: state.comments.count, draft: state.draft, agent: state.turn?.agent ?? .claude)
    }
}

extension ReviewView {
    /// The tab's name, for "Follow-up to haunt".
    var targetName: String { crumbName ?? "the agent" }
}

/// 06's right column: "Follow-up to haunt", the draft, what sending does, and the two send buttons.
final class SendPanel: NSView {
    private let box = NSScrollView()
    private let textView: RVTextView
    private let sendBtn = RVButton("Send to agent", key: "⌘⇧S", primary: true)
    private let keepBtn = RVButton("Send and keep reviewing")
    private var target = "", count = 0, agent: Agent = .claude
    var onSend: ((Bool) -> Void)?
    var onEdit: ((String) -> Void)?

    private var lineH: CGFloat { TS.reviewDraftFont * TS.reviewDraftLine }

    override init(frame: NSRect) {
        textView = RVTextView.make(font: Draw.mono(TS.reviewDraftFont), color: Tok.Color.reviewBody, lineHeight: TS.reviewDraftFont * TS.reviewDraftLine)
        super.init(frame: frame)
        textView.onChange = { [weak self] in
            guard let self else { return }
            self.onEdit?(self.textView.string)
            self.needsLayout = true
        }
        textView.autoresizingMask = .width
        box.documentView = textView
        box.drawsBackground = false
        box.hasVerticalScroller = true
        box.autohidesScrollers = true
        box.scrollerStyle = .overlay
        sendBtn.centred = true
        keepBtn.centred = true
        sendBtn.action = { [weak self] in self?.onSend?(false) }
        keepBtn.action = { [weak self] in self?.onSend?(true) }
        for v in [box, sendBtn, keepBtn] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var text: String { textView.string }

    /// The draft styled like the mockup: its references and closing line muted, blocks 8 pt apart.
    func update(target: String, comments: Int, draft: String, agent: Agent) {
        self.target = target
        count = comments
        self.agent = agent
        let s = NSMutableAttributedString()
        let font = Draw.mono(TS.reviewDraftFont)
        let blocks = draft.components(separatedBy: "\n\n")
        for (i, b) in blocks.enumerated() {
            if i > 0 {
                // A block ends its last line, then an empty 8 pt paragraph stands in for the grid gap.
                let gap = NSMutableParagraphStyle()
                gap.minimumLineHeight = TS.reviewDraftGap
                gap.maximumLineHeight = TS.reviewDraftGap
                s.append(RV.para("\n", font, Tok.Color.reviewBody, lineHeight: lineH))
                s.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: gap]))
            }
            let lines = b.components(separatedBy: "\n")
            for (j, l) in lines.enumerated() {
                let ref = j == 0 && lines.count > 1 && l.range(of: #"^\d+\. "#, options: .regularExpression) != nil
                let closing = i == blocks.count - 1 && comments > 0 && l.hasPrefix("Keep everything else.")
                let line = RV.para(l + (j < lines.count - 1 ? "\n" : ""), font, ref || closing ? Tok.Color.textLabel : Tok.Color.reviewBody,
                                   lineHeight: lineH)
                s.append(line)
            }
        }
        textView.textStorage?.setAttributedString(s)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.placeholder = "Write what the agent should change."
        needsLayout = true
        needsDisplay = true
    }

    private var headH: CGFloat { TS.reviewSendHeadPad[0] + TS.reviewSendHeadFont * RV.lh + TS.reviewSendHeadPad[2] }
    private var footH: CGFloat { 1 + TS.reviewPanelFootPad[0] * 2 + sendBtn.height + keepBtn.height + TS.reviewPanelFootGap }

    private var boxRect: NSRect {
        let m = TS.reviewDraftMargin, pad = TS.reviewDraftPad
        let w = bounds.width - 1 - m * 2
        let used = draftHeight(width: w - 2 - pad[1] * 2)
        let maxH = bounds.height - headH - footH - hintHeight - 8
        let h = min(max(used, lineH) + pad[0] * 2 + 2, max(maxH, lineH * 3))
        return NSRect(x: 1 + m, y: headH, width: w, height: h)
    }

    /// Measured on a copy: the text view's own layout manager lays out lazily.
    private func draftHeight(width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: textView.attributedString())
        let lm = NSLayoutManager(), tc = NSTextContainer(size: NSSize(width: width, height: 1e6))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).height
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    private var hint: String {
        "Haunt pastes this into the \(target) tab and switches to it. Nothing is sent until you press Return there."
    }

    private var hintHeight: CGFloat {
        let s = RV.para(hint, Draw.ui(TS.reviewHintFont), .white, lineHeight: TS.reviewHintFont * RV.lh)
        return TS.reviewHintPad[0] * 2 + RV.height(s, width: bounds.width - 1 - TS.reviewHintPad[1] * 2)
    }

    override func layout() {
        super.layout()
        let r = boxRect, pad = TS.reviewDraftPad
        box.frame = NSRect(x: r.minX + 1 + pad[1], y: r.minY + 1 + pad[0], width: r.width - 2 - pad[1] * 2, height: r.height - 2 - pad[0] * 2)
        textView.minSize = NSSize(width: 0, height: box.contentSize.height)
        textView.maxSize = NSSize(width: box.contentSize.width, height: 1e6)
        let used = draftHeight(width: box.contentSize.width)
        textView.frame = NSRect(x: 0, y: 0, width: box.contentSize.width, height: max(used, box.contentSize.height))
        textView.needsDisplay = true
        if window?.firstResponder !== textView { box.contentView.scroll(to: .zero) }
        let fp = TS.reviewPanelFootPad
        let top = bounds.height - footH + 1 + fp[0]
        sendBtn.frame = NSRect(x: 1 + fp[1], y: top, width: bounds.width - 1 - fp[1] * 2, height: sendBtn.height)
        keepBtn.frame = NSRect(x: 1 + fp[1], y: top + sendBtn.height + TS.reviewPanelFootGap, width: bounds.width - 1 - fp[1] * 2,
                               height: keepBtn.height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Draw.fill(bounds, Tok.Color.reviewPanelBg)
        Draw.fill(NSRect(x: 0, y: 0, width: 1, height: bounds.height), Tok.Color.hairline)
        let hp = TS.reviewSendHeadPad, hf = Draw.ui(TS.reviewSendHeadFont), hl = TS.reviewSendHeadFont * RV.lh
        let mid = hp[0] + hl / 2
        let ms = TS.reviewClaudeSmall
        RV.agentMark(agent, in: NSRect(x: 1 + hp[1], y: mid - ms / 2, width: ms, height: ms), ctx: ctx)
        RV.text("Follow-up to \(target)", hf, Tok.Color.textPrimary, x: 1 + hp[1] + ms + TS.reviewSendHeadGap, top: hp[0], lineHeight: hl, in: ctx)
        let cf = Draw.ui(TS.reviewHintFont), cl = TS.reviewHintFont * RV.lh
        let c = RV.plural(count, "comment")
        RV.text(c, cf, Tok.Color.textLabel, x: bounds.width - hp[1] - RV.width(c, cf), top: mid - cl / 2, lineHeight: cl, in: ctx)

        let r = boxRect
        RV.rounded(r, radius: TS.reviewDraftRadius, fill: Tok.Color.windowBg, stroke: Tok.Color.reviewNoteBorder)
        let hs = RV.para(hint, Draw.ui(TS.reviewHintFont), Tok.Color.textLabel, lineHeight: TS.reviewHintFont * RV.lh)
        RV.draw(hs, in: NSRect(x: 1 + TS.reviewHintPad[1], y: r.maxY + TS.reviewHintPad[0], width: bounds.width - 1 - TS.reviewHintPad[1] * 2, height: 200))
        Draw.fill(NSRect(x: 1, y: bounds.height - footH, width: bounds.width - 1, height: 1), Tok.Color.hairline)
    }
}

// MARK: Overview (version 09)

/// 09: the turn as a PR page: who and when, the checks it ran, the files, your review, and (not yet) landing it.
final class OverviewPane: NSView {
    private unowned let review: ReviewView
    private var state: ReviewState { review.state }
    private let center = OverviewCenter()
    private let centerScroll = NSScrollView()
    private let side = OverviewSide()

    init(review: ReviewView) {
        self.review = review
        super.init(frame: .zero)
        center.review = review
        centerScroll.documentView = center
        centerScroll.drawsBackground = false
        centerScroll.hasVerticalScroller = true
        centerScroll.autohidesScrollers = true
        centerScroll.scrollerStyle = .overlay
        side.review = review
        addSubview(centerScroll)
        addSubview(side)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let sw = TS.reviewOvW
        centerScroll.frame = NSRect(x: 0, y: 0, width: bounds.width - sw, height: bounds.height)
        center.frame = NSRect(x: 0, y: 0, width: bounds.width - sw, height: max(center.contentHeight(width: bounds.width - sw), bounds.height))
        side.frame = NSRect(x: bounds.width - sw, y: 0, width: sw, height: bounds.height)
    }

    func submit() { side.submit() }
}

final class OverviewCenter: NSView {
    weak var review: ReviewView?
    private var tabRects: [(ReviewState.Mode?, NSRect)] = []

    override var isFlipped: Bool { true }

    private var pad: [CGFloat] { TS.reviewOvPad }

    func contentHeight(width: CGFloat) -> CGFloat { lastBottom + 16 }
    private var lastBottom: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let review else { return }
        let s = review.state
        Draw.fill(bounds, Tok.Color.windowBg)
        let x0 = pad[1], w = bounds.width - pad[1] * 2
        var y = pad[0]

        // Who and when.
        let mf = Draw.ui(TS.reviewOvMetaFont), ml = TS.reviewOvMetaFont * RV.lh, ms = TS.reviewClaudeSmall
        let t = s.turn
        RV.agentMark(t?.agent ?? .claude, in: NSRect(x: x0, y: y + (ml - ms) / 2, width: ms, height: ms), ctx: ctx)
        var meta = [RV.agentName(t?.agent ?? .claude)]
        if let t, t.number > 0 { meta.append("turn \(t.number)") }
        if let f = t?.finishedMs { meta.append((t?.failed == true ? "failed " : "finished ") + RV.clock(f)) } else if let a = t?.startedMs {
            meta.append("running since \(RV.clock(a))")
        }
        if let a = t?.startedMs, let b = t?.finishedMs, b >= a { meta.append(RV.duration(b - a)) }
        RV.text(meta.joined(separator: " · "), mf, Tok.Color.textLabel, x: x0 + ms + TS.reviewOvGap, top: y, lineHeight: ml, maxWidth: w - ms - TS.reviewOvGap, in: ctx)
        y += ml + TS.reviewOvTitleMargin[0]

        // The prompt stands in for a title: it's what was asked.
        let tf = Draw.ui(TS.reviewOvTitleFont, .semibold), tl = TS.reviewOvTitleFont * RV.lh
        let title = t?.prompt.flatMap { $0.isEmpty ? nil : $0 } ?? (t.map { "Turn \($0.number)" } ?? "No agent turn on this tab")
        RV.text(title, tf, Tok.Color.textPrimary, x: x0, top: y, lineHeight: tl, maxWidth: w, kern: TS.reviewOvTitleFont * TS.reviewOvTitleTrackingEm, in: ctx)
        y += tl + TS.reviewOvTitleMargin[1]

        // branch → upstream · worktree path · state.
        let sf = Draw.ui(TS.reviewOvSubFont), sl = TS.reviewOvSubFont * RV.lh, code = Draw.mono(TS.reviewOvSubFont), gap = TS.reviewOvGap
        var x = x0
        if let d = s.diff {
            if let b = d.branch {
                x += RV.text(b, code, Tok.Color.textSub, x: x, top: y, lineHeight: sl, in: ctx) + gap
                if let u = d.upstream {
                    x += RV.text("→", sf, Tok.Color.textLabel, x: x, top: y, lineHeight: sl, in: ctx) + gap
                    x += RV.text(u, code, Tok.Color.textSub, x: x, top: y, lineHeight: sl, in: ctx) + gap
                }
            }
            let where_ = (d.isWorktree ? "worktree " : "") + (d.root as NSString).abbreviatingWithTildeInPath
            let st = d.uncommitted ? "uncommitted" : "clean"
            let commits = d.commits > 0 ? " · " + RV.plural(d.commits, "commit") + " in the turn" : ""
            RV.text("· \(where_) · \(st)\(commits)", sf, Tok.Color.textLabel, x: x, top: y, lineHeight: sl, maxWidth: x0 + w - x, in: ctx)
        } else if let e = s.loadError {
            RV.text(e, sf, Tok.Color.textLabel, x: x, top: y, lineHeight: sl, maxWidth: w, in: ctx)
        }
        y += sl + TS.reviewOvTabsMt

        // Overview · Files N · Turn N steps.
        let tbf = Draw.ui(TS.reviewOvTabsFont), tbl = TS.reviewOvTabsFont * RV.lh
        tabRects = []
        x = x0
        let tabs: [(String, ReviewState.Mode?)] = [("Overview", .overview), ("Files \(s.files.count)", .files),
                                                   ("Turn \(t?.toolCount ?? 0) steps", nil)]
        for (i, (label, mode)) in tabs.enumerated() {
            let lw = RV.width(label, tbf)
            RV.text(label, tbf, i == 0 ? Tok.Color.textPrimary : Tok.Color.textLabel, x: x, top: y, lineHeight: tbl, in: ctx)
            if i == 0 { Draw.fill(NSRect(x: x, y: RV.px(y + tbl + TS.reviewOvTabsPb - 1), width: lw, height: 1), Tok.Color.textPrimary) }
            tabRects.append((mode, NSRect(x: x, y: y, width: lw, height: tbl + TS.reviewOvTabsPb)))
            x += lw + TS.reviewOvTabsGap
        }
        y += tbl + TS.reviewOvTabsPb
        Draw.fill(NSRect(x: x0, y: RV.px(y), width: w, height: 1), Tok.Color.hairline)
        y += 1 + TS.reviewOvGridMt

        let r = TS.reviewOvGridRatio, g = TS.reviewOvGridGap
        let lw = (w - g) * r / (r + 1), rx = x0 + lw + g, rw = w - lw - g
        let left = drawLeft(s, x: x0, top: y, width: lw, ctx: ctx)
        let right = drawRight(s, x: rx, top: y, width: rw, ctx: ctx)
        lastBottom = max(left, right)
    }

    private func drawLeft(_ s: ReviewState, x: CGFloat, top: CGFloat, width: CGFloat, ctx: CGContext) -> CGFloat {
        var y = top
        RV.label("Agent's summary", x: x, top: y, in: ctx)
        y += TS.reviewSecFont * RV.lh + TS.reviewOvSecMb
        let body = RV.para("No summary: the agent's hooks don't pass its closing message to Haunt yet.", Draw.ui(TS.reviewOvSummaryFont),
                           Tok.Color.textLabel, lineHeight: TS.reviewOvSummaryFont * TS.reviewOvSummaryLine)
        let bh = RV.height(body, width: width)
        RV.draw(body, in: NSRect(x: x, y: y, width: width, height: bh))
        y += bh + TS.reviewOvSecMt[0]

        let lx = RV.label("Checks", x: x, top: y, in: ctx)
        RV.text(" · from the turn", Draw.ui(TS.reviewSecFont), Tok.Color.textLabel, x: x + lx, top: y, in: ctx)
        y += TS.reviewSecFont * RV.lh + TS.reviewOvSecMt[1]
        let cols = TS.reviewOvCheckCols, cf = Draw.ui(TS.reviewOvCheckFont), cl = TS.reviewOvCheckFont * RV.lh
        let rowH = 1 + cols[2] * 2 + cl
        if s.checks.isEmpty {
            Draw.fill(NSRect(x: x, y: RV.px(y), width: width, height: 1), Tok.Color.diffRule)
            RV.text("No test or build commands in this turn.", cf, Tok.Color.textLabel, x: x, top: y + 1 + cols[2], lineHeight: cl, in: ctx)
            return y + rowH
        }
        let rf = Draw.ui(TS.reviewOvCheckResFont), rl = TS.reviewOvCheckResFont * RV.lh
        let codeF = Draw.mono(TS.reviewOvSubFont), codeL = TS.reviewOvSubFont * RV.lh
        for c in s.checks {
            Draw.fill(NSRect(x: x, y: RV.px(y), width: width, height: 1), Tok.Color.diffRule)
            let top = y + 1 + cols[2], mid = top + cl / 2
            let on = c.state == .passed || c.state == .failed
            let mark = c.state == .passed ? "✓" : c.state == .failed ? "✗" : "○"
            RV.text(mark, Draw.mono(TS.reviewOvCheckFont), on ? Tok.Color.textPrimary : Tok.Color.reviewMarkOff, x: x, top: top, lineHeight: cl, in: ctx)
            let res = c.result, src = c.source.map { " · \($0)" } ?? ""
            let srcW = RV.width(src, rf), resW = RV.width(res, rf)
            let rx = x + width - srcW - resW
            RV.text(res, rf, on ? Tok.Color.textSub : Tok.Color.textLabel, x: rx, top: mid - rl / 2, lineHeight: rl, in: ctx)
            if !src.isEmpty { RV.text(src, rf, Tok.Color.textLabel, x: rx + resW, top: mid - rl / 2, lineHeight: rl, in: ctx) }
            let nx = x + cols[0] + cols[1]
            RV.text(c.command, codeF, Tok.Color.textPrimary, x: nx, top: mid - codeL / 2, lineHeight: codeL, maxWidth: rx - cols[1] - nx, in: ctx)
            y += rowH
        }
        return y
    }

    private func drawRight(_ s: ReviewState, x: CGFloat, top: CGFloat, width: CGFloat, ctx: CGContext) -> CGFloat {
        var y = top
        RV.label("Files changed", x: x, top: y, in: ctx)
        let (a, d) = s.totals, tot = "+\(a) −\(d)", sf = Draw.ui(TS.reviewSecFont)
        RV.text(tot, sf, Tok.Color.textLabel, x: x + width - RV.width(tot, sf), top: y, in: ctx)
        y += TS.reviewSecFont * RV.lh + TS.reviewOvSecMb
        let fc = TS.reviewOvFileCols, nf = Draw.mono(TS.reviewFnFont), nl = TS.reviewFnFont * RV.lh, stF = Draw.mono(TS.reviewStFont)
        let rowH = 1 + fc[1] * 2 + nl
        for i in s.tree.fileOrder {
            let f = s.files[i]
            Draw.fill(NSRect(x: x, y: RV.px(y), width: width, height: 1), Tok.Color.diffRule)
            let mid = y + 1 + fc[1] + nl / 2
            let sqX = x + width - RV.squaresWidth
            if !f.binary, !f.special { RV.squares(f.additions, f.deletions, x: sqX, midY: mid) }
            let st = f.special ? "special" : f.binary ? "binary" : RV.stat(f.additions, f.deletions), stW = RV.width(st, stF)
            let stX = sqX - fc[0] - stW
            RV.text(st, stF, Tok.Color.textSub, x: stX, top: mid - TS.reviewStFont * RV.lh / 2, in: ctx)
            RV.text(f.name, nf, Tok.Color.textPrimary, x: x, top: mid - nl / 2, lineHeight: nl, maxWidth: stX - fc[0] - x, in: ctx)
            y += rowH
        }
        y += TS.reviewOvSecMt[0]
        RV.label("Turn", x: x, top: y, in: ctx)
        y += TS.reviewSecFont * RV.lh + TS.reviewOvTurnMb
        guard let t = s.turn else { return y }
        let lf = Draw.ui(TS.reviewOvSubFont), ll = TS.reviewOvSubFont * RV.lh
        var parts = [RV.plural(Int(t.toolCount), "step"), RV.plural(Int(t.editCount), "edit"), RV.plural(t.commands.count, "command")]
        if !t.subagents.isEmpty { parts.append(RV.plural(t.subagents.count, "subagent")) }
        var lines: [(String, NSColor)] = [(parts.joined(separator: " · "), Tok.Color.textSub)]
        for sa in t.subagents.prefix(3) {
            var l = [sa.label]
            if let n = sa.toolCount { l.append(RV.plural(Int(n), "tool")) }
            if let ms = sa.durationMs { l.append(RV.duration(ms)) }
            lines.append((l.joined(separator: " · "), Tok.Color.textLabel))
        }
        for (i, (l, c)) in lines.enumerated() {
            if i > 0 { y += TS.reviewOvTurnGap }
            let p = RV.para(l, lf, c, lineHeight: ll)
            let h = RV.height(p, width: width)
            RV.draw(p, in: NSRect(x: x, y: y, width: width, height: h))
            y += h
        }
        return y
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (mode, r) in tabRects where r.contains(p) {
            // The Turn tab is there because 09 shows it; its view isn't built yet.
            if let mode { review?.setMode(mode) } else { NSSound.beep() }
        }
    }

}

/// 09's right column: Approve / Request changes / Comment only, a note, Submit, and Land it (not wired yet).
final class OverviewSide: NSView {
    weak var review: ReviewView? { didSet { refresh() } }
    private let noteBox = NSScrollView()
    private let note: RVTextView
    private let submitBtn = RVButton("Submit review", key: "⌘↵")
    private let mergeBtn = RVButton("Squash and merge", primary: true)
    private let prBtn = RVButton("Commit and open PR on GitHub")
    private var radioRects: [(ReviewState.Verdict, NSRect)] = []

    override init(frame: NSRect) {
        note = RVTextView.make(font: Draw.ui(TS.reviewRowFont), color: Tok.Color.textPrimary, lineHeight: TS.reviewRowFont * RV.lh)
        super.init(frame: frame)
        note.placeholder = "Note for the agent, optional"
        note.onChange = { [weak self] in self?.review?.state.note = self?.note.string ?? "" }
        note.onCommandReturn = { [weak self] in self?.submit() }
        note.autoresizingMask = .width
        noteBox.documentView = note
        noteBox.drawsBackground = false
        noteBox.hasVerticalScroller = true
        noteBox.autohidesScrollers = true
        noteBox.scrollerStyle = .overlay
        for b in [submitBtn, mergeBtn, prBtn] { b.centred = true }
        submitBtn.action = { [weak self] in self?.submit() }
        // Haunt doesn't merge, commit or push yet; the buttons are 09's and do nothing destructive.
        for b in [mergeBtn, prBtn] {
            b.toolTip = "Coming soon: Haunt doesn't merge, commit or push yet."
            b.action = { NSSound.beep() }
        }
        for v in [noteBox, submitBtn, mergeBtn, prBtn] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        guard let s = review?.state else { return }
        note.string = s.note
        mergeBtn.title = "Squash and merge" + (s.diff?.upstream.map { " into \(($0 as NSString).lastPathComponent)" } ?? "")
        submitBtn.title = s.approved ? "Approved" : "Submit review"
        needsLayout = true
        needsDisplay = true
    }

    func submit() {
        guard let review else { return }
        switch review.state.verdict {
        case .approve:
            review.approve()
            refresh()
        case .requestChanges, .commentOnly:
            review.state.editedDraft = nil
            review.setMode(.sendBack)
        }
    }

    private var pad: [CGFloat] { TS.reviewOvSidePad }
    private var gap: CGFloat { TS.reviewOvSideGap }
    private var secH: CGFloat { TS.reviewSecFont * RV.lh }
    private var radioH: CGFloat { TS.reviewOvTabsFont * RV.lh }

    private var footnote: String {
        let n = review?.state.checks.filter { $0.state == .notRun }.count ?? 0
        return n == 0 ? "" : "\(RV.plural(n, "check")) not run. Run them in the terminal before you merge."
    }

    private func footHeight(width: CGFloat) -> CGFloat {
        guard !footnote.isEmpty else { return 0 }
        return RV.height(RV.para(footnote, Draw.ui(TS.reviewHintFont), .white, lineHeight: TS.reviewHintFont * RV.lh), width: width)
    }

    override func layout() {
        super.layout()
        let x = 1 + pad[1], w = bounds.width - 1 - pad[1] * 2
        var y = pad[0] + secH + gap + radioH * 3 + TS.reviewOvRadioGap * 2 + gap
        let ip = TS.reviewOvInputPad
        noteBox.frame = NSRect(x: x + 1 + ip[1], y: y + 1 + ip[0], width: w - 2 - ip[1] * 2, height: TS.reviewOvInputH - 2 - ip[0] * 2)
        note.frame.size.width = noteBox.contentSize.width
        note.minSize = NSSize(width: 0, height: noteBox.contentSize.height)
        note.maxSize = NSSize(width: noteBox.contentSize.width, height: 1e6)
        y += TS.reviewOvInputH + gap
        submitBtn.frame = NSRect(x: x, y: y, width: w, height: submitBtn.height)
        var b = bounds.height - pad[0]
        let fh = footHeight(width: w)
        if fh > 0 { b -= fh + gap }
        b -= prBtn.height
        prBtn.frame = NSRect(x: x, y: b, width: w, height: prBtn.height)
        b -= gap + mergeBtn.height
        mergeBtn.frame = NSRect(x: x, y: b, width: w, height: mergeBtn.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let s = review?.state else { return }
        Draw.fill(bounds, Tok.Color.reviewPanelBg)
        Draw.fill(NSRect(x: 0, y: 0, width: 1, height: bounds.height), Tok.Color.hairline)
        let x = 1 + pad[1], w = bounds.width - 1 - pad[1] * 2
        var y = pad[0]
        RV.label("Your review", x: x, top: y, in: ctx)
        y += secH + gap
        radioRects = []
        let rf = Draw.ui(TS.reviewOvTabsFont), size = TS.reviewOvRadioSize
        for (v, label) in [(ReviewState.Verdict.approve, "Approve"), (.requestChanges, "Request changes"), (.commentOnly, "Comment only")] {
            let on = s.verdict == v
            let c = NSRect(x: x, y: RV.px(y + (radioH - size[0]) / 2), width: size[0], height: size[0])
            if on {
                let ring = NSBezierPath(ovalIn: c.insetBy(dx: size[1] / 2, dy: size[1] / 2))
                ring.lineWidth = size[1]
                Tok.Color.textPrimary.setStroke()
                ring.stroke()
            } else {
                let ring = NSBezierPath(ovalIn: c.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                Tok.Color.reviewMarkOff.setStroke()
                ring.stroke()
            }
            RV.text(label, rf, on ? Tok.Color.textPrimary : Tok.Color.textSub, x: x + size[0] + TS.reviewOvGap, top: y, lineHeight: radioH, in: ctx)
            radioRects.append((v, NSRect(x: x, y: y, width: w, height: radioH)))
            y += radioH + TS.reviewOvRadioGap
        }
        y += gap - TS.reviewOvRadioGap
        RV.rounded(NSRect(x: x, y: y, width: w, height: TS.reviewOvInputH), radius: TS.reviewOvInputRadius, fill: nil, stroke: Tok.Color.reviewInputBorder)

        let landTop = mergeBtn.frame.minY - gap - secH
        RV.label("Land it", x: x, top: landTop, in: ctx)
        if !footnote.isEmpty {
            let p = RV.para(footnote, Draw.ui(TS.reviewHintFont), Tok.Color.textLabel, lineHeight: TS.reviewHintFont * RV.lh)
            let fh = footHeight(width: w)
            RV.draw(p, in: NSRect(x: x, y: bounds.height - pad[0] - fh, width: w, height: fh))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (v, _) = radioRects.first(where: { $0.1.contains(p) }) else { return }
        review?.state.verdict = v
        needsDisplay = true
    }
}
