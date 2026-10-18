//===----------------------------------------------------------------------===//
// HTTP/3 (RFC 9114) over QUIC: the UDP endpoint.
//
// QUIC is nothing like the TCP path. There is no accept: a datagram arrives,
// its destination connection ID is looked up, and either it belongs to a
// connection or it is the first packet of a new one. Ordering, loss recovery
// and congestion control all happen inside `QUICConnectionState` (VegaQUIC),
// which does no I/O of its own: it is handed datagrams and asked for them.
//
// Each shard binds a UDP socket per thread with SO_REUSEPORT, so the kernel
// hashes clients across them by four-tuple and a client's packets keep
// reaching the same socket. A client that genuinely migrates may be hashed to
// a socket that has never heard of its connection; it recovers by making a new
// one.
//
// A socket has one ENDPOINT task, and the endpoint owns everything QUIC for
// it: the table from connection ID to connection, every `QUICConnectionState`, and
// the HTTP/3 state on top (HTTP3Connection.swift). Nothing else touches any of
// it, so none of it is locked. Its loop: receive a batch of datagrams, waiting
// no longer than the earliest QUIC timer; feed each to its connection (or
// accept, or answer with version negotiation); handle what the connections
// report; run the timers that are due; take what the request tasks posted;
// and send everything the connections have to say, one connection's datagrams
// coalesced into one segmented send (UDP GSO) where the kernel allows.
//
// Requests run as tasks from the shard's stream pool, as HTTP/2 streams do,
// and never touch a `QUICConnectionState`. A task hands its answer to the endpoint
// by posting its stream (HTTP3Stream.swift) under the endpoint's lock and
// firing the endpoint's wake-up trigger, which ends the endpoint's wait on
// the socket early. The endpoint moves what was posted onto the QUIC stream as
// far as the stream's send budget allows, and the rest as acknowledgements
// free room.
//
// Except when nothing could be held up for long: a request to a route that
// has run many times without ever suspending, and is not heavy, is answered
// by the endpoint itself once the datagrams in hand are handled, as an HTTP/2
// connection's only stream is by its reader. It saves the hand-off to a task
// and the wake-up back, which cost more than such a route does. One run that
// does suspend sends the route to the pool for good.
//
// Shutdown sends every connection GOAWAY on its control stream, refuses new
// requests, and closes each connection with H3_NO_ERROR once its requests are
// answered -- or when the grace period runs out.
//===----------------------------------------------------------------------===//

@_spi(Garuda) import VegaQUICCore
import GarudaWire
import Synchronization
import Vega
import VegaCrypto

/// HTTP/3's settings and limits, worked out once from the config.
struct HTTP3Limits: Sendable {
    var enabled: Bool
    /// Requests a client may have open at once on a connection: QUIC's
    /// initial_max_streams_bidi.
    var maxStreams: Int
    /// The receive window of a request stream, and an eighth of the
    /// connection's.
    var streamWindow: Int
    /// SETTINGS_MAX_FIELD_SECTION_SIZE, and the most a header block may be.
    var maxHeadSize: Int
    /// How many cancellations a connection may run up beyond the requests it
    /// has had answered (the rapid-reset defence).
    var resetBudget: Int
    var maxConnections: Int
    var idleTimeoutMs: UInt64
    var bodyTimeoutMs: UInt64
    /// What one stream may have queued on its QUIC stream, sent or not yet
    /// acknowledged, before more of its answer is moved there.
    var sendBudget: Int
    /// A streamed body's writes wait while more than `high` of it is staged,
    /// until it is down to `low`.
    var high: Int
    var low: Int

    init(_ config: ServerConfig) {
        enabled = config.http3Enabled
        maxStreams = max(1, config.h2MaxConcurrentStreams)
        streamWindow = max(16 * 1024, config.h2InitialWindowSize)
        maxHeadSize = config.maxHeadSize
        resetBudget = max(100, maxStreams * 2)
        maxConnections = max(1, config.maxQUICConnections)
        idleTimeoutMs = milliseconds(config.keepAliveTimeout)
        bodyTimeoutMs = milliseconds(config.bodyTimeout)
        high = max(1, config.writeHighWaterMark)
        low = min(max(0, config.writeLowWaterMark), high)
        sendBudget = max(64 * 1024, high)
    }
}

func milliseconds(_ duration: Duration) -> UInt64 {
    let (seconds, attoseconds) = duration.components
    return UInt64(clamping: seconds) &* 1000 &+ UInt64(clamping: attoseconds / 1_000_000_000_000_000)
}

/// Milliseconds on the monotonic clock: QUIC's timers' unit.
@inline(__always)
func quicNowMs() -> UInt64 { monotonicNanos() / 1_000_000 }

/// "h3": the one ALPN protocol QUIC is offered with.
let h3ALPN: [UInt8] = Array("h3".utf8)

// MARK: - The shard's HTTP/3

/// A shard's HTTP/3: its UDP sockets, an endpoint task for each, and the pool
/// their requests run in.
final class HTTP3Service: @unchecked Sendable {
    let runtime: Runtime
    let app: CompiledApplication
    let limits: ConnectionLimits
    let pool: StreamPool
    /// The certificates the handshakes choose among, by SNI.
    let certificates: @Sendable () -> [CertificateKey]
    private let lock = Mutex<(endpoints: [QUICEndpoint], tasks: [Task<Void, Never>])>(([], []))

    init(runtime: Runtime, app: CompiledApplication, limits: ConnectionLimits,
         certificates: @escaping @Sendable () -> [CertificateKey]) {
        self.runtime = runtime
        self.app = app
        self.limits = limits
        self.certificates = certificates
        pool = StreamPool(runtime: runtime, maxTasks: max(1024, runtime.workerCount * 256))
    }

    /// Binds `count` sockets to `host`:`port` and starts an endpoint on each.
    /// Returns the port, which is `port` unless that was 0. From a task on
    /// the runtime.
    @discardableResult
    func start(host: String, port: Int, count: Int) throws(IOError) -> Int {
        var bound = port
        #if os(Windows)
        // No SO_REUSEPORT: a second socket on the port would fail to bind.
        let count = 1
        #endif
        for _ in 0..<max(1, count) {
            let socket = try UDPSocket.bind(host: host, port: bound, reusePort: true)
            if bound == 0 { bound = (try socket.localAddress).port ?? 0 }
            QUICEndpoint.configure(socket)
            let endpoint = QUICEndpoint(service: self)
            let task = runtime.spawn(with: socket) { socket in
                await endpoint.run(socket)
            }
            lock.withLock {
                $0.endpoints.append(endpoint)
                $0.tasks.append(task)
            }
        }
        return bound
    }

    /// Shutdown has begun: GOAWAY everywhere, no new requests, and every
    /// connection closed once its requests are answered or `grace` is up.
    func shutdown(grace: Duration) {
        for endpoint in lock.withLock({ $0.endpoints }) { endpoint.stop(grace: grace) }
    }

    /// The endpoints, one a socket.
    var endpoints: [QUICEndpoint] { lock.withLock { $0.endpoints } }

    /// Returns once every endpoint has ended.
    func wait() async {
        for task in lock.withLock({ $0.tasks }) { await task.value }
    }
}

// MARK: - The endpoint

/// One UDP socket's QUIC: see the top of this file.
///
/// Its stored properties are `@exclusivity(unchecked)`: each is the endpoint
/// task's own or kept under `lock`, so two accesses never overlap.
final class QUICEndpoint: @unchecked Sendable {
    /// Datagrams taken from the socket per system call.
    static let batchSize = 32
    /// The largest datagram taken or sent. Anything larger is a packet the
    /// path could not have carried whole.
    static let datagramSize = 1500
    /// The most datagrams in one segmented send: the kernel takes up to 64,
    /// and 64 KiB, and 32 full-size ones stay inside both.
    static let maxSegments = 32
    /// The most datagrams one connection sends before the others get a turn.
    /// Congestion control is what normally stops a connection; this is so one
    /// that always believes it has something to send cannot hold the socket.
    /// One cut short goes on at once, on the next pass.
    @exclusivity(unchecked) var datagramsPerTurn = 4096
    /// The socket buffers asked for. A burst arriving faster than the
    /// endpoint takes it waits here rather than being dropped.
    static let socketBufferSize = 2 * 1024 * 1024

    let app: CompiledApplication
    let limits: ConnectionLimits
    let settings: HTTP3Limits
    let pool: StreamPool
    let certificates: @Sendable () -> [CertificateKey]
    /// The access log or `app.onResponse` sees each answer.
    let observing: Bool

    // MARK: Shared with the request tasks, under `lock`

    let lock = Mutex<Void>(())
    /// Ends the endpoint's wait on the socket: a task posted something, or
    /// shutdown began.
    let wake = IOTimeoutTrigger()
    /// Streams with something for the endpoint: an answer, body bytes, an
    /// end, a task finished.
    @exclusivity(unchecked) var posted: [Unmanaged<H3Stream>] = []
    @exclusivity(unchecked) var stopRequested = false
    @exclusivity(unchecked) var graceMs: UInt64 = 0
    /// The endpoint is answering requests itself, and takes what is posted
    /// meanwhile once it is done: a post need not wake it.
    @exclusivity(unchecked) var answering = false

    // MARK: The endpoint task's own

    /// Every connection, by each connection ID that reaches it: the one we
    /// issued, and the one the client invented for its first packet, which
    /// it goes on using until it has heard from us.
    @exclusivity(unchecked) var connections: [QUICConnectionID: H3Connection] = [:]
    /// Every connection, once each, until it is closed and its tasks done.
    @exclusivity(unchecked) var live: [H3Connection] = []
    /// Connections with something to look at since the last pass, and the
    /// list they are taken into.
    @exclusivity(unchecked) var touched: [H3Connection] = []
    @exclusivity(unchecked) var servicing: [H3Connection] = []
    @exclusivity(unchecked) var draining: [Unmanaged<H3Stream>] = []
    /// Requests the endpoint answers itself, once the datagrams in hand are
    /// handled.
    @exclusivity(unchecked) var inline: [H3Stream] = []
    /// Version negotiation packets to send: rare, and each its own.
    @exclusivity(unchecked) var replies: [(bytes: [UInt8], to: SocketAddress, from: SocketAddress?)] = []
    /// Outgoing datagrams, back to back, waiting to go out as one send.
    let sendBuffer: UnsafeMutablePointer<UInt8>
    @exclusivity(unchecked) var pendingLength = 0
    @exclusivity(unchecked) var pendingSegment = 0
    @exclusivity(unchecked) var pendingCount = 0
    @exclusivity(unchecked) var pendingPeer: SocketAddress?
    @exclusivity(unchecked) var pendingLocal: SocketAddress?
    /// The earliest QUIC timer, as of the last pass; `UInt64.max` for none.
    @exclusivity(unchecked) var nextTimerMs = UInt64.max
    /// When stalled request bodies were last looked for.
    @exclusivity(unchecked) var lastTickMs: UInt64 = 0
    /// Shutdown has begun here: GOAWAY sent, no new connections.
    @exclusivity(unchecked) var stopping = false
    @exclusivity(unchecked) var stopDeadlineMs = UInt64.max
    /// The grace period is over: every connection has been closed.
    @exclusivity(unchecked) var forced = false

    init(app: CompiledApplication, limits: ConnectionLimits, pool: StreamPool,
         certificates: @escaping @Sendable () -> [CertificateKey]) {
        self.app = app
        self.limits = limits
        settings = limits.http3
        self.pool = pool
        self.certificates = certificates
        observing = limits.accessLog || !app.observers.isEmpty || app.metrics != nil || app.tracer != nil
        sendBuffer = .allocate(capacity: QUICEndpoint.datagramSize * QUICEndpoint.maxSegments)
        posted.reserveCapacity(64)
        draining.reserveCapacity(64)
        touched.reserveCapacity(64)
    }

    convenience init(service: HTTP3Service) {
        self.init(app: service.app, limits: service.limits, pool: service.pool, certificates: service.certificates)
    }

    deinit {
        sendBuffer.deallocate()
    }

    /// Sets the socket up for QUIC: told where each datagram arrived, so a
    /// reply leaves from the address the client reached; never fragmented,
    /// which QUIC requires; and buffers large enough for a burst.
    static func configure(_ socket: borrowing UDPSocket) {
        try? socket.enablePathInfo()
        try? socket.setDontFragment()
        try? socket.setOption(.receiveBufferSize, to: socketBufferSize)
        try? socket.setOption(.sendBufferSize, to: socketBufferSize)
    }

    /// The configuration a new connection is made with: the certificates as
    /// they are now, so a reload reaches the next handshake.
    func quicConfig() -> QUICServerConfiguration {
        var config = QUICServerConfiguration(certificateKeys: certificates(), applicationProtocols: ["h3"])
        config.maxIdleTimeout = .milliseconds(settings.idleTimeoutMs)
        config.initialMaxStreamData = UInt64(settings.streamWindow)
        config.initialMaxData = UInt64(settings.streamWindow) &* 8
        config.initialMaxStreamsBidi = UInt64(settings.maxStreams)
        // Datagrams are WebTransport's (RFC 9221, RFC 9297): as large as a
        // packet of the smallest size a path must carry.
        config.maxDatagramFrameSize = 1200
        return config
    }

    /// From any task: begin shutting down.
    func stop(grace: Duration) {
        lock.withLock { _ in
            stopRequested = true
            graceMs = milliseconds(grace)
        }
        wake.fire()
    }

    // MARK: The loop

    func run(_ socket: borrowing UDPSocket) async {
        var batch = DatagramBatch(capacity: QUICEndpoint.batchSize, slotSize: QUICEndpoint.datagramSize)
        var busy = false
        while true {
            var now = quicNowMs()
            var received = 0
            do {
                let wait: Duration = busy ? .zero : waitBefore(now)
                received = try await Runtime.withIOTimeout(for: wait, trigger: wake) { () async throws(IOError) -> Int in
                    try await socket.receive(&batch)
                }
            } catch let error where error == .timedOut {
                // A timer is due, or a task posted something.
            } catch let error where error == .cancelled {
                // The runtime is going away.
                break
            } catch {
                // An ICMP error for some earlier send surfaces here; it says
                // nothing about the socket.
                Log.debug("quic: receive failed: \(error)")
            }
            now = quicNowMs()
            for i in 0..<received where !batch.isTruncated(at: i) {
                let bytes = batch[i]
                guard let from = batch.address(at: i), let base = bytes.baseAddress else { continue }
                handleDatagram(UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self)), bytes.count,
                               from: from, to: batch.localAddress(at: i), ecn: batch.ecn(at: i), nowMs: now)
            }
            busy = service(nowMs: now)
            if !inline.isEmpty {
                await answerInline()
                takePosts()
                serviceTouched(nowMs: now)
            }
            if await flush(socket, nowMs: now) { busy = true }
            // After the flush: what was just sent set loss and probe timers.
            nextTimerMs = earliestTimer(nowMs: now)
            if stopping && (live.isEmpty || forced && closesSent) { break }
        }
        // Whatever is left -- connections draining past the grace period, or
        // everything when the runtime is going away -- has its requests
        // cancelled. The connections stay with the endpoint, which outlives
        // any task still finishing with one of their streams.
        for connection in live { connection.abandon() }
        connections.removeAll()
    }

    /// Every connection left has sent its CONNECTION_CLOSE. Draining one
    /// for three probe timeouts only answers a peer that missed the close,
    /// and a peer that has gone quiet backs those timeouts off for longer
    /// than shutdown has.
    private var closesSent: Bool {
        live.allSatisfy { $0.quic.isClosed || $0.quic.status == .closing && !$0.quic.hasOutput }
    }

    /// How long the socket may be waited on: until the earliest timer, and
    /// no longer than a second, which is how often stalled uploads are
    /// looked for.
    func waitBefore(_ now: UInt64) -> Duration {
        var until = now &+ 1000
        if nextTimerMs < until { until = nextTimerMs }
        if stopDeadlineMs < until { until = stopDeadlineMs }
        return until <= now ? .zero : .milliseconds(Int64(until &- now))
    }

    /// Everything but the socket: posts, events, timers, shutdown. True
    /// when there is more to do at once.
    func service(nowMs now: UInt64) -> Bool {
        takePosts()
        serviceTouched(nowMs: now)
        runTimers(nowMs: now)
        serviceTouched(nowMs: now)
        if now &- lastTickMs >= 1000 {
            lastTickMs = now
            for connection in live { connection.tick(nowMs: now) }
            serviceTouched(nowMs: now)
        }
        checkShutdown(nowMs: now)
        takePosts()
        serviceTouched(nowMs: now)
        reap()
        return lock.withLock { _ in !posted.isEmpty } || !touched.isEmpty
    }

    /// Notes that `connection` has something to look at.
    @inline(__always)
    func touch(_ connection: H3Connection) {
        if !connection.touched {
            connection.touched = true
            touched.append(connection)
        }
    }

    func serviceTouched(nowMs now: UInt64) {
        var rounds = 0
        while !touched.isEmpty && rounds < 4 {
            rounds &+= 1
            swap(&touched, &servicing)
            for connection in servicing {
                connection.touched = false
                connection.handleEvents(nowMs: now)
            }
            servicing.removeAll(keepingCapacity: true)
        }
    }

    /// Runs the timers that are due.
    func runTimers(nowMs now: UInt64) {
        guard now >= nextTimerMs else { return }
        for connection in live {
            let quic = connection.quic
            if let at = quic.nextTimeout(nowMs: now), now >= at {
                quic.onTimeout(nowMs: now)
                touch(connection)
            }
        }
    }

    /// When the next QUIC timer is due; `UInt64.max` for none.
    func earliestTimer(nowMs now: UInt64) -> UInt64 {
        var earliest = UInt64.max
        for connection in live {
            if let at = connection.quic.nextTimeout(nowMs: now), at < earliest { earliest = at }
        }
        return earliest
    }

    /// Takes what the request tasks posted.
    func takePosts() {
        lock.withLock { _ in swap(&posted, &draining) }
        guard !draining.isEmpty else { return }
        for stream in draining { stream.takeUnretainedValue().connection.posted(stream.takeUnretainedValue()) }
        draining.removeAll(keepingCapacity: true)
    }

    /// Lets go of connections that are closed and whose tasks have all
    /// ended.
    func reap() {
        var i = 0
        while i < live.count {
            let connection = live[i]
            if connection.quic.isClosed {
                connection.closeHTTP()
                if connection.tasks == 0 {
                    if connections[connection.localCID] === connection { connections[connection.localCID] = nil }
                    if connections[connection.originalDCID] === connection {
                        connections[connection.originalDCID] = nil
                    }
                    live.swapAt(i, live.count - 1)
                    live.removeLast()
                    continue
                }
            }
            i &+= 1
        }
    }

    /// Shutdown: GOAWAY once, and each connection closed when it has nothing
    /// left to answer, or when the grace period is up.
    func checkShutdown(nowMs now: UInt64) {
        if !stopping {
            let (requested, grace) = lock.withLock { _ in (stopRequested, graceMs) }
            guard requested else { return }
            stopping = true
            stopDeadlineMs = now &+ grace
            for connection in live { connection.goaway() }
        }
        if now >= stopDeadlineMs {
            // Once: the deadline is not waited for again.
            forced = true
            stopDeadlineMs = .max
        }
        for connection in live where !connection.quic.isClosed {
            connection.closeIfDone(force: forced)
        }
    }

    // MARK: Datagrams in

    /// One datagram from `peer`, which arrived on `local`.
    func handleDatagram(_ p: UnsafeMutablePointer<UInt8>, _ n: Int, from peer: SocketAddress,
                        to local: SocketAddress?, ecn: UInt8, nowMs now: UInt64) {
        guard n > 0 else { return }
        if p[0] & 0x80 != 0 {
            // A long header: its version is legible whatever it is, and one
            // this server does not speak is answered with the ones it does.
            guard n >= 5 else { return }
            let version = UInt32(p[1]) << 24 | UInt32(p[2]) << 16 | UInt32(p[3]) << 8 | UInt32(p[4])
            if version == QUICVersion.negotiation { return }
            if !QUICVersion.isSupported(version) {
                negotiateVersion(p, n, from: peer, to: local)
                return
            }
        }
        let header = QUICPacket.parseHeader(p, n, localCIDLength: quicLocalCIDLength)
        guard header.isValid else { return }
        if let connection = connections[header.dcid] {
            // A client is free to change address mid-connection: the
            // connection ID, not the four-tuple, is what identifies it.
            //
            // But a connection ID is on the wire in clear, so anyone who sees
            // one can put it in a UDP header of their own, or rewrite the
            // source of a packet in flight. Believing the address of even an
            // authenticated packet would let one such datagram redirect
            // everything the connection has yet to send. So a datagram from
            // elsewhere is handed over as from another path, and the
            // connection moves there only once the transport has had a
            // PATH_RESPONSE from it (QUICPath.swift).
            let quic = connection.quic
            if peer == connection.peer {
                quic.receive(p, n, ecn: ecn, nowMs: now)
                if quic.acceptedNewPacket { connection.local = local }
            } else {
                let (path, made) = connection.path(for: peer, local: local)
                quic.receive(p, n, ecn: ecn, path: path, nowMs: now)
                // A datagram that did not decrypt is not anybody's claim to
                // the address, and takes no room.
                if made && !quic.datagramAuthenticated { connection.forgetPath(path) }
            }
            touch(connection)
            return
        }
        // Not a connection we know. Only an Initial can start one; anything
        // else -- a stray, a packet for a connection already gone -- is
        // dropped without a word.
        guard header.type == .initial else { return }
        // RFC 9000 section 14.1: a client's first flight fills a datagram,
        // which is what keeps the handshake from being an amplifier for a
        // spoofed source address.
        guard n >= QUICPacket.minimumInitialSize else { return }
        // RFC 9000 section 7.2: the client's first destination ID is at least
        // eight bytes, and is what the Initial keys are made from.
        guard header.dcid.length >= 8 else { return }
        guard !stopping, live.count < settings.maxConnections else { return }
        accept(p, n, header: header, from: peer, to: local, ecn: ecn, nowMs: now)
    }

    private func accept(_ p: UnsafeMutablePointer<UInt8>, _ n: Int, header: QUICPacketHeader,
                        from peer: SocketAddress, to local: SocketAddress?, ecn: UInt8, nowMs now: UInt64) {
        let localCID = QUICConnectionID.random()
        guard let quic = QUICConnectionState(config: quicConfig(), version: header.version, clientDCID: header.dcid,
                                        clientSCID: header.scid, localCID: localCID, nowMs: now) else { return }
        let connection = H3Connection(endpoint: self, quic: quic, peer: peer, local: local,
                                      localCID: localCID, originalDCID: header.dcid)
        connections[localCID] = connection
        connections[header.dcid] = connection
        live.append(connection)
        quic.receive(p, n, ecn: ecn, nowMs: now)
        touch(connection)
    }

    /// Tells a client which versions this server speaks (RFC 9000 section
    /// 6, RFC 8999). The packet is unprotected and keeps no state: a server
    /// that kept state here would be one an attacker could fill.
    private func negotiateVersion(_ p: UnsafeMutablePointer<UInt8>, _ n: Int, from peer: SocketAddress,
                                  to local: SocketAddress?) {
        // Only for a datagram large enough to have started a connection,
        // and so never more bytes out than came in.
        guard n >= QUICPacket.minimumInitialSize else { return }
        // The version-independent layout: the identifiers' lengths are a
        // byte each, and up to 255 bytes, whatever the version.
        var at = 5
        let dcidLength = Int(p[at])
        at &+= 1
        guard n >= at &+ dcidLength &+ 1 else { return }
        let dcid = UnsafeBufferPointer(start: p + at, count: dcidLength)
        at &+= dcidLength
        let scidLength = Int(p[at])
        at &+= 1
        guard n >= at &+ scidLength else { return }
        let scid = UnsafeBufferPointer(start: p + at, count: scidLength)
        // The first byte's low bits are arbitrary, but the high bit is set
        // so the packet reads as a long header.
        var out: [UInt8] = [0x80 | 0x40, 0, 0, 0, 0]
        // The identifiers swap places: what the client used as destination
        // comes back as source.
        out.append(UInt8(scidLength))
        out.append(contentsOf: scid)
        out.append(UInt8(dcidLength))
        out.append(contentsOf: dcid)
        for version in [QUICVersion.v1, QUICVersion.v2] {
            out.append(UInt8(truncatingIfNeeded: version >> 24))
            out.append(UInt8(truncatingIfNeeded: version >> 16))
            out.append(UInt8(truncatingIfNeeded: version >> 8))
            out.append(UInt8(truncatingIfNeeded: version))
        }
        replies.append((out, peer, local))
    }

    // MARK: Datagrams out

    /// Sends what every connection has to say. True when a connection was
    /// cut short of its turn, and still has more.
    func flush(_ socket: borrowing UDPSocket, nowMs now: UInt64) async -> Bool {
        if !replies.isEmpty {
            let sending = replies
            replies.removeAll(keepingCapacity: true)
            for reply in sending {
                // Nothing is pending between flushes: the buffer is free.
                let n = reply.bytes.count
                reply.bytes.withUnsafeBufferPointer { sendBuffer.update(from: $0.baseAddress!, count: n) }
                _ = try? await socket.send(segments: UnsafeRawBufferPointer(start: sendBuffer, count: n),
                                           segmentSize: n, to: reply.to, from: reply.from)
            }
        }
        var more = false
        for connection in live where connection.quic.hasOutput {
            if await writeAll(connection, socket, nowMs: now) { more = true }
        }
        for connection in live where connection.quic.hasProbes {
            await sendProbes(connection, socket, nowMs: now)
        }
        return more
    }

    /// Sends what a connection owes addresses other than its peer's: the
    /// challenges that validate a move, and the answers to probes, which go
    /// back the way they came. One datagram each: they are rare.
    private func sendProbes(_ connection: H3Connection, _ socket: borrowing UDPSocket, nowMs now: UInt64) async {
        for _ in 0..<QUICEndpoint.maxSegments {
            let (n, path) = connection.quic.nextProbeDatagram(sendBuffer, QUICEndpoint.datagramSize, nowMs: now)
            if n == 0 { break }
            guard let to = connection.paths.first(where: { $0.id == path }) else { continue }
            do {
                _ = try await socket.send(segments: UnsafeRawBufferPointer(start: sendBuffer, count: n),
                                          segmentSize: n, to: to.peer, from: to.local)
            } catch {
                Log.debug("quic: send failed: \(error)")
            }
        }
    }

    /// Builds a connection's datagrams straight into `sendBuffer`, back to
    /// back, and sends each run of equal-sized ones with a single segmented
    /// send. A connection moving data produces full-size datagrams one after
    /// another, all to one address, and one system call each costs a route
    /// lookup and a wake-up of the receiver apiece. A run ends at a datagram
    /// shorter than the ones before it (the kernel allows the last to be
    /// short), at one longer (it cannot join, so it starts the next run), or
    /// at `maxSegments`. True when the turn ran out before the connection
    /// did.
    @discardableResult
    func writeAll(_ connection: H3Connection, _ socket: borrowing UDPSocket, nowMs now: UInt64) async -> Bool {
        var remaining = datagramsPerTurn
        while remaining > 0 {
            remaining &-= 1
            // There is always room: a run is sent before it reaches the cap.
            let at = sendBuffer + pendingLength
            let n = connection.quic.nextDatagram(at, QUICEndpoint.datagramSize, nowMs: now)
            if n == 0 {
                remaining = -1
                break
            }
            if pendingLength == 0 {
                pendingPeer = connection.peer
                pendingLocal = connection.local
                pendingSegment = n
            } else if n > pendingSegment {
                let held = pendingLength
                await sendPending(socket, length: held)
                sendBuffer.update(from: sendBuffer + held, count: n)
                pendingPeer = connection.peer
                pendingLocal = connection.local
                pendingSegment = n
            }
            pendingLength &+= n
            pendingCount &+= 1
            if n < pendingSegment || pendingCount == QUICEndpoint.maxSegments {
                await sendPending(socket, length: pendingLength)
            }
        }
        await sendPending(socket, length: pendingLength)
        return remaining == 0
    }

    /// Sends the run at the front of `sendBuffer`. A run the socket refuses
    /// -- an ICMP error for that peer, say -- is lost, and loss recovery
    /// sends its contents again.
    private func sendPending(_ socket: borrowing UDPSocket, length: Int) async {
        defer {
            pendingLength = 0
            pendingCount = 0
        }
        guard length > 0, let peer = pendingPeer else { return }
        let bytes = UnsafeRawBufferPointer(start: sendBuffer, count: length)
        do {
            try await socket.send(segments: bytes, segmentSize: pendingSegment, to: peer, from: pendingLocal)
        } catch {
            Log.debug("quic: send failed: \(error)")
        }
    }
}
