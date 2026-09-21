import Foundation
import Darwin

/// Mock-server tests for the session worker: handshake ordering, projection
/// coherence, patch pipeline, request lane, and fail-closed violations.
enum EndpointSessionTests {
    // MARK: - Minimal mock daemon

    final class MockDaemon {
        let path: String
        private var listenFd: Int32 = -1
        private var acceptThread: Thread?
        let clientSemaphore = DispatchSemaphore(value: 0)

        /// Scripted handler per accepted connection; runs on its own thread.
        var handler: ((Int32, MockDaemon) -> Void)?

        init() {
            path = NSTemporaryDirectory() + "herdr-test-\(UUID().uuidString).sock"
        }

        func start() {
            listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenFd >= 0 else { return }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard bound, Darwin.listen(listenFd, 1) == 0 else {
                Darwin.close(listenFd); listenFd = -1; return
            }
            let acceptThread = Thread { [weak self] in
                guard let self else { return }
                while self.handler == nil && self.listenFd >= 0 {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                while true {
                    let client = Darwin.accept(self.listenFd, nil, nil)
                    if ProcessInfo.processInfo.environment["HERDR_ENDPOINT_DEBUG"] == "1" {
                        FileHandle.standardError.write(
                            Data("mock: accept=\(client) errno=\(errno)\n".utf8))
                    }
                    guard client >= 0 else { break }
                    let server = self
                    let handler = self.handler
                    Thread.detachNewThread {
                        handler?(client, server)
                        Darwin.close(client)
                        server.clientSemaphore.signal()
                    }
                }
            }
            self.acceptThread = acceptThread
            acceptThread.start()
        }

        func stop() {
            if listenFd >= 0 {
                Darwin.close(listenFd)
                listenFd = -1
            }
            unlink(path)
        }

        // Helpers for scripts.

        static func welcome(methods: [String] = ["tab.focus"]) -> [UInt8] {
            let json = """
            {"generation":1,"server_version":"0.9.1-test","snapshot_codec":\
            "shell.snapshot.v1","surface_codec":"shell.surface.v1","input_codec":\
            "shell.input.semantic.v1","blob_codec":"shell.blob.v1","methods":\(methods)}
            """
            return EndpointServerMessage.endpointControl(
                kind: EndpointConstants.welcomeKind, data: json).encoded()
        }

        /// The daemon's real snapshot channel: JSON inside EndpointControl.
        /// Minimal valid snapshot (all required keys, empty collections).
        static func snapshot(rev: UInt64, boot: String = "boot") -> [UInt8] {
            let json = """
            {"boot_id":"\(boot)","revision":\(rev),"update_install_command":"",\
            "latest_release_notes_available":false,"integration_updates_available":false,\
            "worktree_directory":"/wt","tab_bar_right":[],"tab_bar_right_separator":" | ",\
            "agent_order":[],"workspaces":[],"tabs":[],"panes":[],"agents":[],"commands":[]}
            """
            return EndpointServerMessage.endpointControl(
                kind: endpointSnapshotKind, data: json).encoded()
        }

        static func surface(rev: UInt64, surf: UInt64 = 1,
                            boot: String = "boot") -> [UInt8] {
            var f = EndpointWireTests.makeFrame()
            f.bootId = boot
            f.projectionRevision = rev
            f.surfaceRevision = surf
            return EndpointServerMessage.paneSurface(f).encoded()
        }

        static func patch(base: UInt64, surf: UInt64, rev: UInt64 = 1,
                          symbol: String = "Z") -> [UInt8] {
            let p = PaneSurfacePatch(
                bootId: "boot", projectionRevision: rev, baseSurfaceRevision: base,
                surfaceRevision: surf,
                rows: [PaneSurfacePatchRow(x: 1, y: 0, cells: [
                    CellData(symbol: symbol, fg: 0, bg: 0, modifier: 0,
                             skip: false, hyperlink: nil)
                ])],
                panes: EndpointWireTests.makeFrame().panes,
                cursor: CursorState(x: 0, y: 0, visible: true, shape: 0))
            return EndpointServerMessage.paneSurfacePatch(p).encoded()
        }

        /// Reads one framed message from the client fd.
        static func readFrame(fd: Int32) -> [UInt8]? {
            var lengthBytes = [UInt8]()
            while lengthBytes.count < 4 {
                var byte: UInt8 = 0
                let n = Darwin.read(fd, &byte, 1)
                guard n == 1 else { return nil }
                lengthBytes.append(byte)
            }
            let len = Int(lengthBytes[0]) | Int(lengthBytes[1]) << 8
                | Int(lengthBytes[2]) << 16 | Int(lengthBytes[3]) << 24
            var payload = [UInt8](repeating: 0, count: len)
            var offset = 0
            while offset < len {
                let n = payload.withUnsafeMutableBytes { pointer in
                    Darwin.read(fd, pointer.baseAddress?.advanced(by: offset),
                                len - offset)
                }
                guard n > 0 else { return nil }
                offset += n
            }
            return payload
        }

        static func write(fd: Int32, bytes: [UInt8]) {
            let written = bytes.withUnsafeBytes { pointer -> Int in
                Darwin.write(fd, pointer.baseAddress, pointer.count)
            }
            if ProcessInfo.processInfo.environment["HERDR_ENDPOINT_DEBUG"] == "1" {
                FileHandle.standardError.write(
                    Data("mock: write \(written)/\(bytes.count) errno=\(errno)\n".utf8))
            }
        }
    }

    // MARK: - Harness

    final class Recorder {
        private let queue = DispatchQueue(label: "recorder")
        private(set) var snapshots: [UInt64] = []
        private(set) var surfaces: [(proj: UInt64, surf: UInt64)] = []
        private(set) var responses: [(String, [String: Any]?)] = []
        private(set) var disconnected: [String] = []
        var welcomed = false
        private let semaphore = DispatchSemaphore(value: 0)

        func install(on session: EndpointSession) {
            session.onWelcome = { [weak self] _ in
                guard let self else { return }
                self.queue.sync { self.welcomed = true }
                self.semaphore.signal()
            }
            session.onSnapshot = { [weak self] s in
                guard let self else { return }
                self.queue.sync { self.snapshots.append(s.revision) }
                self.semaphore.signal()
            }
            session.onSurface = { [weak self] f in
                guard let self else { return }
                self.queue.sync {
                    self.surfaces.append((f.projectionRevision, f.surfaceRevision))
                }
                self.semaphore.signal()
            }
            session.onDisconnected = { [weak self] reason in
                guard let self else { return }
                self.queue.sync { self.disconnected.append(reason) }
                self.semaphore.signal()
            }
        }

        func installResponses(on session: EndpointSession) {
            session.request(method: "tab.focus", params: ["tab_id": "t"]) { object in
                let id = object?["id"] as? String ?? "none"
                self.queue.sync { self.responses.append((id, object)) }
                self.semaphore.signal()
            }
        }

        func wait(_ count: Int, seconds: Double = 3) -> Bool {
            for _ in 0..<count {
                if semaphore.wait(timeout: .now() + seconds) == .timedOut {
                    return false
                }
            }
            return true
        }
    }

    static func register() {
        let ok1 = TestRegistry.add("session: handshake → snapshot → surface order") {
            let daemon = MockDaemon()
            daemon.start()
            defer { daemon.stop() }
            daemon.handler = { fd, _ in
                guard let hello = MockDaemon.readFrame(fd: fd) else { return }
                guard let decoded = try? EndpointClientMessage.decode(payload: hello),
                      case .endpointControl = decoded else { return }
                MockDaemon.write(fd: fd, bytes: MockDaemon.welcome())
                MockDaemon.write(fd: fd, bytes: MockDaemon.snapshot(rev: 1))
                MockDaemon.write(fd: fd, bytes: MockDaemon.surface(rev: 1))
            }
            let session = EndpointSession(socketPath: daemon.path)
            let recorder = Recorder()
            recorder.install(on: session)
            session.start()
            defer { session.stop() }
            expect(recorder.wait(3), "delivery timeout")
            expect(recorder.welcomed, "welcomed")
            expectEq(recorder.snapshots, [1], "snapshot order")
            expectEq(recorder.surfaces.count, 1, "surface count")
            expectEq(recorder.surfaces.first?.proj ?? 0, 1, "surface projection")
        }
        let ok2 = TestRegistry.add("session: future surface held for its snapshot") {
            let daemon = MockDaemon()
            daemon.start()
            defer { daemon.stop() }
            daemon.handler = { fd, _ in
                _ = MockDaemon.readFrame(fd: fd)
                MockDaemon.write(fd: fd, bytes: MockDaemon.welcome())
                MockDaemon.write(fd: fd, bytes: MockDaemon.snapshot(rev: 1))
                // Surface for the NEXT projection: stored, not emitted.
                MockDaemon.write(fd: fd, bytes: MockDaemon.surface(rev: 2, surf: 1))
                // Matching snapshot lands → stored surface re-emits.
                MockDaemon.write(fd: fd, bytes: MockDaemon.snapshot(rev: 2))
            }
            let session = EndpointSession(socketPath: daemon.path)
            let recorder = Recorder()
            recorder.install(on: session)
            session.start()
            defer { session.stop() }
            expect(recorder.wait(4), "delivery timeout")
            expectEq(recorder.snapshots, [1, 2], "snapshots in order")
            expectEq(recorder.surfaces.map(\.proj), [2],
                     "held surface published only after matching snapshot")
        }
        let ok3 = TestRegistry.add("session: patches advance the baseline") {
            let daemon = MockDaemon()
            daemon.start()
            defer { daemon.stop() }
            daemon.handler = { fd, _ in
                _ = MockDaemon.readFrame(fd: fd)
                MockDaemon.write(fd: fd, bytes: MockDaemon.welcome())
                MockDaemon.write(fd: fd, bytes: MockDaemon.snapshot(rev: 1))
                MockDaemon.write(fd: fd, bytes: MockDaemon.surface(rev: 1, surf: 1))
                MockDaemon.write(fd: fd, bytes: MockDaemon.patch(base: 1, surf: 2))
                MockDaemon.write(fd: fd, bytes: MockDaemon.patch(base: 2, surf: 3))
            }
            let session = EndpointSession(socketPath: daemon.path)
            let recorder = Recorder()
            recorder.install(on: session)
            session.start()
            defer { session.stop() }
            expect(recorder.wait(5), "delivery timeout")
            expectEq(recorder.surfaces.map(\.surf), [1, 2, 3], "revisions")
        }
        let ok4 = TestRegistry.add("session: malformed patch disconnects") {
            let daemon = MockDaemon()
            daemon.start()
            defer { daemon.stop() }
            daemon.handler = { fd, _ in
                _ = MockDaemon.readFrame(fd: fd)
                MockDaemon.write(fd: fd, bytes: MockDaemon.welcome())
                MockDaemon.write(fd: fd, bytes: MockDaemon.snapshot(rev: 1))
                MockDaemon.write(fd: fd, bytes: MockDaemon.surface(rev: 1, surf: 1))
                // base 9 does not match current revision 1 → identity failure.
                MockDaemon.write(fd: fd, bytes: MockDaemon.patch(base: 9, surf: 10))
            }
            let session = EndpointSession(socketPath: daemon.path)
            let recorder = Recorder()
            recorder.install(on: session)
            session.start()
            defer { session.stop() }
            expect(recorder.wait(4), "delivery timeout")
            expectEq(recorder.disconnected.count, 1, "one disconnect")
            expect(recorder.disconnected.first?.contains("patch") ?? false,
                   "patch reason: \(recorder.disconnected.first ?? "")")
        }
        let ok5 = TestRegistry.add("session: request round-trip across chunks") {
            let daemon = MockDaemon()
            daemon.start()
            defer { daemon.stop() }
            daemon.handler = { fd, _ in
                _ = MockDaemon.readFrame(fd: fd)
                MockDaemon.write(fd: fd, bytes: MockDaemon.welcome())
                MockDaemon.write(fd: fd, bytes: MockDaemon.snapshot(rev: 1))
                MockDaemon.write(fd: fd, bytes: MockDaemon.surface(rev: 1))
                guard let payload = MockDaemon.readFrame(fd: fd) else { return }
                let message = try? EndpointClientMessage.decode(payload: payload)
                guard case let .clientShellEndpointRequest(boot, request) = message else {
                    return
                }
                guard let object = request.data(using: .utf8).flatMap({
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }), let id = object["id"] as? String else { return }
                expectEq(boot, "boot", "request boot id")
                let half1 = "{\"id\":\"\(id)\",\"result\":{\"a\":"
                let half2 = "1}}"
                MockDaemon.write(fd: fd, bytes: EndpointServerMessage
                    .clientShellEndpointResponseChunk(
                        bootId: "boot", requestId: id, finalChunk: false,
                        data: Array(half1.utf8)).encoded())
                MockDaemon.write(fd: fd, bytes: EndpointServerMessage
                    .clientShellEndpointResponseChunk(
                        bootId: "boot", requestId: id, finalChunk: true,
                        data: Array(half2.utf8)).encoded())
            }
            let session = EndpointSession(socketPath: daemon.path)
            let recorder = Recorder()
            recorder.install(on: session)
            session.start()
            defer { session.stop() }
            expect(recorder.wait(3), "setup timeout")
            recorder.installResponses(on: session)
            expect(recorder.wait(1), "response timeout")
            expectEq(recorder.responses.count, 1, "one completion")
            let object = recorder.responses.first?.1
            let result = object?["result"] as? [String: Any]
            expectEq(result?["a"] as? Int, 1, "chunked result assembled")
        }
        let ok6 = TestRegistry.add("session: unadvertised method rejected locally") {
            let daemon = MockDaemon()
            daemon.start()
            defer { daemon.stop() }
            daemon.handler = { fd, _ in
                _ = MockDaemon.readFrame(fd: fd)
                MockDaemon.write(fd: fd, bytes: MockDaemon.welcome(methods: ["tab.focus"]))
                MockDaemon.write(fd: fd, bytes: MockDaemon.snapshot(rev: 1))
                MockDaemon.write(fd: fd, bytes: MockDaemon.surface(rev: 1))
                Thread.sleep(forTimeInterval: 0.5)
            }
            let session = EndpointSession(socketPath: daemon.path)
            let recorder = Recorder()
            recorder.install(on: session)
            session.start()
            defer { session.stop() }
            expect(recorder.wait(3), "setup timeout")
            recorder.installResponses(on: session)
            expect(recorder.wait(1), "rejection delivery")
            expectEq(recorder.responses.first?.1 == nil, true, "nil for unadvertised")
        }
        let ok7 = TestRegistry.add("session: non-welcome first message fails closed") {
            let daemon = MockDaemon()
            daemon.start()
            defer { daemon.stop() }
            daemon.handler = { fd, _ in
                _ = MockDaemon.readFrame(fd: fd)
                MockDaemon.write(fd: fd, bytes: MockDaemon.snapshot(rev: 1))
            }
            let session = EndpointSession(socketPath: daemon.path)
            let recorder = Recorder()
            recorder.install(on: session)
            session.start()
            defer { session.stop() }
            expect(recorder.wait(1), "disconnect delivery")
            expect(recorder.disconnected.first?.contains("welcome") ?? false,
                   "welcome reason: \(recorder.disconnected.first ?? "")")
        }
        expect(ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7, "registration")
    }
}
