import Foundation

// MARK: - minimal TOML section editing

/// Minimal TOML section editing, mirroring herdr's config upsert helpers
/// (config/io.rs): values live under `[section]` headers; missing sections
/// are appended. Pure text logic — no herdr knowledge.
enum TomlEdit {
    /// `[section]` … `key = value` → value (unquoted if quoted).
    static func string(in content: String, section: String, key: String) -> String? {
        for line in sectionLines(content, section: section) {
            if let parsed = parseKeyLine(line, key: key) { return unquote(parsed) }
        }
        return nil
    }

    static func bool(in content: String, section: String, key: String) -> Bool? {
        string(in: content, section: section, key: key).flatMap { $0 == "true" }
    }

    /// Replaces `key` inside `[section]` (creating the line or the whole
    /// section as needed) and returns the updated document.
    static func upsert(_ content: String, section: String, key: String, value: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let header = "[\(section)]"

        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
            // Section body ends at the next header line.
            var end = lines.index(after: start)
            while end < lines.endIndex,
                  !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                end = lines.index(after: end)
            }
            var body = Array(lines[lines.index(after: start)..<end])
            if let idx = body.firstIndex(where: { parseKeyLine($0, key: key) != nil }) {
                body[idx] = "\(key) = \(value)"
            } else {
                body.append("\(key) = \(value)")
            }
            lines.replaceSubrange(lines.index(after: start)..<end, with: body)
            return lines.joined(separator: "\n")
        }

        var out = lines
        if !out.isEmpty && !out[out.count - 1].isEmpty { out.append("") }
        out.append(header)
        out.append("\(key) = \(value)")
        return out.joined(separator: "\n") + "\n"
    }

    static func upsertBool(_ content: String, section: String, key: String, value: Bool) -> String {
        upsert(content, section: section, key: key, value: value ? "true" : "false")
    }

    private static func sectionLines(_ content: String, section: String) -> [String] {
        var collecting = false
        var result: [String] = []
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if collecting { break }
                collecting = line == "[\(section)]"
            } else if collecting {
                result.append(line)
            }
        }
        return result
    }

    private static func parseKeyLine(_ line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"),
              trimmed.hasPrefix("\(key) ")
              || trimmed.hasPrefix("\(key)=")
        else { return nil }
        return trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func unquote(_ s: String) -> String {
        (s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2)
            ? String(s.dropFirst().dropLast()) : s
    }
}
