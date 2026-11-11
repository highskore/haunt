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

    static func names(_ agents: [SetupAgent]) -> String { list(agents.map(\.name)) }

    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

/// A plugin haunt.app bundles, as `haunt setup --list-plugins` describes it.
struct BundledPlugin: Decodable, Equatable {
    let id: String
    let short: String
    let name: String
    let description: String
    /// Installed from this app's bundle.
    let installed: Bool
    /// Where the installed copy came from (`bundled`, or a folder for `haunt plugin install`); nil when not installed.
    let source: String?
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

    /// The bundled plugins, from the CLI; empty when the app was built without any.
    func plugins(_ done: @escaping ([BundledPlugin]) -> Void) {
        SetupCLI.run(["--list-plugins"], config: config, fixture: fixture) { ok, text in
            done(ok ? (try? JSONDecoder().decode([BundledPlugin].self, from: Data(text.utf8))) ?? [] : [])
        }
    }

    /// Claude Code / Codex checkboxes, then the bundled plugins (if any), all unchecked; Continue sets up what is
    /// checked, and "Just the terminal" records the choice and changes nothing.
    func showPicker(on window: NSWindow, checked: Set<SetupAgent> = [], checkedPlugins: Set<String> = []) {
        plugins { [weak self, weak window] plugins in
            guard let self, let window else { return }
            self.showPicker(on: window, plugins: plugins, checked: checked, checkedPlugins: checkedPlugins)
        }
    }

    private func showPicker(on window: NSWindow, plugins: [BundledPlugin], checked: Set<SetupAgent>, checkedPlugins: Set<String>) {
        let boxes = SetupAgent.allCases.map { a -> NSButton in
            let b = NSButton(checkboxWithTitle: a.name, target: nil, action: nil)
            b.attributedTitle = Self.title(a)
            b.state = checked.contains(a) ? .on : .off
            return b
        }
        let pluginBoxes = plugins.map { p -> NSButton in
            let b = NSButton(checkboxWithTitle: p.name, target: nil, action: nil)
            b.attributedTitle = NSAttributedString(string: p.name, attributes: [.font: Tok.App.sheetFont, .foregroundColor: Tok.App.sheetText])
            b.state = checkedPlugins.contains(p.short) ? .on : .off
            return b
        }
        let items = zip(plugins, pluginBoxes).map { p, b -> NSView in
            guard !p.description.isEmpty else { return b }
            let d = NSStackView(views: [Self.detail(p.description, width: Tok.App.setupChoicesW - Tok.App.setupDetailIndent - Tok.App.scrollerGutter)])
            d.edgeInsets = NSEdgeInsets(top: 0, left: Tok.App.setupDetailIndent, bottom: 0, right: 0)
            let item = NSStackView(views: [b, d])
            item.orientation = .vertical
            item.alignment = .leading
            item.spacing = Tok.App.setupDetailGap
            return item
        }
        let alert = NSAlert()
        alert.messageText = "Which agents do you use?"
        alert.informativeText = "Haunt shows what each agent is doing through a small adapter. You'll see the exact change before it's made, and can change it later in Settings."
        let cont = alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Just the terminal")
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Tok.App.setupChoiceGap
        var list: NSScrollView?
        if !plugins.isEmpty {
            stack.addArrangedSubview(Self.detail("Plugins (optional), installed only if you check them:", width: Tok.App.setupChoicesW))
            stack.setCustomSpacing(Tok.App.setupGroupGap, after: boxes.last!)
            // A first height that keeps NSAlert in its usual layout (a sheet taller than the screen gets another one).
            list = Self.scrolling(items, width: Tok.App.setupChoicesW, spacing: Tok.App.setupChoiceGap,
                                  maxH: max(window.frame.height / 2, Tok.App.setupPluginsMinH))
            stack.addArrangedSubview(list!)
        }
        stack.frame = NSRect(x: 0, y: 0, width: Tok.App.setupChoicesW, height: stack.fittingSize.height)
        alert.accessoryView = stack
        alert.layout()
        // The sheet hangs from the window's top; the plugins scroll so it ends above the window's bottom.
        if let list, let h = list.constraints.first(where: { $0.firstAttribute == .height }), let full = list.documentView?.frame.height {
            let rest = alert.window.frame.height - h.constant
            let fit = min(full, max(window.frame.height - Tok.App.setupSheetMargin - rest, Tok.App.setupPluginsMinH)).rounded(.down)
            let grow = fit - h.constant
            h.constant = fit
            list.hasVerticalScroller = fit < full
            stack.setFrameSize(NSSize(width: stack.frame.width, height: stack.frame.height + grow))
            var f = alert.window.frame
            f.size.height += grow
            alert.window.setFrame(f, display: false)
            stack.layoutSubtreeIfNeeded()
        }
        let all = boxes + pluginBoxes
        let toggled = BlockTarget { cont.isEnabled = all.contains { $0.state == .on } }
        for b in all {
            b.target = toggled
            b.action = #selector(BlockTarget.fire)
        }
        toggled.fire()
        alert.beginSheetModal(for: window) { [self] r in
            _ = toggled
            guard r == .alertFirstButtonReturn else {
                run(["none"], on: window, report: false) { _ in }
                return
            }
            let chosen = zip(SetupAgent.allCases, boxes).filter { $0.1.state == .on }.map(\.0)
            let picked = zip(plugins, pluginBoxes).filter { $0.1.state == .on }.map(\.0)
            // Back shows the same list again, without asking the CLI a second time.
            let back = { [weak self, weak window] in
                if let window {
                    self?.showPicker(on: window, plugins: plugins, checked: Set(chosen), checkedPlugins: Set(picked.map(\.short)))
                }
            }
            let pluginArgs = picked.isEmpty ? [] : ["--plugins", picked.map(\.short).joined(separator: ",")]
            // Plugins alone still record "no agents", so the picker doesn't come back on the next launch.
            let agentArgs = chosen.isEmpty ? ["none"] : chosen.map(\.rawValue)
            let what = SetupAgent.list(chosen.map(\.name) + picked.map(\.name))
            confirm(args: agentArgs + pluginArgs, title: chosen.isEmpty ? "Install \(what)?" : "Set up \(what)?", apply: "Apply",
                    on: window, back: back, done: {})
        }
    }

    /// A column of views that scrolls once it is taller than `maxH`; `fill` stretches each view to the column,
    /// which leaves the scroller its own room.
    static func scrolling(_ views: [NSView], width: CGFloat, spacing: CGFloat, maxH: CGFloat, fill: Bool = false) -> NSScrollView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = spacing
        let w = column.widthAnchor.constraint(equalToConstant: width)
        w.isActive = true
        if fill { views.forEach { $0.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true } }
        if fill, column.fittingSize.height > maxH { w.constant = width - Tok.App.scrollerGutter }
        column.frame = NSRect(x: 0, y: 0, width: w.constant, height: column.fittingSize.height)
        // Flipped, so the list starts at its top.
        let doc = FlippedView(frame: column.frame)
        doc.addSubview(column)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(column.frame.height, maxH).rounded(.up)))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = column.frame.height > maxH
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: scroll.frame.height).isActive = true
        return scroll
    }

    /// Secondary text in a native sheet, wrapping at `width`.
    private static func detail(_ text: String, width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = Tok.App.sheetDetailFont
        f.textColor = Tok.App.sheetDetail
        f.preferredMaxLayoutWidth = width
        return f
    }

    /// The CLI's dry run as a sheet; Apply runs the same command with --yes. `back` replaces Cancel with Back.
    func confirm(_ agents: [SetupAgent], remove: Bool, on window: NSWindow, back: (() -> Void)?, done: @escaping () -> Void) {
        confirm(args: (remove ? ["--remove"] : []) + agents.map(\.rawValue),
                title: remove ? "Remove \(SetupAgent.names(agents))?" : "Set up \(SetupAgent.names(agents))?",
                apply: remove ? "Remove" : "Apply", on: window, back: back, done: done)
    }

    func confirm(args: [String], title: String, apply applyTitle: String, on window: NSWindow,
                 back: (() -> Void)?, done: @escaping () -> Void) {
        SetupCLI.run(args + ["--dry-run"], config: config, fixture: fixture) { [weak self, weak window] ok, text in
            guard let self, let window else { return }
            // Apply runs separately, so it carries the preview's hash and the CLI refuses a change that differs.
            let marker = "preview sha256 "
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let sha = lines.last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
            guard ok, let sha else { return self.report("Couldn't prepare the change", text, on: window, then: back ?? done) }
            let preview = lines.filter { !$0.hasPrefix(marker) }.joined(separator: "\n")
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = "This is what `haunt setup \(args.joined(separator: " "))` will do:"
            alert.accessoryView = Self.textBox(preview)
            alert.addButton(withTitle: back == nil ? "Cancel" : "Back")
            let apply = alert.addButton(withTitle: applyTitle)
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
            att.bounds = NSRect(x: 0, y: -Tok.App.setupIconDrop, width: img.size.width, height: img.size.height)
            s.append(NSAttributedString(attachment: att))
            s.append(NSAttributedString(string: "  "))
        }
        s.append(NSAttributedString(string: a.name))
        s.addAttributes([.font: Tok.App.sheetFont, .foregroundColor: Tok.App.sheetText],
                        range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Read-only and unwrapped, so a diff keeps its columns; scrolls past fourteen lines.
    static func textBox(_ text: String) -> NSScrollView {
        let font = Tok.App.sheetMono
        let lineH = NSLayoutManager().defaultLineHeight(for: font)
        let n = text.split(separator: "\n", omittingEmptySubsequences: false).count, range = Tok.App.setupDiffLines
        let lines = min(max(n, range.lowerBound), range.upperBound)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Tok.App.setupDiffW,
                                                height: (lineH * CGFloat(lines)).rounded(.up) + Tok.App.setupDiffChrome))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = font
        tv.textContainerInset = Tok.App.textBoxInset
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

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
    private let notifications: () -> NotificationSettings
    private let stack = NSStackView()
    private var targets: [BlockTarget] = []
    private var plugins: [BundledPlugin] = []

    init(sheets: SetupSheets, configPath: String, notifications: @escaping () -> NotificationSettings,
         openConfig: @escaping () -> Void) {
        self.sheets = sheets
        self.configPath = configPath
        self.notifications = notifications
        self.openConfig = openConfig
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Tok.App.settingsW, height: Tok.App.settingsH),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Settings"
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = Tok.Color.windowBg
        win.isReleasedWhenClosed = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Tok.App.settingsGap
        stack.edgeInsets = Tok.App.settingsInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Tok.App.settingsW),
        ])
        win.contentView = content
        super.init(window: win)
        rebuild()
    }

    /// Rebuilds now, then again once the CLI has said which plugins are bundled and installed.
    func refresh() {
        rebuild()
        sheets.plugins { [weak self] p in
            guard let self, p != self.plugins else { return }
            self.plugins = p
            self.rebuild()
        }
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
        // Read-only: the switches live in config.toml's [notifications], which hot-reloads into this section.
        let n = notifications()
        func onOff(_ on: Bool) -> String { on ? "On" : "Off" }
        section("Notifications", [
            row(icon: nil, name: "Notifications", status: onOff(n.enabled), button: "Edit in config.toml…", action: openConfig),
            row(icon: nil, name: "When an agent needs you", status: onOff(n.onPermission)),
            row(icon: nil, name: "When an agent finishes", status: onOff(n.onDone)),
            row(icon: nil, name: "Menu bar item", status: onOff(n.menuBar)),
        ])
        if !plugins.isEmpty {
            let w = Tok.App.settingsW - insetsW
            let rows = plugins.map { p -> NSView in
                let status = p.installed ? "Installed"
                    : p.source.map { "Installed (from \(($0 as NSString).abbreviatingWithTildeInPath))" } ?? "Not installed"
                let button = p.installed ? "Remove…" : p.source == nil ? "Install…" : "Replace…"
                let r = row(icon: nil, name: p.name, status: status, button: button) { [weak self] in self?.change(p) }
                guard !p.description.isEmpty else { return r }
                let d = NSTextField(wrappingLabelWithString: p.description)
                d.font = Draw.ui(Tok.Size.rowMeta)
                d.textColor = Tok.Color.textMeta
                d.preferredMaxLayoutWidth = w - Tok.App.scrollerGutter
                let v = NSStackView(views: [r, d])
                v.orientation = .vertical
                v.alignment = .leading
                v.spacing = Tok.App.setupDetailGap
                r.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
                return v
            }
            section("Plugins", [SetupSheets.scrolling(rows, width: w, spacing: Tok.App.settingsGap,
                                                      maxH: Tok.App.settingsPluginsMaxH, fill: true)])
        }
        section("Config", [row(icon: nil, name: (configPath as NSString).abbreviatingWithTildeInPath, status: "",
                               button: "Open config.toml", action: openConfig)])
        window?.setContentSize(stack.fittingSize)
    }

    private func change(_ a: SetupAgent, remove: Bool) {
        guard let window else { return }
        sheets.confirm([a], remove: remove, on: window, back: nil) { [weak self] in self?.rebuild() }
    }

    private func change(_ p: BundledPlugin) {
        guard let window else { return }
        // A copy from elsewhere is the user's to remove (`haunt plugin remove`); Replace installs the app's in its place.
        sheets.confirm(args: [p.installed ? "--remove-plugins" : "--plugins", p.short],
                       title: p.installed ? "Remove \(p.name)?" : p.source == nil ? "Install \(p.name)?" : "Replace \(p.name)?",
                       apply: p.installed ? "Remove" : "Apply", on: window, back: nil) { [weak self] in self?.refresh() }
    }

    private var insetsW: CGFloat { Tok.App.settingsInsets.left + Tok.App.settingsInsets.right }

    private func section(_ title: String, _ rows: [NSView]) {
        if !stack.arrangedSubviews.isEmpty {
            let rule = NSBox()
            rule.boxType = .separator
            stack.addArrangedSubview(rule)
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -insetsW).isActive = true
            stack.setCustomSpacing(Tok.App.settingsAfterRule, after: rule)
        }
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [
            .font: Draw.ui(Tok.Size.labelFont, .medium), .foregroundColor: Tok.Color.textLabel,
            .kern: Tok.Size.labelFont * Tok.Size.labelTrackingEm,
        ]))
        stack.addArrangedSubview(label)
        for r in rows {
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -insetsW).isActive = true
        }
        if let last = rows.last { stack.setCustomSpacing(Tok.App.settingsAfterSection, after: last) }
    }

    private func row(icon: NSImage?, name: String, status: String, button: String? = nil,
                     action: @escaping () -> Void = {}) -> NSView {
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
        if let button {
            let target = BlockTarget(action)
            targets.append(target)
            let b = NSButton(title: button, target: target, action: #selector(BlockTarget.fire))
            b.bezelStyle = .rounded
            b.controlSize = .small
            views.append(b)
        }
        let h = NSStackView(views: views)
        h.orientation = .horizontal
        h.spacing = Tok.App.settingsRowGap
        return h
    }
}
