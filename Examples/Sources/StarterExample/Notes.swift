//===----------------------------------------------------------------------===//
// Notes: what an account owns.
//
//   GET    /notes?limit=20&before=41   200 a page, newest first
//   POST   /notes   {"title","body"?}  201 the note, or 422
//   GET    /notes/:id                  200, or 404
//   PATCH  /notes/:id  {"title"?,"body"?}  200, or 404
//   DELETE /notes/:id                  204, or 404
//
// Every route here needs an access token, and every statement is bound to the
// account the token names -- `where id = $1 and user_id = $2`. A note that
// belongs to somebody else answers 404, not 403: whether an id exists is not
// something a stranger needs to learn.
//
// Paging is by cursor (`before=<id>`), not by offset. An offset re-reads and
// skips rows that were already sent, and a note inserted meanwhile shifts
// every later page. `id desc` with `before` reads one index range.
//===----------------------------------------------------------------------===//

import Garuda

public struct Note: Codable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let body: String
    public let createdAt: Int64
    public let updatedAt: Int64
}

struct NewNote: Decodable, Validated {
    let title: String
    let body: String?

    func validate(_ check: inout Validation) {
        check.notEmpty("title", title)
        check.length("title", title, atMost: 200)
        check.require((body?.utf8.count ?? 0) <= 64 * 1024, "body", "is at most 64 KiB")
    }
}

struct NoteChanges: Decodable, Validated {
    let title: String?
    let body: String?

    func validate(_ check: inout Validation) {
        // A field that is absent is not being changed; one that is there is
        // held to the same rule as a new note's.
        check.notEmpty("title", title)
        check.length("title", title, atMost: 200)
        check.require((body?.utf8.count ?? 0) <= 64 * 1024, "body", "is at most 64 KiB")
        // A rule about the value and not about any one field, which is what
        // the empty name is for.
        check.require(title != nil || body != nil, "", "send a title, a body, or both")
    }
}

public struct NotePage: Codable, Sendable {
    public let notes: [Note]
    /// What to pass as `before` for the next page, or nil at the end.
    public let nextBefore: Int64?
}

struct PageQuery: Decodable {
    let limit: Int?
    let before: Int64?
}

/// Every column a `Note` needs, named as its properties are.
private let noteColumns = #"id, title, body, created_at as "createdAt", updated_at as "updatedAt""#


func addNoteRoutes(_ app: Application) {
    app.group("/notes") {
        app.get("") { (query: Query<PageQuery>, jwt: JWT<AccessClaims>, services: State<Services>)
            async throws -> JSON<NotePage> in
            let owner = try owner(jwt)
            let limit = min(max(query.value.limit ?? 20, 1), 100)
            let before = query.value.before ?? Int64.max
            let notes = try await services.value.pool.query(
                Note.self,
                "select \(noteColumns) from notes where user_id = $1 and id < $2 order by id desc limit $3",
                owner, before, limit)
            // A full page means there may be another; a short one is the end.
            return JSON(NotePage(notes: notes, nextBefore: notes.count == limit ? notes.last?.id : nil))
        }
            .summary("A page of your notes, newest first")
            .tags("notes")

        app.post("") { (body: Body<NewNote>, jwt: JWT<AccessClaims>, services: State<Services>)
            async throws -> JSON<Note> in
            let owner = try owner(jwt)
            // Checked before this ran, so what is left is what to store.
            let title = body.value.title.trimmingWhitespace()
            let text = body.value.body ?? ""
            let now = Timestamp.now.secondsSinceEpoch
            guard let note = try await services.value.pool.first(
                Note.self,
                "insert into notes (user_id, title, body, created_at, updated_at) "
                    + "values ($1, $2, $3, $4, $4) returning \(noteColumns)",
                owner, title, text, now) else {
                throw HTTPError(.internalServerError)
            }
            return JSON(note, status: .created)
        }
            .summary("Write a note")
            .tags("notes")

        app.get("/:id") { (id: Path<Int64>, jwt: JWT<AccessClaims>, services: State<Services>)
            async throws -> JSON<Note>? in
            try await services.value.pool.first(
                Note.self, "select \(noteColumns) from notes where id = $1 and user_id = $2",
                id.value, try owner(jwt)).map { JSON($0) }
        }
            .summary("One note")
            .tags("notes")
            .response(.notFound, "No note of yours has that id")

        app.patch("/:id") { (id: Path<Int64>, body: Body<NoteChanges>, jwt: JWT<AccessClaims>,
                             services: State<Services>) async throws -> JSON<Note>? in
            let owner = try owner(jwt)
            let title = body.value.title?.trimmingWhitespace()
            let text = body.value.body
            // coalesce keeps what the request left out.
            return try await services.value.pool.first(
                Note.self,
                "update notes set title = coalesce($1, title), body = coalesce($2, body), updated_at = $3 "
                    + "where id = $4 and user_id = $5 returning \(noteColumns)",
                title, text, Timestamp.now.secondsSinceEpoch, id.value, owner).map { JSON($0) }
        }
            .summary("Change a note")
            .tags("notes")
            .response(.notFound, "No note of yours has that id")

        app.delete("/:id") { (id: Path<Int64>, jwt: JWT<AccessClaims>, services: State<Services>)
            async throws -> HTTPStatus in
            let deleted = try await services.value.pool.execute(
                "delete from notes where id = $1 and user_id = $2", id.value, try owner(jwt))
            return deleted == 1 ? .noContent : .notFound
        }
            .summary("Delete a note")
            .tags("notes")
    }
}

/// The account an access token names. A token this server signed always has a
/// number here, so anything else is a token that should not have verified.
private func owner(_ jwt: JWT<AccessClaims>) throws -> Int64 {
    guard let id = jwt.claims.userID else { throw HTTPError(.unauthorized, "that token names no account") }
    return id
}
