//===----------------------------------------------------------------------===//
// Traces, through swift-distributed-tracing.
//
//     app.onWorkerStart { _ in InstrumentationSystem.bootstrap(makeTracer()) }
//     app.tracing()
//
// Each request is a server span, continued from the caller's trace when its
// headers carry one. Under it, as child spans: every call the HTTP client
// makes -- with the trace sent on in its headers -- every PostgreSQL
// statement, every Redis round trip, and whatever the handler starts itself
// with `withSpan`, since the handler runs with the request's span as its
// `ServiceContext.current`.
//
// Workers are processes, forked from the one that set the application up, and
// an exporter's threads do not survive a fork: the tracer is made in each
// worker, either by the closure given to `tracing` or by bootstrapping the
// `InstrumentationSystem` in `onWorkerStart`, whose hooks run before the
// worker reads it.
//
// What is recorded follows OpenTelemetry's semantic conventions for HTTP and
// database spans. A request's span is named for its method and route pattern
// -- "GET /users/:id", never the path itself, which would make every user a
// name of their own -- and ends when the response has been answered: for a
// streamed response, when its last byte is queued rather than when its head
// is. With tracing off none of this runs: the request path pays one check.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP
import Tracing

extension Application {
    /// Traces requests with the tracer `InstrumentationSystem` holds in each
    /// worker. Bootstrap it in `onWorkerStart`, which runs in the worker
    /// before the tracer is looked for there: bootstrapped before the worker
    /// is forked, an exporter's threads stay behind in the parent.
    public func tracing() {
        tracing { _ in InstrumentationSystem.tracer }
    }

    /// Traces requests with the tracer `make` returns, called once in each
    /// worker, with its index, after its `onWorkerStart` hooks.
    public func tracing(_ make: @escaping (_ worker: Int) -> any Tracer) {
        precondition(compiled == nil, "tracing turned on after the application was compiled")
        makeTracer = make
    }
}

/// A request's server span, kept by slot until the request is answered.
struct RequestSpan {
    let generation: UInt32
    let requestId: UInt32
    let span: any Span
    /// Whether a failure has been said on it, with a message the status the
    /// answer sets must not replace.
    var failed = false
}

/// A request's headers, as a carrier to read a trace from: `Request` itself
/// cannot be one, being noncopyable. Read on the worker's thread, where it
/// is made, and nowhere else.
struct RequestHeaders: @unchecked Sendable {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int
}

/// Reads a trace from a request's headers.
struct RequestHeaderExtractor: Extractor {
    func extract(key: String, from headers: RequestHeaders) -> String? {
        Request(worker: headers.worker, slot: headers.slot).header(key)
    }
}

/// Adds a trace to an outbound request's headers, over any the caller set by
/// the same name.
struct ClientHeaderInjector: Injector {
    func inject(_ value: String, forKey key: String, into headers: inout [(String, String)]) {
        headers.removeAll { $0.0.count == key.count && $0.0.lowercased() == key.lowercased() }
        headers.append((key, value))
    }
}

/// The tracer of the worker this thread runs, if it traces.
@inline(__always)
var workerTracer: (any Tracer)? {
    currentWorker?.pointee.tracer
}

extension Worker {
    /// Looks for the worker's tracer, once its start hooks have run.
    mutating func startTracing(_ index: Int) {
        guard let make = application?.pointee.makeTracer else { return }
        tracer = make(index)
    }

    /// Opens the span of the request just dispatched on `slot`, continuing
    /// the trace its headers carry, if any.
    mutating func startRequestSpan(_ slot: Int) {
        guard let tracer else { return }
        // Left by a request that ended without being answered.
        if requestSpans[slot] != nil { endRequestSpan(slot) }
        let c = table[slot]
        let method = c.pointee.head.methodSlice.span(in: c.pointee.headBase()).string
        var context = ServiceContext.topLevel
        let span: any Span = withUnsafeMutablePointer(to: &self) { worker in
            tracer.extract(RequestHeaders(worker: worker, slot: slot), into: &context,
                           using: RequestHeaderExtractor())
            let span = tracer.startSpan(method, context: context, ofKind: .server)
            guard span.isRecording else { return span }
            let request = Request(worker: worker, slot: slot)
            let version: String
            switch String(describing: worker.pointee.protocolName(slot)) {
            case "HTTP/3": version = "3"
            case "HTTP/2": version = "2"
            case "HTTP/1.0": version = "1.0"
            default: version = "1.1"
            }
            let scheme = String(describing: worker.pointee.requestScheme(slot))
            let address = worker.pointee.requestClient(slot).address.string
            let path = c.pointee.head.path.span(in: c.pointee.headBase()).string
            let agent = request.header("user-agent")
            span.updateAttributes { attributes in
                attributes["http.request.method"] = method
                attributes["url.path"] = path
                attributes["url.scheme"] = scheme
                attributes["network.protocol.name"] = "http"
                attributes["network.protocol.version"] = version
                attributes["client.address"] = address
                if let agent { attributes["user_agent.original"] = agent }
            }
            return span
        }
        requestSpans[slot] = RequestSpan(generation: c.pointee.generation,
                                         requestId: c.pointee.requestId, span: span)
    }

    /// The span of the request on `slot`, if it is the one still there.
    @inline(__always)
    func requestSpan(_ slot: Int) -> (any Span)? {
        // Every request asks, traced or not: untraced, this is the answer,
        // without hashing anything.
        guard !requestSpans.isEmpty, let kept = requestSpans[slot] else { return nil }
        let c = table[slot]
        guard kept.generation == c.pointee.generation, kept.requestId == c.pointee.requestId else { return nil }
        return kept.span
    }

    /// The request on `slot` has its status: named for its route now that
    /// the route is known, and ended unless a streamed body is still to come.
    mutating func requestSpanAnswered(_ slot: Int, status: Int, bodyToCome: Bool) {
        guard let span = requestSpan(slot) else { return }
        let c = table[slot]
        let index = Int(c.pointee.routeIndex)
        var route: String? = nil
        if index >= 0, let patterns = application?.pointee.routePatterns, index < patterns.count {
            route = patterns[index]
        }
        if let route { span.operationName = span.operationName + " " + route }
        if span.isRecording {
            span.updateAttributes { attributes in
                if let route { attributes["http.route"] = route }
                attributes["http.response.status_code"] = status
                // A server's span fails on its own faults only: a 4xx is the
                // client's.
                if status >= 500 { attributes["error.type"] = String(status) }
            }
        }
        if status >= 500 && requestSpans[slot]?.failed != true { span.setStatus(SpanStatus(code: .error)) }
        if !bodyToCome { endRequestSpan(slot) }
    }

    /// Says on the request's span why it failed.
    mutating func requestSpanFailed(_ slot: Int, _ error: (any Error)?, _ description: @autoclosure () -> String) {
        guard let span = requestSpan(slot) else { return }
        if let error { span.recordError(error) }
        span.setStatus(SpanStatus(code: .error, message: description()))
        requestSpans[slot]?.failed = true
    }

    /// Ends the span kept for `slot`, whatever request it was for.
    mutating func endRequestSpan(_ slot: Int) {
        guard let kept = requestSpans.removeValue(forKey: slot) else { return }
        kept.span.end()
    }
}

// MARK: - Outbound spans

/// The span of one outbound call, or nothing when the worker does not trace.
@inline(__always)
func startClientSpan(_ name: String, _ describe: (inout SpanAttributes) -> Void) -> (any Span)? {
    guard let tracer = workerTracer else { return nil }
    let span = tracer.startSpan(name, ofKind: .client)
    if span.isRecording { span.updateAttributes(describe) }
    return span
}

extension Span {
    /// Ends the span for a call that failed.
    func fail(_ error: any Error, type: String) {
        recordError(error)
        attributes["error.type"] = type
        setStatus(SpanStatus(code: .error))
        end()
    }

    /// Ends the span of an HTTP call with the status it was answered with.
    /// To a client, a 4xx is a failure as much as a 5xx is.
    func answered(_ status: Int) {
        if isRecording {
            updateAttributes { attributes in
                attributes["http.response.status_code"] = status
                if status >= 400 { attributes["error.type"] = String(status) }
            }
        }
        if status >= 400 { setStatus(SpanStatus(code: .error)) }
        end()
    }
}

extension ClientError {
    /// The case alone, without what it carries: `error.type` is meant to be
    /// one of a few values, not a message.
    var kind: String {
        String(String(describing: self).prefix { $0 != "(" })
    }
}

/// `url` for a span: without a user and password, and with the query's
/// values taken out -- a token or a signature is often one -- leaving its
/// names.
func redactedURL(_ url: String) -> String {
    var bytes = Array(url.utf8)
    if let scheme = firstIndex(of: Array("://".utf8), in: bytes) {
        let start = scheme + 3
        let end = bytes[start...].firstIndex { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") }
            ?? bytes.count
        if let at = bytes[start..<end].lastIndex(of: UInt8(ascii: "@")) {
            bytes.removeSubrange(start...at)
        }
    }
    if let hash = bytes.firstIndex(of: UInt8(ascii: "#")) { bytes.removeSubrange(hash...) }
    guard let question = bytes.firstIndex(of: UInt8(ascii: "?")) else {
        return String(decoding: bytes, as: UTF8.self)
    }
    var out = Array(bytes[...question])
    var inValue = false
    for byte in bytes[(question + 1)...] {
        if byte == UInt8(ascii: "&") {
            inValue = false
            out.append(byte)
        } else if byte == UInt8(ascii: "=") && !inValue {
            inValue = true
            out.append(contentsOf: Array("=REDACTED".utf8))
        } else if !inValue {
            out.append(byte)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard haystack.count >= needle.count else { return nil }
    for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] {
        if Array(haystack[i..<(i + needle.count)]) == needle { return i }
    }
    return nil
}

/// The span for one PostgreSQL statement: named for what it does -- the
/// statement's first keyword -- with its SQL as written. Values are sent
/// apart from the SQL and never recorded.
func startPostgresSpan(_ sql: String, _ configuration: PostgresConfiguration) -> (any Span)? {
    guard workerTracer != nil else { return nil }
    let operation = sqlOperation(sql)
    return startClientSpan(operation ?? "postgresql") { attributes in
        attributes["db.system.name"] = "postgresql"
        if let operation { attributes["db.operation.name"] = operation }
        attributes["db.query.text"] = sql
        if let database = configuration.database { attributes["db.namespace"] = database }
        attributes["server.address"] = configuration.host
        attributes["server.port"] = Int(configuration.port)
    }
}

extension Span {
    /// Ends the span of a statement that failed, with the SQLSTATE the
    /// server gave when it was the server that refused.
    func fail(_ error: PostgresClientError) {
        if case .postgres(.server(let fields)) = error, !fields.code.isEmpty {
            attributes["db.response.status_code"] = fields.code
            fail(error, type: fields.code)
        } else {
            fail(error, type: String(String(describing: error).prefix { $0 != "(" }))
        }
    }

    /// Ends the span of a Redis round trip that failed, with the error's
    /// code -- WRONGTYPE, MOVED -- when the server gave one.
    func fail(_ error: RedisClientError) {
        if case .server(let refused) = error, !refused.code.isEmpty {
            attributes["db.response.status_code"] = refused.code
            fail(error, type: refused.code)
        } else {
            fail(error, type: String(String(describing: error).prefix { $0 != "(" }))
        }
    }
}

/// The first word of a statement, upper-cased: SELECT, INSERT, WITH, BEGIN.
func sqlOperation(_ sql: String) -> String? {
    var word: [UInt8] = []
    for byte in sql.utf8 {
        let letter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        if letter {
            word.append(byte & 0xDF)
            if word.count > 16 { return nil }
        } else if !word.isEmpty {
            break
        } else if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x28 {
            return nil
        }
    }
    return word.isEmpty ? nil : String(decoding: word, as: UTF8.self)
}

/// The span for one Redis round trip: named for its command, or PIPELINE
/// for several sent together. Arguments -- keys and values alike -- are
/// not recorded.
func startRedisSpan(_ commands: [RedisCommand], _ configuration: RedisConfiguration) -> (any Span)? {
    guard workerTracer != nil, let first = commands.first?.arguments.first else { return nil }
    let name = commands.count == 1 ? String(decoding: first, as: UTF8.self).uppercased() : "PIPELINE"
    return startClientSpan(name) { attributes in
        attributes["db.system.name"] = "redis"
        attributes["db.operation.name"] = name
        if commands.count > 1 { attributes["db.operation.batch.size"] = commands.count }
        attributes["db.namespace"] = String(configuration.database)
        if let path = configuration.unixSocketPath {
            attributes["server.address"] = path
        } else {
            attributes["server.address"] = configuration.host
            attributes["server.port"] = Int(configuration.port)
        }
    }
}
