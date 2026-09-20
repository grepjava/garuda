// `@JSON` cannot write a dictionary, because nothing fixes the order of its
// keys, and the generated code must send what Codable sent byte for byte.
// expect-error: cannot write a dictionary member
import Garuda
import GarudaJSON

@JSON struct Settings: Codable {
    var name: String
    var flags: [String: Bool]
}
