//===----------------------------------------------------------------------===//
// Connections the HTTP client makes, and the ones it keeps.
//
// One pool per process -- a shard is a process -- keyed by where a connection
// goes and how it was secured, shared by every task on every worker thread.
// A connection is one task's from when it is taken until the response on it
// has been read to its end; then it goes back, or is closed.
//
// What makes a kept connection safe to hand to the next caller:
//
//   * The key. An encrypted connection is kept under the name its
//     certificate was checked against, the trust store it was checked with,
//     and the ALPN it offered: a connection verified for one name handed to a
//     caller that asked for another reopens the hole hostname verification
//     exists to close, and one that settled on HTTP/1.1 handed to a caller
//     expecting HTTP/2 is a frame header written into a request line.
//   * Silence. A kept connection that has something to say before it is
//     asked is a peer hanging up, or one about to, and is closed rather than
//     handed over: the oldest bug in connection pooling.
//   * Age. One idle for longer than `idleTime` is closed; a server's own idle
//     timeout is often not much longer, and a request written into a
//     connection the server is closing is lost.
//
// Garuda 1 kept these per worker and closed idle ones from the worker's sweep.
// Here any task may take one, so the pool is locked, and the sweep is done
// as connections come back, at most once a second.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import Vega
import VegaFS
import VegaIO
import VegaTLS

/// Why a connection did not come up.
public enum OutboundError: Error, Equatable, Sendable {
    /// A name could not be resolved: a nameserver that is down, or a host
    /// that has gone away.
    case unresolved
    /// The connection was refused, unreachable, or reset, or its TLS
    /// handshake failed. Carries the error code.
    case failed(Int32)
    /// It did not come up inside the time allowed.
    case timedOut
    /// The task that wanted it was cancelled.
    case cancelled
    /// This process already has as many client connections open as it may.
    case exhausted
    /// The trust store named could not be read.
    case trustStore
}

/// A connection's bytes, whatever carries them.
protocol ClientTransport: AnyObject, Sendable {
    func read(into buffer: inout IOBuffer) async throws(IOError) -> Int
    func write(_ bytes: UnsafeRawBufferPointer) async throws(IOError)
    /// Whether a read would return at once: input, or the peer's close.
    var hasPendingInput: Bool { get }
    /// What ALPN settled on, over TLS.
    var applicationProtocol: String? { get }
}

final class TCPClientTransport: ClientTransport {
    let stream: TCPStream

    init(_ stream: consuming TCPStream) { self.stream = stream }

    func read(into buffer: inout IOBuffer) async throws(IOError) -> Int { try await stream.read(into: &buffer) }
    func write(_ bytes: UnsafeRawBufferPointer) async throws(IOError) { try await stream.write(bytes) }
    var hasPendingInput: Bool { stream.hasPendingInput }
    var applicationProtocol: String? { nil }
}

final class TLSClientTransport: ClientTransport {
    let stream: TLSStream<TCPStream>

    init(_ stream: consuming TLSStream<TCPStream>) { self.stream = stream }

    func read(into buffer: inout IOBuffer) async throws(IOError) -> Int { try await stream.read(into: &buffer) }
    func write(_ bytes: UnsafeRawBufferPointer) async throws(IOError) { try await stream.write(bytes) }
    var hasPendingInput: Bool { stream.hasPendingInput }
    var applicationProtocol: String? { stream.applicationProtocol }
}

/// Where a connection goes, and how it was secured: which kept connections
/// may be handed to a caller.
struct OriginKey: Hashable, Sendable {
    var host: String
    var port: UInt16
    /// Empty for plaintext. Otherwise the trust store and the ALPN offer,
    /// NUL-separated: none of them may contain one, so no pair can spell
    /// another's identity. The name checked is `host`.
    var tls: String = ""
}

/// One connection the client made. One task's at a time.
final class ClientConnection: @unchecked Sendable {
    let key: OriginKey
    let transport: any ClientTransport
    /// What has been read and not yet taken. Empty whenever the connection
    /// is kept.
    var input = IOBuffer(capacity: 16 * 1024)
    /// When it was last given back.
    var idleSince = ContinuousClock.now

    init(key: OriginKey, transport: any ClientTransport) {
        self.key = key
        self.transport = transport
    }

    deinit {
        ClientConnections.shared.closed()
    }

    var isHTTP2: Bool { transport.applicationProtocol == "h2" }

    /// Reads more onto the end of `input`. 0 is the peer's close.
    func readMore() async throws(IOError) -> Int {
        if input.capacity - input.count < 4096 { input.reserveCapacity(input.capacity * 2) }
        return try await transport.read(into: &input)
    }
}

/// The connections the client keeps, by where they go.
final class ClientConnections: Sendable {
    static let shared = ClientConnections()

    /// How many may be open at once, in use or kept.
    let limit = 1024
    /// How many are kept per place.
    let idlePerKey = 32
    /// How long one is kept unused.
    let idleTime = Duration.seconds(30)

    private struct Kept {
        var idle: [OriginKey: [ClientConnection]] = [:]
        var lastSweep = ContinuousClock.now
    }

    private let kept = Mutex(Kept())
    private let open = Atomic<Int>(0)
    private let contexts = Mutex<[String: TLSContext]>([:])

    /// A kept connection to `key` that is still fit to use, newest first.
    func take(_ key: OriginKey) -> ClientConnection? {
        let now = ContinuousClock.now
        while true {
            let taken: ClientConnection? = kept.withLock { kept in
                guard var list = kept.idle[key], let last = list.popLast() else { return nil }
                kept.idle[key] = list.isEmpty ? nil : list
                return last
            }
            guard let connection = taken else { return nil }
            // Released outside the lock: dropping one closes its socket.
            if now - connection.idleSince < idleTime && !connection.transport.hasPendingInput {
                return connection
            }
        }
    }

    /// Keeps `connection` for the next caller to the same place. It must
    /// have nothing left on it.
    func give(_ connection: ClientConnection) {
        let now = ContinuousClock.now
        connection.idleSince = now
        var dropped: [ClientConnection] = []
        kept.withLock { kept in
            var list = kept.idle[connection.key, default: []]
            list.append(connection)
            if list.count > idlePerKey { dropped.append(list.removeFirst()) }
            kept.idle[connection.key] = list
            // The ones nobody came back for, wherever they go.
            if now - kept.lastSweep >= .seconds(1) {
                kept.lastSweep = now
                for (key, list) in kept.idle {
                    let fresh = list.filter { now - $0.idleSince < idleTime }
                    guard fresh.count < list.count else { continue }
                    dropped.append(contentsOf: list.filter { now - $0.idleSince >= idleTime })
                    kept.idle[key] = fresh.isEmpty ? nil : fresh
                }
            }
        }
        _ = dropped
    }

    /// Closes every kept connection.
    func closeIdle() {
        let all = kept.withLock { kept in
            let all = kept.idle
            kept.idle = [:]
            return all
        }
        _ = all
    }

    /// How many are kept, for tests.
    var idleCount: Int { kept.withLock { $0.idle.values.reduce(0) { $0 + $1.count } } }

    /// One more is about to be opened, if the limit allows.
    func opening() throws(OutboundError) {
        let now = open.add(1, ordering: .relaxed).newValue
        if now > limit {
            open.subtract(1, ordering: .relaxed)
            throw .exhausted
        }
    }

    /// One has been closed, or never came up.
    func closed() {
        open.subtract(1, ordering: .relaxed)
    }

    /// The client context for a trust store and an ALPN offer, made once.
    func context(caFile: String, alpn: [String]) async throws(OutboundError) -> TLSContext {
        let name = caFile + "\u{0}" + alpn.joined(separator: ",")
        if let made = contexts.withLock({ $0[name] }) { return made }
        let roots: TLSConfiguration.TrustRoots
        if caFile.isEmpty {
            roots = .system
        } else {
            guard let pem = try? await FileSystem.readString(caFile) else { throw .trustStore }
            roots = .certificates(pem)
        }
        let made: TLSContext
        do {
            made = try TLSContext(.client(trustRoots: roots, applicationProtocols: alpn))
        } catch {
            throw .trustStore
        }
        contexts.withLock { $0[name] = made }
        return made
    }

    /// Opens a connection to `host`: the name looked up, its addresses raced,
    /// and over TLS the handshake, all by `deadline`. An HTTP/2 connection --
    /// what ALPN chose, or `forceHTTP2` -- comes split, for its reader task
    /// and its writers to use at once.
    func connect(host: String, port: UInt16, secure: Bool, caFile: String, alpn: [String], forceHTTP2: Bool,
                 key: OriginKey, deadline: ContinuousClock.Instant) async throws(OutboundError) -> Connected {
        let context: TLSContext? = secure ? try await self.context(caFile: caFile, alpn: alpn) : nil
        try opening()
        do throws(OutboundError) {
            let addresses: [SocketAddress]
            do {
                addresses = try await Runtime.withIODeadline(until: deadline) { () async throws(IOError) -> [SocketAddress] in
                    try await SocketAddress.lookup(host: host, port: Int(port))
                }
            } catch {
                if error == .timedOut { throw OutboundError.timedOut }
                if error == .cancelled { throw OutboundError.cancelled }
                throw OutboundError.unresolved
            }
            do {
                return try await Runtime.withIODeadline(until: deadline) { () async throws(IOError) -> Connected in
                    let tcp = try await TCPStream.connect(to: addresses)
                    guard let context else {
                        guard forceHTTP2 else { return .http1(ClientConnection(key: key, transport: TCPClientTransport(tcp))) }
                        let halves = tcp.halves()
                        return .http2(SplitReader(halves.reader), SplitWriter(halves.writer))
                    }
                    let tls = try await TLSStream.connect(tcp, serverName: host, context: context)
                    guard forceHTTP2 || tls.applicationProtocol == "h2" else {
                        return .http1(ClientConnection(key: key, transport: TLSClientTransport(tls)))
                    }
                    let halves = tls.halves()
                    return .http2(SplitReader(halves.reader), SplitWriter(halves.writer))
                }
            } catch {
                if error == .timedOut { throw OutboundError.timedOut }
                if error == .cancelled { throw OutboundError.cancelled }
                throw OutboundError.failed(error.code)
            }
        } catch {
            closed()
            throw error
        }
    }
}

/// A connection just made: whole, for HTTP/1.1, or split for HTTP/2. Either
/// way it is counted as open until what holds it goes.
enum Connected {
    case http1(ClientConnection)
    case http2(any ClientReader, any ClientWriter)
}

/// The reading half of a split connection: one task's, its reader's.
protocol ClientReader: AnyObject, Sendable {
    func read(into buffer: inout IOBuffer) async throws(IOError) -> Int
}

/// The writing half: one writer's at a time, under the connection's lock.
protocol ClientWriter: AnyObject, Sendable {
    func write(_ bytes: UnsafeRawBufferPointer) async throws(IOError)
}

final class SplitReader<Reader: AsyncReader & ~Copyable & Sendable>: ClientReader {
    let reader: Reader
    init(_ reader: consuming Reader) { self.reader = reader }
    func read(into buffer: inout IOBuffer) async throws(IOError) -> Int { try await reader.read(into: &buffer) }
}

final class SplitWriter<Writer: AsyncWriter & ~Copyable & Sendable>: ClientWriter {
    let writer: Writer
    init(_ writer: consuming Writer) { self.writer = writer }
    func write(_ bytes: UnsafeRawBufferPointer) async throws(IOError) { try await writer.write(bytes) }
}
