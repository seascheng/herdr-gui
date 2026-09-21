# Endpoint Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the v19 app-frame mirror with herdr endpoint generation 1 (bincode client socket) plus a CoreText cell painter, keeping the existing AppKit chrome.

**Architecture:** One worker thread owns the `herdr-client.sock` connection (handshake → snapshot/surface projection → baseline patches → single-lane JSON API requests). `CellSurfaceView` paints server `CellData` grids with CoreText and routes semantic input pane-relatively. Chrome (Sidebar/TabStrip/ConfigPanel) is re-pointed at the snapshot projection and navigation APIs.

**Tech Stack:** Swift 5/AppKit/CoreText, existing `BincodeWriter`/`BincodeReader` (bincode 2 standard), no new dependencies. Porting sources: penso/herdr-gpui (Apache-2.0) and herdrdev/herdr@`856b64b9` — exact files listed in the spec.

**Spec:** `docs/superpowers/specs/2026-09-21-endpoint-rewrite-design.md` — all frozen constants (codecs, modifier bits, color packing, limits, cursor shapes) live there; this plan argues from it.

## Global Constraints

- Wire field/variant order is a compatibility contract; encode/decode must follow declaration order exactly (bincode 2 standard: enum variant = u32 varint, integers prefix-varint, u32-LE frame length prefix).
- Fail-closed handshake: generation≠1, any codec ≠ the four exact strings, or welcome `error` → disconnect with readable reason; never fall back.
- Patch application is atomic; any validation failure drops the connection (no partial state, no replay).
- No client-side terminal-mode policy: wheel events are semantic `Mouse{ScrollUp|ScrollDown}`; the daemon decides routing.
- Frame limits: 2 MiB outbound, 32 MiB inbound, 8 MiB response assembly; strict trailing-byte rejection.
- macOS mapping: cmd→super(8), option→alt(4); cmd-chords never reach the terminal.
- herdr ≥ 0.9.0 required; SSH herdr pages disabled with an explanatory placeholder this phase.
- Build with `swift-app/build.sh` (swiftc, `-warnings-as-errors`).

---

### Task 1: Test harness + vendored fixtures

**Files:**
- Create: `swift-app/tools/run-tests.sh`
- Create: `swift-app/Tests/Fixtures/endpoint-hello-v1.json`, `endpoint-welcome-v1.json`, `endpoint-snapshot-v1.json`
- Create: `swift-app/Tests/TestMain.swift` (assertion micro-runner: `expect(_:_:file:line:)`, `expectThrows`, fixture loader relative to `#filePath`)

**Interfaces:**
- Produces: `run-tests.sh` compiles explicit file lists (Infra + new Endpoint/CellCanvas logic files + Tests) into `build/herdr-gui-tests` and runs it; exit code = failures.
- Produces: `func loadFixture(_ name: String) throws -> Data` in TestMain.

- [ ] **Step 1:** Fetch the three fixture JSONs from `https://raw.githubusercontent.com/herdrdev/herdr/856b64b9bfd41b9d3d82e2375ed5b4bf941fda28/tests/fixtures/endpoint-{hello,welcome,snapshot}-v1.json` into `Tests/Fixtures/`.
- [ ] **Step 2:** Write `TestMain.swift` runner + `run-tests.sh` (mirror `build.sh` flags minus UI frameworks; add `-ONONE -g` for speed).
- [ ] **Step 3:** Smoke test: a passing dummy expectation and a failing one; verify script exit codes. Remove the dummy.
- [ ] **Step 4:** Commit `test: add CLI test harness + upstream fixtures`.

### Task 2: EndpointWire — wire types + codec

**Files:**
- Create: `swift-app/Sources/Herdr/Endpoint/EndpointWire.swift`
- Test: `swift-app/Tests/EndpointWireTests.swift`

**Interfaces:**
- Consumes: `BincodeWriter`, `BincodeReader`, `BincodeFrame`.
- Produces: `enum EndpointClientMessage` (TerminalHello, Input, ClipboardImage, Resize, Detach, AttachTerminal, AttachScroll, ObserveTerminal, ControlTerminal, GraphicsTransmissionResult, GraphicsTransmissionStarted, ClientShellHello, ClientShellResize, ClientShellPaneInput, ClientShellPopupInput, ClientShellEndpointRequest, AttachMouse, ClientShellHostTheme, ClientShellFocus, ClientShellMouseCapture, EndpointControl) with `encoded() -> [UInt8]` (framed);
  `enum EndpointServerMessage` (Welcome, Terminal, Graphics, ServerShutdown, Notify, Clipboard, WindowTitle, ReloadSoundConfig, MouseCapture, TerminalBell, GraphicsFile, GraphicsTransmissionRetired, ClientShellSnapshot, PaneSurface, SemanticNotification, ClientShellError, DirectTerminalKeyboardProtocol, ClientShellKeyboardReportAll, ClientShellEndpointResponseChunk, PaneSurfacePatch, EndpointControl) with `static func decode(payload:) throws -> EndpointServerMessage`;
  payload structs `CellData, CursorState, FrameData, PaneSurfaceFrame, PaneSurfacePatch, PaneSurfacePatchRow, PaneSurfacePane, PaneSurfaceScrollMetrics, PaneSurfaceSplit, SurfaceRect, ClientShellSnapshot, ClientShellWorkspace, ClientShellWorktree, ClientShellTab, ClientShellPane, ClientShellAgent, ClientShellCommand, ClientShellTabStatusSegment, ClientShellPopupSurface, ClientShellProductAnnouncement, ClientShellReleaseNotes, TerminalFrame, SemanticNotification`, input family `ClientPaneInputEvent, ClientKeyCode, ClientKeyKind, ClientMouseButton, ClientMouseKind, ClientMousePosition, ClientMouseGeometry, WindowsKeyRecord, ClientSurfaceSize` — declarations and order mirroring `crates/herdr-protocol/src/wire.rs` exactly.
- Produces: `extension FrameData { func validate() throws }` and `extension PaneSurfaceFrame { mutating func applyPatch(_:) throws }` porting `frame.rs` (identity/geometry/bounds/hyperlink/cursor rules, atomic).

Encoding pattern (applies to every type; variant index = declaration order, 0-based):

```swift
// enum: writeVariant(index) then payload fields in order; Option<T>: writeBool + payload
// struct: fields in declaration order. Vec<T>: writeVarint(count) then elements.
```

- [ ] **Step 1:** Write failing tests: round-trip a `PaneSurfaceFrame` with 2×2 cells + cursor + hyperlink; round-trip `ClientShellPaneInput` with Key/Mouse/Paste variants; assert exact bytes for a hand-computed minimal `EndpointControl` frame (kind+data string) and a `CellData`; assert `applyPatch` rejects wrong `base_surface_revision`, row overflow, hyperlink index, geometry change; asserts `validate` rejects cell-count mismatch.
- [ ] **Step 2:** Run → fails (types missing).
- [ ] **Step 3:** Implement full mirror of wire.rs with encode/decode.
- [ ] **Step 4:** Run → passes; add frozen-byte regression for the two hand-computed cases.
- [ ] **Step 5:** Commit `feat(endpoint): wire types, codec, patch pipeline`.

### Task 3: Handshake types + validation

**Files:**
- Create: `swift-app/Sources/Herdr/Endpoint/EndpointHandshake.swift`
- Test: `swift-app/Tests/EndpointHandshakeTests.swift`

**Interfaces:**
- Produces: `struct EndpointHello: Codable` (generation=1, cell px, surfaceSize, false-flags, codec lists) with `static func make(cellWidth:cellHeight:cols:rows:) -> EndpointHello`; `struct EndpointWelcome: Codable` (generation, serverVersion, codecs, methods, capabilities, error{code,message}); `enum EndpointHandshakeError: Error, CustomStringConvertible`; `func validateWelcome(_:) throws` implementing the fail-closed matrix; `let endpointHelloKind = "endpoint.hello.v1"`, `endpointWelcomeKind`, codec string constants.

- [ ] **Step 1:** Failing tests: fixture hello encodes/decodes; fixture welcome validates OK; welcome with `error` → throws with code+message; generation 2 → throws; each of the four codecs wrong → throws; methods list parse.
- [ ] **Step 2:** Implement; run → pass. Commit `feat(endpoint): handshake validation`.

### Task 4: EndpointSession worker

**Files:**
- Create: `swift-app/Sources/Herdr/Endpoint/EndpointSession.swift`
- Test: `swift-app/Tests/EndpointSessionTests.swift` (mock server over UNIX socketpair/socket file)

**Interfaces:**
- Consumes: Task 2+3 types, `UnixSocket.swift`.
- Produces: `final class EndpointSession` with `init(socketPath:, queue:)`; callbacks `onWelcome(EndpointWelcome)`, `onSnapshot(ClientShellSnapshot)`, `onSurface(PaneSurfaceFrame)`, `onResponse(requestId:String, json:[String:Any])`, `onError(String)`; `func start(); func stop()`; `func send(events:[ClientPaneInputEvent], paneId:String)`, `func sendPopup(events:[ClientPaneInputEvent], terminalId:String)`, `func resize(cols:rows:cellWidth:cellHeight:)`, `func request(method:String, params:[String:Any], completion:([String:Any]?) -> Void)` (single in-flight, FIFO behind input, request-id monotonically increasing, chunk assembly per `request_id` until `final_chunk`).
- Projection rules (from session.rs): retain future surfaces until matching snapshot; invalidate on boot change; snapshot timeout 10 s; request timeout 60 s; poll 10 ms; write timeout 1 s; reconnect NOT in this layer.

- [ ] **Step 1:** Failing tests against a mock server: complete handshake → snapshot+surface delivered in order; surface arriving before its snapshot is delivered after; patch sequence advances `surface_revision`; malformed patch → `onError` + socket closed; request round-trip with 2 chunks; second request while one in flight queues; unknown welcome first message → error.
- [ ] **Step 2:** Implement worker loop (port run_connection/handle_message structure; POSIX read poll; generation token to retire superseded readers).
- [ ] **Step 3:** Run → pass. Commit `feat(endpoint): session worker with projection + request lane`.

### Task 5: EndpointClient app handle + reconnect

**Files:**
- Create: `swift-app/Sources/Herdr/Endpoint/EndpointClient.swift`

**Interfaces:**
- Produces: `final class EndpointClient` — `init(socketPath:)`, main-thread callbacks (`onSnapshot`, `onSurface`, `onState(connected:Bool, message:String?)`), `func start() / stop()`, forwarded input/resize/request methods, bounded-backoff reconnect (0.5 s doubling → 30 s cap; reset after 30 s stable; no retry after handshake-rejection errors).

- [ ] **Step 1:** Implement (logic covered by Task 4 tests + backoff unit test with injected clock if trivial; else manual).
- [ ] **Step 2:** Commit `feat(endpoint): client handle with reconnect backoff`.

### Task 6: CellTheme — palette + color rules

**Files:**
- Create: `swift-app/Sources/Terminal/CellCanvas/CellTheme.swift`
- Test: `swift-app/Tests/CellThemeTests.swift`

**Interfaces:**
- Produces: `struct CellTheme` (`foreground/background/cursor: UInt32` RGB, `palette: [UInt32]` ×256); `func resolveColor(_ value: UInt32, default: UInt32) -> UInt32`; `func cellColors(_ cell: CellData) -> (fg: UInt32, bg: UInt32)` implementing reverse/dim/hidden; static xterm-256 base table; static theme from existing ChromeTheme palette tables (16 ANSI overrides in xterm positions).

- [ ] **Step 1:** Failing tests: named 1..=16 → palette[n-1]; 0/other → default; 0x01xxxxxx indexed; 0x02RRGGBB; reverse swap; dim blend formula; hidden fg=bg.
- [ ] **Step 2:** Implement; run → pass. Commit `feat(cellcanvas): theme + color resolution`.

### Task 7: CellInputMapper

**Files:**
- Create: `swift-app/Sources/Terminal/CellCanvas/CellInputMapper.swift`
- Test: `swift-app/Tests/CellInputMapperTests.swift`

**Interfaces:**
- Produces: `enum CellInputMapper` — `static func keyEvent(_ nsevent: NSEvent, chars: String, carbonModifiers:) -> ClientPaneInputEvent?` (non-printables/ctrl/F-keys only; cmd-chord → nil), `static func modifiers(_ nsevent: NSEvent) -> UInt8`, `static func mouseKind(down/up/drag/moved, button:) -> ClientMouseKind`, `static func viewport(width:height:cellWidth:cellHeight:) -> ClientSurfaceSize`; `struct WheelAccumulator` (per-target fraction, direction reset, ±128 clamp) with `lines(target:deltaY:cellHeight:) -> Int`.

- [ ] **Step 1:** Failing tests: port the wheel-accumulator test matrix from herdr-gpui `terminal.rs` tests (fraction carry, target/direction/gesture reset, ±128 clamp, non-finite); key mapping table (enter/backspace/arrows/F5/ctrl-c/space/shift-tab→BackTab; cmd-x → nil); viewport clamp math.
- [ ] **Step 2:** Implement; run → pass. Commit `feat(cellcanvas): input mapping + wheel accumulator`.

### Task 8: CellSurfaceView painter

**Files:**
- Create: `swift-app/Sources/Terminal/CellCanvas/CellSurfaceView.swift`
- Test: `swift-app/Tests/CellSurfaceLogicTests.swift` (hit-testing, popup origin, cursor rect — pure functions exposed as internal statics)

**Interfaces:**
- Consumes: `CellTheme`, `CellInputMapper`, `PaneSurfaceFrame` projection (delivered via a `CellSurfaceView.update(surface:)` on main).
- Produces: `final class CellSurfaceView: NSView, NSTextInputClient` — `var onPaneInput: ((String, [ClientPaneInputEvent]) -> Void)?`, `var onPopupInput: ...`, `var onResize: ((ClientSurfaceSize) -> Void)?`, `var onOpenURL: ((URL) -> Void)?`; renders main frame + centered popup; pane hit-test uses `inner_rect`; selection (shift/drag) with `NSPasteboard` copy; hyperlink hover + Cmd-click open; cursor blink-free render per shape table; resize debounced 150 ms → `onResize`; CTLine cache keyed `(fg, bold|italic)` capped 4096 entries; `needsDisplay` diffing via `surface_revision` (skip when unchanged).

- [ ] **Step 1:** Failing logic tests: pane hit-test inside `inner_rect` only; popup centered origin formula; cursor rect per shape class.
- [ ] **Step 2:** Implement painter (two-pass: background spans then glyphs; decorations after; cursor last at 50% alpha).
- [ ] **Step 3:** Run tests; commit `feat(cellcanvas): CoreText cell surface view`.

### Task 9: Snapshot adapter

**Files:**
- Create: `swift-app/Sources/Herdr/Endpoint/EndpointModel.swift`
- Test: `swift-app/Tests/EndpointModelTests.swift`

**Interfaces:**
- Produces: `extension HerdrModel { static func sidebarState(_ snapshot: ClientShellSnapshot) -> HerdrModel.SidebarState }` — typed `AgentStatus` → status string, agent second line from pane `cwd`/`state_labels`/titles, workspace/tab labels, focused ids; `static func statusDotColor(_ status:) -> NSColor`-free `String` mapping consistent with existing Sidebar rendering.

- [ ] **Step 1:** Failing test: synth snapshot → SidebarState fields (agents across workspaces, tab mapping, focus).
- [ ] **Step 2:** Implement; run → pass. Commit `feat(endpoint): snapshot → sidebar adapter`.

### Task 10: HerdrPage rewire + SSH disable + legacy deletion

**Files:**
- Modify: `swift-app/Sources/Pages/HerdrPage.swift` (replace api/event/host internals; keep Sidebar/TabStrip/Settings wiring)
- Modify: `swift-app/Sources/App/Sessions.swift` (SSH herdr → disabled placeholder page)
- Modify: `swift-app/Sources/App/AppDelegate.swift` (only if ghosttyApp init needs scoping)
- Modify: `swift-app/Sources/Herdr/HerdrModel.swift` (remove JSON snapshot parser)
- Delete: `Herdr/HerdrWire.swift`, `Herdr/HerdrAttachSession.swift`, `Herdr/HerdrEventStream.swift`, `Herdr/HerdrAPI.swift`, `Herdr/HerdrScrollChannel.swift`, `Herdr/HerdrSteering.swift`, `Terminal/MirrorStream.swift`, `Terminal/TerminalSurfaceHost.swift`, `Terminal/TerminalInputRouter.swift`
- Modify: `README.md` (architecture section: endpoint gen1, herdr ≥ 0.9.0, painter)

**Interfaces:**
- Consumes: Tasks 2–9 products.
- Behavior: sidebar/tab clicks → `workspace.focus`/`tab.focus`; ⌘T/⌘N → `tab.create`/`workspace.create`; close/rename as today via request lane; settings panel writes config.toml then `server.reload_config` request; status bar shows connection state + handshake errors verbatim.

- [ ] **Step 1:** Rewire HerdrPage to EndpointClient + CellSurfaceView; navigation closures to request lane.
- [ ] **Step 2:** Disable SSH herdr entries (menu shows alias + "0.9+ bridge coming"); plain Terminal untouched.
- [ ] **Step 3:** Delete legacy files; fix all compile errors (grep for deleted symbols).
- [ ] **Step 4:** `./build.sh` → clean build with `-warnings-as-errors`.
- [ ] **Step 5:** Commit `feat!: endpoint gen1 rewrite, drop v19 mirror + steering`.

### Task 11: Live smoke + docs

**Files:** none new (throwaway smoke script allowed under /tmp)

- [ ] **Step 1:** Start daemon (`herdr server` via brew services or direct), launch app, verify: sidebar lists workspaces/agents from snapshot; typing reaches shell; ⌘T creates tab; tab click focuses; split panes hit-test correctly; resize reflows; rename works; quit leaves daemon running.
- [ ] **Step 2:** Verify handshake failure path: point at a bogus socket → readable error state.
- [ ] **Step 3:** Update README (protocol, requirements, screenshots unchanged); final commit.

## Self-Review

- Spec coverage: wire/framing (T2), handshake (T3), projection/patch/lane (T4), reconnect (T5), colors (T6), input (T7), painter+selection+links+popup (T8), chrome adapter (T9), cutover+SSH disable+deletions (T10), smoke+README (T11). Kitty graphics/delta codecs/SSH bridge are spec'd non-goals (Phase 2). ✔
- Placeholder scan: every step names files/symbols/constants; porting sources are public URLs with exact paths. ✔
- Type consistency: `ClientPaneInputEvent`, `PaneSurfaceFrame`, `EndpointWelcome`, `ClientSurfaceSize` used uniformly across tasks. ✔
