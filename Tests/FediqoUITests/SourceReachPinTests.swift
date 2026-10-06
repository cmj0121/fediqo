import Foundation
import os
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Every request a pin's session made, as it went out: which door it went through — the plain
/// client or the signed-in one — whether it carried a token, its path, and what the run's list
/// of requests showed for its host at that moment (purpose, and the name beside it).
final class ReachLog: @unchecked Sendable {
    private let lines = OSAllocatedUnfairLock(uncheckedState: [String]())
    let work: SourceWork

    init(work: SourceWork) { self.work = work }

    func note(_ door: String, _ request: URLRequest) {
        let host = request.url?.host() ?? ""
        let running = Set(work.now.values.filter { $0.host == host }
            .map { "\($0.purpose.rawValue) \($0.name?.text(language: .english) ?? "-")" }).sorted().joined(separator: " + ")
        let token = request.value(forHTTPHeaderField: "Authorization") == nil ? "no token" : "token"
        let line = "\(door) \(token) \(host)\(request.url?.path ?? "") | \(running)"
        lines.withLockUnchecked { $0.append(line) }
    }

    /// What was noted since the last take, in the order it went out.
    func take() -> [String] {
        lines.withLockUnchecked { noted in
            defer { noted = [] }
            return noted
        }
    }
}

/// A client and a sender that note each request and answer from `routes` by path — an empty
/// list where a path has none, which every listing read takes for "nothing there".
struct ReachDoor: HTTPClient, HTTPSender {
    let door: String
    let log: ReachLog
    var routes: [String: String] = [:]
    /// A path that answers only after three seconds, unless whoever asked gives up first: for
    /// seeing which deadline ends a read. Slow and not silent, so a read bounded by the wrong
    /// deadline is a pin that fails, not a run that hangs.
    var hanging: String?
    /// Told each path as its request goes out, before it is answered: for a pin that changes
    /// something between two requests of one read.
    var onRequest: (@Sendable (String) async -> Void)?

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.note(door, request)
        let url = request.url!
        await onRequest?(url.path + (url.query.map { "?" + $0 } ?? ""))
        var body = routes[url.path] ?? "[]"
        if let hanging, url.path == hanging {
            try await Task.sleep(for: .seconds(3))
            body = url.path.hasSuffix("/context") ? #"{"ancestors":[],"descendants":[\#(SourceReachPinTests.late)]}"# : "[\(SourceReachPinTests.late)]"
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// #299: each source is reached from one place — and reached exactly as it was. For every way
/// the app speaks to a source, what is pinned is what went out: through which door (plain or
/// signed in), with a token or without, and under which purpose and name in the requests of
/// this run; and which deadline ends a read that never answers.
///
/// **Written against the code while each call site still built its own client**, and unchanged
/// since: so gathering the building into one place is shown here to have moved nothing.
@MainActor
@Suite("Each source is reached as it was")
struct SourceReachPinTests {
    private static let m = "m.example"
    private static let z = "z.example"
    private static let d = "d.example"
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private static let mastodon = Source(host: m, kind: .mastodon, lists: [ListSubscription(id: "7", name: "Friends")])
    private static let discuz = Source(host: z, kind: .discuz, boards: [BoardSubscription(fid: 42, name: "Dev")])
    private static let discourse = Source(host: d, kind: .discourse)

    private static func post(_ id: String, _ categories: Set<FediqoCore.Category> = [.public], answering: String? = nil) -> Note {
        Note(
            id: "https://\(m)/users/ada/statuses/\(id)", source: Source(host: m, kind: .mastodon), author: "Ada",
            handle: "@ada@\(m)", body: "post \(id)", postedAt: origin, categories: categories, audience: .everyone,
            statusID: id, refs: answering.map { [.answers($0)] } ?? []
        )
    }

    /// What a slow path answers with, if anybody is still waiting.
    nonisolated static let late = #"{"id":"77","uri":"https://m.example/users/ada/statuses/77","in_reply_to_id":"9","created_at":"2026-01-01T00:00:00.000Z","content":"<p>late</p>","visibility":"public","account":{"username":"ada","acct":"ada","display_name":"Ada"}}"#
    private static let status = #"{"id":"50","uri":"https://m.example/users/ada/statuses/50","created_at":"2026-01-01T00:00:00.000Z","content":"<p>x</p>","visibility":"public","account":{"username":"ada","acct":"ada","display_name":"Ada"}}"#
    private static let routes: [String: String] = [
        "/api/v1/statuses/9/context": #"{"ancestors":[],"descendants":[]}"#,
        "/api/v2/search": #"{"statuses":[]}"#,
        "/api/v2/instance": #"{"domain":"m.example","version":"4.6.6","configuration":{"statuses":{"max_characters":500}}}"#,
        "/api/v1/statuses": status, "/api/v1/statuses/9/favourite": status, "/api/v1/statuses/8": status,
        "/api/v1/accounts/verify_credentials": #"{"id":"1","username":"me","acct":"me"}"#,
    ]

    /// A session on a Mastodon, a Discuz! and a Discourse, signed in to the Mastodon or not,
    /// whose every request is noted.
    private static func shell(
        signedIn: Bool, holding notes: [Note] = [], hanging: String? = nil
    ) async throws -> (ShellSession, ReachLog) {
        let work = SourceWork()
        let log = ReachLog(work: work)
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(host: m, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: MastodonOAuth.scopes(writing: true)))
        }
        let plain = ReachDoor(door: "plain", log: log, routes: routes, hanging: hanging)
        let signed = ReachDoor(door: "signed", log: log, routes: routes, hanging: hanging)
        let sessions = MastodonSessions(tokens: tokens, sender: signed)
        sessions.work = work
        let store = ItemStore(sources: [mastodon, discuz, discourse], notes: notes)
        let session = ShellSession(http: plain, store: store, mastodon: sessions, posts: ForumPosts(http: plain))
        session.work = work
        session.posts.work = work
        session.blogs.work = work
        var limits = LoadLimits()
        limits.interval = 0
        limits.backoff = 0
        session.loads = LoadPacer(limits: limits, clock: StillClock())
        session.mastodon.refresh()
        await session.reloadFromStore()
        await session.refs.settled()
        _ = log.take()
        return (session, log)
    }

    private static func only(_ host: String, _ lines: [String]) -> [String] {
        lines.filter { $0.contains(" \(host)/") }
    }

    // MARK: - Reading

    @Test("A reload of a Mastodon signed in to: its public timeline and what is rising through the plain door with no token, each under its own name; its lists' names, Home and each list through the signed door, each timeline under the name the reader knows it by")
    func reloadSignedIn() async throws {
        let (session, log) = try await Self.shell(signedIn: true)
        await session.reload.timeline(.all, in: session)
        #expect(Set(Self.only(Self.m, log.take())) == [
            // What kind of server it is now, asked beside the read.
            "plain no token m.example/api/v2/instance | serverCheck -",
            "plain no token m.example/api/v1/timelines/public | timeline Public",
            "plain no token m.example/api/v1/trends/statuses | timeline Trends",
            "signed token m.example/api/v1/lists | lists -",
            "signed token m.example/api/v1/timelines/home | timeline Home",
            "signed token m.example/api/v1/timelines/list/7 | timeline Friends",
        ])
    }

    @Test("A reload of a Mastodon nobody is signed in to asks through the plain door alone; a Discuz! reads each board under the board's name and its ranking lists as Trends; a Discourse its front page under no name")
    func reloadUnsignedAndForums() async throws {
        let (session, log) = try await Self.shell(signedIn: false)
        await session.reload.timeline(.all, in: session)
        let lines = log.take()
        #expect(Set(Self.only(Self.m, lines)) == [
            "plain no token m.example/api/v2/instance | serverCheck -",
            "plain no token m.example/api/v1/timelines/public | timeline Public",
            "plain no token m.example/api/v1/trends/statuses | timeline Trends",
        ])
        #expect(Self.only(Self.z, lines) == [
            "plain no token z.example/forum.php | timeline Dev",
            "plain no token z.example/misc.php | timeline Trends", "plain no token z.example/misc.php | timeline Trends",
        ])
        #expect(Set(Self.only(Self.d, lines)) == [
            "plain no token d.example/latest.json | timeline -", "plain no token d.example/site.json | timeline -",
        ])
    }

    @Test("Right after a sign-in, Home and the lists are read through the signed door under no name; choosing lists asks for them the same way")
    func readAsYou() async throws {
        let (session, log) = try await Self.shell(signedIn: true)
        await session.readAsYou(host: Self.m)
        #expect(Self.only(Self.m, log.take()) == [
            "signed token m.example/api/v1/lists | timeline -",
            "signed token m.example/api/v1/timelines/home | timeline -",
            "signed token m.example/api/v1/timelines/list/7 | timeline -",
        ])
    }

    // MARK: - A tag, a search

    @Test("A tag is read through the signed door where somebody is signed in and the plain one where nobody is, under the tag's own name; a Discourse's through the plain door; a search only through the signed door, as a search")
    func tagAndSearch() async throws {
        let tag = try #require(PostTag("#cats"))
        let (signed, signedLog) = try await Self.shell(signedIn: true)
        await signed.reload.tag(tag, timeline: .all, in: signed)
        let lines = signedLog.take()
        #expect(Self.only(Self.m, lines) == ["signed token m.example/api/v1/timelines/tag/cats | timeline #cats"])
        #expect(Set(Self.only(Self.d, lines)) == [
            "plain no token d.example/tag/cats.json | timeline #cats", "plain no token d.example/site.json | timeline #cats",
        ])
        #expect(Self.only(Self.z, lines).isEmpty)
        await signed.reload.search("cats", timeline: .all, in: signed)
        #expect(signedLog.take() == ["signed token m.example/api/v2/search | search -"])

        let (unsigned, unsignedLog) = try await Self.shell(signedIn: false)
        await unsigned.reload.tag(tag, timeline: .all, in: unsigned)
        #expect(Self.only(Self.m, unsignedLog.take()) == ["plain no token m.example/api/v1/timelines/tag/cats | timeline #cats"])
        await unsigned.reload.search("cats", timeline: .all, in: unsigned)
        #expect(unsignedLog.take().isEmpty, "a search is never asked unsigned")
    }

    // MARK: - Opening, loading, acting

    @Test("A thread is read through the signed door where somebody is signed in and the plain one where nobody is, as a conversation; what an item refers to is loaded the same way, as a reference — and never through the plain door in a signed-in reader's place")
    func openingAndLoading() async throws {
        for signedIn in [true, false] {
            let door = signedIn ? "signed token" : "plain no token"
            let (session, log) = try await Self.shell(signedIn: signedIn, holding: [Self.post("9")])
            let row = try #require(session.held(Self.post("9").key.rowID))
            await session.conversations.open(row, in: session)
            #expect(log.take() == ["\(door) m.example/api/v1/statuses/9/context | conversation -"])

            await session.store.ingest([Self.post("10", signedIn ? [.home] : [.public], answering: "8")], ifSourceHere: Self.m)
            await session.reloadFromStore()
            await session.refs.settled()
            #expect(log.take() == ["\(door) m.example/api/v1/statuses/8 | reference -"])
        }
        // Read as the reader, then signed out: what Home left owing is not asked for at all.
        let (session, log) = try await Self.shell(signedIn: true, holding: [Self.post("9")])
        await session.store.ingest([Self.post("10", [.home], answering: "8")], ifSourceHere: Self.m)
        await session.reloadFromStore()
        await session.refs.settled()
        #expect(log.take() == ["signed token m.example/api/v1/statuses/8 | reference -"])
        await session.signOut(host: Self.m)
        _ = log.take()
        await session.store.ingest([Self.post("12", [.public], answering: "11")], ifSourceHere: Self.m)
        await session.reloadFromStore()
        await session.refs.settled()
        #expect(log.take().isEmpty, "nothing is read unsigned in their place")
    }

    @Test("An act and a post go through the signed door, as writing; how long a post may be is asked through the plain door, as a check of the server")
    func actingAndTheLimit() async throws {
        let (session, log) = try await Self.shell(signedIn: true, holding: [Self.post("9")])
        let row = try #require(session.held(Self.post("9").key.rowID))
        await session.toggle(.favourite, on: row)
        #expect(log.take() == ["signed token m.example/api/v1/statuses/9/favourite | write -"])
        await session.refreshPostLimit(of: Self.m)
        #expect(log.take() == ["plain no token m.example/api/v2/instance | serverCheck -"])
    }

    // MARK: - A forum's own pages

    @Test("A forum topic's opening post is read as a forum post and its replies as replies, through the plain door where the reader is not signed in to that forum")
    func aForumsPages() async throws {
        let (session, log) = try await Self.shell(signedIn: false)
        let ref = ForumThreadRef(host: Self.z, tid: 5)
        await session.posts.fetch(ref)
        #expect(log.take().map { $0.components(separatedBy: " | ").last ?? "" } == ["forumPost -"])
        await session.posts.fetchReplies(ref)
        let replies = log.take()
        #expect(replies.map { $0.components(separatedBy: " | ").last ?? "" } == ["forumReplies -"])
        #expect(replies.allSatisfy { $0.hasPrefix("plain no token z.example/") })
    }

    @Test("A forum's sign-in goes to that forum and to no other: a read of the forum signed in to goes through its own browser, and a read of any other host through the plain client, starting no browser for it")
    func aForumsSignInIsItsOwn() async {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let plain = FixtureHTTP()
        let session = ShellSession(http: plain, forums: forums)
        session.sources = [Source(host: "cookie.example", kind: .discuz), Source(host: "other.example", kind: .discuz), Self.mastodon]
        await forums.plantSession(host: "cookie.example")
        #expect(session.reload.transport("cookie.example", in: session) is ForumJoinTransport)
        for host in ["other.example", Self.m, Self.d] {
            #expect((session.reload.transport(host, in: session) as? FixtureHTTP) === plain, "\(host)")
            #expect(!forums.hasEngine(host: host), "\(host): a browser was started for it")
        }
    }

    // MARK: - Which deadline

    @Test("A reload's read that never answers ends by the reload's deadline, and a thread's by the thread's own: each with the other set to an hour", .timeLimit(.minutes(1)))
    func whichDeadline() async throws {
        let (session, log) = try await Self.shell(signedIn: false, holding: [Self.post("9")], hanging: "/api/v1/timelines/public")
        session.reload.deadline = .milliseconds(40)
        session.conversations.deadline = .seconds(3_600)
        await session.reload.timeline(.all, in: session)
        #expect(Self.only(Self.m, log.take()).contains("plain no token m.example/api/v1/timelines/public | timeline Public"))
        #expect(!session.notes.contains { $0.statusID == "77" }, "the read was given up on by the reload's deadline, not waited for")

        let (opening, _) = try await Self.shell(signedIn: false, holding: [Self.post("9")], hanging: "/api/v1/statuses/9/context")
        opening.reload.deadline = .seconds(3_600)
        opening.conversations.deadline = .milliseconds(40)
        let row = try #require(opening.held(Self.post("9").key.rowID))
        await opening.conversations.open(row, in: opening)
        #expect(opening.conversations.standing(of: row.id) == .absent(.unreachable), "given up on by the thread's own deadline")
        #expect(opening.conversations.conversation(around: row).descendants.isEmpty)
    }
}
