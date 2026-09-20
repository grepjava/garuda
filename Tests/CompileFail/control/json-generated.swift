// `@JSON` on the shapes it does handle, so that a harness which cannot load
// the plugin fails here rather than passing every refusal above.
import Garuda
import GarudaJSON

@JSON public struct Line: Codable {
    public var sku: String
    public var quantity: Int
}

@JSON public struct Order: Codable {
    public let id: Int
    public let lines: [Line]
    public let tags: [String]
    public let note: String?
    public let `default`: Bool
}
