import Foundation

// MARK: - sidebar view models

/// Sidebar 的展示模型。Chrome 层不认识 herdr 领域类型（HerdrModel）：
/// 页面层负责把快照模型映射到这里，字段即视图所需。
struct SidebarWorkspaceModel {
    let id: String
    let label: String
    let tabCount: Int
    let status: String
}

struct SidebarAgentModel {
    let name: String
    let status: String
    /// AgentIconCatalog 的键（agent kind）。
    let iconKind: String
    /// 该 agent 所在 tab 的 id（点击回调携带）。
    let tabId: String
    /// 已合成的第二行文本（状态 · 详情），视图不再做拼接逻辑。
    let contextLine: String
}
