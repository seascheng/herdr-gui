import Cocoa

// MARK: - sidebar chrome (spaces / agents panels)

/// Section header (uppercase, letter-spaced) with an inline trailing
/// '+' that adds within the section.
final class SectionHeaderView: NSView {
    let label = NSTextField(labelWithString: "")
    private(set) var plus: IconButton?

    init(_ text: String, plusAction: (() -> Void)? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: Chrome.theme.secondaryText,
                .kern: 1.1,
            ])
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])

        if let plusAction {
            let b = IconButton.make("plus", pointSize: 11, onClick: plusAction)
            addSubview(b)
            NSLayoutConstraint.activate([
                b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                b.centerYAnchor.constraint(equalTo: centerYAnchor),
                b.widthAnchor.constraint(equalToConstant: 20),
                b.heightAnchor.constraint(equalToConstant: 18),
                label.trailingAnchor.constraint(lessThanOrEqualTo: b.leadingAnchor, constant: -6),
            ])
            plus = b
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func setTitle(_ text: String) {
        label.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: Chrome.theme.secondaryText,
                .kern: 1.1,
            ])
    }
}

/// Icon → SF Symbol catalog for known CLI agents (tty7's CLIAgent table,
/// adapted from the herdr-gui reference). Matches on the agent kind
/// string; unknown agents fall back to the cpu glyph.
enum AgentIconCatalog {
    static let map: [String: String] = [
        "claude": "sparkles",
        "codex": "curlybraces",
        "omp": "brain.head.profile",
        "pi": "function",
        "opencode": "chevron.left.forwardslash.chevron.right",
        "gemini": "diamond",
        "grok": "bolt",
        "aider": "wrench.and.screwdriver",
        "goose": "bird",
        "copilot": "person.crop.circle",
        "crush": "hexagon",
        "sgpt": "ant.fill",
        "droid": "terminal.fill",
    ]

    static func icon(for kind: String?) -> String {
        guard let key = kind?.lowercased(), !key.isEmpty else { return "cpu" }
        if let exact = map[key] { return exact }
        for (name, symbol) in map where key.contains(name) { return symbol }
        return "cpu"
    }
}

/// One sidebar row: leading SF Symbol icon, title, optional dim meta
/// line, trailing status dot; rounded translucent selection pill when
/// active (herdr-gui reference form). herdr's status semantics carry
/// over: working ● yellow, blocked ● red, done ● teal, idle ● green,
/// unknown ● gray — one dot size, color carries the state.
final class SidebarRowView: NSView {
    private let click: () -> Void
    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let dotView = DotView()
    private var pillColor: NSColor = .clear
    private var hovered = false
    private var trackedBounds: NSRect = .null
    private var heightConstraint: NSLayoutConstraint?
    private var menuProvider: (() -> NSMenu)?

    final class DotView: NSView {
        var fill: NSColor = .systemGreen
        override func draw(_ dirtyRect: NSRect) {
            fill.setFill()
            let side: CGFloat = 6
            let rect = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                              width: side, height: side)
            NSBezierPath(ovalIn: rect).fill()
        }
    }


    init(click: @escaping () -> Void) {
        self.click = click
        super.init(frame: .zero)

        heightConstraint = heightAnchor.constraint(
            equalToConstant: ChromeMetrics.twoLineRowHeight)
        heightConstraint?.isActive = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.unregisterDraggedTypes()
        addSubview(iconView)

        labelField.font = .systemFont(ofSize: 12.5)
        labelField.textColor = .secondaryLabelColor
        labelField.lineBreakMode = .byTruncatingTail

        metaField.font = .systemFont(ofSize: 10)
        metaField.textColor = Chrome.theme.secondaryText
        metaField.lineBreakMode = .byTruncatingTail

        // Text block centers as a unit against the icon's midline — both
        // single-line and two-line rows stay horizontally aligned.
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.addArrangedSubview(labelField)
        textStack.addArrangedSubview(metaField)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: dotView.leadingAnchor, constant: -6),
            dotView.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 7),
            dotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(text: String, meta: String?, icon symbol: String, status: String,
                   selected: Bool, menuProvider: (() -> NSMenu)? = nil) {
        self.menuProvider = menuProvider
        let twoLine = !(meta ?? "").isEmpty
        heightConstraint?.constant = twoLine
            ? ChromeMetrics.twoLineRowHeight : ChromeMetrics.singleLineRowHeight
        metaField.stringValue = meta ?? ""
        metaField.isHidden = !twoLine
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.contentTintColor = selected
            ? Chrome.theme.foreground
            : Chrome.theme.secondaryText.withAlphaComponent(0.8)

        labelField.stringValue = text
        labelField.font = .systemFont(ofSize: 12.5, weight: selected ? .semibold : .regular)
        pillColor = selected ? Chrome.theme.selectionPill : .clear
        labelField.textColor = selected ? Chrome.theme.foreground : Chrome.theme.secondaryText
        dotView.fill = Chrome.theme.statusColor(status)
        dotView.needsDisplay = true
        needsDisplay = true
    }

    /// Diagnostics-only (HERDR_DUMP_VIEWS layout self-check).
    func labelWidthForDiagnostics() -> CGFloat { labelField.frame.width }

    /// Brand glyph override (official tool logo) for the SF fallback.
    func setIconImage(_ image: NSImage) {
        iconView.image = image
    }

    override func draw(_ dirtyRect: NSRect) {
        // Rounded shape is shared by both states: selection pill, hover
        // fill (agents rows included).
        let fill: NSColor? = pillColor != .clear
            ? pillColor
            : (hovered ? Chrome.theme.hoverFill : nil)
        guard let fill else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                     xRadius: 7, yRadius: 7).setClip()
        fill.setFill()
        bounds.fill()
    }

    // Hover tracking rebuilt only on real geometry change; rebuilding on
    // every updateTrackingAreas re-fires mouseEntered — hover flicker.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackedBounds != bounds else { return }
        trackedBounds = bounds
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { click() }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// 5pt drag strip for adjusting the sidebar width (herdr-gui reference).
final class WidthHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var startWidth: CGFloat = 0
    private var startLoc = NSPoint.zero

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let sidebar = superview, sidebar.bounds.width > 60 else { return }
        startWidth = sidebar.bounds.width
        startLoc = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(startWidth + NSEvent.mouseLocation.x - startLoc.x)
    }
}

/// One collapsed-rail tile: a status dot that focuses its workspace.
final class RailWorkspaceDot: NSView {
    private let dot = SidebarRowView.DotView()
    private let click: () -> Void
    private var hovered = false
    private var trackedBounds = NSRect.null

    init(click: @escaping () -> Void) {
        self.click = click
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        dot.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        dot.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(status: String, selected: Bool) {
        dot.fill = Chrome.theme.statusColor(status)
        dot.needsDisplay = true
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = Chrome.theme.foreground.withAlphaComponent(0.6).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            Chrome.theme.hoverPill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackedBounds != bounds else { return }
        trackedBounds = bounds
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { click() }
}

/// herdr's own sidebar structure: workspace list over the agents panel,
/// separated by a hairline — a plain top-aligned column, no scrolling.
/// Collapses to a narrow rail of workspace status dots; width is
/// drag-adjustable via the right-edge handle.
final class SidebarView: NSView {
    var onWorkspaceSelected: ((String) -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onReloadConfig: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenKeybinds: (() -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    var onAgentSelected: ((String) -> Void)?
    var onCloseWorkspace: ((String) -> Void)?
    var onNewWorkspace: (() -> Void)?
    private(set) var isCollapsed = false
    private let column = NSStackView()
    private let rail = NSStackView()
    private let wordmark = NSTextField(labelWithString: "hertty")
    private let widthHandle = WidthHandle()
    private let launcher = IconButton(frame: .zero)
    private lazy var collapseToggle: IconButton = IconButton.make(
        "sidebar.leading", pointSize: 13) { [weak self] in
            self?.onToggleCollapse?()
        }
    private lazy var spacesHeader: SectionHeaderView = SectionHeaderView("Spaces") { [weak self] in
        self?.onNewWorkspace?()
    }
    private lazy var agentsHeader: SectionHeaderView = SectionHeaderView("Agents")
    private let wsStack = NSStackView()
    private let agentStack = NSStackView()
    private var renderedState = ""

    /// Session target name (Local / ssh alias) shown as the sidebar title.
    var serverLabel: String = "hertty" {
        didSet { wordmark.stringValue = serverLabel }
    }

    init() {
        super.init(frame: .zero)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        for stack in [wsStack, agentStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
        }

        let topSpacer = NSView()
        topSpacer.translatesAutoresizingMaskIntoConstraints = false
        // The wordmark is centered and the toggle trails — both clear of
        // the traffic lights horizontally — so the row hugs the top.
        topSpacer.heightAnchor.constraint(equalToConstant: 7).isActive = true

        // Wordmark row: centered name, collapse toggle at the trailing
        // edge — both clear of the traffic lights above.
        wordmark.font = .systemFont(ofSize: 13, weight: .semibold)
        wordmark.textColor = Chrome.theme.foreground
        wordmark.alignment = .center
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        wordmark.lineBreakMode = .byTruncatingMiddle

        collapseToggle.translatesAutoresizingMaskIntoConstraints = false
        let wordmarkRow = NSView()
        wordmarkRow.translatesAutoresizingMaskIntoConstraints = false
        wordmarkRow.addSubview(wordmark)
        wordmarkRow.addSubview(collapseToggle)
        NSLayoutConstraint.activate([
            wordmark.centerXAnchor.constraint(equalTo: wordmarkRow.centerXAnchor),
            wordmark.centerYAnchor.constraint(equalTo: wordmarkRow.centerYAnchor),
            collapseToggle.trailingAnchor.constraint(equalTo: wordmarkRow.trailingAnchor, constant: -2),
            collapseToggle.centerYAnchor.constraint(equalTo: wordmarkRow.centerYAnchor),
            collapseToggle.widthAnchor.constraint(equalToConstant: 24),
            collapseToggle.heightAnchor.constraint(equalToConstant: 22),
            wordmarkRow.heightAnchor.constraint(equalToConstant: 22),
        ])

        let divider = HairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(topSpacer)
        column.addArrangedSubview(wordmarkRow)
        column.addArrangedSubview(spacesHeader)
        column.addArrangedSubview(wsStack)
        column.addArrangedSubview(divider)
        column.addArrangedSubview(agentsHeader)
        column.addArrangedSubview(agentStack)
        column.setCustomSpacing(4, after: topSpacer)
        column.setCustomSpacing(12, after: wordmarkRow)
        column.setCustomSpacing(8, after: spacesHeader)
        column.setCustomSpacing(12, after: wsStack)
        column.setCustomSpacing(8, after: divider)
        column.setCustomSpacing(8, after: agentsHeader)

        for row in [topSpacer, wordmarkRow, spacesHeader, divider, agentsHeader] {
            row.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        }

        // Collapsed rail: expand toggle over one status dot per workspace.
        rail.orientation = .vertical
        rail.alignment = .centerX
        rail.spacing = 2
        rail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rail)
        let railToggle = IconButton.make("sidebar.leading", pointSize: 13) { [weak self] in
            self?.onToggleCollapse?()
        }
        railToggle.translatesAutoresizingMaskIntoConstraints = false
        let railSpacer = NSView()
        railSpacer.translatesAutoresizingMaskIntoConstraints = false
        // Pages start below the session bar (which carries the traffic
        // lights), so the rail hugs the top like the expanded column.
        railSpacer.heightAnchor.constraint(equalToConstant: 7).isActive = true
        rail.addArrangedSubview(railSpacer)
        rail.addArrangedSubview(railToggle)
        rail.setCustomSpacing(4, after: railSpacer)
        railToggle.widthAnchor.constraint(equalToConstant: 26).isActive = true
        railToggle.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // Width drag handle over the right hairline.
        widthHandle.onDrag = { [weak self] width in
            self?.onWidthChange?(width)
        }
        widthHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(widthHandle)

        let hairline = HairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        // Bottom-right launcher, mirroring herdr's own sidebar "menu":
        // native actions where the server API has them, the TUI menu for
        // the rest (rendered inside the mirror).
        launcher.symbol = "line.3.horizontal"
        launcher.onClick = { [weak self] in
            if ProcessInfo.processInfo.environment["HERDR_DUMP_VIEWS"] == "1" {
                DiagLog.views("LAUNCHER CLICKED frame=\(self?.launcher.frame ?? .zero)\n")
            }
            self?.popLauncherMenu()
        }
        launcher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(launcher)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: hairline.leadingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: hairline.leadingAnchor),
            rail.topAnchor.constraint(equalTo: topAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
            widthHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthHandle.topAnchor.constraint(equalTo: topAnchor),
            widthHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthHandle.widthAnchor.constraint(equalToConstant: 5),
            divider.heightAnchor.constraint(equalToConstant: 1),
            launcher.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            launcher.trailingAnchor.constraint(equalTo: hairline.leadingAnchor, constant: -6),
            launcher.widthAnchor.constraint(equalToConstant: 28),
            launcher.heightAnchor.constraint(equalToConstant: 22),
        ])
        rail.isHidden = true
    }

    private func popLauncherMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        settings.image = menuItemIcon("gearshape")
        menu.addItem(settings)
        let keybinds = NSMenuItem(title: "Keybinds…",
                                  action: #selector(keybindsAction), keyEquivalent: "")
        keybinds.target = self
        keybinds.image = menuItemIcon("keyboard")
        menu.addItem(keybinds)
        let reload = NSMenuItem(title: "Reload Config",
                                action: #selector(reloadConfigAction), keyEquivalent: "")
        reload.target = self
        reload.image = menuItemIcon("arrow.clockwise")
        menu.addItem(reload)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: launcher)
    }

    @objc private func settingsAction() { onOpenSettings?() }
    @objc private func keybindsAction() { onOpenKeybinds?() }
    @objc private func reloadConfigAction() { onReloadConfig?() }

    /// Collapsed = narrow rail (toggle + workspace dots); the width
    /// constraint itself is owned by the app delegate.
    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        column.isHidden = collapsed
        rail.isHidden = !collapsed
        widthHandle.isHidden = collapsed
        collapseToggle.symbol = collapsed ? "sidebar.trailing" : "sidebar.leading"
        needsDisplay = true
    }

    private func rebuildRail(workspaces: [SidebarWorkspaceModel], focusedWorkspaceId: String?) {
        rail.arrangedSubviews.dropFirst(2).forEach { rail.removeView($0) }
        for ws in workspaces {
            let dot = RailWorkspaceDot { [weak self] in
                self?.onWorkspaceSelected?(ws.id)
            }
            dot.configure(status: ws.status, selected: ws.id == focusedWorkspaceId)
            rail.addArrangedSubview(dot)
            dot.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.theme.topBarBackground.setFill()
        bounds.fill()
    }

    private func addRow(_ stack: NSStackView, _ make: () -> SidebarRowView) {
        let row = make()
        stack.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }

    /// Rebuilds both sections from the snapshot model. The fingerprint
    /// guard keeps no-op snapshots (2s fallback poll) from churning rows.
    func render(workspaces: [SidebarWorkspaceModel], focusedWorkspaceId: String?,
                agents: [SidebarAgentModel], focusedTabId: String?) {
        let wsPart = workspaces.map { "\($0.id)|\($0.label)|\($0.tabCount)|\($0.status)" }
            .joined(separator: "\u{1}")
        let agentPart = agents.map { "\($0.name)|\($0.status)|\($0.iconKind)|\($0.tabId)" }
            .joined(separator: "\u{1}")
        let state = wsPart + "\u{0}" + (focusedWorkspaceId ?? "") + "\u{0}"
            + (focusedTabId ?? "") + "\u{0}" + agentPart
        guard state != renderedState else { return }
        renderedState = state
        rebuildRail(workspaces: workspaces, focusedWorkspaceId: focusedWorkspaceId)

        wsStack.arrangedSubviews.forEach { wsStack.removeView($0) }
        for ws in workspaces {
            let status = ws.status
            addRow(wsStack) {
                let row = SidebarRowView { [weak self] in
                    self?.onWorkspaceSelected?(ws.id)
                }
                row.configure(
                    text: ws.label,
                    meta: "\(ws.tabCount) tab\(ws.tabCount == 1 ? "" : "s")",
                    icon: "square.grid.2x2",
                    status: status,
                    selected: ws.id == focusedWorkspaceId,
                    menuProvider: { [weak self] in
                        let menu = NSMenu()
                        let close = NSMenuItem(title: "Close Workspace…",
                                               action: #selector(Self.closeWsAction),
                                               keyEquivalent: "")
                        close.target = self
                        close.representedObject = ws.id
                        menu.addItem(close)
                        return menu
                    })
                return row
            }
        }

        agentsHeader.setTitle(agents.isEmpty ? "Agents" : "Agents (\(agents.count))")
        agentStack.arrangedSubviews.forEach { agentStack.removeView($0) }
        if agents.isEmpty {
            addRow(agentStack) {
                let row = SidebarRowView {}
                row.configure(text: "no agents", meta: nil, icon: "cpu",
                              status: "unknown", selected: false)
                return row
            }
        }
        for agent in agents {
            addRow(agentStack) {
                let row = SidebarRowView { [weak self] in
                    self?.onAgentSelected?(agent.tabId)
                }
                row.configure(
                    text: agent.name,
                    meta: agent.contextLine,
                    icon: AgentIconCatalog.icon(for: agent.iconKind),
                    status: agent.status,
                    selected: agent.tabId == focusedTabId,
                    menuProvider: { [weak self] in
                        let menu = NSMenu()
                        let focus = NSMenuItem(title: "Focus Tab",
                                               action: #selector(Self.agentFocusAction),
                                               keyEquivalent: "")
                        focus.target = self
                        focus.representedObject = agent.tabId
                        menu.addItem(focus)
                        return menu
                    })
                if let brand = AgentBrandIcons.image(for: agent.iconKind) {
                    row.setIconImage(brand)
                }
                return row
            }
        }
        if ProcessInfo.processInfo.environment["HERDR_DUMP_VIEWS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.dumpLayoutForDiagnostics(rows: workspaces.count)
            }
        }
    }

    /// Agent row's second line comes precomposed by the page layer
    /// (status · state label / title / cwd) — the view renders it as-is.

    private func dumpLayoutForDiagnostics(rows: Int) {
        if ProcessInfo.processInfo.environment["HERDR_DUMP_VIEWS"] != "1" { return }
        var out = "SIDEBAR bounds=\(Int(bounds.width))x\(Int(bounds.height))\n"
        func dump(_ v: NSView, depth: Int) {
            let f = v.frame
            let name = String(describing: type(of: v))
            let text = (v as? NSTextField)?.stringValue ?? ""
            out += String(repeating: " ", count: depth * 2)
                + "\(name) [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]"
                + (text.isEmpty ? "" : " '\(text)'") + "\n"
            if depth < 4 { v.subviews.forEach { dump($0, depth: depth + 1) } }
        }
        subviews.forEach { dump($0, depth: 1) }
        out += "\n"
        DiagLog.views(out)
    }

    @objc private func closeWsAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onCloseWorkspace?(id) }
    }

    @objc private func agentFocusAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onAgentSelected?(id) }
    }
}
