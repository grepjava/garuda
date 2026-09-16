//===----------------------------------------------------------------------===//
// DNS messages (RFC 1035), built and read without touching the network.
//
// This half has no I/O in it at all, which is deliberate: the dangerous part of
// a resolver is not sending the question, it is believing the answer. A reply
// arrives from a socket anyone on the path can write to, so every length in it
// is a claim by a stranger, and the parser is the only thing standing between
// that claim and a worker thread.
//
// Two of those claims can hang a worker outright, and both are shaped like
// ordinary data:
//
//   - A compression pointer that points at itself, or at another pointer that
//     points back, is an infinite loop inside the parse. The name never grows,
//     so a cap on the length of a name does not save it. What saves it is that
//     a pointer must land strictly before the pointer making it: the addresses
//     visited then strictly descend, and going round would mean jumping to one
//     already visited, which is above where the walk now is and so forbidden
//     by that same rule.
//   - A record length, or a label length, that runs past the end of the
//     datagram. Every read is bounded against the buffer rather than against
//     the number the message gives for it.
//
// Names come back as text rather than as borrowed bytes, unlike HPACK next
// door. A lookup happens once per connection rather than once per header, and
// the answer outlives the datagram it came in -- it goes into a cache with a
// TTL -- so there is nothing to be won by handing out pointers into a buffer
// that is about to be reused.
//===----------------------------------------------------------------------===//

import GarudaCore

/// Why a message could not be built, or could not be believed.
enum DNSError: Error, Equatable {
    /// The message ended in the middle of something it had promised.
    case truncated
    /// A label of no length, one longer than 63 bytes, or a length whose top
    /// bits are one of the two encodings RFC 1035 reserved and never defined.
    case badLabel
    /// A name longer than the 255 bytes the wire format allows.
    case nameTooLong
    /// A compression pointer that does not go strictly backwards, which is the
    /// only way a chain of them is guaranteed to end.
    case badPointer
}

/// The record types this resolver knows how to read. Anything else parses as
/// `other` rather than failing: a nameserver is entitled to send records we
/// did not ask about, and refusing the whole answer over one of them would be
/// a resolver that stops working when somebody else changes a zone.
enum DNSRecordType: UInt16, Equatable {
    case a = 1
    case cname = 5
    case aaaa = 28
}

/// What a record carried.
enum DNSData: Equatable {
    /// Four bytes for an A record, sixteen for an AAAA, in network order.
    case address([UInt8])
    /// The name this one is an alias for.
    case canonicalName(String)
    /// A type this resolver does not model, kept only so the count adds up.
    case other(UInt16)
}

struct DNSRecord: Equatable {
    /// The name this record is *about*, which after a CNAME is not the name
    /// that was asked for.
    var name: String
    var ttl: UInt32
    var data: DNSData
}

struct DNSResponse: Equatable {
    var id: UInt16
    /// False when a server sent us a question rather than an answer.
    var isResponse: Bool
    /// The answer did not fit in a datagram and must be asked again over TCP.
    /// The records that did fit are still here, and are still not the whole
    /// answer, which is why this is not something a caller may ignore.
    var isTruncated: Bool
    /// RCODE: 0 is success, 3 is the name does not exist.
    var responseCode: UInt8
    /// The question as the server echoed it back, for checking that this reply
    /// answers the question that was asked.
    var questionName: String
    var questionType: UInt16
    var answers: [DNSRecord]
}

enum DNSMessage {
    /// The fixed header: id, flags, and four counts.
    static let headerLength = 12

    // MARK: - Asking

    /// Writes a standard recursive query into `buffer`, replacing whatever was
    /// in it.
    ///
    /// `id` is the caller's to choose and the caller's to check on the way
    /// back. It wants to be unpredictable rather than merely unique: an
    /// off-path attacker who can guess it can answer before the real server
    /// does, and the first answer to arrive is the one that gets believed.
    static func encodeQuery(id: UInt16, name: String, type: DNSRecordType,
                            into buffer: inout [UInt8]) throws(DNSError) {
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(headerLength + name.utf8.count + 6)
        buffer.append(UInt8(truncatingIfNeeded: id >> 8))
        buffer.append(UInt8(truncatingIfNeeded: id))
        // Recursion desired. This is a stub resolver: it asks a full one to do
        // the walking rather than chasing referrals from the root itself.
        buffer.append(0x01)
        buffer.append(0x00)
        buffer.append(0x00); buffer.append(0x01)    // one question
        buffer.append(0x00); buffer.append(0x00)    // no answers
        buffer.append(0x00); buffer.append(0x00)    // no authority records
        buffer.append(0x00); buffer.append(0x00)    // no additional records
        try appendName(name, to: &buffer)
        buffer.append(UInt8(truncatingIfNeeded: type.rawValue >> 8))
        buffer.append(UInt8(truncatingIfNeeded: type.rawValue))
        buffer.append(0x00); buffer.append(0x01)    // class IN
    }

    /// Writes `name` as length-prefixed labels ending in a root label.
    ///
    /// Compression is not used. It saves bytes only when a message repeats a
    /// name, and a question contains exactly one.
    private static func appendName(_ name: String, to buffer: inout [UInt8]) throws(DNSError) {
        var label: [UInt8] = []
        label.reserveCapacity(63)
        var total = 1                      // the root label
        var labels = 0

        func flush() throws(DNSError) {
            // An empty label is a doubled dot or a leading one. Only the root
            // label is empty, and it is written once, at the end.
            guard !label.isEmpty, label.count <= 63 else { throw .badLabel }
            total += 1 + label.count
            guard total <= 255 else { throw .nameTooLong }
            buffer.append(UInt8(label.count))
            buffer.append(contentsOf: label)
            label.removeAll(keepingCapacity: true)
            labels += 1
        }

        for byte in name.utf8 {
            if byte == UInt8(ascii: ".") {
                try flush()
            } else {
                label.append(byte)
            }
        }
        // A trailing dot is the root and has already been accounted for; what
        // is left over otherwise is the last label.
        if !label.isEmpty { try flush() }
        guard labels > 0 else { throw .badLabel }
        buffer.append(0)
    }

    // MARK: - Believing

    /// Reads a reply. Everything it returns has been bounded against the
    /// buffer, not against the lengths the message claims for itself.
    ///
    /// It does not check the id or that this is a response at all: that is the
    /// resolver's to do, since only the resolver knows what it asked.
    static func parse(_ bytes: UnsafeRawBufferPointer) throws(DNSError) -> DNSResponse {
        guard bytes.count >= headerLength else { throw .truncated }
        let id = be16(bytes, 0)
        let flags = be16(bytes, 2)
        let questionCount = Int(be16(bytes, 4))
        let answerCount = Int(be16(bytes, 6))

        var at = headerLength
        var questionName = ""
        var questionType: UInt16 = 0
        for question in 0..<questionCount {
            let (name, next) = try readName(bytes, at)
            at = next
            guard at + 4 <= bytes.count else { throw .truncated }
            if question == 0 {
                questionName = name
                questionType = be16(bytes, at)
            }
            at += 4
        }

        var answers: [DNSRecord] = []
        // Bounded by what is actually here, not by the count in the header: a
        // header claiming 65,535 answers in a 40-byte datagram would otherwise
        // reserve for all of them before reading the first.
        answers.reserveCapacity(min(answerCount, bytes.count / 12))
        for _ in 0..<answerCount {
            // A record whose owner name runs off the end is not an answer.
            let (name, afterName) = try readName(bytes, at)
            at = afterName
            guard at + 10 <= bytes.count else { throw .truncated }
            let type = be16(bytes, at)
            let ttl = UInt32(be16(bytes, at + 4)) << 16 | UInt32(be16(bytes, at + 6))
            let length = Int(be16(bytes, at + 8))
            at += 10
            guard at + length <= bytes.count else { throw .truncated }
            let data: DNSData
            switch type {
            case DNSRecordType.a.rawValue where length == 4,
                 DNSRecordType.aaaa.rawValue where length == 16:
                data = .address(Array(bytes[at..<(at + length)]))
            case DNSRecordType.cname.rawValue:
                // Read within the record, but a name may point outside it, so
                // this is bounded by the buffer like every other read.
                data = .canonicalName(try readName(bytes, at).0)
            default:
                data = .other(type)
            }
            at += length
            answers.append(DNSRecord(name: name, ttl: ttl, data: data))
        }

        return DNSResponse(id: id,
                           isResponse: flags & 0x8000 != 0,
                           isTruncated: flags & 0x0200 != 0,
                           responseCode: UInt8(flags & 0x000f),
                           questionName: questionName,
                           questionType: questionType,
                           answers: answers)
    }

    @inline(__always)
    private static func be16(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    /// Reads a name, following compression pointers, and returns it with the
    /// offset just past the name *as it appeared in the record* -- which is
    /// past the first pointer, not past wherever that pointer led.
    private static func readName(_ bytes: UnsafeRawBufferPointer,
                                 _ start: Int) throws(DNSError) -> (String, Int) {
        var name: [UInt8] = []
        var at = start
        var after = -1
        // A pointer must land strictly before the pointer that made the jump.
        // That is sufficient on its own: the addresses visited strictly
        // descend, so the walk cannot revisit one, because anything already
        // visited lies above where it now is.
        //
        // There was a second condition here -- that each jump also go further
        // back than the last -- until mutation testing showed no message could
        // reach it. Two guards over one hazard hide each other, and one that
        // cannot fire reads as safety while providing none, so it is gone
        // rather than kept and excused.

        while true {
            guard at < bytes.count else { throw .truncated }
            let length = Int(bytes[at])
            if length == 0 {
                at += 1
                if after < 0 { after = at }
                break
            }
            switch length & 0xc0 {
            case 0x00:
                guard at + 1 + length <= bytes.count else { throw .truncated }
                if !name.isEmpty { name.append(UInt8(ascii: ".")) }
                name.append(contentsOf: bytes[(at + 1)..<(at + 1 + length)])
                guard name.count <= 255 else { throw .nameTooLong }
                at += 1 + length
            case 0xc0:
                guard at + 2 <= bytes.count else { throw .truncated }
                let target = (length & 0x3f) << 8 | Int(bytes[at + 1])
                // Recorded before the first jump: what follows the name in the
                // record is what follows the pointer, wherever it leads.
                if after < 0 { after = at + 2 }
                guard target < at else { throw .badPointer }
                at = target
            default:
                // 0x40 and 0x80 are the two label kinds RFC 1035 reserved and
                // nothing ever defined. A message using one is not a message
                // this parser can claim to understand.
                throw .badLabel
            }
        }
        return (String(decoding: name, as: UTF8.self), after)
    }
}
