import Foundation
import Darwin

/// One binary client-protocol connection to herdr (herdr-client.sock, v19).
///
/// Full-app (TUI-style) connection: one stream mirroring herdr's entire app
/// frame — the render path the native TUI itself uses, so it is always
/// streaming. Reader thread pumps frames; writes serialize through a queue;
/// the socket read timeout is armed only for the handshake.
///
/// Lifecycle rules that keep rendering stable:
/// - connect() tears down any previous socket BEFORE dialing, so the server
///   never sees two connections from us; a generation token retires readers
///   from superseded connections so they deliver nothing.
/// - Keyboard input typed while (re)connecting is buffered and flushed once
///   the app stream is live (the "IOWRITE after split" black hole).
/// - Frame gaps (server one-slot render queue drops) do NOT resync anything:
///   the server only advances its ANSI diff baseline after a successful
///   write, so the next diff still applies to exactly what we have.
final class HerdrAttachSession {
    private let socketPath: String
    private var sock: Int32 = -1
    private let queue = DispatchQueue(label: "herdr.attach.session")

    /// Bumped on every teardown; readers capture their generation and stop
    /// delivering once superseded.
    private var generation = 0
    /// Keystrokes accepted while no controller socket is live (bounded).
    private var pendingInput: [UInt8] = []
    private static let pendingInputLimit = 1 << 16

    var onFrame: ((MirrorFrame) -> Void)?
    var onMouseCapture: ((Bool) -> Void)?
    var onTitle: ((String?) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onFrameGap: ((UInt64) -> Void)?
    private(set) var isAttached = false

    init(socketPath: String = NSString(string: "~/.config/herdr/herdr-client.sock").expandingTildeInPath) {
        self.socketPath = socketPath
    }

    // MARK: lifecycle

    /// Full-app connection: one stream mirroring herdr's entire
    /// app frame. This is the render path the native TUI itself uses, so it
    /// is always streaming — no per-terminal attach, no control takeover.
    func connectApp(cols: UInt16, rows: UInt16) throws {
        teardownSocket()
        guard let fd = UnixSocket.connect(path: socketPath) else { throw HerdrWireError.closed }
        queue.sync { sock = fd }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        do {
            try send(raw: HerdrClientMessage.hello(cols: cols, rows: rows, launchModeApp: true))
            let firstPayload = try readFrame(fd: fd)
            guard case let .welcome(_, ansi, err) = HerdrServerMessage.decode(firstPayload),
                  err == nil, ansi
            else { throw HerdrWireError.closed }
            var blocking = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &blocking, socklen_t(MemoryLayout<timeval>.size))
            queue.sync {
                isAttached = true
            }
            flushPendingInput()
            startReader()
            if ProcessInfo.processInfo.environment["HERDR_DUMP_FRAMES"] == "1" {
                DiagLog.frames("CONN t=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) attached grid=\(cols)x\(rows)\n")
            }

        } catch {
            queue.sync { if sock == fd { Darwin.close(fd); sock = -1 } }
            throw error
        }
    }

    func close() {
        queue.sync {
            generation += 1
            isAttached = false
            pendingInput.removeAll()
            if sock >= 0 { Darwin.close(sock); sock = -1 }
        }
    }

    /// Closes any live socket and retires its reader. Runs before dialing a
    /// new connection so the server never sees two connections from us.
    private func teardownSocket() {
        queue.sync {
            generation += 1
            isAttached = false
            if sock >= 0 { Darwin.close(sock); sock = -1 }
        }
    }
    // MARK: input path

    func sendInput(_ data: [UInt8]) {
        let buffered = queue.sync { () -> Bool in
            if isAttached, sock >= 0 { return false }
            if pendingInput.count + data.count <= Self.pendingInputLimit {
                pendingInput += data
            }
            return true
        }
        guard !buffered else { return }
        try? send(raw: HerdrClientMessage.input(data))
    }

    /// Sends buffered keystrokes as one Input message once control is live.
    private func flushPendingInput() {
        let buffered = queue.sync { () -> [UInt8] in
            let buf = pendingInput
            pendingInput.removeAll()
            return buf
        }
        guard !buffered.isEmpty else { return }
        try? send(raw: HerdrClientMessage.input(buffered))
    }

    func sendResize(cols: UInt16, rows: UInt16, cellW: UInt32 = 0, cellH: UInt32 = 0) {
        try? send(raw: HerdrClientMessage.resize(cols: cols, rows: rows, cellW: cellW, cellH: cellH))
    }

    /// Structured wheel scroll for the full-app mirror: herdr's app frame
    /// never enables terminal mouse reporting, so the wheel must ride the
    /// same structured InputEvents path the TUI CLI uses.
    func sendWheelScroll(up: Bool, count: Int, column: UInt16, row: UInt16) {
        try? send(raw: HerdrClientMessage.inputEventsScroll(up: up, count: count,
                                                            column: column, row: row))
    }

    /// Structured click/drag forwarding: herdr's app frame never enables
    /// terminal mouse reporting, so mouse interaction rides InputEvents —
    /// the same path the TUI CLI uses (pane focus, divider drags,
    /// selection, herdr menus).
    func sendMouseEvent(kind: UInt32, button: Int, column: UInt16, row: UInt16,
                        modifiers: MirrorKeyModifiers) {
        try? send(raw: HerdrClientMessage.inputEventsMouse(kind: kind, button: button,
                                                           column: column, row: row,
                                                           modifiers: modifiers))
    }

    /// Structured key presses for modifier-dependent herdr bindings
    /// (switch_workspace prefix+shift+N, focus_agent prefix+alt+N).
    func sendKeyEvents(_ keys: [MirrorKeyChord]) {
        try? send(raw: HerdrClientMessage.inputEventsKeys(keys))
    }

    // MARK: internals

    private func startReader() {
        let generation = queue.sync { self.generation }
        let thread = Thread { [weak self] in
            self?.readLoop(gen: generation)
        }
        thread.name = "herdr-attach-reader"
        thread.start()
    }

    private func readLoop(gen: Int) {
        var lastSequence: UInt64 = 0

        while true {
            let fd = queue.sync { () -> Int32 in
                guard gen == generation, isAttached, sock >= 0 else { return -1 }
                return sock
            }
            guard fd >= 0 else { return }
            do {
                let payload = try readFrame(fd: fd)
                let msg = HerdrServerMessage.decode(payload)
                if ProcessInfo.processInfo.environment["HERDR_DUMP_FRAMES"] == "1" {
                    DiagLog.frames("READ t=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) gen=\(gen) \(Self.describe(msg))\n")
                }
                if case let .terminalFrame(sequence, _, _, _, _) = msg {
                    if sequence > lastSequence + 1 && lastSequence > 0 {
                        // The server does not advance its ANSI baseline when
                        // its one-slot client queue drops a frame.
                        onFrameGap?(sequence - lastSequence - 1)
                    }
                    lastSequence = sequence
                }
                if case .shutdown = msg {
                    queue.sync { if gen == generation { isAttached = false } }
                    guard queue.sync(execute: { gen == generation }) else { return }
                    onDisconnect?("shutdown")
                    return
                }
                guard queue.sync(execute: { gen == generation }) else { return }
                forward(msg)
            } catch {
                queue.sync { if gen == generation { isAttached = false } }
                guard queue.sync(execute: { gen == generation }) else { return }
                if ProcessInfo.processInfo.environment["HERDR_DUMP_FRAMES"] == "1" {
                    DiagLog.frames("READ-EXIT t=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) gen=\(gen) error=\(error)\n")
                }
                onDisconnect?("\(error)")
                return
            }
        }
    }

    /// Env-gated (HERDR_DUMP_FRAMES) one-line description of a decoded
    /// server message — the reader-side truth of what herdr pushes.
    private static func describe(_ msg: HerdrServerMessage) -> String {
        switch msg {
        case .welcome(let v, let ansi, let err):
            return "welcome v=\(v) ansi=\(ansi) err=\(err ?? "-")"
        case .terminalFrame(let seq, let w, let h, let full, let bytes):
            return "frame seq=\(seq) grid=\(w)x\(h) full=\(full ? 1 : 0) bytes=\(bytes.count)"
        case .mouseCapture(let on): return "mouse-capture on=\(on)"
        case .windowTitle(let t): return "title \(t ?? "-")"
        case .clipboard: return "clipboard"
        case .shutdown(let r): return "shutdown \(r ?? "-")"
        case .unknown(let v): return "unknown variant=\(v)"
        }
    }

    private func send(raw frame: [UInt8]) throws {
        try queue.sync {
            guard sock >= 0, UnixSocket.writeAll(fd: sock, bytes: frame) else {
                throw HerdrWireError.closed
            }
        }
    }

    private func readFrame(fd: Int32) throws -> [UInt8] {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        try readExact(fd: fd, &lenBuf)
        let len = UInt32(lenBuf[0]) | UInt32(lenBuf[1]) << 8 | UInt32(lenBuf[2]) << 16 | UInt32(lenBuf[3]) << 24
        guard len > 0, len < 64 << 20 else { throw HerdrWireError.truncated }
        var payload = [UInt8](repeating: 0, count: Int(len))
        try readExact(fd: fd, &payload)
        return payload
    }

    private func readExact(fd: Int32, _ buf: inout [UInt8]) throws {
        let total = buf.count
        var got = 0
        while got < total {
            let n = buf.withUnsafeMutableBufferPointer { b -> Int in
                Darwin.read(fd, b.baseAddress! + got, total - got)
            }
            if n <= 0 { throw HerdrWireError.closed }
            got += n
        }
    }
}

/// 语义回调适配：协议消息在此降解为 MirrorStream 的形状，
/// Terminal 层不再看见 HerdrServerMessage。
extension HerdrAttachSession: MirrorStream {
    func sendResize(cols: UInt16, rows: UInt16) {
        sendResize(cols: cols, rows: rows, cellW: 0, cellH: 0)
    }

    fileprivate func forward(_ msg: HerdrServerMessage) {
        switch msg {
        case let .terminalFrame(sequence, width, height, full, bytes):
            onFrame?(MirrorFrame(sequence: sequence, width: width, height: height,
                                 isFullSnapshot: full, bytes: bytes))
        case let .windowTitle(title):
            onTitle?(title)
        case let .mouseCapture(active):
            onMouseCapture?(active)
        default:
            break
        }
    }
}
