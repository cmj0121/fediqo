import Foundation
import Testing
import GRDB
@testable import FediqoCore

/// What a post carries besides its words: what came attached, whether it arrives covered, and
/// how it has been received. All three were thrown away until migration 005, so the tests that
/// matter most here are the ones about **not knowing**.
@Suite("What a post carries")
struct PostAnatomyTests {
    private let server = makeServer("one.example")

    private func attached(_ store: LocalStore, _ key: String) async throws -> [(String, String?, String?, String)] {
        try await store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT kind, url, preview_url, alt FROM post_media WHERE merge_key = ? ORDER BY position
                """, arguments: [key])
                .map { ($0["kind"] as String, $0["url"] as String?, $0["preview_url"] as String?, $0["alt"] as String) }
        }
    }

    @Test("An attachment keeps what it is, where it is, and what it was described as")
    func attachmentsSurviveTheRoundTrip() async throws {
        let store = try LocalStore.inMemory()
        let film = Attachment(kind: .video, url: URL(string: "https://one.example/v/1.mp4"),
                              previewURL: URL(string: "https://one.example/v/1.png"), alt: "a cat, falling over")
        let sound = Attachment(kind: .audio, url: URL(string: "https://one.example/a/1.mp3"))
        let post = makePost(uri: "https://one.example/1", at: 100)
        let carrying = Post(uri: post.uri, socialProtocol: .mastodon, sourceURL: post.sourceURL,
                            createdAt: post.createdAt, authorId: post.authorId, authorName: post.authorName,
                            authorHandle: post.authorHandle, text: post.text, attachments: [film, sound])
        try await store.save([carrying], from: server)

        let rows = try await attached(store, carrying.mergeKey)
        #expect(rows.map(\.0) == ["video", "audio"])
        #expect(rows[0].3 == "a cat, falling over")
        // An audio clip with no still is a row with no preview, not a row with a made-up one.
        #expect(rows[1].2 == nil)

        let read = try await store.timeline().first
        #expect(read?.attachments == [film, sound])
        // And what a screen can draw is the still where there is one, the file otherwise.
        #expect(read?.mediaURLs == [film.previewURL!, sound.url!])
    }

    @Test("A post stored before 005 says it has something to draw, and nothing more")
    func oldAttachmentsAreUnknown() async throws {
        let store = try LocalStore.inMemory()
        // Exactly what 001 wrote: the one column, and no row in `post_media`.
        try await store.save([makePost(uri: "https://one.example/1", at: 100)], from: server)
        try await store.write { db in
            try db.execute(sql: """
                UPDATE posts SET media_urls = '["https://one.example/m/1.jpg"]' WHERE merge_key = ?
                """, arguments: [makePost(uri: "https://one.example/1", at: 100).mergeKey])
        }

        let read = try #require(try await store.timeline().first)
        #expect(read.attachments.count == 1)
        // `unknown` is the answer rather than a missing one: it can be drawn, and that is all
        // anybody knows about it.
        #expect(read.attachments[0].kind == .unknown)
        #expect(read.attachments[0].url == nil)
        #expect(read.mediaURLs.map(\.absoluteString) == ["https://one.example/m/1.jpg"])
    }

    @Test("Never told and told-nothing are two different answers")
    func silenceIsNotAZero() async throws {
        let store = try LocalStore.inMemory()
        let silent = makePost(uri: "https://one.example/1", at: 100)
        let told = Post(uri: "https://one.example/2", socialProtocol: .mastodon, sourceURL: silent.sourceURL,
                        createdAt: Date(timeIntervalSince1970: 200), authorId: silent.authorId,
                        authorName: silent.authorName, authorHandle: silent.authorHandle, text: "told",
                        sensitive: false, spoiler: "", counts: Counts(replies: 0, reblogs: 3, favourites: nil))
        try await store.save([silent, told], from: server)

        let read = try await store.timeline()
        let quiet = try #require(read.first { $0.uri == silent.uri })
        #expect(quiet.sensitive == nil)
        #expect(quiet.spoiler == nil)
        #expect(quiet.counts.areKnown == false)

        let loud = try #require(read.first { $0.uri == told.uri })
        #expect(loud.sensitive == false)
        #expect(loud.spoiler == "")
        #expect(loud.counts.replies == 0)
        #expect(loud.counts.reblogs == 3)
        // A number that server did not send stays unknown rather than becoming zero.
        #expect(loud.counts.favourites == nil)
    }

    @Test("What a post was written with is kept, and its absence is not a guess")
    func theClientIsKeptWhereThereIsOne() async throws {
        let store = try LocalStore.inMemory()
        let written = Post(uri: "https://one.example/1", socialProtocol: .mastodon,
                           sourceURL: "https://one.example", createdAt: Date(timeIntervalSince1970: 100),
                           authorId: "https://one.example/users/a", authorName: "A",
                           authorHandle: "@a@one.example", text: "hello",
                           application: Application(name: "Ivory", website: URL(string: "https://tapbots.com/ivory")))
        let relayed = makePost(uri: "https://one.example/2", at: 200)
        try await store.save([written, relayed], from: server)

        let read = try await store.timeline()
        let mine = try #require(read.first { $0.uri == written.uri })
        #expect(mine.application?.name == "Ivory")
        #expect(mine.application?.website?.absoluteString == "https://tapbots.com/ivory")
        // A server says nothing about what somebody else's writer used, and neither do we.
        #expect(read.first { $0.uri == relayed.uri }?.application == nil)
    }

    @Test("A count moving is not an edit, and a server that sends none blanks nothing")
    func countsAreNotAnEdit() async throws {
        let store = try LocalStore.inMemory()
        let host = "authority.example"
        let authority = makeServer(host)
        let first = Post(uri: "https://\(host)/api/v1/statuses/1", originURI: "https://\(host)/users/a/statuses/1",
                         socialProtocol: .mastodon, sourceURL: "https://\(host)",
                         createdAt: Date(timeIntervalSince1970: 100), authorId: "https://\(host)/@a",
                         authorName: "A", authorHandle: "@a@\(host)", text: "hello",
                         counts: Counts(replies: 1, reblogs: 1, favourites: 1))
        try await store.save([first], from: authority, now: Date(timeIntervalSince1970: 1))

        let busier = Post(uri: first.uri, originURI: first.originURI, socialProtocol: .mastodon,
                          sourceURL: first.sourceURL, createdAt: first.createdAt, authorId: first.authorId,
                          authorName: first.authorName, authorHandle: first.authorHandle, text: "hello",
                          counts: Counts(replies: 9, reblogs: nil, favourites: nil))
        try await store.save([busier], from: authority, now: Date(timeIntervalSince1970: 2))

        let row = try await store.read { db in
            try Row.fetchOne(db, sql: """
                SELECT replies_count, reblogs_count, updated_at FROM posts WHERE merge_key = ?
                """, arguments: [first.mergeKey])
                .map { ($0["replies_count"] as Int?, $0["reblogs_count"] as Int?, $0["updated_at"] as Int64?) }
        }
        #expect(row?.0 == 9)
        // The one it stopped sending is kept rather than blanked.
        #expect(row?.1 == 1)
        // And `updated_at` still means what it always meant: an authority edited this post.
        #expect(row?.2 == nil)
    }
}
