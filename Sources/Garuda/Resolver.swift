//===----------------------------------------------------------------------===//
// Turning a name into an address, on the worker's own poller.
//
// This is the reason the outbound layer refuses names: `getaddrinfo` blocks,
// and there is no way to interrupt it. A route with a 500 ms deadline whose
// lookup stalls for five seconds would sail past that deadline and hold the
// thread that was doing it. A query sent over a socket this poller owns is a
// wait like every other wait here, so a deadline unwinds it and a drain closes
// it.
//
// It is a stub resolver: it asks a full one to do the walking rather than
// chasing referrals from the root. That is what every program on the machine
// does, and it is what resolv.conf describes.
//
// What it does not do yet, deliberately, is fall back to TCP when an answer is
// truncated. Truncation is reported rather than hidden, so a caller is never
// handed half an answer believing it whole; the fallback is the next slice.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore

enum ResolveError: Error, Equatable {
    /// No nameserver answered, across every server and every attempt.
    case unanswered
    /// Every server that answered said the name does not exist.
    case noSuchName
    /// A name was found but carried no address of a kind we can use.
    case noAddress
    /// The answer did not fit in a datagram. Until TCP fallback exists this is
    /// reported rather than silently treated as the whole answer.
    case truncated
    /// The request that wanted it ended, or the worker is shutting down.
    case cancelled
    /// The name itself is not one that can be asked about.
    case badName
}

/// An address as bytes, with the family implied by its length: four for IPv4,
/// sixteen for IPv6.
struct ResolvedAddress: Equatable {
    var bytes: [UInt8]

    var isIPv6: Bool { bytes.count == 16 }

    /// The literal form, which is what `Worker.connect` wants -- it parses
    /// with AI_NUMERICHOST and never resolves anything itself.
    var text: String {
        if bytes.count == 4 {
            return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
        }
        guard bytes.count == 16 else { return "" }
        // Full form, no "::" compression. It is longer to read and shorter to
        // get wrong, and the only reader is getaddrinfo.
        var parts: [String] = []
        parts.reserveCapacity(8)
        var i = 0
        while i < 16 {
            let group = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
            parts.append(String(group, radix: 16))
            i += 2
        }
        return parts.joined(separator: ":")
    }
}

extension Worker {
    /// The port every nameserver in resolv.conf listens on. resolv.conf has no
    /// syntax for another, so there is nothing to read from the file -- but a
    /// test has to be able to stand up a nameserver of its own on a port the
    /// kernel chose, so this is a worker's setting rather than a constant.
    static let defaultNameserverPort: UInt16 = 53

    /// Looks up `name`, trying each candidate from the search list in turn and
    /// each nameserver in turn within that.
    ///
    /// Returns every address the winning answer carried, in the order the
    /// server gave them: a server rotates its own records, and reordering them
    /// here would undo whatever balancing it was doing.
    static func resolve(_ worker: UnsafeMutablePointer<Worker>, name: String,
                        wantIPv6: Bool = false) async throws(ResolveError) -> [ResolvedAddress] {
        // An address is not a name. Asking a nameserver about one would be a
        // round trip to be told what was already in hand.
        if let literal = asLiteral(name) { return [literal] }

        let config = worker.pointee.resolverConfig
        let type: DNSRecordType = wantIPv6 ? .aaaa : .a
        var sawName = false

        for candidate in config.candidates(for: name) {
            for server in config.nameservers {
                var attempt = 0
                while attempt < config.attempts {
                    attempt += 1
                    do {
                        let answer = try await ask(worker, candidate, type: type,
                                                   server: server,
                                                   seconds: config.timeoutSeconds)
                        switch answer {
                        case .addresses(let found):
                            return found
                        case .noSuchName:
                            // This candidate does not exist. Another server
                            // will say the same, so move to the next name
                            // rather than asking again.
                            sawName = true
                            attempt = config.attempts
                        case .truncated:
                            // What truncation means is "ask me again over
                            // TCP", so that is what happens rather than the
                            // lookup failing. The same server, since it is the
                            // one holding the answer.
                            let whole = try await askOverTCP(worker, candidate, type: type,
                                                             server: server,
                                                             seconds: config.timeoutSeconds)
                            switch whole {
                            case .addresses(let found):
                                return found
                            case .noSuchName, .empty:
                                sawName = true
                                attempt = config.attempts
                            case .truncated, .ignored:
                                // Truncated over TCP is a server contradicting
                                // itself, and there is no third transport to
                                // try. Escaping rather than retrying: the
                                // catch below would report this as a server
                                // that never answered, when it answered twice.
                                throw Escape.truncated
                            }
                        case .empty:
                            // The name exists with no record of this type.
                            sawName = true
                            attempt = config.attempts
                        case .ignored:
                            // Not an answer to what was asked: keep waiting on
                            // this server by asking again.
                            continue
                        }
                    } catch let escape as Escape {
                        // An answer, and a final one. Retrying would get the
                        // same reply from the same server.
                        throw escape.reason
                    } catch ResolveError.cancelled {
                        throw ResolveError.cancelled
                    } catch ResolveError.badName {
                        // The name cannot be asked about at all, so no server
                        // will do better. Reporting this as unreachable would
                        // send somebody looking at the network for a fault in
                        // the string they passed in.
                        throw ResolveError.badName
                    } catch {
                        // This server did not answer. Try it again, then the
                        // next one.
                        continue
                    }
                }
            }
        }
        if sawName { throw .noAddress }
        throw .unanswered
    }

    /// Carries a decided outcome out through the retry loop.
    ///
    /// The loop catches everything it does not recognise and moves to the next
    /// server, which is right for a server that did not answer and wrong for
    /// an answer that settles the question. A separate type cannot be confused
    /// with the failures that mean "try again".
    private struct Escape: Error {
        var reason: ResolveError
        static let truncated = Escape(reason: .truncated)
    }

    /// What one question to one server produced.
    private enum Answer {
        case addresses([ResolvedAddress])
        case noSuchName
        case truncated
        /// The name exists but has no record of the type asked for.
        case empty
        /// A datagram that was not an answer to this question.
        case ignored
    }

    /// Builds a query and the id it must be answered with.
    ///
    /// Shared by both transports so the TCP retry asks exactly what the
    /// datagram asked, with a fresh id: reusing the first one would let an
    /// answer aimed at the truncated query be taken for the retry.
    private static func buildQuery(_ name: String,
                                   type: DNSRecordType) throws(ResolveError) -> (UInt16, [UInt8]) {
        // Unpredictable, not merely unique: an off-path attacker who can guess
        // the id can answer before the real server does, and the first answer
        // to arrive is the one believed. So the same source QUIC draws its
        // connection ids from, not a counter and not the clock.
        var idBytes: [UInt8] = [0, 0]
        _ = idBytes.withUnsafeMutableBytes { pg_random_bytes($0.baseAddress, 2) }
        let id = UInt16(idBytes[0]) << 8 | UInt16(idBytes[1])
        var query: [UInt8] = []
        do {
            try DNSMessage.encodeQuery(id: id, name: name, type: type, into: &query)
        } catch {
            throw .badName
        }
        return (id, query)
    }

    /// Asks one server one question, once.
    private static func ask(_ worker: UnsafeMutablePointer<Worker>, _ name: String,
                            type: DNSRecordType, server: String,
                            seconds: Int) async throws(ResolveError) -> Answer {
        let (id, query) = try buildQuery(name, type: type)

        let index: Int
        switch worker.pointee.beginConnect(udp: server, port: worker.pointee.nameserverPort) {
        case .failure: throw .unanswered
        case .success(let i): index = i
        }
        guard let table = worker.pointee.outbound else { throw .cancelled }
        let socket = OutboundSocket(worker: worker, index: index,
                                    generation: table[index].pointee.generation)
        // Closed on every path: a resolver socket is never pooled, and a
        // record left open would hold a descriptor until the worker drained.
        defer { socket.close() }

        do {
            // A query is one datagram and far below any sane MTU, so a short
            // write means the socket refused it rather than took part of it.
            let sent = try query.withUnsafeBytes { try socket.write($0) }
            guard sent == query.count else { throw ResolveError.unanswered }
            try await socket.readable(milliseconds: UInt64(max(1, seconds)) * 1000)

            var buffer = [UInt8](repeating: 0, count: 1232)
            let got = try buffer.withUnsafeMutableBytes { try socket.read(into: $0) }
            guard got > 0 else { return .ignored }
            return believe(buffer, count: got, id: id, name: name, type: type)
        } catch let error as OutboundError {
            throw error == .cancelled ? .cancelled : .unanswered
        } catch let error as ResolveError {
            throw error
        } catch {
            throw .unanswered
        }
    }

    /// Asks the same question again over TCP, which is what a truncated answer
    /// is telling us to do.
    ///
    /// The message is identical; only the framing differs, a two-byte length
    /// in front of it. The reply arrives on a stream rather than in a
    /// datagram, so it comes in as many pieces as TCP feels like and has to be
    /// read to a length rather than to a boundary.
    private static func askOverTCP(_ worker: UnsafeMutablePointer<Worker>, _ name: String,
                                   type: DNSRecordType, server: String,
                                   seconds: Int) async throws(ResolveError) -> Answer {
        let (id, query) = try buildQuery(name, type: type)
        let milliseconds = UInt64(max(1, seconds)) * 1000
        let socket: OutboundSocket
        do {
            // No pool marker here, unlike the UDP path, and deliberately.
            //
            // A marker would keep this connection from being handed to an
            // ordinary caller -- but it is closed below on every path and
            // never released, so it is never in the pool to be handed to
            // anyone. Mutation testing showed the marker could be deleted with
            // nothing failing, and a test written to catch that passed either
            // way, because the table is empty by the time the next caller
            // asks. Dead code that reads as a safeguard is worse than none: it
            // invites the next person to trust it.
            //
            // If this ever calls release() instead of close(), the marker has
            // to come back, and that is the moment it becomes testable.
            socket = try await Worker.connect(worker, host: server,
                                              port: worker.pointee.nameserverPort,
                                              milliseconds: milliseconds)
        } catch {
            throw error == .cancelled ? .cancelled : .unanswered
        }
        defer { socket.close() }

        do {
            var framed: [UInt8] = []
            framed.reserveCapacity(query.count + 2)
            framed.append(UInt8(truncatingIfNeeded: query.count >> 8))
            framed.append(UInt8(truncatingIfNeeded: query.count))
            framed.append(contentsOf: query)
            try await writeAll(socket, framed, milliseconds: milliseconds)

            let header = try await readExactly(socket, 2, milliseconds: milliseconds)
            let length = Int(header[0]) << 8 | Int(header[1])
            // A server naming a length it will not send would otherwise have
            // this waiting until the timeout for bytes that are not coming;
            // the read below is bounded by the same clock either way.
            guard length > 0, length <= 65_535 else { return .ignored }
            let body = try await readExactly(socket, length, milliseconds: milliseconds)
            return believe(body, count: body.count, id: id, name: name, type: type)
        } catch let error as ResolveError {
            throw error
        } catch {
            throw .unanswered
        }
    }

    /// Writes every byte, waiting for writability whenever the socket is full.
    private static func writeAll(_ socket: OutboundSocket, _ bytes: [UInt8],
                                 milliseconds: UInt64) async throws(ResolveError) {
        var sent = 0
        while sent < bytes.count {
            let n: Int
            do {
                n = try bytes.withUnsafeBytes { raw in
                    try socket.write(UnsafeRawBufferPointer(rebasing: raw[sent...]))
                }
            } catch {
                // withUnsafeBytes erases the typed throw, so what arrives here
                // is `any Error` and has to be put back before it can be
                // compared.
                throw (error as? OutboundError) == .cancelled ? .cancelled : .unanswered
            }
            sent += n
            if sent < bytes.count {
                do {
                    try await socket.writable(milliseconds: milliseconds)
                } catch {
                    throw error == .cancelled ? .cancelled : .unanswered
                }
            }
        }
    }

    /// Reads exactly `count` bytes, or fails. A stream splits where it likes,
    /// so a short read is ordinary rather than an error.
    ///
    /// The loop here is **not covered by the tests**, and it is worth saying so
    /// rather than leaving somebody to assume it is. Cutting it to a single
    /// iteration leaves the whole suite green, because a fake nameserver on
    /// loopback cannot be made to deliver a short read: whatever it writes has
    /// arrived in full by the time this wakes from `readable()`, so one read
    /// always drains it. Three attempts at forcing a split -- between the
    /// length and the body, then inside the body -- all failed for that reason.
    ///
    /// It stays because a real network does split a reply across segments and
    /// a resolver that assumed otherwise would fail intermittently against a
    /// real server, which is the worst kind of failure to chase. But it is
    /// unproven code, and if it is ever changed, that change is unguarded.
    private static func readExactly(_ socket: OutboundSocket, _ count: Int,
                                    milliseconds: UInt64) async throws(ResolveError) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            do {
                try await socket.readable(milliseconds: milliseconds)
            } catch {
                throw error == .cancelled ? .cancelled : .unanswered
            }
            let n: Int
            do {
                n = try out.withUnsafeMutableBytes { raw in
                    try socket.read(into: UnsafeMutableRawBufferPointer(rebasing: raw[got...]))
                }
            } catch {
                // The peer closing mid-message is reported as failed(0) by the
                // socket, and half a reply is not a reply. The cast is because
                // withUnsafeMutableBytes erases the typed throw.
                throw (error as? OutboundError) == .cancelled ? .cancelled : .unanswered
            }
            got += n
        }
        return out
    }

    /// Decides whether a datagram answers the question that was asked.
    ///
    /// The id alone is not enough. Checking the echoed question too means an
    /// attacker who guesses the id but not the name gets nothing, and a stale
    /// reply to an earlier question cannot be mistaken for this one.
    private static func believe(_ buffer: [UInt8], count: Int, id: UInt16,
                                name: String, type: DNSRecordType) -> Answer {
        let parsed: DNSResponse
        do {
            parsed = try buffer.withUnsafeBytes { bytes throws(DNSError) in
                try DNSMessage.parse(UnsafeRawBufferPointer(rebasing: bytes[0..<count]))
            }
        } catch {
            // A message this parser will not believe is one to wait past, not
            // one to fail on: the real answer may still be coming.
            return .ignored
        }
        guard parsed.isResponse, parsed.id == id,
              parsed.questionType == type.rawValue,
              sameName(parsed.questionName, name) else { return .ignored }
        if parsed.isTruncated { return .truncated }
        if parsed.responseCode == 3 { return .noSuchName }
        guard parsed.responseCode == 0 else { return .ignored }

        var found: [ResolvedAddress] = []
        for record in parsed.answers {
            if case .address(let bytes) = record.data {
                // A CNAME chain is followed by the server, which returns the
                // alias and the address together; taking every address in the
                // answer picks up the end of that chain without walking it.
                let wants = type == .aaaa ? 16 : 4
                if bytes.count == wants { found.append(ResolvedAddress(bytes: bytes)) }
            }
        }
        return found.isEmpty ? .empty : .addresses(found)
    }

    /// Names differ only by case and by a trailing dot, both of which a server
    /// is free to change when it echoes the question back.
    private static func sameName(_ a: String, _ b: String) -> Bool {
        func normalise(_ s: String) -> [UInt8] {
            var out = Array(s.utf8)
            if out.last == UInt8(ascii: ".") { out.removeLast() }
            for i in out.indices where out[i] >= 65 && out[i] <= 90 { out[i] += 32 }
            return out
        }
        return normalise(a) == normalise(b)
    }

    /// An address written out already, which needs no lookup. Parsed by the
    /// same inet_pton both families go through, so this agrees with what
    /// `connect` will accept rather than having an opinion of its own.
    private static func asLiteral(_ name: String) -> ResolvedAddress? {
        var bytes = [UInt8](repeating: 0, count: 16)
        var family: Int32 = 0
        let ok = name.withCString { host in
            bytes.withUnsafeMutableBytes { out in
                pg_parse_ip(host, out.baseAddress?.assumingMemoryBound(to: UInt8.self), &family)
            }
        }
        guard ok == 0 else { return nil }
        // `family` is 4 or 6, the family and not a length: an IPv4 address is
        // written into the first four of the sixteen bytes.
        guard family == 4 || family == 6 else { return nil }
        return ResolvedAddress(bytes: Array(bytes[0..<(family == 4 ? 4 : 16)]))
    }
}
