import Foundation
import os

// MARK: - logging

/// Unified os.Logger (the vendored Ghostty embed calls HerdrLog too).
enum HerdrLog {
    private static let logger = Logger(subsystem: "com.herdr-gui", category: "app")
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
    static func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
}

/// Env-gated diagnostics sink: appends to a /tmp log (created on first
/// write). The HERDR_DUMP_VIEWS / HERDR_DUMP_FRAMES harnesses render
/// their reports through these — one append implementation, two files.
enum DiagLog {
    static func views(_ text: String) { append(text, to: "/tmp/herdr-views.log") }
    static func frames(_ text: String) { append(text, to: "/tmp/herdr-frames.log") }

    private static func append(_ text: String, to path: String) {
        let url = URL(fileURLWithPath: path)
        let data = text.data(using: .utf8) ?? Data()
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
