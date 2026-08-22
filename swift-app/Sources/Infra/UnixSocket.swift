import Foundation
import Darwin

enum UnixSocket {
    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let copied = withUnsafeMutableBytes(of: &address.sun_path) { destination -> Bool in
            guard pathBytes.count <= destination.count else { return false }
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
            return true
        }
        guard copied else {
            Darwin.close(fd)
            return nil
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    static func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { writeAll(fd: fd, buffer: $0) }
    }

    static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { writeAll(fd: fd, buffer: $0) }
    }

    static func readLine(fd: Int32, limit: Int = 64 << 20) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8 << 10)
        while result.count <= limit {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                result.append(contentsOf: buffer[..<newline])
                return result
            }
            result.append(contentsOf: buffer[..<count])
        }
        return result.isEmpty || result.count > limit ? nil : result
    }

    private static func writeAll(fd: Int32, buffer: UnsafeRawBufferPointer) -> Bool {
        guard let base = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}
