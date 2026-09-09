//===----------------------------------------------------------------------===//
// HTTP/2 framing (RFC 9113).
//
// Frames are a nine-octet header and a payload. Nothing here owns memory or
// interprets a payload; it is the wire format and the constants, so that the
// connection layer can stay about state rather than byte offsets.
//===----------------------------------------------------------------------===//

import PeregrineCore

public enum H2FrameType: UInt8 {
    case data = 0x0
    case headers = 0x1
    case priority = 0x2
    case rstStream = 0x3
    case settings = 0x4
    case pushPromise = 0x5
    case ping = 0x6
    case goaway = 0x7
    case windowUpdate = 0x8
    case continuation = 0x9
}

public struct H2Flags: OptionSet, Sendable {
    public let rawValue: UInt8
    @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// DATA, HEADERS.
    public static let endStream  = H2Flags(rawValue: 0x1)
    /// SETTINGS, PING.
    public static let ack        = H2Flags(rawValue: 0x1)
    /// HEADERS, PUSH_PROMISE, CONTINUATION.
    public static let endHeaders = H2Flags(rawValue: 0x4)
    /// DATA, HEADERS, PUSH_PROMISE.
    public static let padded     = H2Flags(rawValue: 0x8)
    /// HEADERS.
    public static let priority   = H2Flags(rawValue: 0x20)
}

/// RFC 9113 section 7.
public enum H2Error: UInt32 {
    case noError = 0x0
    case protocolError = 0x1
    case internalError = 0x2
    case flowControlError = 0x3
    case settingsTimeout = 0x4
    case streamClosed = 0x5
    case frameSizeError = 0x6
    case refusedStream = 0x7
    case cancel = 0x8
    case compressionError = 0x9
    case connectError = 0xa
    case enhanceYourCalm = 0xb
    case inadequateSecurity = 0xc
    case http11Required = 0xd
}

public enum H2Setting: UInt16 {
    case headerTableSize = 0x1
    case enablePush = 0x2
    case maxConcurrentStreams = 0x3
    case initialWindowSize = 0x4
    case maxFrameSize = 0x5
    case maxHeaderListSize = 0x6
    /// RFC 8441, the extended CONNECT protocol that carries WebSockets -- and,
    /// with RFC 9220, WebTransport -- over HTTP/2.
    case enableConnectProtocol = 0x8
}

public struct H2FrameHeader {
    public var length: Int
    public var type: UInt8
    public var flags: H2Flags
    public var streamID: UInt32

    public static let size = 9
    /// Every implementation must accept at least this much; it is also the
    /// default until SETTINGS says otherwise.
    public static let defaultMaxFrameSize = 16384
    public static let defaultInitialWindowSize = 65535
    public static let maxWindowSize = 0x7FFF_FFFF

    public init(length: Int, type: H2FrameType, flags: H2Flags, streamID: UInt32) {
        self.length = length
        self.type = type.rawValue
        self.flags = flags
        self.streamID = streamID
    }

    public init(length: Int, rawType: UInt8, flags: H2Flags, streamID: UInt32) {
        self.length = length
        self.type = rawType
        self.flags = flags
        self.streamID = streamID
    }

    /// Reads a header from at least nine readable bytes.
    @inlinable
    public static func parse(_ p: UnsafePointer<UInt8>) -> H2FrameHeader {
        let length = (Int(p[0]) << 16) | (Int(p[1]) << 8) | Int(p[2])
        // The reserved high bit of the stream identifier is ignored, not
        // rejected: RFC 9113 section 5.1.1.
        let id = (UInt32(p[5] & 0x7F) << 24) | (UInt32(p[6]) << 16)
               | (UInt32(p[7]) << 8) | UInt32(p[8])
        return H2FrameHeader(length: length, rawType: p[3],
                             flags: H2Flags(rawValue: p[4]), streamID: id)
    }

    @inlinable
    public func write(into out: inout ByteBuffer) {
        out.reserve(H2FrameHeader.size)
        let p = out.writePointer
        p[0] = UInt8(truncatingIfNeeded: length >> 16)
        p[1] = UInt8(truncatingIfNeeded: length >> 8)
        p[2] = UInt8(truncatingIfNeeded: length)
        p[3] = type
        p[4] = flags.rawValue
        p[5] = UInt8(truncatingIfNeeded: streamID >> 24) & 0x7F
        p[6] = UInt8(truncatingIfNeeded: streamID >> 16)
        p[7] = UInt8(truncatingIfNeeded: streamID >> 8)
        p[8] = UInt8(truncatingIfNeeded: streamID)
        out.advanceWriter(H2FrameHeader.size)
    }
}

public enum HTTP2 {
    /// The client connection preface, RFC 9113 section 3.4.
    public static let preface: [UInt8] = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    /// Whether `n` bytes at `p` could still become the preface.
    public static func prefaceMatches(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var i = 0
        while i < n && i < preface.count {
            if p[i] != preface[i] { return false }
            i += 1
        }
        return true
    }

    @inlinable
    public static func readUInt32(_ p: UnsafePointer<UInt8>) -> UInt32 {
        (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
    }

    @inlinable
    public static func writeUInt32(_ v: UInt32, into out: inout ByteBuffer) {
        out.reserve(4)
        let p = out.writePointer
        p[0] = UInt8(truncatingIfNeeded: v >> 24)
        p[1] = UInt8(truncatingIfNeeded: v >> 16)
        p[2] = UInt8(truncatingIfNeeded: v >> 8)
        p[3] = UInt8(truncatingIfNeeded: v)
        out.advanceWriter(4)
    }

    /// A header name is valid in HTTP/2 only if it is lowercase and a token.
    /// RFC 9113 section 8.2.1 makes anything else malformed.
    public static func validFieldName(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        if n == 0 { return false }
        var i = 0
        while i < n {
            let c = p[i]
            switch c {
            case 0x41...0x5A: return false            // uppercase
            case 0x30...0x39, 0x61...0x7A: break      // digits, lowercase
            case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E,
                 0x5E, 0x5F, 0x60, 0x7C, 0x7E: break  // remaining tchar
            default: return false
            }
            i += 1
        }
        return true
    }

    /// Field values may not contain NUL, CR or LF, and may not be padded with
    /// spaces or tabs: those are the header-injection shapes.
    public static func validFieldValue(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        if n == 0 { return true }
        if p[0] == 0x20 || p[0] == 0x09 { return false }
        if p[n - 1] == 0x20 || p[n - 1] == 0x09 { return false }
        var i = 0
        while i < n {
            let c = p[i]
            if c == 0x00 || c == 0x0A || c == 0x0D { return false }
            i += 1
        }
        return true
    }

    /// Headers that describe a connection rather than a message, and so have no
    /// meaning in HTTP/2. RFC 9113 section 8.2.2 makes their presence malformed.
    public static func isConnectionSpecific(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        switch n {
        case 2: return equalsLowercased(p, n, "te")   // only "trailers" is legal
        case 7: return equalsLowercased(p, n, "upgrade")
        case 10: return equalsLowercased(p, n, "connection") || equalsLowercased(p, n, "keep-alive")
        case 16: return equalsLowercased(p, n, "proxy-connection")
        case 17: return equalsLowercased(p, n, "transfer-encoding")
        default: return false
        }
    }
}
