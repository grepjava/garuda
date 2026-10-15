import Testing
import Garuda
import GarudaTesting
@testable import ChatExample

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
