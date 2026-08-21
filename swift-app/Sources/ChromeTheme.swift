import Cocoa
import GhosttyKit

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

    static func from(_ cfg: Ghostty.Config?) -> ChromeTheme {
        guard let handle = cfg?.config else { return .fallback }
        func color(_ key: String) -> NSColor? {
            var v = ghostty_config_color_s()
            guard ghostty_config_get(handle, &v, key, UInt(key.utf8.count)) else { return nil }
            return NSColor(srgbRed: CGFloat(v.r) / 255, green: CGFloat(v.g) / 255,
                           blue: CGFloat(v.b) / 255, alpha: 1)
        }
        return ChromeTheme(
            background: color("background") ?? fallback.background,
            foreground: color("foreground") ?? fallback.foreground,
            accent: color("selection-background") ?? fallback.accent)
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

    /// Tab hover wash: strictly one step below the selection pill so the
    /// hierarchy reads idle < hover < selected in every theme. (hoverFill
    /// is a strong contrast lift — right for small icon buttons, too
    /// heavy for full-width tab segments.)
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

}

enum Chrome {
    static var theme: ChromeTheme = .fallback
}
