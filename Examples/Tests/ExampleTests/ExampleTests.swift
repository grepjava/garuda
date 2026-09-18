#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
import Garuda
@testable import TodoExample
@testable import AuthExample
@testable import StreamingExample
@testable import ChatExample

// Each example driven through `app.test`: the real engine, routes and
// handlers, with no network.


@Suite("Todo example")
struct TodoExampleTests {
    @Test func createReadUpdateDelete() throws {
        let client = todoApp(databasePath: ":memory:").test

        let created = try client.post("/todos", body: #"{"title":"  write the docs "}"#)
        #expect(created.status == .created)
        let todo = try created.json(Todo.self)
        #expect(todo.id == 1 && todo.title == "write the docs" && !todo.done)

        #expect(try client.get("/todos/1").json(Todo.self) == todo)
        #expect(try client.get("/todos/2").status == .notFound)

        let patched = try client.request("PATCH", "/todos/1", body: Array(#"{"done":true}"#.utf8))
        #expect(patched.status == .ok)
        #expect(try patched.json(Todo.self).done)
        #expect(try patched.json(Todo.self).title == "write the docs")

        #expect(try client.delete("/todos/1").status == .noContent)
        #expect(try client.delete("/todos/1").status == .notFound)
        #expect(try client.get("/todos/1").status == .notFound)
    }

    @Test func listsFilterAndPage() throws {
        let client = todoApp(databasePath: ":memory:").test
        for title in ["one", "two", "three", "four"] {
            #expect(try client.post("/todos", body: "{\"title\":\"\(title)\"}").status == .created)
        }
        _ = try client.request("PATCH", "/todos/2", body: Array(#"{"done":true}"#.utf8))

        #expect(try client.get("/todos").json([Todo].self).map(\.title) == ["four", "three", "two", "one"])
        #expect(try client.get("/todos?done=true").json([Todo].self).map(\.title) == ["two"])
        #expect(try client.get("/todos?done=false&limit=2").json([Todo].self).map(\.title) == ["four", "three"])
        #expect(try client.get("/todos?limit=2&offset=2").json([Todo].self).map(\.title) == ["two", "one"])
        #expect(try client.get("/todos?limit=many").status == .badRequest)
    }

    @Test func badInputIsRefusedWithAReason() throws {
        let client = todoApp(databasePath: ":memory:").test
        let blank = try client.post("/todos", body: #"{"title":"   "}"#)
        #expect(blank.status == .unprocessableContent)
        // The field is named, so a form knows where to put the message.
        #expect(blank.text == #"{"error":"title must not be empty","#
                    + #""fields":[{"field":"title","message":"must not be empty"}]}"#, "\(blank.text)")
        #expect(try client.post("/todos", body: #"{"name":"x"}"#).status == .badRequest)

        #expect(try client.post("/todos", body: #"{"title":"same"}"#).status == .created)
        let duplicate = try client.post("/todos", body: #"{"title":"same"}"#)
        #expect(duplicate.status == .conflict)
        #expect(duplicate.text.contains("exists"))

        #expect(try client.post("/todos", body: #"{"title":"other"}"#).status == .created)
        let renamed = try client.request("PATCH", "/todos/2", body: Array(#"{"title":"same"}"#.utf8))
        #expect(renamed.status == .conflict)
    }
}

@Suite("Auth example")
struct AuthExampleTests {
    /// Few iterations: the tests check the flow, not the cost.
    private func client() -> TestClient {
        authApp(databasePath: ":memory:", iterations: 1_000).test
    }

    private func login(_ client: TestClient, _ username: String, _ password: String) throws -> TestResponse {
        try client.post("/login", body: "{\"username\":\"\(username)\",\"password\":\"\(password)\"}")
    }

    @Test func signUpLogInUseAndLogOut() throws {
        let client = client()
        let signup = try client.post("/signup", body: #"{"username":"Ada","password":"correct horse"}"#)
        #expect(signup.status == .created)
        #expect(try signup.json(User.self) == User(id: 1, username: "ada"))

        let session = try login(client, "ada", "correct horse")
        #expect(session.status == .ok)
        struct Session: Decodable { let token: String; let expiresAt: Timestamp }
        let token = try session.json(Session.self).token
        #expect(token.utf8.count == 43)

        let bearer = [("authorization", "Bearer \(token)")]
        #expect(try client.get("/me", headers: bearer).json(User.self) == User(id: 1, username: "ada"))
        #expect(try client.get("/whoami", headers: bearer).text == "signed in as ada")
        #expect(try client.get("/whoami").text == "not signed in")
        #expect(try client.post("/logout", headers: bearer).status == .noContent)
        #expect(try client.get("/me", headers: bearer).status == .unauthorized)
        #expect(try client.get("/whoami", headers: bearer).text == "not signed in")
    }

    @Test func wrongCredentialsLookTheSame() throws {
        let client = client()
        _ = try client.post("/signup", body: #"{"username":"ada","password":"correct horse"}"#)
        let wrongPassword = try login(client, "ada", "battery staple")
        let noSuchUser = try login(client, "grace", "battery staple")
        #expect(wrongPassword.status == .unauthorized)
        #expect(noSuchUser.status == .unauthorized)
        #expect(wrongPassword.text == noSuchUser.text)
    }

    @Test func protectedRoutesNeedAValidSession() throws {
        let client = client()
        let missing = try client.get("/me")
        #expect(missing.status == .unauthorized)
        #expect(missing.header("www-authenticate") == "Bearer")
        #expect(try client.get("/me", headers: [("authorization", "Bearer \(Tokens.random())")]).status == .unauthorized)
        // Sign-up and login are outside the group, and need none.
        #expect(try client.post("/signup", body: #"{"username":"ada","password":"correct horse"}"#).status == .created)
    }

    @Test func signUpIsValidated() throws {
        let client = client()
        #expect(try client.post("/signup", body: #"{"username":"a","password":"correct horse"}"#).status
                == .unprocessableContent)
        #expect(try client.post("/signup", body: #"{"username":"ada!","password":"correct horse"}"#).status
                == .unprocessableContent)
        #expect(try client.post("/signup", body: #"{"username":"ada","password":"short"}"#).status
                == .unprocessableContent)
        #expect(try client.post("/signup", body: #"{"username":"ada","password":"correct horse"}"#).status == .created)
        #expect(try client.post("/signup", body: #"{"username":"ADA","password":"another one"}"#).status == .conflict)
    }

    @Test func aWeakerHashIsUpgradedAtLogin() throws {
        // Signed up when the iteration count was lower; logging in under a
        // higher one stores a new hash.
        let path = "/tmp/garuda-auth-example-\(getpid()).db"
        defer { for suffix in ["", "-wal", "-shm"] { unlink(path + suffix) } }
        do {
            let before = authApp(databasePath: path, iterations: 1_000).test
            #expect(try before.post("/signup", body: #"{"username":"ada","password":"correct horse"}"#).status
                    == .created)
        }
        let after = authApp(databasePath: path, iterations: 2_000).test
        #expect(try login(after, "ada", "correct horse").status == .ok)
        #expect(try login(after, "ada", "correct horse").status == .ok)
        let hash = try hashOf("ada", path)
        #expect(hash.hasPrefix("$pbkdf2-sha256$i=2000$"))
    }

    private func hashOf(_ username: String, _ path: String) throws -> String {
        let app = Application()
        app.state { _ in try SQLiteDatabase(SQLiteConfiguration(path: path)) }
        app.get("/hash") { (db: State<SQLiteDatabase>) async throws -> String in
            try await db.value.first(String.self, "select password_hash from users where username = ?", username) ?? ""
        }
        return try app.test.get("/hash").text
    }
}

@Suite("Streaming example")
struct StreamingExampleTests {
    private func directory() -> String {
        var template = Array("/tmp/garuda-streaming-XXXXXX".utf8CString)
        return template.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)!) }
    }

    @Test func aCountdownIsEventsAndThenTheEnd() throws {
        let client = streamingApp(uploadDirectory: "/tmp", tickMilliseconds: 1).test
        let response = try client.get("/countdown?from=3")
        #expect(response.status == .ok)
        #expect(response.header("content-type")?.hasPrefix("text/event-stream") == true)
        #expect(response.text == """
            event: tick
            id: 3
            data: 3

            event: tick
            id: 2
            data: 2

            event: tick
            id: 1
            data: 1

            event: done
            data: liftoff


            """)
    }

    @Test func anExportIsEveryRow() throws {
        let client = streamingApp(uploadDirectory: "/tmp").test
        #expect(try client.get("/export.csv?rows=3").text == "id,square,label\n0,0,row 0\n1,1,row 1\n2,4,row 2\n")
        // Past one batch: every row, in order, none repeated.
        let lines = try client.get("/export.csv?rows=20000").text.split(separator: "\n")
        #expect(lines.count == 20_001)
        #expect(lines.last == "19999,399960001,row 19999")
    }

    @Test func anUploadIsWrittenAndRenamed() throws {
        let dir = directory()
        defer { rmdir(dir) }
        let client = streamingApp(uploadDirectory: dir, maxUploadBytes: 1 << 20).test
        let bytes = (0..<300_000).map { UInt8($0 % 251) }
        let put = try client.put("/uploads/data.bin", body: bytes)
        #expect(put.status == .created)
        struct Info: Decodable { let name: String; let bytes: Int }
        #expect(try put.json(Info.self).bytes == 300_000)
        #expect(try client.get("/uploads/data.bin").json(Info.self).bytes == 300_000)

        // Read back from disk: the same bytes.
        let fd = open(dir + "/data.bin", O_RDONLY)
        #expect(fd >= 0)
        var back = [UInt8](repeating: 0, count: 400_000)
        var total = 0
        while true {
            let n = back.withUnsafeMutableBytes { read(fd, $0.baseAddress! + total, $0.count - total) }
            if n <= 0 { break }
            total += n
        }
        close(fd)
        #expect(total == 300_000 && Array(back[0..<total]) == bytes)
        unlink(dir + "/data.bin")

        let hidden = Result { try client.put("/uploads/..hidden", body: [1]) }
        #expect((try? hidden.get())?.status == .badRequest, "\(hidden)")
        let missing = Result { try client.get("/uploads/missing") }
        #expect((try? missing.get())?.status == .notFound, "\(missing)")
        // Over the limit: refused, and nothing left behind under either name.
        let big = Result { try client.put("/uploads/big", body: [UInt8](repeating: 0, count: 2 << 20)) }
        #expect((try? big.get())?.status == .contentTooLarge, "\(big)")
        #expect(access(dir + "/big", F_OK) != 0)
        #expect(access(dir + "/big.partial", F_OK) != 0)
    }
}

@Suite("Chat example")
struct ChatExampleTests {
    private func next(_ socket: TestWebSocket) throws -> ChatMessage? {
        guard case .text(let text)? = try socket.receive() else { return nil }
        return try JSONCoder.decode(ChatMessage.self, from: Array(text.utf8))
    }

    @Test func whatIsSaidIsHeardByEveryoneInTheRoom() throws {
        let client = chatApp().test
        let ada = try client.webSocket("/rooms/everyone/ws?name=ada")
        #expect(try next(ada).map { "\($0.kind) \($0.name)" } == "joined ada")
        let grace = try client.webSocket("/rooms/everyone/ws?name=grace")
        #expect(try next(grace).map { "\($0.kind) \($0.name)" } == "joined grace")
        #expect(try next(ada).map { "\($0.kind) \($0.name)" } == "joined grace")

        try ada.send("hello")
        #expect(try next(ada).map { "\($0.name): \($0.text)" } == "ada: hello")
        #expect(try next(grace).map { "\($0.name): \($0.text)" } == "ada: hello")

        // Said over HTTP, heard over the WebSocket.
        #expect(try client.post("/rooms/everyone/messages", body: #"{"name":"curl","text":"hi all"}"#).status == .accepted)
        #expect(try next(grace).map { "\($0.name): \($0.text)" } == "curl: hi all")
        #expect(try next(ada).map { "\($0.name): \($0.text)" } == "curl: hi all")

        try grace.close()
        #expect(try next(ada).map { "\($0.kind) \($0.name)" } == "left grace")
    }

    @Test func roomsAreSeparate() throws {
        let client = chatApp().test
        let lobby = try client.webSocket("/rooms/separate/ws?name=ada")
        _ = try next(lobby)
        #expect(try client.post("/rooms/elsewhere/messages", body: #"{"name":"x","text":"not here"}"#).status
                == .accepted)
        #expect(try client.post("/rooms/separate/messages", body: #"{"name":"x","text":"here"}"#).status == .accepted)
        #expect(try next(lobby)?.text == "here")
    }

    @Test func badInputIsRefused() throws {
        let client = chatApp().test
        #expect(try client.post("/rooms/Not_A_Room/messages", body: #"{"name":"x","text":"y"}"#).status == .notFound)
        #expect(try client.post("/rooms/lobby/messages", body: #"{"name":"","text":"y"}"#).status
                == .unprocessableContent)
        #expect(try client.post("/rooms/lobby/messages", body: #"{"name":"x","text":""}"#).status
                == .unprocessableContent)
        #expect(try client.get("/").text.contains("<title>Garuda chat</title>"))
    }
}
