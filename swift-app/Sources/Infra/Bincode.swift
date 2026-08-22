import Foundation

/// bincode 2.x `standard` config encoder (little-endian, prefix varints).
/// ≤250 → single byte; 251/252/253 tag + fixed-width u16/u32/u64 LE.
enum BincodeWriter {
    private static var buf: [UInt8] = []
    private static let lock = NSLock()

    /// Serialized: input arrives on ghostty's IO thread while resizes arrive
    /// on main; a shared static buffer without a lock corrupts the heap.
    static func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    static func resetLocked() { buf.removeAll(keepingCapacity: true) }
    static func bytesLocked() -> [UInt8] { buf }

    static func writeU8(_ v: UInt8) { buf.append(v) }
    static func writeBool(_ v: Bool) { buf.append(v ? 1 : 0) }

    private static func writePrefixVarint(_ value: UInt64) {
        if value <= 250 {
            buf.append(UInt8(truncatingIfNeeded: value))
        } else if value <= UInt64(UInt16.max) {
            buf.append(251)
            let v = UInt16(truncatingIfNeeded: value)
            buf.append(UInt8(truncatingIfNeeded: v))
            buf.append(UInt8(truncatingIfNeeded: v >> 8))
        } else if value <= UInt64(UInt32.max) {
            buf.append(252)
            let v = UInt32(truncatingIfNeeded: value)
            for shift in stride(from: 0, through: 24, by: 8) {
                buf.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
            }
        } else {
            buf.append(253)
            for shift in stride(from: 0, through: 56, by: 8) {
                buf.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            }
        }
    }

    static func writeVarint(_ v: UInt16) { writePrefixVarint(UInt64(v)) }
    static func writeVarint(_ v: UInt32) { writePrefixVarint(UInt64(v)) }

    static func writeString(_ s: String) {
        let utf8 = Array(s.utf8)
        writePrefixVarint(UInt64(utf8.count))
        buf.append(contentsOf: utf8)
    }

    static func writeBytes(_ b: [UInt8]) {
        writePrefixVarint(UInt64(b.count))
        buf.append(contentsOf: b)
    }

    static func writeVariant(_ index: UInt32) { writePrefixVarint(UInt64(index)) }
}

enum BincodeFrame {
    static func frame(_ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        let len = UInt32(payload.count)
        out[0] = UInt8(truncatingIfNeeded: len)
        out[1] = UInt8(truncatingIfNeeded: len >> 8)
        out[2] = UInt8(truncatingIfNeeded: len >> 16)
        out[3] = UInt8(truncatingIfNeeded: len >> 24)
        out.append(contentsOf: payload)
        return out
    }
}
