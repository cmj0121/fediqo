import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #318, the list: the hashtags the reader follows at a source — where it is reached from and
/// how that way stands for each sign-in, what is asked for it and when, how it reads on to its
/// end, and how a row unfollows through the hashtag page's own press.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made the ask where a check can name it: a held ask is let go by the check, and by a guard
/// when the run has gone still; every deadline is on a clock nobody turns.
@MainActor
@Suite("The hashtags followed at a source, as a list", .serialized, .watched)
struct FollowedTagsTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let seeing = "\(reads) read:follows"
    private static let follows = "\(seeing) write:follows"
    private static let page = FollowedTags(host: host)
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let first = "/api/v1/followed_tags?limit=100"
    private static func after(_ id: Int, limit: Int = 100) -> String { "/api/v1/followed_tags?limit=\(limit)&max_id=\(id)" }
    private static func unfollow(_ name: String) -> String { "/api/v1/tags/\(name)/unfollow" }
    private static func follow(_ name: String) -> String { "/api/v1/tags/\(name)/follow" }
    private static func tag(_ name: String) -> String { "/api/v1/tags/\(name)" }
    private static let lookup = "/api/v1/accounts/lookup?acct=me"
    private static let statuses = "/api/v1/accounts/7/statuses"
    /// The reader's own page as the source says it: who they are, and a post of theirs.
    private static let own: [String: PageServer.Answer] = [
        lookup: PageServer.Answer(body: #"{"id":"7","acct":"me","display_name":"Me","note":"","followers_count":1,"following_count":1,"statuses_count":1}"#),
        statuses: PageServer.Answer(
            body: #"[{"id":"9","uri":"https://m.example/users/me/statuses/9","created_at":"2026-10-01T00:00:00.000Z","content":"<p>post</p>","visibility":"public","account":{"acct":"me","display_name":"Me"}}]"#
        ),
    ]
    private static var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI/FediqoRootView.swift")
    }
    /// The five hashtags a real server listed two at a time (`MastodonTagFollowCaptures`, which
    /// the Core's own checks read byte for byte): the one followed last first.
    private static let names = ["fediqo318p5", "fediqo318p4", "fediqo318p3", "fediqo318p2", "fediqo318p1"]
    private static let down = PageServer.Answer(body: "<html>", status: 500)

    /// A stretch made up here in the shape that server's have: the hashtags, and a `Link` whose
    /// next is named by the id of a follow, which no row carries.
    private static func stretch(_ names: [String], next: Int? = nil) -> PageServer.Answer {
        PageServer.Answer(
            body: "[" + names.map { #"{"id":"1","name":"\#($0)","following":true,"featuring":false}"# }.joined(separator: ",") + "]",
            link: next.map {
                #"<https://m.example/api/v1/followed_tags?limit=2&max_id=\#($0)>; rel="next", <https://m.example/api/v1/followed_tags?limit=2&since_id=13>; rel="prev""#
            } ?? #"<https://m.example/api/v1/followed_tags?limit=2&since_id=9>; rel="prev""#
        )
    }

    /// The three stretches of that sitting, each next as the server named it: 12, then 10, then none.
    private static func captured(_ at: Int) -> PageServer.Answer {
        [stretch(Array(names[0 ..< 2]), next: 12), stretch(Array(names[2 ..< 4]), next: 10), stretch([names[4]])][at]
    }

    private static func said(_ name: String, _ following: Bool) -> PageServer.Answer {
        PageServer.Answer(body: #"{"id":"2","name":"\#(name)","history":[],"following":\#(following),"featuring":false}"#)
    }

    private static let whole: [String: PageServer.Answer] = [first: captured(0), after(12): captured(1), after(10): captured(2)]

    private func session(
        _ routes: [String: PageServer.Answer], tokens: any MastodonTokenStore = MemoryMastodonTokens()
    ) async -> (ShellSession, PageServer, SourceWork) {
        let me = PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#)
        let server = PageServer(routes.merging([Self.who: me]) { one, _ in one })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    private func signOut(_ session: ShellSession) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        session.mastodon.refresh()
    }

    private func signIn(
        _ session: ShellSession, as access: String = "tok", holding scopes: String = FollowedTagsTests.follows,
        asked: String? = nil
    ) throws {
        try signOut(session)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: access, clientID: "c", clientSecret: "s", scopes: scopes, asked: asked ?? scopes
        ))
        session.mastodon.refresh()
    }

    /// What the server was asked, but for who the reader is.
    private func asked(_ server: PageServer) async -> [String] {
        await server.asked.filter { $0 != Self.who }
    }

    private func shown(_ list: ShellFollowedTags, in session: ShellSession) -> [String] {
        list.said(of: Self.page, in: session)?.rows.map(\.tag.name) ?? []
    }

    private func row(_ name: String, of list: ShellFollowedTags, in session: ShellSession) -> FollowedTagRow? {
        list.said(of: Self.page, in: session)?.rows.first { $0.tag.name == name }
    }

    // MARK: - Where it is reached from

    @Test("The way to the list stands on the reader's own page at a Mastodon source, and only there: open where the sign-in holds the word that sees who they follow, the lock of how the sign-in stands where it does not — whose press raises the question — and nothing is asked of the server to draw either; with no sign-in, on somebody else's page and at a forum there is none")
    func theWayStandsOnTheReadersOwnPage() async throws {
        let (session, server, work) = await session(Self.whole)
        let list = ShellPersonPages().followed
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        let other = try #require(DummyPerson(handle: "@ada@m.example", host: Self.host))
        #expect(list.entry(on: me, in: session) == nil, "nobody signed in")

        try signIn(session)
        await session.mastodon.learnWho(host: Self.host)
        let open = try #require(list.entry(on: me, in: session))
        #expect(open == FollowedTagsEntry(page: Self.page, locked: nil))
        #expect(open.words(language: .english) == "Hashtags you follow")
        #expect(open.words(language: .taiwanese) == "你追蹤的主題標籤")
        #expect(list.entry(on: other, in: session) == nil, "somebody else's page has none")

        // The word that sees is enough to read the list.
        try signIn(session, holding: Self.seeing)
        await session.mastodon.learnWho(host: Self.host)
        #expect(list.entry(on: me, in: session)?.locked == nil)

        try signIn(session, holding: Self.reads)
        await session.mastodon.learnWho(host: Self.host)
        let locked = try #require(list.entry(on: me, in: session))
        #expect(locked.locked == PartWords.Place(kind: .unasked, key: "part.follows.unasked"))
        #expect(locked.words(language: .english) == "This sign-in was not asked how you stand to people. Update permission")
        #expect(locked.asks)
        // Opened all the same — by a step taken before the sign-in stood so — nothing is asked.
        #expect(list.said(of: Self.page, in: session) == nil)
        await list.opened(Self.page, in: session)
        await list.again(Self.page, in: session)
        await list.readOn(Self.page, in: session)
        #expect(await asked(server).isEmpty, "nothing is asked of the server to draw a lock, or behind one")
        #expect(work.record.allSatisfy { $0.purpose == .signInCheck })
        // Its press raises the question about follows at that source, and sends nothing.
        #expect(session.askFor([.follows], host: Self.host))
        #expect(session.partAsks.open?.ticked == [.follows])
        #expect(await asked(server).isEmpty)

        // The word that changes alone does not see: the lock names the half that is lacking.
        try signIn(session, holding: "\(Self.reads) write:follows")
        await session.mastodon.learnWho(host: Self.host)
        #expect(list.entry(on: me, in: session)?.locked == PartWords.Place(kind: .partly, key: "part.follows.partly.seeing"))
        // Asked for and not given: said, and not a press.
        try signIn(session, holding: Self.reads, asked: Self.follows)
        await session.mastodon.learnWho(host: Self.host)
        #expect(list.entry(on: me, in: session)?.locked == PartWords.Place(kind: .none, key: "part.ask.none"))
        #expect(list.entry(on: me, in: session)?.asks == false)

        // A forum has none, whatever is kept under its name.
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.forum.host, accessToken: "odd", clientID: "c", clientSecret: "s", scopes: Self.follows, asked: Self.follows
        ))
        session.mastodon.refresh()
        let author = try #require(DummyPerson(handle: "@me@forum.example", host: Self.forum.host))
        #expect(list.entry(on: author, in: session) == nil)
        let forums = FollowedTags(host: Self.forum.host)
        #expect(list.said(of: forums, in: session) == nil)
        await list.opened(forums, in: session)
        #expect(await asked(server).isEmpty, "a forum is asked nothing")
    }

    // MARK: - Reading on

    @Test("Opening the list asks its source for one stretch, as the reader, of that host, listed in the run's record under the purpose a hashtag's follow has; the foot's press reads the next by the place the source's Link named, a stretch a press, to the end — and then says the end; nothing is asked past it, or by opening the list again")
    func itReadsOnToItsEnd() async throws {
        let (session, server, work) = await session(Self.whole)
        try signIn(session)
        let list = ShellPersonPages().followed
        #expect(list.said(of: Self.page, in: session)?.reading == .asking, "before anything answered")
        #expect(list.ask(of: Self.page, in: session).asking == nil, "nothing on the wire before it opens")

        await list.opened(Self.page, in: session)
        #expect(await asked(server) == [Self.first])
        #expect(await server.bearers == ["Bearer tok"])
        #expect(work.record.map(\.purpose) == [.followedTags])
        #expect(work.record.allSatisfy { $0.reached == Self.host && $0.source == Self.host })
        #expect(shown(list, in: session) == Array(Self.names.prefix(2)), "the one followed last first")
        var said = try #require(list.said(of: Self.page, in: session))
        #expect(said.reading == .said && said.foot == .more && list.ask(of: Self.page, in: session) == PageAsking())
        #expect(said.rows.count == 2)
        #expect(said.footWords(.more, language: .english) == "More hashtags can be read. Press here to read them.")

        await list.opened(Self.page, in: session)
        #expect(await asked(server).count == 1, "answered: not asked again by being opened")

        await list.readOn(Self.page, in: session)
        #expect(await asked(server) == [Self.first, Self.after(12)])
        #expect(shown(list, in: session) == Array(Self.names.prefix(4)))
        #expect(list.said(of: Self.page, in: session)?.foot == .more)

        await list.readOn(Self.page, in: session)
        said = try #require(list.said(of: Self.page, in: session))
        #expect(said.rows.map(\.tag.name) == Self.names)
        #expect(said.foot == .end)
        #expect(said.footWords(.end, language: .english) == "No more hashtags: m.example has sent all it gives.")
        #expect(said.rows.count == 5)
        #expect(said.rows.allSatisfy { $0.standing == .followed && $0.words() == nil })
        #expect(list.walked(Self.page, in: session) == said.rows.map(\.id))

        await list.readOn(Self.page, in: session)
        #expect(await asked(server) == [Self.first, Self.after(12), Self.after(10)], "nothing is asked past the end")
        #expect(await server.bearers.allSatisfy { $0 == "Bearer tok" })
        #expect(work.record.map(\.purpose) == [.followedTags, .followedTags, .followedTags])
        #expect(session.notes.isEmpty, "nothing is held")
    }

    @Test("A source that lists none is said in a sentence about the source; a list that could not be asked for says so in the page's toast, and `r` asks from the top; a stretch that does not come is said in the toast and changes nothing drawn; a source that names the same next twice ends the list where it is and says so")
    func theStatesOfThePage() async throws {
        let (session, server, _) = await session([Self.first: Self.stretch([])])
        try signIn(session)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)
        var said = try #require(list.said(of: Self.page, in: session))
        #expect(said.rows.isEmpty && said.foot == nil)
        #expect(said.nothing(language: .english) == "m.example lists no hashtags you follow.")

        await server.answer(Self.first, Self.down)
        await list.again(Self.page, in: session)
        said = try #require(list.said(of: Self.page, in: session))
        #expect(said.reading == .said, "what it said before stands")
        #expect(list.ask(of: Self.page, in: session).failed == [Self.host], "and the toast says the miss")

        let (other, down, _) = await self.session([Self.first: Self.down])
        try signIn(other)
        let failed = ShellPersonPages().followed
        await failed.opened(Self.page, in: other)
        said = try #require(failed.said(of: Self.page, in: other))
        #expect(said.reading == .failed && said.rows.isEmpty && said.nothing() == nil)
        #expect(failed.ask(of: Self.page, in: other).failed == [Self.host])
        await failed.opened(Self.page, in: other)
        #expect(await asked(down).count == 1, "a failure is not asked again by being drawn")
        await down.answer(Self.first, Self.stretch(["a", "b"], next: 5))
        await failed.again(Self.page, in: other)
        #expect(shown(failed, in: other) == ["a", "b"])

        // The next stretch does not come.
        await failed.readOn(Self.page, in: other)
        said = try #require(failed.said(of: Self.page, in: other))
        #expect(said.foot == .more && said.rows.map(\.tag.name) == ["a", "b"], "the foot reads on again")
        #expect(failed.ask(of: Self.page, in: other).failed == [Self.host])
        // It names the place it was asked by as its next: not paging.
        await down.answer(Self.after(5), Self.stretch(["c"], next: 5))
        await failed.readOn(Self.page, in: other)
        said = try #require(failed.said(of: Self.page, in: other))
        #expect(said.foot == .stopped && said.rows.map(\.tag.name) == ["a", "b"])
        #expect(said.footWords(.stopped, language: .english) == "m.example stopped handing hashtags on in order. The list ends here.")
        let before = await asked(down).count
        await failed.readOn(Self.page, in: other)
        #expect(await asked(down).count == before, "a list that stopped is not read on")
    }

    @Test("Stop on the hashtags followed calls the ask from the top off: the toast says the wait, then that the reload stopped — never a failure — what the list held stands, what comes late lands nowhere, and asking again says nothing of the stop")
    func stopCallsTheListOff() async throws {
        let (session, server, _) = await session([Self.first: Self.stretch(["a", "b"])])
        try signIn(session)
        let list = ShellPersonPages().followed
        #expect(!list.stop(Self.page), "nothing on the wire: nothing stopped")
        await list.opened(Self.page, in: session)
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let firstGuard = watching("the ask of \(Self.first), held at its server") { await server.release(Self.first) }
        defer { firstGuard.cancel() }
        await server.answer(Self.first, Self.stretch(["c"]))
        let pull = Task { await list.again(Self.page, in: session) }
        await server.arrival(of: Self.first, times: 2, by: pull)
        #expect(list.ask(of: Self.page, in: session, language: .english) == PageAsking(asking: "Asking m.example for the hashtags you follow…", stoppable: true))

        #expect(list.stop(Self.page))
        #expect(list.ask(of: Self.page, in: session) == PageAsking(stopped: true))
        #expect(shown(list, in: session) == ["a", "b"] && list.said(of: Self.page, in: session)?.asking == false)
        await server.release(Self.first)
        await pull.value
        #expect(shown(list, in: session) == ["a", "b"], "what came late landed nowhere")

        await list.again(Self.page, in: session)
        #expect(shown(list, in: session) == ["c"] && list.ask(of: Self.page, in: session) == PageAsking())
    }

    @Test("No more is read than the most a list is read to: reached, the foot says so and is no press, and nothing more is asked")
    func itIsReadOnlySoFar() async throws {
        let (session, server, _) = await session([
            "/api/v1/followed_tags?limit=2": Self.stretch(["a", "b"], next: 9),
            Self.after(9, limit: 2): Self.stretch(["c", "d"], next: 7), Self.after(7, limit: 2): Self.stretch(["e"]),
        ])
        try signIn(session)
        let list = ShellPersonPages().followed
        list.stretch = 2
        list.most = 4
        await list.opened(Self.page, in: session)
        #expect(list.said(of: Self.page, in: session)?.foot == .more)
        await list.readOn(Self.page, in: session)
        let said = try #require(list.said(of: Self.page, in: session))
        #expect(said.rows.count == 4 && said.foot == .farthest && !FollowedTagsSaid.Foot.farthest.presses)
        #expect(said.footWords(.farthest, language: .english) == "Fediqo reads the first 4 hashtags you follow. m.example may list more.")
        await list.readOn(Self.page, in: session)
        #expect(await asked(server).count == 2, "the cap is not read past")
        #expect(ShellFollowedTags.most == 1_000 && MastodonTagFollows.stretch == 100)
    }

    @Test("A stretch that runs past the most a list is read to is shown only as far as that: no more rows than the most, the foot says so and is no press — where the source named a next, where that stretch was its last, and where its first stretch alone is longer")
    func aStretchPastTheMostIsCut() async throws {
        let (session, server, _) = await session([
            "/api/v1/followed_tags?limit=2": Self.stretch(["a", "b"], next: 9),
            Self.after(9, limit: 2): Self.stretch(["c", "d"], next: 7), Self.after(7, limit: 2): Self.stretch(["e"]),
        ])
        try signIn(session)
        let list = ShellPersonPages().followed
        list.stretch = 2
        list.most = 3
        await list.opened(Self.page, in: session)
        #expect(list.said(of: Self.page, in: session)?.foot == .more)
        await list.readOn(Self.page, in: session)
        var said = try #require(list.said(of: Self.page, in: session))
        #expect(said.rows.map(\.tag.name) == ["a", "b", "c"])
        #expect(said.foot == .farthest)
        #expect(said.rows.count == 3)
        #expect(said.footWords(.farthest, language: .english) == "Fediqo reads the first 3 hashtags you follow. m.example may list more.")
        #expect(list.walked(Self.page, in: session).count == 3)
        await list.readOn(Self.page, in: session)
        #expect(await asked(server).count == 2, "the cap is not read past")

        // The stretch that ran past it was the source's last: what was left out is still not said to be all.
        await server.answer(Self.after(9, limit: 2), Self.stretch(["c", "d"]))
        await list.again(Self.page, in: session)
        await list.readOn(Self.page, in: session)
        said = try #require(list.said(of: Self.page, in: session))
        #expect(said.rows.count == 3)
        #expect(said.foot == .farthest)

        // A source that sends more than it was asked for, in its first stretch.
        list.most = 1
        await list.again(Self.page, in: session)
        said = try #require(list.said(of: Self.page, in: session))
        #expect(said.rows.map(\.tag.name) == ["a"])
        #expect(said.foot == .farthest)
    }

    @Test("A next that names another host or another path is not followed there: only the place it names is taken, and the next stretch is asked of the list's own address at the sign-in's own host")
    func aNextElsewhereIsNotFollowed() async throws {
        let elsewhere = PageServer.Answer(
            body: #"[{"id":"1","name":"a","following":true}]"#,
            link: #"<https://elsewhere.example/api/v1/admin/accounts?max_id=5>; rel="next""#
        )
        let (session, server, work) = await session([Self.first: elsewhere, Self.after(5): Self.stretch(["b"])])
        try signIn(session)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)
        await list.readOn(Self.page, in: session)
        #expect(await asked(server) == [Self.first, Self.after(5)])
        #expect(work.record.allSatisfy { $0.reached == Self.host })
        #expect(shown(list, in: session) == ["a", "b"])
    }

    // MARK: - Unfollowing from a row

    @Test("A row's Unfollow goes through the hashtag page's own press: shown first as being done, one request out however often it is pressed, listed as a write; the row then stays, said as not followed with Follow offered, and the hashtag's own page opened after asks its source as it always does and says what that answers; Follow puts it back")
    func aRowUnfollows() async throws {
        let name = Self.names[1]
        let (session, server, work) = await session(Self.whole.merging([
            Self.unfollow(name): Self.said(name, false), Self.follow(name): Self.said(name, true),
            Self.tag(name): Self.said(name, false),
        ]) { one, _ in one })
        try signIn(session)
        let people = ShellPersonPages()
        let list = people.followed
        await list.opened(Self.page, in: session)
        let before = try #require(row(name, of: list, in: session))
        let said = try #require(list.said(of: Self.page, in: session))
        #expect(said.offer(for: before) == .act(false), "Unfollow")
        #expect(FollowedTagsSaid.name(of: .act(false), on: before, language: .english) == "Unfollow")

        await server.hold(Self.unfollow(name))
        let unfollowNameGuard = watching("the ask of \(Self.unfollow(name)), held at its server") { await server.release(Self.unfollow(name)) }
        defer { unfollowNameGuard.cancel() }
        let pressed = Task { await list.press(before.id, on: Self.page, in: session) }
        defer { Task { await server.release(Self.unfollow(name)) } }
        await server.arrival(of: Self.unfollow(name), by: pressed)
        let doing = try #require(row(name, of: list, in: session))
        #expect(doing.standing == .doing(false), "shown first")
        #expect(doing.words(language: .english) == "At m.example: unfollowing…")
        #expect(list.said(of: Self.page, in: session)?.offer(for: doing) == nil, "nothing is offered over a press that is out")
        await list.press(before.id, on: Self.page, in: session)
        await list.press(before.id, on: Self.page, in: session)
        #expect(await asked(server) == [Self.first, Self.unfollow(name)], "one request out")
        await server.release(Self.unfollow(name))
        await pressed.value

        let after = try #require(row(name, of: list, in: session))
        #expect(after.standing == .unfollowed && after.missed == nil)
        #expect(after.words(language: .english) == "At m.example: not followed.")
        #expect(shown(list, in: session) == Array(Self.names.prefix(2)), "the row stays where it stood")
        #expect(list.said(of: Self.page, in: session)?.offer(for: after) == .act(true), "Follow: the way back")
        #expect(list.said(of: Self.page, in: session)?.rows.count == 2)
        #expect(work.record.map(\.purpose) == [.followedTags, .write])

        // The hashtag's own page, opened after, asks as it always does: the list's word is no page's.
        let tag = after.tag
        await people.tags.opened(tag, in: session)
        #expect(await asked(server) == [Self.first, Self.unfollow(name), Self.tag(name)])
        #expect(people.tags.lines(of: tag, in: session).map(\.standing) == [.said(false)])
        // And left: the row is still as the act answered.
        people.tags.closed(tag)
        #expect(row(name, of: list, in: session)?.standing == .unfollowed)

        await list.press(after.id, on: Self.page, in: session)
        #expect(await asked(server) == [Self.first, Self.unfollow(name), Self.tag(name), Self.follow(name)])
        #expect(row(name, of: list, in: session)?.standing == .followed)
        #expect(await server.bearers.allSatisfy { $0 == "Bearer tok" })
    }

    @Test("What the list said of a hashtag is the list's word and no page's: it is let go when the list is left, and the hashtag's page coming in front after — a press answered, or one that did not arrive — asks its source once and says what the source says")
    func theListsWordIsNoPages() async throws {
        let name = Self.names[0], other = Self.names[1]
        let (session, server, _) = await session(Self.whole.merging([
            Self.unfollow(name): Self.said(name, false), Self.unfollow(other): Self.down,
            // The source's own word, which is not what the list was left saying.
            Self.tag(name): Self.said(name, true), Self.tag(other): Self.said(other, false),
        ]) { one, _ in one })
        try signIn(session)
        let people = ShellPersonPages()
        let list = people.followed
        await list.opened(Self.page, in: session)
        let one = try #require(row(name, of: list, in: session))
        let two = try #require(row(other, of: list, in: session))
        await list.press(one.id, on: Self.page, in: session)
        await list.press(two.id, on: Self.page, in: session)
        #expect(row(name, of: list, in: session)?.standing == .unfollowed)
        #expect(row(other, of: list, in: session)?.missed == false)

        list.closed(Self.page)
        #expect(people.tags.lines(of: one.tag, in: session).map(\.standing) == [.asking], "left with the list")
        #expect(people.tags.lines(of: two.tag, in: session).map(\.standing) == [.asking])
        #expect(await asked(server) == [Self.first, Self.unfollow(name), Self.unfollow(other)])

        await people.tags.opened(one.tag, in: session)
        #expect(await asked(server).filter { $0 == Self.tag(name) }.count == 1)
        #expect(people.tags.lines(of: one.tag, in: session) == [TagFollowLine(host: Self.host, tag: one.tag, standing: .said(true))])
        await people.tags.opened(two.tag, in: session)
        #expect(await asked(server).filter { $0 == Self.tag(other) }.count == 1)
        #expect(people.tags.lines(of: two.tag, in: session) == [TagFollowLine(host: Self.host, tag: two.tag, standing: .said(false))])
        await people.tags.opened(one.tag, in: session)
        #expect(await asked(server).count == 5, "asked, the page is drawn from what its source said")

        // Pressed on the list again over what the hashtag's page was told: the list's word still.
        await list.opened(Self.page, in: session)
        await list.press(one.id, on: Self.page, in: session)
        #expect(await asked(server).filter { $0 == Self.unfollow(name) }.count == 2)
        await people.tags.opened(one.tag, in: session)
        #expect(await asked(server).filter { $0 == Self.tag(name) }.count == 2)
    }

    @Test("A press on a row under a sign-in that may not change who the reader follows writes nothing down: given the rest where it stood, the hashtag's page says nothing the source did not")
    func aPressNotSentIsNotWrittenDown() async throws {
        let (session, server, _) = await session(Self.whole)
        try signIn(session, holding: Self.seeing)
        let people = ShellPersonPages()
        let tag = try #require(PostTag("#" + Self.names[0]))
        await people.tags.press(tag, at: Self.host, to: false, in: session)
        let before = ShellPersonPages.signIns(at: Self.host, in: session)
        _ = try session.mastodon.tokens.update(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: Self.follows, asked: Self.follows
        ))
        session.mastodon.refresh()
        #expect(session.mastodon.standing(.follows, host: Self.host) == .held)
        #expect(ShellPersonPages.signIns(at: Self.host, in: session) == before, "the same sign-in, given more")
        #expect(people.tags.lines(of: tag, in: session).map(\.standing) == [.asking])
        #expect(await asked(server).isEmpty)
    }

    @Test("An unfollow that does not arrive is said under the row in the hashtag page's own sentence, and the row stays followed with Unfollow offered; a press on a row the list does not show sends nothing")
    func anUnfollowThatDoesNotArrive() async throws {
        let name = Self.names[0]
        let (session, server, _) = await session(Self.whole.merging([Self.unfollow(name): Self.down]) { one, _ in one })
        try signIn(session)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)
        let before = try #require(row(name, of: list, in: session))
        await list.press(before.id, on: Self.page, in: session)
        let after = try #require(row(name, of: list, in: session))
        #expect(after.standing == .followed && after.missed == false)
        #expect(after.missedWords(language: .english) == "Could not unfollow #\(name) at m.example.")
        #expect(list.said(of: Self.page, in: session)?.offer(for: after) == .act(false))
        #expect(session.mastodon.signedInHosts.contains(Self.host))

        await list.press("m.example\u{1e}rising\u{1e}tag\u{1e}nosuchrow", on: Self.page, in: session)
        #expect(await asked(server) == [Self.first, Self.unfollow(name)])
    }

    @Test("A sign-in that only sees who the reader follows reads the list, and its rows offer no Unfollow: the row's menu holds the line of how the sign-in stands, whose press asks, and a press on the row sends nothing")
    func aSignInThatOnlySees() async throws {
        let (session, server, _) = await session(Self.whole)
        try signIn(session, holding: Self.seeing)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)
        #expect(shown(list, in: session) == Array(Self.names.prefix(2)))
        let said = try #require(list.said(of: Self.page, in: session))
        let first = try #require(said.rows.first)
        let partly = PartWords.Place(kind: .partly, key: "part.follows.partly.changing")
        #expect(said.offer(for: first) == .locked(partly))
        #expect(FollowedTagsSaid.name(of: .locked(partly), on: first, language: .english)
            == "This sign-in was not asked to follow or unfollow. Update permission")
        await list.press(first.id, on: Self.page, in: session)
        #expect(await asked(server) == [Self.first], "no press is sent where the sign-in may not change who is followed")
        #expect(row(first.tag.name, of: list, in: session)?.standing == .followed)
        // Nor does the hashtag page's own press, asked for a row directly.
        await ShellPersonPages().tags.press(first.tag, at: Self.host, to: false, in: session)
        #expect(await asked(server) == [Self.first])
        await list.readOn(Self.page, in: session)
        #expect(shown(list, in: session) == Array(Self.names.prefix(4)), "and it reads on all the same")
    }

    // MARK: - What comes late

    @Test("A list read again does not bring back a row unfollowed while the read was on its way; one unfollowed before the read began is as the read says")
    func aReadAgainDoesNotResurrectARow() async throws {
        let name = Self.names[0]
        let (session, server, _) = await session([
            Self.first: Self.stretch(Array(Self.names.prefix(2))), Self.unfollow(name): Self.said(name, false),
            Self.unfollow(Self.names[1]): Self.said(Self.names[1], false),
        ])
        try signIn(session)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)
        let pressed = try #require(row(name, of: list, in: session))

        await server.hold(Self.first)
        let firstGuard = watching("the ask of \(Self.first), held at its server") { await server.release(Self.first) }
        defer { firstGuard.cancel() }
        let again = Task { await list.again(Self.page, in: session) }
        defer { Task { await server.release(Self.first) } }
        await server.arrival(of: Self.first, times: 2, by: again)
        // The press lands while the read — which still lists the hashtag — is on its way.
        await list.press(pressed.id, on: Self.page, in: session)
        #expect(row(name, of: list, in: session)?.standing == .unfollowed)
        await server.release(Self.first)
        await again.value
        #expect(shown(list, in: session) == Array(Self.names.prefix(2)))
        #expect(row(name, of: list, in: session)?.standing == .unfollowed, "not resurrected by the read that was out")

        // Unfollowed, and then read again: the read began after the answer, and is the newer word.
        let second = try #require(row(Self.names[1], of: list, in: session))
        await list.press(second.id, on: Self.page, in: session)
        #expect(row(Self.names[1], of: list, in: session)?.standing == .unfollowed)
        await server.answer(Self.first, Self.stretch([Self.names[1]]))
        await list.again(Self.page, in: session)
        #expect(shown(list, in: session) == [Self.names[1]], "what the source no longer lists has left")
        #expect(row(Self.names[1], of: list, in: session)?.standing == .followed, "and what it lists is as it says")
    }

    @Test("A hashtag followed again from its row while the list is being read again keeps that row, where it stood, though the read — taken before the follow — does not list it")
    func aRowFollowedAgainIsKept() async throws {
        let name = Self.names[0]
        let (session, server, _) = await session([
            Self.first: Self.stretch(Array(Self.names.prefix(3))), Self.unfollow(name): Self.said(name, false),
            Self.follow(name): Self.said(name, true),
        ])
        try signIn(session)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)
        let pressed = try #require(row(name, of: list, in: session))
        await list.press(pressed.id, on: Self.page, in: session)
        #expect(row(name, of: list, in: session)?.standing == .unfollowed)

        // The read is taken while it is not followed, and lands after it is followed again.
        await server.answer(Self.first, Self.stretch(Array(Self.names[1 ..< 3])))
        await server.hold(Self.first)
        let firstGuard = watching("the ask of \(Self.first), held at its server") { await server.release(Self.first) }
        defer { firstGuard.cancel() }
        let again = Task { await list.again(Self.page, in: session) }
        defer { Task { await server.release(Self.first) } }
        await server.arrival(of: Self.first, times: 2, by: again)
        await list.press(pressed.id, on: Self.page, in: session)
        await server.release(Self.first)
        await again.value
        #expect(shown(list, in: session) == Array(Self.names.prefix(3)), "the row is kept, in the place it had")
        #expect(row(name, of: list, in: session)?.standing == .followed)
        #expect(list.said(of: Self.page, in: session)?.rows.count == 3)

        // Read again after: the read is the newer word, and lists it or does not.
        await list.again(Self.page, in: session)
        #expect(shown(list, in: session) == Array(Self.names[1 ..< 3]))
    }

    @Test("The foot pressed twice asks once; a stretch that comes after the list was asked from the top lands nowhere; and one that comes after the page was left lands nowhere, the list asked afresh when it is opened again")
    func aLateStretchLandsNowhere() async throws {
        let (session, server, _) = await session(Self.whole)
        try signIn(session)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)

        await server.hold(Self.after(12))
        defer { Task { await server.release(Self.after(12)) } }
        let after12Guard = watching("the ask of \(Self.after(12)), held at its server") { await server.release(Self.after(12)) }
        defer { after12Guard.cancel() }
        let one = Task { await list.readOn(Self.page, in: session) }
        await server.arrival(of: Self.after(12), by: one)
        #expect(list.said(of: Self.page, in: session)?.foot == nil, "the stretch on its way is the toast's to say")
        #expect(list.ask(of: Self.page, in: session, language: .english) == PageAsking(asking: "Reading more hashtags…"))
        await list.readOn(Self.page, in: session)
        #expect(await asked(server) == [Self.first, Self.after(12)], "pressed twice: one ask")

        // Asked from the top while the reading-on is out: the top's answer is the list.
        await server.answer(Self.first, Self.stretch(["fresh"]))
        await list.again(Self.page, in: session)
        #expect(shown(list, in: session) == ["fresh"])
        await server.release(Self.after(12))
        await one.value
        #expect(shown(list, in: session) == ["fresh"], "the late stretch lands nowhere")
        #expect(list.said(of: Self.page, in: session)?.foot == .end)

        // Left with a read on its way.
        await server.answer(Self.first, Self.captured(0))
        await list.again(Self.page, in: session)
        await server.hold(Self.after(12))
        let late = Task { await list.readOn(Self.page, in: session) }
        await server.arrival(of: Self.after(12), times: 2, by: late)
        list.closed(Self.page)
        #expect(list.said(of: Self.page, in: session)?.reading == .asking, "nothing of a page left is drawn")
        await server.release(Self.after(12))
        await late.value
        #expect(shown(list, in: session).isEmpty, "and its stretch lands nowhere")
        await list.opened(Self.page, in: session)
        #expect(shown(list, in: session) == Array(Self.names.prefix(2)), "opened again, it is asked afresh")
    }

    @Test("A stretch that comes after the sign-in was replaced, ended, or its source removed lands nowhere: the list is the reader's who asked for it, and the next reader is shown none of it")
    func aReplacedSignInIsNotShownTheOnesBefore() async throws {
        let (session, server, _) = await session(Self.whole)
        try signIn(session)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)
        #expect(shown(list, in: session).count == 2)

        // Replaced while a stretch is out.
        await server.hold(Self.after(12))
        defer { Task { await server.release(Self.after(12)) } }
        let after12Guard = watching("the ask of \(Self.after(12)), held at its server") { await server.release(Self.after(12)) }
        defer { after12Guard.cancel() }
        let late = Task { await list.readOn(Self.page, in: session) }
        await server.arrival(of: Self.after(12), by: late)
        try signIn(session, as: "other")
        #expect(shown(list, in: session).isEmpty, "not drawn for the next reader")
        #expect(list.said(of: Self.page, in: session)?.reading == .asking)
        await server.release(Self.after(12))
        await late.value
        #expect(shown(list, in: session).isEmpty, "and the stretch lands nowhere")
        // The foot pressed by the reader it was not given to reads nothing on.
        await list.readOn(Self.page, in: session)
        #expect(await asked(server).filter { $0 == Self.after(12) }.count == 1)
        await list.opened(Self.page, in: session)
        #expect(await server.bearers.last == "Bearer other", "asked afresh, as them")
        #expect(shown(list, in: session) == Array(Self.names.prefix(2)))

        // Ended while the top is being asked.
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let firstGuard = watching("the ask of \(Self.first), held at its server") { await server.release(Self.first) }
        defer { firstGuard.cancel() }
        let times = await asked(server).filter { $0 == Self.first }.count
        let top = Task { await list.again(Self.page, in: session) }
        await server.arrival(of: Self.first, times: times + 1, by: top)
        try signOut(session)
        #expect(list.said(of: Self.page, in: session) == nil, "no sign-in: no such page")
        await server.release(Self.first)
        await top.value
        #expect(list.said(of: Self.page, in: session) == nil)

        // Its source removed while a stretch is out.
        try signIn(session, as: "third")
        await list.opened(Self.page, in: session)
        await server.hold(Self.after(12))
        let stretches = await asked(server).filter { $0 == Self.after(12) }.count
        let gone = Task { await list.readOn(Self.page, in: session) }
        await server.arrival(of: Self.after(12), times: stretches + 1, by: gone)
        session.sources = session.sources.filter { $0.host != Self.host }
        await server.release(Self.after(12))
        await gone.value
        #expect(list.said(of: Self.page, in: session) == nil)
        session.sources = await session.store.sources()
        #expect(shown(list, in: session).isEmpty, "what came for a source that was gone is not kept for its return")

        // And the same of the list asked from the top.
        await server.hold(Self.first)
        let firsts = await asked(server).filter { $0 == Self.first }.count
        let fromTop = Task { await list.again(Self.page, in: session) }
        await server.arrival(of: Self.first, times: firsts + 1, by: fromTop)
        session.sources = session.sources.filter { $0.host != Self.host }
        await server.release(Self.first)
        await fromTop.value
        session.sources = await session.store.sources()
        #expect(shown(list, in: session).isEmpty)
        #expect(list.said(of: Self.page, in: session)?.reading == .asking)
    }

    // MARK: - The walk

    @Test("The list is a step of the walk as a page of hashtags is: opened once from its line, which is lit and given back on leaving; a page opened to a swipe and named for it; and a walk ended in one go — a timeline switched under it, a hashtag's page kept in front or none — lets go of each list it held, as leaving one does, so opened again it is asked again")
    func theListIsAStepOfTheWalk() async throws {
        var walk = ShellWalk()
        var lamp: String? = "post"
        #expect(walk.open(Self.page, lamp: &lamp))
        #expect(lamp == Self.page.id)
        #expect(walk.openedFollowedTags == Self.page)
        #expect(!walk.open(Self.page, lamp: &lamp), "a step onto the list in front is no step")
        #expect(walk.depth == 1)
        // A page of its own (F10): its sideways is the frame's where it is drawn, and goes back
        // over the stream drawn where it cannot be.
        #expect(TimelinePane.page(walk.standing) == .tabbed && TimelinePane.page(walk.standing, drawn: false) == .opened)
        let named: String = "followed:" + Self.page.id
        #expect(TimelinePane.openedID(walk.standing) == named)
        #expect(walk.followedTags == [Self.page])
        let left = walk.back()
        #expect(left?.step == .followedTags(Self.page))
        #expect(left?.lamp == Self.page.id)
        #expect(walk.followedTags.isEmpty)

        let (session, server, _) = await session(Self.whole)
        try signIn(session)
        let list = ShellPersonPages().followed
        let tag = try #require(PostTag("#" + Self.names[0]))
        var places = TimelinePlaces()
        // Once with a hashtag's page in front, which stays; once with the list in front, which goes.
        for kept in [true, false] {
            _ = walk.open(Self.page, lamp: &lamp)
            if kept { _ = walk.walk(to: .tag(tag), from: "row") }
            await list.opened(Self.page, in: session)
            let before = await asked(server).filter { $0 == Self.first }.count
            let held = walk.followedTags
            #expect(held == [Self.page])
            let stays = FediqoRootView.timelineSwitched(on: &walk, places: &places, from: .all, to: .trends, shown: [], results: nil)
            #expect(stays == (kept ? tag : nil))
            // What the root does about each list the walk held.
            for page in held { list.closed(page) }
            walk.clear()
            #expect(list.said(of: Self.page, in: session)?.reading == .asking, "nothing of a list left is drawn")
            await list.opened(Self.page, in: session)
            #expect(await asked(server).filter { $0 == Self.first }.count == before + 1, "a list opened is a list asked")
        }

        let root = try String(contentsOf: Self.root, encoding: .utf8)
        for call in [
            "let lists = walk.followedTags\n", "for page in lists { people.followed.closed(page) }\n",
            "for page in cleared.lists { people.followed.closed(page) }",
            "if case .followedTags(let page) = left.step { people.followed.closed(page) }",
        ] {
            #expect(root.components(separatedBy: call).count == 2, "the root calls \(call) once")
        }
    }

    @Test("The way to the list is drawn on the reader's own page once the source has said who they are, and on nobody else's; the keys walk it between the figures and the posts where it is a press — open, or a lock that asks — and pass over a lock that asks nothing")
    func theKeysReachTheWayWhereItIsAPress() async throws {
        let ada = "/api/v1/accounts/lookup?acct=ada"
        let (session, _, _) = await session(Self.whole.merging(Self.own) { one, _ in one }.merging([
            ada: PageServer.Answer(body: #"{"id":"42","acct":"ada","display_name":"Ada","note":"","followers_count":1,"following_count":1,"statuses_count":0}"#),
            "/api/v1/accounts/42/statuses": PageServer.Answer(body: "[]"),
        ]) { one, _ in one })
        let pages = ShellPersonPages()
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        let other = try #require(DummyPerson(handle: "@ada@m.example", host: Self.host))

        try signIn(session)
        await session.mastodon.learnWho(host: Self.host)
        #expect(pages.followedEntry(of: me, in: session) == nil, "none until the source has said who they are")
        await pages.opened(me, in: session)
        let open = try #require(pages.followedEntry(of: me, in: session))
        #expect(open == FollowedTagsEntry(page: Self.page, locked: nil))
        // It is the last block of About (F9), which is in front on opening: the lamp lands on
        // About's first block, and reaches the way as it reaches every block.
        let blocks = pages.walkedIDs(of: me, in: session)
        #expect(pages.front(of: me, in: session) == .about && pages.about(of: me, in: session)?.blocks.last == .you)
        #expect(blocks.last == open.id && blocks.count > 1)
        #expect(pages.entry(of: me, in: session) == blocks.first, "the lamp lands on About's first block")
        #expect(pages.tabs(of: me, in: session) == PersonTab.allCases, "a reader's own lists are always tabs")
        await pages.opened(other, in: session)
        #expect(pages.said(of: other, in: session)?.person != nil)
        #expect(pages.followedEntry(of: other, in: session) == nil, "somebody else's page has none")
        #expect(pages.walkedIDs(of: other, in: session).contains(Self.page.id) == false)

        // A lock that asks is a press: the keys stand on it.
        try signIn(session, holding: Self.reads)
        await session.mastodon.learnWho(host: Self.host)
        await pages.opened(me, in: session)
        let asks = try #require(pages.followedEntry(of: me, in: session))
        #expect(asks.locked == PartWords.Place(kind: .unasked, key: "part.follows.unasked"))
        #expect(pages.walkedIDs(of: me, in: session).contains(asks.id))

        // Asked for and not given: said, no press, and no row for the keys.
        try signIn(session, holding: Self.reads, asked: Self.follows)
        await session.mastodon.learnWho(host: Self.host)
        await pages.opened(me, in: session)
        let none = try #require(pages.followedEntry(of: me, in: session))
        #expect(none.locked == PartWords.Place(kind: .none, key: "part.ask.none"))
        #expect(none.asks == false)
        // Still a block of About, read as any block is; Return on it opens nothing.
        #expect(none.presses == false && pages.walkedIDs(of: me, in: session).last == none.id)
        #expect(pages.about(of: me, in: session)?.press(on: none.id) == nil)

        // A forum's reader has no such line.
        let author = try #require(DummyPerson(handle: "@me@forum.example", host: Self.forum.host))
        #expect(pages.followedEntry(of: author, in: session) == nil)
    }

    @Test("A row's menu is its one item — Unfollow, Follow, or the line that asks the sign-in for the rest — and where the sign-in's standing cannot be asked about, that sentence as a dim item that does nothing; nothing while a press of the row is out")
    func theMenuOfARow() throws {
        let tag = try #require(PostTag("#" + Self.names[0]))
        var row = FollowedTagRow(tag: tag, host: Self.host)
        var said = FollowedTagsSaid(page: Self.page, reading: .said, rows: [row])
        var acted = 0, asked = 0
        let unfollow = try #require(said.more(for: row, act: { _ in acted += 1 }, ask: { asked += 1 }))
        #expect(unfollow.whys.isEmpty)
        #expect(unfollow.items.map(\.name) == [L10n.t("tag.follow.unfollow")])
        // Red, asking first which hashtag at which source, as About's row does.
        #expect(unfollow.dangers.count == 1 && unfollow.items.first?.question == ShellQuestion.unfollow(tag, at: Self.host))
        row.standing = .unfollowed
        let follow = try #require(said.more(for: row, act: { _ in }, ask: {}))
        #expect(follow.items.map(\.name) == [L10n.t("tag.follow.follow")] && follow.dangers.isEmpty, "following again asks nothing")
        row.standing = .doing(false)
        #expect(said.more(for: row, act: { _ in }, ask: {}) == nil)

        row.standing = .followed
        said.changing = PartWords.Place(kind: .partly, key: "part.follows.partly.changing")
        let asks = try #require(said.more(for: row, act: { _ in acted += 1 }, ask: { asked += 1 }))
        #expect(asks.whys.isEmpty)
        #expect(asks.items.map(\.name) == [String(format: L10n.t("part.follows.partly.changing"), Self.host)])

        // Said, and not to be asked about: the sentence, and nothing to press.
        let never = PartWords.Place(kind: .none, key: "part.ask.none")
        #expect(never.asks == false)
        said.changing = never
        // Changed (#385): the sentence headed an empty menu; the menu is now the act, dim, saying it.
        let stated = try #require(said.more(for: row, act: { _ in acted += 1 }, ask: { asked += 1 }))
        let sentence = String(format: L10n.t("part.ask.none"), Self.host)
        #expect(stated.items.map(\.name) == [L10n.t("tag.follow.unfollow")] && stated.whys == [sentence])
        let item = try #require(stated.items.first)
        #expect(item.look == .dim(.notNow) && !item.answers)
        #expect(item.title() == ShellMark.said(L10n.t("tag.follow.unfollow"), sentence))
        item.press { _ in }
        #expect(acted == 0)
        #expect(asked == 0)
    }

    @Test("A sign-in that has ended is drawn no list, though what rode beside it could not be read again and still says it sees who the reader follows")
    func anEndedSignInHasNoList() async throws {
        let tokens = PartsRefusedTokens()
        let (session, _, _) = await session(Self.whole, tokens: tokens)
        try signIn(session)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)
        #expect(shown(list, in: session).count == 2)

        // Who is signed in is read — nobody, now — and what each sign-in holds is refused.
        tokens.refusing = true
        try signOut(session)
        #expect(session.mastodon.signedInHosts.contains(Self.host) == false)
        #expect(session.mastodon.standing(.follows, host: Self.host) == .held, "what was read before still stands")
        #expect(list.said(of: Self.page, in: session) == nil)
        #expect(list.canAskAgain(Self.page, in: session) == false)
    }

    // MARK: - Words

    @Test("Every sentence of the list is in each language, and the two tables of Chinese are the same; following is the word the hashtag's page uses")
    func everySentenceIsInEachLanguage() throws {
        let keys = [
            "followed.tags.title", "followed.tags.asking",
            "followed.tags.none", "followed.tags.foot.more", "followed.tags.foot.reading",
            "followed.tags.foot.end", "followed.tags.foot.stopped", "followed.tags.foot.farthest",
        ]
        for key in keys {
            let english = L10n.t(key, language: .english)
            let chinese = L10n.t(key, language: .taiwanese)
            #expect(english != key, "\(key) has no English")
            #expect(chinese != key && chinese != english, "\(key) has no Chinese")
            #expect(!chinese.contains("跟隨"), "\(key): following is 追蹤 here")
        }
        #expect(L10n.t("followed.tags.title", language: .taiwanese).contains("追蹤"))
        // The one purpose both of its asks are listed under says both.
        #expect(L10n.t("work.purpose.followedTags", language: .english) == "Reading the hashtags you follow at a source, or whether you follow one")
        #expect(L10n.t("work.purpose.followedTags", language: .taiwanese) == "讀取你在來源追蹤的主題標籤，或是否追蹤其中某一個")
    }
}

/// A token store that can refuse the look at what each sign-in holds while it still says who is
/// signed in: the two are two reads, and a device may lock between them.
private final class PartsRefusedTokens: MastodonTokenStore, @unchecked Sendable {
    private let held = MemoryMastodonTokens()
    var refusing = false

    func token(host: String) throws -> MastodonToken? { try held.token(host: host) }
    func save(_ token: MastodonToken) throws { try held.save(token) }
    func forget(host: String) throws { try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try held.grants() }
    func parts() throws -> [String: MastodonHeld] {
        if refusing { throw ForumCredentialError.keychain(-25_308) }
        return try held.parts()
    }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}
