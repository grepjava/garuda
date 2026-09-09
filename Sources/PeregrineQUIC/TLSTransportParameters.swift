//===----------------------------------------------------------------------===//
// QUIC transport parameters.
//
// These are the connection's terms: how much data may be in flight, how many
// streams may be open, how long an idle connection lives. They travel inside
// the TLS handshake rather than in QUIC frames, which is what makes them
// authenticated -- an attacker cannot raise a peer's limits by rewriting a
// packet, because doing so would break the handshake transcript.
//
// A parameter that is absent takes its default, and a default is not always
// zero: ack_delay_exponent defaults to 3 and max_udp_payload_size to 65527.
// Getting those wrong shows up as acknowledgements that are silently
// misinterpreted rather than as an error, so they are spelled out here.
//===----------------------------------------------------------------------===//

import PeregrineCore

public struct QUICTransportParameters {
    public static let originalDestinationConnectionID: UInt64 = 0x00
    public static let maxIdleTimeout: UInt64 = 0x01
    public static let statelessResetToken: UInt64 = 0x02
    public static let maxUDPPayloadSize: UInt64 = 0x03
    public static let initialMaxData: UInt64 = 0x04
    public static let initialMaxStreamDataBidiLocal: UInt64 = 0x05
    public static let initialMaxStreamDataBidiRemote: UInt64 = 0x06
    public static let initialMaxStreamDataUni: UInt64 = 0x07
    public static let initialMaxStreamsBidi: UInt64 = 0x08
    public static let initialMaxStreamsUni: UInt64 = 0x09
    public static let ackDelayExponent: UInt64 = 0x0a
    public static let maxAckDelay: UInt64 = 0x0b
    public static let disableActiveMigration: UInt64 = 0x0c
    public static let preferredAddress: UInt64 = 0x0d
    public static let activeConnectionIDLimit: UInt64 = 0x0e
    public static let initialSourceConnectionID: UInt64 = 0x0f
    public static let retrySourceConnectionID: UInt64 = 0x10
    /// RFC 9221, which WebTransport needs.
    public static let maxDatagramFrameSize: UInt64 = 0x20

    public var maxIdleTimeoutMs: UInt64 = 0
    public var maxUDPPayloadSize: UInt64 = 65527
    public var initialMaxData: UInt64 = 0
    public var initialMaxStreamDataBidiLocal: UInt64 = 0
    public var initialMaxStreamDataBidiRemote: UInt64 = 0
    public var initialMaxStreamDataUni: UInt64 = 0
    public var initialMaxStreamsBidi: UInt64 = 0
    public var initialMaxStreamsUni: UInt64 = 0
    public var ackDelayExponent: UInt64 = 3
    public var maxAckDelayMs: UInt64 = 25
    public var disableActiveMigration = false
    public var activeConnectionIDLimit: UInt64 = 2
    public var maxDatagramFrameSize: UInt64 = 0

    public var originalDestinationCID = QUICConnectionID()
    public var initialSourceCID = QUICConnectionID()
    public var retrySourceCID = QUICConnectionID()
    public var hasInitialSourceCID = false
    public var hasOriginalDestinationCID = false
    public var statelessResetToken: [UInt8] = []

    public init() {}

    /// Writes the server's parameters. Only what differs from a default is
    /// omitted where the default is what we want; the connection identifiers
    /// are always sent, because a client that does not see its own view of
    /// them reflected back is required to abort.
    public func encode(into buffer: inout ByteBuffer, isServer: Bool) {
        func writeInt(_ id: UInt64, _ value: UInt64) {
            buffer.writeVarint(id)
            buffer.writeVarint(UInt64(quicVarintLength(value)))
            buffer.writeVarint(value)
        }
        func writeCID(_ id: UInt64, _ cid: QUICConnectionID) {
            buffer.writeVarint(id)
            buffer.writeVarint(UInt64(cid.length))
            cid.withBytes { p, n in buffer.write(p, n) }
        }

        if maxIdleTimeoutMs > 0 { writeInt(Self.maxIdleTimeout, maxIdleTimeoutMs) }
        writeInt(Self.maxUDPPayloadSize, maxUDPPayloadSize)
        writeInt(Self.initialMaxData, initialMaxData)
        writeInt(Self.initialMaxStreamDataBidiLocal, initialMaxStreamDataBidiLocal)
        writeInt(Self.initialMaxStreamDataBidiRemote, initialMaxStreamDataBidiRemote)
        writeInt(Self.initialMaxStreamDataUni, initialMaxStreamDataUni)
        writeInt(Self.initialMaxStreamsBidi, initialMaxStreamsBidi)
        writeInt(Self.initialMaxStreamsUni, initialMaxStreamsUni)
        writeInt(Self.ackDelayExponent, ackDelayExponent)
        writeInt(Self.maxAckDelay, maxAckDelayMs)
        writeInt(Self.activeConnectionIDLimit, activeConnectionIDLimit)
        if disableActiveMigration {
            buffer.writeVarint(Self.disableActiveMigration)
            buffer.writeVarint(0)
        }
        if maxDatagramFrameSize > 0 {
            writeInt(Self.maxDatagramFrameSize, maxDatagramFrameSize)
        }
        if hasInitialSourceCID { writeCID(Self.initialSourceConnectionID, initialSourceCID) }
        if isServer && hasOriginalDestinationCID {
            writeCID(Self.originalDestinationConnectionID, originalDestinationCID)
        }
        if isServer && !statelessResetToken.isEmpty {
            buffer.writeVarint(Self.statelessResetToken)
            buffer.writeVarint(UInt64(statelessResetToken.count))
            statelessResetToken.withUnsafeBufferPointer { buffer.write($0.baseAddress!, $0.count) }
        }
    }

    /// Returns nil on anything malformed, which is a TRANSPORT_PARAMETER_ERROR
    /// for the caller. A duplicate parameter is malformed too: the RFC says so,
    /// and allowing it would make "which one wins" part of the protocol.
    public static func decode(_ p: UnsafePointer<UInt8>, _ n: Int,
                              fromServer: Bool) -> QUICTransportParameters? {
        var out = QUICTransportParameters()
        var r = QUICReader(p, n)
        var seen = Set<UInt64>()

        while !r.isEmpty {
            guard let id = r.varint(), let length = r.varintAsInt(),
                  let body = r.take(length)
            else { return nil }
            // Only known parameters are policed for duplicates; unknown ones
            // are greasing and may legitimately repeat.
            if id <= Self.maxDatagramFrameSize {
                if seen.contains(id) { return nil }
                seen.insert(id)
            }
            var v = QUICReader(body, length)

            switch id {
            case maxIdleTimeout:
                guard let x = v.varint() else { return nil }
                out.maxIdleTimeoutMs = x
            case maxUDPPayloadSize:
                guard let x = v.varint(), x >= 1200 else { return nil }
                out.maxUDPPayloadSize = x
            case initialMaxData:
                guard let x = v.varint() else { return nil }
                out.initialMaxData = x
            case initialMaxStreamDataBidiLocal:
                guard let x = v.varint() else { return nil }
                out.initialMaxStreamDataBidiLocal = x
            case initialMaxStreamDataBidiRemote:
                guard let x = v.varint() else { return nil }
                out.initialMaxStreamDataBidiRemote = x
            case initialMaxStreamDataUni:
                guard let x = v.varint() else { return nil }
                out.initialMaxStreamDataUni = x
            case initialMaxStreamsBidi:
                guard let x = v.varint(), x <= (1 << 60) else { return nil }
                out.initialMaxStreamsBidi = x
            case initialMaxStreamsUni:
                guard let x = v.varint(), x <= (1 << 60) else { return nil }
                out.initialMaxStreamsUni = x
            case ackDelayExponent:
                guard let x = v.varint(), x <= 20 else { return nil }
                out.ackDelayExponent = x
            case maxAckDelay:
                guard let x = v.varint(), x < 1 << 14 else { return nil }
                out.maxAckDelayMs = x
            case disableActiveMigration:
                if length != 0 { return nil }
                out.disableActiveMigration = true
            case activeConnectionIDLimit:
                guard let x = v.varint(), x >= 2 else { return nil }
                out.activeConnectionIDLimit = x
            case initialSourceConnectionID:
                guard let cid = QUICConnectionID(body, length) else { return nil }
                out.initialSourceCID = cid
                out.hasInitialSourceCID = true
            case originalDestinationConnectionID:
                // A client that claims to have chosen the server's connection
                // ID is confused or hostile.
                if !fromServer { return nil }
                guard let cid = QUICConnectionID(body, length) else { return nil }
                out.originalDestinationCID = cid
                out.hasOriginalDestinationCID = true
            case retrySourceConnectionID:
                if !fromServer { return nil }
                guard let cid = QUICConnectionID(body, length) else { return nil }
                out.retrySourceCID = cid
            case statelessResetToken:
                if !fromServer || length != 16 { return nil }
                out.statelessResetToken = [UInt8](UnsafeBufferPointer(start: body, count: 16))
            case preferredAddress:
                if !fromServer { return nil }
            case maxDatagramFrameSize:
                guard let x = v.varint() else { return nil }
                out.maxDatagramFrameSize = x
            default:
                break   // unknown, and unknown is allowed
            }
        }
        return out
    }
}
