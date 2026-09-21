import Cocoa

// MARK: - app delegate (window + session management)

private var keepAliveDelegate: AppDelegate?

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    // One open connection per entry; the session bar mirrors this array.
    private enum Session {
        case herdr(HerdrPageController)

        var spec: SessionSpec {
            switch self {
            case .herdr(let page): return page.spec
            }
        }

        var view: NSView {
            switch self {
            case .herdr(let page): return page.view
            }
        }

        var keyView: NSView? {
            switch self {
            case .herdr(let page): return page.keyView
            }
        }

        func focusTerminal() {
            switch self {
            case .herdr(let page): page.focusTerminal()
            }
        }

        func shutdown() {
            switch self {
            case .herdr(let page): page.shutdown()
            }
        }
    }

    private var sessions: [Session] = []
    private var activeIndex = -1
    private var sessionBar: SessionBarView?
    private var pageContainer: NSView?
    private var focusMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keepAliveDelegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIcon.image
        setupStatusBarItem()
        // Theme home in app support: the user's Ghostty config + themes are
        // copied once — the terminal theme picker reads this library.
        let ownHome = NSHomeDirectory()
            + "/Library/Application Support/herdr-gui/ghostty"
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
        // Chrome follows the active terminal theme (Ghostty theme file).
        GhosttyThemes.reapply()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 832))
        let window = StableWindow(
            contentRect: content.bounds,
            // fullSizeContentView must be present at init: inserting it
            // later leaves the native titlebar band in place (black
            // strip). The session bar carries the traffic lights zone.
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "herdr-gui"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: Chrome.theme.isDark ? .darkAqua : .aqua)
        // Page swaps (remove old view → add new one) expose the window
        // backing for a frame or two before the new page and the Metal
        // surface paint; both backing layers are the theme background
        // so the gap never flashes black.
        window.backgroundColor = Chrome.theme.background
        window.contentView = content
        content.wantsLayer = true
        content.layer?.backgroundColor = Chrome.theme.background.cgColor
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Session bar spans the titlebar zone; pages live below it.
        // Both are mask-sized on purpose: with constraint ties to the
        // content view, every page mount/swap lets AppKit's layout
        // engine re-derive the WINDOW frame from the content fitting
        // size — a fresh page fits at 232×58 (sidebar + strip) or even
        // 0×30 (loading page), and the window collapses to it
        // (contentMinSize is ignored on that private path). Mask sizing
        // severs the constraint path to the window; pages lay out their
        // own constraints inside the fixed container.
        let barHeight: CGFloat = 30
        let bar = SessionBarView(frame: NSRect(
            x: 0, y: content.bounds.height - barHeight,
            width: content.bounds.width, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(bar)
        self.sessionBar = bar

        let pages = NSView(frame: NSRect(
            x: 0, y: 0,
            width: content.bounds.width,
            height: content.bounds.height - barHeight))
        pages.autoresizingMask = [.width, .height]
        content.addSubview(pages)
        self.pageContainer = pages

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

    /// Menu-bar item with the herdr-gui template glyph: clicking toggles
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
                clientSocketPath: HerdrPageController.defaultClientSocketPath)))
        case .local:
            openPrivateTerminal(spec: spec, command: nil)
        case .ssh(let alias) where spec.wantsHerdr:
            // Remote herdr needs the 0.9+ `remote-client-bridge` transport
            // (Phase 2); the old v19 streamlocal tunnel is gone with the
            // mirror. Plain ssh terminal pages still work.
            let alert = NSAlert()
            alert.messageText = "\(alias): remote herdr needs herdr 0.9+"
            alert.informativeText =
                "Remote herdr pages move to herdr's remote-client-bridge in " +
                "the next release. Use a plain ssh terminal page for now."
            alert.runModal()
        case .ssh(let alias):
            openPrivateTerminal(spec: spec, command: "ssh \(alias)")
        }
    }

    /// Standalone Terminal / ssh pages: a private herdr server with its
    /// own sockets, rendered by the same endpoint client + cell canvas.
    /// The page owns the server's lifetime.
    private func openPrivateTerminal(spec: SessionSpec, command: String?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let socketPath = PrivateHerdrSession.shared.clientSocketPath(
                    key: spec.id) else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Could not start herdr for \(spec.label)"
                    alert.informativeText = "herdr 0.9+ must be installed."
                    alert.runModal()
                }
                return
            }
            DispatchQueue.main.async {
                guard let self, self.sessions.firstIndex(where: {
                    $0.spec.id == spec.id
                }) == nil else { return }
                let page = HerdrPageController(
                    spec: spec, clientSocketPath: socketPath,
                    bootstrapCommand: command)
                self.append(.herdr(page))
            }
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
        sessions[index].shutdown()
        sessions.remove(at: index)

        if index == activeIndex {
            activate(min(index, sessions.count - 1))
        } else if index < activeIndex {
            activeIndex -= 1
            renderSessionBar()
        }
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
        let appItem = NSMenuItem(title: "herdr-gui", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit herdr-gui",
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
        sessionMenu.addItem(.separator())
        // Config items act on the active herdr server's config: Open
        // is local-only (remote configs live on the host), Reload
        // works on any connected herdr page.
        let openConfig = sessionMenu.addItem(
            withTitle: "Open Config File",
            action: #selector(menuOpenConfig), keyEquivalent: "")
        openConfig.target = self
        let reloadConfig = sessionMenu.addItem(
            withTitle: "Reload Config",
            action: #selector(menuReloadConfig), keyEquivalent: "")
        reloadConfig.target = self
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

    @objc private func menuOpenConfig() {
        guard case .herdr(let page)? = activeSession else { return }
        page.openConfig()
    }

    @objc private func menuReloadConfig() {
        guard case .herdr(let page)? = activeSession else { return }
        page.reloadConfig()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(menuCloseSession) {
            guard let session = activeSession else { return true }
            return !(session.spec.target == .local && session.spec.wantsHerdr)
        }
        if item.action == #selector(menuOpenConfig) {
            guard case .herdr(let page)? = activeSession else { return false }
            return page.spec.target == .local
        }
        if item.action == #selector(menuReloadConfig) {
            guard case .herdr = activeSession else { return false }
            return true
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

// MARK: - main window

/// NSWindow whose frame only moves by user action. AppKit's constraint
/// engine can otherwise take over the frame (`_changeWindowFrameFrom-
/// ConstraintsIfNecessary` → `_setFrameCommon`) and collapse the window
/// to the content's fitting size: mounting a page whose chrome fits at
/// sidebar+strip (232×58) — or a loading page at 0×30 — resized a
/// 1280×832 window to exactly that, on every page swap. That path also
/// ignores contentMinSize. Overriding the (private, long-stable)
/// selector to a no-op keeps the engine from touching the frame at all;
/// user drags still work and contentMinSize still bounds them.
final class StableWindow: NSWindow {
    @objc func _changeWindowFrameFromConstraintsIfNecessary() {
        // Deliberate no-op: this window is never constraint-driven.
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

