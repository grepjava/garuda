//===----------------------------------------------------------------------===//
// Interned constants.
//
// Every WSGI environ key, every ASGI scope key and every fixed protocol string
// is created once at worker start and reused for the life of the process.
//
// Why it matters: building a WSGI environ means ~20 dict insertions, each of
// which hashes its key. An interned `str` created up front carries its hash in
// the object, so the insertion is a pointer compare instead of a fresh
// allocation plus a UTF-8 decode plus a hash of the bytes. Across 20 keys and
// tens of thousands of requests per second this is one of the largest single
// wins available to a Python server, and it costs one table lookup.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

public enum PyKey: Int, CaseIterable {
    // --- WSGI environ keys ---
    case requestMethod, scriptName, pathInfo, queryString, serverProtocol
    case serverName, serverPort, remoteAddr, remotePort
    case contentType, contentLength
    case wsgiVersion, wsgiURLScheme, wsgiInput, wsgiErrors
    case wsgiMultithread, wsgiMultiprocess, wsgiRunOnce, wsgiFileWrapper
    case wsgiInputTerminated

    // --- ASGI scope keys ---
    case type, asgi, version, specVersion, httpVersion, method, scheme
    case path, rawPath, queryStringBytes, rootPath, headers, client, server
    case state, extensions

    // --- ASGI message keys ---
    case body, moreBody, status, trailers
    case text, bytesKey, subprotocol, subprotocols, code, reason
    case data, stream, moreData, endStream, bidirectional

    // --- ASGI values ---
    case vHTTP, vWebsocket, vLifespan
    case v30, v23, v11, v10, v2, v3
    case vHTTPS
    case vHTTPRequest, vHTTPDisconnect
    case vHTTPResponseStart, vHTTPResponseBody
    case vLifespanStartup, vLifespanStartupComplete, vLifespanStartupFailed
    case vLifespanShutdown, vLifespanShutdownComplete, vLifespanShutdownFailed
    case message
    case vWS, vWSS
    case vWebsocketConnect, vWebsocketAccept, vWebsocketReceive
    case vWebsocketSend, vWebsocketDisconnect, vWebsocketClose
    case vWebTransport
    case vWTConnect, vWTAccept, vWTClose, vWTDisconnect
    case vWTStreamOpen, vWTStreamOpened, vWTStreamReceive, vWTStreamSend
    case vWTDatagramReceive, vWTDatagramSend

    // --- method names for the ASGI scope ---
    case mGET, mHEAD, mPOST, mPUT, mDELETE, mPATCH, mOPTIONS, mCONNECT, mTRACE

    // --- attribute / method names we call through ---
    case nSetResult, nDone, nCancel, nCreateFuture, nCallSoon, nStop, nClose
    case nRead, nReadline, nReadlines, nWrite, nFlush, nSend, nThrow
    case nStartup, nShutdown
}

private let keyNames: [StaticString] = [
    "REQUEST_METHOD", "SCRIPT_NAME", "PATH_INFO", "QUERY_STRING", "SERVER_PROTOCOL",
    "SERVER_NAME", "SERVER_PORT", "REMOTE_ADDR", "REMOTE_PORT",
    "CONTENT_TYPE", "CONTENT_LENGTH",
    "wsgi.version", "wsgi.url_scheme", "wsgi.input", "wsgi.errors",
    "wsgi.multithread", "wsgi.multiprocess", "wsgi.run_once", "wsgi.file_wrapper",
    "wsgi.input_terminated",

    "type", "asgi", "version", "spec_version", "http_version", "method", "scheme",
    "path", "raw_path", "query_string", "root_path", "headers", "client", "server",
    "state", "extensions",

    "body", "more_body", "status", "trailers",
    "text", "bytes", "subprotocol", "subprotocols", "code", "reason",
    "data", "stream", "more_data", "end_stream", "bidirectional",

    "http", "websocket", "lifespan",
    "3.0", "2.3", "1.1", "1.0", "2", "3",
    "https",
    "http.request", "http.disconnect",
    "http.response.start", "http.response.body",
    "lifespan.startup", "lifespan.startup.complete", "lifespan.startup.failed",
    "lifespan.shutdown", "lifespan.shutdown.complete", "lifespan.shutdown.failed",
    "message",
    "ws", "wss",
    "websocket.connect", "websocket.accept", "websocket.receive",
    "websocket.send", "websocket.disconnect", "websocket.close",
    "webtransport",
    "webtransport.connect", "webtransport.accept", "webtransport.close",
    "webtransport.disconnect",
    "webtransport.stream.open", "webtransport.stream.opened",
    "webtransport.stream.receive", "webtransport.stream.send",
    "webtransport.datagram.receive", "webtransport.datagram.send",

    "GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "CONNECT", "TRACE",

    "set_result", "done", "cancel", "create_future", "call_soon", "stop", "close",
    "read", "readline", "readlines", "write", "flush", "send", "throw",
    "startup", "shutdown",
]

/// Global interned-object table. Written once during worker start-up, read-only
/// afterwards, which is exactly what `nonisolated(unsafe)` is for.
public enum Interned {
    nonisolated(unsafe) private static var table: UnsafeMutablePointer<PyObj?>! = nil

    /// Empty `bytes`, `None`, `True`, `False` and the `(1, 0)` WSGI version
    /// tuple, hoisted out of the request path.
    nonisolated(unsafe) public private(set) static var none: PyObj! = nil
    nonisolated(unsafe) public private(set) static var pyTrue: PyObj! = nil
    nonisolated(unsafe) public private(set) static var pyFalse: PyObj! = nil
    nonisolated(unsafe) public private(set) static var emptyBytes: PyObj! = nil
    nonisolated(unsafe) public private(set) static var emptyString: PyObj! = nil
    nonisolated(unsafe) public private(set) static var wsgiVersionTuple: PyObj! = nil

    public static func initialize() -> Bool {
        precondition(keyNames.count == PyKey.allCases.count,
                     "PyKey and keyNames are out of sync")
        table = UnsafeMutablePointer<PyObj?>.allocate(capacity: keyNames.count)
        for (i, name) in keyNames.enumerated() {
            // `name` is a StaticString; its utf8Start is already NUL-terminated
            // because Swift string literals are.
            guard let obj = name.utf8Start.withMemoryRebound(
                to: CChar.self, capacity: name.utf8CodeUnitCount + 1,
                { pg_str_intern($0) }
            ) else { return false }
            table[i] = obj
        }
        none = pg_none()
        pyTrue = pg_true()
        pyFalse = pg_false()
        emptyBytes = pg_bytes_empty()
        emptyString = pg_str_intern("")
        // WSGI requires environ["wsgi.version"] == (1, 0).
        let one = pg_int(1)
        let zero = pg_int(0)
        guard let one, let zero else { return false }
        wsgiVersionTuple = pg_tuple2(one, zero)
        pg_decref(one)
        pg_decref(zero)
        return wsgiVersionTuple != nil && emptyBytes != nil
    }

    /// Borrowed reference; the table owns it forever.
    @inlinable
    public static subscript(_ k: PyKey) -> PyObj {
        storage[k.rawValue].unsafelyUnwrapped
    }

    @usableFromInline
    internal static var storage: UnsafeMutablePointer<PyObj?> {
        @inline(__always) get { table }
    }

    /// The interned uppercase method name for the ASGI scope, avoiding a fresh
    /// string for the overwhelmingly common verbs.
    @inlinable
    public static func methodName(_ m: HTTPMethodCode) -> PyObj? {
        switch m {
        case .get: return Interned[.mGET]
        case .head: return Interned[.mHEAD]
        case .post: return Interned[.mPOST]
        case .put: return Interned[.mPUT]
        case .delete: return Interned[.mDELETE]
        case .patch: return Interned[.mPATCH]
        case .options: return Interned[.mOPTIONS]
        case .connect: return Interned[.mCONNECT]
        case .trace: return Interned[.mTRACE]
        case .other: return nil
        }
    }
}

/// Mirrors `PeregrineHTTP.HTTPMethod` without creating a dependency from the
/// Python layer onto the HTTP layer.
public enum HTTPMethodCode: UInt8, Sendable {
    case get, head, post, put, delete, patch, options, connect, trace, other

    @inlinable
    public init(rawMethodIndex: UInt8) {
        self = HTTPMethodCode(rawValue: rawMethodIndex) ?? .other
    }
}
