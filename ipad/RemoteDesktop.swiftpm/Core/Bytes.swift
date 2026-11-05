// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/Bytes.swift からコピー。直接編集しないでください。
/// リトルエンディアンでバイト列を組み立てる小さなヘルパー。
public struct ByteWriter {
    public var bytes: [UInt8]

    public init(capacity: Int = 0) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }

    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    public mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

    /// 既に書き込んだ位置の u32 を上書きする。
    public mutating func patchU32(at offset: Int, _ v: UInt32) {
        bytes[offset] = UInt8(truncatingIfNeeded: v)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: v >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }
}

public enum ProtocolError: Error, CustomStringConvertible {
    case truncated
    case invalid(String)

    public var description: String {
        switch self {
        case .truncated: return "データが途中で切れています"
        case .invalid(let s): return "不正なデータ: \(s)"
        }
    }
}

/// リトルエンディアンでバイト列を読むヘルパー。
public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ProtocolError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw ProtocolError.truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    public mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw ProtocolError.truncated }
        defer { offset += 4 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    public mutating func skip(_ n: Int) throws {
        guard n >= 0, remaining >= n else { throw ProtocolError.truncated }
        offset += n
    }
}
