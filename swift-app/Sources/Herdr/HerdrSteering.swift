import Foundation

// MARK: - herdr display steering
//
// herdr's app frame only re-renders on TUI input (verified live:
// tab.focus/tab.create change logical state and emit events but never
// push frames to app clients), so every display-moving operation rides
// herdr's documented keybindings over the attach stream. This extension
// keeps those herdr input semantics out of the generic surface host.

extension TerminalSurfaceHost {
    /// Sends raw keys over the attach stream (picker typing, menu arrows).
    func sendKeys(_ keys: String) {
        stream?.sendInput(Array(keys.utf8))
    }

    /// Sends a herdr prefix chord — the documented keybindings path a
    /// native TUI user types (prefix = ctrl+b).
    func sendPrefix(_ suffix: String) {
        sendKeys("\u{02}" + suffix)
    }

    /// Sends a herdr prefix chord as STRUCTURED key events: modifier
    /// bindings (prefix+shift+N, prefix+alt+N) only match when the
    /// shift/alt bits survive the trip, which raw Input bytes cannot
    /// express (a shifted-digit byte re-parses as a different action).
    func sendPrefixChord(_ char: Character, _ modifiers: MirrorKeyModifiers) {
        stream?.sendKeyEvents([
            (char: "b", modifiers: .control),
            (char: char, modifiers: modifiers),
        ])
    }

    /// Synthetic click on herdr's own sidebar launcher. herdr's sidebar
    /// spans the full grid height and splits workspaces-over-agents at
    /// `split` (session snapshot's sidebar_section_split); the launcher
    /// ("menu") is the BOTTOM row of the workspaces section:
    /// row = round(rows * split) - 1, right-aligned in the sidebar cols.
    private func clickHerdrLauncher(split: Double) {
        guard let grid = currentGrid else { return }
        let ratio = min(max(split, 0.1), 0.9)
        let wsH = min(max(Int((Double(grid.1) * ratio).rounded()), 3), Int(grid.1) - 3)
        let row = UInt16(clamping: wsH - 1)
        let col = UInt16(clamping: Int(chromeSidebarCols) - 3)
        stream?.sendMouseEvent(kind: 0, button: 0, column: col, row: row, modifiers: [])
        stream?.sendMouseEvent(kind: 1, button: 0, column: col, row: row, modifiers: [])
    }

    /// Opens herdr's global menu, then activates an item by keyboard:
    /// the menu highlights item 0 (settings) on open, so arrow keys +
    /// Enter select deterministically without depending on the panel's
    /// rendered geometry (it opens under our native sidebar and is
    /// never actually visible). The target overlay then renders full
    /// screen in the mirrored content area.
    func openHerdrOverlay(split: Double, keys: String) {
        clickHerdrLauncher(split: split)
        let bytes = Array(keys.utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.stream?.sendInput(bytes)
        }
    }
}
