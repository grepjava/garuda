// The same for an `encode(to:)`: inside a `#if` it is still an encoder the
// generated writer would replace.
// expect-error: would stop being called
import Garuda
import GarudaJSON

@JSON struct Reading: Codable {
    var celsius: Double

#if DEBUG
    func encode(to encoder: Encoder) throws {
        var out = encoder.singleValueContainer()
        try out.encode(celsius * 9 / 5 + 32)
    }
#endif
}
