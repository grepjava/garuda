// A macro is expanded before a `#if` branch is chosen, so a `CodingKeys` inside
// one cannot be honoured or reasoned about -- and under the branch that does
// compile, Codable would use it while the generated writer used the member
// names. Refused in every branch.
// expect-error: does not read 'CodingKeys'
import Garuda
import GarudaJSON

@JSON struct Person: Codable {
    var name: String
    var secret: String = "private"

#if DEBUG
    enum CodingKeys: String, CodingKey {
        case name = "display_name"
    }
#endif
}
