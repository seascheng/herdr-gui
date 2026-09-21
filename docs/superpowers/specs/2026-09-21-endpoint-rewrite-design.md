# herdr-gui Endpoint Rewrite Design

Date: 2026-09-21
Status: Approved (chat design review, this session)
Scope: Phase 1 (local endpoint only); SSH bridge and graphics deferred.

## Goal

Replace the v19 full-app-frame mirror transport with herdr's **stable endpoint
protocol generation 1** (herdr ≥ 0.9.0): the GUI becomes a native projection of
daemon state (custom chrome, real navigation APIs, semantic pane input) and
stops wrapping the TUI. Rendering moves from libghostty (ANSI app-frame mirror)
to a CoreText cell painter fed by server-computed `CellData` grids.

Rationale (agreed with user): the endpoint wire is herdr's officially frozen
client contract ("wire field and enum variant order are compatibility
contracts"); it eliminates the display-steering layer (synthetic prefix chords,
launcher-click geometry, timing hacks) — the project's largest
upgrade-fragility surface — and the crop math for herdr chrome.

Reference implementations (Apache-2.0, porting sources):
- penso/herdr-gpui: `crates/herdr-protocol/src/{wire,endpoint,frame,codec}.rs`,
  `crates/herdr-client/src/{session,connect,method,handle,event,frame,limits,options,discovery}.rs`,
  `crates/herdr-gpui/src/{terminal,terminal_painter,endpoint}.rs`.
- Upstream herdr (authoritative wire source, pinned):
  herdrdev/herdr @ `856b64b9bfd41b9d3d82e2375ed5b4bf941fda28` (0.9.1),
  `src/protocol/{wire,endpoint}.rs`, `tests/fixtures/endpoint-{hello,welcome,snapshot}-v1.json`.

Local environment: herdr 0.9.1 (Homebrew), `herdr status client --json` reports
`protocol:22, endpoint_protocol_generation:1, capabilities:
[surface_interest, presentation_effects_fence, health_check]`. Sockets:
`~/.config/herdr/herdr.sock` (legacy NDJSON; no longer used) and
`~/.config/herdr/herdr-client.sock` (binary client socket; the one we use).

## Architecture

```
AppKit chrome (Sidebar / TabStrip / ConfigPanel / Sessions)   [kept, adapted]
        │  snapshot projection + navigation actions
        ▼
HerdrEndpointClient  (worker thread; owns socket + projection + request lane)
        │  bincode 2 standard, u32-LE length-prefixed frames
        ▼
~/.config/herdr/herdr-client.sock   →  herdr 0.9+ daemon
        ▲
CellSurfaceView (CoreText cell painter) ← PaneSurfaceFrame/Patch projection
```

One connection, one worker thread (mirror of herdr-client's session.rs):
handshake → welcome validation → snapshot/surface projection → patch
application → API request lane. Reconnect (bounded backoff) lives in the GUI
layer; the session itself never replays.

### Data flow

- Snapshot pushes (`ServerMessage::ClientShellSnapshot`) drive the sidebar/tab
  model. No polling; revisions order the world.
- Surface pushes (`PaneSurfaceFrame` full frames, `PaneSurfacePatch` baseline
  patches) drive the cell canvas. A surface is publishable only when its
  `(boot_id, projection_revision)` equals the latest snapshot's
  `(boot_id, revision)`; future surfaces queue until their snapshot lands;
  a newer snapshot invalidates displayed surfaces with older revisions.
- Navigation/creation go through `ClientShellEndpointRequest`
  (`{id, method, params}` JSON) and answers arrive as
  `ClientShellEndpointResponseChunk` streams assembled per `request_id`
  (8 MiB assembly cap, one in-flight request at a time — daemon lease).
- Input: keyboard/IME/mouse/paste from `CellSurfaceView` →
  `ClientShellPaneInput` / `ClientShellPopupInput` events, pane-relative cells.
- Resize: view bounds ÷ measured cell size → `ClientShellResize`
  (cols clamp 1…4096; rows ≤ 1_000_000/cols).

## Wire contracts (frozen facts used by this design)

- Handshake: `ClientMessage::EndpointControl{kind:"endpoint.hello.v1",
  data:<JSON EndpointClientHello>}`; the FIRST server message must be
  `EndpointControl{kind:"endpoint.welcome.v1", data:<JSON welcome>}`.
  Hello: generation 1; codecs exactly `shell.snapshot.v1`,
  `shell.surface.v1`, `shell.input.semantic.v1`, `shell.blob.v1`;
  `pixel_mouse=false, direct_graphics=false, endpoint_keybindings=false,
  mouse_capture=false, surface_active=true, surface_reuse=false,
  surface_delta=false`. Welcome: fail-closed on `error`, on generation≠1,
  or on any codec mismatch (exact string compare).
- Methods used by the GUI (checked against welcome `methods` before send):
  `workspace.focus|create|close|rename`, `tab.focus|create|close|rename`,
  `pane.focus|close|split|zoom|focus_direction`, `server.reload_config`,
  `worktree.*` (list/create/remove — later phases), `client_shell.surface.set`
  (inactive mode only; not used Phase 1).
- Framing: u32-LE length prefix; outbound cap 2 MiB; inbound cap 32 MiB;
  payload must decode with zero trailing bytes; zero-length frames rejected.
- `CellData.fg/bg` packing: `value>>24==0` and `1..=16` → named color
  `palette[(v&255)-1]`; `0` → default (fg→theme.foreground, bg→theme.background);
  `value>>24==1` → indexed `palette[v&255]`; `value>>24==2` → RGB `v&0xffffff`;
  anything else → default. NOT ARGB.
- `CellData.modifier` bits: bold=1, dim=2, italic=4, underline=8,
  reversed=64, hidden=128, strikethrough=256 (crossterm-compatible order).
  Rendering: reversed swaps fg/bg; dim blends fg halfway toward bg
  (`((fg&0xfefefe)>>1)+((bg&0xfefefe)>>1)`); hidden sets fg=bg.
- Cursor `shape` (DECSCUSR): 3|4 → bottom bar 2px; 5|6 → left bar 2px;
  else block. Draw at 50% alpha over theme cursor color.
- Key events: printable text belongs to IME commits (`TextCommit`), not
  Key-down; Key carries non-printables, ctrl-combos, F1–F24; modifier bits
  shift=1, control=2, alt=4, super=8, hyper=16, meta=32 (macOS: cmd→super,
  option→alt); platform-chord (cmd) keys are NOT sent to the terminal.
- Wheel: fractional accumulation per target, reset on target/direction/gesture
  change, clamp ±128 lines per event, sent as `Mouse{ScrollUp|ScrollDown}`
  with pane-relative cell position (pixel position only when
  `pane.sgr_pixel_mouse` and pane pixel dims > 0).
- Patch application is atomic (all-or-nothing): identity requires same
  `boot_id`, `projection_revision`, `base_surface_revision ==
  current surface_revision`, `surface_revision == current+1`, and no popup
  active; row bounds, hyperlink indices, pane geometry equality (pane_id +
  rect + inner_rect), and cursor bounds are validated before any mutation.
  On any violation the connection is dropped and re-established fresh.
- Limits: handshake/initial-snapshot deadline 10 s; request deadline 60 s;
  socket write timeout 1 s; 10 ms read poll; command queue 64; event queue 8
  (backpressure, never drop); geometry validity: nonzero dims, ≤4096/axis,
  ≤1,000,000 cells, cell pixels ≤4096.
- Snapshot model richness vs. old JSON snapshot: typed `AgentStatus`
  (idle/working/blocked/done/unknown), agents carry `state_labels`,
  `state_change_seq`, titles; workspaces carry branch, worktree, numbers;
  plus `commands` (daemon command palette), diagnostics, update info.

## Components (files)

New:
- `swift-app/Sources/Herdr/Endpoint/EndpointWire.swift` — full Swift mirror
  of wire.rs: `EndpointClientMessage`, `EndpointServerMessage`, all payload
  structs. Bincode encode/decode via existing `BincodeWriter`/`BincodeReader`
  (bincode 2 standard: variant = u32 varint index, fields in declaration
  order). Field order is a compatibility contract — do not reorder.
- `swift-app/Sources/Herdr/Endpoint/EndpointHandshake.swift` —
  `EndpointHello`/`EndpointWelcome` JSON types + validation (fail-closed).
- `swift-app/Sources/Herdr/Endpoint/EndpointSession.swift` — worker loop:
  connect, handshake, projection coherence (boot/revision), patch pipeline,
  request lane (single in-flight, FIFO, chunk assembly), timeouts, disconnect
  events. Port of session.rs minus SSH/health (local active only).
- `swift-app/Sources/Herdr/Endpoint/EndpointClient.swift` — App-facing
  handle: start/stop, command queue API (`focusTab`, `createWorkspace`,
  `renameTab`, `reloadConfig`, generic `request(method:params:)`), event
  callbacks (snapshot/surface/connected/disconnected), reconnect with
  bounded backoff (0.5s → 30s cap, reset after 30 s stable).
- `swift-app/Sources/Herdr/Endpoint/EndpointModel.swift` —
  `ClientShellSnapshot` → `HerdrModel.SidebarState` adapter (typed statuses,
  pane cwd for agents, workspace labels/branches).
- `swift-app/Sources/Terminal/CellCanvas/CellTheme.swift` — fg/bg/cursor +
  256-entry palette; bootstrap from existing theme tables (ChromeTheme);
  named-color and indexed resolution + reverse/dim/hidden blending rules.
- `swift-app/Sources/Terminal/CellCanvas/CellSurfaceView.swift` —
  NSView + NSTextInputClient cell canvas: two-pass paint (background spans →
  glyphs), per-row CTLine cache keyed by (fg, bold/italic) with entry cap,
  decorations (underline/strikethrough), wide-cell `skip`, cursor shapes,
  hyperlink hover/underline (Cmd-click → open URL), selection + copy,
  popup overlay (centered, `ClientShellPopupSurface`), pane hit-testing,
  wheel accumulator, resize → `ClientShellResize`.
- `swift-app/Sources/Terminal/CellCanvas/CellInputMapper.swift` —
  NSEvent → `ClientPaneInputEvent` mapping (key codes, modifiers, mouse
  kinds, paste).
- `swift-app/Tests/` + `swift-app/tools/run-tests.sh` — CLI test runner
  (swiftc-compiled, assertion-based; compiles only Infra + Endpoint +
  CellCanvas-logic sources, no AppKit UI deps for protocol tests).
- `swift-app/Tests/Fixtures/endpoint-{hello,welcome,snapshot}-v1.json` —
  vendored from upstream herdr at the pinned commit.

Modified:
- `swift-app/Sources/Pages/HerdrPage.swift` — replace api/eventStream/host
  internals with `EndpointClient` + `CellSurfaceView`; navigation actions →
  endpoint requests; reconcile cycle replaced by snapshot pushes.
- `swift-app/Sources/App/Sessions.swift` — SSH herdr mirror entries disabled
  with a "requires herdr 0.9+ remote bridge (coming)" state; plain local
  Terminal page unchanged (still libghostty).
- `swift-app/Sources/Herdr/HerdrModel.swift` — SidebarState population moves
  to EndpointModel adapter (struct itself stays).

Deleted (clean cutover):
- `Herdr/HerdrWire.swift`, `Herdr/HerdrAttachSession.swift`,
  `Herdr/HerdrEventStream.swift`, `Herdr/HerdrAPI.swift`,
  `Herdr/HerdrScrollChannel.swift`, `Herdr/HerdrSteering.swift`,
  `Terminal/MirrorStream.swift`, `Terminal/TerminalSurfaceHost.swift`,
  `Terminal/TerminalInputRouter.swift`.
  libghostty remains linked only for the plain Terminal page.

## Error handling

- Unknown/failed handshake (unsupported generation, codec mismatch, welcome
  `error`) → surface a readable banner ("herdr ≥ 0.9.0 required / reason")
  and stop reconnecting that page until user retries.
- Protocol violations (patch mismatch, trailing bytes, oversize frame,
  unsolicited response, revision regression) → drop the connection and
  reconnect fresh (no replay, no partial state); GUI invalidates surfaces on
  `boot_id` change.
- Request timeouts → report on the status bar; never retry blindly
  (uncertain completion — user re-triggers).

## Testing

1. Unit (CLI runner): bincode round-trips with frozen byte assertions for
   representative messages (hello control, pane input, resize); framing
   (prefix, caps, trailing-byte rejection); welcome validation matrix;
   patch apply/reject matrix (identity/geometry/bounds/hyperlink/cursor);
   color resolution + modifier blending; viewport math; wheel accumulator;
   key mapping table; snapshot→sidebar adapter.
2. Fixture tests: vendored upstream JSON parses into handshake types and
   matches expected field values.
3. Live smoke (manual + scripted): against local herdr 0.9.1 — connect,
   snapshot, create workspace/tab, type text via semantic input, focus
   switches, resize, rename, disconnect/reconnect. Deliverable proof is the
   exercised scenario, not new permanent tests.

## Phasing

- Phase 1 (this work): everything above, local `herdr-client.sock` only,
  popup text rendering, no Kitty graphics (advertise `direct_graphics=false`;
  ignore `graphics` scene), no delta/reuse codecs.
- Phase 2 (later): SSH remotes via `herdr --session <n> remote-client-bridge`
  (stdio transport), Kitty graphics, delta codecs, worktree menus,
  semantic notifications (UNUserNotificationCenter).

## Non-goals

- Keeping v19/NDJSON compatibility (no dual protocol).
- Touching the plain local Terminal page (libghostty).
- Client-side terminal-mode policy (scrollback vs alternate screen vs app
  mouse) — the daemon decides; we only send semantic wheel events.
