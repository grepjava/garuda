//===----------------------------------------------------------------------===//
// Chat rooms, heard on every worker.
//
//   GET  /                                   a page to chat from
//   GET  /rooms/:room/ws?name=ada            a WebSocket: text sent is said in
//                                            the room, and everything said
//                                            there comes back as JSON
//   GET  /rooms/:room/events                 the same as server-sent events,
//                                            resumed with Last-Event-ID
//   POST /rooms/:room/messages {"name", "text"}   says something, 202
//
// What it shows: `Topic` carries what is said to subscribers on every worker
// process, so two people connected to different workers are in the same
// room. A WebSocket handler reads what its client sends while forwarding what
// the room says, in a task group. An event stream replays what a reconnecting
// client missed, from the id it last saw.
//===----------------------------------------------------------------------===//

import Garuda

public struct ChatMessage: Codable, Equatable, Sendable {
    /// "message", "joined" or "left": the event it was published as.
    public let kind: String
    public let name: String
    public let text: String
    public let at: Timestamp
}

struct Join: Decodable {
    let name: String?
}

struct Say: Decodable {
    let name: String
    let text: String
}

/// Room names are 1 to 32 lowercase letters, digits and dashes.
private func validRoom(_ room: String) -> Bool {
    (1...32).contains(room.utf8.count) && room.utf8.allSatisfy {
        ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
    }
}

private func topic(_ room: String) throws -> Topic {
    guard validRoom(room) else { throw HTTPError(.notFound, "no such room") }
    return Topic("room:" + room)
}

/// A name is 1 to 32 characters.
private func checkName(_ name: String) throws {
    guard (1...32).contains(name.count) else {
        throw HTTPError(.unprocessableContent, "a name is 1 to 32 characters")
    }
}

/// A message is 1 to 2000 bytes.
private func validText(_ text: String) -> Bool {
    (1...2000).contains(text.utf8.count)
}

/// Says `text` in `room`, to every subscriber on every worker.
@discardableResult
private func say(_ room: Topic, name: String, text: String, event: String = "message") throws -> BroadcastID {
    let message = ChatMessage(kind: event, name: name, text: text, at: .now)
    return try room.publish(JSONCoder.encode(message), event: event)
}

public func chatApp() -> Application {
    let app = Application()

    app.get("/") { () in HTML(chatPage) }

    app.webSocket("/rooms/:room/ws") { (ws: WebSocket, room: Path<String>, join: Query<Join>) async throws in
        let room = try topic(room.value)
        let name = join.value.name ?? "anonymous"
        try checkName(name)
        // Subscribed before announcing, so the client hears its own arrival.
        let heard = try ws.subscribe(room)
        try say(room, name: name, text: "", event: "joined")

        // Two tasks: the room out to this client, and this client into the
        // room. When either ends -- the client closed, went away, or fell
        // silent past the keepalive -- the other is stopped. A wait for the
        // room is not a Swift cancellation point: cancelling the subscription
        // is what ends it.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while true {
                        switch try await heard.next() {
                        case .message(let message):
                            try await ws.send(message.text)
                        case .missed:
                            // This client fell so far behind that messages were
                            // dropped for it; it is told rather than left to guess.
                            try await ws.send(#"{"missed":true}"#)
                        }
                    }
                }
                group.addTask {
                    while let incoming = try await ws.receive() {
                        guard case .text(let text) = incoming, validText(text) else { continue }
                        try say(room, name: name, text: text)
                    }
                }
                defer { heard.cancel() }
                try await group.next()
            }
        } catch {
            // However the connection ended, this person has left.
        }
        try? say(room, name: name, text: "", event: "left")
    }

    app.get("/rooms/:room/events") { (room: Path<String>, last: LastEventID) async throws in
        let room = try topic(room.value)
        return EventStream(keepAlive: 15_000) { events in
            try await events.forward(room, after: last)
        }
    }

    app.post("/rooms/:room/messages") { (room: Path<String>, body: Body<Say>) async throws -> JSON<[String: String]> in
        let room = try topic(room.value)
        try checkName(body.value.name)
        guard validText(body.value.text) else {
            throw HTTPError(.unprocessableContent, "a message is 1 to 2000 bytes")
        }
        let id = try say(room, name: body.value.name, text: body.value.text)
        return JSON(["id": "\(id)"], status: .accepted)
    }

    return app
}
