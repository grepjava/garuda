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

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

public enum ConnState: UInt8 {
    case free
    /// Accumulating the request head.
    case readingHead
    /// Head parsed, streaming the body (WSGI buffers it, ASGI forwards it).
    case readingBody
    /// Handed to the application; for ASGI this can last many event loop turns,
    /// and for a pooled WSGI request it lasts until a thread reports back.
    case dispatching
    /// The HTTP request became a WebSocket; framing is no longer HTTP.
    case websocket
    /// The connection speaks HTTP/2. Requests live in stream slots of their
    /// own; this one owns the socket, the HPACK state and the flow control.
    case http2
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
    /// An ASGI disconnect message has already been delivered.
    public static let disconnectSent   = ConnFlags(rawValue: 1 << 8)
    /// The final http.request message has been handed to the application.
    public static let bodyDelivered    = ConnFlags(rawValue: 1 << 9)
    /// The peer has been checked against the trusted-proxy list. Checking is
    /// per connection rather than per request: the peer cannot change.
    public static let trustEvaluated   = ConnFlags(rawValue: 1 << 10)
    /// ...and it is on the list, so its forwarded headers are believed.
    public static let trustedPeer      = ConnFlags(rawValue: 1 << 11)
    /// The request was a WebSocket upgrade, so `receive` and `send` speak the
    /// websocket half of ASGI rather than the http half. Set before the
    /// handshake is answered, which is why it is separate from `.websocket`.
    public static let websocketMode    = ConnFlags(rawValue: 1 << 12)
    /// HTTP/2: the END_STREAM flag has been sent, so the response is over on
    /// the wire even if the slot is still waiting for its task.
    public static let endStreamSent    = ConnFlags(rawValue: 1 << 13)
    /// The TLS handshake has not finished, so there is no request yet.
    public static let tlsHandshake     = ConnFlags(rawValue: 1 << 14)
    /// ALPN settled on HTTP/2, so this connection owes us a preface.
    public static let alpnH2           = ConnFlags(rawValue: 1 << 15)

    /// Everything that describes one request rather than the connection.
    /// Cleared when a keep-alive connection starts its next request; missing
    /// one of these here would leak state across a pipelined request.
    public static let perRequest: ConnFlags = [
        .owesContinue, .chunkedResponse, .responseStarted, .responseComplete,
        .suppressBody, .disconnected, .disconnectSent, .bodyDelivered,
        .endStreamSent,
    ]
}

public struct Connection {
    public var fd: Int32 = -1
    public var generation: UInt32 = 0
    public var state: ConnState = .free
    public var flags: ConnFlags = []
    /// Poller mask currently registered, so we only issue epoll_ctl on change.
    public var interest: UInt32 = 0

    public var read = ByteBuffer()
    public var write = ByteBuffer()
    /// Request body: buffered whole for WSGI, staged per chunk for ASGI.
    public var body = ByteBuffer()

    public var head = HTTPRequestHead()
    /// Where the request head starts. Slices in `head` are relative to this.
    ///
    /// The head bytes have to stay readable until the application has built its
    /// environ or scope, which can be several event-loop turns later. Two rules
    /// keep them alive without copying:
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

    /// True when this slot is one stream of an HTTP/2 connection rather than
    /// a connection in its own right.
    @inlinable public var isStream: Bool { parentSlot >= 0 }

    /// Cached per-connection Python values so a keep-alive connection builds
    /// its client address once rather than per request.
    public var remoteAddrObj: PyObj? = nil
    public var remotePortObj: PyObj? = nil
    public var clientTuple: PyObj? = nil

    // --- ASGI request state ---
    /// The running asyncio Task, if any.
    public var task: PyObj? = nil
    /// A Future handed to the application from `receive()` and not yet resolved.
    public var pendingReceive: PyObj? = nil
    /// Owned `send` / `receive` callables, released when the request ends.
    public var sendCallable: PyObj? = nil
    public var receiveCallable: PyObj? = nil
    /// A Future handed to the application from `send()` while the write buffer
    /// is over the high water mark, resolved once it drains back below the low
    /// one. This is the whole of ASGI write backpressure: without it a fast
    /// producer keeps appending to a buffer the socket is not draining.
    public var drainWaiter: PyObj? = nil
    /// Declared Content-Length of the response, or -1 for chunked.
    public var responseRemaining: Int = -1

    /// WebSocket framing state; meaningful only in `.websocket` mode.
    public var ws = WebSocketState()

    /// The pooled WSGI request running for this connection, if any. Held
    /// strongly: the job outlives the connection when a client disconnects
    /// mid-request, and the thread still needs it to unwind.
    public var poolJob: WSGIJob? = nil

    /// Free-list link; -1 when in use.
    public var nextFree: Int32 = -1

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
    /// The WSGI pool completion pipe, when a thread pool is running.
    public static let pool: UInt64 = .max - 2
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
