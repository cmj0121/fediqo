import Foundation
import Testing
import GRDB
@testable import FediqoCore

/// Which writers a public timeline is asked for (#113).
///
/// One server's own writers is a different room from the federated timeline, and today there was
/// one public timeline that was both at once, so neither question could be asked.
@Suite("The room, and everywhere else")
struct WritersTests {
    // MARK: - the cut is a lookup as well as an enum

    /// The arrangement `feeds` and `filter_kinds` already have: a row a build does not know is a
    /// timeline it cannot read, so the two lists are held to each other here.
    @Test("Every cut is a row, and every row is a cut")
    func writersMatchTheEnum() async throws {
        let store = try LocalStore.inMemory()
        let rows = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT writers FROM writers ORDER BY writers")
        }
        #expect(rows == Writers.allCases.map(\.rawValue).sorted())
    }

    @Test("The rows were stamped when the migration ran")
    func writersWereStamped() async throws {
        let store = try LocalStore.inMemory()
        let seeded = try await store.read { db in
            try Bool.fetchOne(db, sql: "SELECT min(created_at) > 0 FROM writers")!
        }
        #expect(seeded)
    }

    // MARK: - only the public timeline has a room to cut out of

    /// A home timeline is already one account's, a trending list is the server's own, and a
    /// conversation is one post's. None of them has a room, so none of them keeps a cut — a
    /// value that cannot mean anything is not one to carry around waiting to be believed.
    @Test("Only the public timeline keeps a cut")
    func onlyPublicKeepsIt() {
        #expect(Timeline(name: "n", source: .public, writers: .here, template: "local").writers == .here)
        for source in BaseSource.allCases where source != .public {
            let timeline = Timeline(name: "n", source: source, writers: .here, template: "t")
            #expect(timeline.writers == .everyone)
            #expect(timeline.query.writers == .everyone)
        }
    }

    @Test("A reading carries the cut it was made with")
    func theQueryCarriesIt() {
        let timeline = Timeline(name: "n", source: .public, writers: .elsewhere, template: "remote")
        #expect(timeline.query.writers == .elsewhere)
    }

    // MARK: - through the store and back

    @Test("A timeline remembers which writers it was asked for")
    func roundTrip() async throws {
        let store = try LocalStore.inMemory()
        for (id, writers) in [("a", Writers.everyone), ("b", .here), ("c", .elsewhere)] {
            try await store.save(Timeline(id: id, name: id, source: .public, writers: writers,
                                          template: "public", position: 0))
        }
        let back = try await store.timelines().reduce(into: [String: Writers]()) { $0[$1.id] = $1.writers }
        #expect(back == ["a": .everyone, "b": .here, "c": .elsewhere])
    }

    /// Nothing is backfilled, and here that is not a compromise: every timeline written down
    /// before 017 was asked for the whole public timeline, so `everyone` is what it has always
    /// meant rather than a guess put in its place.
    @Test("A timeline written before the cut existed is the whole timeline")
    func writtenBeforeTheColumn() async throws {
        let store = try LocalStore.inMemory()
        try await store.save(Timeline(id: "old", name: "old", source: .public, template: "public"))
        try await store.write { db in
            try db.execute(sql: "UPDATE timelines SET writers = 'everyone' WHERE id = 'old'")
        }
        #expect(try await store.timelines().first?.writers == .everyone)
    }

    // MARK: - what is asked, and what is checked

    @Test("Each cut is one query, and the whole timeline is none")
    func theQueryItself() {
        #expect(Writers.everyone.mastodonQuery == nil)
        #expect(Writers.here.mastodonQuery?.name == "local")
        #expect(Writers.elsewhere.mastodonQuery?.name == "remote")
    }

    /// A post fetched from a server carries that server as its `sourceURL` whoever wrote it —
    /// that is what fetching means. Who wrote it is in the handle.
    @Test("Who wrote a post is read off the handle, not off where it was fetched from")
    func whoWroteIt() {
        let mine = makePost(uri: "https://a.example/1", at: 1, from: "a.example")
        #expect(MastodonClient.wrote(mine, on: "a.example"))
        // Fetched from a.example, written on b.example: what a federated timeline is full of.
        let theirs = Post(uri: "https://a.example/2", socialProtocol: .mastodon,
                          sourceURL: "https://a.example", createdAt: Date(),
                          authorId: "https://b.example/users/someone", authorName: "someone",
                          authorHandle: "@someone@b.example", text: "hello")
        #expect(!MastodonClient.wrote(theirs, on: "a.example"))
    }

    /// A handle with no host is the server's own writer, which is how Mastodon writes a local
    /// account: `@someone`, with nowhere else to say.
    @Test("A handle with no server is this server's own writer")
    func abareHandleIsLocal() {
        let local = Post(uri: "https://a.example/3", socialProtocol: .mastodon,
                         sourceURL: "https://a.example", createdAt: Date(),
                         authorId: "https://a.example/users/someone", authorName: "someone",
                         authorHandle: "@someone", text: "hello")
        #expect(MastodonClient.wrote(local, on: "a.example"))
    }

    // MARK: - a client that cannot cut says so

    /// Mastodon drops a query parameter it does not know rather than refusing the request, so a
    /// server too old for these hands back the whole federated timeline with a 200. There is no
    /// status code to read — which is why a protocol with no word for the cut must refuse rather
    /// than answer the whole thing, and a reader is told rather than shown the wrong room.
    @Test("A client with no word for the cut refuses rather than answering the whole timeline")
    func aclientThatCannotCut() async throws {
        let client = Uncutting()
        // The whole timeline is not a cut, and falls through to the ordinary reading.
        #expect(try await client.timeline(host: "a.example", limit: 1, before: nil, after: nil,
                                          writers: .everyone, token: nil).count == 1)
        for writers in [Writers.here, .elsewhere] {
            await #expect(throws: SourceFailure.wouldNotCut("a.example", writers)) {
                try await client.timeline(host: "a.example", limit: 1, before: nil, after: nil,
                                          writers: writers, token: nil)
            }
        }
    }

    /// Whatever it is asked, it answers with one post and knows nothing about cutting.
    private struct Uncutting: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] {
            [makePost(uri: "https://a.example/1", at: 1, from: "a.example")]
        }
    }
}
