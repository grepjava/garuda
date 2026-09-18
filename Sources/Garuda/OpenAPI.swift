//===----------------------------------------------------------------------===//
// An OpenAPI 3.1 document built from the routes themselves.
//
//     app.openAPI(OpenAPIInfo(title: "Orders", version: "1.0.0"))
//     app.swaggerUI()
//
//     app.get("/orders/:id") { (id: Path<Int>, db: State<Database>) async throws in
//         JSON(try await db.order(id.value))
//     }
//     .summary("An order by its number")
//     .tags("orders")
//     .response(.notFound, "No order has that number")
//
// A typed route already says most of what the document needs: its method and
// pattern, and the types of what it takes and returns. `Path<Int>` is an
// integer path parameter, `Query<Filter>` is a query parameter for each of
// `Filter`'s fields, `Body<NewOrder>` is a JSON request body, `BearerToken` is
// bearer authentication, and `JSON<Order>` is a JSON 200 -- each schema read
// from the `Decodable` type (OpenAPISchema.swift). Every route method returns
// the route's `OpenAPIOperation`, whose methods add what the types cannot
// say: a summary, tags, the statuses a thrown error answers with.
//
// A raw route, `(borrowing Request, inout Response)`, is listed with its path
// parameters and whatever its operation is told. An extractor or response
// type of your own describes itself by conforming to
// `OpenAPIExtractorDescribing` or `OpenAPIResponseDescribing`.
//
// The document is built once, when the application is compiled, and served
// as it is. `openAPIDocument` returns it for a build step that writes a file.
//===----------------------------------------------------------------------===//

import AvianCore
import AvianHTTP

// MARK: - Describing a route

/// Where a parameter is sent.
public enum OpenAPIParameterLocation: String, Sendable {
    case path, query, header, cookie
}

/// How a route authenticates, as OpenAPI's security schemes say it.
public enum OpenAPISecurityScheme: Sendable {
    /// `Authorization: Bearer`, with an optional hint at the token's format.
    case bearer(format: String? = nil)
    /// `Authorization: Basic`.
    case basic
    /// A key in a header, query parameter or cookie of this name.
    case apiKey(name: String, in: OpenAPIParameterLocation)

    var name: String {
        switch self {
        case .bearer: return "bearerAuth"
        case .basic: return "basicAuth"
        case .apiKey(let name, let location): return "apiKey_\(location.rawValue)_\(name)"
        }
    }

    var definition: OpenAPIValue {
        switch self {
        case .bearer(let format):
            var members: [(String, OpenAPIValue)] = [("type", "http"), ("scheme", "bearer")]
            if let format { members.append(("bearerFormat", .string(format))) }
            return .object(members)
        case .basic:
            return ["type": "http", "scheme": "basic"]
        case .apiKey(let name, let location):
            return ["type": "apiKey", "name": .string(name), "in": .string(location.rawValue)]
        }
    }
}

/// One route's entry in the OpenAPI document, which its registration returns.
/// Each method adds to it and returns it, so they chain.
public final class OpenAPIOperation: @unchecked Sendable {
    typealias Make = (OpenAPISchemas) -> OpenAPIValue

    public let method: HTTPMethod
    public let pattern: String

    var summaryText: String? = nil
    var descriptionText: String? = nil
    var identifier: String? = nil
    var tagList: [String] = []
    var isDeprecated = false
    var isHidden = false
    /// The schema of each path parameter, in order, from `Path` extractors.
    var pathSchemas: [Make] = []
    var parameters: [(OpenAPISchemas) -> [OpenAPIValue]] = []
    var requestBodyMake: Make? = nil
    /// Responses by status code, the one the return type implies first.
    var responses: [(code: String, make: Make)] = []
    var security: [OpenAPISecurityScheme] = []

    public init(_ method: HTTPMethod, _ pattern: String) {
        self.method = method
        self.pattern = pattern
    }

    /// A line saying what the route does.
    @discardableResult
    public func summary(_ text: String) -> Self {
        summaryText = text
        return self
    }

    /// A longer account of the route, CommonMark allowed.
    @discardableResult
    public func description(_ text: String) -> Self {
        descriptionText = text
        return self
    }

    /// Tags that group the route with others in a viewer.
    @discardableResult
    public func tags(_ tags: String...) -> Self {
        tagList += tags
        return self
    }

    /// A name for the operation unique in the document, which generated
    /// clients use as a function name.
    @discardableResult
    public func operationID(_ id: String) -> Self {
        identifier = id
        return self
    }

    @discardableResult
    public func deprecated(_ deprecated: Bool = true) -> Self {
        isDeprecated = deprecated
        return self
    }

    /// Leaves the route out of the document.
    @discardableResult
    public func hidden(_ hidden: Bool = true) -> Self {
        isHidden = hidden
        return self
    }

    /// A status the route answers with and what it means, with no body.
    @discardableResult
    public func response(_ status: HTTPStatus, _ description: String) -> Self {
        setResponse(String(status.code)) { _ in ["description": .string(description)] }
    }

    /// A status the route answers with, and the JSON body it carries.
    @discardableResult
    public func response<T: Decodable>(_ status: HTTPStatus, _ description: String, json type: T.Type) -> Self {
        setResponse(String(status.code)) { schemas in
            ["description": .string(description),
             "content": ["application/json": ["schema": schemas.schema(for: T.self)]]]
        }
    }

    /// A status the route answers with, and a body of `contentType`.
    @discardableResult
    public func response(_ status: HTTPStatus, _ description: String, contentType: String) -> Self {
        setResponse(String(status.code)) { _ in
            ["description": .string(description), "content": .object([(contentType, OpenAPIValue.object([]))])]
        }
    }

    /// The 422 an input with rules of its own can answer with, and the body
    /// it carries. Nothing is added for a type conforming to nothing, since
    /// such a route has no rule to break.
    @discardableResult
    public func validationResponse<Value>(_ type: Value.Type) -> Self {
        guard Value.self is any Validated.Type else { return self }
        return response(.unprocessableContent, "A field breaks one of this route's rules",
                        json: ErrorBody.self)
    }

    /// Says the route needs `scheme`. Called more than once, it needs every
    /// one of them.
    @discardableResult
    public func security(_ scheme: OpenAPISecurityScheme) -> Self {
        if !security.contains(where: { $0.name == scheme.name }) { security.append(scheme) }
        return self
    }

    // MARK: For extractors and response types

    /// The schema of the next path parameter, in the order a `Path` takes them.
    public func pathParameter(schema: @escaping (OpenAPISchemas) -> OpenAPIValue) {
        pathSchemas.append(schema)
    }

    /// A header, query or cookie parameter.
    public func parameter(_ name: String, in location: OpenAPIParameterLocation, required: Bool,
                          description: String? = nil, schema: OpenAPIValue = ["type": "string"]) {
        parameters.append { _ in
            var members: [(String, OpenAPIValue)] = [
                ("name", .string(name)), ("in", .string(location.rawValue)), ("required", .bool(required)),
            ]
            if let description { members.append(("description", .string(description))) }
            members.append(("schema", schema))
            return [.object(members)]
        }
    }

    /// A query parameter for each field of `type`, required unless optional.
    public func queryParameters<T: Decodable>(_ type: T.Type) {
        parameters.append { schemas in
            let object = schemas.resolved(T.self)
            guard case .object(let properties)? = object["properties"] else { return [] }
            var required: [String] = []
            if case .array(let names)? = object["required"] {
                for case .string(let name) in names { required.append(name) }
            }
            return properties.map { name, schema in
                ["name": .string(name), "in": "query", "required": .bool(required.contains(name)), "schema": schema]
            }
        }
    }

    /// The request body: `type` as `contentType`, JSON unless said otherwise.
    public func requestBody<T: Decodable>(_ type: T.Type, contentType: String = "application/json",
                                          required: Bool = true) {
        requestBodyMake = { schemas in
            let media: OpenAPIValue = ["schema": schemas.schema(for: T.self)]
            return ["required": .bool(required), "content": .object([(contentType, media)])]
        }
    }

    /// A request body of `contentType`, described by `schema`.
    public func requestBody(contentType: String, schema: OpenAPIValue = [:], required: Bool = true) {
        requestBodyMake = { _ in
            let media: OpenAPIValue = ["schema": schema]
            return ["required": .bool(required), "content": .object([(contentType, media)])]
        }
    }

    /// The response the handler's return type implies, which a `response`
    /// for the same status replaces.
    public func impliedResponse(_ status: HTTPStatus, _ description: String, contentType: String?,
                                schema: ((OpenAPISchemas) -> OpenAPIValue)? = nil) {
        let code = String(status.code)
        guard !responses.contains(where: { $0.code == code }) else { return }
        responses.insert((code, { schemas in
            guard let contentType else { return ["description": .string(description)] }
            let media: OpenAPIValue = schema.map { ["schema": $0(schemas)] } ?? [:]
            return ["description": .string(description), "content": .object([(contentType, media)])]
        }), at: 0)
    }

    private func setResponse(_ code: String, _ make: @escaping Make) -> Self {
        if let index = responses.firstIndex(where: { $0.code == code }) {
            responses[index] = (code, make)
        } else {
            responses.append((code, make))
        }
        return self
    }

    /// Adds what `type` says about itself, when it says anything.
    func describeExtractor<E: RequestExtractor>(_ type: E.Type) {
        (E.self as? any OpenAPIExtractorDescribing.Type)?.describe(self)
    }

    func describeResponse<R: ResponseConvertible>(_ type: R.Type) {
        if let described = R.self as? any OpenAPIResponseDescribing.Type {
            described.describe(self)
        }
    }
}

/// An extractor that says what it takes from the request.
public protocol OpenAPIExtractorDescribing {
    static func describe(_ operation: OpenAPIOperation)
}

/// A response type that says what it answers with.
public protocol OpenAPIResponseDescribing {
    static func describe(_ operation: OpenAPIOperation)
}

/// The schema of a type known only to be `Decodable` at run time.
func openAPISchema(_ type: any Decodable.Type, _ schemas: OpenAPISchemas) -> OpenAPIValue {
    schemas.schema(for: type)
}

// MARK: - What the built-in types say

extension Path: OpenAPIExtractorDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.pathParameter { schemas in
            (Value.self as? any Decodable.Type).map { openAPISchema($0, schemas) } ?? ["type": "string"]
        }
    }
}

extension Query: OpenAPIExtractorDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.queryParameters(Value.self)
        operation.validationResponse(Value.self)
    }
}

extension Body: OpenAPIExtractorDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.requestBody(Value.self)
        operation.response(.badRequest, "The body is not the JSON this route takes")
        operation.validationResponse(Value.self)
    }
}

extension Form: OpenAPIExtractorDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.requestBody(Value.self, contentType: "application/x-www-form-urlencoded")
        operation.validationResponse(Value.self)
    }
}

extension Multipart: OpenAPIExtractorDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.requestBody(contentType: "multipart/form-data", schema: ["type": "object"])
    }
}

extension BearerToken: OpenAPIExtractorDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.security(.bearer())
        operation.response(.unauthorized, "No valid bearer token")
    }
}

extension BasicCredentials: OpenAPIExtractorDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.security(.basic)
        operation.response(.unauthorized, "No valid credentials")
    }
}

extension LastEventID: OpenAPIExtractorDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.parameter("Last-Event-ID", in: .header, required: false,
                            description: "The last event a reconnecting client saw")
    }
}

extension JSON: OpenAPIResponseDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        let decodable = Value.self as? any Decodable.Type
        operation.impliedResponse(.ok, "OK", contentType: "application/json",
                                  schema: decodable.map { type in { openAPISchema(type, $0) } })
    }
}

extension String: OpenAPIResponseDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.impliedResponse(.ok, "OK", contentType: "text/plain", schema: { _ in ["type": "string"] })
    }
}

extension Text: OpenAPIResponseDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.impliedResponse(.ok, "OK", contentType: "text/plain", schema: { _ in ["type": "string"] })
    }
}

extension HTML: OpenAPIResponseDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.impliedResponse(.ok, "OK", contentType: "text/html", schema: { _ in ["type": "string"] })
    }
}

extension Bytes: OpenAPIResponseDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.impliedResponse(.ok, "OK", contentType: "application/octet-stream")
    }
}

extension EventStream: OpenAPIResponseDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.impliedResponse(.ok, "A stream of server-sent events", contentType: "text/event-stream")
    }
}

extension Optional: OpenAPIResponseDescribing where Wrapped: ResponseConvertible {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.describeResponse(Wrapped.self)
        operation.response(.notFound, "Not found")
    }
}

// MARK: - The document

/// What the document says about the API as a whole.
public struct OpenAPIInfo: Sendable {
    public var title: String
    public var version: String
    public var summary: String?
    public var description: String?
    /// Base URLs the API is served from, such as `https://api.example.com`.
    public var servers: [String]

    public init(title: String, version: String, summary: String? = nil, description: String? = nil,
                servers: [String] = []) {
        self.title = title
        self.version = version
        self.summary = summary
        self.description = description
        self.servers = servers
    }
}

/// A document the application fills in when it compiles.
final class OpenAPIDocumentBox: @unchecked Sendable {
    let info: OpenAPIInfo
    var json: [UInt8] = []

    init(_ info: OpenAPIInfo) {
        self.info = info
    }
}

extension Application {
    /// Serves the OpenAPI document of every route at `path`, as JSON.
    public func openAPI(_ info: OpenAPIInfo, path: String = "/openapi.json") {
        precondition(compiled == nil, "openAPI added after the application was compiled")
        let box = OpenAPIDocumentBox(info)
        openAPIDocuments.append(box)
        get(path) { _, response in
            response.send(bytes: box.json, contentType: "application/json")
        }
        .hidden()
    }

    /// Serves Swagger UI at `path`, reading the document at `openAPIPath`.
    /// The page loads Swagger UI's script and style from jsDelivr.
    public func swaggerUI(path: String = "/docs", openAPIPath: String = "/openapi.json",
                          title: String = "API documentation") {
        let page = swaggerPage(title: title, document: relativeURL(from: path, to: openAPIPath))
        get(path) { _, response in
            response.send(html: page)
        }
        .hidden()
    }

    /// The OpenAPI document of the routes registered so far.
    public func openAPIDocument(_ info: OpenAPIInfo) -> OpenAPIValue {
        routes.openAPIDocument(info)
    }

    /// The document as JSON text, indented.
    public func openAPIJSON(_ info: OpenAPIInfo) -> String {
        writeOpenAPIJSON(openAPIDocument(info), indent: true)
    }
}

extension Routes {
    func openAPIDocument(_ info: OpenAPIInfo) -> OpenAPIValue {
        let schemas = OpenAPISchemas()
        var paths: [(String, [(String, OpenAPIValue)])] = []
        var schemes: [(String, OpenAPIValue)] = []

        for index in handlers.indices {
            guard let full = patterns[index], let method = methods[index] else { continue }
            let operation = operations[index] ?? OpenAPIOperation(method, full)
            if operation.isHidden { continue }
            let (path, names) = openAPIPath(full)
            guard let methodName = openAPIMethodName(method) else { continue }

            var members: [(String, OpenAPIValue)] = []
            if !operation.tagList.isEmpty { members.append(("tags", .array(operation.tagList.map { .string($0) }))) }
            if let summary = operation.summaryText { members.append(("summary", .string(summary))) }
            if let description = operation.descriptionText { members.append(("description", .string(description))) }
            if let id = operation.identifier { members.append(("operationId", .string(id))) }

            var parameters: [OpenAPIValue] = names.enumerated().map { i, name in
                let schema = i < operation.pathSchemas.count ? operation.pathSchemas[i](schemas) : ["type": "string"]
                return ["name": .string(name), "in": "path", "required": true, "schema": schema]
            }
            for make in operation.parameters { parameters += make(schemas) }
            if !parameters.isEmpty { members.append(("parameters", .array(parameters))) }
            if let body = operation.requestBodyMake { members.append(("requestBody", body(schemas))) }

            var responses = operation.responses.map { ($0.code, $0.make(schemas)) }
            if responses.isEmpty { responses = [("default", ["description": "The route's answer"])] }
            members.append(("responses", .object(responses)))
            if operation.isDeprecated { members.append(("deprecated", true)) }
            if !operation.security.isEmpty {
                members.append(("security", .array(operation.security.map { .object([($0.name, OpenAPIValue.array([]))]) })))
                for scheme in operation.security where !schemes.contains(where: { $0.0 == scheme.name }) {
                    schemes.append((scheme.name, scheme.definition))
                }
            }

            if let at = paths.firstIndex(where: { $0.0 == path }) {
                if !paths[at].1.contains(where: { $0.0 == methodName }) {
                    paths[at].1.append((methodName, .object(members)))
                }
            } else {
                paths.append((path, [(methodName, .object(members))]))
            }
        }

        var infoMembers: [(String, OpenAPIValue)] = [("title", .string(info.title))]
        if let summary = info.summary { infoMembers.append(("summary", .string(summary))) }
        if let description = info.description { infoMembers.append(("description", .string(description))) }
        infoMembers.append(("version", .string(info.version)))

        var document: [(String, OpenAPIValue)] = [("openapi", "3.1.0"), ("info", .object(infoMembers))]
        if !info.servers.isEmpty {
            document.append(("servers", .array(info.servers.map { ["url": .string($0)] })))
        }
        document.append(("paths", .object(paths.map { ($0.0, .object($0.1)) })))
        var components: [(String, OpenAPIValue)] = []
        if !schemas.components.isEmpty { components.append(("schemas", .object(schemas.components))) }
        if !schemes.isEmpty { components.append(("securitySchemes", .object(schemes))) }
        if !components.isEmpty { document.append(("components", .object(components))) }
        return .object(document)
    }
}

/// A Garuda pattern as an OpenAPI path, `:id` and `*rest` as `{id}` and
/// `{rest}`, with the parameters' names in order.
func openAPIPath(_ pattern: String) -> (String, [String]) {
    var names: [String] = []
    let segments = pattern.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
        guard let first = segment.first, first == ":" || first == "*", segment.count > 1 else { return String(segment) }
        let name = String(segment.dropFirst())
        names.append(name)
        return "{" + name + "}"
    }
    let path = segments.joined(separator: "/")
    return (path.isEmpty ? "/" : path, names)
}

private func openAPIMethodName(_ method: HTTPMethod) -> String? {
    switch method {
    case .get: return "get"
    case .head: return "head"
    case .post: return "post"
    case .put: return "put"
    case .delete: return "delete"
    case .patch: return "patch"
    case .options: return "options"
    case .trace: return "trace"
    default: return nil
    }
}

// MARK: - Registration

extension Application {
    public func document(_ operation: OpenAPIOperation) {
        precondition(compiled == nil, "route documented after the application was compiled")
        guard !routes.operations.isEmpty else { return }
        routes.operations[routes.operations.count - 1] = operation
    }
}

extension Router {
    public func document(_ operation: OpenAPIOperation) {
        addDocumentation(operation)
    }
}

// MARK: - Writing JSON

func writeOpenAPIJSON(_ value: OpenAPIValue, indent: Bool) -> String {
    var out = ""
    write(value, into: &out, depth: 0, indent: indent)
    if indent { out += "\n" }
    return out
}

private func write(_ value: OpenAPIValue, into out: inout String, depth: Int, indent: Bool) {
    func newline(_ depth: Int) {
        guard indent else { return }
        out += "\n"
        out += String(repeating: "  ", count: depth)
    }
    switch value {
    case .string(let text):
        writeJSONString(text, into: &out)
    case .integer(let number):
        out += String(number)
    case .number(let number):
        out += number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : "\(number)"
    case .bool(let flag):
        out += flag ? "true" : "false"
    case .null:
        out += "null"
    case .array(let items):
        guard !items.isEmpty else { out += "[]"; return }
        out += "["
        for (i, item) in items.enumerated() {
            if i > 0 { out += "," }
            newline(depth + 1)
            write(item, into: &out, depth: depth + 1, indent: indent)
        }
        newline(depth)
        out += "]"
    case .object(let members):
        guard !members.isEmpty else { out += "{}"; return }
        out += "{"
        for (i, member) in members.enumerated() {
            if i > 0 { out += "," }
            newline(depth + 1)
            writeJSONString(member.0, into: &out)
            out += indent ? ": " : ":"
            write(member.1, into: &out, depth: depth + 1, indent: indent)
        }
        newline(depth)
        out += "}"
    }
}

private func writeJSONString(_ text: String, into out: inout String) {
    out += "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
}

// MARK: - Swagger UI

/// `target` as a URL relative to the page at `page`, so both still meet
/// under --root-path or a proxy's prefix.
func relativeURL(from page: String, to target: String) -> String {
    let depth = max(0, page.split(separator: "/", omittingEmptySubsequences: false).count - 2)
    let trimmed = target.hasPrefix("/") ? String(target.dropFirst()) : target
    return depth == 0 ? "./" + trimmed : String(repeating: "../", count: depth) + trimmed
}

private func swaggerPage(title: String, document: String) -> String {
    var safeTitle = ""
    for c in title {
        switch c {
        case "&": safeTitle += "&amp;"
        case "<": safeTitle += "&lt;"
        case ">": safeTitle += "&gt;"
        default: safeTitle.append(c)
        }
    }
    var url = ""
    writeJSONString(document, into: &url)
    var script = ""
    for c in url {
        if c == "<" { script += "\\u003c" } else { script.append(c) }
    }
    return """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(safeTitle)</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
    </head>
    <body>
    <div id="swagger-ui"></div>
    <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js" crossorigin></script>
    <script>
    window.ui = SwaggerUIBundle({ url: new URL(\(script), window.location.href).href, dom_id: "#swagger-ui" });
    </script>
    </body>
    </html>
    """
}
