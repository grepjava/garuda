//===----------------------------------------------------------------------===//
// Incremental chunked transfer decoder.
//
// Resumable at any byte boundary, so a chunk header split across two TCP
// segments costs nothing extra. Data is never copied here: the decoder hands
// the caller a pointer into the read buffer and the caller decides whether that
// becomes a Python bytes object or is streamed straight through.
//===----------------------------------------------------------------------===//

import PeregrineCore

public struct ChunkedDecoder {
    @usableFromInline
    enum State: UInt8 {
        case size, ext, sizeLF, data, dataCR, dataLF
        case trailerLine, trailerSkip, trailerCR, done
    }

    @usableFromInline var state: State = .size
    @usableFromInline var remaining: Int = 0
    @usableFromInline var digits: Int = 0
    /// Total decoded body bytes, checked against the configured body limit.
    @usableFromInline var decoded: Int = 0
    public var decodedBytes: Int { decoded }
    /// Bytes seen since the terminating chunk.
    ///
    /// Trailers decode to nothing, so the body limit never grows while they
    /// arrive and nothing else here would ever stop. A peer that sends
    /// `0\r\n` and then streams trailer fields forever would hold a
    /// connection, a slot and a read buffer for as long as it cared to, at no
    /// cost to itself -- so the trailer section gets a ceiling of its own.
    @usableFromInline var trailerSeen: Int = 0
    @usableFromInline let maxTrailerBytes: Int
    /// True once the terminating zero-length chunk and trailers are consumed.
    @inlinable public var isFinished: Bool { state == .done }

    /// The default matches the default head limit: a trailer section is a
    /// header section that arrives late, and there is no reason for it to be
    /// allowed to be larger than the one at the front of the message.
    public init(maxTrailerBytes: Int = 32 * 1024) {
        self.maxTrailerBytes = maxTrailerBytes
    }

    public enum Outcome {
        case needMore
        case finished
        case failure(HTTPParseError)
    }

    /// Consumes as much of `base[0..<count]` as possible.
    /// `sink` receives contiguous body runs; it is non-escaping, so no closure
    /// context is heap-allocated.
    @inlinable
    public mutating func decode(
        _ base: UnsafePointer<UInt8>,
        _ count: Int,
        consumed: inout Int,
        _ sink: (UnsafePointer<UInt8>, Int) -> Void
    ) -> Outcome {
        var i = 0
        while i < count {
            switch state {
            case .size:
                let c = base[i]
                if c == cCR {
                    if digits == 0 { return .failure(.badChunk) }
                    i &+= 1
                    state = .sizeLF
                } else if c == cSemicolon {
                    if digits == 0 { return .failure(.badChunk) }
                    i &+= 1
                    state = .ext
                } else {
                    let v = hexValue(c)
                    if v < 0 { return .failure(.badChunk) }
                    // 15 hex digits keeps the running value inside Int64 with
                    // room to spare; anything longer is malicious, not real.
                    if digits >= 15 { return .failure(.badChunk) }
                    remaining = (remaining << 4) | v
                    digits &+= 1
                    i &+= 1
                }

            case .ext:
                // Chunk extensions are legal and universally ignored.
                let idx = findByte(base + i, count &- i, cCR)
                if idx < 0 { i = count } else { i &+= idx &+ 1; state = .sizeLF }

            case .sizeLF:
                if base[i] != cLF { return .failure(.badChunk) }
                i &+= 1
                digits = 0
                state = remaining == 0 ? .trailerLine : .data

            case .data:
                let avail = count &- i
                let take = avail < remaining ? avail : remaining
                if take > 0 {
                    sink(base + i, take)
                    decoded &+= take
                    remaining &-= take
                    i &+= take
                }
                if remaining == 0 { state = .dataCR }

            case .dataCR:
                if base[i] != cCR { return .failure(.badChunk) }
                i &+= 1
                state = .dataLF
            case .dataLF:
                if base[i] != cLF { return .failure(.badChunk) }
                i &+= 1
                state = .size

            case .trailerLine:
                // At the start of a line: either the empty one that ends the
                // trailer section, or a trailer field to skip.
                if base[i] == cCR {
                    i &+= 1
                    state = .trailerCR
                } else if base[i] == cLF {
                    i &+= 1
                    state = .done
                    consumed = i
                    return .finished
                } else {
                    state = .trailerSkip
                }

            case .trailerSkip:
                // Inside a trailer field, whose content is ignored; only the
                // LF that ends it matters. Being a state of its own is what
                // makes that LF mean the same thing however the reads fell:
                // finding it back in `.trailerLine` would read the end of a
                // field as the empty line that ends the section, and end the
                // message a line early whenever a field arrived split from its
                // own terminator.
                let idx = findByte(base + i, count &- i, cLF)
                let take = idx < 0 ? count &- i : idx &+ 1
                trailerSeen &+= take
                // Every byte of the section except its final CRLF passes
                // through here, so this one test bounds the whole of it.
                if trailerSeen > maxTrailerBytes { return .failure(.headTooLarge) }
                i &+= take
                if idx >= 0 { state = .trailerLine }

            case .trailerCR:
                if base[i] != cLF { return .failure(.badChunk) }
                i &+= 1
                state = .done
                consumed = i
                return .finished

            case .done:
                consumed = i
                return .finished
            }
        }
        consumed = i
        return .needMore
    }
}
