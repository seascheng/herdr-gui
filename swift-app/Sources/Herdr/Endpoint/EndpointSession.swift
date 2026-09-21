import Foundation
import Darwin

// MARK: - endpoint session worker (session.rs port, local-active client)
//
// One thread owns connect, handshake, ordered writes, and reads. No
// reconnect and no replay here — GUI-level policy (EndpointClient) decides
// what happens after a disconnect.

/// Fail-closed protocol limits (herdr-protocol codec.rs + herdr-client limits.rs).
enum EndpointLimits {
    static let maxOutboundFrame = 2 << 20          // 2 MiB
    static let maxInboundFrame = 32 << 20          // 32 MiB (graphics)
    static let maxResponseAssembly = 8 << 20       // 8 MiB
    static let handshakeTimeout: TimeInterval = 10
    static let requestTimeout: TimeInterval = 60
    static let readPollInterval: TimeInterval = 0.01
    static let writeTimeout: TimeInterval = 1
    static let maxFutureSurfaces = 16
    static let maxQueuedCommands = 64
}

enum EndpointSessionError: Error, CustomStringConvertible {
    case connectFailed(String)
    case handshake(String)
    case protocolViolation(String)
    case timeout(String)

    var description: String {
        switch self {
        case .connectFailed(let p): return "cannot connect to herdr at \(p)"
        case .handshake(let why): return "handshake failed: \(why)"
        case .protocolViolation(let why): return "protocol violation: \(why)"
        case .timeout(let why): return "timed out: \(why)"
        }
    }
}

private func epDbg(_ text: String) {
    if ProcessInfo.processInfo.environment["HERDR_ENDPOINT_DEBUG"] == "1" {
        FileHandle.standardError.write(Data(("endpoint: " + text + "\n").utf8))
    }
}

final class EndpointSession {
    struct APIRequest {
        let method: String
        let params: [String: Any]
        let completion: ([String: Any]?) -> Void
    }

    struct Outbound {
        let bytes: [UInt8]
        let request: APIRequest?
    }

    /// Serial queue for every callback; never the worker thread, never main.
    private let callbackQueue = DispatchQueue(label: "herdr.endpoint.callbacks")
    private let lock = NSLock()

    let socketPath: String
    private let cellWidth: UInt32
    private let cellHeight: UInt32
    private let cols: UInt16
    private let rows: UInt16

    private var worker: Thread?
    private var stopFlag = false
    private var fd: Int32 = -1
    private var commands: [Outbound] = []
    private var nextRequestId = 1

    // Session state, worker-thread only.
    private var welcome: EndpointWelcome?
    private var snapshot: ClientShellSnapshot?
    private var surface: PaneSurfaceFrame?
    private var futureSurfaces: [PaneSurfaceFrame] = []
    private var pending: (id: String, bytes: [UInt8],
                          started: Date, completion: ([String: Any]?) -> Void)?

    // MARK: Callbacks (callbackQueue)

    var onWelcome: ((EndpointWelcome) -> Void)?
    var onSnapshot: ((ClientShellSnapshot) -> Void)?
    var onSurface: ((PaneSurfaceFrame) -> Void)?
    var onNotification: ((SemanticNotification) -> Void)?
    var onClipboard: ((String) -> Void)?
    var onTitle: ((String?) -> Void)?
    var onDisconnected: ((String) -> Void)?

    init(socketPath: String, cellWidth: UInt32 = 10, cellHeight: UInt32 = 20,
         cols: UInt16 = 80, rows: UInt16 = 24) {
        self.socketPath = socketPath
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.cols = cols
        self.rows = rows
    }

    // MARK: Lifecycle

    func start() {
        lock.lock()
        guard worker == nil else { lock.unlock(); return }
        stopFlag = false
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "herdr-endpoint-io"
        thread.stackSize = 1 << 20
        worker = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        stopFlag = true
        let socket = fd
        fd = -1
        lock.unlock()
        if socket >= 0 { Darwin.close(socket) }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopFlag
    }

    // MARK: Public commands (thread-safe)

    func sendPaneInput(paneId: String, events: [ClientPaneInputEvent]) {
        enqueue(EndpointClientMessage.clientShellPaneInput(paneId: paneId,
                                                           events: events).encoded(),
                request: nil)
    }

    func sendPopupInput(terminalId: String, events: [ClientPaneInputEvent]) {
        enqueue(EndpointClientMessage.clientShellPopupInput(terminalId: terminalId,
                                                            events: events).encoded(),
                request: nil)
    }

    func resize(cellWidth: UInt32, cellHeight: UInt32, cols: UInt16, rows: UInt16) {
        enqueue(EndpointClientMessage.clientShellResize(
            cellWidthPx: cellWidth, cellHeightPx: cellHeight,
            surfaceSize: ClientSurfaceSize(cols: cols, rows: rows),
            pixelMouse: false).encoded(), request: nil)
    }

    /// Single-lane API request. `completion` runs on callbackQueue with the
    /// parsed `{id, result|error}` object, or nil when rejected/failed.
    func request(method: String, params: [String: Any] = [:],
                 completion: @escaping ([String: Any]?) -> Void) {
        enqueue([], request: APIRequest(method: method, params: params,
                                        completion: completion))
    }

    private func enqueue(_ bytes: [UInt8], request: APIRequest?) {
        lock.lock()
        guard !stopFlag, commands.count < EndpointLimits.maxQueuedCommands else {
            lock.unlock()
            if let request {
                callbackQueue.async { request.completion(nil) }
            }
            return
        }
        commands.append(Outbound(bytes: bytes, request: request))
        lock.unlock()
    }

    // MARK: Worker

    private func run() {
        let debug = ProcessInfo.processInfo.environment["HERDR_ENDPOINT_DEBUG"] == "1"
        func dbg(_ text: String) {
            if debug {
                FileHandle.standardError.write(Data(("endpoint: " + text + "\n").utf8))
            }
        }
        dbg("run() connect \(socketPath)")
        let started = Date()
        guard let socket = UnixSocket.connect(path: socketPath) else {
            dbg("connect FAILED errno=\(errno)")
            fail(EndpointSessionError.connectFailed(socketPath).description)
            return
        }
        lock.lock()
        fd = socket
        lock.unlock()

        var timeout = timeval(tv_sec: 0,
                              tv_usec: __darwin_suseconds_t(
                                EndpointLimits.readPollInterval * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var wtimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &wtimeout, socklen_t(MemoryLayout<timeval>.size))

        let hello = EndpointHello.make(cellWidth: cellWidth, cellHeight: cellHeight,
                                       cols: cols, rows: rows)
        let helloJSON: String
        do { helloJSON = try hello.encodedJSON() }
        catch { fail(EndpointSessionError.handshake("encode hello").description); return }
        let helloFrame = EndpointClientMessage.endpointControl(
            kind: EndpointConstants.helloKind, data: helloJSON).encoded()
        guard UnixSocket.writeAll(fd: socket, bytes: helloFrame) else {
            fail(EndpointSessionError.handshake("send hello").description)
            return
        }

        var reader = SessionFrameReader()
        var queued: Outbound?

        while !isStopped && !failedConnection {
            // Handshake/initial-snapshot deadline.
            if snapshot == nil,
               Date().timeIntervalSince(started) > EndpointLimits.handshakeTimeout {
                fail(EndpointSessionError.timeout("initial snapshot").description)
                return
            }
            if let pending, Date().timeIntervalSince(pending.started)
                    > EndpointLimits.requestTimeout {
                fail(EndpointSessionError.timeout("request \(pending.id)").description)
                return
            }

            // Drain commands, bounded per iteration so reads are not starved.
            for _ in 0..<16 {
                if reader.hasPartialFrame { break }  // finish inbound frame first
                guard let next = queued ?? takeCommand() else { queued = nil; break }
                queued = nil
                if let request = next.request {
                    if pending != nil { queued = next; break }  // one lane
                    guard let snapshot else {
                        callbackQueue.async { request.completion(nil) }
                        continue
                    }
                    guard welcome?.advertises(request.method) != false else {
                        callbackQueue.async { request.completion(nil) }
                        continue
                    }
                    let id = String(nextRequestId)
                    nextRequestId += 1
                    let body: [String: Any] = ["id": id, "method": request.method,
                                               "params": request.params]
                    guard let json = try? JSONSerialization.data(
                            withJSONObject: body),
                        let text = String(data: json, encoding: .utf8) else {
                        callbackQueue.async { request.completion(nil) }
                        continue
                    }
                    let frame = EndpointClientMessage.clientShellEndpointRequest(
                        bootId: snapshot.bootId, request: text).encoded()
                    guard UnixSocket.writeAll(fd: socket, bytes: frame) else {
                        callbackQueue.async { request.completion(nil) }
                        fail("socket write failed")
                        return
                    }
                    pending = (id: id, bytes: [],
                               started: Date(), completion: request.completion)
                    continue
                }
                guard UnixSocket.writeAll(fd: socket, bytes: next.bytes) else {
                    fail("socket write failed")
                    return
                }
            }

            let frame: [UInt8]?
            do { frame = try reader.readFrame(fd: socket) }
            catch {
                dbg("read error \(error)")
                fail("socket read failed")
                return
            }
            guard let payload = frame else { continue }  // poll tick
            dbg("frame \(payload.count)B")
            guard let message = try? EndpointServerMessage.decode(payload: payload) else {
                dbg("decode failed")
                fail(EndpointSessionError.protocolViolation("decode frame").description)
                return
            }
            handle(message)
        }
        // Explicit stop: no flush, no replay.
        lock.lock()
        let socket2 = fd
        fd = -1
        lock.unlock()
        if socket2 >= 0 { Darwin.close(socket2) }
    }

    private func takeCommand() -> Outbound? {
        lock.lock(); defer { lock.unlock() }
        guard !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }

    private func handle(_ message: EndpointServerMessage) {
        guard welcome != nil else {
            guard case let .endpointControl(kind, data) = message,
                  kind == EndpointConstants.welcomeKind,
                  let raw = data.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(EndpointWelcome.self,
                                                          from: raw)
            else {
                epDbg("first server message NOT welcome: \(String(describing: message).prefix(120))")
                fail(EndpointSessionError.handshake(
                    "first server message was not \(EndpointConstants.welcomeKind)"
                ).description)
                return
            }
            do {
                welcome = try validateWelcome(decoded)
            } catch let error as EndpointHandshakeError {
                fail(error.description)
                return
            } catch {
                fail(EndpointSessionError.handshake("decode welcome").description)
                return
            }
            emitWelcome(welcome!)
            return
        }

        switch message {
        case .clientShellSnapshot(let s):
            epDbg("handle snapshot rev=\(s.revision)")
            let bootChanged = snapshot.map { $0.bootId != s.bootId } ?? false
            snapshot = s
            if bootChanged {
                surface = nil
                futureSurfaces.removeAll()
            } else if let current = surface,
                      current.projectionRevision < s.revision {
                surface = nil  // stale projection; wait for the matching frame
            }
            emitSnapshot(s)
            publishMatchingSurfaces()

        case .paneSurface(let frame):
            do { try frame.frame.validate() }
            catch {
                fail(EndpointSessionError.protocolViolation("invalid surface").description)
                return
            }
            if matchesSnapshot(frame) {
                surface = frame
                emitSurface(frame)
            } else {
                futureSurfaces.append(frame)
                if futureSurfaces.count > EndpointLimits.maxFutureSurfaces {
                    futureSurfaces.removeFirst()
                }
            }

        case .paneSurfacePatch(let patch):
            guard var current = surface else { return }  // awaiting a full frame
            do {
                try current.applyPatch(patch)
                surface = current
                emitSurface(current)
            } catch {
                fail(EndpointSessionError.protocolViolation(
                        "patch rejected: \(error)").description)
            }
        case let .clientShellEndpointResponseChunk(bootId, requestId, finalChunk, data):
            guard var pending = pending else {
                fail(EndpointSessionError.protocolViolation(
                        "response without pending request").description)
                return
            }
            guard pending.id == requestId, let snapshot,
                  bootId == snapshot.bootId else {
                fail(EndpointSessionError.protocolViolation(
                        "stale response chunk").description)
                return
            }
            pending.bytes.append(contentsOf: data)
            if pending.bytes.count > EndpointLimits.maxResponseAssembly {
                fail(EndpointSessionError.protocolViolation("response too large").description)
                return
            }
            if finalChunk {
                let text = String(decoding: pending.bytes, as: UTF8.self)
                let object = text.data(using: .utf8).flatMap {
                    (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                }
                let completion = pending.completion
                self.pending = nil
                callbackQueue.async { completion(object) }
            } else {
                self.pending = pending
            }
        case .clientShellError(let message):
            if let pending {
                let completion = pending.completion
                self.pending = nil
                callbackQueue.async {
                    completion(["error": ["message": message]])
                }
            }

        case .semanticNotification(let notification):
            let block = onNotification
            callbackQueue.async { block?(notification) }

        case .clipboard(let data):
            let block = onClipboard
            callbackQueue.async { block?(data) }

        case .windowTitle(let title):
            let block = onTitle
            callbackQueue.async { block?(title) }

        case .endpointControl:
            break  // unknown post-welcome controls are optional; ignore

        default:
            break  // legacy attach paths are unused by this client
        }
    }

    private func matchesSnapshot(_ frame: PaneSurfaceFrame) -> Bool {
        guard let snapshot else { return false }
        return frame.bootId == snapshot.bootId
            && frame.projectionRevision == snapshot.revision
    }

    private func publishMatchingSurfaces() {
        guard let snapshot else { return }
        let matching = futureSurfaces.filter {
            $0.bootId == snapshot.bootId && $0.projectionRevision == snapshot.revision
        }
        futureSurfaces.removeAll { frame in
            frame.bootId != snapshot.bootId || frame.projectionRevision < snapshot.revision
        }
        if let newest = matching.last {
            surface = newest
            emitSurface(newest)
        }
    }

    private var failedConnection = false

    private func fail(_ reason: String) {
        lock.lock()
        let alreadyFailed = failedConnection
        failedConnection = true
        let socket = fd
        fd = -1
        lock.unlock()
        guard !alreadyFailed else { return }
        if socket >= 0 { Darwin.close(socket) }
        let block = onDisconnected
        let pendingCompletion = pending?.completion
        pending = nil
        callbackQueue.async {
            pendingCompletion?(nil)
            block?(reason)
        }
    }

    private func emitWelcome(_ w: EndpointWelcome) {
        let block = onWelcome
        callbackQueue.async { block?(w) }
    }

    private func emitSnapshot(_ s: ClientShellSnapshot) {
        let block = onSnapshot
        callbackQueue.async { block?(s) }
    }

    private func emitSurface(_ f: PaneSurfaceFrame) {
        let block = onSurface
        callbackQueue.async { block?(f) }
    }
}

/// Incremental u32-LE length-prefixed frame reader over a polled fd.
/// Partial frames survive read timeouts without losing buffered bytes.
private struct SessionFrameReader {
    private static let debug = ProcessInfo.processInfo.environment["HERDR_ENDPOINT_DEBUG"] == "1"

    private var buffer: [UInt8] = []
    private var payloadLength: Int?

    var hasPartialFrame: Bool { payloadLength != nil || buffer.count >= 4 }

    /// Returns the next complete payload, nil on poll timeout.
    mutating func readFrame(fd: Int32) throws -> [UInt8]? {
        if let payload = parseBuffered() { return payload }
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        let count = chunk.withUnsafeMutableBytes { pointer in
            Darwin.read(fd, pointer.baseAddress, pointer.count)
        }
        if Self.debug && count <= 0 {
            FileHandle.standardError.write(
                Data("endpoint: readFrame count=\(count) errno=\(errno)\n".utf8))
        }
        guard count > 0 else {
            if count == 0 { throw EndpointSessionError.protocolViolation("eof") }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
            throw EndpointSessionError.protocolViolation("read errno \(errno)")
        }
        buffer.append(contentsOf: chunk[..<count])
        return parseBuffered()
    }

    /// Pops ONE complete payload from the buffer, or nil if more bytes are
    /// needed. Buffered leftovers are parsed on later calls before reading.
    private mutating func parseBuffered() -> [UInt8]? {
        if payloadLength == nil {
            guard buffer.count >= 4 else { return nil }
            let len = UInt32(buffer[0]) | UInt32(buffer[1]) << 8
                | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 24
            guard len > 0, len <= EndpointLimits.maxInboundFrame else {
                return nil  // length error handled after a real read path
            }
            payloadLength = Int(len)
            buffer.removeFirst(4)
        }
        guard let length = payloadLength, buffer.count >= length else { return nil }
        let payload = Array(buffer.prefix(length))
        buffer.removeFirst(length)
        payloadLength = nil
        return payload
    }
}
