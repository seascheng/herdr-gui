import Foundation

// MARK: - snapshot → native chrome model

/// Snapshot → the native chrome's data model: herdr's own sidebar
/// structure (spaces over agents) plus every workspace's tabs.
enum HerdrModel {
    struct TabRef { let tabId: String; let label: String }
    struct WorkspaceRef {
        let id: String
        let label: String
        let tabCount: Int
        let agentStatus: String
        let activeTabId: String?
    }
    struct AgentRef {
        let name: String
        var status: String
        let kind: String
        let tabId: String
        let tabLabel: String?
        let workspaceId: String
        let workspaceLabel: String?
        /// Monitoring context (AgentInfo): cwd / terminal title / any
        /// state_labels entry — shown as the agent row's second line.
        let cwd: String?
        let title: String?
        let stateLabel: String?
    }

    struct SidebarState {
        let label: String
        let focusedTabId: String?
        let sidebarSplit: Double
        /// Tabs of EVERY workspace: display steering addresses a tab by
        /// its index inside its own workspace, wherever that is.
        let tabsByWorkspace: [String: [TabRef]]
        let workspaces: [WorkspaceRef]
        let focusedWorkspaceId: String?
        let agents: [AgentRef]
    }

    static func sidebarState(_ snapshot: [String: Any]) -> SidebarState? {
        guard let workspacesRaw = snapshot["workspaces"] as? [[String: Any]],
              let focusedWs = snapshot["focused_workspace_id"] as? String,
              let ws = workspacesRaw.first(where: { $0["workspace_id"] as? String == focusedWs }),
              let tabsRaw = snapshot["tabs"] as? [[String: Any]]
        else { return nil }

        // herdr's own sidebar workspaces/agents split — the launcher row
        // math for opening the TUI global menu depends on it.
        let split = (snapshot["sidebar_section_split"] as? Double) ?? 0.5

        let label = ws["label"] as? String ?? focusedWs
        let focusedTabId = snapshot["focused_tab_id"] as? String
        let tabsByWorkspace = Dictionary(grouping: tabsRaw, by: {
            ($0["workspace_id"] as? String) ?? ""
        }).mapValues { tabs in
            tabs.compactMap { tab -> TabRef? in
                guard let tabId = tab["tab_id"] as? String else { return nil }
                return TabRef(tabId: tabId, label: (tab["label"] as? String) ?? tabId)
            }
        }

        let workspaces = workspacesRaw.compactMap { w -> WorkspaceRef? in
            guard let id = w["workspace_id"] as? String else { return nil }
            return WorkspaceRef(
                id: id,
                label: (w["label"] as? String) ?? id,
                tabCount: (w["tab_count"] as? Int) ?? 0,
                agentStatus: (w["agent_status"] as? String) ?? "unknown",
                activeTabId: w["active_tab_id"] as? String)
        }

        let workspaceLabels = Dictionary(
            uniqueKeysWithValues: workspaces.map { ($0.id, $0.label) })
        let tabLabels = Dictionary(uniqueKeysWithValues:
            tabsByWorkspace.values.flatMap { $0 }.map { ($0.tabId, $0.label) })
        let agents = (snapshot["agents"] as? [[String: Any]] ?? []).compactMap { a -> AgentRef? in
            guard let tabId = a["tab_id"] as? String else { return nil }
            let name = (a["name"] as? String)
                ?? (a["display_agent"] as? String)
                ?? (a["agent"] as? String)
                ?? (a["terminal_title_stripped"] as? String)
                ?? "agent"
            let kind = (a["agent"] as? String)
                ?? (a["display_agent"] as? String)
                ?? name
            let stateLabel = (a["state_labels"] as? [String: String])?
                .values.sorted().first
            return AgentRef(
                name: name,
                status: (a["agent_status"] as? String) ?? "unknown",
                kind: kind,
                tabId: tabId,
                tabLabel: tabLabels[tabId],
                workspaceId: (a["workspace_id"] as? String) ?? "",
                workspaceLabel: workspaceLabels[(a["workspace_id"] as? String) ?? ""],
                cwd: (a["cwd"] as? String),
                title: (a["terminal_title_stripped"] as? String),
                stateLabel: stateLabel)
        }
        return SidebarState(
            label: label,
            focusedTabId: focusedTabId,
            sidebarSplit: split,
            tabsByWorkspace: tabsByWorkspace,
            workspaces: workspaces,
            focusedWorkspaceId: focusedWs,
            agents: agents)
    }
}
