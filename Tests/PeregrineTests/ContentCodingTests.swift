import Testing
@testable import PeregrineCore
@testable import PeregrineHTTP

private func accept(_ s: String) -> AcceptEncoding {
    var bytes = Array(s.utf8)
    return bytes.withUnsafeMutableBufferPointer { AcceptEncoding(UnsafePointer($0.baseAddress!), $0.count) }
}

private func compressible(_ s: String) -> Bool {
    var bytes = Array(s.utf8)
    return bytes.withUnsafeMutableBufferPointer {
        CompressionEligibility.isCompressible(UnsafePointer($0.baseAddress!), $0.count)
    }
}

private func observe(_ e: inout CompressionEligibility, _ name: String, _ value: String) {
    var n = Array(name.utf8)
    var v = Array(value.utf8)
    n.withUnsafeMutableBufferPointer { np in
        v.withUnsafeMutableBufferPointer { vp in
            e.observe(ByteSpan(UnsafePointer(np.baseAddress!), np.count),
                      ByteSpan(UnsafePointer(vp.baseAddress!), vp.count))
        }
    }
}

@Suite struct ContentCodingTests {
    @Test func unratedCodingsGoByServerPreference() {
        // What curl --compressed sends.
        let a = accept("deflate, gzip, br, zstd")
        #expect(a.choose { _ in true } == .br)
        #expect(a.choose { $0 != .br } == .zstd)
        #expect(a.choose { $0 == .gzip } == .gzip)
    }

    @Test func weightsBeatPreference() {
        let a = accept("br;q=0.5, gzip;q=0.9")
        #expect(a.choose { _ in true } == .gzip)
        #expect(a.ranked { _ in true } == [.gzip, .br])
    }

    @Test func zeroRefuses() {
        let a = accept("gzip, br;q=0")
        #expect(a.choose { _ in true } == .gzip)
        #expect(accept("br;q=0.000").choose { _ in true } == .identity)
    }

    @Test func wildcardCoversWhatIsNotNamed() {
        let a = accept("*;q=0.3, gzip;q=0")
        #expect(a.weight(.gzip) == 0)
        #expect(a.weight(.zstd) == 300)
        #expect(a.choose { _ in true } == .br)
    }

    @Test func absentOrEmptyMeansIdentity() {
        #expect(AcceptEncoding().choose { _ in true } == .identity)
        #expect(accept("").choose { _ in true } == .identity)
        #expect(accept("identity").choose { _ in true } == .identity)
    }

    @Test func caseAndWhitespaceAreTolerated() {
        let a = accept("  GZIP ; Q=0.7 ,BR")
        #expect(a.gzip == 700)
        #expect(a.br == 1000)
    }

    @Test func malformedWeightRefuses() {
        #expect(accept("gzip;q=high").gzip == 0)
        #expect(accept("gzip;q=2").gzip == 0)
    }

    @Test func compressibleTypes() {
        #expect(compressible("text/html; charset=utf-8"))
        #expect(compressible("application/json"))
        #expect(compressible("application/problem+json"))
        #expect(compressible("image/svg+xml"))
        #expect(compressible("TEXT/CSS"))
        #expect(!compressible("text/event-stream"))
        #expect(!compressible("image/png"))
        #expect(!compressible("application/octet-stream"))
        #expect(!compressible(""))
    }

    @Test func eligibilityFollowsTheResponse() {
        var e = CompressionEligibility()
        observe(&e, "Content-Type", "text/plain")
        #expect(e.choose(offered: .br, status: 200, bodyAllowed: true,
                         declaredLength: -1, minimumLength: 1024) == .br)
        #expect(e.choose(offered: .br, status: 200, bodyAllowed: true,
                         declaredLength: 100, minimumLength: 1024) == .identity)
        #expect(e.choose(offered: .br, status: 200, bodyAllowed: false,
                         declaredLength: -1, minimumLength: 1024) == .identity)
        #expect(e.choose(offered: .identity, status: 200, bodyAllowed: true,
                         declaredLength: -1, minimumLength: 1024) == .identity)
        #expect(e.mayVary(status: 200))

        var encoded = e
        observe(&encoded, "content-encoding", "gzip")
        #expect(!encoded.mayVary(status: 200))

        var pinned = e
        observe(&pinned, "Cache-Control", "public, no-transform")
        #expect(!pinned.mayVary(status: 200))

        var varied = e
        observe(&varied, "Vary", "Cookie, Accept-Encoding")
        #expect(varied.varyCovered)

        #expect(!e.mayVary(status: 206))
    }
}
