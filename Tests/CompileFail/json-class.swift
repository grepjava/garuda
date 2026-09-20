// `@JSON` reads a value in an extension's initializer, which a class cannot
// have: a designated initializer must be in the body.
// expect-error: can be attached to a struct
import Garuda
import GarudaJSON

@JSON final class Order: Codable {
    var id: Int = 0
}
