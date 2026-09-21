// GarudaSQL — `@PostgresRow`.
//
// The same bargain `@JSON` makes for a request body, for a database row:
//
//     import Garuda
//     import GarudaSQL
//
//     @PostgresRow struct User: Codable {
//         let id: Int
//         let name: String
//     }
//
// Nothing else changes: the same `first(User.self, "select id, name ...")`.
// The pool asks once per result whether the type reads itself, and a type
// without the attribute is decoded exactly as before.

@_exported import Garuda

/// Writes the conformance that lets this type read itself out of a result row
/// instead of going through `Codable`.
///
/// A property is read from the column of its own name. What that column
/// decodes to is what `Codable` decoded it to: the same binary and text
/// paths, the same errors, and a NULL into a non-optional property refused
/// rather than read as zero. An optional property keeps meaning what
/// `decodeIfPresent` meant -- no such column, or a NULL, is nil -- so a
/// result that leaves a column out still reads.
///
/// A `let` that already holds a value is not read, exactly as `Codable` does
/// not read one. `static`, computed and `lazy` properties are not columns.
///
/// A `CodingKeys` in the body, including one inside a `#if`, is an error rather
/// than something ignored:
/// `Codable` would read a property from the column it names, this reads it
/// from the column of the property's own name, and which one applied would
/// depend on which path ran. Rename in the query instead -- `select
/// display_name as name` -- or leave the attribute off.
@attached(extension, conformances: PostgresReadable, names: named(init(row:)))
public macro PostgresRow() = #externalMacro(module: "GarudaMacros", type: "PostgresRowMacro")
