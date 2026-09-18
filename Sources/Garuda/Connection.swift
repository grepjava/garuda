//===----------------------------------------------------------------------===//
// Connection state and the flat connection table.
//
// Connections live in one contiguous slab indexed by slot number, with a free
// list threaded through the unused slots. No dictionary, no per-connection heap
// object, no ARC: accepting a connection is an index pop, and closing one is an
// index push.
//
// Poller tokens pack (generation, slot) into 64 bits. The generation counter is
// what makes stale events harmless: epoll can hand us an event for a descriptor
// we closed earlier in the same batch, and a generation mismatch discards it
// instead of touching a recycled slot.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP
import AvianQUIC

public enum ConnState: UInt8 {
    case free
    /// Accumulating the request head.
    case readingHead
    /// Head parsed, reading the body into `body`.
    case readingBody
    /// Handed to a handler. Usually over within the same call; a handler that
    /// parks a continuation (AsyncOps.swift) holds the slot here until it is
    /// resumed.
    case dispatching
    /// The HTTP request became a WebSocket; framing is no longer HTTP.
    case websocket
    /// The connection speaks HTTP/2. Requests live in stream slots of their
    /// own; this one owns the socket, the HPACK state and the flow control.
    case http2
    /// The connection speaks HTTP/3 over QUIC. It owns no descriptor at all:
    /// the socket belongs to the listener, and this slot exists so that a QUIC
    /// connection can be a connection like any other.
    case http3
    /// Response bytes are queued and the socket is not yet drained.
    case writing
    /// Everything is written; close once the buffer empties.
    case closing
}

public struct ConnFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    @inlinable public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let keepAlive        = ConnFlags(rawValue: 1 << 0)
    public static let peerClosed       = ConnFlags(rawValue: 1 << 1)
    /// A 100-continue is owed to the client.
    public static let owesContinue     = ConnFlags(rawValue: 1 << 2)
    /// Response framing is chunked rather than Content-Length.
    public static let chunkedResponse  = ConnFlags(rawValue: 1 << 3)
    /// The response head has been queued.
    public static let responseStarted  = ConnFlags(rawValue: 1 << 4)
    /// The application signalled the final body message.
    public static let responseComplete = ConnFlags(rawValue: 1 << 5)
    /// HEAD request: send headers, discard the body.
    public static let suppressBody     = ConnFlags(rawValue: 1 << 6)
    /// The client hung up while the application was still running.
    public static let disconnected     = ConnFlags(rawValue: 1 << 7)
    /// The application has already been told the client disconnected.
    public static let disconnectSent   = ConnFlags(rawValue: 1 << 8)
    /// The last of the request body has been handed to the application.
    public static let bodyDelivered    = ConnFlags(rawValue: 1 << 9)
    /// The peer has been checked against the trusted-proxy list. Checking is
    /// per connection rather than per request: the peer cannot change.
    public static let trustEvaluated   = ConnFlags(rawValue: 1 << 10)
    /// ...and it is on the list, so its forwarded headers are believed.
    public static let trustedPeer      = ConnFlags(rawValue: 1 << 11)
    /// The request was a WebSocket upgrade, so the application exchanges
    /// WebSocket messages on it rather than an HTTP request and response. Set
    /// before the handshake is answered, which is why it is separate from
    /// `.websocket`.
    public static let websocketMode    = ConnFlags(rawValue: 1 << 12)
    /// HTTP/2: the END_STREAM flag has been sent, so the response is over on
    /// the wire even if the slot is still waiting for its task.
    public static let endStreamSent    = ConnFlags(rawValue: 1 << 13)
    /// The TLS handshake has not finished, so there is no request yet.
    public static let tlsHandshake     = ConnFlags(rawValue: 1 << 14)
    /// ALPN settled on HTTP/2, so this connection owes us a preface.
    public static let alpnH2           = ConnFlags(rawValue: 1 << 15)
    /// This slot is one request stream of an HTTP/3 connection rather than of
    /// an HTTP/2 one. Both are streams; almost nothing else about them is the
    /// same, so the two are told apart here rather than by looking upward.
    public static let http3Stream      = ConnFlags(rawValue: 1 << 16)

    /// This slot is an accepted-or-pending WebTransport session rather than a
    /// request: its extended CONNECT stream carries capsules, and the streams
    /// and datagrams that belong to it are routed here.
    public static let webtransportMode = ConnFlags(rawValue: 1 << 17)

    /// A request has completed on this connection, so it is idle between
    /// requests rather than newly accepted.
    ///
    /// `isIdle` cannot tell those apart -- both are `readingHead` with an empty
    /// buffer -- and a drain treats them very differently. Closing a keep-alive
    /// connection between requests is correct and expected. Closing one that
    /// has never served anything drops a request the client has already put on
    /// the wire, which it sees as a truncated response rather than as a hint to
    /// open a new connection.
    public static let servedRequest    = ConnFlags(rawValue: 1 << 18)

    /// A finished response is waiting in the write buffer for the end of this
    /// event batch, when it goes out with every other response the batch
    /// produced. See `Worker.flushSoon`.
    public static let flushQueued      = ConnFlags(rawValue: 1 << 19)

    /// --cache-size: the request changes its target -- any method but GET,
    /// HEAD, OPTIONS, TRACE and CONNECT -- and a successful response retires
    /// what is cached for it. `Connection.cacheMark` says which target.
    public static let invalidatesCache = ConnFlags(rawValue: 1 << 20)

    /// The request passed its route's deadline and has been answered 504.
    ///
    /// A deadline can fire while the handler is running, which nothing can
    /// preempt, so the handler goes on and may still try to answer. This says
    /// it no longer holds the request: its sends and headers are dropped in
    /// silence rather than logged as answering twice, and `isCancelled` tells
    /// it so if it asks.
    public static let timedOut         = ConnFlags(rawValue: 1 << 21)
    /// The head is sent and the body is still being written by the handler
    /// (`Response.stream`). `responseComplete` joins it when the body ends.
    public static let streamingResponse = ConnFlags(rawValue: 1 << 22)
    /// The request's route reads its body as it arrives (`onStreamingBody`),
    /// so it was dispatched at its head and the body is still coming.
    public static let bodyStreaming = ConnFlags(rawValue: 1 << 23)

    /// Everything that describes one request rather than the connection.
    /// Cleared when a keep-alive connection starts its next request; missing
    /// one of these here would leak state across a pipelined request.
    public static let perRequest: ConnFlags = [
        .owesContinue, .chunkedResponse, .responseStarted, .responseComplete,
        .suppressBody, .disconnected, .disconnectSent, .bodyDelivered,
        .endStreamSent, .invalidatesCache, .timedOut, .streamingResponse, .bodyStreaming,
    ]
}

public struct Connection {
    public var fd: Int32 = -1
    /// An open file whose remaining bytes are the rest of this response, or -1.
    ///
    /// Set by a `--static-dir` route. The bytes never enter the process on the
    /// plaintext path: `flush` hands the descriptor to sendfile(2) and the
    /// kernel moves them. Over TLS, and on a multiplexed stream, they have to
    /// be read and framed, so the same fields drive a read-and-buffer loop.
    public var fileFD: Int32 = -1
    public var fileOffset: Int = 0
    public var fileRemaining: Int = 0

    public var generation: UInt32 = 0
    /// Identity of the current request on this connection. Bumped at
    /// `beginRequest`, not at allocate: keep-alive reuses the slot and its
    /// connection generation, so a timer armed for request A must not resume
    /// request B. See AsyncOps.swift.
    public var requestId: UInt32 = 0
    /// Handler parked waiting for an op (timer, later I/O).
    public var contState: ContState = .none
    public var contKind: ContKind = .none
    /// Head op in the worker's pool, or -1.
    public var contOp: Int32 = -1
    /// Generation of `contOp` when it was armed, so a recycled op is not freed
    /// through a handle that outlived it.
    public var contOpGeneration: UInt32 = 0
    /// Ticket of the ready-queue entry that may resume this continuation.
    public var contTicket: UInt32 = 0
    /// The handler a `.handler` continuation calls when it resumes, or nil.
    /// Set only while `contKind` is `.handler`, which is how releasing it
    /// stays off the path of requests that never wait.
    public var contHandler: Handler? = nil
    /// While `contKind` is `.task`: the number of the task running the
    /// request in the worker's pool, or -1 while it waits for one.
    var contTask: Int32 = -1
    /// The async handler a request queued for a task will run.
    var contAsyncHandler: AsyncHandler? = nil
    /// The request's deadline op in the worker's pool, or -1. A deadline
    /// cannot share `contOp`: it has to outlast the waits a handler makes for
    /// itself, and `armTimer` overwrites `contOp` on every one of them, which
    /// would orphan the deadline where `cancelOps` could never free it.
    var deadlineOp: Int32 = -1
    /// Generation of `deadlineOp` when it was armed, so a recycled op is not
    /// freed through a handle that outlived it.
    var deadlineOpGeneration: UInt32 = 0

    /// Parked on something other than a handler running now, so no handler
    /// may answer it. A request on a task is answered by that task, from
    /// whichever wait it resumes, so it does not count.
    var isParked: Bool { contState == .waiting && contKind != .task }

    /// Forgets every field a continuation uses, for a slot being made ready
    /// to carry a fresh request.
    ///
    /// This only forgets a continuation; cancelling a live one, which has an
    /// op to unlink and a task to unwind, is `cancelOps`. HTTP/2 and HTTP/3
    /// make a stream slot ready by hand rather than through `beginRequest`,
    /// so a field added to a continuation is missed by both unless it is
    /// added here.
    mutating func resetContinuation() {
        contState = .none
        contKind = .none
        contOp = -1
        contHandler = nil
        contTask = -1
        contAsyncHandler = nil
        // Only the handle. Both callers take a slot fresh from the free list,
        // whose deadline op was freed when its last occupant closed; freeing
        // the op itself is `disarmDeadline`, at the request boundaries.
        deadlineOp = -1
        deadlineOpGeneration = 0
    }
    /// The request's typed context, made when a handler first stores a value.
    var context: RequestContext? = nil
    /// The status `Response.send` uses when it is not given one.
    public var handlerStatus: UInt16 = 200
    /// The route's parameters, and where the routed path starts relative to
    /// the head, so a resumed handler can read them again.
    public var routeParameters = RouteParameters()
    public var routeOffset: Int32 = 0
    /// The route number that answered, for `onResponse`; -1 for none.
    var routeIndex: Int32 = -1
    /// Headers the handler added. See `forEachHeaderRecord`.
    public var responseHeaders = ByteBuffer()
    public var state: ConnState = .free
    public var flags: ConnFlags = []
    /// Poller mask currently registered, so we only issue epoll_ctl on change.
    public var interest: UInt32 = 0

    public var read = ByteBuffer()
    public var write = ByteBuffer()
    /// Request body, buffered whole before the request is dispatched.
    public var body = ByteBuffer()

    public var head = HTTPRequestHead()
    /// Where the request head starts. Slices in `head` are relative to this.
    ///
    /// The head bytes have to stay readable until the request has been
    /// answered, which for a parked handler can be several loop turns later.
    /// Two rules keep them alive without copying:
    ///   * a Content-Length body is read straight into `body`, so nothing ever
    ///     writes over the head still sitting in `read`;
    ///   * a chunked body needs `read` for its framing, so there and only there
    ///     the head is copied into `headStore` first.
    public var headOrigin: Int = 0
    public var headInStore = false
    public var headStore = ByteBuffer()

    public var chunked = ChunkedDecoder()
    /// Remaining Content-Length bytes, or -1 while chunked.
    public var bodyRemaining: Int = 0

    public var lastActivity: UInt64 = 0
    public var requestCount: UInt32 = 0
    /// Monotonic microseconds at the moment this request was dispatched, for
    /// the access log's duration. Only read when --access-log is on, and only
    /// written then either: a clock read per request is small but it is not
    /// nothing, and nobody should pay for a log they are not keeping.
    public var requestStartUs: UInt64 = 0
    /// Wall-clock microseconds at which this request's first byte arrived, for
    /// --request-start-header: the kernel's receive timestamp on plaintext, the
    /// first read otherwise. Written only with the flag on.
    public var headStartUs: UInt64 = 0

    /// The TLS session, when this connection has one. Streams never do: they
    /// travel over their connection.
    public var tls: OpaquePointer? = nil

    // --- HTTP/2 ---
    /// Connection state, on the slot that owns the socket.
    public var h2: H2Connection? = nil
    /// The slot owning the socket, when this slot is a stream; -1 otherwise.
    public var parentSlot: Int32 = -1
    public var streamID: UInt32 = 0
    /// Flow control, in bytes. `send` is what the peer will accept from us,
    /// `recv` what we have told the peer it may send.
    public var sendWindow: Int = 0
    public var recvWindow: Int = 0
    public var pendingRecvUpdate: Int = 0
    /// Body bytes received, for checking a declared Content-Length against
    /// what actually arrived.
    public var bodyReceived: Int = 0
    /// The `:scheme` the client asked for was https.
    public var h2Scheme = false

    // --- HTTP/3 ---
    /// Connection state, on the slot that owns the QUIC connection.
    public var h3: H3Connection? = nil
    /// The QUIC connection this slot owns, when it owns one.
    public var quicRef: QUICConnection? = nil
    /// The QUIC stream identifier, when this slot is an HTTP/3 request.
    /// Separate from `streamID` because QUIC's are 62-bit.
    public var qstreamID: UInt64 = 0
    /// The frame being read on a request stream, and what is left of it.
    public var h3FrameType: UInt64 = 0
    public var h3FrameRemaining: Int = 0
    /// The `:protocol` of an extended CONNECT, which is how WebTransport and
    /// WebSocket-over-HTTP/3 announce themselves.
    public var connectProtocol = ByteBuffer()
    /// The WebTransport session this extended CONNECT became, if it became one.
    var wt: WTSession? = nil
    /// The handlers waiting for a streamed response's backlog to drain, each
    /// resumed with true when it has and false when the request ends first.
    ///
    /// A list rather than one, because concurrent producers are part of the
    /// API: if the second one to find the backlog full were let through, the
    /// mark would bound the first writer and nothing else.
    var writerWakes: [UnsafeContinuation<Bool, Never>] = []
    /// Handlers waiting for this request to end so that they can give up on
    /// a wait the engine does not own (Cancellation.swift).
    var cancelWaiters: [CancelWaiter] = []
    /// The body a streaming route is reading as it arrives, shared with its
    /// reader so what arrived survives the slot closing.
    var bodyStream: RequestBodyState? = nil
    /// The most body this request may send: `--max-body`, or its route's own
    /// limit when the route streams its body.
    var bodyLimit: Int = 0
    /// How much of an HTTP/2 streaming body has been given back to the
    /// stream's window.
    var bodyNoted: Int = 0

    /// True when this slot is one stream of a multiplexed connection rather
    /// than a connection in its own right.
    @inlinable public var isStream: Bool { parentSlot >= 0 }
    /// ...and which kind, which decides how a response is framed.
    @inlinable public var isH3Stream: Bool { flags.contains(.http3Stream) }

    /// Peer address bytes, filled at accept.
    public var remoteAddr = ByteBuffer()
    public var remotePort: UInt16 = 0
    /// Declared Content-Length of the response, or -1 for chunked.
    public var responseRemaining: Int = -1

    /// The coding this request's client accepts best among those the server
    /// can produce, settled at dispatch. Whether the response actually uses it
    /// is up to the response's own headers.
    public var acceptedCoding: ContentCoding = .identity
    /// --request-id: this request's ID, settled at dispatch, and whether it is
    /// the one a trusted proxy sent -- in which case the application already
    /// has it among the request headers and nothing needs replacing.
    public var requestID = ByteBuffer()
    public var requestIDKept = false
    /// --trace-context: the trace ID and parent span ID of a valid W3C
    /// traceparent, 48 hex characters in that order, or empty. Settled at
    /// dispatch.
    public var traceContext = ByteBuffer()
    /// --cache-size: the key this request's response would be stored under,
    /// and the response as it is copied.
    public var cacheKey = ByteBuffer()
    public var capture = ResponseCapture()
    /// The hash of the target of a request that changes it, which a
    /// successful response invalidates. See `ConnFlags.invalidatesCache`.
    public var cacheMark: UInt64 = 0
    /// The compressor for a response body being compressed.
    public var encoder = ResponseEncoder()

    /// WebSocket framing state; meaningful only in `.websocket` mode.
    public var ws = WebSocketState()

    /// Free-list link; -1 when in use.
    public var nextFree: Int32 = -1

    /// An event stream's keep-alive: how long it may go without a write before
    /// a comment is sent, 0 for never, and when the next is due. At the end,
    /// clear of the fields every request touches.
    var eventKeepAliveMs: UInt32 = 0
    var eventKeepAliveDue: UInt64 = 0
    /// A WebSocket on a stream: bytes received and not yet credited back to
    /// the peer, held while the handler's queue is full.
    var wsUncredited: Int = 0

    @inlinable public init() {}

    @inlinable
    public var isIdle: Bool { state == .readingHead && read.isEmpty }

    /// Base pointer the current `head` slices are relative to.
    @inlinable
    public mutating func headBase() -> UnsafePointer<UInt8> {
        headInStore ? UnsafePointer(headStore.pointer(at: 0))
                    : UnsafePointer(read.pointer(at: headOrigin))
    }
}

/// Reserved poller tokens. Real connections use `(generation << 24) | slot`,
/// and slots are bounded well below 2^24.
public enum PollToken {
    public static let listener: UInt64 = .max
    public static let signals: UInt64 = .max - 1
    /// The QUIC socket. One descriptor serves every QUIC connection, so unlike
    /// TCP there is no per-connection token.
    public static let quic: UInt64 = .max - 3
    /// The metrics listener, when one is bound.
    public static let metrics: UInt64 = .max - 4
    /// The --redirect-http listener, when one is bound.
    public static let redirect: UInt64 = .max - 5
    /// The read end of the blocking pool's pipe, when the pool has started.
    public static let blocking: UInt64 = .max - 6
    /// The broadcast ring's wake descriptor, once something has subscribed.
    public static let broadcast: UInt64 = .max - 7
    /// Scrapes and redirects whose request has not finished arriving. One token
    /// per pending slot, so an event names its slot without a search. Kept
    /// clear of the singletons above and far below any slot token.
    public static let metricsPendingCount = 8
    public static let metricsPendingBase: UInt64 = .max - 16

    @inlinable
    public static func metricsPending(_ index: Int) -> UInt64 {
        metricsPendingBase &+ UInt64(index)
    }

    @inlinable
    public static func metricsPendingIndex(_ token: UInt64) -> Int? {
        guard token >= metricsPendingBase,
              token < metricsPendingBase &+ UInt64(metricsPendingCount) else { return nil }
        return Int(token &- metricsPendingBase)
    }

    /// Marks a token as an outbound connection's rather than a slot's.
    ///
    /// A slot token is a `UInt32` generation shifted up 24, so it never
    /// reaches 2^56; the singletons above sit at `.max - n`. Bit 62 is free of
    /// both, so it tells the two namespaces apart without touching either.
    public static let outboundBit: UInt64 = 1 << 62

    @inlinable
    public static func outbound(index: Int, generation: UInt32) -> UInt64 {
        outboundBit | (UInt64(generation) << slotBits) | UInt64(index)
    }

    @inlinable
    public static func isOutbound(_ token: UInt64) -> Bool {
        token & outboundBit != 0
    }

    public static let slotBits: UInt64 = 24
    public static let slotMask: UInt64 = (1 << 24) - 1

    @inlinable
    public static func make(slot: Int, generation: UInt32) -> UInt64 {
        (UInt64(generation) << slotBits) | UInt64(slot)
    }

    @inlinable
    public static func slot(_ token: UInt64) -> Int { Int(token & slotMask) }

    @inlinable
    public static func generation(_ token: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: token >> slotBits)
    }
}

/// Fixed-capacity slab of connections with an embedded free list.
public struct ConnectionTable {
    @usableFromInline var slots: UnsafeMutablePointer<Connection>
    public let capacity: Int
    @usableFromInline var firstFree: Int32
    public private(set) var liveCount: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0 && capacity < (1 << 24), "connection table out of range")
        self.capacity = capacity
        slots = UnsafeMutablePointer<Connection>.allocate(capacity: capacity)
        slots.initialize(repeating: Connection(), count: capacity)
        // Thread the free list: slot i points at i+1, last points at -1.
        var i = 0
        while i < capacity {
            slots[i].nextFree = Int32(i + 1 < capacity ? i + 1 : -1)
            i += 1
        }
        firstFree = 0
    }

    @inlinable
    public subscript(slot: Int) -> UnsafeMutablePointer<Connection> {
        slots + slot
    }

    /// Claims a slot, or -1 when the table is full (which the caller turns into
    /// a 503 rather than an unbounded queue).
    public mutating func allocate() -> Int {
        let slot = Int(firstFree)
        if slot < 0 { return -1 }
        firstFree = slots[slot].nextFree
        slots[slot].nextFree = -1
        slots[slot].generation &+= 1
        liveCount += 1
        return slot
    }

    public mutating func release(_ slot: Int) {
        slots[slot].nextFree = firstFree
        slots[slot].state = .free
        firstFree = Int32(slot)
        liveCount -= 1
    }

    public func destroy() {
        slots.deallocate()
    }
}
