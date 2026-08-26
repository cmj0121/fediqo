import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// Posts written once and read back in order: the "Writing" and "Reading" diagrams, row by row.
@Suite("Posts in and out of the store")
struct PostStoreTests {
    private let one = Server(host: "one.example", socialProtocol: .mastodon, title: "One")
    private let two = Server(host: "two.example", socialProtocol: .mastodon, title: "Two")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_000_060)

    @Test("A post saved and read back is the post that was saved")
    func roundTrip() async throws {
        let store = try LocalStore.inMemory()
        let post = Post(
            uri: "https://one.example/api/v1/statuses/1",
            originURI: "https://o.example/users/a/statuses/1",
            socialProtocol: .mastodon,
            sourceURL: "https://one.example",
            createdAt: Date(timeIntervalSince1970: 1_000),
            authorId: "https://o.example/users/a",
            authorName: "A",
            authorHandle: "@a@o.example",
            authorAvatarURL: URL(string: "https://o.example/a.png"),
            text: "hello <b>world</b>",
            attachments: [Attachment(kind: .image, url: URL(string: "https://o.example/m/1.jpg"))],
            webURL: URL(string: "https://o.example/@a/1"),
            inReplyToURI: "https://one.example/api/v1/statuses/0",
            tags: ["Swift", "rust"],
            boostedBy: "B",
            boostedById: "https://b.example/users/b",
            sources: ["one.example"]
        )

        try await store.save([post], from: one, now: t0)
        let read = try await store.timeline()

        #expect(read == [post])
    }

    @Test("The same post from two servers is one row: the first source stays, last_seen_at moves")
    func twoServersOneRow() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([makePost(uri: "https://a.example/1", at: 100, from: "one.example")], from: one, now: t0)
        try await store.save([makePost(uri: "https://a.example/1", at: 100, from: "two.example")], from: two, now: t1)

        let (source, lastSeen, created) = try await store.read { db -> (String, Int64, Int64) in
            let row = try Row.fetchOne(db, sql: "SELECT source_url, last_seen_at, created_at FROM posts")!
            return (row["source_url"], row["last_seen_at"], row["created_at"])
        }
        #expect(try await count(store, "SELECT count(*) FROM posts") == 1)
        #expect(source == "https://one.example")
        #expect(lastSeen == LocalStore.milliseconds(t1))
        #expect(created == LocalStore.milliseconds(t0))
        #expect(try await store.timeline().map(\.sources) == [["one.example"]])
    }

    @Test("A boost and its original are two rows")
    func boostIsItsOwnRow() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([
            makePost(uri: "https://a.example/1", at: 100),
            makePost(uri: "https://a.example/1", at: 120, boostedBy: "someone else"),
        ], from: one, now: t0)

        let read = try await store.timeline()
        #expect(read.count == 2)
        #expect(read.map(\.boostedBy) == ["someone else", nil])
        #expect(try await count(store, "SELECT count(*) FROM accounts") == 2)
    }

    @Test("The authority's edit is taken; anyone else's is ignored")
    func onlyTheAuthorityEdits() async throws {
        let store = try LocalStore.inMemory()
        let origin = "https://one.example/users/someone/statuses/1"
        let first = makePost(uri: "https://one.example/api/v1/statuses/1", originURI: origin, at: 100, from: "one.example", tags: ["a"])
        try await store.save([first], from: one, now: t0)

        let edited = makePost(uri: first.uri, originURI: origin, at: 100, from: "one.example", text: "edited", tags: ["b"])
        try await store.save([edited], from: one, now: t1)

        let (text, updated) = try await store.read { db -> (String, Int64?) in
            let row = try Row.fetchOne(db, sql: "SELECT text, updated_at FROM posts")!
            return (row["text"], row["updated_at"])
        }
        #expect(text == "edited")
        #expect(updated == LocalStore.milliseconds(t1))
        #expect(try await store.timeline().first?.tags == ["b"])

        let elsewhere = makePost(uri: "https://two.example/api/v1/statuses/9", originURI: origin, at: 100, from: "two.example",
                                 authorId: first.authorId, text: "tampered", tags: ["c"])
        try await store.save([elsewhere], from: two, now: t1)

        #expect(try await store.timeline().first?.text == "edited")
        #expect(try await store.timeline().first?.tags == ["b"])
    }

    @Test("An authority changing only the tags is taken; anyone else changing them is not")
    func onlyTheAuthorityRetags() async throws {
        let store = try LocalStore.inMemory()
        let origin = "https://one.example/users/someone/statuses/1"
        let first = makePost(uri: "https://one.example/api/v1/statuses/1", originURI: origin, at: 100, from: "one.example", tags: ["a"])
        try await store.save([first], from: one, now: t0)

        let retagged = makePost(uri: first.uri, originURI: origin, at: 100, from: "one.example", tags: ["a", "b"])
        try await store.save([retagged], from: one, now: t1)
        #expect(try await store.timeline().first?.tags == ["a", "b"])
        #expect(try await store.read { db in try Int64.fetchOne(db, sql: "SELECT updated_at FROM posts") } == LocalStore.milliseconds(t1))

        let elsewhere = makePost(uri: "https://two.example/api/v1/statuses/9", originURI: origin, at: 100, from: "two.example", tags: ["c"])
        try await store.save([elsewhere], from: two, now: t1)
        #expect(try await store.timeline().first?.tags == ["a", "b"])
    }

    @Test("A post lands in the hour it was posted, and a bucket never shrinks")
    func bucketsFollowPostedAtAndOnlyGrow() async throws {
        let store = try LocalStore.inMemory()
        let twoHoursAgo = t0.addingTimeInterval(-7_200).timeIntervalSince1970
        let posts = [
            makePost(uri: "https://a.example/1", at: twoHoursAgo, tags: ["swift"]),
            makePost(uri: "https://a.example/2", at: twoHoursAgo + 1, tags: ["swift"]),
        ]
        try await store.save(posts, from: one, now: t0)

        let bucket = LocalStore.hourBucket(LocalStore.milliseconds(Date(timeIntervalSince1970: twoHoursAgo)))
        #expect(bucket != LocalStore.hourBucket(LocalStore.milliseconds(t0)))
        #expect(try await count(store, "SELECT posts FROM tag_buckets WHERE tag = 'swift' AND bucket_at = ?", [bucket]) == 2)
        #expect(try await count(store, "SELECT count(*) FROM tag_buckets") == 1)

        try await store.markDeleted(mergeKey: posts[0].mergeKey, now: t0)
        try await store.purgeDeleted(olderThan: t1)
        try await store.save([posts[1]], from: one, now: t1)
        #expect(try await count(store, "SELECT posts FROM tag_buckets WHERE tag = 'swift' AND bucket_at = ?", [bucket]) == 2)
        #expect(try await store.read { db in try Int64.fetchOne(db, sql: "SELECT updated_at FROM tag_buckets") } == nil)
    }

    @Test("A server learns its title once, and what is local to it is never touched")
    func serverTitleFillsIn() async throws {
        let store = try LocalStore.inMemory()
        // Seen first as an origin: no title yet.
        let viaTwo = makePost(uri: "https://two.example/api/v1/statuses/1", originURI: "https://one.example/users/someone/statuses/1",
                              at: 100, from: "two.example")
        try await store.save([viaTwo], from: two, now: t0)
        try await store.write { db in try db.execute(sql: "UPDATE servers SET selected_at = 7, position = 3 WHERE url = 'https://one.example'") }
        #expect(try await store.read { db in try String.fetchOne(db, sql: "SELECT title FROM servers WHERE url = 'https://one.example'") } == nil)

        try await store.save([makePost(uri: "https://a.example/2", at: 100)], from: one, now: t1)
        try await store.save([makePost(uri: "https://a.example/3", at: 100)], from: one, now: t1)
        let (title, selected, position) = try await store.read { db -> (String?, Int64?, Int64?) in
            let row = try Row.fetchOne(db, sql: "SELECT title, selected_at, position FROM servers WHERE url = 'https://one.example'")!
            return (row["title"], row["selected_at"], row["position"])
        }
        #expect(title == "One")
        #expect(selected == 7)
        #expect(position == 3)
    }

    @Test("ActivityPub is stored as Mastodon and read back as Mastodon")
    func activityPubIsMastodonToTheStore() async throws {
        let store = try LocalStore.inMemory()
        let post = makePost(uri: "https://ap.example/notes/1", at: t0.timeIntervalSince1970, from: "ap.example", socialProtocol: .activityPub)
        try await store.save([post], from: Server(host: "ap.example", socialProtocol: .activityPub), now: t0)

        #expect(try await store.read { db in try String.fetchOne(db, sql: "SELECT proto FROM posts") } == "mastodon")
        #expect(try await store.timeline().first?.socialProtocol == .mastodon)
    }

    @Test("A trend's updated_at moves with its rank, not with every sighting")
    func trendUpdatedOnlyOnRankChange() async throws {
        let store = try LocalStore.inMemory()
        let post = makePost(uri: "https://a.example/1", at: 100)
        let zero = makePost(uri: "https://a.example/0", at: 100)
        try await store.save([post, zero], from: one, now: t0)
        try await store.recordTrending([post], from: one, now: t0)
        try await store.recordTrending([post], from: one, now: t1)
        #expect(try await store.read { db in try Int64.fetchOne(db, sql: "SELECT updated_at FROM server_trends") } == nil)

        try await store.recordTrending([zero, post], from: one, now: t1)
        #expect(try await store.read { db in try Int64.fetchOne(db, sql: "SELECT updated_at FROM server_trends WHERE rank = 1") } == LocalStore.milliseconds(t1))
    }

    @Test("Tags land in tags and post_tags, and the hour's bucket counts posts and distinct authors")
    func tagsAndBuckets() async throws {
        let store = try LocalStore.inMemory()
        let seconds = t0.timeIntervalSince1970
        try await store.save([
            makePost(uri: "https://a.example/1", at: seconds, tags: ["Swift", "rust"]),
            makePost(uri: "https://a.example/2", at: seconds + 1, tags: ["swift"]),
            makePost(uri: "https://a.example/3", at: seconds + 2, authorId: "https://one.example/users/other", tags: ["swift"]),
        ], from: one, now: t0)

        let tags = try await store.read { db in try String.fetchAll(db, sql: "SELECT tag FROM tags ORDER BY tag") }
        let buckets = try await store.read { db in
            try Row.fetchAll(db, sql: "SELECT tag, posts, authors FROM tag_buckets ORDER BY tag")
                .map { ($0["tag"] as String, $0["posts"] as Int, $0["authors"] as Int) }
        }
        #expect(tags == ["rust", "swift"])
        #expect(try await count(store, "SELECT count(*) FROM post_tags") == 4)
        #expect(buckets.map(\.0) == ["rust", "swift"])
        #expect(buckets.map(\.1) == [1, 3])
        #expect(buckets.map(\.2) == [1, 2])
        #expect(try await count(store, "SELECT count(DISTINCT bucket_at) FROM tag_buckets") == 1)
    }

    @Test("Trending writes what the server ranked, and reads back in that order")
    func trendingKeepsRank() async throws {
        let store = try LocalStore.inMemory()
        let posts = [
            makePost(uri: "https://a.example/older", at: 100),
            makePost(uri: "https://a.example/newer", at: 200),
        ]
        try await store.save(posts, from: one, now: t0)
        try await store.recordTrending(posts, from: one, now: t0)
        try await store.recordTrending(posts.reversed(), from: one, now: t1)

        let (firstSeen, lastSeen, rank) = try await store.read { db -> (Int64, Int64, Int) in
            let row = try Row.fetchOne(db, sql: "SELECT first_seen_at, last_seen_at, rank FROM server_trends WHERE merge_key = ?",
                                       arguments: ["https://a.example/newer"])!
            return (row["first_seen_at"], row["last_seen_at"], row["rank"])
        }
        #expect(firstSeen == LocalStore.milliseconds(t0))
        #expect(lastSeen == LocalStore.milliseconds(t1))
        #expect(rank == 0)
        #expect(try await store.trending(since: t0).map(\.uri) == ["https://a.example/newer", "https://a.example/older"])
        #expect(try await store.trending(since: t1.addingTimeInterval(1)).isEmpty)
        #expect(try await count(store, "SELECT count(*) FROM server_trends") == 2)
    }

    @Test("The timeline does not write server_trends")
    func timelineWritesNoTrends() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([makePost(uri: "https://a.example/1", at: 100)], from: one, now: t0)
        #expect(try await count(store, "SELECT count(*) FROM server_trends") == 0)
    }

    @Test("A deleted post leaves the timeline; a purge removes it and what hangs off it, but not the count")
    func deleteThenPurge() async throws {
        let store = try LocalStore.inMemory()
        let post = makePost(uri: "https://a.example/1", at: t0.timeIntervalSince1970, tags: ["swift"])
        try await store.save([post], from: one, now: t0)
        try await store.recordTrending([post], from: one, now: t0)

        try await store.markDeleted(mergeKey: post.mergeKey, now: t0)
        try await store.markDeleted(mergeKey: post.mergeKey, now: t1)
        #expect(try await store.timeline().isEmpty)
        #expect(try await store.trending(since: t0).isEmpty)
        #expect(try await store.read { db in try Int64.fetchOne(db, sql: "SELECT deleted_at FROM posts") } == LocalStore.milliseconds(t0))

        #expect(try await store.purgeDeleted(olderThan: t0) == 0)
        #expect(try await store.purgeDeleted(olderThan: t1) == 1)
        #expect(try await count(store, "SELECT count(*) FROM posts") == 0)
        #expect(try await count(store, "SELECT count(*) FROM post_tags") == 0)
        #expect(try await count(store, "SELECT count(*) FROM server_trends") == 0)
        #expect(try await count(store, "SELECT count(*) FROM posts_fts WHERE posts_fts MATCH 'hello'") == 0)
        #expect(try await count(store, "SELECT posts FROM tag_buckets WHERE tag = 'swift'") == 1)
    }

    @Test("Full-text search finds what was written")
    func searchFindsText() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([makePost(uri: "https://a.example/1", at: 100)], from: one, now: t0)
        #expect(try await count(store, "SELECT count(*) FROM posts_fts WHERE posts_fts MATCH 'hello'") == 1)
        #expect(try await count(store, "SELECT count(*) FROM posts_fts WHERE posts_fts MATCH 'goodbye'") == 0)
    }

    @Test("A post without an author is refused, not skipped")
    func emptyAuthorRefused() async throws {
        let store = try LocalStore.inMemory()
        let post = makePost(uri: "u", at: 100, authorId: "")
        await #expect(throws: PostStoreError.missingAuthor(uri: "u")) {
            try await store.save([post], from: one, now: t0)
        }
        #expect(try await count(store, "SELECT count(*) FROM posts") == 0)
    }
}
