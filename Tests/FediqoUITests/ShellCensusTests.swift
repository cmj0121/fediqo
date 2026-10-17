import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// The session's census (#360, K-12): how many entries each collection the session holds has —
/// what the long walk prints beside the store's. Counts only, asserted as counts.
@Suite("The session's census")
@MainActor
struct ShellCensusTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("a session over an empty store counts nothing in any collection")
    func empty() {
        let census = ShellSession(http: FixtureHTTP([:])).census()
        #expect(!census.isEmpty)
        #expect(census.filter { $0.value != 0 }.isEmpty)
    }

    @Test("a session over a store of N rows holds N notes", arguments: [1, 30])
    func held(rows: Int) async {
        let notes = (0..<rows).map { n in
            Note(
                id: "p\(n)", source: Self.source, author: "A", handle: "a@one.example", body: "b",
                postedAt: Self.at.addingTimeInterval(-Double(n) * 60), categories: [.home]
            )
        }
        let session = ShellSession(http: FixtureHTTP([:]), store: ItemStore(sources: [Self.source], notes: notes))
        await session.reloadFromStore()
        let census = session.census()
        #expect(census["notes"] == rows)
        #expect(census["sources"] == 1)
        #expect(census["heldReplies"] == 0)
    }
}
