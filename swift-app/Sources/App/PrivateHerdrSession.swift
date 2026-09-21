import Foundation

// MARK: - private herdr session for standalone terminal pages
//
// The plain Terminal / ssh pages run their own herdr server instance with
// private sockets (HERDR_SOCKET_PATH → derived *-client.sock), rendered by
// the same endpoint client + cell canvas as everything else. One terminal
// implementation; the user's main session stays untouched.

final class PrivateHerdrSession {
    static let shared = PrivateHerdrSession()

    private var processes: [String: Process] = [:]  // socketPath → process
    private let lock = NSLock()

    private var baseDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/herdr-gui/private"
    }

    /// Ensures a private server for `key` is running and returns its
    /// client socket path. `key` is a stable page id (session spec id).
    func clientSocketPath(key: String) -> String? {
        let apiSocket = baseDirectory + "/" + safe(key) + ".sock"
        let clientSocket = baseDirectory + "/" + safe(key) + "-client.sock"

        if isSocketAlive(clientSocket) { return clientSocket }

        lock.lock()
        defer { lock.unlock() }

        if isSocketAlive(clientSocket) { return clientSocket }
        // A stale server may hold the api socket; its client socket would
        // be alive too, so a dead client socket means spawn is safe.
        try? FileManager.default.createDirectory(
            atPath: baseDirectory, withIntermediateDirectories: true)
        unlink(apiSocket)
        unlink(clientSocket)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: PrivateHerdrSession.herdrBinary())
        process.arguments = ["server"]
        process.environment = ["HERDR_SOCKET_PATH": apiSocket]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        processes[clientSocket] = process

        // Wait for the client socket to accept (server startup).
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if isSocketAlive(clientSocket) { return clientSocket }
            usleep(100_000)
        }
        return nil
    }

    func shutdown(clientSocket: String) {
        lock.lock()
        defer { lock.unlock() }
        if let process = processes.removeValue(forKey: clientSocket) {
            process.terminate()
        }
    }

    private func safe(_ key: String) -> String {
        key.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }

    private func isSocketAlive(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let pathCopied: Bool = withUnsafeMutableBytes(of: &address.sun_path) { destination in
            guard destination.count >= bytes.count else { return false }
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
            return true
        }
        guard pathCopied else { return false }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        return connected
    }

    static func herdrBinary() -> String {
        let candidates = [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            NSHomeDirectory() + "/.local/bin/herdr",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "herdr"
    }
}
