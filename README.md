<div align="center">

<img src="swift-app/Assets/AppIcon/app-icon.png" alt="herdr-gui" width="88" height="88" />

### herdr-gui

**A native macOS window for herdr — endpoint protocol, agent sidebar, painted terminal cells.**

<sub>Pure Swift · Native chrome on AppKit · Terminal painted with CoreText from herdr's semantic cells</sub>

<br />

[![Platforms](https://img.shields.io/badge/platforms-macOS-blue)](#build-from-source)
[![License](https://img.shields.io/badge/license-MPL--2.0-blue)](LICENSE)

<br />

</div>

## Why

- **Native window, herdr semantics** — an AppKit sidebar and tab strip project herdr's own snapshot model; sessions, panes, and agents underneath stay herdr
- **Endpoint generation 1** — herdr's stable client contract (0.9+): typed snapshots, semantic pane input, real navigation APIs. No TUI mirroring, no synthesized keybindings; herdr upgrades don't touch this GUI
- **Cell canvas, not a terminal emulator** — herdr renders cells server-side; this app paints them with CoreText (background spans → glyphs → decorations → cursor), split panes included
- **Agent-aware sidebar** — 15 agent CLIs with icons, live status dots, a cwd/title second line per agent, one click to jump to its tab
- **Native settings** — theme, sound, toasts, agent labels: written to `config.toml` with `server.reload_config`, exactly the TUI's write-then-reload flow

## What's inside

| | |
|---|---|
| **Protocol** | vendored endpoint gen1 wire (bincode 2, framed) from herdr upstream · handshake fail-closed on generation/codec mismatch · snapshot channel (JSON in `endpointControl`) · baseline surface patches applied atomically · single-lane API requests (`tab.focus`, `workspace.create`, …) |
| **Rendering** | `CellSurfaceView`: CoreText cell painter with a bounded CTLine glyph cache · named/indexed/RGB colors, reverse/dim/hidden blending · underline/strikethrough decorations · DECSCUSR cursor shapes · hyperlinks (hover + ⌘-click) · selection + copy · centered popup overlay · resize reported to the daemon |
| **Chrome** | workspaces-over-agents sidebar (herdr's own split) · tab strip with inline rename & close (`tab.rename`) · collapsible sidebar with persisted width · <kbd>⌘ N</kbd> new workspace · <kbd>⇧⌘ W</kbd>-style close with confirmation · <kbd>⌘ ,</kbd> settings |
| **Input** | semantic `ClientPaneInputEvent`: keys, IME text commits, mouse, wheel (fractional accumulator), paste — all pane-relative cells; the daemon decides scrollback/alternate-screen/app-mouse policy |
| **Lifecycle** | bounded-backoff reconnect (stable connections reset the ladder) · handshake rejections surface as readable offline state instead of retry loops |
| **Servers** | pinned Local herdr page (endpoint gen1, herdr ≥ 0.9.0) · plain local Terminal page (libghostty EXEC) · plain ssh terminal pages · remote herdr pages wait for herdr's `remote-client-bridge` (next release) |

Supported agent icons: Claude Code · Codex · Copilot · Cursor · Gemini · Qwen · Grok · Amp · Goose · Cline · Droid · Kimi · OpenCode · Oh My Pi · Pi

## Protocol provenance

The wire declarations in `swift-app/Sources/Herdr/Endpoint/` mirror herdr's
`src/protocol/{wire,endpoint}.rs` (pinned upstream commit `856b64b9`, Apache-2.0)
as adapted client-side by [herdr-gpui](https://github.com/penso/herdr-gpui).
Field and variant order are compatibility contracts — see the comments there.
Handshake/snapshot fixtures in `swift-app/Tests/Fixtures/` are vendored from
the same source.

## Build from source

Requires macOS with a Swift toolchain (Xcode Command Line Tools), and a
running [herdr](https://herdr.dev) server **0.9.0 or newer**:

```sh
cd swift-app
./build.sh        # → swift-app/herdr-gui
```

The binary runs against the vendored `CGhostty/lib/libghostty.dylib` via
rpath — keep them side by side (libghostty is only used by the plain
Terminal page now). `python3` is optional: present, it regenerates the
icon tables from `Assets/`.

Run the test suite (wire codec, handshake validation, session projection,
painter logic, snapshot adapter):

```sh
swift-app/tools/run-tests.sh
```

---

<div align="center">
<sub>
Endpoint protocol from [herdr](https://herdr.dev) · rendering references [herdr-gpui](https://github.com/penso/herdr-gpui) (Apache-2.0) · [MPL-2.0](LICENSE)
</sub>
</div>
