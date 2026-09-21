import Foundation

// MARK: - ClientShellSnapshot JSON codec (endpoint snapshot channel)
//
// The daemon delivers snapshots as `EndpointControl{kind: "shell.snapshot.v1",
// data: <JSON>}` — serde_json, snake_case, NOT the bincode wire path
// (herdr-gpui session.rs: serde_json::from_str). Shapes verified against the
// upstream fixture endpoint-snapshot-v1.json.

extension ClientShellSnapshot: Decodable {
    enum CodingKeys: String, CodingKey {
        case bootId = "boot_id"
        case revision
        case configDiagnostic = "config_diagnostic"
        case productAnnouncement = "product_announcement"
        case updateAvailable = "update_available"
        case updateInstallCommand = "update_install_command"
        case serverKeybindingsToml = "server_keybindings_toml"
        case latestReleaseNotesAvailable = "latest_release_notes_available"
        case integrationUpdatesAvailable = "integration_updates_available"
        case worktreeDirectory = "worktree_directory"
        case releaseNotes = "release_notes"
        case focusedWorkspaceId = "focused_workspace_id"
        case focusedTabId = "focused_tab_id"
        case focusedPaneId = "focused_pane_id"
        case tabBarRight = "tab_bar_right"
        case tabBarRightSeparator = "tab_bar_right_separator"
        case agentViewLabel = "agent_view_label"
        case agentOrder = "agent_order"
        case workspaces, tabs, panes, agents, commands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bootId = try c.decode(String.self, forKey: .bootId)
        revision = try c.decode(UInt64.self, forKey: .revision)
        configDiagnostic = try c.decodeIfPresent(String.self, forKey: .configDiagnostic)
        productAnnouncement = try c.decodeIfPresent(
            ClientShellProductAnnouncement.self, forKey: .productAnnouncement)
        updateAvailable = try c.decodeIfPresent(String.self, forKey: .updateAvailable)
        updateInstallCommand = try c.decode(
            String.self, forKey: .updateInstallCommand)
        serverKeybindingsToml = try c.decodeIfPresent(
            String.self, forKey: .serverKeybindingsToml)
        latestReleaseNotesAvailable = try c.decode(
            Bool.self, forKey: .latestReleaseNotesAvailable)
        integrationUpdatesAvailable = try c.decode(
            Bool.self, forKey: .integrationUpdatesAvailable)
        worktreeDirectory = try c.decode(String.self, forKey: .worktreeDirectory)
        releaseNotes = try c.decodeIfPresent(
            ClientShellReleaseNotes.self, forKey: .releaseNotes)
        focusedWorkspaceId = try c.decodeIfPresent(
            String.self, forKey: .focusedWorkspaceId)
        focusedTabId = try c.decodeIfPresent(String.self, forKey: .focusedTabId)
        focusedPaneId = try c.decodeIfPresent(String.self, forKey: .focusedPaneId)
        tabBarRight = try c.decode([ClientShellTabStatusSegment].self, forKey: .tabBarRight)
        tabBarRightSeparator = try c.decode(
            String.self, forKey: .tabBarRightSeparator)
        agentViewLabel = try c.decodeIfPresent(String.self, forKey: .agentViewLabel)
        agentOrder = try c.decode([String].self, forKey: .agentOrder)
        workspaces = try c.decode([ClientShellWorkspace].self, forKey: .workspaces)
        tabs = try c.decode([ClientShellTab].self, forKey: .tabs)
        panes = try c.decode([ClientShellPane].self, forKey: .panes)
        agents = try c.decode([ClientShellAgent].self, forKey: .agents)
        commands = try c.decode([ClientShellCommand].self, forKey: .commands)
    }
}

// Simple members with snake_case-free keys decode via the tuple-bearing
// owners; explicit implementations keep synthesis in the declaring file.
extension ClientShellProductAnnouncement: Decodable {
    enum CodingKeys: String, CodingKey {
        case version, id, title, body, preview
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        preview = try c.decode(Bool.self, forKey: .preview)
    }
}
extension ClientShellReleaseNotes: Decodable {
    enum CodingKeys: String, CodingKey {
        case version, body, preview
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        body = try c.decode(String.self, forKey: .body)
        preview = try c.decode(Bool.self, forKey: .preview)
    }
}
extension ClientShellTabStatusSegment: Decodable {
    enum CodingKeys: String, CodingKey {
        case text, accent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        accent = try c.decode(Bool.self, forKey: .accent)
    }
}

extension AgentStatus: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "idle": self = .idle
        case "working": self = .working
        case "blocked": self = .blocked
        case "done": self = .done
        default: self = .unknown
        }
    }
}

extension ClientShellCommandAction: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? "Unknown"
        switch raw {
        case "Shell": self = .shell
        case "Pane": self = .pane
        case "Popup": self = .popup
        case "PluginAction": self = .pluginAction
        default: self = .unknown
        }
    }
}

extension ClientShellCommand: Decodable {
    enum CodingKeys: String, CodingKey {
        case commandId = "command_id"
        case bindingLabel = "binding_label"
        case bindingLabels = "binding_labels"
        case action
        case description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try c.decode(String.self, forKey: .commandId)
        bindingLabel = try c.decode(String.self, forKey: .bindingLabel)
        bindingLabels = try c.decode([String].self, forKey: .bindingLabels)
        action = try c.decode(ClientShellCommandAction.self, forKey: .action)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }
}

extension ClientShellWorktree: Decodable {
    enum CodingKeys: String, CodingKey {
        case key, label
        case isLinkedWorktree = "is_linked_worktree"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        isLinkedWorktree = try c.decode(Bool.self, forKey: .isLinkedWorktree)
    }
}

extension ClientShellWorkspace: Decodable {
    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case activeTabId = "active_tab_id"
        case newWorkspaceCwd = "new_workspace_cwd"
        case number, label
        case customLabel = "custom_label"
        case branch
        case gitAheadBehind = "git_ahead_behind"
        case tokens
        case worktree
        case focused
        case agentStatus = "agent_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        activeTabId = try c.decode(String.self, forKey: .activeTabId)
        newWorkspaceCwd = try c.decode(String.self, forKey: .newWorkspaceCwd)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.decode(String.self, forKey: .label)
        customLabel = try c.decode(Bool.self, forKey: .customLabel)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        if let pair = try c.decodeIfPresent([Int].self, forKey: .gitAheadBehind) {
            gitAheadBehind = (pair.first ?? 0, pair.last ?? 0)
        } else {
            gitAheadBehind = nil
        }
        tokens = (try c.decode([[String]].self, forKey: .tokens))
            .compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        worktree = try c.decodeIfPresent(ClientShellWorktree.self, forKey: .worktree)
        focused = try c.decode(Bool.self, forKey: .focused)
        agentStatus = try c.decode(AgentStatus.self, forKey: .agentStatus)
    }
}

extension ClientShellTab: Decodable {
    enum CodingKeys: String, CodingKey {
        case tabId = "tab_id"
        case workspaceId = "workspace_id"
        case number, label
        case customLabel = "custom_label"
        case zoomed, focused
        case agentStatus = "agent_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabId = try c.decode(String.self, forKey: .tabId)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.decode(String.self, forKey: .label)
        customLabel = try c.decode(Bool.self, forKey: .customLabel)
        zoomed = try c.decode(Bool.self, forKey: .zoomed)
        focused = try c.decode(Bool.self, forKey: .focused)
        agentStatus = try c.decode(AgentStatus.self, forKey: .agentStatus)
    }
}

extension ClientShellPane: Decodable {
    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case label, cwd
        case foregroundCwd = "foreground_cwd"
        case focused
        case rightClickPassthrough = "right_click_passthrough"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try c.decode(String.self, forKey: .paneId)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        tabId = try c.decode(String.self, forKey: .tabId)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        foregroundCwd = try c.decodeIfPresent(String.self, forKey: .foregroundCwd)
        focused = try c.decode(Bool.self, forKey: .focused)
        rightClickPassthrough = try c.decode(Bool.self, forKey: .rightClickPassthrough)
    }
}

extension ClientShellAgent: Decodable {
    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case name
        case displayAgent = "display_agent"
        case agent
        case title
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case agentStatus = "agent_status"
        case stateChangeSeq = "state_change_seq"
        case stateLabels = "state_labels"
        case tokens
        case focused
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try c.decode(String.self, forKey: .paneId)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        tabId = try c.decode(String.self, forKey: .tabId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        displayAgent = try c.decodeIfPresent(String.self, forKey: .displayAgent)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        terminalTitle = try c.decodeIfPresent(String.self, forKey: .terminalTitle)
        terminalTitleStripped = try c.decodeIfPresent(
            String.self, forKey: .terminalTitleStripped)
        agentStatus = try c.decode(AgentStatus.self, forKey: .agentStatus)
        stateChangeSeq = try c.decode(UInt64.self, forKey: .stateChangeSeq)
        stateLabels = (try c.decode([[String]].self, forKey: .stateLabels))
            .compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        tokens = (try c.decode([[String]].self, forKey: .tokens))
            .compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        focused = try c.decode(Bool.self, forKey: .focused)
    }
}

/// The snapshot channel kind (endpoint.rs ENDPOINT_SNAPSHOT_KIND).
let endpointSnapshotKind = "shell.snapshot.v1"
