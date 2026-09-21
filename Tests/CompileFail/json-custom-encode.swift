// `@JSON` takes precedence over Codable, so an `encode(to:)` written by hand
// would never be called again.
// expect-error: would stop being called
import Garuda
import GarudaJSON

@JSON struct Reading: Codable {
    var celsius: Double

    func encode(to encoder: Encoder) throws {
        var out = encoder.singleValueContainer()
        try out.encode(celsius * 9 / 5 + 32)
    }
}
