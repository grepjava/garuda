//===----------------------------------------------------------------------===//
// Response serialisation.
//
// Headers are emitted straight into the connection write buffer as bytes. There
// is no intermediate header collection, no dictionary, and no String: the WSGI
// and ASGI layers hand over pointers into Python-owned memory and those bytes
// are memcpy-ed once into the outgoing buffer.
//===----------------------------------------------------------------------===//

import PeregrineCore

/// What a response header was recognised as, so the writer knows which ones it
/// still has to synthesise.
public struct ResponseHeaderKind: OptionSet, Sendable {
    public let rawValue: UInt8
    @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let contentLength    = ResponseHeaderKind(rawValue: 1 << 0)
    public static let transferEncoding = ResponseHeaderKind(rawValue: 1 << 1)
    public static let connection       = ResponseHeaderKind(rawValue: 1 << 2)
    public static let date             = ResponseHeaderKind(rawValue: 1 << 3)
    public static let server           = ResponseHeaderKind(rawValue: 1 << 4)
}

public enum HTTPResponseWriter {

    /// Writes `HTTP/1.1 <code> <reason>\r\n`.
    @inlinable
    public static func writeStatusLine(_ buf: inout ByteBuffer, status: Int) {
        buf.write("HTTP/1.1 ")
        buf.writeDecimal(status)
        buf.writeByte(cSP)
        buf.write(reason(status))
        buf.writeCRLF()
    }

    /// Status line where the application supplied its own reason phrase (WSGI
    /// hands us `"200 OK"` as one opaque string).
    @inlinable
    public static func writeStatusLine(_ buf: inout ByteBuffer, raw: ByteSpan) {
        buf.write("HTTP/1.1 ")
        buf.write(raw)
        buf.writeCRLF()
    }

    /// Emits one header, rejecting anything that could split the response.
    ///
    /// A CR or LF smuggled through an application-supplied header value is the
    /// classic response-splitting hole, and applications do occasionally
    /// interpolate user input into headers. The check is two comparisons per
    /// byte over data already in L1.
    @inlinable
    public static func writeHeader(_ buf: inout ByteBuffer,
                                   name: ByteSpan, value: ByteSpan) -> Bool {
        var i = 0
        while i < name.count {
            let c = name.base[i]
            if !isTokenChar(c) { return false }
            i &+= 1
        }
        i = 0
        while i < value.count {
            if !isFieldValueChar(value.base[i]) { return false }
            i &+= 1
        }
        buf.reserve(name.count &+ value.count &+ 4)
        buf.write(name)
        buf.writeByte(cColon)
        buf.writeByte(cSP)
        buf.write(value)
        buf.writeCRLF()
        return true
    }

    /// Recognises the headers the server manages itself.
    @inlinable
    public static func classify(_ name: ByteSpan) -> ResponseHeaderKind {
        switch name.count {
        case 4:
            if equalsLowercased(name.base, 4, "date") { return .date }
        case 6:
            if equalsLowercased(name.base, 6, "server") { return .server }
        case 10:
            if equalsLowercased(name.base, 10, "connection") { return .connection }
        case 14:
            if equalsLowercased(name.base, 14, "content-length") { return .contentLength }
        case 17:
            if equalsLowercased(name.base, 17, "transfer-encoding") { return .transferEncoding }
        default:
            return []
        }
        return []
    }

    @inlinable
    public static func writeDate(_ buf: inout ByteBuffer, _ cache: borrowing DateCache) {
        buf.write("Date: ")
        buf.write(UnsafePointer(cache.bytes), cache.count)
        buf.writeCRLF()
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

    /// Frames one chunk of a chunked response.
    @inlinable
    public static func writeChunk(_ buf: inout ByteBuffer,
                                  _ p: UnsafePointer<UInt8>, _ n: Int) {
        buf.reserve(n &+ 20)
        buf.writeHex(n)
        buf.writeCRLF()
        buf.write(p, n)
        buf.writeCRLF()
    }

    @inlinable
    public static func writeLastChunk(_ buf: inout ByteBuffer) {
        buf.write("0\r\n\r\n")
    }

    /// A complete, self-contained error response. Used for parse failures and
    /// for application crashes, where there is nothing left to negotiate.
    public static func writeError(_ buf: inout ByteBuffer, status: Int,
                                  closeConnection: Bool, dateCache: borrowing DateCache) {
        let body = reason(status)
        writeStatusLine(&buf, status: status)
        writeDate(&buf, dateCache)
        buf.write("Server: peregrine\r\nContent-Type: text/plain; charset=utf-8\r\n")
        writeContentLength(&buf, body.utf8CodeUnitCount)
        writeConnection(&buf, keepAlive: !closeConnection)
        endHead(&buf)
        buf.write(body)
    }

    /// Reason phrases for the statuses a server actually emits. Unknown codes
    /// get a generic phrase rather than a lookup failure.
    @inlinable
    public static func reason(_ code: Int) -> StaticString {
        switch code {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 414: return "URI Too Long"
        case 415: return "Unsupported Media Type"
        case 421: return "Misdirected Request"
        case 422: return "Unprocessable Content"
        case 426: return "Upgrade Required"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 505: return "HTTP Version Not Supported"
        default:
            switch code / 100 {
            case 1: return "Informational"
            case 2: return "Success"
            case 3: return "Redirection"
            case 4: return "Client Error"
            default: return "Server Error"
            }
        }
    }

    /// Responses that must not carry a body, per RFC 9110.
    @inlinable
    public static func statusForbidsBody(_ code: Int) -> Bool {
        code == 204 || code == 304 || (code >= 100 && code < 200)
    }
}
