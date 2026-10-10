// Offloaded routes that must compile: values in, a value out.
import Garuda

struct Order: Decodable, Sendable { var item: String }

func routes(_ app: Application) {
    app.offload.get("/sum/:n") { (n: Path<Int>) -> String in "\((1...n.value).reduce(0, +))" }
    app.offload.post("/order") { (order: Body<Order>) -> Text in Text(order.value.item) }
}
