import Foundation

// MARK: - mirror stream abstraction (dependency inversion)

/// One server frame. A full frame re-baselines the ANSI stream (diffs
/// apply on top of it); anything else applies to the running baseline.
struct MirrorFrame {
    let sequence: UInt64
    let width: UInt16
    let height: UInt16
    let isFullSnapshot: Bool
    let bytes: [UInt8]
}

/// Modifier bits exactly as herdr's InputEvents wire expects them
/// (crossterm semantics).
struct MirrorKeyModifiers: OptionSet {
    let rawValue: UInt8
    static let shift = Self(rawValue: 0x01)
    static let control = Self(rawValue: 0x02)
    static let alternate = Self(rawValue: 0x04)
    static let command = Self(rawValue: 0x08)
}

/// One keypress: the character plus the modifiers held alongside it.
typealias MirrorKeyChord = (char: Character, modifiers: MirrorKeyModifiers)

/// The display stream a mirror surface consumes. Terminal owns the
/// abstraction; the herdr attach session (Herdr/) is the implementation.
/// Terminal 不认识任何 herdr 类型——协议字段即视图管线所需。
protocol MirrorStream: AnyObject {
    /// 渲染帧；实现方保证 gap 语义（差分基线不因丢帧漂移）。
    var onFrame: ((MirrorFrame) -> Void)? { get set }
    /// 服务端鼠标捕获通知：true = 聚焦 pane 应用要鼠标上报
    /// （alt-screen TUI），滚轮必须走应用输入路径。
    var onMouseCapture: ((Bool) -> Void)? { get set }
    var onDisconnect: ((String) -> Void)? { get set }
    var onFrameGap: ((UInt64) -> Void)? { get set }
    var isAttached: Bool { get }

    func connectApp(cols: UInt16, rows: UInt16) throws
    func sendInput(_ data: [UInt8])
    func sendKeyEvents(_ keys: [MirrorKeyChord])
    func sendMouseEvent(kind: UInt32, button: Int, column: UInt16, row: UInt16,
                        modifiers: MirrorKeyModifiers)
    func sendWheelScroll(up: Bool, count: Int, column: UInt16, row: UInt16)
    func sendResize(cols: UInt16, rows: UInt16)
    func close()
}

/// 原生滚动通道：精确行数的 scrollback 滚动（捕获关闭时使用）。
protocol PaneScrollChannel: AnyObject {
    var isUsable: Bool { get }
    var onInvalidated: (() -> Void)? { get set }
    func updateTarget(terminalId: String?, columns: UInt16, rows: UInt16)
    func scroll(up: Bool, lines: Int, column: UInt16, row: UInt16)
    func shutdown()
}
