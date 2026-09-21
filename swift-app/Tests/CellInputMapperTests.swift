import Foundation
import AppKit

/// Input mapping tests: the wheel-accumulator matrix ported from herdr-gpui
/// terminal.rs, key-code mapping, modifier bits, and viewport math.
enum CellInputMapperTests {
    static func register() {
        let ok1 = TestRegistry.add("input: wheel preserves fractions, resets on change") {
            var wheel = WheelAccumulator()
            let pane = InputTarget.pane("pane")
            let other = InputTarget.pane("other")
            let popup = InputTarget.popup("other")
            // 12px with cell height 20 → 0 lines, then another 12 → 1.
            expectEq(wheel.lines(target: pane, deltaY: 12, cellHeight: 20), 0, "first 12px")
            expectEq(wheel.lines(target: pane, deltaY: 12, cellHeight: 20), 1, "second 12px")
            // Target change resets the fraction.
            expectEq(wheel.lines(target: other, deltaY: 12, cellHeight: 20), 0, "target reset")
            // Gesture start resets.
            expectEq(wheel.lines(target: popup, deltaY: 12, cellHeight: 20,
                                 gestureStarted: true), 0, "gesture reset")
            // Direction change resets the remainder.
            expectEq(wheel.lines(target: popup, deltaY: 25, cellHeight: 20), 1, "25px → 1")
            expectEq(wheel.lines(target: popup, deltaY: -30, cellHeight: 20), -1, "reverse")
            // Clamped at ±128 lines per event.
            expectEq(wheel.lines(target: popup, deltaY: 1_000_000, cellHeight: 20), 128, "clamp")
            // Non-finite deltas do not poison the accumulator.
            expectEq(wheel.lines(target: pane, deltaY: Double.nan, cellHeight: 20), 0, "nan")
            expectEq(wheel.lines(target: pane, deltaY: 15, cellHeight: 20), 0, "after nan 15")
            expectEq(wheel.lines(target: pane, deltaY: 15, cellHeight: 20), 1, "after nan 30")
        }
        let ok2 = TestRegistry.add("input: wheel event construction") {
            let target = WheelTarget(target: .pane("p1"),
                                     position: .cell(column: 2, row: 3),
                                     geometry: nil)
            let up = target.event(lines: 2, modifiers: 1)
            guard case let .mouse(kind, position, geometry, modifiers, lines) = up else {
                return expect(false, "mouse case")
            }
            expectEq(kind, ClientMouseKind.scrollUp, "kind")
            expectEq(position, ClientMousePosition.cell(column: 2, row: 3), "pos")
            expect(geometry == nil, "no geometry")
            expectEq(modifiers, 1, "shift bit")
            expectEq(lines, 2, "lines")
            let down = target.event(lines: -1, modifiers: 0)
            guard case let .mouse(kind2, _, _, _, lines2) = down else {
                return expect(false, "mouse case 2")
            }
            expectEq(kind2, ClientMouseKind.scrollDown, "down kind")
            expectEq(lines2, 1, "abs lines")
        }
        let ok3 = TestRegistry.add("input: key mapping table") {
            func key(_ keyCode: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags)
                -> ClientPaneInputEvent? {
                CellInputMapper.keyEvent(keyCode: keyCode, chars: chars,
                                         modifierFlags: flags, isRepeat: false)
            }
            // Non-printables.
            guard case .key(let code, _, _, _, _, _, _, _, _) =
                key(36, "\r", []) else { return expect(false, "enter") }
            expectEq(code, ClientKeyCode.enter, "enter")
            guard case .key(let code2, _, _, _, _, _, _, _, _) =
                key(125, "\u{F701}", []) else { return expect(false, "down") }
            expectEq(code2, ClientKeyCode.down, "down")
            guard case .key(let code3, _, _, _, _, _, _, _, _) =
                key(48, "\t", .shift) else { return expect(false, "backtab") }
            expectEq(code3, ClientKeyCode.backTab, "shift-tab")
            // Ctrl combos: ctrl-c as Char("c") with control bit.
            guard case .key(.char(let c), let modifiers, _, _, _, _, _, _, _) =
                key(8, "c", .control) else { return expect(false, "ctrl-c") }
            expectEq(c, "c", "ctrl char")
            expectEq(modifiers, 2, "control bit")
            // Cmd chords never reach the terminal.
            expect(key(8, "c", .command) == nil, "cmd-c dropped")
            // Plain printable text is NOT a key event (IME/TextCommit owns it).
            expect(key(8, "c", []) == nil, "plain char dropped")
            expect(key(49, " ", []) == nil, "plain space dropped")
            // ctrl-space maps to Char(" ").
            guard case .key(.char(let sp), let m2, _, _, _, _, _, _, _) =
                key(49, " ", .control) else { return expect(false, "ctrl-space") }
            expectEq(sp, " ", "space char")
            expectEq(m2, 2, "ctrl bit")
        }
        let ok4 = TestRegistry.add("input: modifier bits and viewport math") {
            expectEq(CellInputMapper.modifierBits(.shift), 1, "shift")
            expectEq(CellInputMapper.modifierBits(.control), 2, "control")
            expectEq(CellInputMapper.modifierBits(.option), 4, "alt")
            expectEq(CellInputMapper.modifierBits(.command), 8, "super")
            expectEq(CellInputMapper.modifierBits([.shift, .option]), 5, "combined")
            let size = CellInputMapper.viewport(width: 800.6, height: 419.9,
                                                cellWidth: 8.01, cellHeight: 20.0)
            expectEq(size.cols, 99, "cols floor")
            expectEq(size.rows, 20, "rows floor")
            // Degenerate inputs clamp to 1x1 instead of zero.
            let tiny = CellInputMapper.viewport(width: 3, height: 1,
                                                cellWidth: 10, cellHeight: 20)
            expectEq(tiny.cols, 1, "min cols")
            expectEq(tiny.rows, 1, "min rows")
        }
        expect(ok1 && ok2 && ok3 && ok4, "registration")
    }
}
