import Testing
@testable import Garuda

// The connection table readies a slot only when one is first wanted, so a
// worker sized for thousands of connections holds memory for the ones it has
// had, not for all it could have.

@Suite("Connection table")
struct ConnectionTableTests {
    @Test func slotsAreReadiedAsTheyAreFirstWanted() {
        var table = ConnectionTable(capacity: 1000)
        defer { table.destroy() }
        #expect(table.initialized == 0)
        #expect(table.allocate() == 0)
        #expect(table.allocate() == 1)
        #expect(table.allocate() == 2)
        #expect(table.initialized == 3)
        #expect(table.liveCount == 3)

        // A slot given back is the next one taken, before a new one is made.
        table.release(1)
        #expect(table.allocate() == 1)
        #expect(table.initialized == 3)
        // Taken again, it is a new connection by its generation.
        let before = table[1].pointee.generation
        table.release(1)
        #expect(table.allocate() == 1)
        #expect(table[1].pointee.generation == before &+ 1)
    }

    @Test func aFullTableRefusesAndReleasedSlotsComeBack() {
        var table = ConnectionTable(capacity: 4)
        defer { table.destroy() }
        for expected in 0..<4 { #expect(table.allocate() == expected) }
        #expect(table.allocate() == -1)
        #expect(table.initialized == 4)
        table.release(2)
        table.release(0)
        #expect(table.allocate() == 0)
        #expect(table.allocate() == 2)
        #expect(table.allocate() == -1)
        #expect(table.liveCount == 4)
    }
}
