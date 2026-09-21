import Foundation

/// Wire codec tests: frozen-byte regressions, round-trips, and the atomic
/// patch/validate matrices ported from herdr-protocol frame.rs.
enum EndpointWireTests {
    static func makeFrame(w: UInt16 = 2, h: UInt16 = 2) -> PaneSurfaceFrame {
        let cells = (0..<Int(w) * Int(h)).map { i in
            CellData(symbol: i == 0 ? "A" : " ", fg: 0, bg: 0,
                     modifier: 0, skip: false, hyperlink: nil)
        }
        return PaneSurfaceFrame(
            bootId: "boot", projectionRevision: 1, surfaceRevision: 1,
            frame: FrameData(cells: cells, width: w, height: h,
                             cursor: CursorState(x: 0, y: 0, visible: true, shape: 0),
                             hyperlinks: [], graphics: []),
            panes: [PaneSurfacePane(paneId: "p1", contentRevision: 1,
                                    rect: SurfaceRect(x: 0, y: 0, width: w, height: h),
                                    innerRect: SurfaceRect(x: 0, y: 0, width: w, height: h),
                                    scrollbarRect: nil, scroll: nil, focused: true,
                                    mouseReporting: false, sgrPixelMouse: false,
                                    alternateScreenActive: false,
                                    pixelWidth: 100, pixelHeight: 100)],
            splits: [], popup: nil, graphics: SurfaceGraphicsScene())
    }

    static func register() {
        let ok1 = TestRegistry.add("wire: EndpointControl frozen bytes") {
            let msg = EndpointClientMessage.endpointControl(
                kind: "endpoint.hello.v1", data: "{}")
            let framed = msg.encoded()
            var payload: [UInt8] = [20, 17]  // variant 20, string len 17
            payload.append(contentsOf: Array("endpoint.hello.v1".utf8))
            payload.append(contentsOf: [2, 123, 125])  // string len 2 + "{}"
            var expected: [UInt8] = [UInt8(payload.count), 0, 0, 0]
            expected.append(contentsOf: payload)
            expectEq(framed, expected, "EndpointControl encoding")
            let back = try EndpointClientMessage.decode(payload: Array(framed[4...]))
            guard case let .endpointControl(kind, data) = back else {
                return expect(false, "round-trip case")
            }
            expectEq(kind, "endpoint.hello.v1", "kind")
            expectEq(data, "{}", "data")
        }
        let ok2 = TestRegistry.add("wire: CellData frozen bytes") {
            let cell = CellData(symbol: "A", fg: 0x02FF8000, bg: 0,
                                modifier: 1, skip: false, hyperlink: nil)
            var w = WireWriter()
            cell.encode(to: &w)
            let expected: [UInt8] = [
                1, 65,                        // symbol "A"
                252, 0x00, 0x80, 0xFF, 0x02,  // fg varint u32 0x02FF8000
                0,                            // bg
                1,                            // modifier bold
                0,                            // skip
                0,                            // hyperlink None
            ]
            expectEq(w.buf, expected, "CellData bytes")
            var r = BincodeReader(expected)
            let back = try CellData(from: &r)
            expectEq(back.symbol, "A", "symbol")
            expectEq(back.fg, 0x02FF8000, "fg")
            expectEq(back.modifier, 1, "modifier")
            expect(r.remaining == 0, "trailing")
        }
        let ok3 = TestRegistry.add("wire: ClientShellPaneInput round-trip") {
            let key = EndpointClientMessage.clientShellPaneInput(
                paneId: "p1",
                events: [.key(code: .char("x"), modifiers: 2, kind: .press,
                              repeatCount: 1, shiftedCodepoint: nil,
                              generatedText: nil, tracksRelease: false,
                              physicalKeyId: nil, windowsRecord: nil),
                         .textCommit("héllo"),
                         .mouse(kind: .scrollUp,
                                position: .cell(column: 3, row: 4),
                                geometry: ClientMouseGeometry(
                                    cols: 80, rows: 24, widthPx: 640, heightPx: 480),
                                modifiers: 0, lines: 2),
                         .paste("clip")])
            let framed = key.encoded()
            let back = try EndpointClientMessage.decode(payload: Array(framed[4...]))
            guard case let .clientShellPaneInput(paneId, events) = back else {
                return expect(false, "case")
            }
            expectEq(paneId, "p1", "paneId")
            expectEq(events.count, 4, "events")
            guard case let .key(code, mods, kind, repeatCount, shifted, gen,
                                track, phys, win) = events[0] else {
                return expect(false, "key case")
            }
            expectEq(code, ClientKeyCode.char("x"), "code")
            expectEq(mods, 2, "modifiers")
            expectEq(kind, ClientKeyKind.press, "kind")
            expectEq(repeatCount, 1, "repeat")
            expect(shifted == nil && gen == nil && !track && phys == nil && win == nil,
                   "optionals")
            guard case let .textCommit(text) = events[1] else { return expect(false, "tc") }
            expectEq(text, "héllo", "text")
            guard case let .mouse(kind2, pos, geo, mods2, lines) = events[2] else {
                return expect(false, "mouse case")
            }
            expectEq(kind2, ClientMouseKind.scrollUp, "mouse kind")
            expectEq(pos, ClientMousePosition.cell(column: 3, row: 4), "pos")
            expectEq(geo?.cols ?? 0, 80, "geo")
            expectEq(mods2, 0, "mouse mods")
            expectEq(lines, 2, "lines")
            guard case let .paste(p) = events[3] else { return expect(false, "paste") }
            expectEq(p, "clip", "paste text")
        }
        let ok4 = TestRegistry.add("wire: PaneSurfaceFrame round-trip") {
            var f = makeFrame()
            f.popup = ClientShellPopupSurface(
                terminalId: "pop", title: "T",
                width: .cells(20), height: .percent(50),
                frame: FrameData(cells: [CellData(symbol: "x", fg: 0, bg: 0,
                                                  modifier: 0, skip: false, hyperlink: nil)],
                                 width: 1, height: 1, cursor: nil,
                                 hyperlinks: ["https://herdr.dev"], graphics: []),
                mouseReporting: false, sgrPixelMouse: false,
                pixelWidth: 10, pixelHeight: 10)
            f.frame.cells[1].hyperlink = 0
            f.frame.hyperlinks = ["https://herdr.dev"]
            f.splits = [PaneSurfaceSplit(direction: .vertical, pos: 1,
                                         area: SurfaceRect(x: 0, y: 0, width: 2, height: 2),
                                         hitRect: SurfaceRect(x: 2, y: 0, width: 1, height: 2),
                                         path: [false, true])]
            let msg = EndpointServerMessage.paneSurface(f)
            let framed = msg.encoded()
            let back = try EndpointServerMessage.decode(payload: Array(framed[4...]))
            guard case let .paneSurface(f2) = back else { return expect(false, "case") }
            expectEq(f2.bootId, "boot", "boot")
            expectEq(f2.frame.width, 2, "width")
            expectEq(f2.frame.cells.count, 4, "cells")
            expectEq(f2.frame.hyperlinks, ["https://herdr.dev"], "hyperlinks")
            expectEq(f2.frame.cells[1].hyperlink, 0, "cell link")
            expectEq(f2.panes.count, 1, "panes")
            expectEq(f2.splits.count, 1, "splits")
            expectEq(f2.splits[0].direction, PaneSurfaceSplitDirection.vertical, "split dir")
            expectEq(f2.popup?.terminalId, "pop", "popup id")
            expectEq(f2.popup?.width, ClientShellPopupSize.cells(20), "popup size")
            expectEq(f2.popup?.frame.hyperlinks.first, "https://herdr.dev", "popup links")
        }
        let ok5 = TestRegistry.add("wire: snapshot round-trip") {
            let snap = makeSnapshot()
            let msg = EndpointServerMessage.clientShellSnapshot(snap)
            let framed = msg.encoded()
            let back = try EndpointServerMessage.decode(payload: Array(framed[4...]))
            guard case let .clientShellSnapshot(s2) = back else { return expect(false, "case") }
            expectEq(s2.bootId, "boot-v1", "boot")
            expectEq(s2.revision, 7, "revision")
            expectEq(s2.workspaces.count, 1, "workspaces")
            expectEq(s2.workspaces[0].gitAheadBehind?.0, 1, "ahead")
            expectEq(s2.workspaces[0].worktree?.isLinkedWorktree, true, "linked")
            expectEq(s2.tabs[0].agentStatus, AgentStatus.working, "tab status")
            expectEq(s2.agents[0].stateLabels.first?.1, "waiting", "state label")
            expectEq(s2.commands[0].action, ClientShellCommandAction.shell, "command action")
            expectEq(s2.tabBarRight[0].text, "host", "segment")
            expectEq(s2.focusedPaneId, "w1:p1", "focused pane")
        }
        let ok6 = TestRegistry.add("wire: FrameData.validate matrix") {
            var f = makeFrame().frame
            try f.validate()
            f.cells.removeLast()
            expectThrows({ try f.validate() }, "cell count")
            var g = makeFrame().frame
            g.cells[0].hyperlink = 9
            expectThrows({ try g.validate() }, "hyperlink index")
            var c = makeFrame().frame
            c.cursor = CursorState(x: 5, y: 0, visible: true, shape: 0)
            expectThrows({ try c.validate() }, "cursor bounds")
            var d = makeFrame().frame
            d.cursor = CursorState(x: 5, y: 0, visible: false, shape: 0)
            try d.validate()  // invisible cursor may be out of bounds
        }
        let ok7 = TestRegistry.add("wire: applyPatch atomic matrix") {
            var frame = makeFrame()
            let good = PaneSurfacePatch(
                bootId: "boot", projectionRevision: 1, baseSurfaceRevision: 1,
                surfaceRevision: 2,
                rows: [PaneSurfacePatchRow(x: 1, y: 0, cells: [
                    CellData(symbol: "Z", fg: 0, bg: 0, modifier: 0, skip: false,
                             hyperlink: nil)
                ])],
                panes: frame.panes,
                cursor: CursorState(x: 1, y: 0, visible: true, shape: 2))
            try frame.applyPatch(good)
            expectEq(frame.frame.cells[1].symbol, "Z", "patched cell")
            expectEq(frame.surfaceRevision, 2, "revision")
            expectEq(frame.frame.cursor?.shape, 2, "cursor replaced")

            var badBoot = good; badBoot.bootId = "other"
            expectThrows({ try frame.applyPatch(badBoot) }, "boot")
            var stale = good; stale.surfaceRevision = 5
            expectThrows({ try frame.applyPatch(stale) }, "revision gap")
            var rowOOB = good; rowOOB.surfaceRevision = 3; rowOOB.baseSurfaceRevision = 2
            rowOOB.rows = [PaneSurfacePatchRow(x: 0, y: 9, cells: [])]
            expectThrows({ try frame.applyPatch(rowOOB) }, "row bounds")
            var rowWide = rowOOB
            rowWide.rows = [PaneSurfacePatchRow(x: 2, y: 0, cells: [
                CellData(symbol: "Z", fg: 0, bg: 0, modifier: 0, skip: false,
                         hyperlink: nil)
            ])]
            expectThrows({ try frame.applyPatch(rowWide) }, "row overflow")
            var geo = good; geo.surfaceRevision = 3; geo.baseSurfaceRevision = 2
            geo.panes = [PaneSurfacePane(
                paneId: "p1", contentRevision: 1,
                rect: SurfaceRect(x: 0, y: 0, width: 1, height: 1),
                innerRect: SurfaceRect(x: 0, y: 0, width: 1, height: 1),
                scrollbarRect: nil, scroll: nil, focused: true,
                mouseReporting: false, sgrPixelMouse: false,
                alternateScreenActive: false, pixelWidth: 1, pixelHeight: 1)]
            expectThrows({ try frame.applyPatch(geo) }, "geometry")
            var withLink = good; withLink.surfaceRevision = 3
            withLink.baseSurfaceRevision = 2
            withLink.rows = [PaneSurfacePatchRow(x: 0, y: 0, cells: [
                CellData(symbol: "Z", fg: 0, bg: 0, modifier: 0, skip: false,
                         hyperlink: 7)
            ])]
            expectThrows({ try frame.applyPatch(withLink) }, "link index")
            var withPopup = frame
            withPopup.popup = ClientShellPopupSurface(
                terminalId: "pop", title: "T", width: nil, height: nil,
                frame: FrameData(cells: [], width: 0, height: 0, cursor: nil,
                                 hyperlinks: [], graphics: []),
                mouseReporting: false, sgrPixelMouse: false,
                pixelWidth: 0, pixelHeight: 0)
            var pop = good; pop.surfaceRevision = 3; pop.baseSurfaceRevision = 2
            expectThrows({ try withPopup.applyPatch(pop) }, "popup active")
            // Failed patches mutated nothing:
            expectEq(frame.frame.cells[1].symbol, "Z", "no mutation on failure")
        }
        let ok8 = TestRegistry.add("wire: unknown variant rejected, trailing rejected") {
            expectThrows({
                _ = try EndpointServerMessage.decode(payload: [99, 0, 0])
            }, "unknown variant")
            expectThrows({
                _ = try EndpointClientMessage.decode(payload: [4, 1, 2, 3])
            }, "trailing bytes on Detach")
        }
        expect(ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 && ok8, "registration")
    }

    static func makeSnapshot() -> ClientShellSnapshot {
        ClientShellSnapshot(
            bootId: "boot-v1", revision: 7,
            configDiagnostic: "warn",
            productAnnouncement: ClientShellProductAnnouncement(
                version: "1.0.0", id: "a", title: "T", body: "B", preview: false),
            updateAvailable: "1.0.1", updateInstallCommand: "herdr update",
            serverKeybindingsToml: nil, latestReleaseNotesAvailable: true,
            integrationUpdatesAvailable: false, worktreeDirectory: "/worktrees",
            releaseNotes: ClientShellReleaseNotes(version: "1.0.1", body: "N", preview: true),
            focusedWorkspaceId: "w1", focusedTabId: "w1:t1", focusedPaneId: "w1:p1",
            tabBarRight: [ClientShellTabStatusSegment(text: "host", accent: true)],
            tabBarRightSeparator: " | ", agentViewLabel: "focus",
            agentOrder: ["w1:p1"],
            workspaces: [ClientShellWorkspace(
                workspaceId: "w1", activeTabId: "w1:t1", newWorkspaceCwd: "/repo",
                number: 1, label: "repo", customLabel: false, branch: "main",
                gitAheadBehind: (1, 2), tokens: [("model", "opus")],
                worktree: ClientShellWorktree(key: "repo/main", label: "main",
                                              isLinkedWorktree: true),
                focused: true, agentStatus: .idle)],
            tabs: [ClientShellTab(tabId: "w1:t1", workspaceId: "w1", number: 1,
                                  label: "main", customLabel: false, zoomed: false,
                                  focused: true, agentStatus: .working)],
            panes: [ClientShellPane(paneId: "w1:p1", workspaceId: "w1", tabId: "w1:t1",
                                    label: "shell", cwd: "/repo", foregroundCwd: "/repo",
                                    focused: true, rightClickPassthrough: false)],
            agents: [ClientShellAgent(
                paneId: "w1:p1", workspaceId: "w1", tabId: "w1:t1",
                name: "reviewer", displayAgent: "Claude", agent: "claude",
                title: "Review", terminalTitle: "Claude Review",
                terminalTitleStripped: "Claude Review", agentStatus: .blocked,
                stateChangeSeq: 9, stateLabels: [("blocked", "waiting")],
                tokens: [("task", "review")], focused: true)],
            commands: [ClientShellCommand(
                commandId: "c1", bindingLabel: "prefix+x",
                bindingLabels: ["prefix+x"], action: .shell, description: "D")])
    }
}
