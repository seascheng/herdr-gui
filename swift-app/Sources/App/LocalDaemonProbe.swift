import Foundation

// MARK: - auto-start for the user's main herdr daemon
//
// The Local page talks to the shared daemon socket (~/.config/herdr/
// herdr-client.sock). When nothing is listening there, start one herdr
// server detached and wait for the socket. The daemon is the user's own
// session: never terminated on app exit.

enum LocalDaemonProbe {
    static let clientSocketPath = NSString(
        string: "~/.config/herdr/herdr-client.sock").expandingTildeInPath

    static func isSocketAlive(_ path: String) -> Bool {
        var stat = sockaddr_un()
        stat.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: stat.sun_path) else {
            return false
        }
        pathBytes.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &stat.sun_path) { dest in
                dest.copyBytes(from: raw)
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let sockLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        var address = stat
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, sockLen)
            }
        }
        return result == 0
    }

    /// Spawns `herdr server` detached; returns true when the client socket
    /// came alive within the wait window.
    @discardableResult
    static func startDaemon() -> Bool {
        if isSocketAlive(clientSocketPath) { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: PrivateHerdrSession.herdrBinary())
        process.arguments = ["server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if isSocketAlive(clientSocketPath) { return true }
            usleep(100_000)
        }
        return false
    }
}
