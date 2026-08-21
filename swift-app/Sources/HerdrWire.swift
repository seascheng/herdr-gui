import Foundation

/// Client→Server encoder (herdr client protocol **v19**, bincode 2 standard).
/// Variants: 0=Hello 1=Input 2=ClipboardImage 3=Resize 4=Detach 5=AttachTerminal
///           6=AttachScroll 7=InputEvents 8=ObserveTerminal 9=ControlTerminal
/// launch_mode (v19): 0=App 1=TerminalAttach
enum HerdrClientMessage {
    static func hello(cols: UInt16, rows: UInt16, launchModeApp: Bool = false) -> [UInt8] {
        BincodeWriter.withLock {
            BincodeWriter.resetLocked()
            BincodeWriter.writeVariant(0)
            BincodeWriter.writeVarint(UInt32(19))
            BincodeWriter.writeVarint(cols)
            BincodeWriter.writeVarint(rows)
            BincodeWriter.writeVarint(UInt32(0))
            BincodeWriter.writeVarint(UInt32(0))
            BincodeWriter.writeVariant(1) // TerminalAnsi
            BincodeWriter.writeVariant(0) // keybindings = Server
            BincodeWriter.writeVariant(launchModeApp ? 0 : 1) // launch_mode: 0=App 1=TerminalAttach
            return BincodeFrame.frame(BincodeWriter.bytesLocked())
        }
    }

    /// Variant 5: switch this connection into direct terminal attach mode.
    static func attachTerminal(terminalId: String, takeover: Bool) -> [UInt8] {
        BincodeWriter.withLock {
            BincodeWriter.resetLocked()
            BincodeWriter.writeVariant(5)
            BincodeWriter.writeString(terminalId)
            BincodeWriter.writeBool(takeover)
            return BincodeFrame.frame(BincodeWriter.bytesLocked())
        }
    }

    /// Variant 6: host scrollback scroll for attach clients; `lines` is an
    /// exact row count. column/row are 0-based pane-local coordinates.

    static func attachScroll(up: Bool, lines: Int, column: UInt16, row: UInt16,
                             modifiers: UInt8) -> [UInt8] {
        BincodeWriter.withLock {
            BincodeWriter.resetLocked()
            BincodeWriter.writeVariant(6)
            BincodeWriter.writeVariant(0)                       // source = Wheel
            BincodeWriter.writeVariant(up ? 0 : 1)              // direction
            BincodeWriter.writeVarint(UInt16(clamping: lines))
            BincodeWriter.writeVariant(1)                       // column = Some
            BincodeWriter.writeVarint(column)
            BincodeWriter.writeVariant(1)                       // row = Some
            BincodeWriter.writeVarint(row)
            BincodeWriter.writeU8(modifiers)
            return BincodeFrame.frame(BincodeWriter.bytesLocked())
        }
    }

    /// Variant 4: graceful disconnect.
    static func detach() -> [UInt8] {
        BincodeWriter.withLock {
            BincodeWriter.resetLocked()
            BincodeWriter.writeVariant(4)
            return BincodeFrame.frame(BincodeWriter.bytesLocked())
        }
    }

    static func input(_ data: [UInt8]) -> [UInt8] {
        BincodeWriter.withLock {
            BincodeWriter.resetLocked()
            BincodeWriter.writeVariant(1)
            BincodeWriter.writeBytes(data)
            return BincodeFrame.frame(BincodeWriter.bytesLocked())
        }
    }

    static func resize(cols: UInt16, rows: UInt16, cellW: UInt32, cellH: UInt32) -> [UInt8] {
        BincodeWriter.withLock {
            BincodeWriter.resetLocked()
            BincodeWriter.writeVariant(3)
            BincodeWriter.writeVarint(cols)
            BincodeWriter.writeVarint(rows)
            BincodeWriter.writeVarint(cellW)
            BincodeWriter.writeVarint(cellH)
            return BincodeFrame.frame(BincodeWriter.bytesLocked())
        }
    }

    /// Server-side host-scrollback wheel scroll.
    /// Structured mouse scroll (InputEvents → Mouse → ScrollUp/ScrollDown).
    /// herdr's app-mode ANSI stream never enables terminal mouse reporting,
    /// so encoded wheel bytes would be ignored; the TUI CLI sends structured
    /// mouse events instead, and this mirrors that path. column/row are
    /// 0-based over the full app grid (crossterm semantics).

    static func inputEventsScroll(up: Bool, count: Int, column: UInt16, row: UInt16) -> [UInt8] {
        let n = max(count, 1)
        return BincodeWriter.withLock {
            BincodeWriter.resetLocked()
            BincodeWriter.writeVariant(7)            // ClientMessage::InputEvents
            BincodeWriter.writeVariant(UInt32(n))
            for _ in 0..<n {
                BincodeWriter.writeVariant(2)        // ClientInputEvent::Mouse
                BincodeWriter.writeVariant(up ? 4 : 5) // ScrollUp / ScrollDown
                BincodeWriter.writeVarint(column)
                BincodeWriter.writeVarint(row)
                BincodeWriter.writeU8(0)             // modifiers
            }
            return BincodeFrame.frame(BincodeWriter.bytesLocked())
        }
    }

    /// One structured mouse event (InputEvents → Mouse → Down/Up/Drag).
    /// button: 0=Left 1=Right 2=Middle. column/row are 0-based over the
    /// full app grid (crossterm semantics) — herdr routes them to pane
    /// focus, divider drags, selection, and its own menus.
    static func inputEventsMouse(kind: UInt32, button: Int,
                                 column: UInt16, row: UInt16, modifiers: UInt8) -> [UInt8] {
        BincodeWriter.withLock {
            BincodeWriter.resetLocked()
            BincodeWriter.writeVariant(7)            // ClientMessage::InputEvents
            BincodeWriter.writeVariant(1)            // one event
            BincodeWriter.writeVariant(2)            // ClientInputEvent::Mouse
            BincodeWriter.writeVariant(kind)         // 0=Down 1=Up 2=Drag 3=Moved
            if kind < 3 {
                BincodeWriter.writeVariant(UInt32(max(0, min(2, button))))
            }
            BincodeWriter.writeVarint(column)
            BincodeWriter.writeVarint(row)
            BincodeWriter.writeU8(modifiers)
            return BincodeFrame.frame(BincodeWriter.bytesLocked())
        }
    }

}

/// Server→Client (v19). 0=Welcome 1=Frame 2=Terminal 3=Graphics 4=ServerShutdown
/// 5=Notify 6=Clipboard 7=WindowTitle 8=ReloadSoundConfig 9=MouseCapture ...
enum HerdrServerMessage {
    case terminalFrame(seq: UInt64, width: UInt16, height: UInt16, full: Bool, bytes: [UInt8])
    case welcome(version: UInt32, encodingIsAnsi: Bool, error: String?)
    case mouseCapture(Bool)
    case windowTitle(String?)
    case clipboard(String)
    case shutdown(String?)
    case unknown(variant: UInt64)

    static func decode(_ payload: [UInt8]) -> HerdrServerMessage {
        var r = BincodeReader(payload)
        var variant: UInt64 = 0xFFFF
        do {
            variant = try r.readVarint()
            switch variant {
            case 0:
                let version = try r.readU32()
                let enc = try r.readVarint()
                let err = try r.readOptionString()
                return .welcome(version: version, encodingIsAnsi: enc == 1, error: err)
            case 2:
                let seq = try r.readU64()
                let width = try r.readU16()
                let height = try r.readU16()
                let full = try r.readBool()
                let bytes = try r.readBytes()
                return .terminalFrame(seq: seq, width: width, height: height, full: full, bytes: bytes)
            case 7: return .windowTitle(try r.readOptionString())
            case 9: return .mouseCapture(try r.readBool())
            case 6: return .clipboard(try r.readString())
            case 4: return .shutdown(try r.readOptionString())
            default: return .unknown(variant: variant)
            }
        } catch {
            return .unknown(variant: 0xFFFF)
        }
    }
}
