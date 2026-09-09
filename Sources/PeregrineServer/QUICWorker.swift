//===----------------------------------------------------------------------===//
// The QUIC socket inside the worker loop.
//
// QUIC joins the same poller as everything else, as one more descriptor. What
// makes it different is that readiness on that descriptor is not readiness of
// a connection: one event may carry datagrams for dozens of connections, and
// a connection may need to send with no event at all because a timer fired.
// So the flow is: drain the socket, service whatever it touched, then let
// every connection put out what it owes.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineQUIC

extension Worker {
    public mutating func registerQUIC() -> Bool {
        guard let quic else { return true }
        guard poller.add(quic.fd, .read, token: PollToken.quic) else {
            Log.error("failed to register the QUIC socket")
            return false
        }
        return true
    }

    /// How long the loop may block. QUIC has timers of its own -- an
    /// acknowledgement owed in milliseconds, a probe that has to fire -- so a
    /// worker serving QUIC cannot sleep for the usual interval.
    public func quicPollTimeout(_ base: Int32) -> Int32 {
        guard let quic else { return base }
        let now = pg_monotonic_ms()
        guard let at = quic.nextTimeout(nowMs: now) else { return base }
        if at <= now { return 0 }
        let wait = at - now
        return wait >= UInt64(base) ? base : Int32(wait)
    }

    mutating func handleQUICEvent(_ mask: PollMask) {
        guard let quic else { return }
        let now = pg_monotonic_ms()
        if mask.wantsRead { quic.readable(nowMs: now) }
        serviceQUIC(nowMs: now)
    }

    /// Services every connection the socket touched, then flushes. Called from
    /// the readiness path and from the timer.
    mutating func serviceQUIC(nowMs: UInt64) {
        guard let quic else { return }
        for connection in quic.takeTouched() {
            drainQUICEvents(connection, nowMs: nowMs)
        }
        if !quic.flush(nowMs: nowMs) {
            // The socket is full. Watch for writability so the rest goes out
            // as soon as it drains, rather than waiting for the next timer.
            _ = poller.modify(quic.fd, [.read, .write], token: PollToken.quic)
        } else {
            _ = poller.modify(quic.fd, .read, token: PollToken.quic)
        }
    }

    /// Runs QUIC timers. Kept separate from `sweepTimeouts`, which is throttled
    /// to once a second: an acknowledgement owed in twenty-five milliseconds
    /// cannot wait that long.
    mutating func quicTick() {
        guard let quic else { return }
        let now = pg_monotonic_ms()
        // Fine enough for an acknowledgement deadline, coarse enough that an
        // idle worker is not walking its connection list per millisecond.
        if now &- lastQUICTick < 4 && !quic.blocked { return }
        lastQUICTick = now
        quic.sweep(nowMs: now)
        for connection in quic.recentlyClosed {
            releaseQUICConnection(connection)
        }
        serviceQUIC(nowMs: now)
    }

    mutating func drainQUICEvents(_ connection: QUICConnection, nowMs: UInt64) {
        for event in connection.takeEvents() {
            switch event.kind {
            case .handshakeComplete:
                Log.debug { line in
                    line.str("quic: connection established, alpn=")
                    connection.selectedALPN.withUnsafeBufferPointer { p in
                        if let base = p.baseAddress { line.bytes(base, p.count) }
                    }
                }
                beginHTTP3(connection)
            case .streamReadable, .streamFinished:
                http3StreamReadable(connection, streamID: event.streamID)
            case .streamReset, .stopSending:
                http3StreamAborted(connection, streamID: event.streamID, code: event.code)
            case .streamWritable:
                http3StreamWritable(connection, streamID: event.streamID)
            case .datagram:
                http3Datagrams(connection)
            case .closed:
                releaseQUICConnection(connection)
            }
        }
    }
}
