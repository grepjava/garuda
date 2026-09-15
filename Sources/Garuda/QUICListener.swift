//===----------------------------------------------------------------------===//
// The QUIC listener.
//
// One UDP socket serves every client, so this is nothing like the TCP path.
// There is no accept: a datagram arrives, its destination connection ID is
// looked up, and either it belongs to a connection or it is the first packet
// of a new one. Everything else -- ordering, retransmission, congestion --
// happens inside QUICConnection.
//
// Each worker binds its own socket with SO_REUSEPORT, so the kernel hashes
// arriving datagrams by four-tuple and a client's packets consistently reach
// the same worker. The cost of that choice is that a client which genuinely
// migrates to a new address may be hashed to a different worker, which has
// never heard of its connection; it recovers by making a new one.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaQUIC

public final class QUICListener {
    /// How many datagrams to take from the socket per syscall.
    static let batchSize = 32
    /// The largest datagram we will accept or send. Anything larger is a
    /// packet the path could not have carried intact.
    static let datagramSize = 1500

    public let fd: Int32
    var config: QUICServerConfig

    /// Connections indexed by every connection ID that reaches them: the one
    /// we issued, and the one the client invented for its first packet, which
    /// it keeps using until it has heard from us.
    var connections: [QUICConnectionID: QUICConnection] = [:]
    /// Owning list, so a connection with several identifiers is only closed
    /// once.
    var live: [QUICConnection] = []

    /// The most datagrams sent in one GSO call. The kernel takes up to 64 and
    /// 64 KiB; 32 full-size datagrams stay inside both.
    static let maxSegments = 32

    var receiveBuffer: UnsafeMutablePointer<UInt8>
    var messages: UnsafeMutablePointer<pg_udp_msg>
    /// Outgoing datagrams, back to back, waiting to go out as one send.
    var sendBuffer: UnsafeMutablePointer<UInt8>
    /// For version negotiation, which is written while receiving and must not
    /// land on top of a batch the socket has not taken yet.
    var negotiationBuffer: UnsafeMutablePointer<UInt8>
    /// Whether datagrams to one peer go out as one send (UDP GSO).
    var gso: Bool
    /// The batch in `sendBuffer`: its length, its datagram size (every one but
    /// the last is exactly this), how many it holds, and where it goes.
    var pendingLength = 0
    var pendingSegment = 0
    var pendingCount = 0
    var pendingPeer = pg_udp_addr()
    var pendingLocal = pg_udp_addr()
    /// Set when the socket refused a datagram; cleared when it takes one.
    public private(set) var blocked = false
    /// Connections that saw traffic in the last batch, in arrival order and
    /// without repeats. Collected rather than handed to a callback because the
    /// worker that services them is a struct and cannot be captured.
    var touched: [QUICConnection] = []
    var touchedSet: Set<ObjectIdentifier> = []
    /// Connections that finished during the last sweep.
    public private(set) var recentlyClosed: [QUICConnection] = []

    public var maxConnections = 4096

    public init(fd: Int32, config: QUICServerConfig) {
        self.fd = fd
        self.config = config
        let stride = QUICListener.datagramSize
        receiveBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: stride * QUICListener.batchSize)
        messages = UnsafeMutablePointer<pg_udp_msg>.allocate(capacity: QUICListener.batchSize)
        sendBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: stride * QUICListener.maxSegments)
        negotiationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: stride)
        gso = pg_udp_gso_supported(fd) != 0
    }

    deinit {
        receiveBuffer.deallocate()
        messages.deallocate()
        sendBuffer.deallocate()
        negotiationBuffer.deallocate()
    }

    public func destroy() {
        connections.removeAll()
        live.removeAll()
        _ = pg_close(fd)
    }

    // MARK: - Receiving

    /// Called when the socket is readable. Connections that saw traffic are
    /// left in `touched` for the caller to service.
    @discardableResult
    public func readable(nowMs: UInt64) -> Int {
        var total = 0
        while true {
            let n = Int(pg_udp_recv_batch(fd, receiveBuffer, QUICListener.datagramSize,
                                          messages, Int32(QUICListener.batchSize)))
            if n <= 0 { break }
            for i in 0..<n {
                let length = Int(messages[i].len)
                if length == 0 { continue }
                let p = receiveBuffer + i * QUICListener.datagramSize
                if let connection = route(p, length, messages[i], nowMs: nowMs) {
                    if touchedSet.insert(ObjectIdentifier(connection)).inserted {
                        touched.append(connection)
                    }
                }
            }
            total += n
            if n < QUICListener.batchSize { break }
        }
        return total
    }

    public func takeTouched() -> [QUICConnection] {
        let out = touched
        touched.removeAll(keepingCapacity: true)
        touchedSet.removeAll(keepingCapacity: true)
        return out
    }

    private func route(_ p: UnsafeMutablePointer<UInt8>, _ length: Int,
                       _ message: pg_udp_msg, nowMs: UInt64) -> QUICConnection? {
        let header = QUICPacket.parseHeader(p, length, localCIDLength: quicLocalCIDLength)
        if !header.isValid { return nil }

        if let connection = connections[header.dcid] {
            // A client is free to change address mid-connection; the
            // connection ID, not the four-tuple, is what identifies it.
            //
            // But a connection ID is in clear on the wire, so anyone who can
            // see one can put it in a UDP header of their own. Believing the
            // source address before the packet has decrypted would let that
            // packet redirect everything this connection has yet to send --
            // the client's replies included -- to wherever the sender liked,
            // for the cost of one forged datagram. So the address moves only
            // once a packet from it has authenticated and proved newer than
            // anything seen before; anything else is answered where the peer
            // already was.
            connection.receive(p, length, ecn: message.ecn, nowMs: nowMs)
            if connection.acceptedNewPacket {
                connection.peerAddress = message.peer
                connection.localAddress = message.local
            }
            return connection
        }

        if header.isLong && !QUICVersion.isSupported(header.version) {
            sendVersionNegotiation(to: message, dcid: header.dcid, scid: header.scid)
            return nil
        }
        if header.type != .initial { return nil }
        // RFC 9000 section 14.1: a client's first flight must fill a datagram,
        // which is what makes the handshake unattractive to an attacker
        // looking for amplification.
        if length < QUICPacket.minimumInitialSize { return nil }
        if live.count >= maxConnections { return nil }

        return accept(p, length, message, header: header, nowMs: nowMs)
    }

    private func accept(_ p: UnsafeMutablePointer<UInt8>, _ length: Int,
                        _ message: pg_udp_msg, header: QUICPacketHeader,
                        nowMs: UInt64) -> QUICConnection? {
        let localCID = QUICConnectionID.random()
        guard let connection = QUICConnection(config: config, version: header.version,
                                              clientDCID: header.dcid,
                                              clientSCID: header.scid,
                                              localCID: localCID, nowMs: nowMs)
        else { return nil }
        connection.peerAddress = message.peer
        connection.localAddress = message.local

        // Both identifiers reach the same connection: the client goes on using
        // the one it invented until it has seen ours.
        connections[localCID] = connection
        connections[header.dcid] = connection
        live.append(connection)

        connection.receive(p, length, ecn: message.ecn, nowMs: nowMs)
        return connection
    }

    /// Tells a client which versions this server speaks. The packet is not
    /// protected and carries no state; a server that kept state here would be
    /// one an attacker could fill up.
    private func sendVersionNegotiation(to message: pg_udp_msg,
                                        dcid: QUICConnectionID, scid: QUICConnectionID) {
        var offset = 0
        // The first byte's low bits are arbitrary, but the high bit must be
        // set so the packet reads as a long header.
        let out = negotiationBuffer
        out[0] = 0x80 | 0x40
        offset = 1
        quicWriteUInt32BE(QUICVersion.negotiation, out + offset)
        offset += 4
        // The identifiers are swapped: what the client used as destination
        // comes back as source.
        scid.withBytes { q, n in
            out[offset] = UInt8(n); offset += 1
            if n > 0 { (out + offset).update(from: q, count: n) }
            offset += n
        }
        dcid.withBytes { q, n in
            out[offset] = UInt8(n); offset += 1
            if n > 0 { (out + offset).update(from: q, count: n) }
            offset += n
        }
        quicWriteUInt32BE(QUICVersion.v1, out + offset)
        offset += 4
        var peer = message.peer
        var local = message.local
        _ = pg_udp_send(fd, out, offset, &peer, &local, 0)
    }

    // MARK: - Sending

    /// Pushes out whatever every connection has ready. Returns false when the
    /// socket refused a datagram and the caller should wait for writability.
    @discardableResult
    public func flush(nowMs: UInt64) -> Bool {
        blocked = false
        var index = 0
        while index < live.count {
            let connection = live[index]
            index += 1
            if !writeAll(connection, nowMs: nowMs) { return false }
        }
        return true
    }

    public func flushOne(_ connection: QUICConnection, nowMs: UInt64) {
        _ = writeAll(connection, nowMs: nowMs)
    }

    /// The most datagrams one connection may send before the others get a
    /// turn. Congestion control is what normally stops this loop, so the cap
    /// is generous; what it is really for is that a connection which believes
    /// it always has something to send must not be able to hold the worker.
    private static let datagramsPerTurn = 4096

    /// Builds a connection's datagrams straight into `sendBuffer`, back to
    /// back, and sends each run of equal-sized ones with a single GSO call.
    ///
    /// A connection moving data produces full-size datagrams, one after
    /// another, all to the same address, and one syscall apiece was half the
    /// worker's CPU: each also paid for its own route lookup and its own
    /// wakeup of the receiver. A run ends at a datagram shorter than the ones
    /// before it (the kernel allows the last to be short), at one longer (it
    /// cannot join, so it starts the next run), or at `maxSegments`.
    private func writeAll(_ connection: QUICConnection, nowMs: UInt64) -> Bool {
        if !sendPending() { return false }
        let perSend = gso ? QUICListener.maxSegments : 1
        var remaining = QUICListener.datagramsPerTurn
        while remaining > 0 {
            remaining -= 1
            // There is always room: a run is sent before it reaches perSend.
            let at = sendBuffer + pendingLength
            let n = connection.nextDatagram(at, QUICListener.datagramSize, nowMs: nowMs)
            if n == 0 { break }
            if pendingLength == 0 {
                pendingPeer = connection.peerAddress
                pendingLocal = connection.localAddress
                pendingSegment = n
            } else if n > pendingSegment {
                let held = pendingLength
                if !sendPending() {
                    // The socket is full with a run still waiting. The new
                    // datagram is dropped, as a datagram the socket refused
                    // always was; loss recovery sends its contents again.
                    return false
                }
                (sendBuffer).update(from: sendBuffer + held, count: n)
                pendingPeer = connection.peerAddress
                pendingLocal = connection.localAddress
                pendingSegment = n
            }
            pendingLength += n
            pendingCount += 1
            if n < pendingSegment || pendingCount == perSend {
                if !sendPending() { return false }
            }
        }
        return sendPending()
    }

    /// Sends the run in `sendBuffer`. False only when the socket is full, and
    /// then the run is kept for the next flush rather than thrown away: the
    /// worker watches for writability and calls back as soon as there is room.
    private func sendPending() -> Bool {
        if pendingLength == 0 { return true }
        // A run built before GSO turned out to be refused.
        if !gso && pendingCount > 1 { return sendPendingOneByOne() }
        let segment = pendingCount > 1 ? UInt16(pendingSegment) : 0
        let sent = pg_udp_send_segments(fd, sendBuffer, pendingLength, segment,
                                        &pendingPeer, &pendingLocal, 0)
        if sent >= 0 {
            clearPending()
            return true
        }
        let error = pg_errno()
        if pg_err_is_again(error) != 0 {
            blocked = true
            return false
        }
        if segment > 0 && pg_udp_gso_refused(error) != 0 {
            // The kernel or the device will not segment. Nothing was wrong
            // with the datagrams, so they go out one at a time, and so does
            // everything after them.
            gso = false
            return sendPendingOneByOne()
        }
        // A hard error says nothing about the socket: an ICMP unreachable for
        // one peer surfaces here. The run is lost, and recovered as loss.
        clearPending()
        return true
    }

    private func sendPendingOneByOne() -> Bool {
        var offset = 0
        while offset < pendingLength {
            let n = min(pendingSegment, pendingLength - offset)
            let sent = pg_udp_send(fd, sendBuffer + offset, n, &pendingPeer, &pendingLocal, 0)
            if sent < 0 && pg_err_is_again(pg_errno()) != 0 {
                // Keep what has not gone, at the front, for the next flush.
                let rest = pendingLength - offset
                sendBuffer.update(from: sendBuffer + offset, count: rest)
                pendingLength = rest
                pendingCount = (rest + pendingSegment - 1) / pendingSegment
                blocked = true
                return false
            }
            offset += n
        }
        clearPending()
        return true
    }

    @inline(__always)
    private func clearPending() {
        pendingLength = 0
        pendingCount = 0
    }

    // MARK: - Timers

    /// The earliest moment any connection needs attention, or nil.
    public func nextTimeout(nowMs: UInt64) -> UInt64? {
        var earliest: UInt64?
        for connection in live {
            guard let at = connection.nextTimeout(nowMs: nowMs) else { continue }
            if earliest == nil || at < earliest! { earliest = at }
        }
        return earliest
    }

    /// Runs timers and reaps connections that have finished. Anything that
    /// closed is left in `recentlyClosed`.
    public func sweep(nowMs: UInt64) {
        recentlyClosed.removeAll(keepingCapacity: true)
        var survivors: [QUICConnection] = []
        survivors.reserveCapacity(live.count)
        for connection in live {
            if let at = connection.nextTimeout(nowMs: nowMs), nowMs >= at {
                connection.onTimeout(nowMs: nowMs)
            }
            if connection.isClosed {
                recentlyClosed.append(connection)
                forget(connection)
            } else {
                survivors.append(connection)
                if connection.hasOutput || !connection.events.isEmpty {
                    if touchedSet.insert(ObjectIdentifier(connection)).inserted {
                        touched.append(connection)
                    }
                }
            }
        }
        live = survivors
    }

    private func forget(_ connection: QUICConnection) {
        connections = connections.filter { $0.value !== connection }
    }

    public func close(_ connection: QUICConnection, nowMs: UInt64) {
        connection.close(0)
        _ = writeAll(connection, nowMs: nowMs)
    }
}
