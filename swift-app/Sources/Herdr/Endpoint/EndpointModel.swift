import Foundation

// MARK: - ClientShellSnapshot → native chrome model (EndpointModel.swift)
//
// The endpoint snapshot is typed: statuses are an enum, agents carry their
// pane id (for cwd lookup), workspaces carry labels/branches. No defensive
// multi-key JSON guessing — the projection below is total.

extension HerdrModel {
    static func statusString(_ status: AgentStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .blocked: return "blocked"
        case .done: return "done"
        case .unknown: return "unknown"
        }
    }

    static func sidebarState(_ snapshot: ClientShellSnapshot) -> HerdrModel.SidebarState {
        let tabsByWorkspace = Dictionary(grouping: snapshot.tabs, by: \.workspaceId)
            .mapValues { tabs in
                tabs.map { TabRef(tabId: $0.tabId, label: $0.label) }
            }
        let workspaceLabels = Dictionary(
            uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceId, $0.label) })
        let paneCwds = Dictionary(
            snapshot.panes.compactMap { pane in pane.cwd.map { (pane.paneId, $0) } },
            uniquingKeysWith: { first, _ in first })
        let tabLabels = Dictionary(
            uniqueKeysWithValues: snapshot.tabs.map { ($0.tabId, $0.label) })

        let workspaces = snapshot.workspaces.map { ws in
            WorkspaceRef(
                id: ws.workspaceId,
                label: ws.label,
                tabCount: tabsByWorkspace[ws.workspaceId]?.count ?? 0,
                agentStatus: statusString(ws.agentStatus),
                activeTabId: ws.activeTabId)
        }

        let agents = snapshot.agents.map { agent in
            let kind = agent.agent ?? agent.displayAgent ?? agent.name
            let name = agent.name ?? agent.displayAgent ?? kind
                ?? agent.terminalTitleStripped ?? "agent"
            return AgentRef(
                name: name,
                status: statusString(agent.agentStatus),
                kind: kind ?? name,
                tabId: agent.tabId,
                tabLabel: tabLabels[agent.tabId],
                workspaceId: agent.workspaceId,
                workspaceLabel: workspaceLabels[agent.workspaceId],
                cwd: paneCwds[agent.paneId],
                title: agent.terminalTitle ?? agent.terminalTitleStripped,
                stateLabel: agent.stateLabels.first?.1)
        }

        let focusedLabel = snapshot.focusedWorkspaceId
            .flatMap { id in snapshot.workspaces.first { $0.workspaceId == id } }
            .map(\.label) ?? (snapshot.focusedWorkspaceId ?? "")
        return SidebarState(
            label: focusedLabel,
            focusedTabId: snapshot.focusedTabId,
            sidebarSplit: 0.5,  // TUI layout value; unused by endpoint chrome
            tabsByWorkspace: tabsByWorkspace,
            workspaces: workspaces,
            agents: agents,
            focusedWorkspaceId: snapshot.focusedWorkspaceId)
    }
}
