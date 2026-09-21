// `@PostgresRow` shares the check, so a conditional `CodingKeys` is refused
// there too: which column a property came from would otherwise depend on the
// branch and on which decoding path ran.
// expect-error: does not read 'CodingKeys'
import Garuda
import GarudaSQL

@PostgresRow struct Account: Codable {
    var name: String

#if DEBUG
    enum CodingKeys: String, CodingKey {
        case name = "display_name"
    }
#endif
}
