//===----------------------------------------------------------------------===//
// A UUID, without Foundation.
//
//     let id = UUID.random()
//     try await db.execute("insert into orders (id, placed) values ($1, $2)", id, Timestamp.now)
//
// Sixteen bytes. It binds to PostgreSQL as a uuid in binary, reads back from
// a uuid column in either format, and is a string in JSON. Written as
// `Garuda.UUID` wherever Foundation's is also in scope.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaPostgres

public struct UUID: Hashable, Comparable, Sendable {
    /// The first eight bytes, big-endian.
    public let high: UInt64
    /// The last eight bytes, big-endian.
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    /// From exactly 16 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        high = bytes[0..<8].reduce(0) { $0 << 8 | UInt64($1) }
        low = bytes[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// From its text, with or without hyphens, in either case.
    public init?(_ text: String) {
        guard let bytes = UUIDText.parse(text.utf8) else { return nil }
        self.init(bytes: bytes)
    }

    /// A version 4 UUID: 122 random bits from the system's generator.
    public static func random() -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let filled = bytes.withUnsafeMutableBytes { pg_random_bytes($0.baseAddress, 16) }
        // An identifier that might repeat is worse than none: a system that
        // cannot hand out random bytes is not one to keep running on.
        precondition(filled == 0, "the system's random generator failed")
        bytes[6] = bytes[6] & 0x0F | 0x40
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(bytes: bytes)!
    }

    public var bytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            out[i] = UInt8(truncatingIfNeeded: high >> (56 - 8 * UInt64(i)))
            out[8 + i] = UInt8(truncatingIfNeeded: low >> (56 - 8 * UInt64(i)))
        }
        return out
    }

    /// The version nibble: 4 for `random()`.
    public var version: Int { Int(high >> 12 & 0xF) }

    public static func < (a: UUID, b: UUID) -> Bool {
        (a.high, a.low) < (b.high, b.low)
    }
}

extension UUID: CustomStringConvertible, LosslessStringConvertible {
    /// `xxxxxxxx-xxxx-4xxx-xxxx-xxxxxxxxxxxx`, lower case.
    public var description: String { UUIDText.format(bytes) }
}

extension UUID: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try String(from: decoder)
        guard let value = UUID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a UUID: \(text)"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        try description.encode(to: encoder)
    }
}

extension UUID: PostgresBindable {
    public var postgresValue: PostgresValue { .binary(bytes, type: PostgresType.uuid) }
}
