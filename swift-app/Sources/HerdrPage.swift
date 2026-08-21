import Cocoa
import GhosttyKit

// MARK: - herdr page (one mirrored herdr server)

/// A full herdr chrome page: sidebar + herdr tab strip + the mirrored
/// app surface, plus its own API/event-stream/reconcile cycle bound to
/// one server (local socket, or the local end of an SSH tunnel).
final class HerdrPageController {
    let view = NSView(frame: .zero)
    let spec: SessionSpec

    private let api: HerdrAPI
    private let clientSocketPath: String
    private var sidebar: SidebarView?
    private var tabStrip: TabStripView?
    private var host: TerminalSurfaceHost?

    private var eventStream: HerdrEventStream?
    private var reconcileCoalesce: DispatchWorkItem?
    private var reconcileInFlight = false
    private var reconcilePending = false
    private var pollTimer: Timer?
    private var focusedTabId = ""
    /// herdr's sidebar section split (snapshot), for launcher-row math.
    private var sidebarSplit: Double = 0.5
    private var sidebarCollapsed = false
    private var sidebarWidth: NSLayoutConstraint?
    private var didAutoOpenSettings = false
    private var settingsPanel: SettingsPanelController?
    init(spec: SessionSpec, apiSocketPath: String, clientSocketPath: String) {
        self.spec = spec
        self.api = HerdrAPI(socketPath: apiSocketPath)
        self.clientSocketPath = clientSocketPath
        buildUI()
        startStreams()
    }

    private func buildUI() {
        let content = view
        content.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = SidebarView()
        sidebar.serverLabel = spec.label
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        self.sidebar = sidebar

        let tabStrip = TabStripView()
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabStrip)
        self.tabStrip = tabStrip

        sidebar.onReloadConfig = { [weak self] in
            _ = self?.api.call("server.reload_config", [:])
        }
        sidebar.onOpenSettings = { [weak self] in
            guard let self else { return }
            if self.settingsPanel == nil {
                self.settingsPanel = SettingsPanelController(
                    spec: self.spec,
                    reload: { _ = self.api.call("server.reload_config", [:]) })
            }
            self.settingsPanel?.show(parent: self.view.window)
        }
        sidebar.onOpenKeybinds = { [weak self] in
            self?.host?.openHerdrOverlay(split: self?.sidebarSplit ?? 0.5, keys: "\u{1b}[B\r")
        }

        let host = TerminalSurfaceHost(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)  // content area only; clipped surface shows
        self.host = host          // just herdr's middle region
        host.attach(app: AppDelegate.ghosttyApp(), clientSocketPath: clientSocketPath)

        let sidebarWidth = NSLayoutConstraint(
            item: sidebar, attribute: .width, relatedBy: .equal,
            toItem: nil, attribute: .notAnAttribute, multiplier: 1,
            constant: CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth")))
        if sidebarWidth.constant < 180 { sidebarWidth.constant = 200 }
        sidebarWidth.isActive = true
        self.sidebarWidth = sidebarWidth
        sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")

        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: content.topAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: 28),
        ])

        sidebar.onWidthChange = { [weak self] width in
            self?.applySidebarWidth(min(max(width, 180), 340), collapsed: false)
        }
        sidebar.onToggleCollapse = { [weak self] in
            guard let self else { return }
            self.sidebarCollapsed.toggle()
            self.applySidebarWidth(
                self.sidebarCollapsed ? 56 : max(UserDefaults.standard.double(forKey: "sidebarWidth"), 180),
                collapsed: self.sidebarCollapsed)
            self.sidebar?.setCollapsed(self.sidebarCollapsed)
        }
        sidebar.setCollapsed(sidebarCollapsed)
        if sidebarCollapsed { sidebarWidth.constant = 56 }

        sidebar.onWorkspaceSelected = { [weak self] workspaceId in
            self?.api.focusWorkspace(workspaceId)
            self?.reconcileNow()
        }
        sidebar.onNewWorkspace = { [weak self] in
            _ = self?.api.call("workspace.create", [:])
            self?.reconcileNow()
        }
        sidebar.onCloseWorkspace = { [weak self] in
            self?.api.closeWorkspace($0)
            self?.reconcileNow()
        }
        sidebar.onAgentSelected = { [weak self] tabId in
            self?.api.focusTab(tabId)
            self?.reconcileNow()
        }
        tabStrip.onTabIdSelected = { [weak self] tabId in
            self?.api.focusTab(tabId)
            self?.reconcileNow()
        }
        tabStrip.onCloseTab = { [weak self] tabId in
            self?.api.closeTab(tabId)
            self?.reconcileNow()
        }
        tabStrip.onRenameTab = { [weak self] tabId, name in
            self?.api.renameTab(tabId, to: name)
        }
        tabStrip.onNewTab = { [weak self] in
            _ = self?.api.call("tab.create", [:])
            self?.reconcileNow()
        }
    }

    private func startStreams() {
        // herdr is the sole source of structure: events push within ~10ms;
        // the 2s snapshot poll remains as a self-healing fallback.
        reconcileNow()
        let events = HerdrEventStream(socketPath: api.socketPath)
        events.onEvent = { [weak self] (_: String) in
            guard let self else { return }
            self.reconcileCoalesce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reconcileNow() }
            self.reconcileCoalesce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
        }
        // A dropped scroll channel usually means its cached terminal id went
        // stale (tab closed): re-read the snapshot immediately.
        host?.scrollChannel?.onInvalidated = { [weak self] in
            self?.reconcileNow()
        }
        events.start()
        eventStream = events
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.reconcileNow()
        }
    }

    // MARK: surface / lifecycle

    var keyView: NSView? { host?.keyView }
    var surfaceView: Ghostty.SurfaceView? { host?.keyView as? Ghostty.SurfaceView }

    func focusTerminal() {
        if let keyView { keyView.window?.makeFirstResponder(keyView) }
    }

    func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        reconcileCoalesce?.cancel()
        eventStream?.stop()
        eventStream = nil
        host?.shutdown()
        host?.scrollChannel?.shutdown()
        host?.removeFromSuperview()
    }

    // MARK: menu actions

    func menuNewTab() { _ = api.call("tab.create", [:]) }
    func menuCloseTab() { api.closeTab(focusedTabId) }

    // MARK: reconcile (native chrome only; content comes from the stream)

    private func reconcileNow() {
        guard !reconcileInFlight else { reconcilePending = true; return }
        reconcileInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = self?.api.snapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.reconcileInFlight = false
                if let snapshot { self.reconcile(with: snapshot) }
                if self.reconcilePending {
                    self.reconcilePending = false
                    self.reconcileNow()
                }
            }
        }
    }

    private func reconcile(with snapshot: [String: Any]) {
        guard let state = HerdrModel.sidebarState(snapshot) else { return }
        let layout = (snapshot["layouts"] as? [[String: Any]])?
            .first { $0["tab_id"] as? String == state.focusedTabId }

        if let layout {
            updateChrome(from: layout)
            updateFocusedPane(from: layout, snapshot: snapshot)
        } else {
            host?.scrollChannel?.updateTarget(terminalId: nil, columns: 0, rows: 0)
        }

        let focused = state.focusedTabId ?? state.tabs.first?.tabId ?? ""
        let tabs = state.tabs.map { (id: $0.tabId, name: $0.label) }
        focusedTabId = focused
        sidebarSplit = state.sidebarSplit
        if ProcessInfo.processInfo.environment["HERDR_OPEN_SETTINGS"] == "1",
           !didAutoOpenSettings {
            didAutoOpenSettings = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.host?.openHerdrOverlay(split: state.sidebarSplit, keys: "\r")
            }
        }
        sidebar?.render(workspaces: state.workspaces,
                        focusedWorkspaceId: state.focusedWorkspaceId,
                        agents: state.agents,
                        focusedTabId: state.focusedTabId)
        tabStrip?.render(tabs: tabs, selectedId: focused)
    }

    private func updateChrome(from layout: [String: Any]) {
        guard let area = layout["area"] as? [String: Any] else { return }
        let columns = CGFloat((area["x"] as? Double) ?? 26)
        let rows = CGFloat((area["y"] as? Double) ?? 1)
        guard host?.chromeSidebarCols != columns || host?.chromeTopRows != rows else { return }
        host?.chromeSidebarCols = columns
        host?.chromeTopRows = rows
        host?.needsLayout = true
    }

    private func updateFocusedPane(from layout: [String: Any], snapshot: [String: Any]) {
        guard let paneId = layout["focused_pane_id"] as? String,
              let paneLayouts = layout["panes"] as? [[String: Any]],
              let rect = paneLayouts.first(where: { $0["pane_id"] as? String == paneId })?["rect"] as? [String: Any],
              let panes = snapshot["panes"] as? [[String: Any]],
              let terminalId = panes.first(where: { $0["pane_id"] as? String == paneId })?["terminal_id"] as? String
        else {
            host?.scrollChannel?.updateTarget(terminalId: nil, columns: 0, rows: 0)
            return
        }

        let columns = UInt16(clamping: Int((rect["width"] as? Double) ?? 0))
        let rows = UInt16(clamping: Int((rect["height"] as? Double) ?? 0))
        host?.scrollChannel?.updateTarget(
            terminalId: terminalId,
            columns: columns,
            rows: rows
        )
        host?.focusedPaneRect = NSRect(
            x: CGFloat((rect["x"] as? Double) ?? 0),
            y: CGFloat((rect["y"] as? Double) ?? 0),
            width: CGFloat(columns),
            height: CGFloat(rows)
        )
    }

    /// Sidebar width changes are terminal-area resizes: the constraint
    /// moves the host's leading edge, and the surface/grid pipeline
    /// (Resize → awaitingFullFrame → live-metrics crop) handles the rest.
    private func applySidebarWidth(_ width: CGFloat, collapsed: Bool) {
        sidebarWidth?.constant = width
        if !collapsed {
            UserDefaults.standard.set(Double(width), forKey: "sidebarWidth")
        }
        UserDefaults.standard.set(collapsed, forKey: "sidebarCollapsed")
    }
}
