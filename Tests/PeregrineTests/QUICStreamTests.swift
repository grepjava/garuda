//===----------------------------------------------------------------------===//
// The parts of QUIC that are about bookkeeping rather than bytes on the wire:
// what an acknowledgement means for what is still owed, what a receiver is
// obliged to hold on to, and reading a key phase before spending the one
// decryption attempt a packet gets.
//
// These are all failure modes that a working connection never reaches. They
// need loss, reordering, overlap and a key update to show themselves, so they
// are driven directly rather than through a connection.
//===----------------------------------------------------------------------===//

import CPeregrine
import Testing
@testable import PeregrineCore
@testable import PeregrineQUIC

// MARK: - What an acknowledgement means

@Test("a range set removes exactly the range it is given")
func byteRangeSubtraction() {
    var ranges = QUICByteRanges()
    ranges.add(0, 100)
    ranges.add(200, 300)

    // A hole in the middle splits the range it falls inside.
    ranges.subtract(40, 60)
    #expect(ranges.count == 3)
    #expect(ranges.ranges[0] == (low: 0, high: 40))
    #expect(ranges.ranges[1] == (low: 60, high: 100))
    #expect(ranges.ranges[2] == (low: 200, high: 300))

    // Overlapping the front, overlapping the back, covering one whole.
    ranges.subtract(0, 20)
    #expect(ranges.ranges[0] == (low: 20, high: 40))
    ranges.subtract(280, 400)
    #expect(ranges.ranges[2] == (low: 200, high: 280))
    ranges.subtract(0, 100)
    #expect(ranges.count == 1)
    #expect(ranges.ranges[0] == (low: 200, high: 280))

    // A range that touches nothing changes nothing.
    ranges.subtract(1000, 2000)
    #expect(ranges.count == 1)
}

@Test("an acknowledgement does not erase an earlier retransmission")
func ackKeepsEarlierLoss() {
    var send = QUICSendStream()
    var bytes = [UInt8](repeating: 0, count: 200)
    for i in 0..<200 { bytes[i] = UInt8(truncatingIfNeeded: i) }
    bytes.withUnsafeBufferPointer { send.write($0.baseAddress!, 200) }
    send.sent = 200

    // Two packets: the first is lost, the second arrives.
    send.declareLost(0, 100)
    send.acknowledge(100, 200)

    // The peer is still missing 0..100, and an acknowledgement of 100..200
    // says nothing whatever about it.
    #expect(!send.lost.isEmpty)
    #expect(send.lost.ranges[0] == (low: 0, high: 100))
    // The bytes are still here to send again: the buffer is trimmed from the
    // front, and the front has not been acknowledged.
    #expect(send.base == 0)
    #expect(send.data.readableBytes == 200)

    // Once it does arrive, nothing is owed and the buffer goes.
    send.acknowledge(0, 100)
    #expect(send.lost.isEmpty)
    #expect(send.base == 200)
    send.destroy()
}

@Test("data acknowledged in another packet is not owed again")
func lossAfterAckOwesNothing() {
    var send = QUICSendStream()
    var bytes = [UInt8](repeating: 7, count: 100)
    bytes.withUnsafeBufferPointer { send.write($0.baseAddress!, 100) }
    send.sent = 100
    send.acknowledge(50, 100)
    send.declareLost(0, 100)
    #expect(send.lost.ranges.count == 1)
    #expect(send.lost.ranges[0] == (low: 0, high: 50))
    send.destroy()
}

// MARK: - Reassembly

@Test("overlapping fragments are held once, inside the window")
func overlappingFragmentsAreBounded() {
    var receive = QUICReceiveStream()
    receive.limit = 4096

    // Every fragment is inside the window and every one has a distinct
    // offset, which is the whole of what flow control checks. Kept whole they
    // would be two megabytes; kept as the bytes they actually add they are
    // three kilobytes, because that is all the window can describe.
    var chunk = [UInt8](repeating: 0, count: 1024)
    for start in 1...2048 {
        for i in 0..<1024 { chunk[i] = UInt8(truncatingIfNeeded: start + i) }
        let outcome = chunk.withUnsafeBufferPointer {
            receive.accept(offset: UInt64(start), $0.baseAddress!, 1024, fin: false)
        }
        #expect(outcome == .ok)
    }
    let held = receive.early.reduce(0) { $0 + $1.bytes.count }
    #expect(held <= 4096)

    // What was kept is still the right bytes: the one missing byte at the
    // front releases the whole run, in order.
    var first: [UInt8] = [0]
    let outcome = first.withUnsafeBufferPointer {
        receive.accept(offset: 0, $0.baseAddress!, 1, fin: false)
    }
    #expect(outcome == .ok)
    #expect(receive.received == 3072)
    #expect(receive.early.isEmpty)
    let ready = [UInt8](UnsafeBufferPointer(start: receive.ready.readPointer,
                                            count: receive.ready.readableBytes))
    #expect(ready.count == 3072)
    var correct = true
    for i in 0..<ready.count where ready[i] != UInt8(truncatingIfNeeded: i) {
        correct = false
    }
    #expect(correct)
    receive.destroy()
}

@Test("a fragment already held is not stored a second time")
func duplicateFragmentIsNotStored() {
    var receive = QUICReceiveStream()
    receive.limit = 1024
    let chunk = [UInt8](repeating: 9, count: 100)
    for _ in 0..<10 {
        _ = chunk.withUnsafeBufferPointer {
            receive.accept(offset: 10, $0.baseAddress!, 100, fin: false)
        }
    }
    #expect(receive.early.count == 1)
    #expect(receive.early.reduce(0) { $0 + $1.bytes.count } == 100)
    receive.destroy()
}

@Test("a fragment reaching past one already held keeps only the new part")
func extendingFragmentKeepsOnlyTheNewPart() {
    var receive = QUICReceiveStream()
    receive.limit = 1024
    var chunk = [UInt8](repeating: 0, count: 200)
    for i in 0..<200 { chunk[i] = UInt8(truncatingIfNeeded: 10 + i) }

    _ = chunk.withUnsafeBufferPointer {
        receive.accept(offset: 10, $0.baseAddress!, 100, fin: false)
    }
    _ = chunk.withUnsafeBufferPointer {
        receive.accept(offset: 10, $0.baseAddress!, 200, fin: false)
    }
    #expect(receive.early.reduce(0) { $0 + $1.bytes.count } == 200)

    var head = [UInt8](repeating: 0, count: 10)
    for i in 0..<10 { head[i] = UInt8(truncatingIfNeeded: i) }
    _ = head.withUnsafeBufferPointer {
        receive.accept(offset: 0, $0.baseAddress!, 10, fin: false)
    }
    #expect(receive.received == 210)
    let ready = [UInt8](UnsafeBufferPointer(start: receive.ready.readPointer,
                                            count: receive.ready.readableBytes))
    var correct = ready.count == 210
    for i in 0..<ready.count where ready[i] != UInt8(truncatingIfNeeded: i) {
        correct = false
    }
    #expect(correct)
    receive.destroy()
}

// MARK: - Key phase

@Test("the key phase is readable before the packet is opened")
func keyPhaseBeforeOpening() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 { secret[i] = UInt8(truncatingIfNeeded: i &* 11 &+ 5) }
    var direction = try #require(secret.withUnsafeBufferPointer {
        quicDirection(secret: $0.baseAddress!, secretLen: 32,
                      cipher: .aes128GCMSHA256, version: QUICVersion.v1)
    })
    defer { direction.destroy() }

    let headerLength = 13
    let payloadLength = 200
    let total = headerLength + payloadLength + quicAEADTagLength
    var packet = [UInt8](repeating: 0, count: total)
    packet[0] = 0x47                        // short header, key phase, 4-byte pn
    for i in 1..<9 { packet[i] = UInt8(i) } // connection ID
    for i in headerLength..<(headerLength + payloadLength) {
        packet[i] = UInt8(truncatingIfNeeded: i)
    }
    let plaintext = Array(packet[headerLength..<(headerLength + payloadLength)])
    let sealed: Int? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.seal(buf.baseAddress!, pnOffset: 9, pnLength: 4,
                         payloadLength: payloadLength, packetNumber: 4242,
                         keys: direction.keys, header: direction.header)
    }
    #expect(sealed == total)
    let onTheWire = packet

    // Unprotecting answers the question the key phase asks without committing
    // to any packet protection key. That is what lets a key update be
    // recognised before the one in-place decryption attempt is spent on the
    // wrong keys.
    var unprotected: QUICProtect.Unprotected? = nil
    packet.withUnsafeMutableBufferPointer { buf in
        unprotected = QUICProtect.unprotect(buf.baseAddress!, pnOffset: 9,
                                            end: total, largestReceived: 4241,
                                            header: direction.header)
    }
    let un = try #require(unprotected)
    #expect(un.keyPhase == true)
    #expect(un.packetNumber == 4242)
    #expect(un.pnLength == 4)

    // Putting the header back leaves the packet exactly as it arrived, so
    // deciding which keys apply costs the attempt nothing.
    packet.withUnsafeMutableBufferPointer { QUICProtect.restore($0.baseAddress!, un) }
    #expect(packet == onTheWire)

    var reopened: QUICProtect.Unprotected? = nil
    packet.withUnsafeMutableBufferPointer { buf in
        reopened = QUICProtect.unprotect(buf.baseAddress!, pnOffset: 9,
                                         end: total, largestReceived: 4241,
                                         header: direction.header)
    }
    let again = try #require(reopened)
    #expect(again.keyPhase == true)
    let opened: QUICProtect.Opened? = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.openBody(buf.baseAddress!, again, end: total,
                             keys: direction.keys)
    }
    let result = try #require(opened)
    #expect([UInt8](UnsafeBufferPointer(start: result.payload,
                                        count: result.payloadLength)) == plaintext)
}

@Test("a packet with the phase bit clear reads as the other phase")
func keyPhaseClearIsReadable() throws {
    var secret = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 { secret[i] = UInt8(truncatingIfNeeded: i &* 3 &+ 1) }
    var direction = try #require(secret.withUnsafeBufferPointer {
        quicDirection(secret: $0.baseAddress!, secretLen: 32,
                      cipher: .aes128GCMSHA256, version: QUICVersion.v1)
    })
    defer { direction.destroy() }

    let headerLength = 13
    let total = headerLength + 64 + quicAEADTagLength
    var packet = [UInt8](repeating: 0, count: total)
    packet[0] = 0x43                        // short header, phase clear
    for i in 1..<9 { packet[i] = UInt8(i) }
    _ = packet.withUnsafeMutableBufferPointer { buf in
        QUICProtect.seal(buf.baseAddress!, pnOffset: 9, pnLength: 4,
                         payloadLength: 64, packetNumber: 1,
                         keys: direction.keys, header: direction.header)
    }
    var unprotected: QUICProtect.Unprotected? = nil
    packet.withUnsafeMutableBufferPointer { buf in
        unprotected = QUICProtect.unprotect(buf.baseAddress!, pnOffset: 9,
                                            end: total, largestReceived: 0,
                                            header: direction.header)
    }
    let un = try #require(unprotected)
    #expect(un.keyPhase == false)
}
