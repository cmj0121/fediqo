import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #299: the ways of reaching a source that `SourceReachPinTests` does not drive — reading
/// older, a forum's next page, what is rising further down, reading down a place where posts
/// may be missing, a forum's blog, and a forum's reload across a change of sign-in. For each,
/// what went out: through which door, with a token or without, and under which purpose and name.
///
/// **Written after the building of clients was gathered into one place, and run unchanged
/// against the code from before it**, where every one of these passes too.
@MainActor
@Suite("Each source is reached as it was, further down")
struct SourceReachMovedPinTests {
    private static let m = "m.example"
    private static let z = "z.example"
    private static let d = "d.example"
    private static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private static let mastodon = Source(host: m, kind: .mastodon, lists: [ListSubscription(id: "7", name: "Friends")])
    private static let discourse = Source(host: d, kind: .discourse)

    private static func post(_ id: Int, _ category: FediqoCore.Category, gap: Bool = false) -> Note {
        Note(
            id: "https://\(m)/users/ada/statuses/\(category)-\(id)", source: Source(host: m, kind: .mastodon), author: "Ada",
            handle: "@ada@\(m)", body: "post \(id)", postedAt: origin.addingTimeInterval(Double(id)), categories: [category],
            statusID: "\(id)", gaps: gap ? [TimelineGap(.mayBeMissing, in: category)] : [], listed: [category: "\(id)"]
        )
    }

    private static func thread(_ tid: Int, on host: String, kind: ProtocolKind, board: String? = nil) -> Note {
        Note(
            id: kind == .discuz ? "discuz:\(host):\(tid)" : "discourse:\(host):\(tid)", source: Source(host: host, kind: kind),
            author: "kim", handle: "kim@\(host)", body: "", title: "t\(tid)", postedAt: origin.addingTimeInterval(Double(tid)),
            categories: board.map { [.board(id: $0)] } ?? []
        )
    }

    private static func statuses(_ ids: ClosedRange<Int>) -> String {
        "[" + ids.map {
            #"{"id":"\#($0)","uri":"https://m.example/users/ada/statuses/t\#($0)","created_at":"2026-01-01T00:00:00.000Z","content":"<p>x</p>","visibility":"public","account":{"username":"ada","acct":"ada","display_name":"Ada"}}"#
        }.joined(separator: ",") + "]"
    }

    private static func shell(
        signedIn: Bool, sources: [Source], holding notes: [Note], routes: [String: String] = [:],
        forums: ForumSessions = ForumSessions(), onRequest: (@Sendable (String) async -> Void)? = nil
    ) async throws -> (ShellSession, ReachLog) {
        let work = SourceWork()
        let log = ReachLog(work: work)
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(host: m, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: MastodonOAuth.scopes(writing: true)))
        }
        var routes = routes
        routes["/api/v2/instance"] = #"{"domain":"m.example","version":"4.6.6","configuration":{"statuses":{"max_characters":500}}}"#
        let plain = ReachDoor(door: "plain", log: log, routes: routes, onRequest: onRequest)
        let signed = ReachDoor(door: "signed", log: log, routes: routes)
        let sessions = MastodonSessions(tokens: tokens, sender: signed)
        sessions.work = work
        let session = ShellSession(
            http: plain, store: ItemStore(sources: sources, notes: notes), forums: forums, mastodon: sessions,
            posts: ForumPosts(http: plain), blogs: ForumBlogs(http: plain, through: forums)
        )
        session.work = work
        session.posts.work = work
        session.blogs.work = work
        session.mastodon.refresh()
        await session.reloadFromStore()
        _ = log.take()
        return (session, log)
    }

    private static func only(_ host: String, _ lines: [String]) -> [String] {
        lines.filter { $0.contains(" \(host)/") }
    }

    // MARK: - Reading older

    @Test("Reading older on a Mastodon: its public timeline through the plain door under its own name; Home and a list through the signed door, each under the name the reader knows it by")
    func olderOnAMastodon() async throws {
        let held = [Self.post(5, .public), Self.post(6, .home), Self.post(7, .list(id: "7"))]
        let (session, log) = try await Self.shell(signedIn: true, sources: [Self.mastodon], holding: held)
        await session.reload.more(.all, in: session)
        #expect(Set(log.take()) == [
            "plain no token m.example/api/v1/timelines/public | timeline Public",
            "signed token m.example/api/v1/timelines/home | timeline Home",
            "signed token m.example/api/v1/timelines/list/7 | timeline Friends",
        ])

        let (unsigned, unsignedLog) = try await Self.shell(signedIn: false, sources: [Self.mastodon], holding: held)
        await unsigned.reload.more(.all, in: unsigned)
        #expect(unsignedLog.take() == ["plain no token m.example/api/v1/timelines/public | timeline Public"], "Home and a list are nobody's to read on unsigned")
    }

    @Test("What is rising, read further down, is asked through the plain door as Trends, signed in or not")
    func risingFurtherDown() async throws {
        for signedIn in [true, false] {
            let (session, log) = try await Self.shell(
                signedIn: signedIn, sources: [Source(host: Self.m, kind: .mastodon)], holding: [],
                routes: ["/api/v1/trends/statuses": Self.statuses(1...20)]
            )
            await session.reload.timeline(.trends, in: session)
            _ = log.take()
            await session.reload.more(.trends, in: session)
            #expect(log.take() == ["plain no token m.example/api/v1/trends/statuses | timeline Trends"])
        }
    }

    @Test("A forum's next page: a Discuz! board under the board's name, a Discuz! front page and a Discourse's under none, all through the plain door where nobody is signed in to the forum")
    func aForumsNextPage() async throws {
        let boarded = Source(host: Self.z, kind: .discuz, boards: [BoardSubscription(fid: 42, name: "Dev")])
        let (session, log) = try await Self.shell(
            signedIn: false, sources: [boarded, Self.discourse],
            holding: [Self.thread(9, on: Self.z, kind: .discuz, board: "42"), Self.thread(3, on: Self.d, kind: .discourse)]
        )
        await session.reload.more(.all, in: session)
        let lines = log.take()
        #expect(Self.only(Self.z, lines) == ["plain no token z.example/forum.php | timeline Dev"])
        #expect(Set(Self.only(Self.d, lines)) == [
            "plain no token d.example/latest.json | timeline -", "plain no token d.example/site.json | timeline -",
        ])

        let (front, frontLog) = try await Self.shell(
            signedIn: false, sources: [Source(host: Self.z, kind: .discuz)], holding: [Self.thread(9, on: Self.z, kind: .discuz)]
        )
        await front.reload.more(.all, in: front)
        #expect(frontLog.take() == ["plain no token z.example/forum.php | timeline -"])
    }

    // MARK: - Reading down a gap

    @Test("A place where posts may be missing is read down through the plain door for the public timeline and the signed door for Home and a list, each under its own name; signed out, Home's is not asked at all")
    func readingDown() async throws {
        // In each timeline, a post with the mark and one held below it.
        let held = [Self.post(31, .public, gap: true), Self.post(41, .home, gap: true), Self.post(51, .list(id: "7"), gap: true)]
            + [Self.post(11, .public), Self.post(12, .home), Self.post(13, .list(id: "7"))]
        let (session, log) = try await Self.shell(signedIn: true, sources: [Self.mastodon], holding: held)
        await session.reload.readDown(Stretch(host: Self.m, category: .public), below: held[0].key, in: session)
        #expect(log.take() == ["plain no token m.example/api/v1/timelines/public | timeline Public"])
        await session.reload.readDown(Stretch(host: Self.m, category: .home), below: held[1].key, in: session)
        #expect(log.take() == ["signed token m.example/api/v1/timelines/home | timeline Home"])
        await session.reload.readDown(Stretch(host: Self.m, category: .list(id: "7")), below: held[2].key, in: session)
        #expect(log.take() == ["signed token m.example/api/v1/timelines/list/7 | timeline Friends"])

        let (unsigned, unsignedLog) = try await Self.shell(signedIn: false, sources: [Self.mastodon], holding: held)
        await unsigned.reload.readDown(Stretch(host: Self.m, category: .home), below: held[1].key, in: unsigned)
        #expect(unsignedLog.take().isEmpty)
    }

    // MARK: - A forum's blog, and its reload

    @Test("A forum's ranked blog, opened, is read as a forum post through the plain door where nobody is signed in to that forum")
    func aBlog() async throws {
        let source = Source(host: Self.z, kind: .discuz)
        let blog = Note(
            id: DiscuzBlogRow.id(host: Self.z, blog: 500), source: source, author: "kim", handle: "kim@\(Self.z)", body: "an excerpt",
            title: "a blog", postedAt: Self.origin, categories: [.trends],
            url: URL(string: "https://\(Self.z)/home.php?mod=space&uid=21&do=blog&id=500")
        )
        let (session, log) = try await Self.shell(signedIn: false, sources: [source], holding: [blog])
        let row = try #require(session.held(blog.key.rowID))
        await session.blogs.open(row)
        #expect(log.take() == ["plain no token z.example/home.php | forumPost -"])
    }

    @Test("A forum's reload is read through the transport it began with: a sign-in to that forum that lands between two of its boards changes nothing for the rest of that reload — every board and both ranking lists go through the one door, and no browser is started for it")
    func oneTransportForAReload() async throws {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let source = Source(host: Self.z, kind: .discuz, boards: [BoardSubscription(fid: 42, name: "Dev"), BoardSubscription(fid: 43, name: "Chat")])
        // As the first board's page is asked for, the reader's sign-in to this forum lands.
        let (session, log) = try await Self.shell(
            signedIn: false, sources: [source], holding: [], forums: forums,
            onRequest: { path in
                if path.contains("fid=42") { await forums.plantSession(host: Self.z) }
            }
        )
        #expect(!forums.readsThroughEngine(host: Self.z), "the premise: not signed in as the reload begins")
        session.reload.deadline = .seconds(2)
        await session.reload.timeline(.all, in: session)
        #expect(forums.readsThroughEngine(host: Self.z), "the premise: signed in by the time the second board is read")
        #expect(log.take() == [
            "plain no token z.example/forum.php | timeline Dev", "plain no token z.example/forum.php | timeline Chat",
            "plain no token z.example/misc.php | timeline Trends", "plain no token z.example/misc.php | timeline Trends",
        ])
        #expect(!forums.hasEngine(host: Self.z), "nothing of this reload went to the forum's browser")
    }
}
