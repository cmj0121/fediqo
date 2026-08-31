import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// Who a post was written for, from the wire to the store.
///
/// The four are a closed set and the schema says so with a foreign key, so there are two ways
/// to be wrong and both are here: a word nobody has heard of must not reach the store, and a
/// post nobody described must not be given an audience it never claimed.
@Suite("Who a post was written for")
struct AudienceTests {
    private func statusJSON(_ visibility: String?, boostedBy: String? = nil) -> String {
        let said = visibility.map { "\"visibility\": \"\($0)\"," } ?? ""
        let inner = """
        "id": "1",
        "uri": "https://one.example/users/a/statuses/1",
        "url": "https://one.example/@a/1",
        "created_at": "2026-08-21T10:00:00.000Z",
        "content": "<p>hello</p>",
        \(said)
        "account": { "id": "10", "url": "https://one.example/@a", "username": "a", "acct": "a",
                     "display_name": "Ada", "avatar": null },
        "media_attachments": [], "tags": []
        """
        guard let boostedBy else { return "[{\(inner)}]" }
        // The wrapper is public, as a boost's wrapper always is; the post inside it is not.
        return """
        [{
          "id": "2",
          "uri": "https://one.example/users/\(boostedBy)/statuses/2/activity",
          "url": null,
          "created_at": "2026-08-21T11:00:00Z",
          "content": "",
          "visibility": "public",
          "account": { "id": "11", "url": "https://one.example/@\(boostedBy)", "username": "\(boostedBy)",
                       "acct": "\(boostedBy)", "display_name": "Bee", "avatar": null },
          "media_attachments": [], "tags": [],
          "reblog": {\(inner)}
        }]
        """
    }

    private func decoded(_ json: String) throws -> Post {
        try MastodonClient.decoder
            .decode([MastodonDTO.Status].self, from: Data(json.utf8))
            .map { $0.asPost(from: "one.example") }[0]
    }

    @Test("Each of the four words the wire uses names an audience",
          arguments: [("public", Audience.everyone), ("unlisted", .unlisted),
                      ("private", .followers), ("direct", .mentioned)])
    func theFourWords(word: String, audience: Audience) throws {
        #expect(try decoded(statusJSON(word)).audience == audience)
        // And the raw value is the wire's word, so nothing is translated on the way to the store.
        #expect(audience.rawValue == word)
    }

    /// A server that says nothing has told us nothing, and a server that says something this
    /// build has never heard of has told us nothing we can pass on. Both are `nil`, and neither
    /// costs the reader the post.
    @Test("A word nobody said, and a word nobody knows, are both never-told")
    func nothingAndNonsense() throws {
        #expect(try decoded(statusJSON(nil)).audience == nil)
        #expect(try decoded(statusJSON("limited")).audience == nil)
        #expect(try decoded(statusJSON("limited")).text == "hello")
    }

    /// A boost's wrapper is always public; the post inside it is what was written and what the
    /// row draws. Reading the wrapper would tell every reader that a followers-only post they
    /// are looking at is public, which is the worst of the four to get wrong.
    @Test("A boost carries the audience of the post it boosted, not the wrapper's")
    func aBoostSaysWhatWasWritten() throws {
        let post = try decoded(statusJSON("private", boostedBy: "b"))
        #expect(post.isBoost)
        #expect(post.audience == .followers)
    }

    @Test("It survives the store, and comes back the same")
    func itRoundTrips() async throws {
        let store = try LocalStore.inMemory()
        let server = Server(host: "one.example", socialProtocol: .mastodon)
        let posts = Audience.allCases.enumerated().map { index, audience in
            makePost(uri: "https://one.example/api/v1/statuses/\(index)",
                     originURI: "https://one.example/users/a/statuses/\(index)",
                     at: TimeInterval(index), audience: audience)
        }
        try await store.save(posts, from: server)

        let read = try await store.posts(named: posts.map(\.mergeKey))
        #expect(Set(read.compactMap(\.post.audience)) == Set(Audience.allCases))
    }

    /// The one thing a bare column could not do. `visibilities` is the contract, and a word
    /// outside it is refused here rather than stored and puzzled over on some later read.
    @Test("A word outside the four is refused by the store, not kept")
    func theSetIsClosed() async throws {
        let store = try LocalStore.inMemory()
        let post = makePost(uri: "a", at: 1)
        try await store.save([post], from: Server(host: "one.example", socialProtocol: .mastodon))

        await #expect(throws: (any Error).self) {
            try await store.write { db in
                try db.execute(sql: "UPDATE posts SET visibility = 'limited' WHERE merge_key = ?",
                               arguments: [post.mergeKey])
            }
        }
    }

    /// Nothing is backfilled, here as everywhere. A post written down before there was a column
    /// for this has no answer in it, and never acquires one by being read again.
    @Test("A post stored with no audience keeps none")
    func nothingIsInvented() async throws {
        let store = try LocalStore.inMemory()
        let post = makePost(uri: "a", at: 1)
        try await store.save([post], from: Server(host: "one.example", socialProtocol: .mastodon))

        let read = try await store.posts(named: [post.mergeKey]).first
        #expect(read?.post.audience == nil)
    }

    /// The four the schema seeds are the four the type has, in the same words. Two lists that
    /// have to agree, so they are asked to.
    @Test("The schema's four and the type's four are one list")
    func theSchemaAgrees() async throws {
        let store = try LocalStore.inMemory()
        let seeded = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT visibility FROM visibilities ORDER BY visibility")
        }
        #expect(seeded == Audience.allCases.map(\.rawValue).sorted())
        // And they were stamped when the migration ran, like every other seeded lookup.
        let stamped = try await store.read { db in
            try Bool.fetchOne(db, sql: "SELECT min(created_at) > 0 FROM visibilities")!
        }
        #expect(stamped)
    }
}
