import Foundation
import Darwin

/// Long-lived `events.subscribe` stream on the herdr API socket (herdr.sock).
///
/// One dedicated connection (the API is one-request-per-connection for
/// everything else): subscribe once, then the server pushes NDJSON event
/// envelopes (`{"event":"tab.focused","data":{...}}`). This replaces
/// snapshot polling as the primary change signal — a tab click round-trips
/// in ~10ms instead of waiting for the next 2s poll.
final class HerdrEventStream {
    private let socketPath: String
    private let queue = DispatchQueue(label: "herdr.events")
    private var generation = 0
    private var socketFd: Int32 = -1

    private(set) var isRunning = false

    /// Event name → called on the main queue.
    var onEvent: ((String) -> Void)?

    private static let subscribeRequest: [UInt8] = {
        let request: [String: Any] = [
            "id": "herdr-mirror:events",
            "method": "events.subscribe",
            "params": [
                "subscriptions": [
                    ["type": "tab.focused"],
                    ["type": "layout.updated"],
                ]
            ],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return [] }
        data.append(0x0A)
        return Array(data)

    }()

    init(socketPath: String = NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath) {
        self.socketPath = socketPath
    }

    func start() {
        let shouldStart = queue.sync { () -> Bool in
            guard !isRunning else { return false }
            isRunning = true
            generation += 1
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "herdr-events"
        thread.start()
    }

    func stop() {
        queue.sync {
            generation += 1
            isRunning = false
            if socketFd >= 0 { Darwin.shutdown(socketFd, SHUT_RDWR) }
        }
    }

    private func loop() {
        var backoff: UInt32 = 1
        while queue.sync(execute: { isRunning }) {
            if runOnce() {
                backoff = 1 // clean exit after stop()
                return
            }
            // Reconnect with a capped delay; never let the counter overflow.
            sleep(backoff)
            backoff = min(backoff * 2, 5)

        }
    }

    /// Runs one connection until it drops. Returns true when the stream was
    /// stopped explicitly (caller should exit).
    private func runOnce() -> Bool {
        let generation = queue.sync { self.generation }
        guard let fd = UnixSocket.connect(path: socketPath) else { return false }
        let accepted = queue.sync { () -> Bool in
            guard self.generation == generation, isRunning else { return false }
            socketFd = fd
            return true
        }
        guard accepted else {
            Darwin.close(fd)
            return true
        }
        defer {
            queue.sync { if socketFd == fd { socketFd = -1 } }
            Darwin.close(fd)
        }

        guard !Self.subscribeRequest.isEmpty,
              UnixSocket.writeAll(fd: fd, bytes: Self.subscribeRequest) else {
            return false
        }

        var pending = [UInt8]()
        pending.reserveCapacity(8 << 10)
        var chunk = [UInt8](repeating: 0, count: 8 << 10)
        while queue.sync(execute: { self.generation == generation && isRunning }) {
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { return false }
            pending.append(contentsOf: chunk[..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let name = Self.eventName(line) else { continue }
                DispatchQueue.main.async { [weak self] in self?.onEvent?(name) }
            }
            guard pending.count <= 1 << 20 else { return false }
        }
        return true
    }

    /// `{"event":"<name>",...}` → name. The first line after subscribe is an
    /// ack (`{"id":...,"result":...}`) and yields nil.
    private static func eventName(_ line: [UInt8]) -> String? {
        guard let text = String(bytes: line, encoding: .utf8),
              let start = text.range(of: "\"event\":\"")
        else { return nil }
        let tail = text[start.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let name = String(tail[..<end])
        return name.isEmpty ? nil : name
    }
}
