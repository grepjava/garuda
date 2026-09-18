import Testing
@testable import Garuda

// Validation: the rules themselves, what they answer with, and that a type
// with rules is checked wherever a request is decoded into it.

// MARK: - Types with rules

private struct RuleAddress: Codable, Validated, Sendable {
    var street: String
    var city: String
    var postcode: String?

    func validate(_ check: inout Validation) {
        check.notEmpty("street", street)
        check.notEmpty("city", city)
        check.length("postcode", postcode, atLeast: 2, atMost: 8)
    }
}

private struct RuleItem: Codable, Validated, Sendable {
    var sku: String
    var quantity: Int

    func validate(_ check: inout Validation) {
        check.length("sku", sku, atLeast: 3, atMost: 12)
        check.range("quantity", quantity, atLeast: 1, atMost: 100)
    }
}

private struct RuleOrder: Codable, Validated, Sendable {
    var email: String
    var items: [RuleItem]
    var home: RuleAddress
    var billing: RuleAddress?
    var note: String?
    var currency: String

    func validate(_ check: inout Validation) {
        check.email("email", email)
        check.count("items", items, atLeast: 1, atMost: 20)
        check.each("items", items)
        check.nested("home", home)
        check.nested("billing", billing)
        check.length("note", note, atMost: 8)
        check.oneOf("currency", currency, ["GBP", "EUR", "USD"])
    }
}

private func anOrder(email: String = "ada@example.com", items: [RuleItem] = [RuleItem(sku: "abc", quantity: 1)],
                   home: RuleAddress = RuleAddress(street: "12 Mill Lane", city: "Cambridge", postcode: nil),
                   billing: RuleAddress? = nil, note: String? = nil,
                   currency: String = "GBP") -> RuleOrder {
    RuleOrder(email: email, items: items, home: home, billing: billing, note: note, currency: currency)
}

@Suite("Validation rules")
struct ValidationRuleTests {
    @Test func aValueThatBreaksNothingHasNoProblems() throws {
        #expect(anOrder().validationProblems.isEmpty)
        #expect(try anOrder().validated().email == "ada@example.com")
    }

    @Test func everyBrokenRuleIsReportedAndNotJustTheFirst() throws {
        let problems = anOrder(email: "not-an-address", items: [], currency: "YEN").validationProblems
        #expect(problems.map(\.field) == ["email", "items", "currency"])
        #expect(problems[0].message == "must look like an email address")
        #expect(problems[1].message == "must not be empty")
        #expect(problems[2].message == "must be one of GBP, EUR, USD")
    }

    @Test func aFieldInsideOneIsNamedByThePathToIt() throws {
        let problems = anOrder(items: [RuleItem(sku: "ok-one", quantity: 1), RuleItem(sku: "x", quantity: 0)],
                             home: RuleAddress(street: "", city: "Cambridge", postcode: "C"),
                             billing: RuleAddress(street: "x", city: "", postcode: nil))
            .validationProblems
        // The same path JSON decoding reports for the same place, so a form
        // can put the message on the field it came from.
        #expect(problems.map(\.field) == ["items[1].sku", "items[1].quantity",
                                          "home.street", "home.postcode", "billing.city"])
        #expect(problems[0].message == "must be at least 3 characters")
        #expect(problems[1].message == "must be at least 1")
    }

    @Test func nilIsAbsentRatherThanWrong() throws {
        // An optional field that is not there breaks no rule; one that is
        // there is held to the same rule as any other.
        #expect(anOrder(note: nil).validationProblems.isEmpty)
        #expect(anOrder(billing: nil).validationProblems.isEmpty)
        let long = anOrder(note: "a note that is too long").validationProblems
        #expect(long.map(\.field) == ["note"])
        #expect(long[0].message == "must be at most 8 characters")
    }

    @Test func aStringOfWhitespaceIsNotAName() throws {
        var check = Validation()
        check.notEmpty("name", "  \u{00A0}\t ")
        #expect(check.problems.map(\.message) == ["must not be empty"])
        // Length counts what is there, so a rule that wants one character is
        // satisfied by a space -- which is why the two rules are separate.
        var counted = Validation()
        counted.length("name", " ", atLeast: 1)
        #expect(counted.isValid)
    }

    @Test func lengthCountsCharactersAsAPersonCountsThem() throws {
        var check = Validation()
        check.length("emoji", "🔒🔒", atMost: 2)
        check.length("accented", "é", atMost: 1)
        #expect(check.isValid, "\(check.problems)")
        check.length("emoji", "🔒🔒🔒", atMost: 2)
        #expect(check.problems.map(\.message) == ["must be at most 2 characters"])
    }

    @Test func rangeChecksTheBoundsItIsGivenAndNoOthers() throws {
        var check = Validation()
        check.range("low", 0, atLeast: 1)
        check.range("high", 101, atMost: 100)
        check.range("either", 50, atLeast: 1, atMost: 100)
        check.range("unbounded", -5)
        // Anything that compares, not only numbers.
        check.range("when", "2026-01-01", atLeast: "2026-06-01")
        #expect(check.problems.map(\.field) == ["low", "high", "when"])
        #expect(check.problems[0].message == "must be at least 1")
        #expect(check.problems[1].message == "must be at most 100")
    }

    @Test func whatAnEmailAddressLooksLike() throws {
        for good in ["ada@example.com", "a.b+tag@sub.example.co.uk", "x@y.zz"] {
            #expect(Validation.looksLikeEmail(good), "\(good)")
        }
        for bad in ["", "ada", "ada@", "@example.com", "ada@example", "ada@@example.com",
                    "ada@.example.com", "ada@example..com", "ada@example.com.",
                    "ada example@example.com", "ada@example.com\r\nbcc: x@y.zz",
                    "ada@example.com\u{7F}"] {
            #expect(!Validation.looksLikeEmail(bad), "\(bad)")
        }
        // As long as a mailbox may be, and one longer.
        let local = String(repeating: "a", count: 254 - "@example.com".utf8.count)
        #expect(Validation.looksLikeEmail(local + "@example.com"))
        #expect(!Validation.looksLikeEmail("a" + local + "@example.com"))
    }

    @Test func aRuleWithNoMethodOfItsOwnIsRequire() throws {
        var check = Validation()
        check.require(4 % 3 == 0, "quantity", "must be whole boxes")
        check.require(true, "quantity", "must be whole boxes")
        // The whole value, when no one field is at fault.
        check.require(false, "", "must name either a card or an account")
        #expect(check.problems.map(\.field) == ["quantity", ""])
        #expect(check.problems[1].sentence == "must name either a card or an account")
        #expect(check.problems[0].sentence == "quantity must be whole boxes")
    }

    @Test func countIsForLists() throws {
        var check = Validation()
        check.count("items", [Int](), atLeast: 1)
        check.count("tags", [1, 2, 3], atMost: 2)
        check.count("fine", [1], atLeast: 1, atMost: 2)
        #expect(check.problems.map(\.message) == ["must not be empty", "must have at most 2 items"])
        var many = Validation()
        many.count("items", [Int](), atLeast: 2)
        #expect(many.problems.map(\.message) == ["must have at least 2 items"])
    }
}

@Suite("What a refused value answers with")
struct ValidationErrorTests {
    @Test func theStatusIs422() throws {
        #expect(ValidationError(field: "email", message: "is wrong").status == .unprocessableContent)
        #expect(ValidationError(field: "email", message: "is wrong").status.code == 422)
    }

    @Test func theReasonIsEveryProblemUpToABound() throws {
        let error = ValidationError(field: "email", message: "must look like an email address")
        #expect(error.reason == "email must look like an email address")

        let two = ValidationError([ValidationProblem(field: "a", message: "is wrong"),
                                   ValidationProblem(field: "", message: "does not add up")])
        #expect(two.reason == "a is wrong; does not add up")

        // Bounded, because the number of fields in a type is not: `fields`
        // still has all of them.
        let many = ValidationError((1...9).map { ValidationProblem(field: "f\($0)", message: "is wrong") })
        #expect(many.reason == "f1 is wrong; f2 is wrong; f3 is wrong; f4 is wrong; f5 is wrong; and 4 more")
        #expect(many.fields.count == 9)

        #expect(ValidationError([]).reason == "the request is not valid")
    }

    @Test func aValidatedValueCanBeCheckedAwayFromARequest() throws {
        // What a service does with a value that came from a queue or a file.
        do {
            _ = try anOrder(email: "nope").validated()
            Issue.record("a broken rule should throw")
        } catch let error as ValidationError {
            #expect(error.fields.map(\.field) == ["email"])
        }
    }
}

// MARK: - Through a request

private struct RuleSignup: Codable, Validated, Sendable {
    var email: String
    var age: Int

    func validate(_ check: inout Validation) {
        check.email("email", email)
        check.range("age", age, atLeast: 18)
    }
}

private struct RuleSearch: Codable, Validated, Sendable {
    var q: String
    var page: Int

    func validate(_ check: inout Validation) {
        check.length("q", q, atLeast: 2, atMost: 40)
        check.range("page", page, atLeast: 1, atMost: 100)
    }
}

private struct RuleUnchecked: Codable, Sendable {
    var name: String
}

@Suite("Validation through a request")
struct ValidationRequestTests {
    @Test func aBodyWithRulesIsCheckedBeforeTheHandlerRuns() throws {
        let app = Application()
        app.post("/signup") { (body: Body<RuleSignup>) -> String in
            "reached \(body.value.email)"
        }
        let client = app.test

        let good = try client.post("/signup", body: #"{"email":"ada@example.com","age":36}"#)
        #expect(good.status == .ok)
        #expect(good.text == "reached ada@example.com")

        let bad = try client.post("/signup", body: #"{"email":"ada","age":12}"#)
        #expect(bad.status == .unprocessableContent, "the type is right and its rules are not")
        #expect(bad.text == #"{"error":"email must look like an email address; age must be at least 18","#
                    + #""fields":[{"field":"email","message":"must look like an email address"},"#
                    + #"{"field":"age","message":"must be at least 18"}]}"#, "\(bad.text)")
    }

    @Test func aBodyThatIsNotTheTypeIsStill400() throws {
        // The two failures are different failures, and the status says which.
        let app = Application()
        app.post("/signup") { (body: Body<RuleSignup>) -> String in "reached" }
        let client = app.test

        let wrongType = try client.post("/signup", body: #"{"email":"ada@example.com","age":"old"}"#)
        #expect(wrongType.status == .badRequest)
        // A decoding failure names the field as well now, from the path the
        // decoder already reports.
        #expect(try wrongType.json(ErrorBody.self).fields
                    == [ValidationProblem(field: "age", message: "is not Int")])

        let missing = try client.post("/signup", body: #"{"age":36}"#)
        #expect(missing.status == .badRequest)
        #expect(try missing.json(ErrorBody.self).fields
                    == [ValidationProblem(field: "email", message: "is missing")])

        // Not JSON at all is about the bytes, so there is no field to name and
        // the answer is the one key it always was.
        let nonsense = try client.post("/signup", body: "{")
        #expect(nonsense.status == .badRequest)
        #expect(try nonsense.json(ErrorBody.self).fields == nil)
        #expect(try nonsense.json(ErrorBody.self).error != "")
    }

    @Test func aQueryWithRulesIsCheckedTheSameWay() throws {
        let app = Application()
        app.get("/search") { (query: Query<RuleSearch>) -> String in "found \(query.value.q)" }
        let client = app.test

        #expect(try client.get("/search?q=swift&page=2").text == "found swift")
        let bad = try client.get("/search?q=s&page=0")
        #expect(bad.status == .unprocessableContent)
        #expect(try bad.json(ErrorBody.self).fields?.map(\.field) == ["q", "page"])
        // A query item that is missing is still a shape the client got wrong.
        #expect(try client.get("/search?q=swift").status == .badRequest)
    }

    @Test func aFormWithRulesIsCheckedTheSameWay() throws {
        let app = Application()
        app.post("/signup") { (form: Form<RuleSignup>) -> String in "reached" }
        let response = try app.test.post("/signup", body: "email=ada&age=12",
                                         headers: [("content-type", "application/x-www-form-urlencoded")])
        #expect(response.status == .unprocessableContent)
        #expect(try response.json(ErrorBody.self).fields?.map(\.field) == ["email", "age"])
    }

    @Test func aTypeWithNoRulesIsUntouched() throws {
        let app = Application()
        app.post("/echo") { (body: Body<RuleUnchecked>) -> String in body.value.name }
        #expect(try app.test.post("/echo", body: #"{"name":"ada"}"#).text == "ada")
    }

    @Test func aHandlerCanRefuseAFieldItself() throws {
        // What a rule on the type cannot know: whether the database already
        // has this address.
        let app = Application()
        app.post("/signup") { (body: Body<RuleSignup>) throws -> String in
            throw ValidationError(field: "email", message: "is already registered")
        }
        let response = try app.test.post("/signup", body: #"{"email":"ada@example.com","age":36}"#)
        #expect(response.status == .unprocessableContent)
        #expect(response.text == #"{"error":"email is already registered","#
                    + #""fields":[{"field":"email","message":"is already registered"}]}"#, "\(response.text)")
    }

    @Test func anErrorWithNothingToAddAnswersAsItAlwaysDid() throws {
        let app = Application()
        app.get("/gone") { () throws -> String in throw HTTPError.notFound("no such note") }
        let response = try app.test.get("/gone")
        #expect(response.status == .notFound)
        #expect(response.text == #"{"error":"no such note"}"#, "and no empty fields key")
    }
}

@Suite("Validation in the OpenAPI document")
struct ValidationOpenAPITests {
    @Test func aRouteWhoseInputHasRulesDocumentsIts422() throws {
        let app = Application()
        app.post("/signup") { (body: Body<RuleSignup>) -> String in "reached" }
        app.post("/echo") { (body: Body<RuleUnchecked>) -> String in "reached" }
        app.get("/search") { (query: Query<RuleSearch>) -> String in "reached" }
        let document = app.openAPIDocument(OpenAPIInfo(title: "Rules", version: "1"))

        let checked = document["paths"]?["/signup"]?["post"]?["responses"]
        #expect(checked?["422"]?["description"] == "A field breaks one of this route's rules")
        #expect(checked?["400"] != nil, "and the 400 for a body that is not the type")
        // The body it answers with, so a client knows to read `fields`.
        #expect(checked?["422"]?["content"]?["application/json"]?["schema"]
                    == ["$ref": "#/components/schemas/ErrorBody"])
        // Which says `error` is always there and `fields` is not.
        let shape = document["components"]?["schemas"]?["ErrorBody"]
        #expect(shape?["required"] == ["error"])

        // A route whose query has rules answers it too.
        #expect(document["paths"]?["/search"]?["get"]?["responses"]?["422"] != nil)
        // A route with no rules cannot answer 422, and does not claim to.
        #expect(document["paths"]?["/echo"]?["post"]?["responses"]?["422"] == nil)
    }
}
