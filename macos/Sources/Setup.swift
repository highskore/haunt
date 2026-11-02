import AppKit
import os

/// The agents `haunt setup` installs an adapter for.
enum SetupAgent: String, CaseIterable {
    case claude, codex

    var name: String { self == .claude ? "Claude Code" : "Codex" }

    var icon: NSImage? {
        let s = Tok.Size.claudeIcon
        switch self {
        case .claude:
            return NSImage(size: NSSize(width: s, height: s), flipped: true) { r in
                Draw.claudeMark(in: r)
                return true
            }
        case .codex:
            // A template image: AppKit tints it to the label colour wherever it is shown.
            return Draw.openAIMark
        }
    }

    static func names(_ agents: [SetupAgent]) -> String { agents.map(\.name).joined(separator: " and ") }
}

/// Runs the `haunt` CLI bundled in Contents/Helpers, so the app shows and applies exactly what `haunt setup` does.
enum SetupCLI {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.haunt.Haunt", category: "setup")

    static var url: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/haunt") }

    /// Calls back on the main queue with the exit status and the combined stdout and stderr.
    static func run(_ args: [String], config: HauntConfig, fixture: Bool,
                    completion: @escaping (_ ok: Bool, _ output: String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var env = ProcessInfo.processInfo.environment
            env["HAUNT_CONFIG_DIR"] = config.dir.path
            if fixture {
                // Fixture previews read nothing of the user's own agent configs.
                env["HOME"] = config.dir.appendingPathComponent("home").path
                env["CODEX_HOME"] = nil
                env["CLAUDE_CONFIG_DIR"] = nil
            } else {
                env["PATH"] = userPath
            }
            let p = Process()
            p.executableURL = url
            p.arguments = ["setup"] + args
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            var ok = false
            var text = ""
            do {
                try p.run()
                text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {
                text = "Couldn't run \(url.path): \(error.localizedDescription)"
            }
            logger.info("haunt setup \(args.joined(separator: " "), privacy: .public): \(ok ? "ok" : "failed", privacy: .public)")
            DispatchQueue.main.async { completion(ok, text) }
        }
    }

    /// An app opened from Finder gets launchd's bare PATH, which misses claude.
    private static let userPath: String = {
        let env = ProcessInfo.processInfo.environment
        let found = LoginPath.fetch(shell: env["SHELL"] ?? "/bin/zsh")
        return LoginPath.compose(found: found, inherited: env["PATH"], home: NSHomeDirectory())
    }()
}

/// The first-launch picker and the confirm sheets, shared with Settings. Every change comes from the CLI's own text.
final class SetupSheets {
    private let config: HauntConfig
    private let fixture: Bool

    init(config: HauntConfig, fixture: Bool) {
        self.config = config
        self.fixture = fixture
    }

    /// The agents state.json records; nil until setup has run once.
    var recorded: Set<SetupAgent>? {
        config.loadState().agents.map { Set($0.compactMap(SetupAgent.init(rawValue:))) }
    }

    /// Claude Code / Codex checkboxes, Continue, and "Just the terminal", which records the choice and changes nothing.
    func showPicker(on window: NSWindow, checked: Set<SetupAgent> = []) {
        let alert = NSAlert()
        alert.messageText = "Which agents do you use?"
        alert.informativeText = "Haunt shows what each agent is doing through a small adapter. You'll see the exact change before it's made, and can change it later in Settings."
        let cont = alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Just the terminal")
        let boxes = SetupAgent.allCases.map { a -> NSButton in
            let b = NSButton(checkboxWithTitle: a.name, target: nil, action: nil)
            b.attributedTitle = Self.title(a)
            b.state = checked.contains(a) ? .on : .off
            return b
        }
        let toggled = BlockTarget { cont.isEnabled = boxes.contains { $0.state == .on } }
        for b in boxes {
            b.target = toggled
            b.action = #selector(BlockTarget.fire)
        }
        toggled.fire()
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: stack.fittingSize.height)
        alert.accessoryView = stack
        alert.beginSheetModal(for: window) { [self] r in
            _ = toggled
            if r == .alertFirstButtonReturn {
                let chosen = zip(SetupAgent.allCases, boxes).filter { $0.1.state == .on }.map(\.0)
                confirm(chosen, remove: false, on: window,
                        back: { [weak self, weak window] in
                            if let window { self?.showPicker(on: window, checked: Set(chosen)) }
                        }, done: {})
            } else {
                run(["none"], on: window, report: false) { _ in }
            }
        }
    }

    /// The CLI's dry run as a sheet; Apply runs the same command with --yes. `back` replaces Cancel with Back.
    func confirm(_ agents: [SetupAgent], remove: Bool, on window: NSWindow, back: (() -> Void)?, done: @escaping () -> Void) {
        let args = (remove ? ["--remove"] : []) + agents.map(\.rawValue)
        SetupCLI.run(args + ["--dry-run"], config: config, fixture: fixture) { [weak self, weak window] ok, text in
            guard let self, let window else { return }
            // Apply runs separately, so it carries the preview's hash and the CLI refuses a change that differs.
            let marker = "preview sha256 "
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let sha = lines.last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
            guard ok, let sha else { return self.report("Couldn't prepare the change", text, on: window, then: back ?? done) }
            let preview = lines.filter { !$0.hasPrefix(marker) }.joined(separator: "\n")
            let alert = NSAlert()
            alert.messageText = remove ? "Remove \(SetupAgent.names(agents))?" : "Set up \(SetupAgent.names(agents))?"
            alert.informativeText = "This is what `haunt setup \(args.joined(separator: " "))` will do:"
            alert.accessoryView = Self.textBox(preview)
            alert.addButton(withTitle: back == nil ? "Cancel" : "Back")
            let apply = alert.addButton(withTitle: remove ? "Remove" : "Apply")
            apply.keyEquivalent = ""
            alert.beginSheetModal(for: window) { [weak self] r in
                guard let self else { return }
                guard r == .alertSecondButtonReturn else { return (back ?? done)() }
                self.run(args + ["--yes", "--expect", sha], on: window, report: true) { _ in done() }
            }
        }
    }

    private func run(_ args: [String], on window: NSWindow, report: Bool, then: @escaping (Bool) -> Void) {
        // Fixtures only ever preview.
        guard !fixture else { return then(false) }
        SetupCLI.run(args, config: config, fixture: false) { [weak self, weak window] ok, text in
            guard let self, let window else { return then(ok) }
            if report || !ok {
                self.report(ok ? "Done" : "Setup didn't finish", text, on: window) { then(ok) }
            } else {
                then(ok)
            }
        }
    }

    private func report(_ title: String, _ text: String, on window: NSWindow, then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = Self.textBox(text)
        alert.beginSheetModal(for: window) { _ in then() }
    }

    static func title(_ a: SetupAgent) -> NSAttributedString {
        let s = NSMutableAttributedString()
        if let img = a.icon {
            let att = NSTextAttachment()
            att.image = img
            att.bounds = NSRect(x: 0, y: -3, width: img.size.width, height: img.size.height)
            s.append(NSAttributedString(attachment: att))
            s.append(NSAttributedString(string: "  "))
        }
        s.append(NSAttributedString(string: a.name))
        s.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor],
                        range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Read-only and unwrapped, so a diff keeps its columns; scrolls past fourteen lines.
    static func textBox(_ text: String) -> NSScrollView {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let lineH = NSLayoutManager().defaultLineHeight(for: font)
        let lines = min(max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 3), 14)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: (lineH * CGFloat(lines)).rounded(.up) + 24))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = font
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text.trimmingCharacters(in: .newlines)
        scroll.documentView = tv
        tv.sizeToFit()
        // The text view otherwise opens scrolled to its end.
        DispatchQueue.main.async { tv.scrollToBeginningOfDocument(nil) }
        return scroll
    }
}

/// Lets a closure be a control's target.
final class BlockTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

/// Haunt > Settings…: one vertical stack of sections, so more can be added below Agents.
final class SettingsWindowController: NSWindowController {
    private let sheets: SetupSheets
    private let configPath: String
    private let openConfig: () -> Void
    private let stack = NSStackView()
    private var targets: [BlockTarget] = []

    init(sheets: SetupSheets, configPath: String, openConfig: @escaping () -> Void) {
        self.sheets = sheets
        self.configPath = configPath
        self.openConfig = openConfig
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Settings"
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = Tok.Color.windowBg
        win.isReleasedWhenClosed = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 440),
        ])
        win.contentView = content
        super.init(window: win)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets = []
        let recorded = sheets.recorded ?? []
        section("Agents", SetupAgent.allCases.map { a in
            let on = recorded.contains(a)
            return row(icon: a.icon, name: a.name, status: on ? "Set up" : "Not set up",
                       button: on ? "Remove…" : "Set up…") { [weak self] in self?.change(a, remove: on) }
        })
        section("Config", [row(icon: nil, name: (configPath as NSString).abbreviatingWithTildeInPath, status: "",
                               button: "Open config.toml", action: openConfig)])
        window?.setContentSize(stack.fittingSize)
    }

    private func change(_ a: SetupAgent, remove: Bool) {
        guard let window else { return }
        sheets.confirm([a], remove: remove, on: window, back: nil) { [weak self] in self?.rebuild() }
    }

    private func section(_ title: String, _ rows: [NSView]) {
        if !stack.arrangedSubviews.isEmpty {
            let rule = NSBox()
            rule.boxType = .separator
            stack.addArrangedSubview(rule)
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            stack.setCustomSpacing(14, after: rule)
        }
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [
            .font: Draw.ui(Tok.Size.labelFont, .medium), .foregroundColor: Tok.Color.textLabel,
            .kern: Tok.Size.labelFont * Tok.Size.labelTrackingEm,
        ]))
        stack.addArrangedSubview(label)
        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        if let last = rows.last { stack.setCustomSpacing(18, after: last) }
    }

    private func row(icon: NSImage?, name: String, status: String, button: String,
                     action: @escaping () -> Void) -> NSView {
        var views: [NSView] = []
        if let icon { views.append(NSImageView(image: icon)) }
        let title = NSTextField(labelWithString: name)
        title.font = Draw.ui(Tok.Size.rowName)
        title.textColor = Tok.Color.textHi
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        views.append(title)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        if !status.isEmpty {
            let s = NSTextField(labelWithString: status)
            s.font = Draw.ui(Tok.Size.rowMeta)
            s.textColor = Tok.Color.textMeta
            views.append(s)
        }
        let target = BlockTarget(action)
        targets.append(target)
        let b = NSButton(title: button, target: target, action: #selector(BlockTarget.fire))
        b.bezelStyle = .rounded
        b.controlSize = .small
        views.append(b)
        let h = NSStackView(views: views)
        h.orientation = .horizontal
        h.spacing = 8
        return h
    }
}
