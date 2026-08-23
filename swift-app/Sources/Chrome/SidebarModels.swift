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
    /// 第二行文本：详情（原始标题 → state label → cwd），页面层合成。
    let contextLine: String
    /// omp working 时标题里的盲文转圈字符（⠋⠙⠹…）：徽章原样显示，
    /// 随标题同步自然替换——无本地动画。
    let spinnerChar: Character?
}
