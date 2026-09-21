// `@PostgresRow` reads a property from the column of its own name, where
// Codable would have used the name in `CodingKeys`: adding the attribute must
// not quietly change which column a property is read from.
// expect-error: does not read 'CodingKeys'
import Garuda
import GarudaSQL

@PostgresRow struct Account: Codable {
    var name: String

    enum CodingKeys: String, CodingKey {
        case name = "display_name"
    }
}
