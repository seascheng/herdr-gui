import Foundation

/// ClientShellSnapshot → HerdrModel.SidebarState projection.
enum EndpointModelTests {
    static func register() {
        let ok1 = TestRegistry.add("model: snapshot projects sidebar state") {
            let snapshot = EndpointWireTests.makeSnapshot()
            let state = HerdrModel.sidebarState(snapshot)
            expectEq(state.focusedWorkspaceId ?? "", "w1", "focused workspace")
            expectEq(state.focusedTabId ?? "", "w1:t1", "focused tab")
            expectEq(state.workspaces.count, 1, "workspace count")
            let ws = state.workspaces[0]
            expectEq(ws.id, "w1", "workspace id")
            expectEq(ws.label, "repo", "workspace label")
            expectEq(ws.tabCount, 1, "tab count")
            expectEq(ws.activeTabId ?? "", "w1:t1", "active tab")
            expectEq(ws.agentStatus, "idle", "workspace status")
            expectEq(state.tabsByWorkspace["w1"]?.first?.label ?? "", "main", "tab label")
            expectEq(state.agents.count, 1, "agent count")
            let agent = state.agents[0]
            expectEq(agent.name, "reviewer", "agent name")
            expectEq(agent.kind, "claude", "agent kind")
            expectEq(agent.status, "blocked", "agent status")
            expectEq(agent.tabId, "w1:t1", "agent tab")
            expectEq(agent.cwd ?? "", "/repo", "agent cwd from pane")
            expectEq(agent.title ?? "", "Claude Review", "agent title")
            expectEq(agent.stateLabel ?? "", "waiting", "state label")
            expectEq(agent.workspaceLabel ?? "", "repo", "workspace label")
        }
        let ok2 = TestRegistry.add("model: agent fallbacks and pane cwd lookup") {
            var snapshot = EndpointWireTests.makeSnapshot()
            // Strip identifying fields → fallback chain.
            snapshot.agents[0].name = nil
            snapshot.agents[0].displayAgent = nil
            snapshot.agents[0].agent = nil
            snapshot.agents[0].terminalTitle = nil
            snapshot.agents[0].stateLabels = []
            // Pane without cwd → agent second line falls back to title.
            snapshot.panes[0].cwd = nil
            let state = HerdrModel.sidebarState(snapshot)
            let agent = state.agents[0]
            expectEq(agent.name, "Claude Review", "name fallback to stripped title")
            expectEq(agent.kind, "Claude Review", "kind fallback")
            expect(agent.cwd == nil, "no pane cwd")
            expectEq(agent.title ?? "", "Claude Review", "title kept")
            expect(agent.stateLabel == nil, "no state labels")
        }
        let ok3 = TestRegistry.add("model: status string mapping") {
            expectEq(HerdrModel.statusString(.idle), "idle", "idle")
            expectEq(HerdrModel.statusString(.working), "working", "working")
            expectEq(HerdrModel.statusString(.blocked), "blocked", "blocked")
            expectEq(HerdrModel.statusString(.done), "done", "done")
            expectEq(HerdrModel.statusString(.unknown), "unknown", "unknown")
        }
        expect(ok1 && ok2 && ok3, "registration")
    }
}
