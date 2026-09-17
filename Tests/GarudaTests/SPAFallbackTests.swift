import Testing
#if canImport(Glibc)
import Glibc
#endif
import CAvian
import AvianCore
@testable import Garuda
import AvianHTTP

// --spa-fallback: a single-page application's page for browser navigations no
// file or route answers.

nonisolated(unsafe) private var spaCounter = 0

/// A directory holding `index.html` and `assets/app.js`, removed afterwards.
private final class SiteDirectory {
    let path: String

    init() {
        spaCounter += 1
        path = "/tmp/garuda-spa-\(getpid())-\(spaCounter)"
        mkdir(path, 0o755)
        mkdir(path + "/assets", 0o755)
        write("/index.html", "<!doctype html><div id=app></div>")
        write("/assets/app.js", "console.log('app')")
    }

    private func write(_ name: String, _ text: String) {
        let file = fopen(path + name, "w")!
        fputs(text, file)
        fclose(file)
    }

    deinit {
        unlink(path + "/assets/app.js")
        unlink(path + "/index.html")
        rmdir(path + "/assets")
        rmdir(path)
    }
}

private let browser = [("accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")]

@Suite("SPA fallback")
struct SPAFallbackTests {
    private func client(_ site: SiteDirectory, prefix: String = "/") -> TestClient {
        let app = Application()
        app.get("/api/users") { JSON(["ada"]) }
        app.post("/app/submit") { "submitted" }
        app.group("/docs") {
            app.fallback { _, response in response.send(status: .notFound, "docs fallback") }
        }
        var config = ServerConfig()
        config.maxConnections = 16
        config.staticRoutes = [(prefix: UnsafePointer(strdup("/assets")!), directory: UnsafePointer(strdup(site.path + "/assets")!))]
        config.spaFallbacks = [(prefix: UnsafePointer(strdup(prefix)!), directory: UnsafePointer(strdup(site.path)!),
                                file: UnsafePointer(strdup("/index.html")!))]
        return app.testClient(configuration: config)
    }

    @Test func aNavigationNoRouteAnswersGetsThePage() throws {
        let site = SiteDirectory()
        let client = client(site)
        let page = try client.get("/settings/profile", headers: browser)
        #expect(page.status == 200)
        #expect(page.text == "<!doctype html><div id=app></div>")
        #expect(page.header("content-type")?.hasPrefix("text/html") == true)
        let etag = try #require(page.header("etag"))
        #expect(try client.get("/", headers: browser).text == page.text)
        #expect(try client.get("/settings", headers: browser + [("if-none-match", etag)]).status == 304)
        #expect(try client.request("HEAD", "/settings", headers: browser).status == 200)
    }

    @Test func routesFilesAndEverythingElseKeepTheirAnswers() throws {
        let site = SiteDirectory()
        let client = client(site)
        // Routes, files and a scope's own fallback come first.
        #expect(try client.get("/api/users", headers: browser).text == #"["ada"]"#)
        #expect(try client.get("/assets/app.js", headers: browser).text == "console.log('app')")
        #expect(try client.get("/docs/intro", headers: browser).text == "docs fallback")
        // A request that does not ask for HTML keeps its 404.
        #expect(try client.get("/assets/missing.js", headers: [("accept", "*/*")]).status == 404)
        #expect(try client.get("/api/nothing", headers: [("accept", "application/json")]).status == 404)
        #expect(try client.get("/settings").status == 404)
        // Only GET and HEAD, and another method on a routed path is still 405.
        #expect(try client.request("POST", "/settings", headers: browser).status == 404)
        #expect(try client.get("/app/submit", headers: browser).status == 405)
    }

    @Test func aPrefixCoversWholeSegmentsOnly() throws {
        let site = SiteDirectory()
        let client = client(site, prefix: "/app")
        #expect(try client.get("/app", headers: browser).status == 200)
        #expect(try client.get("/app/orders/7", headers: browser).status == 200)
        #expect(try client.get("/application", headers: browser).status == 404)
        #expect(try client.get("/other", headers: browser).status == 404)
    }

    @Test func theFlagIsParsedAndChecked() {
        func parsed(_ arguments: [String]) -> GarudaCLI.Parsed {
            let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 2)
            for (i, argument) in (["garuda"] + arguments).enumerated() { argv[i] = strdup(argument) }
            argv[arguments.count + 1] = nil
            return GarudaCLI.parse(argc: arguments.count + 1, argv: argv)
        }
        let site = SiteDirectory()
        guard case .run(let config) = parsed(["--spa-fallback", "/=\(site.path)/index.html",
                                              "--spa-fallback", "/admin=\(site.path)/index.html"]) else {
            Issue.record("the flags did not parse")
            return
        }
        #expect(config.spaFallbacks.map { String(cString: $0.prefix) } == ["/admin", "/"])
        #expect(config.spaFallbacks.map { String(cString: $0.directory) } == [site.path, site.path])
        #expect(config.spaFallbacks.map { String(cString: $0.file) } == ["/index.html", "/index.html"])
        for bad in [["--spa-fallback", "/=\(site.path)/nope.html"], ["--spa-fallback", "app=\(site.path)/index.html"],
                    ["--spa-fallback", "/="]] {
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
