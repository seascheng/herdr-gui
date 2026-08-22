import Foundation

/// Reads bincode 2.x `standard` payloads (prefix varints, little-endian).
struct BincodeReader {
    let data: [UInt8]
    private(set) var pos: Int = 0

    init(_ data: [UInt8]) { self.data = data }

    var remaining: Int { data.count - pos }

    private mutating func byte() throws -> UInt8 {
        guard pos < data.count else { throw HerdrWireError.truncated }
        let b = data[pos]; pos += 1; return b
    }

    mutating func readVarint() throws -> UInt64 {
        let first = try byte()
        switch first {
        case 0...250: return UInt64(first)
        case 251: return UInt64(try readU16LE())
        case 252: return UInt64(try readU32LE())
        case 253: return try readU64LE()
        default: throw HerdrWireError.truncated
        }
    }

    private mutating func readU16LE() throws -> UInt16 {
        let lo = try byte(), hi = try byte()
        return UInt16(lo) | UInt16(hi) << 8
    }

    private mutating func readU32LE() throws -> UInt32 {
        var v: UInt32 = 0
        for shift in stride(from: 0, through: 24, by: 8) {
            v |= UInt32(try byte()) << UInt32(shift)
        }
        return v
    }

    private mutating func readU64LE() throws -> UInt64 {
        var v: UInt64 = 0
        for shift in stride(from: 0, through: 56, by: 8) {
            v |= UInt64(try byte()) << UInt64(shift)
        }
        return v
    }

    mutating func readU16() throws -> UInt16 { UInt16(try readVarint()) }
    mutating func readU32() throws -> UInt32 { UInt32(try readVarint()) }
    mutating func readU64() throws -> UInt64 { try readVarint() }
    mutating func readBool() throws -> Bool { try byte() != 0 }

    mutating func readString() throws -> String {
        let n = try readBoundedLength()
        let slice = data[pos..<(pos + n)]
        pos += n
        return String(decoding: slice, as: UTF8.self)
    }

    mutating func readBytes() throws -> [UInt8] {
        let n = try readBoundedLength()
        let slice = Array(data[pos..<(pos + n)])
        pos += n
        return slice
    }

    mutating func readOptionString() throws -> String? {
        try readBool() ? try readString() : nil
    }

    private mutating func readBoundedLength() throws -> Int {
        let raw = try readVarint()
        guard raw <= UInt64(64 << 20) else { throw HerdrWireError.truncated }
        let n = Int(raw)
        guard n >= 0, remaining >= n else { throw HerdrWireError.truncated }
        return n
    }
}

enum HerdrWireError: Error {
    case truncated
    case closed
}
