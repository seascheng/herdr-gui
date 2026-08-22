import Foundation

/// Dedicated TerminalAttach connection for native scrolling.
///
/// herdr's App-client wheel path (InputEvents) scrolls a config-fixed number
/// of rows per event and drives the TUI's own wheel routing. Attach clients
/// instead get `AttachScroll { lines }` — exact line counts over the server's
/// scrollback view, with per-pane wheel routing (mouse-report apps receive
/// encoded wheel bytes, plain shells scroll history). The App mirror displays
/// the result, so this channel only ever *sends*.
///
/// Lifecycle: herdr locks a terminal's size while a client is attached, so
/// the connection is opened lazily on the first wheel tick and closed after
/// an idle timeout to release the lock (window splits stay resizable).
final class HerdrScrollChannel {
    private let queue = DispatchQueue(label: "herdr-scroll-channel")
    private var fd: Int32 = -1
    private var attachedTerminalId = ""

    private var idleWorkItem: DispatchWorkItem?
    /// Time after which a failed attach may be retried; before it, callers
    /// use the App-path fallback.
    private var failedUntil = Date.distantPast
    private let idleInterval: TimeInterval = 1.5

    private let socketPath: String

    init(clientSocketPath: String = NSString(
        string: "~/.config/herdr/herdr-client.sock").expandingTildeInPath) {
        self.socketPath = clientSocketPath
    }

    private struct Target: Equatable {
        let terminalId: String
        let columns: UInt16
        let rows: UInt16
    }
    private var target: Target?

    var isUsable: Bool {
        queue.sync { Date() >= failedUntil && target != nil }
    }

    func updateTarget(terminalId: String?, columns: UInt16, rows: UInt16) {
        let next = terminalId.map { Target(terminalId: $0, columns: columns, rows: rows) }
        queue.async { [weak self] in
            guard let self, target != next else { return }
            target = next
            if attachedTerminalId != next?.terminalId { closeLocked() }
        }
    }

    /// Scroll `lines` rows on the focused pane. `column`/`row` are 0-based
    /// pane-local cell coordinates (crossterm semantics).

    func scroll(up: Bool, lines: Int, column: UInt16, row: UInt16) {
        queue.async { [weak self] in
            guard let self,
                  Date() >= failedUntil,
                  let target
            else { return }
            if fd < 0 || attachedTerminalId != target.terminalId {
                closeLocked()
                guard connectLocked(target: target) else { return }
            }

            self.sendAttachScroll(up: up, lines: max(lines, 1),
                                  column: column, row: row)
            self.scheduleIdleClose()
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            self?.closeLocked()
        }
    }

    // MARK: - Connection (queue-private)

    private func connectLocked(target: Target) -> Bool {
        defer { if fd < 0 { failedUntil = Date().addingTimeInterval(1.0) } }
        guard let sock = UnixSocket.connect(path: socketPath) else {
            HerdrLog.error("scroll-channel: connect failed errno=\(errno)")
            return false
        }

        // The handshake must never block this serial queue unboundedly:
        // isUsable() syncs onto it from the main-thread wheel path, so a
        // wedged welcome read would freeze the whole UI. Bound it, then
        // return the socket to blocking mode for the drain reader.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        // Attach resizes the terminal, so Hello must use the focused pane's
        // current allocation from the same snapshot as its terminal id.
        let hello = HerdrClientMessage.hello(
            cols: target.columns,
            rows: target.rows,
            launchModeApp: false
        )

        guard send(fd: sock, bytes: hello) else {
            HerdrLog.error("scroll-channel: hello send failed errno=\(errno)")
            Darwin.close(sock); return false
        }
        guard readWelcome(fd: sock) else {
            HerdrLog.error("scroll-channel: welcome read failed errno=\(errno)")
            Darwin.close(sock); return false
        }

        // Attach (takeover=false: never steal a user's `herdr attach`).
        // The server rejects bad attaches by shutting this connection down;
        // the reader will observe EOF and reset state.
        let attach = HerdrClientMessage.attachTerminal(terminalId: target.terminalId, takeover: false)

        guard send(fd: sock, bytes: attach) else {
            HerdrLog.error("scroll-channel: attach send failed errno=\(errno)")
            Darwin.close(sock); return false
        }


        // Handshake succeeded: back to blocking mode for the drain
        // reader (frames arrive on the server's cadence).
        var blocking = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &blocking,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &blocking,
                   socklen_t(MemoryLayout<timeval>.size))
        fd = sock
        attachedTerminalId = target.terminalId

        startReader(fd: sock)
        return true
    }

    private func readWelcome(fd: Int32) -> Bool {
        // Welcome = u32 length prefix + payload; any length is fine, errors
        // arrive as the same envelope and just fail the attach downstream.
        var lenBuf = [UInt8](repeating: 0, count: 4)
        guard readFully(fd: fd, buffer: &lenBuf, count: 4) else { return false }
        let len = Int(lenBuf[0]) | Int(lenBuf[1]) << 8 | Int(lenBuf[2]) << 16 | Int(lenBuf[3]) << 24
        guard len > 0, len < 1 << 20 else { return len == 0 }
        var payload = [UInt8](repeating: 0, count: len)
        return readFully(fd: fd, buffer: &payload, count: len)
    }

    private func readFully(fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress! + done, count - done)
            }
            if n <= 0 { return false }
            done += n
        }
        return true
    }

    /// Drain server frames so writes never block. The App connection is the
    /// display surface; this stream is discarded. One reader per connection:
    /// a shared "running" flag raced reconnects (a new socket could end up
    /// with no reader, and the server tears down write-blocked clients).
    private func startReader(fd: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let cap = buf.count
                let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, cap) }
                if n <= 0 { break }
            }
            guard let self else { return }
            self.queue.async {
                // Socket died (rejection, teardown, or crash): reset so the
                // next gesture reconnects with fresh snapshot data.
                if self.fd == fd {
                    self.fd = -1
                    self.attachedTerminalId = ""
                    self.failedUntil = Date() // brief backoff until reconcile
                }
                DispatchQueue.main.async { self.onInvalidated?() }
            }
        }
    }

    /// Fired whenever an established connection drops: the cached terminal
    /// id may be stale (closed tab), so reconcile should re-read the
    /// snapshot before the next gesture.
    var onInvalidated: (() -> Void)?

    private func sendAttachScroll(up: Bool, lines: Int, column: UInt16, row: UInt16) {
        let msg = HerdrClientMessage.attachScroll(up: up, lines: lines,
                                                  column: column, row: row, modifiers: 0)
        if !send(fd: fd, bytes: msg) {
            // Rejected or broken: back off so wheel uses the fallback path.
            failedUntil = Date().addingTimeInterval(2)
            closeLocked()
        }
    }

    private func scheduleIdleClose() {
        idleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if fd >= 0 {
                _ = send(fd: fd, bytes: HerdrClientMessage.detach())
            }
            closeLocked()
        }
        idleWorkItem = item
        queue.asyncAfter(deadline: .now() + idleInterval, execute: item)
    }

    private func closeLocked() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        attachedTerminalId = ""
    }

    private func send(fd: Int32, bytes: [UInt8]) -> Bool {
        UnixSocket.writeAll(fd: fd, bytes: bytes)
    }
}
