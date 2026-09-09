//===----------------------------------------------------------------------===//
// RFC 6455 framing.
//
// Same posture as the HTTP parser: no allocation, no copying beyond the one
// unmask pass that has to touch every payload byte anyway, and strictness
// wherever leniency would let a peer desynchronise the stream.
//
// The rules that are actually enforced here, because each one is a real
// interoperability or security failure if it is not:
//   * a client frame must be masked, and a server frame must not be;
//   * a control frame is at most 125 bytes and is never fragmented;
//   * reserved bits must be clear, since no extension has been negotiated;
//   * an unknown opcode is a protocol error rather than something to skip;
//   * a continuation frame without a message in progress, or a new data frame
//     while one is in progress, is a protocol error.
//===----------------------------------------------------------------------===//

import PeregrineCore

public enum WSOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    @inlinable
    public var isControl: Bool { rawValue & 0x8 != 0 }

    @inlinable
    public init?(_ raw: UInt8) {
        switch raw {
        case 0x0: self = .continuation
        case 0x1: self = .text
        case 0x2: self = .binary
        case 0x8: self = .close
        case 0x9: self = .ping
        case 0xA: self = .pong
        default: return nil
        }
    }
}

/// Close codes this server originates. Peer-supplied codes are passed through
/// to the application unchanged.
public enum WSCloseCode {
    public static let normal: UInt16 = 1000
    public static let goingAway: UInt16 = 1001
    public static let protocolError: UInt16 = 1002
    public static let unsupportedData: UInt16 = 1003
    /// Reported to the application when the peer closed without a code.
    public static let noStatus: UInt16 = 1005
    public static let abnormal: UInt16 = 1006
    public static let invalidPayload: UInt16 = 1007
    public static let policyViolation: UInt16 = 1008
    public static let messageTooBig: UInt16 = 1009
    public static let internalError: UInt16 = 1011
}

public struct WSFrameHeader {
    public var fin = false
    public var opcode: WSOpcode = .continuation
    public var masked = false
    public var payloadLength = 0
    public var mask: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    /// Bytes the header itself occupies.
    public var headerLength = 0

    @inlinable public init() {}
    @inlinable public var totalLength: Int { headerLength &+ payloadLength }
}

public enum WSDecodeError: Sendable {
    case protocolError
    case messageTooBig
    case unmaskedClientFrame
}

public enum WSDecodeResult {
    case needMore
    case header(WSFrameHeader)
    case failure(WSDecodeError)
}

public enum WebSocketCodec {

    /// Parses a frame header. The payload is not required to be present yet:
    /// the caller compares `totalLength` against what it has buffered.
    public static func parseHeader(_ base: UnsafePointer<UInt8>, _ count: Int,
                                   maxPayload: Int) -> WSDecodeResult {
        if count < 2 { return .needMore }
        var head = WSFrameHeader()
        let b0 = base[0]
        let b1 = base[1]

        // No extension has been negotiated, so RSV1..3 must be zero.
        if b0 & 0x70 != 0 { return .failure(.protocolError) }
        guard let opcode = WSOpcode(b0 & 0x0F) else { return .failure(.protocolError) }
        head.fin = (b0 & 0x80) != 0
        head.opcode = opcode
        head.masked = (b1 & 0x80) != 0

        var length = Int(b1 & 0x7F)
        var offset = 2
        if length == 126 {
            if count < 4 { return .needMore }
            length = (Int(base[2]) << 8) | Int(base[3])
            offset = 4
        } else if length == 127 {
            if count < 10 { return .needMore }
            var v = 0
            var i = 2
            while i < 10 {
                // The high bit must be zero per RFC 6455, and anything past
                // 2^62 would overflow the arithmetic below regardless.
                if i == 2 && base[i] & 0x80 != 0 { return .failure(.protocolError) }
                v = (v << 8) | Int(base[i])
                i += 1
            }
            length = v
            offset = 10
        }

        if opcode.isControl {
            // A control frame must be short and must not be fragmented, so a
            // peer cannot smuggle an unbounded payload past the message limit.
            if length > 125 || !head.fin { return .failure(.protocolError) }
        } else if length > maxPayload {
            return .failure(.messageTooBig)
        }

        if head.masked {
            if count < offset + 4 { return .needMore }
            head.mask = (base[offset], base[offset + 1], base[offset + 2], base[offset + 3])
            offset += 4
        }
        head.payloadLength = length
        head.headerLength = offset
        return .header(head)
    }

    /// Copies `n` payload bytes from `src` to `dst`, unmasking as it goes.
    /// `phase` is the index of the first byte within the frame payload, so a
    /// payload delivered in pieces still lines up with the four-byte key.
    @inlinable
    public static func unmask(_ dst: UnsafeMutablePointer<UInt8>,
                              _ src: UnsafePointer<UInt8>,
                              _ n: Int,
                              _ mask: (UInt8, UInt8, UInt8, UInt8),
                              phase: Int = 0) {
        var key = mask
        withUnsafeBytes(of: &key) { raw in
            let k = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < n {
                dst[i] = src[i] ^ k[(i &+ phase) & 3]
                i &+= 1
            }
        }
    }

    /// Writes a server frame. Server frames are never masked.
    public static func writeFrame(_ buf: inout ByteBuffer,
                                  opcode: WSOpcode,
                                  fin: Bool,
                                  payload: UnsafePointer<UInt8>?,
                                  length: Int) {
        buf.reserve(length &+ 10)
        buf.writeByte((fin ? 0x80 : 0x00) | opcode.rawValue)
        if length < 126 {
            buf.writeByte(UInt8(length))
        } else if length <= 0xFFFF {
            buf.writeByte(126)
            buf.writeByte(UInt8(truncatingIfNeeded: length >> 8))
            buf.writeByte(UInt8(truncatingIfNeeded: length))
        } else {
            buf.writeByte(127)
            var shift = 56
            while shift >= 0 {
                buf.writeByte(UInt8(truncatingIfNeeded: length >> shift))
                shift -= 8
            }
        }
        if let payload, length > 0 { buf.write(payload, length) }
    }

    /// A close frame carrying a status code and an optional UTF-8 reason.
    public static func writeClose(_ buf: inout ByteBuffer,
                                  code: UInt16,
                                  reason: UnsafePointer<UInt8>?,
                                  reasonLength: Int) {
        // 125 total, minus the two code bytes.
        let n = min(reasonLength, 123)
        var payload = ByteBuffer(capacity: n + 2)
        defer { payload.destroy() }
        payload.writeByte(UInt8(truncatingIfNeeded: code >> 8))
        payload.writeByte(UInt8(truncatingIfNeeded: code))
        if let reason, n > 0 { payload.write(reason, n) }
        writeFrame(&buf, opcode: .close, fin: true,
                   payload: UnsafePointer(payload.readPointer), length: n + 2)
    }

    /// Whether a close code may appear on the wire. 1005 and 1006 are
    /// reserved for local reporting and must never be sent.
    @inlinable
    public static func isSendableCloseCode(_ code: UInt16) -> Bool {
        if code == 1005 || code == 1006 || code == 1015 { return false }
        if code >= 1000 && code <= 1014 { return true }
        return code >= 3000 && code <= 4999
    }
}

/// Validates UTF-8 incrementally, which a text message has to be.
///
/// A server that forwards invalid UTF-8 as `str` either raises deep inside the
/// application or silently substitutes replacement characters; RFC 6455 says to
/// fail the connection with 1007 instead.
public struct UTF8Validator {
    @usableFromInline var state: UInt32 = 0
    @usableFromInline var codepoint: UInt32 = 0
    /// Smallest value the sequence in progress is allowed to encode, which is
    /// what rules out overlong forms.
    @usableFromInline var minimum: UInt32 = 0

    @inlinable public init() {}

    @inlinable public var isComplete: Bool { state == 0 }

    /// Feeds bytes. Returns false as soon as the sequence cannot be valid.
    public mutating func feed(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var i = 0
        while i < n {
            let c = p[i]
            i &+= 1
            if state == 0 {
                if c < 0x80 { continue }
                if c >= 0xC2 && c <= 0xDF {
                    state = 1; minimum = 0x80; codepoint = UInt32(c & 0x1F); continue
                }
                if c >= 0xE0 && c <= 0xEF {
                    state = 2; minimum = 0x800; codepoint = UInt32(c & 0x0F); continue
                }
                if c >= 0xF0 && c <= 0xF4 {
                    state = 3; minimum = 0x10000; codepoint = UInt32(c & 0x07); continue
                }
                return false
            }
            if c & 0xC0 != 0x80 { return false }
            codepoint = (codepoint << 6) | UInt32(c & 0x3F)
            state &-= 1
            if state == 0 {
                // Overlong encodings, surrogates and out-of-range values are
                // all rejected here rather than passed to Python.
                if codepoint > 0x10FFFF { return false }
                if codepoint >= 0xD800 && codepoint <= 0xDFFF { return false }
                if codepoint < minimum { return false }
            }
        }
        return true
    }
}
