//===----------------------------------------------------------------------===//
// Traces, through swift-distributed-tracing.
//
//     app.onShardStart { _ in InstrumentationSystem.bootstrap(makeTracer()) }
//     app.tracing()
//
// Each request is a server span, continued from the caller's trace when its
// headers carry one. Under it, as child spans: every call the HTTP client
// makes -- with the trace sent on in its headers -- every PostgreSQL
// statement, every Redis round trip, and whatever the handler starts itself
// with `withSpan`, since the handler runs with the request's span as its
// `ServiceContext.current`.
//
// Shards are processes, forked from the one that set the application up, and
// an exporter's threads do not survive a fork: the tracer is made in each
// shard, either by the closure given to `tracing` or by bootstrapping the
// `InstrumentationSystem` in `onShardStart`, whose hooks run before the
// shard looks for it.
//
// What is recorded follows OpenTelemetry's semantic conventions for HTTP and
// database spans. A request's span is named for its method and route pattern
// -- "GET /users/:id", never the path itself, which would make every user a
// name of their own -- and ends when the response has been answered: for a
// streamed response, when its last byte is queued rather than when its head
// is. With tracing off none of this runs: the request path pays one check.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import Tracing
import VegaDBTracing

extension Application {
    /// Traces requests with the tracer `InstrumentationSystem` holds in each
    /// shard. Bootstrap it in `onShardStart`, which runs in the shard before
    /// the tracer is looked for there: bootstrapped before the shards are
    /// forked, an exporter's threads stay behind in the parent.
    public func tracing() {
        tracing { _ in InstrumentationSystem.tracer }
    }

    /// Traces requests with the tracer `make` returns, called once in each
    /// shard, with its index, after its `onShardStart` hooks.
    public func tracing(_ make: @escaping @Sendable (_ shard: Int) -> any Tracer) {
        precondition(compiledApplication == nil, "tracing turned on after the application was compiled")
        makeTracer = make
    }
}

/// The tracer a request's handler, and whatever it calls, traces with: in
/// its context, so that two applications in one process -- tests -- each
/// keep their own.
enum ShardTracerKey: ServiceContextKey {
    typealias Value = any Tracer
}

/// The shard's tracer, for a call made outside any request: a background
/// job, a start hook. Set once the shard has made it.
enum ShardTracer {
    private static let installed = Mutex<(any Tracer)?>(nil)

    static func install(_ tracer: (any Tracer)?) {
        installed.withLock { $0 = tracer }
    }

    /// The tracer to trace an outbound call with: the request's, or the
    /// shard's. Nil when nothing traces.
    static var current: (any Tracer)? {
        if let tracer = ServiceContext.current?[ShardTracerKey.self] { return tracer }
        return installed.withLock { $0 }
    }
}

extension CompiledApplication {
    /// Before the shard's state is built, so a database configuration made
    /// there is traced too (`DatabaseTracing.installed`).
    func startTracing() {
        guard makeTracer != nil else { return }
        DatabaseTracing.installed = ShardDatabaseTracer()
    }

    /// After the start hooks, which may have bootstrapped the tracer.
    func makeShardTracer(_ shard: ShardInfo) {
        guard let makeTracer else { return }
        let made = makeTracer(shard.index)
        tracer = made
        ShardTracer.install(made)
    }
}

// MARK: - Request spans

/// A request's server span, as the exchange holds it: a file that imports
/// Tracing cannot also name the standard library's `Span<UInt8>`, which
/// Exchange.swift does, so it names this instead.
struct RequestSpan {
    let span: any Tracing.Span

    func recordError(_ error: any Error) { span.recordError(error) }
    func end() { span.end() }
}

/// A request's headers, as a carrier to read a trace from: `Request` itself
/// cannot be one, being noncopyable. Read in the request's own task.
struct RequestHeaders: @unchecked Sendable {
    let x: UnsafeMutablePointer<Exchange>
}

/// Reads a trace from a request's headers.
struct RequestHeaderExtractor: Extractor {
    func extract(key: String, from headers: RequestHeaders) -> String? {
        Request(headers.x).header(key)
    }
}

/// Runs the request in `x` inside its server span, continuing the trace its
/// headers carry, if any. The span is ended by `endRequestSpan` once the
/// request has been answered.
@inline(never)
func tracedDispatch(_ x: UnsafeMutablePointer<Exchange>, _ app: CompiledApplication, _ tracer: any Tracer,
                    matched: Int32, observing: Bool) async {
    let head = x.pointee.head
    let method = x.pointee.slice(head.methodSlice).string
    var context = ServiceContext.topLevel
    tracer.extract(RequestHeaders(x: x), into: &context, using: RequestHeaderExtractor())
    context[ShardTracerKey.self] = tracer
    let span = tracer.startSpan(method, context: context, ofKind: .server)
    if span.isRecording {
        let request = Request(x)
        let version: String
        switch protocolName(head, headParsed: true) {
        case "HTTP/2": version = "2"
        case "HTTP/1.0": version = "1.0"
        default: version = "1.1"
        }
        let path = x.pointee.slice(head.path).string
        let scheme = request.arrivedOverHTTPS ? "https" : "http"
        let address = request.remoteAddress
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
    }
    // One left by a request that ended without being answered.
    x.pointee.span?.end()
    x.pointee.span = RequestSpan(span: span)
    await ServiceContext.withValue(span.context) {
        await dispatchRouted(x, app, matched: matched, observing: observing)
    }
}

/// The request in `x` has been answered with `status`: its span is named for
/// its route now that the route is known, and ended.
func endRequestSpan(_ x: UnsafeMutablePointer<Exchange>, _ app: CompiledApplication, status: Int) {
    guard let span = x.pointee.span?.span else { return }
    x.pointee.span = nil
    let index = Int(x.pointee.route)
    let route: String? = index >= 0 && index < app.patterns.count ? app.patterns[index] : nil
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
    if let failure = x.pointee.failure {
        span.setStatus(SpanStatus(code: .error, message: failure))
    } else if status >= 500 {
        span.setStatus(SpanStatus(code: .error))
    }
    span.end()
}

// MARK: - Outbound spans

/// The span of one outbound call, under the current one, or nothing when
/// nothing traces.
func startClientSpan(_ name: String, _ describe: (inout SpanAttributes) -> Void) -> (any Tracing.Span)? {
    guard let tracer = ShardTracer.current else { return nil }
    let span = tracer.startSpan(name, context: ServiceContext.current ?? .topLevel, ofKind: .client)
    if span.isRecording { span.updateAttributes(describe) }
    return span
}

/// Adds a trace to an outbound request's headers, over any the caller set by
/// the same name.
struct ClientHeaderInjector: Injector {
    func inject(_ value: String, forKey key: String, into headers: inout [(String, String)]) {
        headers.removeAll { $0.0.count == key.count && $0.0.lowercased() == key.lowercased() }
        headers.append((key, value))
    }
}

extension Tracing.Span {
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

// MARK: - Database spans

/// What vega-db's clients tell about each round trip, as spans on the
/// shard's tracer under the current span: installed as
/// `DatabaseTracing.installed` in a shard that traces.
struct ShardDatabaseTracer: DatabaseTracer {
    func start(_ describe: () -> DatabaseOperation) -> (any DatabaseSpan)? {
        guard let tracer = ShardTracer.current else { return nil }
        let operation = describe()
        let span = tracer.startSpan(operation.name, context: ServiceContext.current ?? .topLevel, ofKind: .client)
        if span.isRecording {
            span.updateAttributes { attributes in
                attributes["db.system.name"] = operation.system
                if let name = operation.operation { attributes["db.operation.name"] = name }
                if let text = operation.queryText { attributes["db.query.text"] = text }
                if let size = operation.batchSize { attributes["db.operation.batch.size"] = size }
                if let namespace = operation.namespace { attributes["db.namespace"] = namespace }
                if let address = operation.serverAddress { attributes["server.address"] = address }
                if let port = operation.serverPort { attributes["server.port"] = port }
            }
        }
        return TracedRoundTrip(span: span)
    }
}

struct TracedRoundTrip: DatabaseSpan {
    let span: any Tracing.Span

    func end() { span.end() }

    func fail(_ failure: DatabaseFailure) {
        if let code = failure.statusCode { span.attributes["db.response.status_code"] = code }
        span.fail(failure.error, type: failure.type)
    }
}
