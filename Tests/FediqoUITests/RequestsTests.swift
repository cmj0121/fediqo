import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #313, the last of it: the people who ask to follow the reader are listed and answered, and
/// a follower is removed — where each is reached, what a row offers, what is sent and when,
/// and what the list says after.
///
/// **No check here waits on the clock.** Each waits on an ask arriving at `PageServer` or on
/// the call that made it returning; a held ask is let go by the check, and by a guard when the
/// run has gone still; every deadline is on a clock nobody turns.
@MainActor
@Suite("Requests to follow are answered, and a follower removed", .serialized, .watched)
struct RequestsTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let seeing = "\(reads) read:follows"
    private static let follows = "\(seeing) write:follows"

    private static let who = "/api/v1/accounts/verify_credentials"
    private static let lookup = "/api/v1/accounts/lookup?acct=me"
    private static let listed = "/api/v1/follow_requests?limit=80"
    private static let mine = "/api/v1/accounts/7/followers?limit=80"
    private static let theirs = "/api/v1/accounts/42/followers?limit=80"
    private static func stands(_ ids: [Int]) -> String {
        "/api/v1/accounts/relationships?" + ids.map { "id%5B%5D=\($0)" }.joined(separator: "&")
    }
    private static func accept(_ id: Int) -> String { "/api/v1/follow_requests/\(id)/authorize" }
    private static func refuse(_ id: Int) -> String { "/api/v1/follow_requests/\(id)/reject" }
    private static func remove(_ id: Int) -> String { "/api/v1/accounts/\(id)/remove_from_followers" }

    private static let requests = PeopleList(requestsAt: host)
    private static let me = Person(source: source, accountID: "7", handle: "@me@m.example", name: "Me", tally: Person.Tally(followers: 2))
    private static let followers = PeopleList(.followers, of: me)
    private static let ada = Person(source: source, accountID: "42", handle: "@ada@m.example", name: "Ada")

    private static func people(_ ids: [Int]) -> PageServer.Answer {
        PageServer.Answer(body: "[" + ids.map { #"{"id":"\#($0)","acct":"p\#($0)","display_name":"Person \#($0)"}"# }.joined(separator: ",") + "]")
    }

    /// One standing in the shape a real server's has (`MastodonRequestsCaptures`, in Core's checks).
    private static func standing(_ id: Int, followedBy: Bool) -> String {
        #"{"id":"\#(id)","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":\#(followedBy),"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#
    }

    private static func said(_ standings: String...) -> PageServer.Answer { PageServer.Answer(body: "[" + standings.joined(separator: ",") + "]") }
    private static let gone = PageServer.Answer(body: #"{"error":"Record not found"}"#, status: 404)

    private static func served(_ more: [String: PageServer.Answer] = [:]) -> [String: PageServer.Answer] {
        [
            who: PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#),
            lookup: PageServer.Answer(body: #"{"id":"7","acct":"me","display_name":"Me","followers_count":2}"#),
            listed: people([3, 4]), mine: people([3, 4]), theirs: people([3, 4]),
            stands([3, 4]): said(standing(3, followedBy: false), standing(4, followedBy: false)),
            accept(3): PageServer.Answer(body: standing(3, followedBy: true)),
            refuse(4): PageServer.Answer(body: standing(4, followedBy: false)),
            remove(3): PageServer.Answer(body: standing(3, followedBy: false)),
        ].merging(more) { $1 }
    }

    private func session(_ routes: [String: PageServer.Answer] = served()) async -> (ShellSession, PageServer) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        session.work = SourceWork()
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server)
    }

    private func signIn(_ session: ShellSession, as access: String = "tok", holding scopes: String = RequestsTests.follows) async throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: access, clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
    }

    private func asked(_ server: PageServer) async -> [String] {
        await server.asked.filter { $0 != Self.who }
    }

    private func row(_ id: String, of list: PeopleList, _ lists: ShellPeoplePages, _ session: ShellSession) throws -> Person {
        try #require(lists.said(of: list, in: session)?.people.first { $0.accountID == id })
    }

    private func ids(_ list: PeopleList, _ lists: ShellPeoplePages, _ session: ShellSession) -> [String] {
        lists.said(of: list, in: session)?.people.map(\.accountID) ?? []
    }

    // MARK: - The list, and what its rows offer

    @Test("The people who ask to follow the reader are a list of people like any other — asked as the reader, one stretch and how the reader stands to those in it — whose rows offer accepting as a press and refusing behind the `…`, asked first; a sign-in that only sees reads the list and is offered nothing; with no sign-in there is no such list, and nothing is asked")
    func theRequestsAreListed() async throws {
        let en = DummyLanguage.english
        let (session, server) = await session()
        let lists = ShellPersonPages().lists
        #expect(lists.said(of: Self.requests, in: session) == nil, "nobody is signed in: nothing to draw")
        await lists.opened(Self.requests, in: session)
        #expect(await asked(server).isEmpty, "and nobody is asked")

        try await signIn(session)
        let before = try #require(lists.said(of: Self.requests, in: session))
        #expect(before.reading == .asking && before.stateLine() == nil)
        #expect(TimelineToast.waiting(PeopleSaid.words(Self.requests.which) + ".asking", hosts: ["m.example"], language: en) == "Asking m.example who asks to follow you…")
        #expect(PeopleSaid.title(Self.requests, language: en) == "Who asks to follow you at m.example")
        #expect(PeopleSaid.title(Self.requests, language: .taiwanese) == "在 m.example 請求跟隨你的人")
        await lists.opened(Self.requests, in: session)
        #expect(await asked(server) == [Self.listed, Self.stands([3, 4])])
        #expect(await server.bearers.suffix(2) == ["Bearer tok", "Bearer tok"])
        let said = try #require(lists.said(of: Self.requests, in: session))
        #expect(said.people.map(\.accountID) == ["3", "4"] && said.stands.count == 2 && said.own)
        #expect(said.acts == [.acceptRequest, .refuseRequest] && said.accepts && said.dangerous == [.refuseRequest])
        #expect(PeopleSaid.counts(Self.requests) == nil, "the list itself counts nobody: how many ask is the account check's figure (`PeopleSaid.tally`)")

        // The row's `…`: refusing, which asks first and says what it does.
        var pressed: [PersonAct] = []
        let menu = try #require(PeoplePane.menu(for: said, of: said.people[0], asks: .constant(nil)) { pressed.append($0) })
        let more = menu.more()
        #expect(more.items.map(\.name) == ["Refuse"].map { _ in PersonActing.name(.refuseRequest) } && more.whys.isEmpty)
        let question = ShellQuestion.about(.refuseRequest, "@p3@m.example", at: Self.host, language: en)
        #expect(question.title == "Refuse the request of @p3@m.example to follow you at m.example?")
        #expect(question.line == "They will not follow you. They can ask again." && question.choices.map(\.label) == ["Refuse"] && question.choices.map(\.role) == [.destructive])
        #expect(ShellQuestion.about(.refuseRequest, "@p3", at: Self.host, language: .taiwanese).title == "在 m.example 拒絕 @p3 跟隨你的請求？")
        #expect(PersonRow.acceptSpoken(said.people[0], language: en) == "Let @p3@m.example follow you at m.example")

        // Nobody asks: said of the source.
        let (empty, _) = await self.session(Self.served([Self.listed: Self.people([])]))
        try await signIn(empty)
        let none = ShellPersonPages().lists
        await none.opened(Self.requests, in: empty)
        #expect(none.said(of: Self.requests, in: empty)?.nothing(language: en) == "m.example says nobody asks to follow you.")

        // A sign-in that sees and may not change: the list, and plain rows.
        let (seeing, wire) = await self.session()
        try await signIn(seeing, holding: Self.seeing)
        let plain = ShellPersonPages().lists
        await plain.opened(Self.requests, in: seeing)
        let read = try #require(plain.said(of: Self.requests, in: seeing))
        #expect(read.people.count == 2 && read.acts.isEmpty && !read.accepts)
        #expect(PeoplePane.menu(for: read, of: read.people[0], asks: .constant(nil)) { _ in } == nil)
        await plain.press(.acceptRequest, on: read.people[0], of: Self.requests, in: seeing)
        #expect(await asked(wire) == [Self.listed, Self.stands([3, 4])], "nothing is sent for it")
        // And it is told why, over the rows, with the press that asks for the rest.
        let lock = PartWords.Place(kind: .partly, key: "part.follows.partly.changing")
        #expect(read.lock == lock && lock.asks)
        #expect(read.lockWords(language: en) == "This sign-in was not asked to follow or unfollow. Update permission")
        await plain.opened(Self.followers, in: seeing)
        #expect(plain.said(of: Self.followers, in: seeing)?.lock == lock, "the reader's own followers, where removal would be")
        await plain.opened(PeopleList(.followers, of: Self.ada), in: seeing)
        #expect(plain.said(of: PeopleList(.followers, of: Self.ada), in: seeing)?.lock == nil, "nothing would be offered on anybody else's")
        #expect(said.lock == nil && said.lockWords() == nil, "a sign-in that may change them has no such line")
    }

    @Test("A request accepted or refused leaves the list at the press and is sent after, through the sequence a press on somebody's page goes through: one request out a person, a second press of that row meanwhile sends nothing; answered, the row is gone and how the reader stands to them is what the source said. One that did not arrive, or whose request is no longer there, puts the row back and says so under it, in both languages; pressed again and answered, the sentence goes")
    func acceptingAndRefusing() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let pages = ShellPersonPages(), lists = pages.lists
        await lists.opened(Self.requests, in: session)
        let three = try row("3", of: Self.requests, lists, session), four = try row("4", of: Self.requests, lists, session)

        await server.hold(Self.accept(3))
        let accept3Guard = watching("the ask of \(Self.accept(3)), held at its server") { await server.release(Self.accept(3)) }
        defer { accept3Guard.cancel() }
        let pressed = Task { await lists.press(.acceptRequest, on: three, of: Self.requests, in: session) }
        await server.arrival(of: Self.accept(3), by: pressed)
        #expect(ids(Self.requests, lists, session) == ["4"], "it leaves at the press")
        await lists.press(.acceptRequest, on: three, of: Self.requests, in: session)
        await lists.press(.refuseRequest, on: three, of: Self.requests, in: session)
        #expect(await asked(server) == [Self.listed, Self.stands([3, 4]), Self.accept(3)], "one request out a person")
        await server.release(Self.accept(3))
        await pressed.value
        #expect(ids(Self.requests, lists, session) == ["4"] && lists.said(of: Self.requests, in: session)?.missed.isEmpty == true)
        let stood = pages.acts.acting(of: DummyPerson(three), said: PersonSaid(source: Self.host, reading: .said(three)), in: session)
        #expect(stood?.reading == .said(PersonStanding(accountID: "3", followedBy: true)), "as the source answered")

        await lists.press(.refuseRequest, on: four, of: Self.requests, in: session)
        #expect(ids(Self.requests, lists, session).isEmpty)
        #expect(await asked(server).suffix(2) == [Self.accept(3), Self.refuse(4)])
        // Gone rows take no further press.
        await lists.press(.acceptRequest, on: four, of: Self.requests, in: session)
        #expect(await asked(server).count == 4)

        // The request is no longer there — taken back, or answered elsewhere: refused as not found.
        for answer in [Self.gone, nil] as [PageServer.Answer?] {
            let (other, wire) = await self.session(Self.served().filter { $0.key != Self.accept(3) })
            try await signIn(other)
            let stale = ShellPersonPages().lists
            await stale.opened(Self.requests, in: other)
            let row = try self.row("3", of: Self.requests, stale, other)
            await wire.answer(Self.accept(3), answer)
            await stale.press(.acceptRequest, on: row, of: Self.requests, in: other)
            let back = try #require(stale.said(of: Self.requests, in: other))
            #expect(back.people.map(\.accountID) == ["3", "4"], "the row is back")
            #expect(back.missed == ["3": "Could not accept the request of @p3@m.example at m.example."])
            #expect(PersonActing.missedWords(.acceptRequest, named: "@p3", at: Self.host, language: .taiwanese) == "無法在 m.example 接受 @p3 的請求。")
            #expect(PersonActing.missedWords(.refuseRequest, named: "@p3", at: Self.host, language: .english) == "Could not refuse the request of @p3 at m.example.")
            #expect(other.mastodon.signedInHosts.contains(Self.host), "a refusal signs nobody out")
            // Read again from the top, the rows are new and the sentence goes.
            await stale.again(Self.requests, in: other)
            #expect(stale.said(of: Self.requests, in: other)?.missed.isEmpty == true)
            await wire.answer(Self.accept(3), PageServer.Answer(body: Self.standing(3, followedBy: true)))
            await stale.press(.acceptRequest, on: row, of: Self.requests, in: other)
            #expect(stale.said(of: Self.requests, in: other)?.people.map(\.accountID) == ["4"])
            #expect(stale.said(of: Self.requests, in: other)?.missed.isEmpty == true)
        }
    }

    @Test("A follower is removed from the `…` of a row of the reader's own Followers list and nowhere else: asked first, in words that say what it does; the row leaves at the yes and the source's figure is left as the source said it; nothing is offered or sent on somebody else's list, for an act of another list, or for somebody the source says does not follow the reader")
    func removingAFollower() async throws {
        let en = DummyLanguage.english
        let follow = Self.said(Self.standing(3, followedBy: true), Self.standing(4, followedBy: false))
        let (session, server) = await session(Self.served([Self.stands([3, 4]): follow]))
        try await signIn(session)
        let lists = ShellPersonPages().lists
        await lists.opened(Self.followers, in: session)
        let said = try #require(lists.said(of: Self.followers, in: session))
        #expect(said.own && said.acts == [.removeFollower] && !said.accepts && said.dangerous == [.removeFollower])
        let menu = try #require(PeoplePane.menu(for: said, of: said.people[0], asks: .constant(nil)) { _ in })
        #expect(menu.more().items.map(\.name) == [PersonActing.name(.removeFollower)])
        #expect(PersonActing.name(.removeFollower, language: en) == "Remove from following you")
        let question = ShellQuestion.about(.removeFollower, "@p3@m.example", at: Self.host, language: en)
        #expect(question.title == "Remove @p3@m.example from following you at m.example?")
        #expect(question.line == "They will no longer follow you. They can follow you again, or ask to.")
        #expect(ShellQuestion.about(.removeFollower, "@p3", at: Self.host, language: .taiwanese).title == "在 m.example 讓 @p3 不再跟隨你？")

        // Somebody else's followers: the same people, and nothing to do to them.
        let others = PeopleList(.followers, of: Self.ada)
        await lists.opened(others, in: session)
        let foreign = try #require(lists.said(of: others, in: session))
        #expect(!foreign.own && foreign.acts.isEmpty && foreign.people.count == 2)
        let before = await asked(server)
        await lists.press(.removeFollower, on: foreign.people[0], of: others, in: session)
        // An act of another list, and somebody the source says does not follow the reader.
        await lists.press(.acceptRequest, on: said.people[0], of: Self.followers, in: session)
        await lists.press(.removeFollower, on: said.people[1], of: Self.followers, in: session)
        // And past the list, the sequence itself refuses an act that is not of the list it came from.
        let acts = try #require(lists.acts)
        let wrong = await acts.pressRow(.acceptRequest, on: said.people[0], standing: nil, listed: .followers, in: session)
        let other = await acts.pressRow(.removeFollower, on: said.people[0], standing: nil, listed: .requests, in: session)
        let page = await acts.pressRow(.follow, on: said.people[0], standing: nil, listed: .followers, in: session)
        #expect(!wrong && !other && !page)
        #expect(await asked(server) == before, "nothing is sent for any of them")

        await lists.press(.removeFollower, on: said.people[0], of: Self.followers, in: session)
        #expect(await asked(server) == before + [Self.remove(3)])
        let after = try #require(lists.said(of: Self.followers, in: session))
        #expect(after.people.map(\.accountID) == ["4"] && after.missed.isEmpty)
        #expect(after.list.counted == 2, "the figure is the source's, not arithmetic")
        // It did not arrive: the row is back, and says so.
        let (down, wire) = await self.session(Self.served([Self.stands([3, 4]): follow, Self.remove(3): PageServer.Answer(body: "<html>", status: 500)]))
        try await signIn(down)
        let failing = ShellPersonPages().lists
        await failing.opened(Self.followers, in: down)
        await failing.press(.removeFollower, on: said.people[0], of: Self.followers, in: down)
        #expect(failing.said(of: Self.followers, in: down)?.people.count == 2)
        #expect(failing.said(of: Self.followers, in: down)?.missed == ["3": "Could not remove @p3@m.example from following you at m.example."])
        #expect(await asked(wire).last == Self.remove(3))
    }

    @Test("An answer is taken only by the press, the reading of the list and the reader it went with: where the list was read again from the top while the press was out, the source's fresh word of who is on it stands; and where the reader changed, nothing of the first reader's press is drawn or written for the second")
    func whoseAnAnswerIs() async throws {
        let (session, server) = await session()
        try await signIn(session, as: "first")
        let lists = ShellPersonPages().lists
        await lists.opened(Self.requests, in: session)
        let three = try row("3", of: Self.requests, lists, session)

        await server.hold(Self.accept(3))
        let accept3Guard = watching("the ask of \(Self.accept(3)), held at its server") { await server.release(Self.accept(3)) }
        defer { accept3Guard.cancel() }
        let pressed = Task { await lists.press(.acceptRequest, on: three, of: Self.requests, in: session) }
        await server.arrival(of: Self.accept(3), by: pressed)
        await lists.again(Self.requests, in: session)
        #expect(ids(Self.requests, lists, session) == ["4"], "still leaving while the press is out")
        await server.release(Self.accept(3))
        await pressed.value
        #expect(ids(Self.requests, lists, session) == ["4"], "that read was answered before the press: the press's answer is the newer word")
        // A read that lands after the answer is newer still, and is the list.
        await lists.again(Self.requests, in: session)
        #expect(ids(Self.requests, lists, session) == ["3", "4"])

        // The reader changes while a press is out.
        await server.hold(Self.refuse(4))
        let refuse4Guard = watching("the ask of \(Self.refuse(4)), held at its server") { await server.release(Self.refuse(4)) }
        defer { refuse4Guard.cancel() }
        let four = try row("4", of: Self.requests, lists, session)
        let refusing = Task { await lists.press(.refuseRequest, on: four, of: Self.requests, in: session) }
        await server.arrival(of: Self.refuse(4), by: refusing)
        try await signIn(session, as: "second")
        await lists.opened(Self.requests, in: session)
        #expect(ids(Self.requests, lists, session) == ["3", "4"], "the second reader's list, whole")
        await server.release(Self.refuse(4))
        await refusing.value
        let second = try #require(lists.said(of: Self.requests, in: session))
        #expect(second.people.map(\.accountID) == ["3", "4"] && second.missed.isEmpty)
        let refusals = await server.asked.filter { $0 == Self.refuse(4) }
        #expect(refusals.count == 1, "sent once, as the reader who pressed")
    }

    // MARK: - Where it is reached

    @Test("The way to the requests is a line of the reader's own page, on About before the hashtags they follow: in words and with no figure, the lamp stops on it, and nobody else's page has it; a sign-in that does not see who follows the reader has its own sentence there with the lock; with no sign-in, and for a forum, there is none")
    func theWayToTheRequests() async throws {
        let (session, server) = await session()
        let pages = ShellPersonPages()
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        let ada = try #require(DummyPerson(handle: "@ada@m.example", host: Self.host))
        #expect(pages.requestsEntry(of: me, in: session) == nil, "nobody is signed in")

        try await signIn(session)
        #expect(pages.requestsEntry(of: me, in: session) == nil, "none until the source has said who they are")
        await pages.opened(me, in: session)
        let entry = try #require(pages.requestsEntry(of: me, in: session))
        #expect(entry == RequestsEntry(list: Self.requests, locked: nil) && entry.presses)
        #expect(entry.words(language: .english) == "People who ask to follow you" && entry.words(language: .taiwanese) == "請求跟隨你的人")
        let about = try #require(pages.about(of: me, in: session))
        // The ways to whom the reader mutes and blocks stand between (#314).
        #expect(about.requests == entry && about.blocks.contains(.requests) && about.blocks.last == .you)
        #expect(about.blocks.firstIndex(of: .requests).map { about.blocks[($0 + 1)...].allSatisfy { [.muted, .blocked, .servers, .waiting, .you].contains($0) } } == true)
        #expect(pages.walkedIDs(of: me, in: session).contains(RequestsEntry.id))
        #expect(about.press(on: RequestsEntry.id) == nil, "the step is the walk's to take")
        #expect(pages.requestsEntry(of: ada, in: session) == nil && pages.about(of: ada, in: session)?.requests == nil)
        let count = await asked(server).count
        _ = pages.requestsEntry(of: me, in: session)
        #expect(await asked(server).count == count, "drawing it asks nobody")

        // A sign-in that only reads: the line is its lock, and says what was not asked.
        try await signIn(session, holding: Self.reads)
        await pages.opened(me, in: session)
        let locked = try #require(pages.requestsEntry(of: me, in: session))
        #expect(locked.locked == PartWords.Place(kind: .unasked, key: "part.follows.unasked") && locked.asks)
        #expect(locked.words(language: .english) == String(format: L10n.t("part.follows.unasked", language: .english), Self.host))
        // One that sees: the list is theirs to read.
        try await signIn(session, holding: Self.seeing)
        await pages.opened(me, in: session)
        #expect(pages.requestsEntry(of: me, in: session)?.locked == nil)

        let author = try #require(DummyPerson(handle: "@me@forum.example", host: Self.forum.host))
        #expect(pages.requestsEntry(of: author, in: session) == nil)
        #expect(pages.lists.said(of: PeopleList(requestsAt: Self.forum.host), in: session) == nil)
    }

    @Test("The line says how many ask as the source's own check of the sign-in last said: the figure whole, in words for one and for none, and words alone where the check said no figure; it does not count down when a request is answered here, is replaced when the check next runs, and is never one another reader's check said")
    func theFigureOnTheLine() async throws {
        func check(_ count: String) -> PageServer.Answer {
            PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me","source":{"note":""\#(count)}}"#)
        }
        let (session, server) = await session(Self.served([Self.who: check(#","follow_requests_count":1204"#)]))
        let pages = ShellPersonPages()
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        try await signIn(session)
        #expect(session.mastodon.asking(host: Self.host) == 1204)
        await pages.opened(me, in: session)
        let entry = try #require(pages.requestsEntry(of: me, in: session))
        #expect(entry.counted == 1204 && entry.words(language: .english) == "1,204 people ask to follow you")
        #expect(entry.words(language: .taiwanese) == "1,204 人請求跟隨你")
        func words(_ counted: Int?, _ language: DummyLanguage) -> String { RequestsEntry(list: Self.requests, counted: counted).words(language: language) }
        #expect(words(1, .english) == "1 person asks to follow you" && words(1, .taiwanese) == "1 人請求跟隨你")
        #expect(words(nil, .english) == "People who ask to follow you")

        // A request accepted here: the figure is the source's, and stays as its check said it.
        await pages.lists.opened(Self.requests, in: session)
        let three = try row("3", of: Self.requests, pages.lists, session)
        await pages.lists.press(.acceptRequest, on: three, of: Self.requests, in: session)
        #expect(ids(Self.requests, pages.lists, session) == ["4"] && pages.requestsEntry(of: me, in: session)?.counted == 1204)
        // The check runs again, and its word replaces the last.
        await server.answer(Self.who, check(#","follow_requests_count":0"#))
        await session.mastodon.learnWho(host: Self.host)
        // Nought, as the check said it: no line at all, no block of About, and nothing for the lamp to stop on.
        #expect(session.mastodon.asking(host: Self.host) == 0 && pages.requestsEntry(of: me, in: session) == nil)
        #expect(pages.about(of: me, in: session)?.blocks.contains(.requests) == false)
        #expect(!pages.walkedIDs(of: me, in: session).contains(RequestsEntry.id))
        #expect(L10n.t("people.requests.entry.none", language: .english) == "people.requests.entry.none", "the sentence for nobody is gone")
        // A check that says no figure: words alone.
        await server.answer(Self.who, check(""))
        await session.mastodon.learnWho(host: Self.host)
        let silent = try #require(pages.requestsEntry(of: me, in: session))
        #expect(silent.counted == nil && silent.words(language: .english) == "People who ask to follow you")
        #expect(pages.walkedIDs(of: me, in: session).contains(RequestsEntry.id), "no figure said is not nobody: the line stands")

        // Another sign-in takes the source and has not been checked: nothing of the first's is said of it.
        await server.answer(Self.who, check(#","follow_requests_count":9"#))
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.mastodon.asking(host: Self.host) == 9)
        // Replaced under the session's feet, as a package read back does: nothing is told of it yet.
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "second", clientID: "c", clientSecret: "s", scopes: Self.follows, asked: Self.follows
        ))
        #expect(session.mastodon.asking(host: Self.host) == nil, "the first reader's figure is not the second's")
        session.mastodon.refresh()
        #expect(session.mastodon.asking(host: Self.host) == nil)
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.mastodon.asking(host: Self.host) == 9, "theirs, once their own check has said")

        // What the check's answer is read as.
        func said(_ body: String) -> Int? { MastodonWho.said(Data(body.utf8), at: Self.host).asking }
        #expect(said(#"{"id":"7","acct":"me","source":{"follow_requests_count":3}}"#) == 3)
        #expect(said(#"{"id":"7","acct":"me"}"#) == nil && said(#"{"id":"7","acct":"me","source":{}}"#) == nil)
        #expect(said(#"{"id":"7","acct":"me","source":{"follow_requests_count":-1}}"#) == nil)
        #expect(said(#"{"id":"7","acct":"me","source":{"follow_requests_count":"3"}}"#) == nil && said(#"{"id":"7","acct":"me","source":"x"}"#) == nil)
        #expect(said(#"{"acct":"me","source":{"follow_requests_count":3}}"#) == nil, "said of an account the check named, or of nobody")
        #expect(MastodonWho.said(Data(#"{"id":"7","acct":"me","source":"x"}"#.utf8), at: Self.host).id == "7", "the rest of the check stands")
    }

    @Test("Somebody who follows the reader is removed from the `…` of their page too, under the divider: offered only where the source last said they follow the reader, asked first with the same question, sent through the same sequence — and what the source answers is how the reader then stands; never on the reader's own page")
    func removingFromTheirPage() async throws {
        let remove = Self.remove(42)
        let (session, server) = await session(Self.served([
            Self.stands([42]): Self.said(Self.standing(42, followedBy: true)),
            remove: PageServer.Answer(body: Self.standing(42, followedBy: false)),
        ]))
        try await signIn(session)
        let acts = ShellPersonPages().acts
        let ada = DummyPerson(Self.ada), page = PersonSaid(source: Self.host, reading: .said(Self.ada))
        await acts.opened(ada, said: page, in: session)
        let follows = try #require(acts.acting(of: ada, said: page, in: session))
        #expect(follows.reading == .said(PersonStanding(accountID: "42", followedBy: true)) && follows.more == [.removeFollower])
        #expect(follows.asksBefore(.removeFollower) && follows.question(before: .removeFollower) == ShellQuestion.about(.removeFollower, "@ada@m.example", at: Self.host))
        #expect(follows.question(before: .removeFollower).title == String(format: L10n.t("person.removeFollower.ask.title"), "@ada@m.example", Self.host))
        // With somebody the reader follows too: Unfollow first, and removal after it — under the divider, since it asks.
        let both = PersonActing(
            source: Self.host, named: "@ada", reading: .said(PersonStanding(accountID: "42", following: true, followedBy: true)), changes: true
        )
        // Changed (#385): unfollowing somebody anyone may follow now asks too, so both are red.
        #expect(both.more == [.unfollow, .removeFollower] && both.asksBefore(.unfollow))
        let menu = both.menu(act: { _ in })
        #expect(menu.items.map(\.name) == [PersonActing.name(.unfollow), PersonActing.name(.removeFollower)])
        #expect(menu.dangers.count == 2)
        // Not where the source did not say they follow the reader, nor to a sign-in that may not change it.
        let not = PersonActing(source: Self.host, named: "@ada", reading: .said(PersonStanding(accountID: "42", following: true)), changes: true)
        let seeing = PersonActing(source: Self.host, named: "@ada", reading: .said(PersonStanding(accountID: "42", followedBy: true)), changes: false)
        #expect(not.more == [.unfollow] && seeing.more.isEmpty && PersonActing(source: Self.host, named: "@ada", reading: .asking, changes: true).more.isEmpty)

        await acts.press(.removeFollower, on: ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands([42]), remove])
        let after = try #require(acts.acting(of: ada, said: page, in: session))
        #expect(after.reading == .said(PersonStanding(accountID: "42")) && after.more.isEmpty && after.missed == nil)
        // No longer said to follow the reader: nothing is offered, and nothing sent.
        await acts.press(.removeFollower, on: ada, said: page, in: session)
        #expect(await asked(server).count == 2)
        // The reader's own page has no standing, and so no `…` at all.
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        #expect(acts.acting(of: me, said: PersonSaid(source: Self.host, reading: .said(Self.me)), in: session) == nil)
        await acts.press(.removeFollower, on: me, said: PersonSaid(source: Self.host, reading: .said(Self.me)), in: session)
        #expect(await asked(server).count == 2)
    }

    @Test("A row's press goes through the one sequence a press on somebody's page does, and is no copy of it; no key is given to any of the three; every sentence is written in all three tables; and a row that accepts lays out at a wide page and across a phone")
    func oneSequenceAndWritten() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        let ui = url.appending(path: "Sources/FediqoUI"), shell = ui.appending(path: "Shell")
        for file in try FileManager.default.contentsOfDirectory(atPath: shell.path) where file != "ShellPersonActs.swift" {
            let text = try String(contentsOf: shell.appending(path: file), encoding: .utf8)
            for call in ["through.answer(", ".removeFollower(", ".answer(accountID"] {
                #expect(!text.contains(call), "\(file) sends an answer to a request by a way of its own")
            }
        }
        let lists = try String(contentsOf: shell.appending(path: "ShellPeople.swift"), encoding: .utf8)
        // Through the sequence, saying what it came to (#314).
        #expect(lists.components(separatedBy: "acts.pressRowCame(").count == 2)
        // A suggestion dismissed is no act on how the reader stands, and has a guard of its own (#315).
        #expect(!lists.contains("PressGuard<String, PersonAct>"), "a row's act has no guard of its own")
        #expect(lists.components(separatedBy: "PressGuard<").count == 2, "one guard, the dismissal's")

        let keys = try String(contentsOf: shell.appending(path: "DummyCommand.swift"), encoding: .utf8)
        #expect(!keys.contains("acceptRequest") && !keys.contains("removeFollower") && !keys.contains("refuseRequest"))

        let written = [
            "person.act.accept", "person.act.accept.spoken", "person.act.refuse", "person.act.removeFollower", "person.act.accept.failed",
            "person.act.refuse.failed", "person.act.removeFollower.failed", "person.refuse.ask.title", "person.refuse.ask.line",
            "person.removeFollower.ask.title", "person.removeFollower.ask.line", "people.requests.entry", "people.title.requests",
            "people.requests.asking", "people.requests.none", "people.requests.entry.count",
        ]
        func places(_ text: String) -> [String] { text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted() }
        let tables = try ["en", "zh-TW", "zh-Hant"].map { name in
            try String(contentsOf: ui.appending(path: "Resources/\(name).lproj/Localizable.strings"), encoding: .utf8)
        }
        for key in written {
            #expect(tables.allSatisfy { $0.components(separatedBy: "\n\"\(key)\" = \"").count == 2 }, "\(key) is written once in each table")
            let english = L10n.t(key, language: .english), taiwanese = L10n.t(key, language: .taiwanese)
            #expect(english != key && taiwanese != key && english != taiwanese && places(english) == places(taiwanese), "\(key)")
        }
        #expect(tables[1] == tables[2])
        for act in PersonAct.allCases where ShellPersonActs.isOfARow(act) {
            #expect(PersonActing.missedWords(act, named: "@a", at: Self.host, language: .english).contains("@a"))
        }

        let person = Person(source: Self.source, accountID: "3", handle: "@a-long-handle-indeed@a-long-host.example", name: "A long name indeed", locked: true)
        let said = PeopleSaid(
            list: Self.requests, signedIn: true, own: true, reading: .said, people: [person],
            acts: [.acceptRequest, .refuseRequest], missed: ["3": "Could not accept the request of @a at m.example."],
            lock: PartWords.Place(kind: .unasked, key: "part.follows.partly.changing")
        )
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 390), (.narrow, 320)] {
                func height<Row: View>(_ row: Row) -> CGFloat {
                    let hosted = NSHostingView(rootView: row.frame(width: width).environment(\.shellLayout, layout).environment(\.colorScheme, scheme))
                    hosted.layoutSubtreeIfNeeded()
                    return hosted.fittingSize.height
                }
                let menu = PeoplePane.menu(for: said, of: person, asks: .constant(nil)) { _ in }
                let plain = height(PersonRow(person: person, menu: menu)), accepting = height(PersonRow(person: person, menu: menu, accept: {}))
                #expect(plain > 0 && accepting >= plain, "\(accepting) against \(plain) at \(width)")
                let pane = PeoplePane(said: said, selectedID: .constant(nil), onOpen: { _ in }, onBack: {})
                let hosted = NSHostingView(rootView: pane.frame(width: width, height: 600).environment(\.shellLayout, layout).environment(\.colorScheme, scheme))
                hosted.layoutSubtreeIfNeeded()
                #expect(hosted.fittingSize == CGSize(width: width, height: 600))
            }
        }
    }
}
