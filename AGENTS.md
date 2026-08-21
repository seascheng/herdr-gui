# AGENTS.md

## Build

- Build with `cd swift-app && bash build.sh` (strict: `-warnings-as-errors`, `-O`).
- Run the app via the hub (`herdr-mirror`, `pty: false`), never leave stray copies running.
- Use `wax`, not `brew`.

## Checks

Run before committing:

```sh
cd swift-app && bash build.sh
```

## Scope

- `swift-app/Sources/` (one module per concern: `AppDelegate`, `TerminalSurfaceHost`, `TerminalInputRouter`, `NativeChrome`, `ChromeTheme`, `HerdrControl`, `HerdrEvents`, `HerdrAttach`, `HerdrScrollChannel`, `UnixSocket`, `BincodeReader`).
- Treat cmux, Warp, Arc, and Superconductor as UI/product references only.
- Do not add browser panes, plugin UI, marketplace, cloud accounts, or telemetry.
- `swift-app/vendor-swift/` is a whitelisted compile closure of Ghostty's Swift embedding layer — treat it as vendored dependency code, not our product code; extend the `VENDOR_SOURCES` list in `build.sh`, don't fork it.
