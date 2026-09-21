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

