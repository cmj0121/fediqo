import Foundation
import Testing
@testable import FediqoCore

@Suite("Notices told on the reader's own Mastodon line")
struct MastodonNoticeLineTests {
    private static let source = Source(host: LocalServers.mastodon, kind: .mastodon)

    private static func told() throws -> [LineEvent] {
        var reader = ServerSentEvents()
        return try reader.feed(Data(ServerSentEventsTests.closed(MastodonNoticeLineCaptures.user).utf8))
    }

    @Test("The real line's notices read as the single read reads them: a favourite, a boost, a mention and a follow, each a line of one by its own id")
    func captured() throws {
        let told = try Self.told()
        #expect(told.map(\.name) == ["update", "notification", "notification", "update", "notification", "notification", "delete"])
        let notices = told.compactMap { MastodonNotices.told($0, source: Self.source) }
        #expect(notices.map(\.kind) == [.favourite, .reblog, .mention, .follow])
        #expect(notices.map(\.newestID) == ["138", "139", "140", "142"], "141, held back, is never told")
        #expect(notices.allSatisfy { $0.count == 1 && $0.source == Self.source })
        #expect(notices.map(\.handle) == [.one(id: "138"), .one(id: "139"), .one(id: "140"), .one(id: "142")])
        #expect(notices[0].post != nil && notices[3].post == nil, "a follow is about nobody's post")
        #expect(notices[3].people.first?.handle.contains("fediqo_hidden") == true)
    }

    @Test("The source saying requests let through have landed is heard by its own name, and is no notice")
    func merged() {
        let said = LineEvent(name: "notifications_merged", data: "1")
        #expect(MastodonNotices.saysMerged(said))
        #expect(MastodonNotices.told(said, source: Self.source) == nil)
        #expect(!MastodonNotices.saysMerged(LineEvent(name: "update", data: "{}")))
    }

    @Test("Any other event, or words that will not read, is no notice")
    func notNotices() throws {
        let told = try Self.told()
        #expect(MastodonNotices.told(told[0], source: Self.source) == nil)
        #expect(MastodonNotices.told(LineEvent(name: "notification", data: "{not json"), source: Self.source) == nil)
    }
}

/// #430: the three newer kinds, as `MastodonLiveCaptures` records a real server sending them.
@Suite("A quoted post changed, and a collection's news")
struct NoticeNewerKindsTests {
    private let source = Source(host: "mastodon.localhost", kind: .mastodon)

    private func page(_ path: String, _ body: String) async throws -> NoticePage {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: source.host, accessToken: "t", clientID: "c", clientSecret: "s")
        let door = MastodonAuthorized(token: token, sender: FixtureSender([path: .json(body)]), store: tokens)
        return try await MastodonNotices(door: door).page(source: source, gathered: path.contains("v2"))
    }

    @Test("Each word is a kind of its own, and comes back as it was sent", arguments: [
        ("quoted_update", Notice.Kind.quotedUpdate), ("added_to_collection", .addedToCollection), ("collection_update", .collectionUpdate),
    ])
    func words(word: String, kind: Notice.Kind) {
        #expect(Notice.Kind(type: word) == kind)
        #expect(kind.type == word)
    }

    @Test("A quoted post changed carries the person's own quoting post, on both reads")
    func quoted() async throws {
        let one = try #require(try await page("/api/v1/notifications", MastodonLiveCaptures.quotedUpdate).notices.first)
        #expect(one.kind == .quotedUpdate && one.post != nil && one.people.count == 1)
        let line = try #require(try await page("/api/v2/notifications", MastodonLiveCaptures.quotedUpdateGathered).notices.first)
        #expect(line.kind == .quotedUpdate && line.people.count == 1)
    }

    @Test("A collection's news names the collection and its owner, on both reads")
    func collections() async throws {
        let ones = try await page("/api/v1/notifications", MastodonLiveCaptures.collectionNews).notices
        #expect(ones.map(\.kind) == [.collectionUpdate, .addedToCollection])
        #expect(ones.allSatisfy { $0.collection == "Close friends" && $0.people.count == 1 && $0.post == nil })
        let lines = try await page("/api/v2/notifications", MastodonLiveCaptures.collectionNewsGathered).notices
        #expect(lines.map(\.kind) == [.collectionUpdate, .addedToCollection])
        #expect(lines.allSatisfy { $0.collection == "Close friends" && $0.people.count == 1 })
    }
}
