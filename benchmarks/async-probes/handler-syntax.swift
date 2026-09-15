// Does the proposed handler syntax type-check, and pick the right path?
//   - a closure with no await must select the synchronous overload
//   - a closure with an await must select the async overload
//   - typed extractors of any number and type, through parameter packs
//   - the extracted values are what the handler receives
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct FakeRequest {
    var parameters: [String]
    var query: [String: String]
}

struct BadRequest: Error {}

protocol Extractor {
    static func extract(from request: FakeRequest, position: inout Int) throws(BadRequest) -> Self
}

struct Path<Value: LosslessStringConvertible>: Extractor {
    var value: Value
    static func extract(from request: FakeRequest, position: inout Int) throws(BadRequest) -> Self {
        guard position < request.parameters.count,
              let value = Value(request.parameters[position]) else { throw BadRequest() }
        position += 1
        return Path(value: value)
    }
}

struct Query: Extractor {
    var items: [String: String]
    static func extract(from request: FakeRequest, position: inout Int) throws(BadRequest) -> Self {
        Query(items: request.query)
    }
}

protocol ResponseConvertible { var text: String { get } }
extension String: ResponseConvertible { var text: String { self } }

enum Route {
    case sync((FakeRequest) throws -> String)
    case async((FakeRequest) async throws -> String)
}

final class Application {
    var routes: [(String, Route)] = []

    func get<each E: Extractor, R: ResponseConvertible>(
        _ path: String, _ handler: @escaping (repeat each E) throws -> R
    ) {
        routes.append((path, .sync({ request in
            var position = 0
            return try handler(repeat try (each E).extract(from: request, position: &position)).text
        })))
    }

    func get<each E: Extractor, R: ResponseConvertible>(
        _ path: String, _ handler: @escaping (repeat each E) async throws -> R
    ) {
        routes.append((path, .async({ request in
            var position = 0
            return try await handler(repeat try (each E).extract(from: request, position: &position)).text
        })))
    }
}

@inline(never) func lookUp(_ id: Int) async -> String { "user \(id)" }

@main
struct Probe {
    static func main() async {
        let app = Application()

        app.get("/") { () in
            "hello"
        }
        app.get("/user/:id") { (id: Path<Int>) in
            "user \(id.value)"
        }
        app.get("/db/user/:id") { (id: Path<Int>) in
            await lookUp(id.value)
        }
        app.get("/search/:kind/:page") { (kind: Path<String>, page: Path<Int>, query: Query) in
            "\(kind.value) page \(page.value) q=\(query.items["q"] ?? "")"
        }
        app.get("/slow/:kind/:page") { (kind: Path<String>, page: Path<Int>, query: Query) async throws -> String in
            try await Task.sleep(for: .milliseconds(1))
            return "\(kind.value) page \(page.value) q=\(query.items["q"] ?? "")"
        }

        let requests: [FakeRequest] = [
            FakeRequest(parameters: [], query: [:]),
            FakeRequest(parameters: ["42"], query: [:]),
            FakeRequest(parameters: ["7"], query: [:]),
            FakeRequest(parameters: ["books", "3"], query: ["q": "swift"]),
            FakeRequest(parameters: ["books", "3"], query: ["q": "swift"]),
        ]
        for ((path, route), request) in zip(app.routes, requests) {
            switch route {
            case .sync(let run):
                print("\(path): sync -> \((try? run(request)) ?? "threw")")
            case .async(let run):
                print("\(path): async -> \((try? await run(request)) ?? "threw")")
            }
        }
        if case .sync(let run) = app.routes[1].1 {
            let bad = FakeRequest(parameters: ["abc"], query: [:])
            print("/user/abc: \((try? run(bad)) ?? "threw, so a 400")")
        }
    }
}
