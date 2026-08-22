import Cocoa

// MARK: - tab strip chrome (top workspace tabs)

/// NSTextField with Enter=commit / Escape=cancel while inline-editing.
final class RenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        font = .systemFont(ofSize: 12)
        textColor = Chrome.theme.foreground
        backgroundColor = Chrome.theme.selectionPill
        drawsBackground = true
        focusRingType = .none
        bezelStyle = .roundedBezel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(insertNewline(_:)):
            onCommit?()
            return true
        case #selector(cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

/// One top tab, two forms: quiet (session-bar pill, draw(_:) fill) or
/// capsule (Ghostty tray form — layer fill, trailing divider between
/// unselected neighbors). Hover reveals the close ✕, double-click (or
/// right-click) renames via herdr `tab.rename`.
final class TabSegmentView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String) -> Void)?

    enum Style {
        case quiet
        case capsule
    }

    private let style: Style
    private let labelField = NSTextField(labelWithString: "")
    /// Vertical separator at the trailing edge (capsule style only).
    private let divider = HairlineView()
    private var closeButton: IconButton?
    private var selected = false
    private var hovered = false
    private var trackedBounds: NSRect = .null
    private var clickCommitMonitor: Any?

    init(style: Style = .quiet) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true

        labelField.font = .systemFont(ofSize: 12)
        labelField.textColor = Chrome.theme.secondaryText
        labelField.lineBreakMode = .byTruncatingTail
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)

        // Separator between unselected neighbors (Ghostty tray form);
        // the selected pill swallows the dividers it touches.
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            // Ghostty's native tabs center the title; the trailing gap
            // keeps room so the hover close ✕ never overlaps it.
            labelField.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -8),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -26),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 10),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        divider.isHidden = true
    }

    override func layout() {
        super.layout()
        // Capsule tabs are fully round at both ends; quiet keeps the
        // small radius the session-bar pills use.
        layer?.cornerRadius = style == .capsule ? bounds.height / 2 : 6
    }

    /// Capsule fills ride the updateLayer path: setting backgroundColor
    /// during `configure` (render rebuilds happen before the view is in
    /// a layer-backed hierarchy) silently lands on nil and the fill is
    /// lost; `needsDisplay` defers the write to display time.
    override var wantsUpdateLayer: Bool { style == .capsule }

    override func updateLayer() {
        super.updateLayer()
        guard style == .capsule else { return }
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = fillForState(hovered: hovered)?.cgColor
    }

    /// Ghostty tray form: unselected tabs are transparent on the tray —
    /// hover is the only unselected fill; the selected pill stays dark.
    private func fillForState(hovered: Bool) -> NSColor? {
        if selected { return Chrome.theme.selectionPill }
        return hovered ? Chrome.theme.tabHoverFill : nil
    }

    private func applyStateFill(hovered: Bool) {
        guard style == .capsule else { return }
        layer?.backgroundColor = fillForState(hovered: hovered)?.cgColor
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(text: String, selected: Bool, showDivider: Bool = false) {
        self.selected = selected
        labelField.stringValue = text
        labelField.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        labelField.textColor = selected ? Chrome.theme.foreground : Chrome.theme.secondaryText
        divider.isHidden = !showDivider
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard style == .quiet, selected else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                     xRadius: 6, yRadius: 6).setClip()
        Chrome.theme.selectionPill.setFill()
        bounds.fill()
    }

    // Hover tracking rebuilt only on real geometry change (flicker loop
    // otherwise); the close ✕ is revealed only while hovered.
    override func updateTrackingAreas() {

        guard trackedBounds != bounds else { return }
        trackedBounds = bounds
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    private lazy var editField: RenameField = {
        let f = RenameField()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.isHidden = true
        f.onCommit = { [weak self] in self?.endInlineRename(commit: true) }
        f.onCancel = { [weak self] in self?.endInlineRename(commit: false) }
        addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            f.trailingAnchor.constraint(equalTo: leadingAnchor, constant: 130),
            f.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return f
    }()

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        if style == .capsule {
            applyStateFill(hovered: true)
        } else {
            // Hover must not downgrade a selected pill: segment rebuilds
            // under a stationary cursor re-fire enter, and the selection
            // would flash light until the mouse leaves.
            layer?.backgroundColor = selected
                ? Chrome.theme.selectionPill.cgColor
                : Chrome.theme.hoverPill.cgColor
        }
        // Pinned sessions (local) have no close affordance at all.
        guard onClose != nil else { return }
        guard let close = closeButton else {
            let b = IconButton.make("xmark", pointSize: 9) { [weak self] in
                self?.onClose?()
            }
            addSubview(b)
            NSLayoutConstraint.activate([
                b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                b.centerYAnchor.constraint(equalTo: centerYAnchor),
                b.widthAnchor.constraint(equalToConstant: 18),
                b.heightAnchor.constraint(equalToConstant: 18),
            ])

            closeButton = b
            return
        }
        close.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        if style == .capsule {
            applyStateFill(hovered: false)
        } else {
            layer?.backgroundColor = nil
        }
        closeButton?.isHidden = true
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 {
            beginInlineRename()
            return
        }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameAction), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeAction), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameAction() { beginInlineRename() }
    @objc private func closeAction() { onClose?() }

    /// Inline title editing: the label swaps for a bordered field; Enter
    /// commits (herdr `tab.rename`), Escape cancels, blur commits.
    func beginInlineRename() {
        guard onRename != nil, editField.isHidden else { return }
        editField.stringValue = labelField.stringValue
        labelField.isHidden = true
        editField.isHidden = false
        window?.makeFirstResponder(editField)
        editField.currentEditor()?.selectAll(nil)
        clickCommitMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.window {
                self.endInlineRename(commit: true)
            }
            return event
        }
    }

    fileprivate func endInlineRename(commit: Bool) {
        if let monitor = clickCommitMonitor {
            NSEvent.removeMonitor(monitor)
            clickCommitMonitor = nil
        }
        guard !editField.isHidden else { return }
        let name = editField.stringValue.trimmingCharacters(in: .whitespaces)
        editField.isHidden = true
        labelField.isHidden = false
        window?.makeFirstResponder(nil)
        if commit, !name.isEmpty, name != labelField.stringValue {
            labelField.stringValue = name
            onRename?(name)
        }
    }
}

/// Top strip covering herdr's own tab bar, Ghostty-native form: capsule
/// tabs ride a rounded tray that scrolls horizontally when they
/// overflow; the '+' sits as a round outlined control pinned at the end.
final class TabStripView: NSView {
    var onTabIdSelected: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onRenameTab: ((String, String) -> Void)?
    var onNewTab: (() -> Void)?

    private let tabScroll = NSScrollView()
    private let stack = NSStackView()
    private let plusButton = IconButton(frame: .zero)
    private var renderedState = ""

    init() {
        super.init(frame: .zero)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.setContentHuggingPriority(.required, for: .horizontal)

        tabScroll.drawsBackground = true
        tabScroll.backgroundColor = Chrome.theme.tabBarBackground
        tabScroll.borderType = .noBorder
        tabScroll.hasHorizontalScroller = true
        tabScroll.hasVerticalScroller = false
        tabScroll.autohidesScrollers = true
        tabScroll.scrollerStyle = .overlay
        tabScroll.horizontalScrollElasticity = .allowed
        tabScroll.verticalScrollElasticity = .none
        tabScroll.documentView = stack
        addSubview(tabScroll)
        // A zero-frame autoresizing subview would pin the strip (and
        // with it the whole window — the engine drives the window frame
        // back to the fitting width) to width 0.
        tabScroll.translatesAutoresizingMaskIntoConstraints = false

        plusButton.symbol = "plus"
        plusButton.pointSize = 10
        plusButton.tint = Chrome.theme.iconTint
        plusButton.isCircular = true
        plusButton.outlineColor = Chrome.theme.controlOutline
        plusButton.onClick = { [weak self] in self?.onNewTab?() }
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        addSubview(plusButton)

        let hairline = HairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        NSLayoutConstraint.activate([
            tabScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabScroll.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -8),
            tabScroll.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            tabScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.heightAnchor.constraint(equalToConstant: 20),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: tabScroll.contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Paint the full strip first so no AppKit backdrop leaks through;
        // the rounded tray then uses the same resolved theme color.
        Chrome.theme.topBarBackground.setFill()
        bounds.fill()
        let tray = NSRect(
            x: 4, y: 2,
            width: max(0, plusButton.frame.minX - 8 - 4),
            height: bounds.height - 4)
        NSBezierPath(roundedRect: tray,
                     xRadius: tray.height / 2, yRadius: tray.height / 2).setClip()
        Chrome.theme.tabBarBackground.setFill()
        tray.fill()
    }

    /// Rebuilds the segments; the scroll view keeps every tab reachable
    /// and the selected segment is brought into view after layout. The
    /// fingerprint guard keeps no-op snapshots from churning views.
    func render(tabs: [(id: String, name: String)], selectedId: String) {
        let state = selectedId + "\u{0}"
            + tabs.map { $0.id + "\u{0}" + $0.name }.joined(separator: "\u{1}")
        guard state != renderedState else { return }
        renderedState = state

        stack.arrangedSubviews.forEach { stack.removeView($0) }
        var selectedSegment: TabSegmentView?
        for (index, tab) in tabs.enumerated() {
            let segment = TabSegmentView(style: .capsule)
            let isSelected = tab.id == selectedId
            let nextSelected = index + 1 < tabs.count && tabs[index + 1].id == selectedId
            let showDivider = !isSelected && !nextSelected && index + 1 < tabs.count
            segment.configure(text: tab.name, selected: isSelected, showDivider: showDivider)
            segment.onClick = { [weak self] in self?.onTabIdSelected?(tab.id) }
            segment.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
            segment.onRename = { [weak self] name in self?.onRenameTab?(tab.id, name) }
            // Every segment shares the available strip width equally; the
            // minimum only bites once the total tab content overflows.
            segment.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            segment.setContentCompressionResistancePriority(.required, for: .horizontal)
            segment.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(segment)
            if isSelected { selectedSegment = segment }
        }
        guard let selectedSegment else { return }
        DispatchQueue.main.async { [weak self, weak selectedSegment] in
            guard let self, let selectedSegment,
                  let documentView = self.tabScroll.documentView else { return }
            let rect = selectedSegment.convert(selectedSegment.bounds, to: documentView)
            self.tabScroll.contentView.scrollToVisible(rect)
        }
    }
}
