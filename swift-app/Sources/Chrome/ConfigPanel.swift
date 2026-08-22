import Cocoa

// MARK: - herdr config.toml access (the same file herdr's own TUI edits)

/// Minimal TOML section editing, mirroring herdr's config upsert helpers
/// (config/io.rs): values live under `[section]` headers; missing sections
/// are appended. Only the keys herdr's settings overlay persists are used.
enum TomlEdit {
    /// `[section]` … `key = value` → value (unquoted if quoted).
    static func string(in content: String, section: String, key: String) -> String? {
        for line in sectionLines(content, section: section) {
            if let parsed = parseKeyLine(line, key: key) { return unquote(parsed) }
        }
        return nil
    }

    static func bool(in content: String, section: String, key: String) -> Bool? {
        string(in: content, section: section, key: key).flatMap { $0 == "true" }
    }

    /// Replaces `key` inside `[section]` (creating the line or the whole
    /// section as needed) and returns the updated document.
    static func upsert(_ content: String, section: String, key: String, value: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let header = "[\(section)]"

        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
            // Section body ends at the next header line.
            var end = lines.index(after: start)
            while end < lines.endIndex,
                  !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                end = lines.index(after: end)
            }
            var body = Array(lines[lines.index(after: start)..<end])
            if let idx = body.firstIndex(where: { parseKeyLine($0, key: key) != nil }) {
                body[idx] = "\(key) = \(value)"
            } else {
                body.append("\(key) = \(value)")
            }
            lines.replaceSubrange(lines.index(after: start)..<end, with: body)
            return lines.joined(separator: "\n")
        }

        var out = lines
        if !out.isEmpty && !out[out.count - 1].isEmpty { out.append("") }
        out.append(header)
        out.append("\(key) = \(value)")
        return out.joined(separator: "\n") + "\n"
    }

    static func upsertBool(_ content: String, section: String, key: String, value: Bool) -> String {
        upsert(content, section: section, key: key, value: value ? "true" : "false")
    }

    private static func sectionLines(_ content: String, section: String) -> [String] {
        var collecting = false
        var result: [String] = []
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if collecting { break }
                collecting = line == "[\(section)]"
            } else if collecting {
                result.append(line)
            }
        }
        return result
    }

    private static func parseKeyLine(_ line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"),
              trimmed.hasPrefix("\(key) ")
              || trimmed.hasPrefix("\(key)=")
        else { return nil }
        return trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func unquote(_ s: String) -> String {
        (s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2)
            ? String(s.dropFirst().dropLast()) : s
    }
}

/// Reads/writes herdr's config.toml — directly for the local session,
/// through `ssh <alias>` for remote ones — then triggers the server's
/// live reload (the same write-then-reload path herdr's TUI uses).
final class HerdrConfigStore {
    static let remotePath = "~/.config/herdr/config.toml"
    private let alias: String?  // nil = local

    init(target: SessionSpec.Target) {
        if case .ssh(let alias) = target { self.alias = alias } else { self.alias = nil }
    }

    private var localPath: String {
        NSString(string: "~/.config/herdr/config.toml").expandingTildeInPath
    }

    func read(completion: @escaping (String?) -> Void) {
        let alias = self.alias
        let path = localPath
        DispatchQueue.global(qos: .userInitiated).async {
            if let alias {
                completion(Self.ssh(alias: alias, arguments: ["cat", Self.remotePath]))
            } else {
                completion(try? String(contentsOfFile: path, encoding: .utf8))
            }
        }
    }

    func write(_ content: String, completion: @escaping (Bool) -> Void) {
        let alias = self.alias
        let path = localPath
        DispatchQueue.global(qos: .userInitiated).async {
            if let alias {
                let ok = Self.ssh(
                    alias: alias,
                    arguments: ["mkdir -p ~/.config/herdr && cat > \(Self.remotePath)"],
                    stdin: content)
                completion(ok != nil)
            } else {
                let url = URL(fileURLWithPath: path)
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    completion(true)
                } catch {
                    HerdrLog.error("config write: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }
    }

    /// One ssh run; returns stdout, or nil on failure. `arguments` are the
    /// raw remote command words joined for the remote shell.
    private static func ssh(alias: String, arguments: [String], stdin: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", alias]
        args.append(contentsOf: arguments)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            try? inPipe.fileHandleForWriting.close()
        }
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}

// MARK: - native settings panel

/// Native GUI for the settings herdr's TUI overlay persists to config.toml:
/// theme, status indicators, sound, toast delivery, agent border labels,
/// agent panel sort. Each change writes the file and calls
/// server.reload_config — exactly the TUI's write-then-reload flow, so
/// the mirror updates live.
///
/// Skinned with the product chrome theme (Chrome.theme — the terminal
/// palette herdr's sidebar renders with), System-Settings rhythm:
/// section headers over label rows, one aligned control column, quiet
/// footer with the config path + apply state.
final class SettingsPanelController: NSObject {
    static let themeNames = [
        "catppuccin", "catppuccin-latte", "terminal", "tokyo-night", "tokyo-night-day",
        "dracula", "nord", "gruvbox", "gruvbox-light", "one-dark", "one-light",
        "solarized", "solarized-light", "kanagawa", "kanagawa-lotus",
        "rose-pine", "rose-pine-dawn", "vesper",
    ]

    private let spec: SessionSpec
    private let store: HerdrConfigStore
    private let reload: () -> Void
    private var window: NSWindow?
    private var content = ""

    private var isLocal: Bool {
        if case .local = spec.target { return true }
        return false
    }

    init(spec: SessionSpec, reload: @escaping () -> Void) {
        self.spec = spec
        self.store = HerdrConfigStore(target: spec.target)
        self.reload = reload
    }

    private var specLabel: String {
        switch spec.target {
        case .local: return "Local"
        case .ssh(let alias): return alias
        }
    }

    // MARK: controls

    private var themePopup = NSPopUpButton()
    private var indicatorsPopup = NSPopUpButton()
    private var soundSwitch = NSSwitch()
    private var toastPopup = NSPopUpButton()
    private var labelsSwitch = NSSwitch()
    private var sortPopup = NSPopUpButton()
    private var pathField = NSTextField(labelWithString: "")
    private var statusField = NSTextField(labelWithString: "")

    func show(parent: NSWindow?) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "herdr Settings — \(specLabel)"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        // Chrome family: the panel carries the product/herdr look.
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = Chrome.theme.background
        panel.isOpaque = true
        panel.appearance = NSAppearance(named: Chrome.theme.isDark ? .darkAqua : .aqua)
        buildControls(in: panel.contentView!)
        panel.setContentSize(NSSize(width: 470, height: panel.contentView!.fittingSize.height + 48))
        window = panel
        if let parent {
            panel.setFrameOrigin(NSPoint(
                x: parent.frame.midX - panel.frame.width / 2,
                y: parent.frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func refresh() {
        store.read { [weak self] content in
            DispatchQueue.main.async {
                guard let self, let window = self.window, window.isVisible else { return }
                self.content = content ?? ""
                self.applyToControls()
            }
        }
    }

    private func buildControls(in view: NSView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        var lastRow: NSStackView?

        func section(_ title: String) {
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = Chrome.theme.secondaryText
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(10, after: label)
        }

        func row(_ label: String, _ control: NSControl) {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 13)
            text.textColor = Chrome.theme.foreground
            let r = NSStackView(views: [text, control])
            r.orientation = .horizontal
            r.spacing = 12
            r.alignment = .centerY
            stack.addArrangedSubview(r)
            lastRow = r
        }

        for (popup, items) in [
            (themePopup, Self.themeNames.map { $0.replacingOccurrences(of: "-", with: " ").capitalized }),
            (indicatorsPopup, ["Dots", "Symbols"]),
            (toastPopup, ["Off", "herdr", "Terminal", "System"]),
            (sortPopup, ["Spaces", "Priority"]),
        ] {
            popup.addItems(withTitles: items)
            popup.font = .systemFont(ofSize: 12.5)
            popup.target = self
        }
        themePopup.action = #selector(themeChanged)
        indicatorsPopup.action = #selector(indicatorsChanged)
        toastPopup.action = #selector(toastChanged)
        sortPopup.action = #selector(sortChanged)
        soundSwitch.target = self
        soundSwitch.action = #selector(soundChanged)
        labelsSwitch.target = self
        labelsSwitch.action = #selector(labelsChanged)

        section("Appearance")
        row("Theme", themePopup)
        row("Status indicators", indicatorsPopup)
        if let r = lastRow { stack.setCustomSpacing(20, after: r) }

        section("Feedback")
        row("Sound", soundSwitch)
        row("Toasts", toastPopup)
        if let r = lastRow { stack.setCustomSpacing(20, after: r) }

        section("Agents")
        row("Pane border labels", labelsSwitch)
        row("Panel sort", sortPopup)

        // Quiet footer: the exact file being edited + apply state.
        let divider = HairlineView()
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(8, after: divider)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        pathField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        pathField.textColor = Chrome.theme.secondaryText
        pathField.stringValue = isLocal
            ? "~/.config/herdr/config.toml"
            : "\(specLabel):~/.config/herdr/config.toml"
        statusField.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusField.textColor = Chrome.theme.secondaryText
        statusField.stringValue = ""
        footer.addArrangedSubview(pathField)
        let spacer = NSView()
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(statusField)
        stack.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            themePopup.widthAnchor.constraint(equalToConstant: 220),
            indicatorsPopup.widthAnchor.constraint(equalToConstant: 220),
            toastPopup.widthAnchor.constraint(equalToConstant: 220),
            sortPopup.widthAnchor.constraint(equalToConstant: 220),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
        ])
    }

    private func applyToControls() {
        let theme = TomlEdit.string(in: content, section: "theme", key: "name") ?? "catppuccin"
        themePopup.selectItem(withTitle: theme.replacingOccurrences(of: "-", with: " ").capitalized)

        let indicators = TomlEdit.string(in: content, section: "ui", key: "status_indicators") ?? "dots"
        indicatorsPopup.selectItem(at: indicators == "symbols" ? 1 : 0)

        soundSwitch.state = (TomlEdit.bool(in: content, section: "ui.sound", key: "enabled") ?? true)
            ? .on : .off

        let toast = TomlEdit.string(in: content, section: "ui.toast", key: "delivery") ?? "off"
        toastPopup.selectItem(at: ["off": 0, "herdr": 1, "terminal": 2, "system": 3][toast] ?? 0)

        labelsSwitch.state = (TomlEdit.bool(
            in: content, section: "ui", key: "show_agent_labels_on_pane_borders") ?? false)
            ? .on : .off

        let sort = TomlEdit.string(in: content, section: "ui", key: "agent_panel_sort") ?? "spaces"
        sortPopup.selectItem(at: sort == "priority" ? 1 : 0)
    }

    // MARK: apply-on-change

    private func update(contentTransform: (String) -> String) {
        content = contentTransform(content)
        store.write(content) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusField.stringValue = ok ? "applied" : "write failed"
                if ok { self.reload() }
            }
        }
    }

    @objc private func themeChanged(_: Any) {
        let raw = themePopup.titleOfSelectedItem ?? "Catppuccin"
        let name = raw.lowercased().replacingOccurrences(of: " ", with: "-")
        update { c in
            let withName = TomlEdit.upsert(c, section: "theme", key: "name", value: "\"\(name)\"")
            return TomlEdit.upsertBool(withName, section: "theme", key: "auto_switch", value: false)
        }
    }

    @objc private func indicatorsChanged(_: Any) {
        update { c in
            TomlEdit.upsert(c, section: "ui", key: "status_indicators",
                            value: self.indicatorsPopup.indexOfSelectedItem == 1 ? "\"symbols\"" : "\"dots\"")
        }
    }

    @objc private func soundChanged(_: Any) {
        update { c in
            TomlEdit.upsertBool(c, section: "ui.sound", key: "enabled",
                                value: self.soundSwitch.state == .on)
        }
    }

    @objc private func toastChanged(_: Any) {
        let values = ["\"off\"", "\"herdr\"", "\"terminal\"", "\"system\""]
        update { c in
            TomlEdit.upsert(c, section: "ui.toast", key: "delivery",
                            value: values[self.toastPopup.indexOfSelectedItem])
        }
    }

    @objc private func labelsChanged(_: Any) {
        update { c in
            TomlEdit.upsertBool(c, section: "ui", key: "show_agent_labels_on_pane_borders",
                                value: self.labelsSwitch.state == .on)
        }
    }

    @objc private func sortChanged(_: Any) {
        update { c in
            TomlEdit.upsert(c, section: "ui", key: "agent_panel_sort",
                            value: self.sortPopup.indexOfSelectedItem == 1 ? "\"priority\"" : "\"spaces\"")
        }
    }
}
