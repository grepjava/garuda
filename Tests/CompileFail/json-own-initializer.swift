// The generated reader delegates to the memberwise initializer, which an
// initializer written in the body replaces.
// expect-error: which this initializer replaces
import Garuda
import GarudaJSON

@JSON struct Order: Codable {
    var id: Int

    init(id: Int) { self.id = id }
}
