// `@JSON` writes members under their own names, so a `CodingKeys` that renames
// or omits one would be honoured by Codable and ignored by the fast path: the
// same type would send two different shapes depending on which ran.
// expect-error: does not read 'CodingKeys'
import Garuda
import GarudaJSON

@JSON struct Person: Codable {
    var name: String
    var secret: String = "private"

    enum CodingKeys: String, CodingKey {
        case name = "display_name"
    }
}
