import Cocoa

// MARK: - chrome primitives (shared drawing / interaction atoms)

/// Shared low-level chrome pieces every surface uses: the hairline
/// separator, the hover-lift SF Symbol button, menu-item icon tinting,
/// chrome row metrics, and the env-gated diagnostics sink. Colors come
/// from `Chrome.theme` (the mirror surface's resolved Ghostty config).
enum ChromeMetrics {
    static let twoLineRowHeight: CGFloat = 46   // workspace / agent card
    static let singleLineRowHeight: CGFloat = 40 // row without a meta line
}

/// 0.5pt separator drawn in draw(_:) — assigning layer?.background in
/// init silently no-ops when the layer doesn't exist yet.
final class HairlineView: NSView {
    var color: NSColor = Chrome.theme.hairline { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// Icon button: an SF Symbol glyph in an NSImageView — the system
/// rasterizes symbols natively at the live backing density. Transparent
/// at rest, contrast-lifted fill on hover. The glyph is re-applied
/// whenever the backing store changes (mixed-DPI stays sharp).
final class IconButton: NSView {
    var onClick: (() -> Void)?
    var tint: NSColor = .secondaryLabelColor { didSet { applyIcon() } }
    var pointSize: CGFloat = 13 { didSet { applyIcon() } }
    var symbol: String = "plus" { didSet { applyIcon() } }
    /// Round button (Ghostty '+' form): cornerRadius tracks the shorter
    /// side instead of the fixed 5pt.
    var isCircular = false
    /// Resting ring for buttons that read as controls (the tab strip
    /// '+'): outline + glyph, fill only while pressed. nil = bare glyph.
    var outlineColor: NSColor? { didSet { needsDisplay = true } }

    private let imageView = NSImageView()
    private var ownTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.unregisterDraggedTypes()
        addSubview(imageView)
        imageView.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        imageView.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        // Geometry changed → re-run updateLayer (cornerRadius follows
        // the shorter side).
        needsDisplay = true
    }

    /// Corner radius and the resting ring live on the updateLayer path —
    /// setting layer properties in init no-ops while the layer doesn't
    /// exist yet.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = isCircular
            ? min(bounds.width, bounds.height) / 2
            : 5
        layer?.borderWidth = outlineColor != nil ? 1 : 0
        layer?.borderColor = outlineColor?.cgColor
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyIcon()
    }

    private func applyIcon() {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) else {
            imageView.image = nil
            return
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [tint]))
        imageView.image = base.withSymbolConfiguration(cfg) ?? base
    }
    // Tracking is created ONCE: .inVisibleRect follows the frame, and
    // rebuilding tracking areas on every updateTrackingAreas call makes
    // AppKit re-fire mouseEntered — the hover flicker loop.
    private func installTrackingOnce() {
        guard ownTracking == nil else { return }
        let t = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        ownTracking = t
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTrackingOnce()
        applyIcon()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Chrome.theme.hoverFill.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) {
        // Outline buttons stay unfilled at rest and through hover — the
        // fill reads as the press itself.
        if outlineColor != nil {
            layer?.backgroundColor = Chrome.theme.hoverFill.cgColor
        }
        onClick?()
    }

    override func mouseUp(with event: NSEvent) {
        if outlineColor != nil {
            layer?.backgroundColor = nil
        }
    }

    static func make(_ symbol: String, pointSize: CGFloat = 13,
                     onClick: (() -> Void)? = nil) -> IconButton {
        let b = IconButton(frame: .zero)
        b.symbol = symbol
        b.pointSize = pointSize
        b.tint = Chrome.theme.iconTint
        b.onClick = onClick

        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

/// Menu-item icon: theme-tinted SF Symbol at menu scale (matches the
/// herdr-gui add-workspace menu style).
func menuItemIcon(_ symbol: String, pointSize: CGFloat = 10) -> NSImage? {
    NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(
            .init(pointSize: pointSize, weight: .regular)
                .applying(.init(paletteColors: [Chrome.theme.iconTint])))
}

