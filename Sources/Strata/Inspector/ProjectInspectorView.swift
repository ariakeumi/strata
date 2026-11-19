import AppKit

/// Shows a project folder’s type, build artifact sizes and runnable scripts. Updates measured sizes in place.
final class ProjectInspectorView: NSView {
    /// Overrides the built-in Run in Terminal.
    var onRunScript: ((ProjectScript) -> Void)?

    private(set) var info: ProjectInfo?
    let preferences: Prefs
    private let clipboard: Clipboard
    private let stack = NSStackView()
    private var showsAllScripts = false
    private var artifactRows: [String: ArtifactRow] = [:]
    private var artifactsTotalLabel: NSTextField?
    private static let collapsedScriptCount = 6

    init(frame: NSRect = .zero, preferences: Prefs, clipboard: Clipboard) {
        self.preferences = preferences
        self.clipboard = clipboard
        super.init(frame: frame)
        // Sections meet at the hairline, same as the Inspector's other cards.
        addColumn(stack, spacing: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ info: ProjectInfo?) {
        let previous = self.info
        self.info = info
        guard let info else {
            rebuild()
            return
        }
        if previous?.folder != info.folder { showsAllScripts = false }
        guard let previous, previous.folder == info.folder, previous.kinds == info.kinds, previous.scripts == info.scripts,
              previous.artifacts.map(\.id) == info.artifacts.map(\.id) else {
            rebuild()
            return
        }
        updateArtifacts()
    }

    // MARK: - Building

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        artifactRows = [:]
        artifactsTotalLabel = nil
        guard let info else { return }

        // Each part is a card like the Inspector's others, collapsed and expanded the same way.
        if !info.kinds.isEmpty {
            let chips = FlowView(spacing: 6, lineSpacing: 6)
            for kind in info.kinds { chips.add(KindChip(kind)) }
            let content = section()
            add(chips, to: content)
            addCard(id: "project", title: String(localized: "Project", comment: "Inspector section title: the folder's software project"),
                    symbol: "chevron.left.forwardslash.chevron.right", content: content)
        }
        if !info.artifacts.isEmpty { buildArtifacts(info.artifacts) }
        if !info.scripts.isEmpty { buildScripts(info.scripts) }
        updateArtifacts()
    }

    private func buildArtifacts(_ artifacts: [ProjectArtifact]) {
        let total = label("", size: 11, color: InspectorColors.secondary, monospacedDigits: true)
        artifactsTotalLabel = total
        let content = section()
        for artifact in artifacts {
            let row = ArtifactRow(artifact)
            artifactRows[artifact.id] = row
            add(row, to: content, spacingAfter: 2)
        }
        addCard(id: "artifacts", title: String(localized: "Build Artifacts", comment: "Inspector section title: regenerable build output folders"),
                symbol: "shippingbox", content: content, accessory: total)
    }

    private func buildScripts(_ scripts: [ProjectScript]) {
        // One group per file the scripts came from, in detection order.
        var sources: [String] = []
        for script in scripts where !sources.contains(script.source) { sources.append(script.source) }
        let runnerName = scripts.first.map { $0.source == "package.json" ? $0.runner.rawValue : "" } ?? ""
        let content = section()

        let limit = showsAllScripts ? Int.max : Self.collapsedScriptCount
        var shown = 0
        for source in sources {
            let group = scripts.filter { $0.source == source }
            if sources.count > 1, shown < limit {
                let title = source == "package.json" ? "package.json · \(group[0].runner.rawValue)" : source
                add(inset(label(title, size: 10.5, weight: .medium, color: InspectorColors.tertiary), by: ScriptRow.inset), to: content, spacingAfter: 2)
            }
            for script in group where shown < limit {
                let row = ScriptRow(script, clipboard: clipboard)
                row.onRun = { [weak self] in self?.run(script) }
                add(row, to: content, spacingAfter: 1)
                shown += 1
            }
            if let last = content.arrangedSubviews.last, sources.count > 1 { content.setCustomSpacing(8, after: last) }
        }
        if scripts.count > shown {
            let more = NSButton(title: String(localized: "Show \(scripts.count - shown) More", comment: "plural"), target: self,
                                action: #selector(showMoreScripts))
            more.isBordered = false
            more.font = .systemFont(ofSize: 11, weight: .medium)
            more.contentTintColor = InspectorColors.accent
            more.attributedTitle = NSAttributedString(string: more.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: InspectorColors.accent,
            ])
            add(inset(more, by: ScriptRow.inset - 1), to: content)
        }
        addCard(id: "scripts", title: String(localized: "Scripts", comment: "Inspector section title: runnable project scripts"),
                symbol: "terminal", content: content,
                accessory: sources.count == 1 && !runnerName.isEmpty ? label(runnerName, size: 11, color: InspectorColors.tertiary) : nil)
    }

    // MARK: - Artifacts state

    private func updateArtifacts() {
        guard let info else { return }
        for artifact in info.artifacts {
            artifactRows[artifact.id]?.updateSize(of: artifact)
        }
        let all = info.artifacts
        let known = all.compactMap(\.bytes).saturatingSum
        artifactsTotalLabel?.stringValue = info.isMeasuring
            ? (known > 0 ? String(localized: "\(Format.bytes(known))+", comment: "A total size still being measured: at least this much") : "")
            : Format.bytes(known)
    }

    private func run(_ script: ProjectScript) {
        if let onRunScript { return onRunScript(script) }
        let project = info?.folder.lastPathComponent
        let preferences = preferences
        Task { if !(await ProjectActions.runInTerminal(script, projectName: project, preferences: preferences)) { Sounds.beep() } }
    }

    @objc private func showMoreScripts() {
        showsAllScripts = true
        rebuild()
    }

    // MARK: - Helpers

    /// The rows of one card, top to bottom.
    private func section() -> NSStackView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        return content
    }

    private func addCard(id: String, title: String, symbol: String, content: NSStackView, accessory: NSView? = nil) {
        let card = InspectorCard(id: id, title: title, symbol: symbol, content: content, accessory: accessory,
                                 preferences: preferences)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func add(_ view: NSView, to content: NSStackView, spacingAfter spacing: CGFloat = 6) {
        content.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.setCustomSpacing(spacing, after: view)
    }

    /// `view` shifted right, to line up with the script names inside their hover background.
    private func inset(_ view: NSView, by amount: CGFloat) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: amount),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}

// MARK: - Pieces

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                   monospacedDigits: Bool = false, monospaced: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight)
        : monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

/// Lays out its subviews left to right, wrapping to new lines; height follows the width it's given.
final class FlowView: NSView {
    private let spacing: CGFloat
    private let lineSpacing: CGFloat
    private var lastWidth: CGFloat = 0

    init(spacing: CGFloat, lineSpacing: CGFloat) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    func add(_ view: NSView) {
        addSubview(view)
        invalidateIntrinsicContentSize()
    }

    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.intrinsicContentSize
            let w = min(size.width, max(width, 1))
            if x > 0, x + w > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if apply { view.frame = NSRect(x: x, y: y, width: w, height: size.height) }
            x += w + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return y + lineHeight
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: arrange(width: bounds.width > 0 ? bounds.width : 10_000, apply: false))
    }

    override func layout() {
        super.layout()
        _ = arrange(width: bounds.width, apply: true)
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A capsule naming one project kind: symbol, name, and the package manager or build system in secondary text.
private final class KindChip: NSView {
    private let symbol: NSImage?
    private let text: NSAttributedString

    init(_ info: ProjectKindInfo) {
        symbol = NSImage(systemSymbolName: info.kind.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [InspectorColors.secondary])))
        let text = NSMutableAttributedString(string: info.kind.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: InspectorColors.primary,
        ])
        if let detail = info.detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: InspectorColors.secondary,
            ]))
        }
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(info.detail.map { "\(info.kind.title), \($0)" } ?? info.kind.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(8 + 14 + 4 + text.size().width + 9), height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        InspectorColors.primary.withAlphaComponent(dark ? 0.10 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        if let symbol {
            let s = symbol.size
            symbol.draw(in: NSRect(x: 8 + (14 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let size = text.size()
        text.draw(at: NSPoint(x: 8 + 14 + 4, y: (bounds.height - size.height) / 2))
    }
}

/// A build artifact’s name and measured size.
private final class ArtifactRow: NSView {
    private let nameLabel: NSTextField
    private let sizeLabel = label("", size: 11, color: InspectorColors.secondary, monospacedDigits: true)
    private let spinner = NSProgressIndicator()

    init(_ artifact: ProjectArtifact) {
        let name = NSMutableAttributedString(string: artifact.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: InspectorColors.primary,
        ])
        if artifact.urls.count > 1 {
            name.append(NSAttributedString(string: "  ×\(artifact.urls.count)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: InspectorColors.tertiary,
            ]))
        }
        if artifact.role == .environment {
            name.append(NSAttributedString(string: "  " + String(localized: "environment", comment: "Note after a build folder's name: it's a virtual environment"), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: InspectorColors.tertiary,
            ]))
        }
        nameLabel = NSTextField(labelWithAttributedString: name)
        super.init(frame: .zero)

        let icon = NSImageView(image: NSWorkspace.shared.icon(for: .folder))
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sizeLabel.alignment = .right
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        toolTip = artifact.urls.map { Format.tildePath($0) }.joined(separator: "\n")

        for view in [icon, nameLabel, sizeLabel, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateSize(of: artifact)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateSize(of artifact: ProjectArtifact) {
        if let bytes = artifact.bytes {
            sizeLabel.stringValue = Format.bytes(bytes)
            spinner.stopAnimation(nil)
        } else {
            sizeLabel.stringValue = ""
            spinner.startAnimation(nil)
        }
        let size = artifact.bytes.map(Format.bytes)
            ?? String(localized: "measuring", comment: "Accessibility: the folder's size is still being measured")
        setAccessibilityLabel("\(artifact.name), \(size)")
    }
}

/// Script name over its command (monospaced, secondary), with a play button that runs it in a terminal.
private final class ScriptRow: NSView {
    /// Text inset inside the row's hover background.
    static let inset: CGFloat = 6
    var onRun: (() -> Void)?
    private let script: ProjectScript
    private let clipboard: Clipboard
    private let runButton = NSButton()
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(_ script: ProjectScript, clipboard: Clipboard) {
        self.script = script
        self.clipboard = clipboard
        super.init(frame: .zero)
        let name = label(script.name, size: 12, weight: .medium, color: InspectorColors.primary)
        // Prose (## help, doc comments) in the text font; commands monospaced.
        let command = script.summary.map { label($0, size: 11, color: InspectorColors.secondary) }
            ?? label(script.command.isEmpty ? script.invocation : script.command, size: 10.5, color: InspectorColors.secondary,
                     monospaced: true)
        command.lineBreakMode = .byTruncatingTail
        runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: String(localized: "Run \(script.name) in Terminal"))
        runButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        runButton.isBordered = false
        runButton.imagePosition = .imageOnly
        runButton.contentTintColor = InspectorColors.secondary
        runButton.target = self
        runButton.action = #selector(runClicked)
        runButton.toolTip = String(localized: "Run “\(script.invocation)” in Terminal", comment: "Tooltip; the placeholder is a shell command")
        toolTip = ([script.invocation] + [script.summary, script.command.isEmpty ? nil : script.command].compactMap { $0 })
            .joined(separator: "\n")

        for view in [name, command, runButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            name.trailingAnchor.constraint(lessThanOrEqualTo: runButton.leadingAnchor, constant: -6),
            command.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            command.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 0),
            command.trailingAnchor.constraint(lessThanOrEqualTo: runButton.leadingAnchor, constant: -6),
            runButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            runButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            runButton.widthAnchor.constraint(equalToConstant: 22),
            runButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(script.name): \(script.summary ?? script.command)")
        menu = makeMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        InspectorColors.primary.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        hovering = on
        runButton.contentTintColor = on ? InspectorColors.accent : InspectorColors.secondary
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRun?() }
    }

    @objc private func runClicked() { onRun?() }

    override func accessibilityPerformPress() -> Bool {
        onRun?()
        return true
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let run = NSMenuItem(title: String(localized: "Run in Terminal"), action: #selector(runClicked), keyEquivalent: "")
        run.target = self
        run.image = NSImage(systemSymbolName: "play", accessibilityDescription: nil)
        menu.addItem(run)
        let copy = NSMenuItem(title: String(localized: "Copy Command", comment: "Menu command: copy the script's shell command"), action: #selector(copyCommand), keyEquivalent: "")
        copy.target = self
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copy)
        return menu
    }

    @objc private func copyCommand() {
        clipboard.copyText(script.invocation)
    }
}
