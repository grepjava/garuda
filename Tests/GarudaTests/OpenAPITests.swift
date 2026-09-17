import Testing
import CAvian
#if canImport(Glibc)
import Glibc
#endif
@testable import Garuda
import AvianHTTP

// The OpenAPI document: schemas from Decodable types, operations from typed
// routes and what they are told, and the document and Swagger UI served.

private enum Status: String, Codable, CaseIterable {
    case open, shipped, cancelled
}

private enum Priority: Int, Codable, CaseIterable {
    case low = 1, high = 2
}

private struct Line: Codable {
    var sku: String
    var quantity: Int
}

private struct Order: Codable {
    var id: Int
    var number: Int64
    var total: Double
    var paid: Bool
    var note: String?
    var status: Status
    var priority: Priority
    var lines: [Line]
    var tags: Set<String>
    var attributes: [String: String]
    var reference: Garuda.UUID
    var placedAt: Timestamp
    var shipping: Line?
}

private struct Category: Codable {
    var name: String
    var children: [Category]
    var parent: Box?
}

private final class Box: Codable {
    var inner: Category
}

private struct Page<Item: Codable>: Codable {
    var items: [Item]
    var next: String?
}

private struct Filter: Decodable {
    var status: Status?
    var limit: Int
}

private struct NewOrder: Decodable {
    var lines: [Line]
}

private struct Money: Decodable, OpenAPISchemaDescribing {
    var cents: Int
    init(from decoder: any Decoder) throws {
        let text = try String(from: decoder)
        cents = Int(text) ?? 0
    }
    static func openAPISchema(_ schemas: OpenAPISchemas) -> OpenAPIValue {
        ["type": "string", "pattern": "^[0-9]+\\.[0-9]{2}$"]
    }
}

/// The value at a path of object keys and array indices.
private func at(_ value: OpenAPIValue?, _ path: Any...) -> OpenAPIValue? {
    var current = value
    for step in path {
        guard let now = current else { return nil }
        if let key = step as? String {
            current = now[key]
        } else if let index = step as? Int, case .array(let items) = now {
            current = index < items.count ? items[index] : nil
        } else {
            return nil
        }
    }
    return current
}

private func keys(_ value: OpenAPIValue?) -> [String] {
    guard case .object(let members)? = value else { return [] }
    return members.map(\.0)
}

@Suite("OpenAPI schemas")
struct OpenAPISchemaTests {
    @Test func aCodableStructBecomesAComponent() {
        let schemas = OpenAPISchemas()
        #expect(schemas.schema(for: Order.self) == ["$ref": "#/components/schemas/Order"])
        #expect(schemas.components.map(\.0) == ["Line", "Order"])
        let order = schemas.resolved(Order.self)
        #expect(keys(order["properties"]) == ["id", "number", "total", "paid", "note", "status", "priority",
                                               "lines", "tags", "attributes", "reference", "placedAt", "shipping"])
        #expect(order["required"] == ["id", "number", "total", "paid", "status", "priority", "lines", "tags",
                                      "attributes", "reference", "placedAt"])
        #expect(at(order, "properties", "id") == ["type": "integer", "format": "int64"])
        #expect(at(order, "properties", "total") == ["type": "number", "format": "double"])
        #expect(at(order, "properties", "paid") == ["type": "boolean"])
        #expect(at(order, "properties", "note") == ["type": "string"])
        #expect(at(order, "properties", "status") == ["type": "string", "enum": ["open", "shipped", "cancelled"]])
        #expect(at(order, "properties", "priority") == ["type": "integer", "enum": [1, 2]])
        #expect(at(order, "properties", "lines") == ["type": "array", "items": ["$ref": "#/components/schemas/Line"]])
        #expect(at(order, "properties", "tags") == ["type": "array", "items": ["type": "string"], "uniqueItems": true])
        #expect(at(order, "properties", "attributes") == ["type": "object", "additionalProperties": ["type": "string"]])
        #expect(at(order, "properties", "reference") == ["type": "string", "format": "uuid"])
        #expect(at(order, "properties", "placedAt") == ["type": "string", "format": "date-time"])
        #expect(at(order, "properties", "shipping") == ["$ref": "#/components/schemas/Line"])
        #expect(schemas.resolved(Line.self) == [
            "type": "object",
            "properties": ["sku": ["type": "string"], "quantity": ["type": "integer", "format": "int64"]],
            "required": ["sku", "quantity"],
        ])
    }

    @Test func typesThatHoldThemselvesReferToThemselves() {
        let schemas = OpenAPISchemas()
        #expect(schemas.schema(for: Category.self) == ["$ref": "#/components/schemas/Category"])
        let category = schemas.resolved(Category.self)
        #expect(at(category, "properties", "children", "items") == ["$ref": "#/components/schemas/Category"])
        #expect(at(category, "properties", "parent") == ["$ref": "#/components/schemas/Box"])
        #expect(at(schemas.resolved(Box.self), "properties", "inner") == ["$ref": "#/components/schemas/Category"])
    }

    @Test func valuesGenericsAndTypesThatDescribeThemselves() {
        let schemas = OpenAPISchemas()
        #expect(schemas.schema(for: [Int].self) == ["type": "array", "items": ["type": "integer", "format": "int64"]])
        #expect(schemas.schema(for: String?.self) == ["type": "string"])
        #expect(schemas.schema(for: Status.self) == ["type": "string", "enum": ["open", "shipped", "cancelled"]])
        #expect(schemas.schema(for: Money.self) == ["type": "string", "pattern": "^[0-9]+\\.[0-9]{2}$"])
        #expect(schemas.schema(for: Page<Line>.self) == ["$ref": "#/components/schemas/Page_Line"])
        #expect(at(schemas.resolved(Page<Line>.self), "properties", "items", "items")
            == ["$ref": "#/components/schemas/Line"])
        #expect(schemas.components.map(\.0) == ["Line", "Page_Line"])
    }

    @Test func theDocumentIsWrittenAsJSON() {
        let value: OpenAPIValue = ["a": "x\"y\n\u{1}", "b": [1, 2.5, true, .null], "c": [:], "d": []]
        #expect(writeOpenAPIJSON(value, indent: false) == #"{"a":"x\"y\n\u0001","b":[1,2.5,true,null],"c":{},"d":[]}"#)
        #expect(writeOpenAPIJSON(["k": [1]], indent: true) == "{\n  \"k\": [\n    1\n  ]\n}\n")
    }
}

@Suite("OpenAPI document")
struct OpenAPIDocumentTests {
    private let info = OpenAPIInfo(title: "Shop", version: "2.1.0", description: "Orders and more",
                                   servers: ["https://api.example.com"])

    private func app() -> Application {
        let app = Application()
        app.openAPI(info)
        app.swaggerUI(path: "/docs")
        app.get("/orders") { (filter: Query<Filter>) in JSON([Order]()) }
            .summary("Orders, newest first")
            .tags("orders")
            .operationID("listOrders")
        app.post("/orders") { (token: BearerToken, order: Body<NewOrder>) async throws in JSON(Line(sku: "", quantity: 0)) }
            .response(.created, "The order", json: Order.self)
            .tags("orders")
        app.group("/shops/:shop") {
            app.get("/orders/:id") { (shop: Path<String>, id: Path<Int>) -> JSON<Order>? in nil }
                .response(.notFound, "No such order")
                .deprecated()
        }
        app.get("/files/*path") { request, response in response.send("file") }
            .description("A file, by its path")
        app.get("/secret") { "hidden" }.hidden()
        app.post("/login") { (form: Form<NewOrder>) in HTTPStatus.noContent }
            .security(.apiKey(name: "X-Key", in: .header))
        app.get("/plain") { "text" }
        let router = Router()
        router.get("/status") { JSON(["ok": true]) }.summary("Health")
        app.nest("/v2", router)
        return app
    }

    @Test func routesBecomeOperations() throws {
        let document = app().openAPIDocument(info)
        #expect(document["openapi"] == "3.1.0")
        #expect(document["info"] == ["title": "Shop", "description": "Orders and more", "version": "2.1.0"])
        #expect(document["servers"] == [["url": "https://api.example.com"]])
        #expect(keys(document["paths"]) == ["/orders", "/shops/{shop}/orders/{id}", "/files/{path}", "/login",
                                            "/plain", "/v2/status"])
        #expect(keys(at(document, "paths", "/orders")) == ["get", "post"])

        let list = at(document, "paths", "/orders", "get")
        #expect(list?["summary"] == "Orders, newest first")
        #expect(list?["tags"] == ["orders"])
        #expect(list?["operationId"] == "listOrders")
        #expect(list?["parameters"] == [
            ["name": "status", "in": "query", "required": false,
             "schema": ["type": "string", "enum": ["open", "shipped", "cancelled"]]],
            ["name": "limit", "in": "query", "required": true, "schema": ["type": "integer", "format": "int64"]],
        ])
        #expect(at(list, "responses", "200") == [
            "description": "OK",
            "content": ["application/json": ["schema": ["type": "array", "items": ["$ref": "#/components/schemas/Order"]]]],
        ])

        let create = at(document, "paths", "/orders", "post")
        #expect(create?["requestBody"] == [
            "required": true,
            "content": ["application/json": ["schema": ["$ref": "#/components/schemas/NewOrder"]]],
        ])
        #expect(keys(create?["responses"]) == ["200", "401", "400", "201"])
        #expect(at(create, "responses", "201", "content", "application/json", "schema")
            == ["$ref": "#/components/schemas/Order"])
        #expect(create?["security"] == [["bearerAuth": []]])

        let one = at(document, "paths", "/shops/{shop}/orders/{id}", "get")
        #expect(one?["parameters"] == [
            ["name": "shop", "in": "path", "required": true, "schema": ["type": "string"]],
            ["name": "id", "in": "path", "required": true, "schema": ["type": "integer", "format": "int64"]],
        ])
        #expect(keys(one?["responses"]) == ["200", "404"])
        #expect(at(one, "responses", "404") == ["description": "No such order"])
        #expect(one?["deprecated"] == true)

        let file = at(document, "paths", "/files/{path}", "get")
        #expect(file?["description"] == "A file, by its path")
        #expect(file?["responses"] == ["default": ["description": "The route's answer"]])
        #expect(at(file, "parameters", 0, "name") == "path")

        let login = at(document, "paths", "/login", "post")
        #expect(at(login, "requestBody", "content", "application/x-www-form-urlencoded", "schema")
            == ["$ref": "#/components/schemas/NewOrder"])
        #expect(login?["security"] == [["apiKey_header_X-Key": []]])
        #expect(at(document, "paths", "/plain", "get", "responses", "200", "content", "text/plain")
            == ["schema": ["type": "string"]])
        #expect(at(document, "paths", "/v2/status", "get", "summary") == "Health")

        #expect(keys(at(document, "components", "schemas")) == ["Filter", "Line", "Order", "NewOrder"])
        #expect(at(document, "components", "securitySchemes") == [
            "bearerAuth": ["type": "http", "scheme": "bearer"],
            "apiKey_header_X-Key": ["type": "apiKey", "name": "X-Key", "in": "header"],
        ])
    }

    @Test func theDocumentAndSwaggerUIAreServed() throws {
        let app = app()
        let client = app.test
        let served = try client.get("/openapi.json")
        #expect(served.status == 200)
        #expect(served.header("content-type") == "application/json")
        #expect(served.text == app.openAPIJSON(info))
        // GARUDA_OPENAPI_OUT=path writes the document out, for a validator.
        if let out = av_getenv("GARUDA_OPENAPI_OUT"), let file = fopen(out, "w") {
            _ = served.body.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, file) }
            fclose(file)
        }
        #expect(served.text.hasPrefix("{\n  \"openapi\": \"3.1.0\",\n"))

        let page = try client.get("/docs")
        #expect(page.header("content-type")?.hasPrefix("text/html") == true)
        #expect(page.text.contains("swagger-ui-dist@5/swagger-ui-bundle.js"))
        #expect(page.text.contains(#"new URL("./openapi.json", window.location.href)"#))
        #expect(relativeURL(from: "/api/v1/docs", to: "/openapi.json") == "../../openapi.json")
        #expect(relativeURL(from: "/docs", to: "/specs/api.json") == "./specs/api.json")
    }

    @Test func patternsBecomePaths() {
        #expect(openAPIPath("/") == ("/", []))
        #expect(openAPIPath("/a/:b/c/*d") == ("/a/{b}/c/{d}", ["b", "d"]))
    }
}
