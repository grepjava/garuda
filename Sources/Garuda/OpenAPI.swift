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
// `Filter`'s fields, `Body<NewOrder>` is a JSON request body, `Form` and
// `Multipart` are form bodies, `BearerToken` is bearer authentication, and
// `JSON<Order>` is a JSON 200 -- each schema read from the `Decodable` type
// (OpenAPISchema.swift). `State` and `Context` take nothing from the request
// and say nothing; an optional or `Result` extractor says what the one it
// wraps says. Every route method returns the route's `OpenAPIOperation`,
// whose methods add what the types cannot say: a summary, tags, the statuses
// a thrown error answers with.
//
// A raw route, `(borrowing Request, borrowing Response)`, is listed with its
// path parameters and whatever its operation is told. An extractor or
// response type of your own describes itself by conforming to
// `OpenAPIExtractorDescribing` or `OpenAPIResponseDescribing`.
//
// A scope can speak for every route in it: `authenticate` adds its security
// scheme and 401, `authorize` its 403, through `describeRoutes`. A note is
// kept with the scope, like its middleware, and applied when the document is
// written, so it reaches routes registered before it as well.
//
// None of this costs a request anything. What a route says about itself is
// gathered when it is registered, by casting its extractor and answer types
// once; the document is built from that when it is asked for, and the one
// `openAPI` serves is built once, when the application compiles, and sent as
// the bytes it already is.
//===----------------------------------------------------------------------===//

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

/// What a scope adds to the OpenAPI entry of every route in it, through
/// `describeRoutes`.
public typealias OperationNote = (OpenAPIOperation) -> Void

/// One route's entry in the OpenAPI document, which its registration returns.
/// Each method adds to it and returns it, so they chain.
///
/// It is only ever touched while routes are registered and when a document
/// is built, both on the thread that sets the application up.
public final class OpenAPIOperation: @unchecked Sendable {
    typealias Make = (OpenAPISchemas) -> OpenAPIValue

    public let method: HTTPMethod
    /// The pattern as it was registered, inside its groups.
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

    /// A copy for one document to apply its scopes' notes to, so the route's
    /// own entry -- which a router mounted twice shares between both places
    /// -- never carries what one scope said into another, or into the next
    /// document.
    func copy() -> OpenAPIOperation {
        let copy = OpenAPIOperation(method, pattern)
        copy.summaryText = summaryText
        copy.descriptionText = descriptionText
        copy.identifier = identifier
        copy.tagList = tagList
        copy.isDeprecated = isDeprecated
        copy.isHidden = isHidden
        copy.pathSchemas = pathSchemas
        copy.parameters = parameters
        copy.requestBodyMake = requestBodyMake
        copy.responses = responses
        copy.security = security
        return copy
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

    /// A status the route's scope can answer with -- the 401 of an
    /// `authenticate`, the 403 of an `authorize` -- which leaves alone what
    /// the route has said about that status itself.
    @discardableResult
    public func scopeResponse(_ status: HTTPStatus, _ description: String) -> Self {
        let code = String(status.code)
        guard !responses.contains(where: { $0.code == code }) else { return self }
        responses.append((code, { _ in ["description": .string(description)] }))
        return self
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

    /// Adds what `type` says about itself, when it says anything. A typed
    /// route calls this once per extractor, when it is registered.
    @usableFromInline
    func describeExtractor<E: RequestExtractor>(_ type: E.Type) {
        (E.self as? any OpenAPIExtractorDescribing.Type)?.describe(self)
    }

    /// Adds what the answer type `type` says about itself.
    @usableFromInline
    func describeResponse<R: ResponseConvertible>(_ type: R.Type) {
        (R.self as? any OpenAPIResponseDescribing.Type)?.describe(self)
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

/// A `JWT` reads a bearer token, as `authenticate(jwt:)` does, and is
/// written the same way.
extension JWT: OpenAPIExtractorDescribing {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.security(.bearer(format: "JWT"))
        operation.response(.unauthorized, "No valid bearer token")
    }
}

/// What an optional or `Result` extractor takes is what the one it wraps
/// takes: it only changes what a refusal means.
extension Optional: OpenAPIExtractorDescribing where Wrapped: RequestExtractor {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.describeExtractor(Wrapped.self)
    }
}

extension Result: OpenAPIExtractorDescribing where Success: RequestExtractor, Failure == any Error {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.describeExtractor(Success.self)
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

extension Optional: OpenAPIResponseDescribing where Wrapped: ResponseConvertible {
    public static func describe(_ operation: OpenAPIOperation) {
        operation.describeResponse(Wrapped.self)
        operation.response(.notFound, "Not found")
    }
}

// MARK: - Registration

/// What an application keeps for its document: each route's operation, the
/// notes of its scopes, and the documents it serves.
struct APIDocumentation {
    /// The operation of each route that has one, by route index. A route
    /// registered through the protocol's `on` alone has none, and is listed
    /// with what its pattern says.
    var operations: [Int: OpenAPIOperation] = [:]
    /// `describeRoutes` outside any group, and in groups, by group.
    var notes: [OperationNote] = []
    var groupNotes: [Int: [OperationNote]] = [:]
    /// What `openAPI` serves, filled in when the application compiles.
    var served: [OpenAPIDocumentBox] = []
}

extension RouteBuilder {
    /// Registers a raw handler and gives it an operation to be told about.
    func documentedRoute(_ method: HTTPMethod, _ pattern: String,
                         _ handler: @escaping Handler) -> OpenAPIOperation {
        on(method, pattern, handler)
        let operation = OpenAPIOperation(method, pattern)
        document(operation)
        return operation
    }
}

extension Application {
    public func document(_ operation: OpenAPIOperation) {
        precondition(compiledApplication == nil, "route documented after the application was compiled")
        guard let last = routes.indices.last, routes[last].registeredPattern == operation.pattern,
              routes[last].method == operation.method else { return }
        documentation.operations[last] = operation
    }

    public func describeRoutes(_ note: @escaping OperationNote) {
        precondition(compiledApplication == nil, "routes described after the application was compiled")
        if let group = openGroups.last {
            documentation.groupNotes[group, default: []].append(note)
        } else {
            documentation.notes.append(note)
        }
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

/// A document `openAPI` serves, written when the application compiles and
/// only read after that.
final class OpenAPIDocumentBox: @unchecked Sendable {
    let info: OpenAPIInfo
    var json: [UInt8] = []

    init(_ info: OpenAPIInfo) {
        self.info = info
    }
}

extension Application {
    /// Serves the OpenAPI document of every route at `path`, as JSON. The
    /// document is written once, when the application compiles, so it has
    /// every route however late it was registered, and serving it is sending
    /// bytes already made.
    public func openAPI(_ info: OpenAPIInfo, path: String = "/openapi.json") {
        precondition(compiledApplication == nil, "openAPI added after the application was compiled")
        let box = OpenAPIDocumentBox(info)
        documentation.served.append(box)
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
        buildOpenAPIDocument(info)
    }

    /// The document as JSON text, indented: what `openAPI` serves.
    public func openAPIJSON(_ info: OpenAPIInfo) -> String {
        String(decoding: openAPIBytes(openAPIDocument(info), indent: true), as: UTF8.self)
    }

    /// Writes every document `openAPI` serves. `compile` calls it, once.
    func writeServedDocuments() {
        for box in documentation.served {
            box.json = openAPIBytes(buildOpenAPIDocument(box.info), indent: true)
        }
    }

    /// The document. `schemas` is taken rather than made when a caller
    /// wants to see what reading the types found: `documentProblems`.
    func buildOpenAPIDocument(_ info: OpenAPIInfo,
                              into schemas: OpenAPISchemas = OpenAPISchemas()) -> OpenAPIValue {
        var paths: [(String, [(String, OpenAPIValue)])] = []
        var schemes: [(String, OpenAPIValue)] = []

        for (index, route) in routes.enumerated() {
            let operation = documentedOperation(index)
            if operation.isHidden { continue }
            let (path, names) = openAPIPath(route.pattern)
            guard let methodName = openAPIMethodName(route.method) else { continue }

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

    /// Route `index`'s operation with what its scopes add: a rule of a scope
    /// applies to every route in it, so it is added here rather than at
    /// registration, where a route registered before the rule would have
    /// missed it. The notes are applied to a copy, so the route's own entry
    /// is the same however many documents are written.
    func documentedOperation(_ index: Int) -> OpenAPIOperation {
        let route = routes[index]
        let operation = documentation.operations[index]?.copy()
            ?? OpenAPIOperation(route.method, route.registeredPattern)
        for note in documentation.notes { note(operation) }
        for group in route.groups {
            for note in documentation.groupNotes[group] ?? [] { note(operation) }
        }
        return operation
    }

    // MARK: Checks

    /// What the OpenAPI document cannot promise, for a team generating
    /// clients from it. Empty when it says everything it should.
    ///
    /// ```
    /// #expect(app.documentProblems(info).isEmpty)
    /// ```
    ///
    /// What it finds:
    ///
    /// - A schema read from a type whose decoding stopped early, which is a
    ///   schema that may be missing whatever came after. Such a type either
    ///   conforms to `OpenAPISchemaDescribing` and says what it is, or gets
    ///   named here.
    /// - Two routes with the same `operationID`, which generated clients turn
    ///   into two functions of one name. (Two routes with the same method and
    ///   path cannot get this far: the route table refuses them.)
    ///
    /// It does not serve anything, so the document it builds is thrown away.
    public func documentProblems(_ info: OpenAPIInfo) -> [String] {
        var found: [String] = []
        var identifiers: [String: String] = [:]
        for (index, route) in routes.enumerated() {
            guard let operation = documentation.operations[index], !operation.isHidden,
                  let name = openAPIMethodName(route.method) else { continue }
            let (path, _) = openAPIPath(route.pattern)
            let described = name.uppercased() + " " + path
            if let id = operation.identifier {
                if let other = identifiers[id] {
                    found.append("\(described) and \(other) share the operationID \"\(id)\"")
                }
                identifiers[id] = described
            }
        }
        // Building the document is what reads the types, so the schemas only
        // know what is uncertain afterwards.
        let schemas = OpenAPISchemas()
        _ = buildOpenAPIDocument(info, into: schemas)
        for (type, reason) in schemas.uncertain {
            found.append("the schema for \(type) may be incomplete: \(reason)")
        }
        return found
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

func openAPIMethodName(_ method: HTTPMethod) -> String? {
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

// MARK: - Writing JSON

/// Compact, through the same writer as every JSON answer.
extension OpenAPIValue: JSONWritable {
    public func write(json output: inout JSONOutput) {
        write(into: &output, depth: 0, indent: false)
    }

    /// Writes the value, its members on lines of their own indented by two
    /// spaces a level when `indent` is set, for a document people read.
    func write(into output: inout JSONOutput, depth: Int, indent: Bool) {
        switch self {
        case .string(let text):
            output.write(text)
        case .integer(let number):
            output.write(number)
        case .number(let number):
            output.write(number)
        case .bool(let flag):
            output.write(flag)
        case .null:
            output.writeNull()
        case .array(let items):
            output.beginArray()
            guard !items.isEmpty else { return output.endArray() }
            for (i, item) in items.enumerated() {
                if i > 0 { output.comma() }
                newline(&output, depth + 1, indent)
                item.write(into: &output, depth: depth + 1, indent: indent)
            }
            newline(&output, depth, indent)
            output.endArray()
        case .object(let members):
            output.beginObject()
            guard !members.isEmpty else { return output.endObject() }
            for (i, member) in members.enumerated() {
                if i > 0 { output.comma() }
                newline(&output, depth + 1, indent)
                output.write(member.0)
                if indent { output.append(": ") } else { output.colon() }
                member.1.write(into: &output, depth: depth + 1, indent: indent)
            }
            newline(&output, depth, indent)
            output.endObject()
        }
    }
}

private func newline(_ output: inout JSONOutput, _ depth: Int, _ indent: Bool) {
    guard indent else { return }
    output.append("\n")
    for _ in 0..<depth { output.append("  ") }
}

/// The document's bytes, ending in a newline when indented.
func openAPIBytes(_ value: OpenAPIValue, indent: Bool) -> [UInt8] {
    var output = JSONOutput(capacity: 4096)
    value.write(into: &output, depth: 0, indent: indent)
    if indent { output.append("\n") }
    return output.bytes
}

func writeOpenAPIJSON(_ value: OpenAPIValue, indent: Bool) -> String {
    String(decoding: openAPIBytes(value, indent: indent), as: UTF8.self)
}

// MARK: - Swagger UI

/// `target` as a URL relative to the page at `page`, so both still meet
/// under a proxy's prefix.
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
    // The URL as a JavaScript string: JSON's escaping, and `<` and the two
    // line separators JavaScript once refused written as escapes too, so
    // nothing in it can close the script element.
    var quoted = JSONOutput()
    quoted.write(document)
    var script = ""
    for scalar in String(decoding: quoted.bytes, as: UTF8.self).unicodeScalars {
        switch scalar {
        case "<": script += "\\u003c"
        case "\u{2028}": script += "\\u2028"
        case "\u{2029}": script += "\\u2029"
        default: script.unicodeScalars.append(scalar)
        }
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
