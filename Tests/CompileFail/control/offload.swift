// Offloaded routes that must compile: values in, a value out. State is
// shared by every thread of its shard, so a pool thread may take it too.
import Garuda

struct Order: Decodable, Sendable { var item: String }

final class Counter: Sendable { let start = 0 }

func routes(_ app: Application) {
    app.offload.get("/sum/:n") { (n: Path<Int>) -> String in "\((1...n.value).reduce(0, +))" }
    app.offload.post("/order") { (order: Body<Order>) -> Text in Text(order.value.item) }
    app.offload.get("/hits") { (counter: State<Counter>) -> String in "\(counter.value.start)" }
}
