import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// What one server said somebody did, written down once and read back whole.
@Suite("Notices in and out of the store")
struct NoticeStoreTests {
    private let one = Server(host: "one.example", socialProtocol: .mastodon, title: "One")
    private let two = Server(host: "two.example", socialProtocol: .mastodon, title: "Two")
    private let me = "https://one.example/users/me"
    private let alsoMe = "https://two.example/users/me"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_000_060)

    /// A signed-in account, written the short way. `owned_accounts` has a foreign key to
    /// `accounts`, which has one to `servers`, so all three go in — the same order
    /// `SignInCoordinator` writes them in, and for the same reason.
    private func signIn(_ store: LocalStore, _ server: Server, as authorId: String) async throws {
        try await store.write { db in
            try db.execute(sql: """
                INSERT INTO servers (url, host, proto, created_at) VALUES (?, ?, 'mastodon', 1)
                ON CONFLICT DO NOTHING
                """, arguments: [server.endpoint, server.host])
            try db.execute(sql: """
                INSERT INTO accounts (author_id, proto, server_url, created_at) VALUES (?, 'mastodon', ?, 1)
                ON CONFLICT DO NOTHING
                """, arguments: [authorId, server.endpoint])
            try db.execute(sql: """
                INSERT INTO owned_accounts (author_id, server_url, created_at) VALUES (?, ?, 1)
                ON CONFLICT DO NOTHING
                """, arguments: [authorId, server.endpoint])
        }
    }

    private func mention(_ id: String, on server: Server, to owner: String,
                         at moment: Date, arrived: Date? = nil) -> Notice {
        Notice(
            remoteId: id,
            serverURL: server.endpoint,
            kind: .mention,
            ownerId: owner,
            actorId: "https://who.example/users/who",
            actorName: "Who",
            actorHandle: "@who@who.example",
            actorAvatarURL: URL(string: "https://who.example/who.png"),
            post: Post(
                uri: "https://\(server.host)/api/v1/statuses/\(id)",
                originURI: "https://who.example/users/who/statuses/\(id)",
                socialProtocol: .mastodon,
                sourceURL: server.endpoint,
                createdAt: moment,
                authorId: "https://who.example/users/who",
                authorName: "Who",
                authorHandle: "@who@who.example",
                text: "at you, \(id)",
                sources: [server.host]
            ),
            noticedAt: moment,
            arrivedAt: arrived ?? moment
        )
    }

    @Test("Every kind of notice is a row, and every row is a kind of notice")
    func kindsMatchTheEnum() async throws {
        let store = try LocalStore.inMemory()
        let kinds = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM notice_kinds ORDER BY kind")
        }
        #expect(kinds == NoticeKind.allCases.map(\.rawValue).sorted())
    }

    @Test("A mention saved and read back brings its post with it")
    func roundTrip() async throws {
        let store = try LocalStore.inMemory()
        try await signIn(store, one, as: me)

        let notice = mention("7", on: one, to: me, at: t0)
        #expect(try await store.save([notice], from: one, as: me, now: t1) == 1)

        let read = try await store.notices()
        #expect(read.count == 1)
        #expect(read.first?.id == "https://one.example#7")
        #expect(read.first?.kind == .mention)
        #expect(read.first?.actorHandle == "@who@who.example")
        #expect(read.first?.post?.text == "at you, 7")
        #expect(read.first?.isUnseen == true)
        #expect(try await store.unseenNoticeCount() == 1)
    }

    /// The status inside a notification is a post like any other, and arrives having said how
    /// it arrived — there is no such thing here as a post from nowhere.
    @Test("A mention's post arrives through the notice feed, like every other post says how it came")
    func theStatusIsAPost() async throws {
        let store = try LocalStore.inMemory()
        try await signIn(store, one, as: me)
        try await store.save([mention("7", on: one, to: me, at: t0)], from: one, as: me, now: t1)

        let feeds = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT feed FROM post_origins")
        }
        #expect(feeds == ["notice"])
    }

    /// A reconnect asks for everything after the mark and the live socket carries some of the
    /// same events. Overlap is the normal case, and the second telling must change nothing.
    @Test("Told twice, kept once — and the moment it first arrived is not moved")
    func toldTwice() async throws {
        let store = try LocalStore.inMemory()
        try await signIn(store, one, as: me)

        let first = mention("7", on: one, to: me, at: t0, arrived: t0)
        #expect(try await store.save([first], from: one, as: me, now: t0) == 1)

        let again = mention("7", on: one, to: me, at: t0, arrived: t1)
        #expect(try await store.save([again], from: one, as: me, now: t1) == 0)

        let read = try await store.notices()
        #expect(read.count == 1)
        #expect(read.first?.arrivedAt == t0)
    }

    /// `remote_id` is unique on the server that issued it and nowhere else. Two servers
    /// numbering their own events from one is the ordinary case, not a collision.
    @Test("Two servers can both call an event 7, and that is two notices")
    func sameNumberDifferentServers() async throws {
        let store = try LocalStore.inMemory()
        try await signIn(store, one, as: me)
        try await signIn(store, two, as: alsoMe)

        try await store.save([mention("7", on: one, to: me, at: t0)], from: one, as: me, now: t0)
        try await store.save([mention("7", on: two, to: alsoMe, at: t1)], from: two, as: alsoMe, now: t1)

        let read = try await store.notices()
        #expect(read.map(\.id) == ["https://two.example#7", "https://one.example#7"])
        #expect(read.map(\.ownerId) == [alsoMe, me])
    }

    @Test("The mark moves forward and never back")
    func markOnlyClimbs() async throws {
        let store = try LocalStore.inMemory()
        try await signIn(store, one, as: me)

        #expect(try await store.noticeMark(from: one.endpoint, as: me) == nil)
        try await store.setNoticeMark("40", from: one.endpoint, as: me)
        #expect(try await store.noticeMark(from: one.endpoint, as: me) == "40")

        // A catch-up still walking an older page finishing after a live event landed.
        try await store.setNoticeMark("30", from: one.endpoint, as: me)
        #expect(try await store.noticeMark(from: one.endpoint, as: me) == "40")
    }

    /// What a reader saw is a screenful with a bottom edge. What arrived while they were
    /// reading it is not among them.
    @Test("Looking marks what was there, not what arrived afterwards")
    func seenHasAnEdge() async throws {
        let store = try LocalStore.inMemory()
        try await signIn(store, one, as: me)
        try await store.save([mention("1", on: one, to: me, at: t0),
                              mention("2", on: one, to: me, at: t1)], from: one, as: me, now: t1)

        #expect(try await store.markNoticesSeen(upTo: t0) == 1)
        #expect(try await store.unseenNoticeCount() == 1)

        let read = try await store.notices()
        #expect(read.map(\.isUnseen) == [true, false])
    }

    /// Several events can share a millisecond. Paging on the time alone would either repeat
    /// them or step over them, so the cursor is the pair.
    @Test("A page is taken from a place, and a shared timestamp is still two places")
    func pagingOnThePair() async throws {
        let store = try LocalStore.inMemory()
        try await signIn(store, one, as: me)
        try await store.save([mention("1", on: one, to: me, at: t0),
                              mention("2", on: one, to: me, at: t0),
                              mention("3", on: one, to: me, at: t0)], from: one, as: me, now: t0)

        let first = try await store.notices(limit: 2)
        #expect(first.map(\.remoteId) == ["3", "2"])

        let next = try await store.notices(limit: 2, before: first.last)
        #expect(next.map(\.remoteId) == ["1"])
    }
}
