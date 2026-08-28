import Foundation

// MARK: - herdr config.toml access (the same file herdr's own TUI edits)

/// Reads/writes herdr's config.toml — directly for the local session,
/// through `ssh <alias>` for remote ones. The caller triggers the
/// server's live reload after a write (the TUI's write-then-reload flow).
final class HerdrConfigStore {
    static let remotePath = "~/.config/herdr/config.toml"
    /// Local config.toml — the file the Settings panel writes and the
    /// menu bar's Open Config File opens.
    static let localPath = NSString(
        string: "~/.config/herdr/config.toml").expandingTildeInPath
    private let alias: String?  // nil = local

    init(target: SessionSpec.Target) {
        if case .ssh(let alias) = target { self.alias = alias } else { self.alias = nil }
    }

    func read(completion: @escaping (String?) -> Void) {
        let alias = self.alias
        let path = Self.localPath
        DispatchQueue.global(qos: .userInitiated).async {
            if let alias {
                completion(Self.ssh(alias: alias, arguments: ["cat", Self.remotePath]))
            } else {
                completion(try? String(contentsOfFile: path, encoding: .utf8))
            }
        }
    }

    func write(_ content: String, completion: @escaping (Bool) -> Void) {
        let alias = self.alias
        let path = Self.localPath
        DispatchQueue.global(qos: .userInitiated).async {
            if let alias {
                let ok = Self.ssh(
                    alias: alias,
                    arguments: ["mkdir -p ~/.config/herdr && cat > \(Self.remotePath)"],
                    stdin: content)
                completion(ok != nil)
            } else {
                let url = URL(fileURLWithPath: path)
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    completion(true)
                } catch {
                    HerdrLog.error("config write: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }
    }

    /// One ssh run; returns stdout, or nil on failure. `arguments` are the
    /// raw remote command words joined for the remote shell.
    private static func ssh(alias: String, arguments: [String], stdin: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", alias]
        args.append(contentsOf: arguments)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            try? inPipe.fileHandleForWriting.close()
        }
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
