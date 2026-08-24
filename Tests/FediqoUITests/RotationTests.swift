import Testing
@testable import FediqoUI

/// The rule every rotation in the app shares.
@Suite("Going round a list")
struct RotationTests {
    @Test("Forwards from the last is the first, backwards from the first is the last")
    func wrapsBothWays() {
        let items = ["a", "b", "c"]
        #expect(rotated(items, from: "a", by: 1) == "b")
        #expect(rotated(items, from: "c", by: 1) == "a")
        #expect(rotated(items, from: "a", by: -1) == "c")
        #expect(rotated(items, from: "c", by: -1) == "b")
    }

    @Test("A list with nowhere to start has no answer")
    func nowhereToStart() {
        #expect(rotated(["a", "b"], from: "z", by: 1) == nil)
        #expect(rotated([String](), from: "a", by: 1) == nil)
    }
}
