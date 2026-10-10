// An offloaded handler handed a worker's state. A pool built by app.state
// belongs to its worker, and the handler runs on another thread, so State is
// not Sendable and an offloaded route cannot take it.
// expect-error: type 'State<Counter>' does not conform to the 'Sendable' protocol
import Garuda

// Sendable itself, as PostgresPool is: what is refused is State.
final class Counter: @unchecked Sendable { var hits = 0 }

func routes(_ app: Application) {
    app.offload.get("/hits") { (counter: State<Counter>) -> String in
        counter.value.hits += 1
        return "\(counter.value.hits)"
    }
}
