import Foundation

// MARK: - Ghostty theme files → CellTheme
//
// Ghostty themes are ini files: `background = #1e1e2e`, `palette = 0=#...`
// The GUI resolves cell colors client-side, so a Ghostty theme maps 1:1
// onto CellTheme (fg/bg/cursor + 16 ANSI; the 216-cube and grayscale ramp
// are fixed xterm standards). Scans the app copy (seeded at launch from
// the user's Ghostty), the user's live themes, and Ghostty.app's bundle.

enum GhosttyThemes {
    static let changedNotification = Notification.Name("herdrGuiCellThemeChanged")

    private static let themeDirectories: [String] = {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Application Support/herdr-gui/ghostty/themes",
            home + "/.config/ghostty/themes",
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        ]
    }()

    /// Available theme names (file names), directory order preserved,
    /// duplicates skipped. Empty when no Ghostty themes exist.
    static func names() -> [String] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [String] = []
        for dir in themeDirectories {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries.sorted() where !seen.contains(entry) {
                seen.insert(entry)
                result.append(entry)
            }
        }
        return result
    }

    /// Parses a theme file into a CellTheme; nil when the file is missing
    /// or carries no colors. `palette = N=#hex` keys (0–15) plus
    /// background/foreground/cursor-color/selection-background.
    static func load(name: String) -> CellTheme? {
        let fm = FileManager.default
        guard let path = themeDirectories.first(where: {
            fm.fileExists(atPath: $0 + "/" + name)
        }), let text = try? String(contentsOfFile: path + "/" + name,
                                   encoding: .utf8)
        else { return nil }
        var ansi = [UInt32?](repeating: nil, count: 16)
        var background: UInt32?
        var foreground: UInt32?
        var cursor: UInt32?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "palette" {
                // palette = 3=#cdd6f4
                let sub = value.split(separator: "=", maxSplits: 1)
                guard sub.count == 2,
                      let index = Int(sub[0].trimmingCharacters(in: .whitespaces)),
                      (0..<16).contains(index),
                      let hex = hexValue(sub[1].trimmingCharacters(in: .whitespaces))
                else { continue }
                ansi[index] = hex
            } else if let hex = hexValue(value) {
                switch key {
                case "background": background = hex
                case "foreground": foreground = hex
                case "cursor-color", "cursor-foreground": cursor = hex
                default: break
                }
            }
        }
        guard background != nil || foreground != nil else { return nil }
        // Fill unspecified ANSI slots from a readable default ramp.
        let fallbackAnsi = CellTheme.defaults.palette
        let resolved = (0..<16).map { ansi[$0] ?? fallbackAnsi[$0] }
        return CellTheme(
            ansi16: resolved,
            foreground: foreground ?? 0xd8dee9,
            background: background ?? 0x101419,
            cursor: cursor ?? foreground ?? 0xd8dee9)
    }

    /// `#rrggbb` or `#rgb` → packed 0x00RRGGBB.
    static func hexValue(_ text: String) -> UInt32? {
        let value = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard value.count == 3 || value.count == 6,
              let parsed = UInt64(value, radix: 16) else { return nil }
        if value.count == 3 {
            let r = UInt32((parsed >> 8) & 0xF), g = UInt32((parsed >> 4) & 0xF),
                b = UInt32(parsed & 0xF)
            return (r << 4 | r) << 16 | (g << 4 | g) << 8 | (b << 4 | b)
        }
        return UInt32(parsed) & 0xffffff
    }

    // MARK: Current theme (GUI-local preference)

    private static let themeKey = "cellThemeName"

    /// The active CellTheme: the saved Ghostty theme, else the user's
    /// ghostty `theme =` setting if that file parses, else defaults.
    static func current() -> CellTheme {
        let saved = UserDefaults.standard.string(forKey: themeKey)
        if let saved, let theme = load(name: saved) { return theme }
        if let configured = ChromeTheme.configuredThemeName(),
           let theme = load(name: configured) { return theme }
        return .defaults
    }

    static func currentName() -> String? {
        UserDefaults.standard.string(forKey: themeKey)
            ?? ChromeTheme.configuredThemeName()
    }

    /// Applies a new theme everywhere: preference, chrome, live pages.
    static func apply(name: String?) {
        if let name {
            UserDefaults.standard.set(name, forKey: themeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: themeKey)
        }
        reapply()
    }

    /// Pushes the current theme to the chrome and all open pages.
    static func reapply() {
        let cellTheme = current()
        Chrome.theme = ChromeTheme.from(cellTheme)
        NotificationCenter.default.post(name: changedNotification, object: cellTheme)
    }
}
