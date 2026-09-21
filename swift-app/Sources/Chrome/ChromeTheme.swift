import Cocoa

// MARK: - Chrome theme (follows the mirror surface's Ghostty config)

/// The native chrome follows the terminal's theme: colors are read from
/// the RESOLVED Ghostty config — the same one the mirror surface renders
/// with — so the sidebar / tab strip match whatever theme runs in the
/// terminal. Derived surfaces (top bar, hairline, hover, selection pill)
/// follow the tty7 chrome recipe from the herdr-gui reference.
struct ChromeTheme {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor

    static let fallback = ChromeTheme(
        background: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        foreground: NSColor(srgbRed: 0.87, green: 0.87, blue: 0.87, alpha: 1),
        accent: NSColor(srgbRed: 0.30, green: 0.30, blue: 0.30, alpha: 1))

    /// Chrome from the active cell theme: background/foreground carry
    /// over; the cursor color doubles as the accent.
    static func from(_ cellTheme: CellTheme) -> ChromeTheme {
        func color(_ packed: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((packed >> 16) & 255) / 255,
                    green: CGFloat((packed >> 8) & 255) / 255,
                    blue: CGFloat(packed & 255) / 255, alpha: 1)
        }
        return ChromeTheme(
            background: color(cellTheme.background),
            foreground: color(cellTheme.foreground),
            accent: color(cellTheme.cursor))
    }

    /// The `theme =` name from the config ghostty actually loads — our
    /// own-home copy first, then the user's live Ghostty configs.
    static func configuredThemeName() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/Library/Application Support/herdr-gui/ghostty/config",
            home + "/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            home + "/Library/Application Support/com.mitchellh.ghostty/config",
            home + "/.config/ghostty/config",
        ]
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == "theme" else { continue }
                return parts[1].split(separator: ",").first
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    /// `#rrggbb` / `#rgb` theme-file colors.
    private static func hexColor(_ hex: String) -> NSColor? {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 3 || value.count == 6,
              let parsed = UInt64(value, radix: 16) else { return nil }
        if value.count == 3 {
            let r = CGFloat((parsed >> 8) & 0xF) / 15, g = CGFloat((parsed >> 4) & 0xF) / 15,
                b = CGFloat(parsed & 0xF) / 15
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        let r = CGFloat((parsed >> 16) & 0xFF) / 255, g = CGFloat((parsed >> 8) & 0xFF) / 255,
            b = CGFloat(parsed & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    var isDark: Bool {
        let c = background.usingColorSpace(.deviceRGB) ?? background
        return c.brightnessComponent < 0.5
    }

    private func blend(_ base: NSColor, with other: NSColor, fraction t: CGFloat) -> NSColor {
        let b = base.usingColorSpace(.deviceRGB)!, o = other.usingColorSpace(.deviceRGB)!
        return NSColor(srgbRed: b.redComponent + (o.redComponent - b.redComponent) * t,
                       green: b.greenComponent + (o.greenComponent - b.greenComponent) * t,
                       blue: b.blueComponent + (o.blueComponent - b.blueComponent) * t,
                       alpha: 1)
    }

    /// Sidebar / top strip surface: one step lighter (dark themes) or
    /// darker (light) than the terminal background — a quiet boundary.
    var topBarBackground: NSColor {
        isDark ? blend(background, with: NSColor.white, fraction: 0.05)
               : blend(background, with: NSColor.black, fraction: 0.05)
    }

    /// The herdr tab bar band: one step beyond the sidebar surface, so
    /// the row reads as its own bar with the capsule tabs on top of it.
    var tabBarBackground: NSColor {
        isDark ? blend(background, with: NSColor.white, fraction: 0.08)
               : blend(background, with: NSColor.black, fraction: 0.08)
    }

    /// Resting outline for round chrome controls (the tab strip '+'):
    /// a quiet ring, no fill until pressed.
    var controlOutline: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.20)
    }

    var hairline: NSColor {
        NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.12)
    }

    var secondaryText: NSColor {
        foreground.withAlphaComponent(0.55)
    }

    /// Hover fill: the surface lifted toward the foreground to a 1.18:1
    /// contrast ratio — alpha washes read as nothing.
    var hoverFill: NSColor {
        lift(topBarBackground, toward: foreground, ratio: 1.18)
    }

    /// Icon glyphs sit brighter than secondary text.
    var iconTint: NSColor {
        foreground.withAlphaComponent(0.85)
    }

    var selectionPill: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)
    }

    /// Capsule-tab hover fill (herdr's inner tab strip): one step below
    /// the selection pill — idle is transparent on the tray, selected
    /// is `selectionPill`.
    var tabHoverFill: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.055)
    }

    /// Quiet-form tab hover wash (session-bar pills): strictly one step
    /// below the selection pill so the hierarchy reads idle < hover <
    /// selected in every theme. (hoverFill is a strong contrast lift —
    /// right for small icon buttons, too heavy for full-width segments.)
    var hoverPill: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.04)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.deviceRGB) else { return 0 }
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    private func lift(_ base: NSColor, toward fg: NSColor, ratio: CGFloat) -> NSColor {
        let lb = luminance(base)
        var t: CGFloat = 0.05
        while t <= 1 {
            let mixed = blend(base, with: fg, fraction: t)
            let lm = luminance(mixed)
            if lb <= 0.001 ? lm > 0.05 : (lm + 0.05) / (lb + 0.05) >= ratio {
                return mixed
            }
            t += 0.05
        }
        return blend(base, with: fg, fraction: 1)
    }

    // MARK: agent status (herdr's AgentState palette semantics)

    /// herdr status colors: working=yellow, blocked=red, done=teal,
    /// idle=green, unknown=overlay gray.
    func statusColor(_ status: String) -> NSColor {
        switch status {
        case "working": return NSColor(srgbRed: 0.96, green: 0.62, blue: 0.02, alpha: 1)
        case "blocked": return NSColor(srgbRed: 0.94, green: 0.35, blue: 0.37, alpha: 1)
        case "done": return NSColor(srgbRed: 0.08, green: 0.62, blue: 0.59, alpha: 1)
        case "idle": return NSColor(srgbRed: 0.13, green: 0.77, blue: 0.37, alpha: 1)
        default: return secondaryText
        }
    }

    /// Icon tint per status: attention states (working/blocked/done)
    /// tint the row icon; idle/unknown keep the neutral chrome — a
    /// green tint on every resting agent would erase the distinction.
    func statusIconTint(_ status: String) -> NSColor? {
        switch status {
        case "working", "blocked", "done": return statusColor(status)
        default: return nil
        }
    }

    /// Whole-row wash for attention states, sitting below the
    /// selection pill in the hierarchy.
    func statusRowFill(_ status: String) -> NSColor {
        switch status {
        case "working": return statusColor(status).withAlphaComponent(0.10)
        case "blocked": return statusColor(status).withAlphaComponent(0.12)
        default: return .clear
        }
    }
}

enum Chrome {
    static var theme: ChromeTheme = .fallback
}
