//===----------------------------------------------------------------------===//
// Request representation.
//
// A parsed request owns no memory. Every field is a (offset, length) pair into
// the connection read buffer, so parsing a request allocates exactly nothing --
// no String, no Array, no Dictionary. The bytes are copied precisely once, when
// they are handed to Python as a str or bytes object.
//===----------------------------------------------------------------------===//

import PeregrineCore

/// A range inside the connection read buffer. 32-bit because a request head is
/// capped well below 4 GiB, which halves the size of the header table and keeps
/// more of it in cache.
public struct HTTPSlice: Equatable, Sendable {
    public var offset: UInt32
    public var length: UInt32

    @inlinable
    public init(_ offset: Int, _ length: Int) {
        self.offset = UInt32(truncatingIfNeeded: offset)
        self.length = UInt32(truncatingIfNeeded: length)
    }

    @inlinable public init() { offset = 0; length = 0 }
    @inlinable public var isEmpty: Bool { length == 0 }
    @inlinable public var count: Int { Int(length) }

    @inlinable
    public func span(in base: UnsafePointer<UInt8>) -> ByteSpan {
        ByteSpan(base + Int(offset), Int(length))
    }
}

public struct HTTPHeaderRef {
    public var name: HTTPSlice
    public var value: HTTPSlice
    /// Cached lowercase-insensitive hash of the name, so the WSGI environ
    /// builder can skip re-folding names it has already classified.
    public var nameHash: UInt32

    @inlinable
    public init(name: HTTPSlice, value: HTTPSlice, nameHash: UInt32) {
        self.name = name
        self.value = value
        self.nameHash = nameHash
    }
}

public enum HTTPMethod: UInt8, Sendable {
    case get, head, post, put, delete, patch, options, connect, trace, other

    @inlinable
    public var hasNoResponseBody: Bool { self == .head }
}

public struct HTTPRequestFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    @inlinable public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let keepAlive       = HTTPRequestFlags(rawValue: 1 << 0)
    public static let chunked         = HTTPRequestFlags(rawValue: 1 << 1)
    public static let expectContinue  = HTTPRequestFlags(rawValue: 1 << 2)
    public static let hasHost         = HTTPRequestFlags(rawValue: 1 << 3)
    public static let upgrade         = HTTPRequestFlags(rawValue: 1 << 4)
    public static let hasContentLength = HTTPRequestFlags(rawValue: 1 << 5)
    /// Set when the path contained a percent escape, so the decoder only runs
    /// on the requests that actually need it.
    public static let escapedPath     = HTTPRequestFlags(rawValue: 1 << 6)
}

public struct HTTPRequestHead {
    public var method: HTTPMethod = .other
    public var methodSlice = HTTPSlice()
    /// The raw request-target, exactly as it arrived (ASGI `raw_path`).
    public var target = HTTPSlice()
    /// Target minus the query string, still percent-encoded.
    public var path = HTTPSlice()
    /// Query string without the leading `?`.
    public var query = HTTPSlice()
    public var httpMinor: UInt8 = 1
    /// 1 for HTTP/1.x, 2 and 3 for the binary versions, where the parser is
    /// only ever handed a head this server rebuilt.
    public var httpMajor: UInt8 = 1
    public var headerCount: Int = 0
    /// -1 when absent.
    public var contentLength: Int = -1
    public var flags: HTTPRequestFlags = []
    /// Byte length of the whole request head including the terminating CRLF.
    public var headEnd: Int = 0

    @inlinable public init() {}

    @inlinable public var isKeepAlive: Bool { flags.contains(.keepAlive) }
    @inlinable public var isChunked: Bool { flags.contains(.chunked) }

    /// Whether a body may follow, per RFC 9112 section 6.
    @inlinable
    public var hasBody: Bool {
        flags.contains(.chunked) || contentLength > 0
    }
}

public enum HTTPParseError: UInt16, Sendable {
    case badRequestLine = 400
    case badHeader = 4001
    case badVersion = 505
    case uriTooLong = 414
    case headTooLarge = 431
    case tooManyHeaders = 4310
    /// Content-Length and Transfer-Encoding together, or two disagreeing
    /// Content-Length values: classic request-smuggling vectors, always fatal.
    case conflictingFraming = 4002
    case unsupportedTransferEncoding = 501
    case badChunk = 4003

    /// HTTP status to report for this failure.
    @inlinable
    public var status: Int {
        switch self {
        case .badRequestLine, .badHeader, .conflictingFraming, .badChunk: return 400
        case .badVersion: return 505
        case .uriTooLong: return 414
        case .headTooLarge, .tooManyHeaders: return 431
        case .unsupportedTransferEncoding: return 501
        }
    }
}

public enum HTTPParseResult {
    case incomplete
    case complete
    case failure(HTTPParseError)
}
