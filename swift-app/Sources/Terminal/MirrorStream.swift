import Foundation

// MARK: - mirror stream abstraction (dependency inversion)

/// The display stream a mirror surface consumes. Terminal owns the
/// abstraction; the herdr attach session (Herdr/) is the implementation.
/// Terminal 不认识任何 herdr 类型——协议字段即视图管线所需。
protocol MirrorStream: AnyObject {
    /// 渲染帧：序号、网格、是否全量（全量 = 新 ANSI 基线）、字节。
    var onFrame: ((UInt64, UInt16, UInt16, Bool, [UInt8]) -> Void)? { get set }
    /// 服务端鼠标捕获通知：true = 聚焦 pane 应用要鼠标上报
    /// （alt-screen TUI），滚轮必须走应用输入路径。
    var onMouseCapture: ((Bool) -> Void)? { get set }
    var onDisconnect: ((String) -> Void)? { get set }
    /// 服务端告知丢弃的帧数（差分基线语义由实现保证）。
    var onFrameGap: ((UInt64) -> Void)? { get set }
    var isAttached: Bool { get }

    func connectApp(cols: UInt16, rows: UInt16) throws
    func sendInput(_ data: [UInt8])
    /// 结构化键事件；modifiers 用 crossterm 位：0x01 shift 0x02 ctrl 0x04 alt。
    func sendKeyEvents(_ keys: [(char: Character, modifiers: UInt8)])
    func sendMouseEvent(kind: UInt32, button: Int, column: UInt16, row: UInt16,
                        modifiers: UInt8)
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
