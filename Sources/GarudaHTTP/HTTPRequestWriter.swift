//===----------------------------------------------------------------------===//
// Request serialisation, for connections this process makes.
//
// The mirror of HTTPResponseWriter next door, and the same shape: bytes go
// straight into the caller's buffer, there is no intermediate header
// collection, and nothing is allocated to describe a message that is about to
// become bytes anyway.
//
// What differs is who the untrusted party is. A server writes a response to a
// request it has already parsed and rejected if malformed; a client writes a
// request whose target and header values an application may well have built
// out of user input -- a path from a route, a token from a form. A CR or LF
// smuggled through any of those ends the request line early and starts a
// second request the caller never wrote, which the server ahead will answer.
// That is request splitting, and on a pooled connection it is request
// smuggling: the extra response arrives while somebody else's request is in
// flight, and every answer after that belongs to the wrong caller.
//
// So every byte that goes out through here is checked, and a value that cannot
// be written safely is refused rather than escaped. Escaping would mean
// guessing what the caller meant; refusing means they find out.
//
// TestClient does not use this, and should not: it builds request text by
// interpolation precisely so tests can send malformed requests at the parser.
// A writer that cannot emit a bad request is the wrong tool for proving the
// server rejects one.
//===----------------------------------------------------------------------===//

import GarudaCore

/// What a caller-supplied request header was recognised as, so the client
/// knows which ones it must still synthesise and which it must refuse.
public struct RequestHeaderKind: OptionSet, Sendable {
    public let rawValue: UInt8
    @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let host             = RequestHeaderKind(rawValue: 1 << 0)
    public static let contentLength    = RequestHeaderKind(rawValue: 1 << 1)
    public static let transferEncoding = RequestHeaderKind(rawValue: 1 << 2)
    public static let connection       = RequestHeaderKind(rawValue: 1 << 3)
    /// A caller that sets its own keeps it; the client adds a default only
    /// when this is absent.
    public static let userAgent        = RequestHeaderKind(rawValue: 1 << 4)
    /// Recognised so the client can refuse it while the compression shim is
    /// encode-only: asking for a coding nothing here can undo buys a body
    /// that cannot be read.
    public static let acceptEncoding   = RequestHeaderKind(rawValue: 1 << 5)
    /// `Expect: 100-continue` changes when the body may be sent, so a client
    /// that writes it without waiting deadlocks against a server that honours
    /// it. Recognised so that is a decision rather than an accident.
    public static let expect           = RequestHeaderKind(rawValue: 1 << 6)

    /// The fields this writer emits itself. A caller-supplied one is refused,
    /// never merged: a second Host is the host-desync attack the parser next
    /// door calls fatal even when the two agree, and a second Content-Length
    /// or a Transfer-Encoding beside one is the smuggling pair it calls
    /// `conflictingFraming`. Sending what this process refuses to receive
    /// would be a strange thing to allow.
    public static let managed: RequestHeaderKind =
        [.host, .contentLength, .transferEncoding, .connection]
}

extension HTTPMethod {
    /// The token to put on the wire, or nil for `.other`, which has no name
    /// of its own -- the caller that parsed or chose it still holds the bytes
    /// and must pass them.
    ///
    /// Lives here rather than beside the enum because nothing else in this
    /// process turns a method back into text: a server reads methods and
    /// never writes one. HTTP/2 will want the same mapping for `:method`.
    @inlinable
    public var token: StaticString? {
        switch self {
        case .get: return "GET"
        case .head: return "HEAD"
        case .post: return "POST"
        case .put: return "PUT"
        case .delete: return "DELETE"
        case .patch: return "PATCH"
        case .options: return "OPTIONS"
        case .connect: return "CONNECT"
        case .trace: return "TRACE"
        case .other: return nil
        }
    }
}

public enum HTTPRequestWriter {

    /// Writes `<method> <target> HTTP/1.1\r\n`, or returns false without
    /// writing anything if either part could break the line.
    ///
    /// The target is checked against VCHAR -- printable ASCII, no space -- which
    /// is what RFC 9112 allows in a request-target and, not by coincidence,
    /// excludes every byte that could end the line early: CR, LF, NUL, space,
    /// DEL and the whole 8-bit range. A target with a space in it is the
    /// commonest form of this bug, because a path built from unescaped user
    /// input usually acquires one long before it acquires a newline.
    public static func writeRequestLine(_ buf: inout ByteBuffer,
                                        method: ByteSpan, target: ByteSpan) -> Bool {
        if method.isEmpty || target.isEmpty { return false }
        var i = 0
        while i < method.count {
            if !isTokenChar(method.base[i]) { return false }
            i &+= 1
        }
        i = 0
        while i < target.count {
            if !isRequestTargetChar(target.base[i]) { return false }
            i &+= 1
        }
        buf.reserve(method.count &+ target.count &+ 12)
        buf.write(method)
        buf.writeByte(cSP)
        buf.write(target)
        buf.write(" HTTP/1.1\r\n")
        return true
    }

    /// As above for a method this process has a name for. `.other` has none,
    /// and is refused here rather than guessed at.
    public static func writeRequestLine(_ buf: inout ByteBuffer,
                                        method: HTTPMethod, target: ByteSpan) -> Bool {
        guard let token = method.token else { return false }
        return UnsafeRawPointer(token.utf8Start).withMemoryRebound(
            to: UInt8.self, capacity: token.utf8CodeUnitCount) { p in
            writeRequestLine(&buf, method: ByteSpan(p, token.utf8CodeUnitCount),
                             target: target)
        }
    }

    /// Writes the one Host field, which HTTP/1.1 requires and this writer owns.
    ///
    /// `authority` is host or host:port, with the port left off when it is the
    /// default for the scheme -- a server matching virtual hosts on the literal
    /// field will not match `example.com:443` against `example.com`.
    public static func writeHost(_ buf: inout ByteBuffer, _ authority: ByteSpan) -> Bool {
        if authority.isEmpty { return false }
        var i = 0
        while i < authority.count {
            // Same VCHAR rule as the target, and for the same reason: a Host
            // is routed on, and a routable value with a newline in it routes
            // twice.
            if !isRequestTargetChar(authority.base[i]) { return false }
            i &+= 1
        }
        buf.reserve(authority.count &+ 8)
        buf.write("Host: ")
        buf.write(authority)
        buf.writeCRLF()
        return true
    }

    /// Writes one caller-supplied field, refusing anything this writer manages
    /// and anything that could split the request.
    ///
    /// The refusal is the point. Silently dropping a caller's Content-Length
    /// would leave them believing they had framed a body they had not, and
    /// writing it beside the one this client emits would put two on the wire.
    public static func writeUserHeader(_ buf: inout ByteBuffer,
                                       name: ByteSpan, value: ByteSpan) -> Bool {
        if !classify(name).isDisjoint(with: .managed) { return false }
        return writeHeader(&buf, name: name, value: value)
    }

    /// Writes one field, checked for bytes that could split the message.
    ///
    /// Forwards to the response writer's implementation: a field is a field in
    /// either direction, and one copy of that check cannot drift out of step
    /// with another the way two copies can.
    @inlinable
    public static func writeHeader(_ buf: inout ByteBuffer,
                                   name: ByteSpan, value: ByteSpan) -> Bool {
        HTTPResponseWriter.writeHeader(&buf, name: name, value: value)
    }

    /// Recognises the fields the client manages or must know about.
    public static func classify(_ name: ByteSpan) -> RequestHeaderKind {
        switch name.count {
        case 4:
            if equalsLowercased(name.base, 4, "host") { return .host }
        case 6:
            if equalsLowercased(name.base, 6, "expect") { return .expect }
        case 10:
            if equalsLowercased(name.base, 10, "connection") { return .connection }
            if equalsLowercased(name.base, 10, "user-agent") { return .userAgent }
        case 14:
            if equalsLowercased(name.base, 14, "content-length") { return .contentLength }
        case 15:
            if equalsLowercased(name.base, 15, "accept-encoding") { return .acceptEncoding }
        case 17:
            if equalsLowercased(name.base, 17, "transfer-encoding") { return .transferEncoding }
        default:
            return []
        }
        return []
    }

    @inlinable
    public static func writeContentLength(_ buf: inout ByteBuffer, _ n: Int) {
        buf.write("Content-Length: ")
        buf.writeDecimal(n)
        buf.writeCRLF()
    }

    @inlinable
    public static func writeChunkedEncoding(_ buf: inout ByteBuffer) {
        buf.write("Transfer-Encoding: chunked\r\n")
    }

    @inlinable
    public static func writeConnection(_ buf: inout ByteBuffer, keepAlive: Bool) {
        buf.write(keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n")
    }

    @inlinable
    public static func endHead(_ buf: inout ByteBuffer) { buf.writeCRLF() }

    /// Frames one chunk of a chunked request body. Chunk framing is the same
    /// in both directions, so this is the response writer's, not a second copy.
    @inlinable
    public static func writeChunk(_ buf: inout ByteBuffer,
                                  _ p: UnsafePointer<UInt8>, _ n: Int) {
        HTTPResponseWriter.writeChunk(&buf, p, n)
    }

    @inlinable
    public static func writeLastChunk(_ buf: inout ByteBuffer) {
        HTTPResponseWriter.writeLastChunk(&buf)
    }
}

/// VCHAR: printable ASCII excluding space. What a request-target may hold, and
/// what a value that is going into a request line must be limited to.
@inlinable
func isRequestTargetChar(_ c: UInt8) -> Bool {
    c > 0x20 && c < 0x7f
}
