import Cocoa

// MARK: - herdr page (one endpoint connection per server)

/// A native-chrome page over one herdr server: sidebar + tab strip + the
/// cell canvas. Everything underneath is the endpoint protocol — snapshots
/// push the chrome model, surfaces push the painted grid, navigation goes
/// through real API requests (`tab.focus`, `workspace.create`, …). There is
/// no TUI mirroring and no display steering.
final class HerdrPageController {
    static let defaultClientSocketPath = NSString(
        string: "~/.config/herdr/herdr-client.sock").expandingTildeInPath

    let view = NSView(frame: .zero)
    let spec: SessionSpec

    private let client: EndpointClient
    private let canvas = CellSurfaceView()
    private var sidebar: SidebarView?
    private var tabStrip: TabStripView?

    /// Last applied sidebar state (rendered chrome truth).
    private var sidebarState: HerdrModel.SidebarState?
    private var focusedTabId = ""
    private var sidebarCollapsed = false
    private var sidebarWidth: NSLayoutConstraint?
    private var settingsPanel: SettingsPanelController?

    init(spec: SessionSpec, clientSocketPath: String) {
        self.spec = spec
        client = EndpointClient(socketPath: clientSocketPath,
                                cellWidth: UInt32(canvas.cellWidth),
                                cellHeight: UInt32(canvas.cellHeight))
        buildUI()
        wireClient()
        client.start()
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
            self?.reloadConfig()
        }
        sidebar.onOpenSettings = { [weak self] in
            guard let self else { return }
            if self.settingsPanel == nil {
                self.settingsPanel = SettingsPanelController(
                    spec: self.spec,
                    reload: { [weak self] in self?.reloadConfig() })
            }
            self.settingsPanel?.show(parent: self.view.window)
        }
        // Keybinds browsing was a TUI overlay; the endpoint replacement
        // (command palette over snapshot `commands`) lands with Phase 2.
        sidebar.onOpenKeybinds = nil

        let canvas = self.canvas
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)

        let sidebarWidth = NSLayoutConstraint(
            item: sidebar, attribute: .width, relatedBy: .equal,
            toItem: nil, attribute: .notAnAttribute, multiplier: 1,
            constant: CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth")))
        if sidebarWidth.constant < 180 { sidebarWidth.constant = 200 }
        sidebarWidth.isActive = true
        self.sidebarWidth = sidebarWidth
        sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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
            self?.request("workspace.focus", ["workspace_id": $0])
        }
        sidebar.onNewWorkspace = { [weak self] in
            self?.request("workspace.create", [:])
        }
        sidebar.onCloseWorkspace = { [weak self] in
            self?.request("workspace.close", ["workspace_id": $0])
        }
        sidebar.onAgentSelected = { [weak self] in
            self?.request("tab.focus", ["tab_id": $0])
        }
        tabStrip.onTabIdSelected = { [weak self] in
            self?.request("tab.focus", ["tab_id": $0])
        }
        tabStrip.onCloseTab = { [weak self] tabId in
            self?.request("tab.close", ["tab_id": tabId])
        }
        tabStrip.onRenameTab = { [weak self] tabId, name in
            self?.request("tab.rename", ["tab_id": tabId, "name": name])
        }
        tabStrip.onNewTab = { [weak self] in self?.menuNewTab() }

        canvas.onPaneInput = { [weak self] paneId, events in
            self?.client.sendPaneInput(paneId: paneId, events: events)
        }
        canvas.onPopupInput = { [weak self] terminalId, events in
            self?.client.sendPopupInput(terminalId: terminalId, events: events)
        }
        canvas.onResize = { [weak self] size, cellWidth, cellHeight in
            self?.client.resize(cellWidth: cellWidth, cellHeight: cellHeight,
                                cols: size.cols, rows: size.rows)
        }
        canvas.onOpenURL = { url in
            NSWorkspace.shared.open(url)
        }
        canvas.onFocusPane = { [weak self] paneId in
            self?.request("pane.focus", ["pane_id": paneId])
        }
        canvas.onRequest = { [weak self] method, params in
            self?.request(method, params)
        }
    }

    private func wireClient() {
        client.onSnapshot = { [weak self] snapshot in
            self?.applySidebarState(HerdrModel.sidebarState(snapshot))
        }
        client.onSurface = { [weak self] surface in
            self?.canvas.update(surface: surface)
        }
        client.onTitle = { [weak self] title in
            self?.applyFocusedTitle(title)
        }
        client.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connected:
                self.sidebar?.serverLabel = self.spec.label
            case .connecting, .disconnected:
                self.sidebar?.serverLabel = self.spec.label + " · connecting…"
            case .failed(let reason):
                self.sidebar?.serverLabel = self.spec.label + " · offline"
                HerdrLog.error("endpoint: \(reason)")
            }
        }
    }

    // MARK: surface / lifecycle

    var keyView: NSView? { canvas }
    /// No libghostty surface on herdr pages anymore; the ghostty surface
    /// registry lookup (notifications) only applies to plain terminal pages.
    var surfaceView: Ghostty.SurfaceView? { nil }

    func focusTerminal() {
        if let keyView { keyView.window?.makeFirstResponder(keyView) }
    }

    func shutdown() {
        client.stop()
        canvas.removeFromSuperview()
    }

    // MARK: config actions

    /// Reload Config — `server.reload_config` over the endpoint request
    /// lane, fire-and-forget so chrome never waits on the server.
    func reloadConfig() {
        client.request(method: "server.reload_config")
    }

    /// Open Config File — local config.toml in the default editor,
    /// created empty when missing (herdr accepts an empty config; the
    /// Settings panel writes the same file).
    func openConfig() {
        guard case .local = spec.target else { return }
        let path = HerdrConfigStore.localPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(
                at: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent),
                withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path) as URL)
    }

    // MARK: menu actions

    func menuNewTab() {
        let workspaceId = sidebarState?.focusedWorkspaceId
        var params: [String: Any] = [:]
        if let workspaceId { params["workspace_id"] = workspaceId }
        request("tab.create", params)
    }

    func menuCloseTab() {
        let tabId = focusedTabId
        guard !tabId.isEmpty else { return }
        request("tab.close", ["tab_id": tabId])
    }

    private func request(_ method: String, _ params: [String: Any]) {
        client.request(method: method, params: params) { object in
            if let error = object?["error"] as? [String: Any],
               let message = error["message"] as? String {
                HerdrLog.warning("endpoint \(method): \(message)")
            }
        }
    }

    // MARK: chrome model

    private func applySidebarState(_ state: HerdrModel.SidebarState) {
        sidebarState = state
        let tabs = state.tabsByWorkspace[state.focusedWorkspaceId ?? ""] ?? []
        let focused = state.focusedTabId ?? tabs.first?.tabId ?? ""
        focusedTabId = focused
        canvas.contextTabId = state.focusedTabId
        sidebar?.render(
            workspaces: state.workspaces.map(Self.sidebarWorkspace),
            focusedWorkspaceId: state.focusedWorkspaceId,
            agents: state.agents.map(Self.sidebarAgent),
            focusedTabId: state.focusedTabId)
        tabStrip?.render(tabs: tabs.map { (id: $0.tabId, name: $0.label) },
                         selectedId: focused)
    }

    /// Live title push → focused agent's row (bypasses the snapshot cycle
    /// entirely; subsequent snapshots re-sync the rest).
    private func applyFocusedTitle(_ title: String?) {
        guard let title, !title.isEmpty,
              var state = sidebarState,
              let focused = state.focusedTabId,
              let idx = state.agents.firstIndex(where: { $0.tabId == focused }),
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

    /// Sidebar width changes shrink the terminal canvas; the resize
    /// debounce reports the new viewport to the daemon.
    private func applySidebarWidth(_ width: CGFloat, collapsed: Bool) {
        sidebarWidth?.constant = width
        if !collapsed {
            UserDefaults.standard.set(Double(width), forKey: "sidebarWidth")
        }
        UserDefaults.standard.set(collapsed, forKey: "sidebarCollapsed")
    }
}
