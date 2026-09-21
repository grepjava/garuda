// GarudaJSON — `@JSON`.
//
// A separate module from `Garuda` because it is the only part of the framework
// that needs swift-syntax. An application that does not import it never builds
// the plugin.
//
//     import Garuda
//     import GarudaJSON
//
//     @JSON struct Order: Codable {
//         let id: Int
//         let name: String
//         let tags: [String]
//     }
//
// Nothing else changes: the same `Body<Order>` and the same `.json(receipt)`.
// The coder finds the conformances and uses them instead of Codable, which on
// the JSON workload is about a fifth off the time a request takes.

@_exported import Garuda

/// Writes the conformances that let this type read and write its own JSON.
///
/// The generated code sends exactly what `Codable` sent: members in the order
/// they are declared, under their own names, a missing key an error unless the
/// member is optional, and a nil optional written as null. A type may keep its
/// `Codable` conformance and will not notice the difference, beyond the time.
///
/// It is written for the shapes it can be sure of. A dictionary or a set
/// member, a generic struct, an initializer in the body -- each is an error
/// naming what to do instead, rather than a quiet fall back to `Codable` that
/// would leave you wondering why the type is slow.
///
/// For the same reason it refuses a `CodingKeys` that renames or omits a
/// member, and an `encode(to:)` written by hand: this conformance is used in
/// preference to `Codable`, so either one would go on describing what
/// `JSONDecoder` sends while a route sent something else. One inside a `#if`
/// is refused too, in every branch -- a macro is expanded before the branch is
/// chosen. Only the type's body is visible here, so a `CodingKeys` in an
/// extension cannot be caught, which is a reason to keep this attribute and a
/// hand-written `Codable` form apart.
@attached(extension, conformances: JSONReadable, JSONWritable,
          names: named(init(json:)), named(write(json:)))
public macro JSON() = #externalMacro(module: "GarudaMacros", type: "JSONMacro")
