// A generic struct's conformance would need constraints on its parameters
// that the macro cannot work out.
// expect-error: cannot be attached to a generic struct
import Garuda
import GarudaJSON

@JSON struct Page<Row>: Codable where Row: Codable {
    var rows: [Row]
}
