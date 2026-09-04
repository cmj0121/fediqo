import Testing
import GRDB
@testable import FediqoCore

/// The base sources and the rules are lookup tables as well as enums, and a row a build does
/// not know is a timeline it cannot read. So the two lists are held to each other here, the
/// way the schema files are held to their bundled copies.
@Suite("The base sources, and the store's own list of them")
struct BaseSourceTests {
    @Test("Every base source is a row, and every row is a base source")
    func feedsMatchTheEnum() async throws {
        let store = try LocalStore.inMemory()
        let rows = try await store.read { db in
            try Row.fetchAll(db, sql: "SELECT feed, ranked, needs_account FROM feeds ORDER BY feed")
                .map { ($0["feed"] as String, ($0["ranked"] as Int) == 1, ($0["needs_account"] as Int) == 1) }
        }
        #expect(rows.map(\.0).sorted() == BaseSource.allCases.map(\.rawValue).sorted())
        for (feed, ranked, needsAccount) in rows {
            let source = try #require(BaseSource(rawValue: feed))
            #expect(source.ranked == ranked)
            #expect(source.needsAccount == needsAccount)
        }
    }

    @Test("Every kind of rule is a row, and every row is a kind of rule")
    func filterKindsMatchTheEnum() async throws {
        let store = try LocalStore.inMemory()
        let kinds = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM filter_kinds ORDER BY kind")
        }
        #expect(kinds == TimelineFilter.Kind.allCases.map(\.rawValue).sorted())
    }

    @Test("Trending is the only source that hands its own order over, and home the only one with an owner")
    func orderAndOwnership() {
        #expect(BaseSource.allCases.filter(\.ranked) == [.trend])
        // An inbox belongs to somebody as surely as a home timeline does: there is no
        // anonymous reading of what was aimed at a person.
        #expect(BaseSource.allCases.filter(\.needsAccount) == [.home, .notice])
        // A ranked list is a snapshot rather than a stretch of time, so nothing pages it and
        // no page from it is evidence that a post has gone. Nor is an inbox: a mention missing
        // from it says nothing about whether the post is still there.
        //
        // `author` is the one here that is a stretch of time and is listed anyway. A page of
        // somebody's posts leaves out what they deleted, so the evidence is real — what is not
        // yet established is that it would be read against the right stretch, and being wrong
        // means telling a reader a post is gone when it is not. See `BaseSource.author`.
        #expect(BaseSource.allCases.filter { !$0.isThreadOfTime } == [.trend, .thread, .notice, .author, .tag])
    }
}
