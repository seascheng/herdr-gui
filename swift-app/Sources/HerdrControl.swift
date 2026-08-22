import Foundation
import Darwin
import os

// MARK: - unified logger (vendored Ghostty embed calls HerdrLog too)

enum HerdrLog {
    private static let logger = Logger(subsystem: "com.hertty", category: "app")
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
    /// Navigation fallback only: the semantic API click-path replacement
    /// runs off the main thread so a slow handler never freezes chrome.
    private let asyncQueue = DispatchQueue(
        label: "herdr.api.fallback", qos: .userInitiated, attributes: .concurrent)

    init(socketPath: String = HerdrAPI.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func call(_ method: String, _ params: [String: Any],
              timeout: TimeInterval? = nil) -> [String: Any]? {
        guard let fd = UnixSocket.connect(path: socketPath) else { return nil }
        defer { Darwin.close(fd) }
        if let timeout {
            let seconds = max(1, Int(timeout.rounded(.up)))
            var value = timeval(tv_sec: seconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value,
                       socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value,
                       socklen_t(MemoryLayout<timeval>.size))
        }

        let request: [String: Any] = ["id": "hertty", "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A)
        guard UnixSocket.writeAll(fd: fd, data: data),
              let response = UnixSocket.readLine(fd: fd),
              let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = json["result"] as? [String: Any]
        else { return nil }
        return result
    }

    /// One-shot control request off the main thread. The herdr API is
    /// one-request-per-connection (verified), so every call dials its
    /// own socket — cheap locally, and off-main so a busy herdr can
    /// never freeze native chrome.
    func callAsync(_ method: String, _ params: [String: Any],
                   completion: @escaping ([String: Any]?) -> Void) {
        asyncQueue.async { [self] in
            let result = call(method, params, timeout: 3)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func focusTabAsync(_ tabId: String, completion: @escaping (Bool) -> Void) {
        callAsync("tab.focus", ["tab_id": tabId]) { completion($0 != nil) }
    }

    func focusWorkspaceAsync(_ workspaceId: String,
                             completion: @escaping (Bool) -> Void) {
        callAsync("workspace.focus", ["workspace_id": workspaceId]) {
            completion($0 != nil)
        }
    }

    func snapshot() -> [String: Any]? {
        call("session.snapshot", [:], timeout: 5)?["snapshot"] as? [String: Any]
    }


    /// Fire-and-forget control mutation: chrome actions (close/rename/
    /// create) must never block on the server. The completion (main
    /// queue) is the earliest point a re-read makes sense.
    func perform(_ method: String, _ params: [String: Any],
                 completion: (() -> Void)? = nil) {
        asyncQueue.async { [self] in
            _ = call(method, params, timeout: 5)
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    func closeTabAsync(_ tabId: String, completion: (() -> Void)? = nil) {
        perform("tab.close", ["tab_id": tabId], completion: completion)
    }

    func closeWorkspaceAsync(_ workspaceId: String,
                             completion: (() -> Void)? = nil) {
        perform("workspace.close", ["workspace_id": workspaceId],
                completion: completion)
    }

    func createWorkspaceAsync(_ completion: (() -> Void)? = nil) {
        perform("workspace.create", [:], completion: completion)
    }

    func renameTabAsync(_ tabId: String, to name: String) {
        perform("tab.rename", ["tab_id": tabId, "name": name])
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
        /// Tabs of EVERY workspace: optimistic navigation needs the
        /// target workspace's list before the server confirms the switch.
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
