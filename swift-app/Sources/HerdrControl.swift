import Foundation
import Darwin
import os

// MARK: - unified logger (vendored Ghostty embed calls HerdrLog too)

enum HerdrLog {
    private static let logger = Logger(subsystem: "com.herdr.mirror", category: "herdr")
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
    static func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
}

// MARK: - herdr NDJSON control plane (herdr.sock)

final class HerdrAPI {
    static let defaultSocketPath = NSString(
        string: "~/.config/herdr/herdr.sock").expandingTildeInPath
    static let defaultClientSocketPath = NSString(
        string: "~/.config/herdr/herdr-client.sock").expandingTildeInPath

    let socketPath: String

    init(socketPath: String = HerdrAPI.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func call(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        guard let fd = UnixSocket.connect(path: socketPath) else { return nil }
        defer { Darwin.close(fd) }

        let request: [String: Any] = ["id": "herdr-mirror", "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A)
        guard UnixSocket.writeAll(fd: fd, data: data),
              let response = UnixSocket.readLine(fd: fd),
              let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = json["result"] as? [String: Any]
        else { return nil }
        return result
    }

    func snapshot() -> [String: Any]? {
        call("session.snapshot", [:])?["snapshot"] as? [String: Any]
    }

    func focusTab(_ tabId: String) {
        _ = call("tab.focus", ["tab_id": tabId])
    }

    func closeTab(_ tabId: String) {
        _ = call("tab.close", ["tab_id": tabId])
    }

    func renameTab(_ tabId: String, to name: String) {
        _ = call("tab.rename", ["tab_id": tabId, "name": name])
    }

    func focusWorkspace(_ workspaceId: String) {
        _ = call("workspace.focus", ["workspace_id": workspaceId])
    }

    func closeWorkspace(_ workspaceId: String) {
        _ = call("workspace.close", ["workspace_id": workspaceId])
    }
}

/// Snapshot → the native chrome's data model: herdr's own sidebar
/// structure (spaces over agents) plus the focused workspace's tabs.
enum HerdrModel {
    struct TabRef { let tabId: String; let label: String }
    struct WorkspaceRef {
        let id: String
        let label: String
        let tabCount: Int
        let agentStatus: String
    }
    struct AgentRef {
        let name: String
        let status: String
        let kind: String
        let tabId: String
        let workspaceId: String
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
        let tabs: [TabRef]
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
        let tabs = tabsRaw
            .filter { $0["workspace_id"] as? String == focusedWs }
            .compactMap { (t: [String: Any]) -> TabRef? in
                guard let tabId = t["tab_id"] as? String else { return nil }
                return TabRef(tabId: tabId, label: (t["label"] as? String) ?? tabId)
            }

        let workspaces = workspacesRaw.compactMap { w -> WorkspaceRef? in
            guard let id = w["workspace_id"] as? String else { return nil }
            return WorkspaceRef(
                id: id,
                label: (w["label"] as? String) ?? id,
                tabCount: (w["tab_count"] as? Int) ?? 0,
                agentStatus: (w["agent_status"] as? String) ?? "unknown")
        }

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
                workspaceId: (a["workspace_id"] as? String) ?? "",
                cwd: (a["cwd"] as? String),
                title: (a["terminal_title_stripped"] as? String),
                stateLabel: stateLabel)
        }
        return SidebarState(
            label: label,
            focusedTabId: focusedTabId,
            sidebarSplit: split,
            tabs: tabs,
            workspaces: workspaces,
            focusedWorkspaceId: focusedWs,
            agents: agents)
    }
}
