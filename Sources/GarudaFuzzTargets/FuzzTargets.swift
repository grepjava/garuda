//===----------------------------------------------------------------------===//
// What a fuzzer feeds, and what has to remain true afterwards.
//
// Every parser here reads bytes chosen by whoever is on the other end of a
// socket, which is the definition of untrusted input: the request head and
// the chunked framing under it, an HPACK or QPACK block, a WebSocket frame
// header, a QUIC packet and the frames and ClientHello inside one, a whole
// HTTP/2 connection -- or, from a server Garuda connects to, a response head,
// a Redis reply or a PostgreSQL backend message. A crash in any of them is
// reachable from the network.
//
// "Does not crash" is the weakest thing a fuzzer can check and the easiest to
// pass by accident, so each target also states an invariant that a corrupted
// parse would break even when nothing traps:
//
//   * every slice a parse hands back points inside the bytes it was given --
//     the slices are offsets into the caller's buffer, and one that runs past
//     the end is how a parser turns a malformed request into a read of
//     somebody else's memory;
//   * a decoder that resumes gives the same answer however the input was
//     split, because on a socket the splits are the peer's choice;
//   * a parse that succeeds from a longer buffer succeeds the same way from
//     exactly the bytes it claimed to consume, which is what makes a
//     pipelined stream separable at all;
//   * whatever a connection sends back, however it was provoked, is legible
//     to a client, and the connection still ends when the client goes.
//
// The targets are a library rather than part of the driver so that the same
// code runs two ways: `pgfuzz` mutates inputs against it, and the test suite
// replays the checked-in corpus through it, which is what stops a fixed crash
// from coming back.
//===----------------------------------------------------------------------===//

import Garuda
import GarudaWire
import GarudaQUIC
import VegaPostgres
import VegaRedis

public enum FuzzTarget: String, CaseIterable, Sendable {
    case httpHead = "http-head"
    case httpResponse = "http-response"
    case chunked = "chunked"
    case hpack = "hpack"
    case qpack = "qpack"
    case websocket = "websocket"
    case quicPacket = "quic-packet"
    case quicFrames = "quic-frames"
    case tlsHello = "tls-hello"
    case h2 = "h2"
    case h3 = "h3"
    case json = "json"
    case resp = "resp"
    case postgres = "postgres"

    /// Whether an input runs a connection, which takes milliseconds where a
    /// parse takes microseconds.
    public var isConnection: Bool {
        switch self {
        case .quicFrames, .tlsHello, .h2, .h3: return true
        default: return false
        }
    }
}

public enum Fuzz {

    /// Runs one input through one target.
    ///
    /// Returns nil when every invariant held, or a description of the one that
    /// did not. A trap or a segmentation fault is the other kind of answer and
    /// needs no return value.
    public static func run(_ target: FuzzTarget,
                           _ input: UnsafePointer<UInt8>, _ count: Int) -> String? {
        switch target {
        case .httpHead: return httpHead(input, count)
        case .httpResponse: return httpResponse(input, count)
        case .chunked: return chunked(input, count)
        case .hpack: return hpack(input, count)
        case .qpack: return qpack(input, count)
        case .websocket: return websocket(input, count)
        case .quicPacket: return quicPacket(input, count)
        case .quicFrames: return quicFrames(input, count)
        case .tlsHello: return tlsHello(input, count)
        case .h2: return h2(input, count)
        case .h3: return h3(input, count)
        case .json: return json(input, count)
        case .resp: return resp(input, count)
        case .postgres: return postgres(input, count)
        }
    }

    @inlinable
    public static func run(_ target: FuzzTarget, _ bytes: [UInt8]) -> String? {
        // A zero-length Array has no base address, and a parser is entitled to
        // hold the pointer it is given even when there is nothing to read
        // through it, so an empty input gets one byte of real storage.
        var padded = bytes
        if padded.isEmpty { padded = [0] }
        return padded.withUnsafeBufferPointer { buf in
            run(target, buf.baseAddress!, bytes.count)
        }
    }

    // MARK: - RESP

    /// Limits far below a connection's, so short inputs reach every one of them.
    private static var respLimits: RedisParser.Limits {
        var limits = RedisParser.Limits()
        limits.maxBulkBytes = 64
        limits.maxElements = 32
        limits.maxDepth = 4
        limits.maxLineBytes = 48
        return limits
    }

    private enum RespRun: Equatable {
        case values([RedisValue], consumed: Int, pending: Bool)
        /// How far a failed parse got is not compared: a connection is closed
        /// on the error, and a call that throws has consumed what it consumed
        /// without saying so.
        case failed(RedisProtocolError)
    }

    /// Every reply in `n` bytes, offered `step` more bytes at a time.
    private static func respReplies(_ base: UnsafePointer<UInt8>, _ n: Int, step: Int) -> RespRun? {
        var parser = RedisParser(limits: respLimits)
        var values: [RedisValue] = []
        var start = 0
        var end = 0
        while end < n {
            end = min(n, end &+ step)
            while start < end {
                let outcome: RedisParser.Outcome
                let consumed: Int
                do {
                    (outcome, consumed) = try parser.parse(base + start, end - start)
                } catch {
                    return .failed(error)
                }
                if consumed < 0 || consumed > end - start { return nil }
                start += consumed
                guard case .value(let value) = outcome else { break }
                values.append(value)
            }
        }
        return .values(values, consumed: start, pending: parser.isMidReply)
    }

    private static func resp(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        guard let whole = respReplies(base, n, step: n == 0 ? 1 : n) else {
            return "a parse consumed more than it was given"
        }
        // Where a read splits a reply is the server's and the network's choice.
        guard let piecewise = respReplies(base, n, step: 1) else {
            return "a one-byte parse consumed more than it was given"
        }
        if whole != piecewise {
            return "whole, \(whole); byte by byte, \(piecewise)"
        }
        // A reply read from a longer buffer reads the same from exactly the
        // bytes it consumed: that is what lets the next reply start there.
        var parser = RedisParser(limits: respLimits)
        if let (outcome, consumed) = try? parser.parse(base, n), case .value(let value) = outcome {
            var again = RedisParser(limits: respLimits)
            guard let (exact, used) = try? again.parse(base, consumed), exact == .value(value), used == consumed else {
                return "a reply of \(consumed) bytes does not read the same from its own bytes"
            }
        }
        return nil
    }

    // MARK: - PostgreSQL backend messages

    /// A stream of backend messages, as a connection reads them: framed one
    /// after another, each body handed to the reader its type byte names.
    private static func postgres(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        // A limit derived from the length, so short inputs land on both sides
        // of it, and the same on every run of the same input.
        let maxLength = 16 &+ (n & 511)
        var columns: [PostgresColumn] = []
        var values: [Range<Int>?] = []
        var offset = 0
        while offset < n {
            let framed = PostgresBackend.frame(base + offset, n - offset, maxLength: maxLength)
            guard case .frame(let frame) = framed else { break }
            if frame.bodyOffset != 5 || frame.bodyLength < 0 || frame.total > n - offset {
                return "a frame of \(frame.bodyOffset)+\(frame.bodyLength) at \(offset) of \(n) bytes"
            }
            // The connection frames whatever its buffer holds, so the same
            // message must frame the same from exactly its own bytes, and not
            // at all from one byte fewer.
            if PostgresBackend.frame(base + offset, frame.total, maxLength: maxLength) != framed {
                return "a message of \(frame.total) bytes frames differently from its own bytes"
            }
            if PostgresBackend.frame(base + offset, frame.total - 1, maxLength: maxLength) != .incomplete {
                return "a message of \(frame.total) bytes frames from \(frame.total - 1)"
            }
            let body = base + offset + frame.bodyOffset
            if let bad = postgresMessage(frame.type, body, frame.bodyLength, &columns, &values) {
                return bad
            }
            offset += frame.total
        }
        return nil
    }

    private static func postgresMessage(_ type: UInt8, _ body: UnsafePointer<UInt8>, _ length: Int,
                                        _ columns: inout [PostgresColumn],
                                        _ values: inout [Range<Int>?]) -> String? {
        let reader = PostgresReader(body, length)
        switch type {
        case UInt8(ascii: "R"): _ = try? PostgresBackend.authentication(reader)
        case UInt8(ascii: "S"): _ = try? PostgresBackend.parameterStatus(reader)
        case UInt8(ascii: "K"): _ = try? PostgresBackend.backendKeyData(reader)
        case UInt8(ascii: "A"): _ = try? PostgresBackend.notification(reader)
        case UInt8(ascii: "Z"): _ = try? PostgresBackend.readyForQuery(reader)
        case UInt8(ascii: "C"): _ = try? PostgresBackend.commandComplete(reader)
        case UInt8(ascii: "E"), UInt8(ascii: "N"): _ = try? PostgresBackend.errorFields(reader)
        case UInt8(ascii: "t"): _ = try? PostgresBackend.parameterDescription(reader)
        case UInt8(ascii: "T"):
            if let described = try? PostgresBackend.rowDescription(reader) { columns = described }
        case UInt8(ascii: "D"):
            guard (try? PostgresBackend.dataRow(reader, into: &values)) != nil else { return nil }
            let bytes = Array(UnsafeBufferPointer(start: body, count: length))
            for (i, range) in values.enumerated() {
                guard let range else { continue }
                // A value is read through its range, so one outside the body
                // is a read of whatever follows the message in the buffer.
                if range.lowerBound < 0 || range.upperBound > length {
                    return "column \(i) is \(range) of a \(length)-byte row"
                }
                let column = i < columns.count ? columns[i] : nil
                if let bad = postgresValue(bytes[range], column) { return "column \(i): \(bad)" }
            }
        case UInt8(ascii: "d"):
            // COPY data, in the text format.
            let bytes = Array(UnsafeBufferPointer(start: body, count: length))
            for row in PostgresCopyText.rows(bytes[...]) {
                // A row read from the server is written back unchanged by
                // a client that copies between tables, so the encoding has to
                // invert the decoding.
                var line = PostgresCopyText.encode(row)
                line.removeLast()
                let again = PostgresCopyText.decode(line[...])
                if again != row { return "the COPY row \(row) reads back as \(again)" }
            }
        default:
            break
        }
        return nil
    }

    /// A column's value, through every decoder that could be handed it.
    private static func postgresValue(_ bytes: ArraySlice<UInt8>, _ column: PostgresColumn?) -> String? {
        if column?.binary ?? true {
            _ = PostgresBinary.integer(bytes)
            _ = PostgresBinary.float8(bytes)
            _ = PostgresBinary.float4(bytes)
            _ = PostgresBinary.bool(bytes)
            _ = PostgresBinary.text(bytes, type: column?.typeOID ?? 25)
            _ = PostgresBinary.dateDays(bytes)
            _ = PostgresBinary.timeMicroseconds(bytes)
            _ = PostgresBinary.interval(bytes)
            _ = PostgresBinary.numeric(bytes)
            _ = PostgresBinary.timestampMicroseconds(bytes)
        }
        // An array in the text format. What parses must survive being
        // written back as a parameter: that is how a client sends an array.
        let text = String(decoding: bytes, as: UTF8.self)
        if let elements = PostgresArrayText.parse(text) {
            let formatted = PostgresArrayText.format(elements)
            guard let again = PostgresArrayText.parse(formatted), again == elements else {
                return "the array \(elements) does not read back from \(formatted)"
            }
        }
        return nil
    }

    // MARK: - JSON

    /// Any JSON document, as a value. Decoding into it uses every container
    /// the coder has, and gives the round trip something to compare.
    indirect enum Value: Codable, Equatable {
        case null
        case bool(Bool)
        case integer(Int64)
        case double(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: any Decoder) throws {
            if var unkeyed = try? decoder.unkeyedContainer() {
                var items: [Value] = []
                while !unkeyed.isAtEnd { items.append(try unkeyed.decode(Value.self)) }
                self = .array(items)
                return
            }
            if let keyed = try? decoder.container(keyedBy: Key.self) {
                var members: [String: Value] = [:]
                for key in keyed.allKeys {
                    members[key.stringValue] = try keyed.decode(Value.self, forKey: key)
                }
                self = .object(members)
                return
            }
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .null
            } else if let value = try? single.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? single.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? single.decode(Double.self) {
                self = .double(value)
            } else {
                self = .string(try single.decode(String.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .null:
                var single = encoder.singleValueContainer()
                try single.encodeNil()
            case .bool(let value):
                var single = encoder.singleValueContainer()
                try single.encode(value)
            case .integer(let value):
                var single = encoder.singleValueContainer()
                try single.encode(value)
            case .double(let value):
                var single = encoder.singleValueContainer()
                try single.encode(value)
            case .string(let value):
                var single = encoder.singleValueContainer()
                try single.encode(value)
            case .array(let items):
                var unkeyed = encoder.unkeyedContainer()
                for item in items { try unkeyed.encode(item) }
            case .object(let members):
                var keyed = encoder.container(keyedBy: Key.self)
                // In a settled order, so that the round trip compares values
                // rather than the order a dictionary happens to hold them in.
                for name in members.keys.sorted() {
                    try keyed.encode(members[name]!, forKey: Key(stringValue: name)!)
                }
            }
        }
    }

    /// A document that decodes must encode again, and read back as the same
    /// value: the coder reads request bodies, which are whatever the peer
    /// chose to send.
    private static func json(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        let bytes = Array(UnsafeBufferPointer(start: base, count: n))
        guard let value = try? JSONCoder.decode(Value.self, from: bytes) else { return nil }
        guard let written = try? JSONCoder.encode(value) else {
            return "a document that decoded could not be encoded again"
        }
        guard let again = try? JSONCoder.decode(Value.self, from: written) else {
            return "what the encoder wrote did not decode: "
                + String(decoding: written, as: UTF8.self)
        }
        if again != value {
            return "the value changed through encode and decode: "
                + String(decoding: written, as: UTF8.self)
        }
        return nil
    }

    // MARK: - HTTP/1 request head

    private static let maxHeaders = 64
    private static let maxHeadSize = 16 * 1024

    private static func httpHead(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        let headers = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: maxHeaders)
        defer { headers.deallocate() }
        var head = HTTPRequestHead()
        let result = HTTPParser.parse(base, n, maxHeadSize: maxHeadSize,
                                      maxHeaders: maxHeaders, headers: headers,
                                      head: &head)
        guard case .complete = result else { return nil }

        if head.headEnd < 0 || head.headEnd > n {
            return "headEnd \(head.headEnd) is outside the \(n) bytes parsed"
        }
        if head.headerCount < 0 || head.headerCount > maxHeaders {
            return "headerCount \(head.headerCount) is outside 0...\(maxHeaders)"
        }
        // Every slice is an offset into the caller's buffer, and the caller
        // only owns what the parse consumed.
        for (what, slice) in [("method", head.methodSlice), ("target", head.target),
                              ("path", head.path), ("query", head.query)] {
            if let bad = outside(slice, head.headEnd, what) { return bad }
        }
        if let bad = headerSlices(headers, head.headerCount, head.headEnd) { return bad }

        // The parser is re-run from the start of the buffer on every read, so
        // a head that is complete inside a longer buffer must still be
        // complete, and end in the same place, when the buffer holds exactly
        // it. Anything else means a pipelined stream cannot be split.
        if head.headEnd < n {
            var again = HTTPRequestHead()
            let repeated = HTTPParser.parse(base, head.headEnd, maxHeadSize: maxHeadSize,
                                            maxHeaders: maxHeaders, headers: headers,
                                            head: &again)
            guard case .complete = repeated else {
                return "a head complete in \(n) bytes is not complete in its own \(head.headEnd)"
            }
            if again.headEnd != head.headEnd {
                return "the head ends at \(head.headEnd) in \(n) bytes and at "
                    + "\(again.headEnd) on its own"
            }
        }
        return nil
    }

    // MARK: - HTTP/1 response head

    /// What the client reads from a server it connected to: the same checks
    /// as a request head, on the parser that reads the other direction.
    private static func httpResponse(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        let headers = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: maxHeaders)
        defer { headers.deallocate() }
        var head = HTTPResponseHead()
        let result = HTTPResponseParser.parse(base, n, maxHeadSize: maxHeadSize,
                                              maxHeaders: maxHeaders, headers: headers, head: &head)
        guard case .complete = result else { return nil }
        if head.headEnd < 0 || head.headEnd > n {
            return "headEnd \(head.headEnd) is outside the \(n) bytes parsed"
        }
        if head.headerCount < 0 || head.headerCount > maxHeaders {
            return "headerCount \(head.headerCount) is outside 0...\(maxHeaders)"
        }
        if head.status < 100 || head.status > 999 {
            return "a status of \(head.status)"
        }
        if let bad = outside(head.reason, head.headEnd, "reason") { return bad }
        if let bad = headerSlices(headers, head.headerCount, head.headEnd) { return bad }
        if head.headEnd < n {
            var again = HTTPResponseHead()
            let repeated = HTTPResponseParser.parse(base, head.headEnd, maxHeadSize: maxHeadSize,
                                                    maxHeaders: maxHeaders, headers: headers, head: &again)
            guard case .complete = repeated, again.headEnd == head.headEnd else {
                return "a response head of \(head.headEnd) bytes does not parse the same on its own"
            }
            // What follows the head is read by the framing it chose, so a
            // longer buffer must not change that choice.
            if again.framing(method: .get) != head.framing(method: .get) {
                return "the body framing depends on bytes after the head"
            }
        }
        return nil
    }

    private static func headerSlices(_ headers: UnsafeMutablePointer<HTTPHeaderRef>, _ count: Int,
                                     _ limit: Int) -> String? {
        var i = 0
        while i < count {
            if let bad = outside(headers[i].name, limit, "header \(i) name") { return bad }
            if let bad = outside(headers[i].value, limit, "header \(i) value") { return bad }
            i &+= 1
        }
        return nil
    }

    private static func outside(_ slice: HTTPSlice, _ limit: Int, _ what: String) -> String? {
        let start = Int(slice.offset)
        let end = start &+ slice.count
        if start < 0 || end < start || end > limit {
            return "the \(what) slice covers \(start)..<\(end) of \(limit) bytes"
        }
        return nil
    }

    // MARK: - Chunked transfer coding

    private static func chunked(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        // A trailer cap far below the server's, so inputs this short can still
        // reach it. Derived from the length rather than fixed, so the corpus
        // explores both sides of the limit -- and the same on both runs, or
        // the two would not be comparable.
        let trailerCap = 8 &+ (n & 63)

        var whole = [UInt8]()
        var wholeDecoder = ChunkedDecoder(maxTrailerBytes: trailerCap)
        var wholeConsumed = 0
        let wholeOutcome = wholeDecoder.decode(base, n, consumed: &wholeConsumed) { p, k in
            whole.append(contentsOf: UnsafeBufferPointer(start: p, count: k))
        }
        if wholeConsumed < 0 || wholeConsumed > n {
            return "the decoder consumed \(wholeConsumed) of \(n) bytes"
        }

        // The same bytes one at a time. Where a read happens to split is the
        // peer's choice, so it must not be able to change what is decoded.
        var piecewise = [UInt8]()
        var pieceDecoder = ChunkedDecoder(maxTrailerBytes: trailerCap)
        var offset = 0
        var pieceOutcome = ChunkedDecoder.Outcome.needMore
        while offset < n {
            var consumed = 0
            pieceOutcome = pieceDecoder.decode(base + offset, 1, consumed: &consumed) { p, k in
                piecewise.append(contentsOf: UnsafeBufferPointer(start: p, count: k))
            }
            if consumed < 0 || consumed > 1 {
                return "a one-byte decode consumed \(consumed)"
            }
            offset &+= consumed
            if case .needMore = pieceOutcome, consumed == 0 {
                // The decoder wants more than the one byte on offer. Nothing
                // here says that is wrong, but the two runs are no longer
                // comparable, so this input is not evidence either way.
                return nil
            }
            if case .needMore = pieceOutcome { continue }
            break
        }

        if describe(wholeOutcome) != describe(pieceOutcome) {
            return "decoding in one go ends \(describe(wholeOutcome)) and byte by byte "
                + "\(describe(pieceOutcome))"
        }
        if whole != piecewise {
            return "decoding in one go yields \(whole.count) body bytes and byte by byte "
                + "\(piecewise.count)"
        }
        return nil
    }

    private static func describe(_ outcome: ChunkedDecoder.Outcome) -> String {
        switch outcome {
        case .needMore: return "needMore"
        case .finished: return "finished"
        case .failure(let e): return "failure(\(e))"
        }
    }

    // MARK: - HPACK

    private static func hpack(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        var fields: [([UInt8], [UInt8])] = []
        var badSpan: String? = nil
        var decoder = HPACKDecoder()
        // The decoder owns manually managed buffers, so it is destroyed rather
        // than dropped -- a fuzzer runs this millions of times.
        defer { decoder.destroy() }
        var failed = false
        do {
            try decoder.decode(base, n) { span in
                // A length is what the caller will read through the pointer
                // beside it, so a negative one is a read backwards out of the
                // decoder's arena. An empty name or value is merely unusual.
                if span.nameLength < 0 || span.valueLength < 0 {
                    if badSpan == nil {
                        badSpan = "a decoded field had lengths "
                            + "\(span.nameLength)/\(span.valueLength)"
                    }
                    return
                }
                fields.append((copy(span.name, span.nameLength),
                               copy(span.value, span.valueLength)))
            }
        } catch {
            failed = true
        }
        if let badSpan { return badSpan }
        if failed { return nil }

        // A header block is decoded against the dynamic table as it stood
        // before it, so the same block against the same starting table must
        // decode the same way. Two fresh decoders start from the same table.
        var again: [([UInt8], [UInt8])] = []
        var second = HPACKDecoder()
        defer { second.destroy() }
        do {
            try second.decode(base, n) { span in
                again.append((copy(span.name, span.nameLength),
                              copy(span.value, span.valueLength)))
            }
        } catch {
            return "the same block decoded once and then threw"
        }
        return compare(fields, again, "two decoders")
    }

    private static func compare(_ a: [([UInt8], [UInt8])], _ b: [([UInt8], [UInt8])], _ what: String) -> String? {
        if a.count != b.count {
            return "the same block decoded to \(a.count) fields and \(b.count), in \(what)"
        }
        var i = 0
        while i < a.count {
            if a[i].0 != b[i].0 || a[i].1 != b[i].1 {
                return "field \(i) differs between \(what)"
            }
            i &+= 1
        }
        return nil
    }

    private static func copy(_ p: UnsafePointer<UInt8>, _ n: Int) -> [UInt8] {
        Array(UnsafeBufferPointer(start: p, count: n))
    }

    // MARK: - QPACK

    /// An HTTP/3 field section. With no dynamic table the decoder holds no
    /// state between sections, so the same section must decode the same way
    /// twice in one decoder -- which is also what catches a span left
    /// pointing into scratch space the second decode reused.
    private static func qpack(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        var decoder = QPACKDecoder()
        defer { decoder.destroy() }
        // A cap derived from the length, so short inputs reach it.
        decoder.maximumFieldSectionSize = 64 &+ (n & 1023)
        func decode() -> Result<[([UInt8], [UInt8])], Bad> {
            var fields: [([UInt8], [UInt8])] = []
            var size = 0
            do {
                try decoder.decode(base, n) { span in
                    if span.nameLength < 0 || span.valueLength < 0 {
                        throw Bad("a decoded field had lengths \(span.nameLength)/\(span.valueLength)")
                    }
                    size += span.nameLength + span.valueLength + 32
                    fields.append((copy(span.name, span.nameLength), copy(span.value, span.valueLength)))
                }
            } catch let bad as Bad {
                return .failure(bad)
            } catch {
                return .success([])
            }
            // The cap is what keeps a peer from making the server hold more
            // than it agreed to, so a section past it must not get through.
            if size > decoder.maximumFieldSectionSize {
                return .failure(Bad("a section of \(size) bytes passed a cap of \(decoder.maximumFieldSectionSize)"))
            }
            return .success(fields)
        }
        let first: [([UInt8], [UInt8])]
        switch decode() {
        case .failure(let bad): return bad.reason
        case .success(let fields): first = fields
        }
        switch decode() {
        case .failure(let bad): return bad.reason
        case .success(let again): return compare(first, again, "two decodes in one decoder")
        }
    }

    struct Bad: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    // MARK: - WebSocket frame header

    private static let maxPayload = 1 << 20

    private static func websocket(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        // RSV1 is permessage-deflate's, allowed only when it was agreed, so
        // both ways are fuzzed; which one follows from the input.
        let allowRSV1 = n & 1 == 1
        guard case .header(let h) = WebSocketCodec.parseHeader(base, n, maxPayload: maxPayload,
                                                               allowRSV1: allowRSV1) else {
            return nil
        }
        if h.headerLength <= 0 || h.headerLength > n {
            return "a header of \(h.headerLength) bytes was read out of \(n)"
        }
        if h.payloadLength < 0 || h.payloadLength > maxPayload {
            return "a payload length of \(h.payloadLength) passed a limit of \(maxPayload)"
        }
        if h.totalLength < h.headerLength {
            return "totalLength \(h.totalLength) is below the header alone"
        }
        if h.rsv1 && !allowRSV1 {
            return "RSV1 was accepted with no extension agreed"
        }
        // The header is exactly as long as it says, so it must parse the same
        // way from exactly that much: the caller uses headerLength to find
        // where the payload starts.
        guard case .header(let again) = WebSocketCodec.parseHeader(base, h.headerLength, maxPayload: maxPayload,
                                                                   allowRSV1: allowRSV1) else {
            return "a header of \(h.headerLength) bytes does not parse from its own bytes"
        }
        if again.headerLength != h.headerLength || again.payloadLength != h.payloadLength
            || again.opcode != h.opcode || again.fin != h.fin || again.masked != h.masked {
            return "the header parses differently from its own bytes"
        }
        return nil
    }

    // MARK: - QUIC packet header

    private static func quicPacket(_ base: UnsafePointer<UInt8>, _ n: Int) -> String? {
        let h = QUICPacket.parseHeader(base, n, localCIDLength: quicLocalCIDLength)
        guard h.isValid else { return nil }
        if h.end < 0 || h.end > n {
            return "the packet ends at \(h.end) of \(n) bytes"
        }
        if h.pnOffset < 0 || h.pnOffset > h.end {
            return "the packet number starts at \(h.pnOffset), outside a packet ending at \(h.end)"
        }
        if h.isLong {
            let tokenStart = h.token.base - base
            if h.token.count < 0 || (h.token.count > 0 && (tokenStart < 0 || tokenStart + h.token.count > h.pnOffset)) {
                return "a token of \(h.token.count) bytes at \(tokenStart), past the header's \(h.pnOffset)"
            }
        }
        // A datagram holds packets end to end, and the next is found where
        // this one ends, so this one must read the same from its own bytes.
        let again = QUICPacket.parseHeader(base, h.end, localCIDLength: quicLocalCIDLength)
        if !again.isValid || again.end != h.end || again.pnOffset != h.pnOffset || again.type != h.type {
            return "a packet of \(h.end) bytes does not parse the same from its own bytes"
        }
        return nil
    }
}
