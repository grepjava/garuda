// WebTransport session handle kept on the connection slab. The ASGI
// WebTransport API is gone; sessions are released without a Python task.

import GarudaCore
import GarudaQUIC

public final class WTSession {
    public let sessionID: UInt64
    public var closeCode: UInt32 = 0
    public var closeReason = ByteBuffer()
    public var disconnectDelivered = false

    init(sessionID: UInt64) {
        self.sessionID = sessionID
    }
}

extension Worker {
    mutating func releaseWebTransport(_ slot: Int) {
        let c = table[slot]
        c.pointee.wt?.closeReason.destroy()
        c.pointee.wt = nil
    }

    func wtOutstanding(_ slot: Int) -> Int {
        _ = slot
        return 0
    }

    mutating func adoptWebTransportStream(_ connectionSlot: Int, _ h3: H3Connection,
                                          _ streamID: UInt64, sessionID: UInt64,
                                          bidirectional: Bool) -> Int {
        _ = connectionSlot
        _ = h3
        _ = streamID
        _ = sessionID
        _ = bidirectional
        return -1
    }

    mutating func wtStreamReadable(_ sessionSlot: Int, _ h3: H3Connection,
                                   _ streamID: UInt64) {
        _ = sessionSlot
        _ = h3
        _ = streamID
    }

    mutating func wtStreamAborted(_ sessionSlot: Int, _ h3: H3Connection,
                                  _ streamID: UInt64) {
        _ = sessionSlot
        _ = h3
        _ = streamID
    }

    mutating func wtStreamWritable(_ sessionSlot: Int) {
        _ = sessionSlot
    }

    mutating func wtDatagram(_ connectionSlot: Int, _ h3: H3Connection,
                             _ payload: [UInt8]) {
        _ = connectionSlot
        _ = h3
        _ = payload
    }

    mutating func readWTCapsules(_ sessionSlot: Int, _ h3: H3Connection,
                                 _ stream: QUICStream) {
        _ = sessionSlot
        _ = h3
        _ = stream
    }

    mutating func endWebTransportSession(_ slot: Int, clean: Bool) {
        _ = clean
        releaseWebTransport(slot)
    }
}
