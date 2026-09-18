//===----------------------------------------------------------------------===//
// Digests, and the HTTP fields that carry one.
//
// RFC 9530 gives two: `Content-Digest` is over the bytes of *this* message,
// and `Repr-Digest` over the whole representation however many messages it
// took. A resumable upload uses both -- one request's bytes, and the file the
// requests add up to -- and so does anything that hands a client something it
// should be able to check:
//
//     let sha = Digest.sha256(bytes)
//     response.addHeader("Content-Digest", Digest.field(sha))   // sha-256=:...:
//
//     if let wanted = Digest.sha256(field: request.header("content-digest") ?? ""),
//        wanted != Digest.sha256(body) {
//         throw HTTPError(.badRequest, "the body is not what its digest says")
//     }
//
// Only SHA-256 is read and written. It is what the registry marks as the one
// to use, and a digest nobody checks is worse than none: a field naming an
// algorithm this does not know reads as nil, so a caller sees "nothing to
// check" rather than a false yes.
//
// `SHA256Digest` is the same hash over bytes that arrive a piece at a time,
// for a body being read or a file being streamed. It cannot be saved and
// resumed in another process, which is why an upload spanning requests hashes
// its file at the end rather than as it goes.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CAvian
import GarudaPostgres

public enum Digest {
    /// The SHA-256 of `bytes`.
    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let rc = bytes.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { o in
                av_hash(Int32(AV_SHA256), input.baseAddress, input.count,
                        o.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
        precondition(rc == 32, "SHA-256 is unavailable")
        return out
    }

    /// The SHA-256 of a file, read a piece at a time so its size does not
    /// decide how much memory this takes. Nil when the file cannot be read.
    public static func sha256(contentsOfFile path: String, chunkSize: Int = 256 * 1024) -> [UInt8]? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        let hash = SHA256Digest()
        var chunk = [UInt8](repeating: 0, count: max(1, chunkSize))
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            chunk.withUnsafeBytes { hash.update($0.baseAddress!, n) }
        }
        return hash.digest()
    }

    /// A digest as `Content-Digest` and `Repr-Digest` carry it:
    /// `sha-256=:<base64>:`, the byte sequence of a structured field.
    public static func field(_ digest: [UInt8]) -> String {
        "sha-256=:" + Base64.encode(digest) + ":"
    }

    /// The SHA-256 a `Content-Digest` or `Repr-Digest` field names, or nil
    /// when it names none this understands -- an algorithm not read here, a
    /// value that is not base64, or a digest that is not 32 bytes.
    public static func sha256(field text: String) -> [UInt8]? {
        for member in text.split(separator: ",") {
            let parts = member.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            guard String(parts[0]).trimmingWhitespace().lowercased() == "sha-256" else { continue }
            let value = String(parts[1]).trimmingWhitespace()
            // A byte sequence is wrapped in colons. Anything else is a field
            // this does not understand rather than a digest to guess at.
            guard value.utf8.count > 2, value.hasPrefix(":"), value.hasSuffix(":") else { return nil }
            let encoded = String(value.dropFirst().dropLast())
            guard let bytes = Base64.decode(encoded), bytes.count == 32 else { return nil }
            return bytes
        }
        return nil
    }

    /// Whether two digests are the same. Constant time in their length, which
    /// a digest of the same algorithm always shares, so a comparison that
    /// stopped early could not say anything anyway -- but a caller comparing
    /// a digest that is also a secret gets the right thing by default.
    public static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}

/// SHA-256 over bytes that arrive a piece at a time.
///
/// A class, because the hash's state is a C context that has to be freed; one
/// instance belongs to one request or one file being read.
public final class SHA256Digest {
    private let context: OpaquePointer

    public init() {
        guard let context = av_hash_new(Int32(AV_SHA256)) else {
            fatalError("SHA-256 is unavailable")
        }
        self.context = context
    }

    deinit { av_hash_free(context) }

    public func update(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { av_hash_update(context, $0.baseAddress, $0.count) }
    }

    public func update(_ bytes: ArraySlice<UInt8>) {
        update(Array(bytes))
    }

    /// Bytes at a pointer, for a caller that already has them lent to it.
    public func update(_ bytes: UnsafeRawPointer, _ count: Int) {
        guard count > 0 else { return }
        av_hash_update(context, bytes, count)
    }

    /// The digest of everything so far. More can be added after it.
    public func digest() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let rc = out.withUnsafeMutableBytes {
            av_hash_snapshot(context, $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        precondition(rc == 32, "SHA-256 is unavailable")
        return out
    }
}
