import Foundation
import AppKit

// MARK: - NSEvent → ClientPaneInputEvent mapping (herdr-gpui terminal.rs port)

/// Where semantic input is addressed: a pane by id, or the active popup.
enum InputTarget: Equatable {
    case pane(String)
    case popup(String)
}

/// Fractional wheel accumulation per target (herdr-gpui WheelAccumulator):
/// sub-cell trackpad motion carries over; target, direction, or gesture
/// changes reset; each event is clamped to ±128 lines.
struct WheelAccumulator {
    private var target: InputTarget?
    private var remainder: Double = 0

    mutating func lines(target newTarget: InputTarget, deltaY: Double,
                        cellHeight: Double, gestureStarted: Bool = false) -> Int {
        if self.target != newTarget || gestureStarted {
            remainder = 0
            self.target = newTarget
        }
        guard deltaY.isFinite, cellHeight > 0 else { return 0 }
        let delta = deltaY / cellHeight
        if delta != 0, delta.sign != remainder.sign {
            remainder = 0
        }
        let total = min(max(remainder + delta, -128), 128)
        let lines = Int(total)
        remainder = total - Double(lines)
        return lines
    }
}

struct WheelTarget {
    let target: InputTarget
    let position: ClientMousePosition
    let geometry: ClientMouseGeometry?

    /// ScrollUp for positive lines (finger up / content down), else ScrollDown.
    func event(lines: Int, modifiers: UInt8) -> ClientPaneInputEvent {
        .mouse(kind: lines > 0 ? .scrollUp : .scrollDown,
               position: position,
               geometry: geometry,
               modifiers: modifiers,
               lines: UInt16(clamping: abs(lines)))
    }
}

enum CellInputMapper {
    /// Modifier bits on the wire: shift=1, control=2, alt=4, super=8,
    /// hyper=16, meta=32. macOS: cmd→super, option→alt.
    static func modifierBits(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        (flags.contains(.shift) ? 1 : 0)
            | (flags.contains(.control) ? 2 : 0)
            | (flags.contains(.option) ? 4 : 0)
            | (flags.contains(.command) ? 8 : 0)
    }

    /// Key events carry only non-printables, ctrl-combos, and function keys:
    /// printable text belongs to IME `TextCommit` commits, preserving
    /// keyboard layouts and dead keys. Cmd chords are native app shortcuts
    /// and never reach the terminal.
    static func keyEvent(keyCode: UInt16, chars: String,
                         modifierFlags: NSEvent.ModifierFlags,
                         isRepeat: Bool) -> ClientPaneInputEvent? {
        guard let code = mapKeyCode(keyCode: keyCode, chars: chars,
                                    modifierFlags: modifierFlags) else { return nil }
        return .key(code: code,
                    modifiers: modifierBits(modifierFlags),
                    kind: isRepeat ? .repeat : .press,
                    repeatCount: 1,
                    shiftedCodepoint: nil,
                    generatedText: nil,
                    tracksRelease: false,
                    physicalKeyId: nil,
                    windowsRecord: nil)
    }

    private static func mapKeyCode(keyCode: UInt16, chars: String,
                                modifierFlags: NSEvent.ModifierFlags) -> ClientKeyCode? {
        let control = modifierFlags.contains(.control)
        let shift = modifierFlags.contains(.shift)
        let command = modifierFlags.contains(.command)
        guard !command else { return nil }
        switch keyCode {
        case 36: return .enter
        case 48: return shift ? .backTab : .tab
        case 49: return control ? .char(" ") : nil
        case 51: return .backspace
        case 53: return .esc
        case 115: return .home
        case 117: return .delete
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 122: return .f(1)
        case 120: return .f(2)
        case 99: return .f(3)
        case 118: return .f(4)
        case 96: return .f(5)
        case 97: return .f(6)
        case 98: return .f(7)
        case 100: return .f(8)
        case 101: return .f(9)
        case 109: return .f(10)
        case 103: return .f(11)
        case 111: return .f(12)
        case 105: return .f(13)
        case 107: return .f(14)
        case 113: return .f(15)
        case 106: return .f(16)
        default: break
        }
        // Control + single char (ctrl-c, ctrl-x …): the unshifted character.
        if control, !chars.isEmpty, chars.utf8.count == 1 {
            return .char(Character(chars))
        }
        return nil
    }

    /// Terminal viewport from pixel bounds: floor division clamped to
    /// 1…4096 columns and rows ≤ 1,000,000/cols (geometry contract).
    static func viewport(width: Double, height: Double,
                         cellWidth: Double, cellHeight: Double) -> ClientSurfaceSize {
        let cw = max(cellWidth, 1)
        let ch = max(cellHeight, 1)
        let cols = min(max(Int(width / cw), 1), 4096)
        let rows = min(max(Int(height / ch), 1), 1_000_000 / cols)
        return ClientSurfaceSize(cols: UInt16(clamping: cols),
                                 rows: UInt16(clamping: max(rows, 1)))
    }

    /// Mouse kind from an NSEvent phase.
    static func mouseKind(isDown: Bool, isDrag: Bool,
                          button: ClientMouseButton) -> ClientMouseKind {
        if isDrag { return .drag(button) }
        return isDown ? .down(button) : .up(button)
    }

    static func mouseButton(eventNumber: Int) -> ClientMouseButton {
        switch eventNumber {
        case 1: return .left
        case 2: return .right
        default: return .middle
        }
    }
}
