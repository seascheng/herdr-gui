import Cocoa
import GhosttyKit

// MARK: - app delegate (window + session management)

private var keepAliveDelegate: AppDelegate?

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var ghostty: Ghostty.App!

    /// The libghostty app handle for surface construction (pages are
    /// built only after applicationDidFinishLaunching initialized it).
    static func ghosttyApp() -> ghostty_app_t {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate,
              let app = delegate.ghostty?.app
        else { fatalError("libghostty app not initialized") }
        return app
    }

    // One open connection per entry; the session bar mirrors this array.
    private enum Session {
        case herdr(HerdrPageController)
        case terminal(TerminalPageController)
        case connecting(ConnectingView)

        var spec: SessionSpec {
            switch self {
            case .herdr(let page): return page.spec
            case .terminal(let page): return page.spec
            case .connecting(let view): return view.spec
            }
        }

        var view: NSView {
            switch self {
            case .herdr(let page): return page.view
            case .terminal(let page): return page.view
            case .connecting(let view): return view
            }
        }

        var keyView: NSView? {
            switch self {
            case .herdr(let page): return page.keyView
            case .terminal(let page): return page.keyView
            case .connecting: return nil
            }
        }

        var surfaceView: Ghostty.SurfaceView? {
            switch self {
            case .herdr(let page): return page.surfaceView
            case .terminal(let page): return page.surfaceView
            case .connecting: return nil
            }
        }

        func focusTerminal() {
            switch self {
            case .herdr(let page): page.focusTerminal()
            case .terminal(let page): page.focusTerminal()
            case .connecting: break
            }
        }

        func shutdown() {
            switch self {
            case .herdr(let page): page.shutdown()
            case .terminal(let page): page.shutdown()
            case .connecting: break
            }
        }
    }

    private var sessions: [Session] = []
    private var activeIndex = -1
    private var sessionBar: SessionBarView?
    private var pageContainer: NSView?
    private var focusMonitor: Any?
    private var tunnels: [String: SSHTunnel] = [:]  // spec.id → tunnel

    func applicationDidFinishLaunching(_ notification: Notification) {
        keepAliveDelegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIcon.image
        setupStatusBarItem()
        // Our OWN ghostty home in app support: config + themes copied once
        // from the user's live Ghostty, then owned by hertty. The env var
        // MUST be set before ghostty_init — libghostty captures the
        // resources dir during init. Without it, CLI launches (which
        // inherit GHOSTTY_RESOURCES_DIR from a hosting Ghostty) and
        // Finder launches resolve themes against different roots.
        let ownHome = NSHomeDirectory()
            + "/Library/Application Support/hertty/ghostty"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: ownHome, withIntermediateDirectories: true)
        let liveConfigs = [
            NSHomeDirectory()
                + "/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            NSHomeDirectory() + "/.config/ghostty/config",
        ]
        if !fm.fileExists(atPath: ownHome + "/config"),
           let source = liveConfigs.first(where: { fm.fileExists(atPath: $0) }) {
            try? fm.copyItem(atPath: source, toPath: ownHome + "/config")
        }
        if !fm.fileExists(atPath: ownHome + "/themes/Arthur") {
            let seed = "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"
            if fm.fileExists(atPath: seed) {
                try? fm.copyItem(atPath: seed, toPath: ownHome + "/themes")
            }
        }
        if fm.fileExists(atPath: ownHome + "/themes") {
            setenv("GHOSTTY_RESOURCES_DIR", ownHome, 1)
        }
        let configPath = fm.fileExists(atPath: ownHome + "/config")
            ? ownHome + "/config" : nil

        guard ghostty_init(0, nil) == 0 else {
            let alert = NSAlert(); alert.messageText = "ghostty_init failed"; alert.runModal()
            NSApp.terminate(nil); return
        }

        let app = Ghostty.App(configPath: configPath)
        guard app.readiness == .ready else {
            let alert = NSAlert()
            alert.messageText = "Failed to initialize libghostty"
            alert.runModal(); NSApp.terminate(nil); return
        }
        ghostty = app
        app.delegate = self
        // Chrome follows the terminal's resolved Ghostty config — the
        // same one the mirror surface renders with.
        Chrome.theme = ChromeTheme.from(app.config)

        if ProcessInfo.processInfo.environment["HERDR_DUMP_VIEWS"] == "1" {
            var probe = ghostty_config_color_s()
            let key = "background"
            let resolved = ghostty_config_get(
                app.config.config, &probe, key, UInt(key.utf8.count))
            let bg = Chrome.theme.background.usingColorSpace(.sRGB)
            DiagLog.views("THEME resolved=\(resolved) rgb=\(probe.r),\(probe.g),\(probe.b)"
                + " env=\(ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] ?? "nil")"
                + " chrome=\(Int((bg?.redComponent ?? 0) * 255)),\(Int((bg?.greenComponent ?? 0) * 255)),\(Int((bg?.blueComponent ?? 0) * 255))"
                + " dark=\(Chrome.theme.isDark)\n")
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 832))
        let window = NSWindow(
            contentRect: content.bounds,
            // fullSizeContentView must be present at init: inserting it
            // later leaves the native titlebar band in place (black
            // strip). The session bar carries the traffic lights zone.
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "hertty"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: Chrome.theme.isDark ? .darkAqua : .aqua)
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Session bar spans the titlebar zone; pages live below it.
        let bar = SessionBarView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        self.sessionBar = bar

        let pages = NSView(frame: .zero)
        pages.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pages)
        self.pageContainer = pages

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            pages.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pages.topAnchor.constraint(equalTo: bar.bottomAnchor),
            pages.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        bar.onSessionSelected = { [weak self] index in
            self?.activate(index)
        }
        bar.onSessionClosed = { [weak self] index in
            self?.closeSession(at: index)
        }
        bar.serversMenuProvider = { [weak self] in
            self?.buildServersMenu() ?? NSMenu()
        }

        buildMainMenu()

        // The default first session: local herdr, as before.
        openSession(SessionSpec(target: .local, wantsHerdr: true))

        focusMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  let container = self.pageContainer,
                  let active = self.activeSession,
                  container.frame.contains(event.locationInWindow),
                  let keyView = active.keyView
            else { return event }
            window.makeFirstResponder(keyView)
            return event
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: status bar

    /// Menu-bar item with the hertty template glyph: clicking toggles
    /// the main window — the reachability hook while agents stream in
    /// the background.
    private var statusItem: NSStatusItem?

    /// Menu-bar glyphs render at ~16-18pt; the source PNG is 32×24 with
    /// no scaling of its own, so unscaled it overflows the bar. Draw it
    /// into an 18×13.5 template copy (lockFocus renders at the screen's
    /// backing scale, so it stays crisp on retina).
    private static let menuBarIcon: NSImage? = {
        guard let base = AppIcon.menuBarTemplate else { return nil }
        let target = NSSize(width: 18, height: 13.5)
        let scaled = NSImage(size: target)
        scaled.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: target))
        scaled.unlockFocus()
        scaled.isTemplate = true
        return scaled
    }()

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon
        item.button?.action = #selector(toggleMainWindow(_:))
        item.button?.target = self
        statusItem = item
    }

    @objc private func toggleMainWindow(_ sender: Any?) {
        guard let window else { return }
        if window.isOnActiveSpace, window.isVisible, window.isKeyWindow {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: sessions

    private var activeSession: Session? {
        guard sessions.indices.contains(activeIndex) else { return nil }
        return sessions[activeIndex]
    }

    /// Opens (or activates) a session. ssh+herdr dials the tunnel first
    /// and shows a connecting page until the endpoints are live.
    private func openSession(_ spec: SessionSpec) {
        if let index = sessions.firstIndex(where: { $0.spec.id == spec.id }) {
            activate(index)
            return
        }

        switch spec.target {
        case .local where spec.wantsHerdr:
            append(.herdr(HerdrPageController(
                spec: spec,
                apiSocketPath: HerdrAPI.defaultSocketPath,
                clientSocketPath: HerdrAPI.defaultClientSocketPath)))
        case .local:
            append(.terminal(TerminalPageController(spec: spec)))
        case .ssh(let alias) where spec.wantsHerdr:
            let connecting = ConnectingView(spec: spec)
            append(.connecting(connecting))
            let tunnel = SSHTunnel(alias: alias)
            tunnels[spec.id] = tunnel
            tunnel.start { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let endpoints):
                    guard let index = self.sessions.firstIndex(where: { $0.spec.id == spec.id })
                    else {
                        self.teardownTunnel(spec.id)
                        return
                    }
                    let page = HerdrPageController(
                        spec: spec,
                        apiSocketPath: endpoints.apiSocket,
                        clientSocketPath: endpoints.clientSocket)
                    self.replaceSession(at: index, with: .herdr(page))
                case .failure(let error):
                    HerdrLog.error("tunnel \(alias): \(error.localizedDescription)")
                    // closeSession tears the tunnel when the session is
                    // still open; otherwise do it here.
                    if let index = self.sessions.firstIndex(where: { $0.spec.id == spec.id }) {
                        self.closeSession(at: index)
                    } else {
                        self.teardownTunnel(spec.id)
                    }
                    let alert = NSAlert()
                    alert.messageText = "Could not connect to \(alias)"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        case .ssh:
            append(.terminal(TerminalPageController(spec: spec)))
        }
    }

    private func append(_ session: Session) {
        sessions.append(session)
        activate(sessions.count - 1)
    }

    private func replaceSession(at index: Int, with session: Session) {
        guard sessions.indices.contains(index) else { return }
        sessions[index] = session
        if index == activeIndex { activate(index) } else { renderSessionBar() }
    }

    private func activate(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        activeIndex = index
        if let container = pageContainer {
            container.subviews.forEach { $0.removeFromSuperview() }
            let view = sessions[index].view
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        renderSessionBar()
        // Terminal takes keyboard focus as the page appears.
        DispatchQueue.main.async { [weak self] in
            self?.activeSession?.focusTerminal()
        }
    }
    private func closeSession(at index: Int) {

        guard sessions.indices.contains(index) else { return }
        // Only the default local herdr page is pinned — every other
        // session (including local Terminal pages) can be closed.
        let spec = sessions[index].spec
        guard !(spec.target == .local && spec.wantsHerdr) else { return }
        let specId = sessions[index].spec.id
        sessions[index].shutdown()
        sessions.remove(at: index)
        teardownTunnel(specId)

        if index == activeIndex {
            activate(min(index, sessions.count - 1))
        } else if index < activeIndex {
            activeIndex -= 1
            renderSessionBar()
        }
    }

    private func teardownTunnel(_ specId: String) {
        tunnels[specId]?.shutdown()
        tunnels[specId] = nil
    }

    private func renderSessionBar() {
        sessionBar?.render(
            sessions: sessions.map { $0.spec },
            activeId: activeSession?.spec.id ?? "")
    }

    // The toolbar button pops the menu itself (anchored to the button,
    // add-workspace reference style); this builds the shared menu.

    /// Terminal + every ssh-config host, native add-workspace style:
    /// flat rows with theme-tinted icons; ⌥ swaps a host to terminal-only.
    /// Shared by the toolbar button popup and the menu-bar Servers item.
    private func buildServersMenu() -> NSMenu {
        let menu = NSMenu()
        let terminal = NSMenuItem(
            title: "Terminal", action: #selector(menuOpenServer(_:)), keyEquivalent: "")
        terminal.target = self
        terminal.representedObject = ["id": "terminal"]
        terminal.image = menuItemIcon("plus")
        menu.addItem(terminal)
        menu.addItem(.separator())

        for alias in SSHConfig.hostAliases() {
            let herdr = NSMenuItem(
                title: alias, action: #selector(menuOpenServer(_:)), keyEquivalent: "")
            herdr.target = self
            herdr.representedObject = ["alias": alias, "herdr": true]
            herdr.image = menuItemIcon("server.rack")
            menu.addItem(herdr)

            let term = NSMenuItem(
                title: "\(alias) — terminal", action: #selector(menuOpenServer(_:)),
                keyEquivalent: "")
            term.target = self
            term.representedObject = ["alias": alias, "herdr": false]
            term.isAlternate = true
            term.keyEquivalentModifierMask = [.option]
            term.image = menuItemIcon("terminal")
            menu.addItem(term)
        }

        if menu.items.count > 2 {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "Hold ⌥ for terminal-only ssh", action: nil,
                                  keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        return menu
    }

    @objc private func menuOpenServer(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any] else { return }
        if info["id"] as? String == "terminal" {
            openSession(SessionSpec(target: .local, wantsHerdr: false))
            return
        }
        guard let alias = info["alias"] as? String,
              let wantsHerdr = info["herdr"] as? Bool
        else { return }
        openSession(SessionSpec(target: .ssh(alias: alias), wantsHerdr: wantsHerdr))
    }

    // MARK: menu / key equivalents

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "hertty", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit hertty",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let serversItem = NSMenuItem(title: "Servers", action: nil, keyEquivalent: "")
        serversItem.submenu = buildServersMenu()
        mainMenu.addItem(serversItem)

        let sessionItem = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
        let sessionMenu = NSMenu()
        let newLocal = sessionMenu.addItem(withTitle: "New Local herdr Session",
                                           action: #selector(menuNewLocalSession), keyEquivalent: "n")
        newLocal.target = self
        let close = sessionMenu.addItem(withTitle: "Close Session",
                                        action: #selector(menuCloseSession), keyEquivalent: "W")
        close.keyEquivalentModifierMask = [.command, .shift]
        // Explicit target so validateMenuItem runs on the delegate.
        close.target = self
        sessionItem.submenu = sessionMenu
        mainMenu.addItem(sessionItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func menuNewLocalSession() {
        openSession(SessionSpec(target: .local, wantsHerdr: true))
    }

    @objc private func menuCloseSession() {
        // The default local herdr page is pinned; the item is validated
        // disabled when it is active.
        guard let session = activeSession,
              !(session.spec.target == .local && session.spec.wantsHerdr),
              let index = sessions.firstIndex(where: { $0.spec.id == session.spec.id })
        else { return }
        closeSession(at: index)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(menuCloseSession) {
            guard let session = activeSession else { return true }
            return !(session.spec.target == .local && session.spec.wantsHerdr)
        }
        return true
    }
    /// Cmd-T / Cmd-W act on the active herdr session.
    func performGhosttyBindingMenuKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers ?? "" {
        case "t":
            if case .herdr(let page)? = activeSession { page.menuNewTab() }
            return true
        case "w":
            if case .herdr(let page)? = activeSession { page.menuCloseTab() }
            return true
        default:
            return false
        }
    }
}

extension AppDelegate: NSMenuItemValidation {}

// MARK: - connecting placeholder page

/// Shown while an ssh herdr tunnel dials: a quiet label so the session
/// tab exists (and can be closed) before the endpoints come up.
final class ConnectingView: NSView {
    let spec: SessionSpec
    private let label = NSTextField(labelWithString: "")

    init(spec: SessionSpec) {
        self.spec = spec
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = "Connecting to \(spec.label)…"
        label.font = .systemFont(ofSize: 13)
        label.textColor = Chrome.theme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.theme.background.setFill()
        bounds.fill()
    }
}

extension AppDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        keepAliveDelegate = delegate
        app.run()
    }
}

extension AppDelegate: GhosttyAppDelegate {
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return delegate.sessions.compactMap { $0.surfaceView }
            .first { $0.id == uuid }
    }
}
