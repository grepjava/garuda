import Testing
import GarudaHTTP
@testable import GarudaServer

private struct Match: Equatable {
    var route: Int32
    var parameters: [String]
}

private func match(_ routes: CompiledRoutes, _ method: HTTPMethod, _ path: String) -> Match {
    let bytes = Array(path.utf8)
    var parameters = RouteParameters()
    let route = bytes.withUnsafeBufferPointer { buffer -> Int32 in
        guard let base = buffer.baseAddress else { return -1 }
        return routes.match(method, base, buffer.count, into: &parameters)
    }
    var captured: [String] = []
    for i in 0..<parameters.count {
        let (start, count) = parameters[i]
        captured.append(String(decoding: bytes[start..<start + count], as: UTF8.self))
    }
    return Match(route: route, parameters: captured)
}

private func compile(_ routes: [(HTTPMethod, String)]) throws -> CompiledRoutes {
    var table = RouteTable()
    for (i, (method, pattern)) in routes.enumerated() {
        try table.add(method, pattern, route: Int32(i))
    }
    return table.compile()
}

@Suite("Route table")
struct RouteTableTests {

    @Test("the benchmark contract")
    func contract() throws {
        let t = try compile([(.get, "/"), (.get, "/user/:id"), (.post, "/user"), (.get, "/delay/:ms")])
        #expect(match(t, .get, "/") == Match(route: 0, parameters: []))
        #expect(match(t, .get, "/user/42") == Match(route: 1, parameters: ["42"]))
        #expect(match(t, .post, "/user") == Match(route: 2, parameters: []))
        #expect(match(t, .get, "/delay/50") == Match(route: 3, parameters: ["50"]))
        #expect(match(t, .get, "/user/").route == -1)
        #expect(match(t, .get, "/user").route == -1)
        #expect(match(t, .post, "/").route == -1)
        #expect(match(t, .get, "/nope").route == -1)
        #expect(match(t, .get, "").route == -1)
        #expect(match(t, .get, "user").route == -1)
    }

    @Test("HEAD falls back to GET, and a HEAD route of its own wins")
    func head() throws {
        let t = try compile([(.get, "/a"), (.get, "/b"), (.head, "/b")])
        #expect(match(t, .head, "/a").route == 0)
        #expect(match(t, .head, "/b").route == 2)
    }

    @Test("a literal beats a parameter, and a dead end backtracks to it")
    func backtracking() throws {
        let t = try compile([(.get, "/user/me"), (.get, "/user/:id"),
                             (.get, "/a/b/c"), (.get, "/a/:x/d")])
        #expect(match(t, .get, "/user/me") == Match(route: 0, parameters: []))
        #expect(match(t, .get, "/user/mei") == Match(route: 1, parameters: ["mei"]))
        #expect(match(t, .get, "/a/b/c") == Match(route: 2, parameters: []))
        #expect(match(t, .get, "/a/b/d") == Match(route: 3, parameters: ["b"]))
        #expect(match(t, .get, "/a/b/e").route == -1)
    }

    @Test("a trailing slash is a segment of its own")
    func trailingSlash() throws {
        let t = try compile([(.get, "/docs"), (.get, "/docs/")])
        #expect(match(t, .get, "/docs").route == 0)
        #expect(match(t, .get, "/docs/").route == 1)
        #expect(match(t, .get, "/docs//").route == -1)
    }

    @Test("the rest of the path, slashes and all")
    func rest() throws {
        let t = try compile([(.get, "/static/*path"), (.get, "/static/index")])
        #expect(match(t, .get, "/static/css/site.css") == Match(route: 0, parameters: ["css/site.css"]))
        #expect(match(t, .get, "/static/") == Match(route: 0, parameters: [""]))
        #expect(match(t, .get, "/static/index") == Match(route: 1, parameters: []))
        #expect(match(t, .get, "/static").route == -1)
    }

    @Test("parameters in several places, kept percent-encoded")
    func manyParameters() throws {
        let t = try compile([(.get, "/:a/x/:b/*c")])
        #expect(match(t, .get, "/one/x/t%20wo/3/4") == Match(route: 0, parameters: ["one", "t%20wo", "3/4"]))
    }

    @Test("patterns that cannot be served are refused")
    func badPatterns() {
        var t = RouteTable()
        #expect(throws: RoutePatternError.mustStartWithSlash) { try t.add(.get, "user", route: 0) }
        #expect(throws: RoutePatternError.emptyParameterName) { try t.add(.get, "/user/:", route: 0) }
        #expect(throws: RoutePatternError.restMustBeLast) { try t.add(.get, "/*a/b", route: 0) }
        #expect(throws: RoutePatternError.tooManyParameters) {
            try t.add(.get, "/:a/:b/:c/:d/:e/:f/:g/:h/:i", route: 0)
        }
        #expect(throws: Never.self) { try t.add(.get, "/same/:x", route: 1) }
        #expect(throws: RoutePatternError.duplicate) { try t.add(.get, "/same/:y", route: 2) }
        #expect(throws: Never.self) { try t.add(.post, "/same/:y", route: 3) }
    }
}
