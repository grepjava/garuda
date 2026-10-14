//===----------------------------------------------------------------------===//
// Deadlines: a bound on how long a route may wait.
//
//     app.deadline(.milliseconds(500)) {
//         app.get("/report") { (db: State<Database>) async throws in … }
//     }
//
// The routes registered inside run under Vega's I/O deadline: a socket, pipe
// or database wait still pending when the time is up gives up with
// IOError.timedOut, and so does any that would start after it. If that
// reaches the deadline unanswered, the request is answered 504.
//
// A deadline bounds waiting, not computing. A handler that loops without
// awaiting holds its thread until it returns, deadline or no; a
// `Runtime.sleep`, a channel or a child task's wait is not I/O and is not
// cut short either. What it covers is the common case: a backend that never
// answers.
//===----------------------------------------------------------------------===//

import Vega

extension RouteBuilder {
    /// Gives every route registered inside `register` a deadline of `limit`
    /// on its I/O waits, answering 504 when one runs out. Inside another
    /// `deadline`, this one is the one in force.
    public func deadline(_ limit: Duration, _ register: () -> Void) {
        group("/") {
            use(DeadlineMiddleware(limit: limit))
            register()
        }
    }
}

/// Runs the layers inside under an I/O deadline.
struct DeadlineMiddleware: Middleware {
    let limit: Duration

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        do {
            try await Runtime.withIODeadline(limit) { () async throws -> Void in try await next() }
        } catch let error as IOError where error == .timedOut {
            // A layer inside may have answered already, and caught nothing.
            if !response.isFinished { response.send(status: .gatewayTimeout) }
        }
    }
}
