import Testing
@testable import PeregrineHTTP

/// What `path` becomes under `--root-path root`.
private func within(_ root: String, _ path: String) -> String {
    let r = Array(root.utf8CString)
    let p = Array(path.utf8)
    return r.withUnsafeBufferPointer { rp in
        let mount = RootPath(rp.baseAddress!)
        return p.withUnsafeBufferPointer { pp in
            let (out, n) = mount.strip(pp.baseAddress!, pp.count)
            return String(decoding: UnsafeBufferPointer(start: out, count: n), as: UTF8.self)
        }
    }
}

@Suite struct RootPathTests {
    @Test func aWholeLeadingSegmentComesOff() {
        #expect(within("/api", "/api/users") == "/users")
        #expect(within("/api", "/api") == "")
        #expect(within("/api/", "/api/users") == "/users")
        #expect(within("/api/v1", "/api/v1/users") == "/users")
    }

    @Test func aPathOutsideTheMountIsLeftAlone() {
        // Behind a proxy that already took the prefix off.
        #expect(within("/api", "/users") == "/users")
        #expect(within("/api", "/scope") == "/scope")
        // Sharing letters is not sharing a segment.
        #expect(within("/api", "/apis") == "/apis")
        #expect(within("/api", "/a") == "/a")
        #expect(within("/api/v1", "/api/v12") == "/api/v12")
    }

    @Test func anEmptyRootPathTakesNothing() {
        #expect(within("", "/users") == "/users")
        #expect(within("/", "/users") == "/users")
    }
}
