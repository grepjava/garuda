import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import GarudaTesting
import GarudaWire
@testable import Garuda

// --static-dir, --static-index, --static-listing and --spa-fallback.

/// A directory of files for one test, removed afterwards.
private final class Site {
    let path: String

    init() {
        var template = Array("/tmp/garuda-static-XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
        precondition(made != nil, "no temporary directory")
        path = String(cString: template)
        chmod(path, 0o755)
    }

    func directory(_ name: String) { mkdir(path + name, 0o755) }

    func write(_ name: String, _ bytes: [UInt8]) {
        let file = fopen(path + name, "w")!
        bytes.withUnsafeBufferPointer { _ = fwrite($0.baseAddress, 1, $0.count, file) }
        fclose(file)
    }

    func write(_ name: String, _ text: String) { write(name, Array(text.utf8)) }

    func link(_ name: String, to target: String) { symlink(target, path + name) }

    deinit {
        let command = "rm -rf '\(path)'"
        _ = command.withCString { system($0) }
    }
}

private func pattern(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }
}

private let browser = [("accept", "text/html,application/xhtml+xml,*/*;q=0.8")]

@Suite("Static files")
struct StaticFileTests {
    private func client(_ site: Site, index: Bool = false, listing: Bool = false, limit: Int = 10_000,
                        prefix: String = "/static", spa: String? = nil) -> TestClient {
        let app = Application()
        app.get("/user/:id") { request, response in response.send(request.parameter(0)) }
        app.get("/static/routed") { _, response in response.send("routed") }
        var config = ServerConfig()
        config.staticDirectories = [(prefix, site.path + "/assets")]
        config.staticIndex = index
        config.staticListing = listing
        config.staticListingLimit = limit
        if let spa { config.spaFallbacks = [(spa, site.path, "/index.html")] }
        let client = app.testClient(configuration: config)
        client.timeout = .seconds(20)
        return client
    }

    private func site() -> Site {
        let site = Site()
        site.directory("/assets")
        site.directory("/assets/deep")
        site.directory("/secret")
        site.directory("/assets-sibling")
        site.write("/assets/site.css", "body { color: red }\n")
        site.write("/assets/deep/nested.txt", "deep\n")
        site.write("/secret/passwd", "TOP SECRET\n")
        site.write("/assets-sibling/leak.txt", "sibling\n")
        site.write("/assets/big.bin", pattern(3_000_000))
        site.write("/assets/inline.bin", pattern(16384))
        site.write("/assets/sendfile.bin", pattern(16385))
        site.write("/index.html", "<!doctype html><div id=app></div>")
        site.link("/assets/escape.txt", to: site.path + "/secret/passwd")
        site.link("/assets/inside.txt", to: "deep/nested.txt")
        site.link("/assets/up", to: "../secret")
        return site
    }

    @Test func filesAreServedWithTheirTypeAndLength() throws {
        let site = site()
        let client = client(site)
        let css = try client.get("/static/site.css")
        #expect(css.status == .ok)
        #expect(css.text == "body { color: red }\n")
        #expect(css.header("content-type") == "text/css; charset=utf-8")
        #expect(css.header("content-length") == "20")
        #expect(css.header("accept-ranges") == "bytes")
        #expect(try client.get("/static/deep/nested.txt").text == "deep\n")
        #expect(try client.get("/static/inside.txt").text == "deep\n")
        let head = try client.head("/static/site.css")
        #expect(head.status == .ok)
        #expect(head.body.isEmpty)
        #expect(head.header("content-length") == "20")
    }

    @Test func largeFilesArriveWhole() throws {
        let site = site()
        let client = client(site)
        #expect(try client.get("/static/big.bin").body == pattern(3_000_000))
        #expect(try client.get("/static/inline.bin").body == pattern(16384))
        #expect(try client.get("/static/sendfile.bin").body == pattern(16385))
        let head = try client.head("/static/big.bin")
        #expect(head.header("content-length") == "3000000")
        #expect(head.body.isEmpty)
    }

    @Test func nothingOutsideTheDirectoryIsReached() throws {
        let site = site()
        let client = client(site)
        for path in ["/static/../secret/passwd", "/static/%2e%2e/secret/passwd", "/static/escape.txt",
                     "/static/up/passwd", "/static/../assets-sibling/leak.txt", "/static/deep",
                     "/static/missing.css", "/static/site.css%00.txt"] {
            #expect(try client.get(path).status == .notFound, "\(path)")
        }
        // A sibling that only shares the prefix's letters is not under it.
        #expect(try client.get("/staticky/site.css").status == .notFound)
        // Outside the prefix, and a path with no file under it, the routes answer.
        #expect(try client.get("/user/7").text == "7")
        #expect(try client.get("/static/routed").text == "routed")
        // Only GET and HEAD.
        #expect(try client.post("/static/site.css").status == .notFound)
    }

    @Test func validatorsAndPreconditions() throws {
        let site = site()
        let client = client(site)
        let etag = try #require(try client.get("/static/site.css").header("etag"))
        #expect(etag.hasPrefix("\"") && etag.hasSuffix("\""))
        let fresh = try client.get("/static/site.css", headers: [("if-none-match", etag)])
        #expect(fresh.status == .notModified)
        #expect(fresh.body.isEmpty)
        #expect(fresh.header("etag") == etag)
        #expect(try client.get("/static/site.css", headers: [("if-none-match", "W/" + etag)]).status == .notModified)
        #expect(try client.get("/static/site.css", headers: [("if-none-match", "\"x\", " + etag)]).status == .notModified)
        #expect(try client.get("/static/site.css", headers: [("if-none-match", "*")]).status == .notModified)
        #expect(try client.get("/static/site.css", headers: [("if-match", "\"nope\"")]).status == .preconditionFailed)
        #expect(try client.get("/static/site.css", headers: [("if-match", etag)]).status == .ok)
        #expect(try client.get("/static/site.css", headers: [("if-match", "W/" + etag)]).status == .preconditionFailed)
    }

    @Test func rangesAreServed() throws {
        let site = site()
        let client = client(site)
        let part = try client.get("/static/site.css", headers: [("range", "bytes=7-11")])
        #expect(part.status == .partialContent)
        #expect(part.text == "color")
        #expect(part.header("content-range") == "bytes 7-11/20")
        #expect(try client.get("/static/site.css", headers: [("range", "bytes=-4")]).text == "red }\n".suffix(4).description)
        let outside = try client.get("/static/site.css", headers: [("range", "bytes=100-")])
        #expect(outside.status == .rangeNotSatisfiable)
        #expect(outside.header("content-range") == "bytes */20")
        let big = try client.get("/static/big.bin", headers: [("range", "bytes=1048576-2097151")])
        #expect(big.status == .partialContent)
        #expect(big.body == Array(pattern(3_000_000)[1048576..<2097152]))
        let etag = try #require(try client.get("/static/site.css").header("etag"))
        #expect(try client.get("/static/site.css", headers: [("range", "bytes=0-3"), ("if-range", etag)]).text == "body")
        #expect(try client.get("/static/site.css", headers: [("range", "bytes=0-3"), ("if-range", "\"nope\"")]).text
                == "body { color: red }\n")
    }

    @Test func directoriesWithAnIndexAndAListing() throws {
        let site = site()
        site.directory("/assets/pages")
        site.write("/assets/pages/index.html", "<h1>pages</h1>")
        site.directory("/assets/listed")
        site.write("/assets/listed/one.txt", "1")
        site.write("/assets/listed/.hidden", "h")
        site.directory("/assets/listed/sub")

        let plain = client(site)
        #expect(try plain.get("/static/pages/").status == .notFound)

        let indexed = client(site, index: true)
        #expect(try indexed.get("/static/pages/").text == "<h1>pages</h1>")
        let redirect = try indexed.get("/static/pages?a=1")
        #expect(redirect.status == .movedPermanently)
        #expect(redirect.header("location") == "/static/pages/?a=1")
        #expect(try indexed.get("/static/listed/").status == .notFound)

        let listed = client(site, listing: true)
        let page = try listed.get("/static/listed/")
        #expect(page.status == .ok)
        #expect(page.header("content-type") == "text/html; charset=utf-8")
        #expect(page.header("cache-control") == "no-store")
        #expect(page.text.contains("href=\"one.txt\""))
        #expect(page.text.contains("href=\"sub/\""))
        #expect(!page.text.contains(".hidden"))
        #expect(try listed.get("/static/listed").status == .movedPermanently)
        // A symbolic link to a directory is not listed, wherever it points.
        #expect(try listed.get("/static/up/").status == .notFound)
        #expect(try listed.get("/static/pages/").text == "<h1>pages</h1>")

        let limited = client(site, listing: true, limit: 1)
        #expect(try limited.get("/static/listed/").text.contains("More entries are not listed"))
    }

    @Test func aRootPrefixRedirectsToOneLeadingSlash() throws {
        let site = site()
        site.directory("/assets/example.com")
        let client = client(site, listing: true, prefix: "/")
        let redirect = try client.send(raw: Array("GET //example.com HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        #expect(redirect.status == .movedPermanently)
        #expect(redirect.header("location") == "/example.com/")
    }

    @Test func overHTTP2() throws {
        let site = site()
        let h2 = try client(site).http2()
        let css = try h2.get("/static/site.css")
        #expect(css.text == "body { color: red }\n")
        #expect(css.header("content-length") == "20")
        let big = try h2.get("/static/big.bin")
        #expect(big.ended)
        #expect(big.body == pattern(3_000_000))
        #expect(try h2.get("/static/site.css", headers: [("range", "bytes=7-11")]).text == "color")
        #expect(try h2.get("/static/site.css", headers: [("if-match", "\"nope\"")]).status == .preconditionFailed)
        let head = try h2.head("/static/big.bin")
        #expect(head.header("content-length") == "3000000")
        #expect(head.ended)
        #expect(head.body.isEmpty)
    }

    @Test func aNavigationNoRouteAnswersGetsTheSPAPage() throws {
        let site = site()
        let client = client(site, spa: "/")
        let page = try client.get("/settings/profile", headers: browser)
        #expect(page.status == .ok)
        #expect(page.text == "<!doctype html><div id=app></div>")
        #expect(page.header("content-type")?.hasPrefix("text/html") == true)
        // Routes and files come first; what does not ask for HTML keeps its 404.
        #expect(try client.get("/user/3", headers: browser).text == "3")
        #expect(try client.get("/static/site.css", headers: browser).text == "body { color: red }\n")
        #expect(try client.get("/settings").status == .notFound)
        #expect(try client.get("/static/missing.js", headers: [("accept", "*/*")]).status == .notFound)
        #expect(try client.post("/settings", headers: browser).status == .notFound)

        let scoped = self.client(site, spa: "/app")
        #expect(try scoped.get("/app", headers: browser).status == .ok)
        #expect(try scoped.get("/app/orders/7", headers: browser).status == .ok)
        #expect(try scoped.get("/application", headers: browser).status == .notFound)
    }

    @Test func theFlagsAreParsed() throws {
        let site = site()
        func parsed(_ arguments: [String]) -> ServerConfig.Parsed { ServerConfig.parse(["garuda"] + arguments) }
        guard case .run(let config) = parsed(["--static-dir", "/static=/srv/www", "--static-listing",
                                              "--static-listing-limit", "5", "--workers", "2",
                                              "--spa-fallback", "/app=\(site.path)/index.html"]) else {
            Issue.record("the flags did not parse")
            return
        }
        #expect(config.staticDirectories.map { "\($0.prefix)=\($0.directory)" } == ["/static=/srv/www"])
        #expect(config.staticListing && config.staticIndex)
        #expect(config.staticListingLimit == 5)
        #expect(config.shards == 2)
        #expect(config.spaFallbacks.map { "\($0.prefix) \($0.directory) \($0.file)" } == ["/app \(site.path) /index.html"])
        for bad in [["--static-dir", "static=/srv"], ["--static-dir", "/static"], ["--static-dir", "=/srv"],
                    ["--spa-fallback", "/=\(site.path)/nope.html"], ["--spa-fallback", "app=\(site.path)/index.html"]] {
            if case .exit(let status) = parsed(bad) { #expect(status == 2) } else { Issue.record("\(bad) parsed") }
        }
    }

    @Test func htmlIsFoundInAnAcceptHeader() {
        func accepts(_ text: String) -> Bool {
            var text = text
            return text.withUTF8 { acceptsHTML(ByteSpan($0.baseAddress!, $0.count)) }
        }
        #expect(accepts("text/html"))
        #expect(accepts("application/xhtml+xml;q=0.9, */*"))
        #expect(accepts("TEXT/HTML"))
        #expect(!accepts("*/*"))
        #expect(!accepts("application/json"))
    }
}

// What a `Range` header asks for, against a file of a known size.
@Suite("Byte ranges")
struct ByteRangeTests {
    @Test func aRangeInsideTheFile() throws {
        #expect(parseByteRange("bytes=0-499", size: 1000) == .bytes(start: 0, length: 500))
        #expect(parseByteRange("bytes=500-999", size: 1000) == .bytes(start: 500, length: 500))
        #expect(parseByteRange("bytes=0-0", size: 1000) == .bytes(start: 0, length: 1))
        #expect(parseByteRange("bytes=999-999", size: 1000) == .bytes(start: 999, length: 1))
    }

    @Test func anOpenEndIsTheRestOfTheFile() throws {
        #expect(parseByteRange("bytes=500-", size: 1000) == .bytes(start: 500, length: 500))
        #expect(parseByteRange("bytes=0-", size: 1000) == .bytes(start: 0, length: 1000))
        #expect(parseByteRange("bytes=900-5000", size: 1000) == .bytes(start: 900, length: 100))
    }

    @Test func aSuffixIsTheEndOfTheFile() throws {
        #expect(parseByteRange("bytes=-500", size: 1000) == .bytes(start: 500, length: 500))
        #expect(parseByteRange("bytes=-1", size: 1000) == .bytes(start: 999, length: 1))
        #expect(parseByteRange("bytes=-5000", size: 1000) == .bytes(start: 0, length: 1000))
        #expect(parseByteRange("bytes=-0", size: 1000) == .unsatisfiable)
    }

    @Test func aRangeOutsideTheFileIs416() throws {
        #expect(parseByteRange("bytes=1000-", size: 1000) == .unsatisfiable)
        #expect(parseByteRange("bytes=1000-1001", size: 1000) == .unsatisfiable)
        #expect(parseByteRange("bytes=5000-6000", size: 1000) == .unsatisfiable)
        #expect(parseByteRange("bytes=0-", size: 0) == .unsatisfiable)
        #expect(parseByteRange("bytes=-1", size: 0) == .unsatisfiable)
    }

    @Test func whatIsNotARangeIsIgnored() throws {
        for header in ["", "bytes", "bytes=", "bytes=-", "bytes=abc", "bytes=1-2-3",
                       "items=0-10", "bytes 0-10", "bytes=0-10x", "bytes=0- 10", "bytes=500-499"] {
            #expect(parseByteRange(header, size: 1000) == .whole, "\(header)")
        }
    }

    @Test func severalRangesAreAnsweredWhole() throws {
        #expect(parseByteRange("bytes=0-99,200-299", size: 1000) == .whole)
        #expect(parseByteRange("bytes=0-99, 200-299", size: 1000) == .whole)
        #expect(parseByteRange("bytes=-100,-200", size: 1000) == .whole)
    }

    @Test func whitespaceAndCaseAreWhatTheyShouldBe() throws {
        #expect(parseByteRange("BYTES=0-9", size: 100) == .bytes(start: 0, length: 10))
        #expect(parseByteRange("  bytes=0-9  ", size: 100) == .bytes(start: 0, length: 10))
        #expect(parseByteRange("bytes= 0-9", size: 100) == .bytes(start: 0, length: 10))
        #expect(parseByteRange("bytes=0-9\t", size: 100) == .bytes(start: 0, length: 10))
    }

    @Test func numbersTooBigToBeAFileAreNotTakenForOne() throws {
        #expect(parseByteRange("bytes=99999999999999999999-", size: 1000) == .unsatisfiable)
        #expect(parseByteRange("bytes=0-99999999999999999999", size: 1000) == .bytes(start: 0, length: 1000))
        #expect(parseByteRange("bytes=-99999999999999999999", size: 1000) == .bytes(start: 0, length: 1000))
    }
}
