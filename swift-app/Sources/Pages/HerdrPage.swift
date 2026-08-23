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
    /// Last applied sidebar state (rendered chrome truth).
    private var sidebarState: HerdrModel.SidebarState?
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
        host.attach(
            app: AppDelegate.ghosttyApp(),
            stream: HerdrAttachSession(socketPath: clientSocketPath),
            scrollChannel: HerdrScrollChannel(clientSocketPath: clientSocketPath))

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

        sidebar.onWorkspaceSelected = { [weak self] in
            self?.focusWorkspace($0)
        }
        sidebar.onNewWorkspace = { [weak self] in
            self?.api.createWorkspaceAsync { [weak self] in self?.reconcileNow() }
        }
        sidebar.onCloseWorkspace = { [weak self] in
            self?.api.closeWorkspaceAsync($0) { [weak self] in self?.reconcileNow() }
        }
        sidebar.onAgentSelected = { [weak self] in
            self?.focusAgent($0)
        }
        tabStrip.onTabIdSelected = { [weak self] in
            self?.focusTab($0)
        }
        tabStrip.onCloseTab = { [weak self] tabId in
            self?.closeTab(tabId)
        }
        tabStrip.onRenameTab = { [weak self] tabId, name in
            self?.api.renameTabAsync(tabId, to: name)
        }
        tabStrip.onNewTab = { [weak self] in self?.newTab() }
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
        // Frame-rate title pushes (server window_title template): fold
        // straight into the focused agent's row — no snapshot round trip.
        host?.onFocusedTitle = { [weak self] title in
            self?.applyFocusedTitle(title)
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

    /// New tab goes through herdr's own `new_tab` binding (prefix+c):
    /// the TUI creates the tab AND moves its view — the API's tab.create
    /// changes logical focus only and leaves the displayed pane behind.
    /// herdr's new-tab flow then parks on a name-input overlay (the
    /// "no bash after new tab" symptom); auto-confirm the default name
    /// so one click lands on a live prompt. A stray Return in a future
    /// herdr without the input just submits an empty shell line.
    private func newTab() {
        host?.sendPrefix("c")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.host?.sendKeys("\r")
        }
    }

    func menuNewTab() { newTab() }
    func menuCloseTab() {
        closeTab(focusedTabId)
    }

    // MARK: navigation
    //
    // Two channels, by what they move. Display-steering operations use
    // herdr's documented keybindings over the attach stream (the app
    // frame follows TUI input only); pure-data operations use the API.
    // herdr's events reconcile the native chrome within ~10ms either way.

    /// Tab focus uses the indexed `switch_tab` binding (prefix+1..9).
    /// Beyond nine tabs the binding cannot address the tab; fall back to
    /// the API (logical focus moves, the displayed pane does not).
    private func focusTab(_ tabId: String) {
        guard let state = sidebarState,
              state.focusedTabId != tabId,
              let workspaceId = state.focusedWorkspaceId,
              let tabs = state.tabsByWorkspace[workspaceId],
              let index = tabs.firstIndex(where: { $0.tabId == tabId })
        else { return }
        if index < 9 {
            host?.sendPrefix(String(index + 1))
        } else {
            HerdrLog.warning("focusTab: tab index \(index) beyond switch_tab range; API fallback")
            api.focusTabAsync(tabId) { [weak self] _ in self?.reconcileNow() }
        }
    }

    /// Closing the displayed tab goes through `close_tab` (prefix+shift+x)
    /// so herdr moves its own view to the next tab; closing a background
    /// tab is pure data — the API path never disturbs the display.
    private func closeTab(_ tabId: String) {
        if tabId == focusedTabId {
            host?.sendPrefix("X")
        } else {
            api.closeTabAsync(tabId) { [weak self] in self?.reconcileNow() }
        }
    }

    /// Agent click: API focus is the truth for chrome; the display
    /// follows the bound `focus_agent` chord (prefix+alt+N by visible
    /// agent position) when the binding exists.
    private func focusAgent(_ tabId: String) {
        guard let state = sidebarState,
              state.focusedTabId != tabId,
              let index = state.agents.firstIndex(where: { $0.tabId == tabId })
        else { return }
        api.focusTabAsync(tabId) { [weak self] _ in
            self?.reconcileNow()
        }
        guard index < 9 else { return }
        host?.sendPrefixChord(Character(String(index + 1)), .alternate)
    }

    private func focusWorkspace(_ workspaceId: String) {
        guard let state = sidebarState,
              state.focusedWorkspaceId != workspaceId,
              let workspace = state.workspaces.first(where: { $0.id == workspaceId })
        else { return }
        focusWorkspaceAndTab(
            workspaceId: workspaceId,
            tabId: workspace.activeTabId ?? state.tabsByWorkspace[workspaceId]?.first?.tabId)
    }

    /// Cross-workspace steering. The API call is the source of truth for
    /// logical focus (chrome follows via events); the display only moves
    /// on TUI input, so we also send the indexed workspace chord. That
    /// requires the `switch_workspace = "prefix+shift+1..9"` binding
    /// (unset in herdr's default config — an unbound chord is a no-op,
    /// leaving the view on the old workspace until herdr's app-render
    /// follows API focus server-side).
    private func focusWorkspaceAndTab(workspaceId: String, tabId: String?) {
        guard let state = sidebarState else { return }
        api.focusWorkspaceAsync(workspaceId) { [weak self] _ in
            self?.reconcileNow()
        }
        guard let wsIndex = state.workspaces.firstIndex(where: { $0.id == workspaceId }),
              wsIndex < 9
        else { return }
        host?.sendPrefixChord(Character(String(wsIndex + 1)), .shift)
        guard let tabId,
              let tabs = state.tabsByWorkspace[workspaceId],
              let index = tabs.firstIndex(where: { $0.tabId == tabId }),
              index < 9
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.host?.sendPrefix(String(index + 1))
        }
    }

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

        sidebarSplit = state.sidebarSplit
        if ProcessInfo.processInfo.environment["HERDR_OPEN_SETTINGS"] == "1",
           !didAutoOpenSettings {
            didAutoOpenSettings = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.host?.openHerdrOverlay(split: state.sidebarSplit, keys: "\r")
            }
        }
        applySidebarState(state)
    }

    private func applySidebarState(_ state: HerdrModel.SidebarState) {
        sidebarState = state
        let tabs = state.tabsByWorkspace[state.focusedWorkspaceId ?? ""] ?? []
        let focused = state.focusedTabId ?? tabs.first?.tabId ?? ""
        focusedTabId = focused
        sidebar?.render(
            workspaces: state.workspaces.map(Self.sidebarWorkspace),
            focusedWorkspaceId: state.focusedWorkspaceId,
            agents: state.agents.map(Self.sidebarAgent),
            focusedTabId: state.focusedTabId)
        tabStrip?.render(tabs: tabs.map { (id: $0.tabId, name: $0.label) },
                         selectedId: focused)
    }

    /// Live title push → focused agent's row (bypasses the snapshot
    /// cycle entirely; the 2s poll re-syncs the rest).
    private func applyFocusedTitle(_ title: String?) {
        guard let title, !title.isEmpty,
              var state = sidebarState,
              let focusedTabId = state.focusedTabId,
              let idx = state.agents.firstIndex(where: { $0.tabId == focusedTabId }),
              state.agents[idx].title != title
        else { return }
        state.agents[idx].title = title
        applySidebarState(state)
    }

    // MARK: domain → sidebar view models

    private static func sidebarWorkspace(_ ws: HerdrModel.WorkspaceRef)
        -> SidebarWorkspaceModel {
        SidebarWorkspaceModel(id: ws.id, label: ws.label,
                              tabCount: ws.tabCount, status: ws.agentStatus)
    }

    /// Agent 第二行的详情（标题 → state label → cwd 尾段）属于领域
    /// 解读，留在页面层；原始标题（含 omp 的转圈字符）原样透传。
    private static func sidebarAgent(_ agent: HerdrModel.AgentRef)
        -> SidebarAgentModel {
        func base(_ path: String) -> String {
            (path as NSString).lastPathComponent
        }
        let detail = agent.title ?? agent.stateLabel ?? agent.cwd.map(base)
        let contextLine = (detail ?? "").isEmpty || detail == agent.name
            ? agent.status
            : detail!
        return SidebarAgentModel(
            name: agent.name, status: agent.status,
            iconKind: agent.kind, tabId: agent.tabId,
            contextLine: contextLine,
            spinnerChar: agent.title?.first(where: isBrailleSpinner))
    }

    /// Braille spinner block (U+2800…U+28FF) — omp writes it into the
    /// title while working.
    private static func isBrailleSpinner(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { (0x2800...0x28FF).contains($0.value) }
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
