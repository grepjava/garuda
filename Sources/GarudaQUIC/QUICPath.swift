//===----------------------------------------------------------------------===//
// Paths other than the one the connection sends on (RFC 9000 sections 8.2
// and 9).
//
// QUIC does no I/O, so it never sees an address. The caller does: it hands
// each datagram over with the identifier it gives that datagram's source
// address, 0 for the address the connection sends to and another number for
// any other. A packet that authenticates from another address is either a
// probe -- nothing but PATH_CHALLENGE, PATH_RESPONSE, NEW_CONNECTION_ID and
// PADDING -- or a sign the peer has moved.
//
// A move is not believed until it is proved. Anyone who can rewrite one
// packet's source address could otherwise point the connection's whole
// output at somebody else, so the connection goes on sending to the address
// it has, sends a PATH_CHALLENGE to the new one, and moves only once a
// PATH_RESPONSE with the same bytes comes back (`.pathValidated`). A path
// that does not answer in time has failed (`.pathFailed`), and nothing was
// ever sent down it but challenges.
//
// What goes to an address not yet validated -- challenges, and the answers a
// probe from it is owed, which must go back the way the probe came (RFC 9000
// section 8.2.2) -- is held to three times what arrived from it, as before
// the handshake validated the first address. Each goes in a datagram of its
// own, padded towards 1200 bytes, which is what proves the path can carry
// QUIC at all (section 8.2.1), and none counts against the congestion window
// of the path in use.
//===----------------------------------------------------------------------===//

import GarudaWire
import VegaCrypto

/// What the connection keeps about one address other than the one it sends
/// to.
struct QUICPathState {
    let id: Int
    /// Bytes that arrived from it, and bytes sent to it.
    var received = 0
    var sent = 0
    /// PATH_RESPONSE data owed to it.
    var responses: [[UInt8]] = []
    /// A move to it is being validated: the challenges outstanding, any
    /// answer to which will do, and whether a new one is owed.
    var validating = false
    var challenges: [[UInt8]] = []
    var challengePending = false
    var deadlineMs: UInt64 = 0
    var nextChallengeMs: UInt64 = 0

    var allowance: Int { 3 &* received &- sent }
    var owes: Bool { !responses.isEmpty || challengePending }
}

extension QUICConnection {
    /// The most addresses kept at once, and the most of anything one keeps.
    static let maxPaths = 4
    static let maxPathFrames = 4
    /// The smallest datagram worth sending to an address: a short header, a
    /// frame and the tag.
    static let minimumProbeSize = 64

    // MARK: Receiving

    /// The path a datagram arrived on, made on first sight. Nil for the
    /// path in use.
    func receivingPathIndex() -> Int? {
        // The path last validated is the one in use, whether or not the
        // caller has heard yet.
        guard receivingPath != 0, receivingPath != lastValidatedPath else { return nil }
        if let i = paths.firstIndex(where: { $0.id == receivingPath }) { return i }
        if paths.count == QUICConnection.maxPaths {
            // The oldest that is not being validated goes; failing that,
            // the oldest.
            paths.remove(at: paths.firstIndex { !$0.validating } ?? 0)
        }
        paths.append(QUICPathState(id: receivingPath))
        return paths.count - 1
    }

    /// A packet from the datagram being received has authenticated: the
    /// datagram counts towards what may be sent back down its path, once.
    func pathAuthenticated() {
        guard !datagramAuthenticated else { return }
        datagramAuthenticated = true
        if let i = receivingPathIndex() { paths[i].received &+= receivingCount }
    }

    /// A PATH_CHALLENGE's bytes: answered down the path they came by.
    func pathChallenged(_ data: UnsafePointer<UInt8>) {
        let bytes = [UInt8](UnsafeBufferPointer(start: data, count: 8))
        guard let i = receivingPathIndex() else {
            pathResponsePending.append(bytes)
            return
        }
        if paths[i].responses.count == QUICConnection.maxPathFrames { paths[i].responses.removeFirst() }
        paths[i].responses.append(bytes)
    }

    /// A packet newer than any before, and more than a probe, came from
    /// another address: the peer may have moved there. It is challenged.
    func pathMoved(nowMs: UInt64) {
        guard let i = receivingPathIndex(), !paths[i].validating else { return }
        paths[i].validating = true
        paths[i].challengePending = true
        let pto = recovery.ptoMs(includeMaxAckDelay: true)
        // RFC 9000 section 8.2.4: three probe timeouts, and no less than
        // six of the initial round trip, so a path with a much longer one
        // than the old has its chance.
        paths[i].deadlineMs = nowMs + max(3 * pto, 6 * QUICRecovery.initialRTTMs)
        paths[i].nextChallengeMs = nowMs + pto
    }

    /// A PATH_RESPONSE's bytes. One that answers a challenge validates the
    /// path the challenge went down, whichever path the answer took (RFC
    /// 9000 section 8.2.2); one that answers none is ignored.
    func pathResponded(_ data: UnsafePointer<UInt8>) {
        let i = paths.firstIndex { path in
            path.validating && path.challenges.contains { challenge in
                challenge.withUnsafeBufferPointer { b in (0..<8).allSatisfy { b[$0] == data[$0] } }
            }
        }
        guard let i else { return }
        let id = paths[i].id
        paths.remove(at: i)
        lastValidatedPath = id
        events.append(QUICEvent(.pathValidated, code: UInt64(id)))
    }

    /// The caller now sends to the address of a path just validated. Its
    /// round trip and capacity are its own (RFC 9000 section 9.4), unless
    /// only the port changed, as when a NAT rebinds.
    public func movedToValidatedPath(portOnly: Bool) {
        if !portOnly { recovery.resetForNewPath() }
    }

    // MARK: Time

    /// The earliest deadline of the paths being validated.
    func pathTimeout(_ consider: (UInt64) -> Void) {
        for path in paths where path.validating {
            consider(path.deadlineMs)
            consider(path.nextChallengeMs)
        }
    }

    /// Paths past their deadline fail; the rest are challenged again, with
    /// new bytes, as every challenge must have (RFC 9000 section 8.2.1).
    func pathTimers(nowMs: UInt64) {
        var i = 0
        while i < paths.count {
            if paths[i].validating && nowMs >= paths[i].deadlineMs {
                events.append(QUICEvent(.pathFailed, code: UInt64(paths[i].id)))
                paths.remove(at: i)
                continue
            }
            if paths[i].validating && nowMs >= paths[i].nextChallengeMs {
                paths[i].challengePending = true
                paths[i].nextChallengeMs = nowMs + recovery.ptoMs(includeMaxAckDelay: true)
            }
            i &+= 1
        }
    }

    // MARK: Sending

    /// Whether some other address is owed a datagram it has the allowance
    /// for.
    public var hasProbes: Bool {
        handshakeComplete && status == .connected
            && paths.contains { $0.owes && $0.allowance >= QUICConnection.minimumProbeSize }
    }

    /// Fills `out` with the next datagram for an address other than the one
    /// the connection sends to, and says which: the caller's identifier for
    /// it. A count of 0 when there is none. Called until it returns 0.
    public func nextProbeDatagram(_ out: UnsafeMutablePointer<UInt8>, _ capacity: Int,
                                  nowMs: UInt64) -> (count: Int, path: Int) {
        guard handshakeComplete, status == .connected,
              keys[QUICLevel.application.rawValue].send.isValid else { return (0, 0) }
        for i in paths.indices where paths[i].owes {
            let budget = min(capacity, paths[i].allowance)
            guard budget >= QUICConnection.minimumProbeSize else { continue }
            let n = buildProbe(&paths[i], out, budget)
            if n > 0 { return (n, paths[i].id) }
        }
        return (0, 0)
    }

    /// One packet of PATH_RESPONSE and PATH_CHALLENGE frames for `path`,
    /// padded as far as `budget` and 1200 bytes allow, sealed.
    private func buildProbe(_ path: inout QUICPathState, _ out: UnsafeMutablePointer<UInt8>,
                            _ budget: Int) -> Int {
        let space = QUICLevel.application.rawValue
        let pnLength = packetNumberLength(.application)
        let packetNumber = spaces[space].nextPacketNumber
        out[0] = 0x40 | (currentKeyPhase ? 0x04 : 0x00) | UInt8(pnLength - 1)
        var offset = 1
        peerCID.withBytes { p, n in
            if n > 0 { (out + offset).update(from: p, count: n) }
            offset += n
        }
        let pnOffset = offset
        offset += pnLength
        let limit = min(budget, QUICPacket.minimumInitialSize) - quicAEADTagLength
        var writer = QUICFrameWriter(base: out, offset: offset, limit: limit)
        while let response = path.responses.first, writer.room >= 9 {
            writer.varint(QUICFrameType.pathResponse)
            response.withUnsafeBufferPointer { writer.bytes($0.baseAddress!, 8) }
            path.responses.removeFirst()
        }
        if path.challengePending && writer.room >= 9 {
            var data = [UInt8](repeating: 0, count: 8)
            data.withUnsafeMutableBytes { SecureRandom.fill($0) }
            if path.challenges.count == QUICConnection.maxPathFrames { path.challenges.removeFirst() }
            path.challenges.append(data)
            writer.varint(QUICFrameType.pathChallenge)
            data.withUnsafeBufferPointer { writer.bytes($0.baseAddress!, 8) }
            path.challengePending = false
        }
        if writer.offset == offset { return 0 }
        // PADDING to the limit.
        if writer.room > 0 {
            (out + writer.offset).update(repeating: 0, count: writer.room)
            writer.offset = writer.limit
        }
        guard let sealed = QUICProtect.seal(out, pnOffset: pnOffset, pnLength: pnLength,
                                            payloadLength: writer.offset - offset,
                                            packetNumber: packetNumber,
                                            keys: keys[space].send.keys,
                                            header: keys[space].send.header)
        else { return 0 }
        // Not recorded as sent: it is not in flight on the path in use, and
        // a challenge that is lost is sent again by its timer, not by loss
        // detection.
        spaces[space].nextPacketNumber += 1
        path.sent &+= sealed
        return sealed
    }
}
