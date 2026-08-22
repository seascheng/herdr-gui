import Foundation

// MARK: - session model

/// One selectable connection in the servers menu / session bar.
/// Local herdr is the pinned default page; "Terminal" (local, no
/// herdr) opens a plain shell surface; ssh hosts choose between a
/// herdr mirror (tunnel + full chrome) and a plain ssh terminal page.
struct SessionSpec: Equatable {
    enum Target: Equatable {
        case local
        case ssh(alias: String)
    }

    let target: Target
    let wantsHerdr: Bool

    var label: String {
        switch target {
        case .local: return wantsHerdr ? "Local" : "Terminal"
        case .ssh(let alias): return alias
        }
    }

    var id: String {
        switch target {
        case .local: return wantsHerdr ? "local" : "local:term"
        case .ssh(let alias): return "ssh:\(alias):\(wantsHerdr ? "herdr" : "term")"
        }
    }
}

// MARK: - ~/.ssh/config parsing

/// Parses `Host` aliases out of ~/.ssh/config (plus one level of Include).
/// Wildcard patterns (`*`, `?`) are menu noise and are skipped; a Host
/// line may list several patterns and each non-wildcard token is an alias.
enum SSHConfig {
    private static var cache: (mtime: Date, hosts: [String])?

    /// The servers menu re-reads on every open; parse only when the
    /// main config file changed (mtime check, add-workspace style).
    static func hostAliases() -> [String] {
        let path = NSHomeDirectory() + "/.ssh/config"
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?
            .first { $0.key == .modificationDate }?.value as? Date ?? .distantPast
        if let c = cache, c.mtime == mtime { return c.hosts }
        var seen = Set<String>()
        var order: [String] = []
        parse(file: path, depth: 0, seen: &seen, order: &order)
        cache = (mtime, order)
        return order
    }

    private static func parse(file: String, depth: Int,
                              seen: inout Set<String>, order: inout [String]) {
        guard depth <= 2,
              let text = try? String(contentsOfFile: file, encoding: .utf8)
        else { return }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1,
                                   omittingEmptySubsequences: true)
            guard let key = parts.first?.lowercased() else { continue }
            let value = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces) : ""

            switch key {
            case "host":
                for token in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    let alias = String(token)
                    guard !alias.isEmpty,
                          !alias.contains("*"), !alias.contains("?"),
                          !alias.hasPrefix("!")
                    else { continue }
                    if seen.insert(alias).inserted { order.append(alias) }
                }
            case "include":
                for token in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    var path = String(token)
                    if path.hasPrefix("~/") {
                        path = NSHomeDirectory() + String(path.dropFirst())
                    } else if !path.hasPrefix("/") {
                        path = NSHomeDirectory() + "/.ssh/" + path
                    }
                    let nsPath = path as NSString
                    if FileManager.default.fileExists(atPath: path, isDirectory: nil) {
                        parse(file: path, depth: depth + 1, seen: &seen, order: &order)
                    } else {
                        // Directory include: take files whose name starts
                        // with the include's file component (covers
                        // `Include conf.d/*` without full glob support).
                        let dir = nsPath.deletingLastPathComponent
                        let prefix = nsPath.lastPathComponent
                        let names = (try? FileManager.default
                            .contentsOfDirectory(atPath: dir)) ?? []
                        for name in names.sorted() where name.hasPrefix(prefix) {
                            parse(file: dir + "/" + name,
                                  depth: depth + 1, seen: &seen, order: &order)
                        }
                    }
                }
            default:
                break
            }
        }
    }
}

// MARK: - SSH streamlocal tunnel

/// Forwards a remote server's two herdr sockets to local endpoints via one
/// `ssh -N -L` connection (OpenSSH streamlocal forwarding), so every
/// existing unix-socket client (API, attach, scroll channel) works
/// unchanged against remote servers.
///
///     ssh -N -o ExitOnForwardFailure=yes \
///         -L <tmp>/api.sock:<remote-home>/.config/herdr/herdr.sock \
///         -L <tmp>/client.sock:<remote-home>/.config/herdr/herdr-client.sock \
///         <alias>
///
/// The remote home is resolved with one `ssh <alias> printenv HOME` probe
/// because `-L` does not expand `~` remotely. NOT YET VERIFIED against a
/// live remote herdr — no test server exists yet.
final class SSHTunnel {
    struct Endpoints {
        let apiSocket: String
        let clientSocket: String
    }

    enum TunnelError: LocalizedError {
        case homeProbeFailed
        case forwardTimeout

        var errorDescription: String? {
            switch self {
            case .homeProbeFailed:
                return "Could not resolve the remote home directory (ssh printenv HOME failed — check key auth)."
            case .forwardTimeout:
                return "ssh did not bring up the socket forwards within 15s."
            }
        }
    }

    /// herdr's socket layout on the remote host, relative to $HOME.
    static let remoteApiSuffix = ".config/herdr/herdr.sock"
    static let remoteClientSuffix = ".config/herdr/herdr-client.sock"

    let alias: String
    private(set) var endpoints: Endpoints?
    private var process: Process?
    private var readyPoller: Timer?
    private let dir = NSTemporaryDirectory()
        + "hertty-\(UUID().uuidString.prefix(8))"

    var onError: ((Error) -> Void)?

    init(alias: String) {
        self.alias = alias
    }

    /// Brings the tunnel up and reports the local endpoints (main queue).
    func start(onReady: @escaping (Result<Endpoints, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            let api = dir + "/api.sock"
            let client = dir + "/client.sock"
            try? FileManager.default.removeItem(atPath: api)
            try? FileManager.default.removeItem(atPath: client)

            // 1) Remote home (ssh does not expand ~ in -L remote paths).
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            probe.arguments = ["-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
                               alias, "printenv HOME"]
            probe.standardOutput = Pipe()
            probe.standardError = Pipe()
            do { try probe.run() } catch {
                DispatchQueue.main.async { onReady(.failure(error)) }
                return
            }
            let homeData = (probe.standardOutput as? Pipe)?
                .fileHandleForReading.readDataToEndOfFile() ?? Data()
            probe.waitUntilExit()
            guard let home = String(data: homeData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !home.isEmpty
            else {
                DispatchQueue.main.async { onReady(.failure(TunnelError.homeProbeFailed)) }
                return
            }

            // 2) Long-lived forward connection.
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = [
                "-N", "-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                "-L", api + ":" + home + "/" + Self.remoteApiSuffix,
                "-L", client + ":" + home + "/" + Self.remoteClientSuffix,
                alias,
            ]
            do { try ssh.run() } catch {
                DispatchQueue.main.async { onReady(.failure(error)) }
                return
            }
            process = ssh

            // 3) Wait for ssh to create the local listeners.
            let deadline = Date().addingTimeInterval(15)
            pollReady(api: api, client: client, deadline: deadline) { [weak self] ok in
                guard let self else { return }
                if ok {
                    let ep = Endpoints(apiSocket: api, clientSocket: client)
                    self.endpoints = ep
                    DispatchQueue.main.async { onReady(.success(ep)) }
                } else {
                    self.shutdown()
                    DispatchQueue.main.async { onReady(.failure(TunnelError.forwardTimeout)) }
                }
            }
        }
    }

    private func pollReady(api: String, client: String, deadline: Date,
                           completion: @escaping (Bool) -> Void) {
        let fm = FileManager.default
        if fm.fileExists(atPath: api) && fm.fileExists(atPath: client) {
            completion(true)
            return
        }
        guard Date() < deadline, process?.isRunning == true else {
            completion(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            self.pollReady(api: api, client: client, deadline: deadline, completion: completion)
        }
    }

    func shutdown() {
        readyPoller?.invalidate()
        readyPoller = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        if let ep = endpoints {
            try? FileManager.default.removeItem(atPath: ep.apiSocket)
            try? FileManager.default.removeItem(atPath: ep.clientSocket)
        }
        try? FileManager.default.removeItem(atPath: dir)
    }

    deinit { shutdown() }
}
