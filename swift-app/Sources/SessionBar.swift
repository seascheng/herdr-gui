import Cocoa

// MARK: - top session bar (server tabs + servers menu)

/// Window-level top strip: one pill per open session (click to switch,
/// hover ✕ to close) and the servers menu button pinned at the trailing
/// edge. Per-session herdr tabs live one level down, on each herdr page.
final class SessionBarView: NSView {
    var onSessionSelected: ((Int) -> Void)?
    var onSessionClosed: ((Int) -> Void)?
    /// Supplies the servers menu on demand; it pops anchored below the
    /// server.rack button, reference-style (popUp at .zero, in: button).
    var serversMenuProvider: (() -> NSMenu)?
    private let stack = NSStackView()
    private let serversButton = IconButton(frame: .zero)
    private var renderedState = ""
    private let hairline = HairlineView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        // Sessions size to their labels (unlike herdr tabs, which
        // deliberately share the row width equally).
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        serversButton.symbol = "server.rack"
        serversButton.pointSize = 13
        serversButton.onClick = { [weak self] in
            guard let self,
                  let menu = self.serversMenuProvider?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self.serversButton)
        }
        serversButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(serversButton)

        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        NSLayoutConstraint.activate([
            // Traffic lights (~70pt) sit in this strip on the left; the
            // stack hugs its content from there (no trailing pin — that
            // would let gravity distribution center the pills).
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 82),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            serversButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            serversButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            serversButton.widthAnchor.constraint(equalToConstant: 32),
            serversButton.heightAnchor.constraint(equalToConstant: 24),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.theme.topBarBackground.setFill()
        bounds.fill()
    }

    /// Diffed rebuild of the session pills.
    func render(sessions: [SessionSpec], activeId: String) {
        let state = activeId + "\u{0}"
            + sessions.map { $0.id + "\u{0}" + $0.label }.joined(separator: "\u{1}")
        guard state != renderedState else { return }
        renderedState = state

        stack.arrangedSubviews.forEach { stack.removeView($0) }
        for (index, spec) in sessions.enumerated() {
            let segment = TabSegmentView()
            segment.configure(text: spec.label, selected: spec.id == activeId)
            segment.onClick = { [weak self] in self?.onSessionSelected?(index) }
            // The local session is pinned: no close affordance.
            if case .local = spec.target {
                segment.onClose = nil
            } else {
                segment.onClose = { [weak self] in self?.onSessionClosed?(index) }
            }
            // Session names come from ssh config aliases — renaming a
            // session label would desync from the menu, so disable it.
            segment.onRename = nil
            stack.addArrangedSubview(segment)
            // Readable minimum for short labels ("Local"); longer labels
            // keep their intrinsic width.
            segment.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        }
}
}
