import Foundation
import Darwin

// MARK: - herdr NDJSON control plane (herdr.sock)

/// One-shot JSON control calls. The herdr API is one-request-per-
/// connection (verified live), so every call dials its own socket and
/// runs off the main thread — a busy herdr can never freeze chrome.
final class HerdrAPI {
    static let defaultSocketPath = NSString(
        string: "~/.config/herdr/herdr.sock").expandingTildeInPath
    static let defaultClientSocketPath = NSString(
        string: "~/.config/herdr/herdr-client.sock").expandingTildeInPath

    let socketPath: String
    private let asyncQueue = DispatchQueue(
        label: "herdr.api", qos: .userInitiated, attributes: .concurrent)

    init(socketPath: String = HerdrAPI.defaultSocketPath) {
        self.socketPath = socketPath
    }

    /// Blocking call — callers must be off the main thread.
    func call(_ method: String, _ params: [String: Any],
              timeout: TimeInterval? = nil) -> [String: Any]? {
        guard let fd = UnixSocket.connect(path: socketPath) else { return nil }
        defer { Darwin.close(fd) }
        if let timeout {
            let seconds = max(1, Int(timeout.rounded(.up)))
            var value = timeval(tv_sec: seconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value,
                       socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value,
                       socklen_t(MemoryLayout<timeval>.size))
        }

        let request: [String: Any] = ["id": "herdr-gui", "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A)
        guard UnixSocket.writeAll(fd: fd, data: data),
              let response = UnixSocket.readLine(fd: fd),
              let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = json["result"] as? [String: Any]
        else { return nil }
        return result
    }

    /// One-shot control request off the main thread; completion on main.
    func callAsync(_ method: String, _ params: [String: Any],
                   completion: @escaping ([String: Any]?) -> Void) {
        asyncQueue.async { [self] in
            let result = call(method, params, timeout: 3)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func focusTabAsync(_ tabId: String, completion: @escaping (Bool) -> Void) {
        callAsync("tab.focus", ["tab_id": tabId]) { completion($0 != nil) }
    }

    func focusWorkspaceAsync(_ workspaceId: String,
                             completion: @escaping (Bool) -> Void) {
        callAsync("workspace.focus", ["workspace_id": workspaceId]) {
            completion($0 != nil)
        }
    }

    /// Snapshot read for reconcile — off the main thread.
    func snapshot() -> [String: Any]? {
        call("session.snapshot", [:], timeout: 5)?["snapshot"] as? [String: Any]
    }

    /// Fire-and-forget control mutation: chrome actions (close/rename/
    /// create) must never block on the server. The completion (main
    /// queue) is the earliest point a re-read makes sense.
    func perform(_ method: String, _ params: [String: Any],
                 completion: (() -> Void)? = nil) {
        asyncQueue.async { [self] in
            _ = call(method, params, timeout: 5)
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    func closeTabAsync(_ tabId: String, completion: (() -> Void)? = nil) {
        perform("tab.close", ["tab_id": tabId], completion: completion)
    }

    func closeWorkspaceAsync(_ workspaceId: String,
                             completion: (() -> Void)? = nil) {
        perform("workspace.close", ["workspace_id": workspaceId],
                completion: completion)
    }

    func createWorkspaceAsync(_ completion: (() -> Void)? = nil) {
        perform("workspace.create", [:], completion: completion)
    }

    func renameTabAsync(_ tabId: String, to name: String) {
        perform("tab.rename", ["tab_id": tabId, "name": name])
    }
}
