import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #311, the page that is a list of people: what is asked for it and when, what the page is
/// handed in each state, what its row says — and that a source which is not asked who people
/// are has no such page.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), and each ends by
/// itself: a held ask is let go in a `defer`, and by the server after its patience.
@MainActor
@Suite("A list of people as its source gives it", .serialized, .timeLimit(.minutes(1)))
struct PeopleTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let who = "/api/v1/accounts/verify_credentials"

    /// Whose lists: as their source said them — it counts 2,811 followers and four followed.
    private static func ada(hides: Bool = false, followers: Int? = 2811, handle: String = "@ada@far.example") -> Person {
        Person(
            source: source, accountID: "42", handle: handle, name: "Ada",
            tally: Person.Tally(following: 4, followers: followers), hidesLists: hides
        )
    }

    private static let followers = PeopleList(.followers, of: ada())
    /// The first stretch as it is asked, and the stretch after the place a `Link` names.
    private static let first = "/api/v1/accounts/42/followers?limit=80"
    private static func after(_ place: Int) -> String { "\(first)&max_id=\(place)" }

    private static func account(_ id: Int, _ more: String = "") -> String {
        #"{"id":"\#(id)","acct":"p\#(id)","display_name":"Person \#(id)","note":"<p>Says \#(id)</p>"\#(more)}"#
    }

    /// A stretch of people, and where the source says the next begins: **a follow's id**, which
    /// is nobody's in the stretch.
    private static func stretch(_ ids: [Int], next: Int? = nil) -> PageServer.Answer {
        PageServer.Answer(
            body: "[" + ids.map { account($0) }.joined(separator: ",") + "]",
            link: next.map { #"<https://m.example/api/v1/accounts/42/followers?limit=80&max_id=\#($0)>; rel="next""# }
        )
    }

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        let work = SourceWork()
        session.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    private static let token = MastodonToken(host: host, accessToken: "tok", clientID: "c", clientSecret: "s")

    private func signIn(_ session: ShellSession) throws {
        try session.mastodon.tokens.save(Self.token)
        session.mastodon.refresh()
    }

    private func ids(_ pages: ShellPeoplePages, _ session: ShellSession, _ list: PeopleList = followers) -> [String] {
        pages.said(of: list, in: session)?.people.map(\.accountID) ?? []
    }

    // MARK: - What is asked, and when

    @Test("Opening a list asks its source for one stretch — one ask, of eighty at most, listed in the run's record as that, and nothing held — and the page is handed who it gave, in its order, and that more can be read; opened again, nobody is asked")
    func openingAsksOnce() async throws {
        let (session, server, work) = await session([Self.first: Self.stretch([3, 2, 1], next: 19)])
        let pages = ShellPersonPages().lists
        #expect(pages.said(of: Self.followers, in: session) == PeopleSaid(list: Self.followers), "before anything answered")
        #expect(pages.said(of: Self.followers, in: session)?.stateLine(language: .english) == "Asking m.example for this list…")

        await pages.opened(Self.followers, in: session)
        #expect(await server.asked == [Self.first] && ShellPeoplePages.stretchLength == 80)
        let acts = work.record.filter { $0.reached == Self.host }
        #expect(acts.count == 1 && acts.allSatisfy { $0.purpose == .people && $0.source == Self.host })

        let said = try #require(pages.said(of: Self.followers, in: session))
        #expect(said.reading == .said && said.people.map(\.accountID) == ["3", "2", "1"] && said.foot == .more && !said.asking)
        #expect(said.stateLine() == nil && said.nothing() == nil && !said.offersAgain && !said.signedIn && !said.own)
        #expect(pages.walked(Self.followers, in: session) == said.people.map(\.id) && pages.canAskAgain(Self.followers, in: session))
        #expect(pages.person(said.people[1].id, on: Self.followers, in: session)?.accountID == "2")
        #expect(pages.person("nobody", on: Self.followers, in: session) == nil)
        #expect(session.notes.isEmpty)
        #expect(await session.store.held(host: Self.host).isEmpty)

        await pages.opened(Self.followers, in: session)
        #expect(await server.asked.count == 1)
        // The other list of the same person is a page of its own, asked where that list is kept.
        let following = PeopleList(.following, of: Self.ada())
        #expect(following.id != Self.followers.id && following.counted == 4)
        await pages.opened(following, in: session)
        #expect(await server.asked.last == "/api/v1/accounts/42/following?limit=80")
        #expect(pages.said(of: following, in: session)?.reading == .failed && pages.said(of: Self.followers, in: session)?.people.count == 3)
    }

    @Test("Reading on is the foot's press, one stretch a press, from the place the source named — a follow's, which is nobody's in the list; a full last stretch names a next that answers nobody, and that is the end; nobody twice, nothing asked past the end, and only there is it said that the source gave fewer than it counts")
    func readingOnIsPressed() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1], next: 19), Self.after(19): Self.stretch([1, 9, 8], next: 7),
            Self.after(7): Self.stretch([]),
        ])
        let pages = ShellPersonPages().lists
        await pages.opened(Self.followers, in: session)
        #expect(pages.said(of: Self.followers, in: session)?.short == nil, "nothing is said of how many were given before the end")
        await pages.readOn(Self.followers, in: session)
        #expect(await server.asked == [Self.first, Self.after(19)])
        #expect(ids(pages, session) == ["3", "2", "1", "9", "8"] && pages.said(of: Self.followers, in: session)?.foot == .more)

        await pages.readOn(Self.followers, in: session)
        let said = try #require(pages.said(of: Self.followers, in: session))
        #expect(said.people.count == 5 && said.foot == .end && said.short == 2806)
        #expect(said.footWords(.end, language: .english) == "m.example gave 5. It counts 2,811: the rest it does not hold, or does not give.")
        await pages.readOn(Self.followers, in: session)
        #expect(await server.asked.count == 3, "nothing is asked past the end")

        // A stretch that does not come is said at the foot, changes nothing drawn, and a press asks again.
        let (other, flaky, _) = await self.session([Self.first: Self.stretch([3, 2], next: 19)])
        let again = ShellPersonPages().lists
        await again.opened(Self.followers, in: other)
        await again.readOn(Self.followers, in: other)
        #expect(again.said(of: Self.followers, in: other)?.foot == .failed && ids(again, other) == ["3", "2"])
        #expect(PeopleSaid.Foot.failed.presses)
        await flaky.answer(Self.after(19), Self.stretch([1]))
        await again.readOn(Self.followers, in: other)
        #expect(ids(again, other) == ["3", "2", "1"] && again.said(of: Self.followers, in: other)?.foot == .end)
        #expect(await flaky.asked == [Self.first, Self.after(19), Self.after(19)])
    }

    @Test("Asked again, a list is read from the top and what was read before is replaced by what comes; one that fails before anything answered says so with a press, and one that fails after says so beside who it gave, who stand")
    func againIsFromTheTop() async throws {
        let (session, server, _) = await session([:])
        let pages = ShellPersonPages().lists
        await pages.opened(Self.followers, in: session)
        var said = try #require(pages.said(of: Self.followers, in: session))
        #expect(said.reading == .failed && said.offersAgain && said.foot == nil && said.nothing() == nil)
        #expect(said.stateLine(language: .english) == "Could not ask m.example for this list.")
        // Failed, it is not asked again by being opened: the press asks.
        await pages.opened(Self.followers, in: session)
        #expect(await server.asked.count == 1)

        await server.answer(Self.first, Self.stretch([3, 2], next: 19))
        await server.answer(Self.after(19), Self.stretch([1]))
        await pages.again(Self.followers, in: session)
        await pages.readOn(Self.followers, in: session)
        #expect(ids(pages, session) == ["3", "2", "1"])

        await server.answer(Self.first, nil)
        await pages.again(Self.followers, in: session)
        said = try #require(pages.said(of: Self.followers, in: session))
        #expect(said.reading == .said && said.againFailed && said.offersAgain && said.people.count == 3 && said.foot == .end)
        #expect(said.stateLine(language: .english) == "Could not ask m.example again. Who it gave before is still here.")

        await server.answer(Self.first, Self.stretch([5, 3], next: 23))
        await pages.again(Self.followers, in: session)
        said = try #require(pages.said(of: Self.followers, in: session))
        #expect(said.people.map(\.accountID) == ["5", "3"] && said.foot == .more && !said.againFailed && said.stateLine() == nil)
        // And reading on goes by the place the new top named.
        await server.answer(Self.after(23), Self.stretch([2]))
        await pages.readOn(Self.followers, in: session)
        #expect(await server.asked.last == Self.after(23) && ids(pages, session) == ["5", "3", "2"])
    }

    // MARK: - While an ask is on the wire

    @Test("An ask is the lists' and not the pane's: the pane that opened a list leaving does not stop it, it lands for the next visit, and opening again while it is on the wire waits on it and asks nothing more")
    func theAskOutlivesThePane() async throws {
        let (session, server, _) = await session([Self.first: Self.stretch([3, 2, 1])])
        let pages = ShellPersonPages().lists
        await server.hold(Self.first)
        let pane = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.first)
        pane.cancel()
        #expect(pages.said(of: Self.followers, in: session)?.reading == .asking && pages.said(of: Self.followers, in: session)?.asking == true)

        let visit = Task { await pages.opened(Self.followers, in: session) }
        await server.release(Self.first)
        await visit.value
        await pane.value
        let said = try #require(pages.said(of: Self.followers, in: session))
        #expect(said.people.count == 3 && !said.asking && said.foot == .end)
        #expect(await server.asked == [Self.first], "asked once, whoever came and went")
    }

    @Test("An ask that was stopped before it answered leaves a list that is asked again when it is opened, and never one that says Asking for the rest of the run")
    func aStoppedAskIsAskedAgain() async throws {
        let stopped = PageServer.Answer(body: "", cancelled: true)
        let (session, server, _) = await session([Self.first: stopped])
        let pages = ShellPersonPages().lists
        await pages.opened(Self.followers, in: session)
        let left = try #require(pages.said(of: Self.followers, in: session))
        #expect(left.reading == .asking && !left.asking && !left.offersAgain, "nothing is said of an ask that was stopped, and nothing is on the wire")

        await server.answer(Self.first, Self.stretch([3], next: 19))
        await pages.opened(Self.followers, in: session)
        #expect(ids(pages, session) == ["3"])
        #expect(await server.asked == [Self.first, Self.first])
        // A reading-on that was stopped is no failure either: the foot offers the press again.
        await server.answer(Self.after(19), stopped)
        await pages.readOn(Self.followers, in: session)
        #expect(pages.said(of: Self.followers, in: session)?.foot == .more)
        await pages.opened(Self.followers, in: session)
        #expect(await server.asked.count == 3, "settled: opened again, nobody is asked")
    }

    @Test("One ask a press and never two for a list: asking again or reading on while the list is being asked asks nothing; a second press of the foot while a stretch is out asks nothing; and asking again while a stretch is out takes the foot off Reading — that stretch, answered late, does not land")
    func pressedWhileOnTheWire() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2], next: 19), Self.after(19): Self.stretch([1], next: 7), Self.after(7): Self.stretch([0]),
        ])
        let pages = ShellPersonPages().lists
        await server.hold(Self.first)
        let opening = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.first)
        for _ in 0..<3 { await pages.again(Self.followers, in: session) }
        await pages.readOn(Self.followers, in: session)
        #expect(await server.asked == [Self.first], "one ask on the wire, and nothing beside it")
        await server.release(Self.first)
        await opening.value

        // The foot pressed twice: one stretch.
        await server.hold(Self.after(19))
        defer { Task { await server.release(Self.after(19)) } }
        let reading = Task { await pages.readOn(Self.followers, in: session) }
        await server.arrival(of: Self.after(19))
        #expect(pages.said(of: Self.followers, in: session)?.foot == .reading)
        await pages.readOn(Self.followers, in: session)
        #expect(await server.asked == [Self.first, Self.after(19)], "one stretch at a time")

        // `r` while that stretch is out: it is called off, and the list is asked from the top.
        await pages.again(Self.followers, in: session)
        #expect(await server.asked == [Self.first, Self.after(19), Self.first])
        let said = try #require(pages.said(of: Self.followers, in: session))
        #expect(said.people.map(\.accountID) == ["3", "2"] && said.foot == .more, "the foot is no longer Reading")
        // The foot pressed again, while the stretch called off has still not come back.
        let second = Task { await pages.readOn(Self.followers, in: session) }
        await server.arrival(of: Self.after(19), times: 2)
        await server.releaseOne(Self.after(19))
        await reading.value
        #expect(ids(pages, session) == ["3", "2"], "what the stretch called off brings late does not land")
        #expect(pages.said(of: Self.followers, in: session)?.foot == .reading, "nor take the foot off the stretch now out")
        // And the foot reads on as it did.
        await server.release(Self.after(19))
        await second.value
        #expect(ids(pages, session) == ["3", "2", "1"] && pages.said(of: Self.followers, in: session)?.foot == .more)

        // The foot pressed while a list already given is being asked from the top: nothing more.
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let before = await server.asked.count
        let asking = Task { await pages.again(Self.followers, in: session) }
        await server.arrival(of: Self.first, times: 3)
        #expect(pages.said(of: Self.followers, in: session)?.asking == true && ids(pages, session).count == 3, "what it gave stays drawn meanwhile")
        await pages.readOn(Self.followers, in: session)
        #expect(await server.asked.count == before + 1)
        await server.release(Self.first)
        await asking.value
        #expect(ids(pages, session) == ["3", "2"])
    }

    @Test("A list the source answers with nobody and no next has no foot, and what stands in its place is the page's to say from what the account said: hidden where it says it hides, none given beside a count, and nothing called hidden on an empty answer alone")
    func anEmptyAnswer() async throws {
        let (session, server, _) = await session([Self.first: Self.stretch([])])
        let pages = ShellPersonPages().lists
        for (person, words) in [
            (Self.ada(hides: true), "@ada@far.example hides this list."), (Self.ada(), "m.example gives none of them here."),
            (Self.ada(followers: 0), "m.example gave nobody for this list."),
        ] {
            let list = PeopleList(.followers, of: person)
            await pages.again(list, in: session)
            let said = try #require(pages.said(of: list, in: session))
            #expect(said.reading == .said && said.people.isEmpty && said.foot == nil && said.nothing(language: .english) == words)
            await pages.readOn(list, in: session)
        }
        #expect(await server.asked == [Self.first, Self.first, Self.first], "one list, asked once a press and never read on")
        // Nobody in a first stretch that names a next is not the end: the foot offers the press.
        await server.answer(Self.first, Self.stretch([], next: 19))
        await pages.again(Self.followers, in: session)
        let more = try #require(pages.said(of: Self.followers, in: session))
        #expect(more.foot == .more && more.nothing() == nil)
    }

    @Test("Asking a list again calls off the stretch still out for it, so one ask is on the wire for a list: the asker of that stretch is told it was walked away from")
    func againCallsOffTheStretch() async throws {
        let (plain, server, _) = await session([Self.first: Self.stretch([3, 2], next: 19), Self.after(19): Self.stretch([1])])
        let calledOff = CalledOff()
        let door = CancellableDoor(server, heard: calledOff)
        let bare = ShellSession(http: door, store: plain.store, mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: door))
        bare.work = SourceWork()
        bare.sources = plain.sources
        let lists = ShellPersonPages().lists
        await lists.opened(Self.followers, in: bare)
        await server.hold(Self.after(19))
        defer { Task { await server.release(Self.after(19)) } }
        let reading = Task { await lists.readOn(Self.followers, in: bare) }
        await server.arrival(of: Self.after(19))
        await lists.again(Self.followers, in: bare)
        await calledOff.wait()
        #expect(await calledOff.asks == [Self.after(19)], "the stretch, and not the ask from the top")
        await server.release(Self.after(19))
        await reading.value
        #expect(lists.said(of: Self.followers, in: bare)?.people.map(\.accountID) == ["3", "2"])
    }

    @Test("An answer that comes back whole after its ask was superseded — the transfer had ended before it could be called off — lands nowhere: nobody's list not on the reader's, an old stretch not on the list asked again, and neither takes the newer ask for answered")
    func aLateAnswerLandsNowhere() async throws {
        let (session, server, _) = await session([Self.first: Self.stretch([3, 2], next: 19), Self.after(19): Self.stretch([1])])
        let pages = ShellPersonPages().lists
        // A wire that answers whatever became of the asker.
        pages.reaching = { _ in MastodonPeople(http: server, host: Self.host) }
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let unsigned = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.first)
        try signIn(session)
        let signed = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.first, times: 2)
        await server.answer(Self.first, Self.stretch([9, 8, 7]))
        await server.releaseOne(Self.first)
        await unsigned.value
        let waiting = try #require(pages.said(of: Self.followers, in: session))
        #expect(waiting.reading == .asking && waiting.asking && waiting.people.isEmpty, "nobody's answer is not the reader's")
        await server.answer(Self.first, Self.stretch([3, 2], next: 19))
        await server.release(Self.first)
        await signed.value
        #expect(ids(pages, session) == ["3", "2"])

        // A stretch superseded by asking again, and then by a stretch of the list asked again.
        await server.hold(Self.after(19))
        defer { Task { await server.release(Self.after(19)) } }
        let old = Task { await pages.readOn(Self.followers, in: session) }
        await server.arrival(of: Self.after(19))
        await pages.again(Self.followers, in: session)
        let new = Task { await pages.readOn(Self.followers, in: session) }
        await server.arrival(of: Self.after(19), times: 2)
        await server.answer(Self.after(19), Self.stretch([6, 5], next: 4))
        await server.releaseOne(Self.after(19))
        await old.value
        let reading = try #require(pages.said(of: Self.followers, in: session))
        #expect(reading.people.map(\.accountID) == ["3", "2"] && reading.foot == .reading, "the old stretch lands nowhere, and the new one is still out")
        await server.answer(Self.after(19), Self.stretch([1]))
        await server.release(Self.after(19))
        await new.value
        #expect(ids(pages, session) == ["3", "2", "1"] && pages.said(of: Self.followers, in: session)?.foot == .end)
    }

    @Test("The reader's own list is told from anybody's by the id the source's check gave their sign-in — and not by a handle, which another account may be shown under: its being empty is never its being hidden")
    func theReadersOwnList() async throws {
        let (session, _, _) = await session([
            Self.first: Self.stretch([]), "/api/v1/accounts/43/followers?limit=80": Self.stretch([]),
            Self.who: PageServer.Answer(body: #"{"id":"42","acct":"me"}"#),
        ])
        try signIn(session)
        await session.mastodon.learnWho(host: Self.host)
        let pages = ShellPersonPages().lists
        let mine = PeopleList(.followers, of: Self.ada(hides: true, handle: "@me@m.example"))
        let somebody = Person(
            source: Self.source, accountID: "43", handle: "@ada@far.example", name: "Ada", tally: Person.Tally(followers: 2811), hidesLists: true
        )
        let theirs = PeopleList(.followers, of: somebody)
        // Another account under the reader's own handle is not the reader.
        let alike = PeopleList(.followers, of: Person(source: Self.source, accountID: "99", handle: "@me@m.example", name: "Me", hidesLists: true))
        #expect(pages.said(of: alike, in: session)?.own == false)
        await pages.opened(mine, in: session)
        let own = try #require(pages.said(of: mine, in: session))
        #expect(own.own && own.signedIn && own.nothing(language: .english) == "m.example gives this sign-in none of them.")
        await pages.opened(theirs, in: session)
        let other = try #require(pages.said(of: theirs, in: session))
        #expect(!other.own && other.signedIn && other.nothing(language: .english) == "@ada@far.example hides this list.")
    }

    @Test("A list is who the source gave whoever asked: read with no sign-in it is not there for a reader who has since signed in, nor a reader's for somebody signed out — each is asked afresh, as themself, and an answer to the one before, come late, lands nowhere")
    func asWhoeverAsked() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2], next: 19), Self.after(19): Self.stretch([1]),
            Self.who: PageServer.Answer(body: #"{"id":"1","acct":"me"}"#),
        ])
        let pages = ShellPersonPages().lists
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let unsigned = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.first)

        try signIn(session)
        #expect(pages.said(of: Self.followers, in: session) == PeopleSaid(list: Self.followers, signedIn: true), "nobody's list is not the reader's")
        let signed = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.first, times: 2)
        // Nobody's answer comes late: it lands nowhere.
        await server.releaseOne(Self.first)
        await unsigned.value
        #expect(pages.said(of: Self.followers, in: session)?.reading == .asking && ids(pages, session).isEmpty)
        #expect(pages.said(of: Self.followers, in: session)?.asking == true, "nor is the reader's ask taken for answered")
        await server.release(Self.first)
        await signed.value
        #expect(await server.bearers == ["", "Bearer tok"] && ids(pages, session) == ["3", "2"])

        // Who they are there becomes known: the list asked a moment before is the same reader's.
        await session.mastodon.learnWho(host: Self.host)
        #expect(ids(pages, session) == ["3", "2"])
        let settled = await server.asked.filter { $0 == Self.first }.count
        await pages.opened(Self.followers, in: session)
        #expect(await server.asked.filter { $0 == Self.first }.count == settled, "and is not asked again")
        // Named now, it is that reader's and no other's.
        await server.answer(Self.who, PageServer.Answer(body: #"{"id":"2","acct":"you"}"#))
        await session.mastodon.learnWho(host: Self.host)
        #expect(pages.said(of: Self.followers, in: session)?.reading == .asking && pages.walked(Self.followers, in: session).isEmpty)
        await pages.opened(Self.followers, in: session)
        #expect(ids(pages, session) == ["3", "2"])

        // The reader reads on, and signs out while the stretch is out.
        await server.hold(Self.after(19))
        defer { Task { await server.release(Self.after(19)) } }
        let reader = Task { await pages.readOn(Self.followers, in: session) }
        await server.arrival(of: Self.after(19))
        _ = try session.mastodon.tokens.forget(Self.token)
        session.mastodon.refresh()
        #expect(pages.said(of: Self.followers, in: session) == PeopleSaid(list: Self.followers), "the reader's list is not nobody's")
        await pages.readOn(Self.followers, in: session)
        #expect(await server.asked.filter { $0 == Self.after(19) }.count == 1, "nobody has no list to read on")
        let nobody = Task { await pages.opened(Self.followers, in: session) }
        await nobody.value
        await server.release(Self.after(19))
        await reader.value
        #expect(ids(pages, session) == ["3", "2"], "the reader's stretch, come late, is not shown to nobody")
        #expect(await server.bearers.last == "", "and nobody's list was asked as nobody")
    }

    /// Signs whoever is signed in out and `access` in: another account on the same host, which
    /// the source has not named either.
    private func signIn(_ session: ShellSession, as access: String) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) {
            _ = try session.mastodon.tokens.forget(held)
            session.mastodon.refresh()
        }
        try session.mastodon.tokens.save(MastodonToken(host: Self.host, accessToken: access, clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
    }

    @Test("Two readers the source never named are two readers of a list: the second is given nothing of what the first was, whichever press of theirs comes first — the list opening, its foot, asking again, or a press on somebody's page at that source — and the same reader pressing again is asked nothing more")
    func twoUnnamedReaders() async throws {
        let (session, server, _) = await session([Self.first: Self.stretch([3, 2], next: 19), Self.after(19): Self.stretch([1])])
        let people = ShellPersonPages()
        let pages = people.lists
        try signIn(session, as: "first")
        await pages.opened(Self.followers, in: session)
        await pages.opened(Self.followers, in: session)
        #expect(await server.asked == [Self.first] && ids(pages, session) == ["3", "2"], "the same sign-in is asked nothing more")

        // The second presses the foot of what is drawn: nothing is read on from the first's place.
        try signIn(session, as: "second")
        #expect(ShellPersonPages.askedAs(at: Self.host, in: session) == .reader(nil), "no handle tells them apart")
        await server.answer(Self.first, Self.stretch([9, 8], next: 23))
        await pages.readOn(Self.followers, in: session)
        await server.arrival(of: Self.first, times: 2)
        #expect(await server.asked == [Self.first, Self.first], "the press itself asks the list afresh")
        await pages.opened(Self.followers, in: session)
        #expect(await server.asked == [Self.first, Self.first] && ids(pages, session) == ["9", "8"])
        #expect(await server.bearers == ["Bearer first", "Bearer second"])

        // A third presses on somebody's page at that source: the lists of that source go with it.
        try signIn(session, as: "third")
        let bo = DummyPerson(handle: "@bo@m.example", host: Self.host)!
        await people.again(bo, in: session)
        #expect(pages.said(of: Self.followers, in: session) == PeopleSaid(list: Self.followers, signedIn: true), "nothing of the second's is drawn")
        // A fourth asks again, with the third's list still there: it is not kept under theirs.
        await pages.opened(Self.followers, in: session)
        try signIn(session, as: "fourth")
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let asking = Task { await pages.again(Self.followers, in: session) }
        await server.arrival(of: Self.first, times: 4)
        #expect(ids(pages, session).isEmpty, "the third's rows are not drawn while the fourth's are asked for")
        await server.release(Self.first)
        await asking.value
        #expect(await server.bearers.last == "Bearer fourth" && ids(pages, session) == ["9", "8"])
    }

    @Test("A stretch asked by a reader the source never named, come back after another such reader has taken their place, lands nowhere; and signing out lets the reader's lists go and calls the ask still out for one off")
    func theFirstReadersLateStretch() async throws {
        let server = PageServer([Self.first: Self.stretch([3, 2], next: 19), Self.after(19): Self.stretch([1])])
        let off = CalledOff()
        let door = CancellableDoor(server, heard: off)
        let session = ShellSession(http: door, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: door))
        session.work = SourceWork()
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        let pages = ShellPersonPages().lists
        try signIn(session, as: "first")
        await pages.opened(Self.followers, in: session)
        await server.hold(Self.after(19))
        defer { Task { await server.release(Self.after(19)) } }
        let first = Task { await pages.readOn(Self.followers, in: session) }
        await server.arrival(of: Self.after(19))

        try signIn(session, as: "second")
        await pages.opened(Self.followers, in: session)
        await off.wait()
        #expect(await off.asks == [Self.after(19)], "the first's stretch is called off")
        await server.release(Self.after(19))
        await first.value
        let said = try #require(pages.said(of: Self.followers, in: session))
        #expect(said.people.map(\.accountID) == ["3", "2"] && said.foot == .more, "and what it brings late lands nowhere")
        #expect(await server.bearers == ["Bearer first", "Bearer first", "Bearer second"])

        // Signed out with an ask out: it is called off, and the list is nobody's afresh.
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let again = Task { await pages.again(Self.followers, in: session) }
        await server.arrival(of: Self.first, times: 3)
        let held = try #require(try session.mastodon.tokens.token(host: Self.host))
        _ = try session.mastodon.tokens.forget(held)
        session.mastodon.refresh()
        let nobody = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.first, times: 4)
        #expect(await off.asks == [Self.after(19), Self.first])
        await server.release(Self.first)
        await again.value
        await nobody.value
        #expect(await server.bearers.last == "" && pages.said(of: Self.followers, in: session)?.signedIn == false)
        #expect(pages.said(of: Self.followers, in: session)?.people.count == 2)
    }

    @Test("A sign-out the signed-in door confirmed is told to the session only where whoever asks now is still who the ask was made as: an answer come late, after that reader has gone, ends nobody's sign-in")
    func aLateSignOutEndsNobodyElse() async throws {
        let refused = PageServer.Answer(body: #"{"error":"The access token was revoked"}"#, status: 401)
        for gone in [false, true] {
            let (session, server, _) = await session([Self.first: refused, Self.who: refused])
            try signIn(session)
            let pages = ShellPersonPages().lists
            await server.hold(Self.first)
            let asking = Task { await pages.opened(Self.followers, in: session) }
            await server.arrival(of: Self.first)
            if gone {
                _ = try session.mastodon.tokens.forget(Self.token)
                session.mastodon.refresh()
                try session.mastodon.tokens.save(Self.token)
                #expect(ShellPersonPages.askedAs(at: Self.host, in: session) == .nobody)
            }
            await server.release(Self.first)
            await asking.value
            #expect(session.mastodon.ended == (gone ? [] : [Self.host]), "gone: \(gone)")
        }
    }

    @Test("A source that stops handing a list on in order — it names a place it named before, straight away or round a ring — ends the list there, with its own sentence and no press, and is not asked again by the foot; asked from the top, the list reads on again")
    func aSourceNotPaging() async throws {
        for ring in [[19, 19], [19, 7, 19]] {
            var routes = [Self.first: Self.stretch([9], next: ring[0])]
            for (step, place) in ring.dropLast().enumerated() {
                routes[Self.after(place)] = Self.stretch([8 - step], next: ring[step + 1])
            }
            let (session, server, _) = await session(routes)
            let pages = ShellPersonPages().lists
            await pages.opened(Self.followers, in: session)
            for _ in ring { await pages.readOn(Self.followers, in: session) }
            let said = try #require(pages.said(of: Self.followers, in: session))
            #expect(said.foot == .stopped && !PeopleSaid.Foot.stopped.presses && said.short == nil, "\(ring)")
            #expect(said.footWords(.stopped, language: .english) == "m.example stopped handing people on in order. The list ends here.")
            let asked = await server.asked.count
            #expect(asked == ring.count)
            await pages.readOn(Self.followers, in: session)
            #expect(await server.asked.count == asked)
            await server.answer(Self.after(19), Self.stretch([1]))
            await pages.again(Self.followers, in: session)
            await pages.readOn(Self.followers, in: session)
            #expect(pages.said(of: Self.followers, in: session)?.foot == .end, "\(ring)")
        }
    }

    @Test("Only so many lists are kept: one opened long ago is asked again when it is opened again, and one still being asked is never let go")
    func onlySoManyAreKept() async throws {
        var routes: [String: PageServer.Answer] = [:]
        let lists = (0...ShellPeoplePages.kept).map { number in
            PeopleList(.followers, of: Person(source: Self.source, accountID: "\(100 + number)", handle: "@p\(number)@m.example", name: "P"))
        }
        for list in lists { routes["/api/v1/accounts/\(list.accountID)/followers?limit=80"] = Self.stretch([1]) }
        let (session, server, _) = await session(routes)
        let pages = ShellPersonPages().lists
        let held = "/api/v1/accounts/100/followers?limit=80"
        await server.hold(held)
        defer { Task { await server.release(held) } }
        let slow = Task { await pages.opened(lists[0], in: session) }
        await server.arrival(of: held)
        for list in lists.dropFirst() { await pages.opened(list, in: session) }
        #expect(pages.said(of: lists[0], in: session)?.asking == true, "the oldest, still asked, is kept")
        await server.release(held)
        await slow.value
        #expect(pages.said(of: lists[0], in: session)?.people.count == 1)
        // One more opened: the oldest settled one goes, and is asked again when opened again.
        let asked = await server.asked.count
        await pages.opened(lists[2], in: session)
        #expect(await server.asked.count == asked, "kept: drawn from what was answered")
        await pages.opened(Self.followers, in: session)
        #expect(pages.said(of: lists[1], in: session)?.reading == .asking, "let go")
        await pages.opened(lists[1], in: session)
        #expect(await server.asked.count == asked + 2)
    }

    // MARK: - A source that is not asked who people are

    @Test("A source that is not asked who people are has no such page, and one that is gone has none: nothing is handed, nothing is asked, nothing is walked — and the page's files name no kind of source")
    func aForumHasNoSuchList() async throws {
        let (session, server, work) = await session([Self.first: Self.stretch([1])])
        let pages = ShellPersonPages()
        for source in [Self.forum, Source(host: "gone.example", kind: .mastodon)] {
            let list = PeopleList(.followers, of: Person(source: source, accountID: "42", handle: "@bob@\(source.host)", name: "bob"))
            #expect(pages.lists.said(of: list, in: session) == nil && !pages.lists.canAskAgain(list, in: session))
            await pages.lists.opened(list, in: session)
            await pages.lists.again(list, in: session)
            await pages.lists.readOn(list, in: session)
            #expect(pages.lists.walked(list, in: session).isEmpty && pages.lists.person("x", on: list, in: session) == nil)
        }
        #expect(await server.asked.isEmpty && work.record.isEmpty)
        // A forum's author is who they were: handed nothing, asked of nobody, with no page of their own to open.
        let author = DummyPerson(making: Note(
            id: "https://forum.example/bob/1", source: Self.forum, author: "bob", handle: "", body: "",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []
        ))!
        #expect(pages.said(of: author, in: session) == nil && ShellPersonPages.own(at: Self.forum.host, in: session) == nil)
        #expect(ShellPersonPages.source(at: Self.forum.host, in: session) == nil && ShellPersonPages.source(at: Self.host, in: session) == Self.source)
        #expect(PersonHeadSaid.made(of: author, said: nil, tabs: [.posts], held: 0, standing: nil, language: .english).through == "Read through forum.example")

        for file in ["PeoplePane.swift", "PersonRow.swift"] {
            let text = try String(contentsOf: Self.shell.appending(path: file), encoding: .utf8)
            for word in ["ProtocolKind", ".kind", "isForum", ".mastodon", ".discuz", ".discourse", "offers.", "Mastodon"] {
                #expect(!text.contains(word), "\(file) names \(word)")
            }
        }
        let asked = try String(contentsOf: Self.shell.appending(path: "ShellPeople.swift"), encoding: .utf8)
        for word in ["ProtocolKind", ".kind", "isForum", ".discuz", ".discourse", "offers."] {
            #expect(!asked.contains(word), "ShellPeople.swift names \(word)")
        }
        #expect(asked.contains("ShellPersonPages.source(at:"), "the one fact is read where a person's page reads it")
    }

    private static var shell: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI/Shell")
    }

    // MARK: - What the page says

    @Test("The head says whose list it is, by their handle made fit for a line, and what the source counts as that source's figure, written whole — or no figure where it said none")
    func theHead() {
        let en = DummyLanguage.english
        #expect(PeopleSaid.title(Self.followers, language: en) == "Who follows @ada@far.example")
        #expect(PeopleSaid.title(PeopleList(.following, of: Self.ada()), language: en) == "Who @ada@far.example follows")
        #expect(PeopleSaid.counts(Self.followers, language: en) == "m.example counts 2,811")
        #expect(PeopleSaid.counts(PeopleList(.following, of: Self.ada()), language: .taiwanese) == "m.example 算有 4 人")
        #expect(PeopleSaid.counts(PeopleList(.followers, of: Self.ada(followers: nil)), language: en) == nil)
        let turned = PeopleList(.followers, of: Self.ada(handle: "@a\u{202E}da\nx@far.example"))
        #expect(PeopleSaid.title(turned, language: en) == "Who follows @ada x@far.example")
        #expect(turned.handle.contains("\u{202E}"), "kept as sent: it is what the reader's own is told by")
    }

    @Test("A list the source answers with nobody is called hidden only where the account says it hides its lists — and never the reader's own, which its owner is given; beside a count that is not nothing the source gave none of them, with a sign-in named only where there is one; otherwise it gave nobody — and nothing is said while there is more to read or no answer")
    func nobodyGiven() {
        let en = DummyLanguage.english
        func said(_ person: Person, signedIn: Bool = false, own: Bool = false, foot: PeopleSaid.Foot? = nil) -> PeopleSaid {
            PeopleSaid(list: PeopleList(.followers, of: person), signedIn: signedIn, own: own, reading: .said, foot: foot)
        }
        #expect(said(Self.ada(hides: true)).nothing(language: en) == "@ada@far.example hides this list.")
        #expect(said(Self.ada(hides: true, followers: 0)).nothing(language: en) == "@ada@far.example hides this list.")
        // An empty answer alone is never called hidden.
        #expect(said(Self.ada()).nothing(language: en) == "m.example gives none of them here.")
        #expect(said(Self.ada(), signedIn: true).nothing(language: en) == "m.example gives this sign-in none of them.")
        for counted in [0, nil] as [Int?] {
            #expect(said(Self.ada(followers: counted), signedIn: true).nothing(language: en) == "m.example gave nobody for this list.")
        }
        // The reader's own hidden list, given empty, is not its being hidden.
        #expect(said(Self.ada(hides: true), signedIn: true, own: true).nothing(language: en) == "m.example gives this sign-in none of them.")
        #expect(said(Self.ada(hides: true), foot: .more).nothing() == nil && said(Self.ada(hides: true), foot: .failed).nothing() == nil)
        #expect(PeopleSaid(list: Self.followers).nothing() == nil && PeopleSaid(list: Self.followers, reading: .failed).nothing() == nil)
        var some = said(Self.ada(hides: true), foot: .end)
        some.people = [Self.ada()]
        #expect(some.nothing() == nil)
    }

    @Test("The end is the end of what the source gives whoever asked: where it gave fewer than it counts the foot says both figures, written whole, and names a sign-in only where there is one; where it gave as many, or said no figure, that it has sent all it gives — and each foot has its own words, with a press only where a press reads")
    func theFoot() {
        let en = DummyLanguage.english
        let given = (0..<41).map { Person(source: Self.source, accountID: "\($0)", handle: "@p\($0)@m.example", name: "p") }
        var said = PeopleSaid(list: Self.followers, signedIn: true, reading: .said, people: given, foot: .end)
        #expect(said.short == 2770)
        #expect(said.footWords(.end, language: en) == "m.example gave 41. It counts 2,811: the rest it does not hold, or leaves out for this sign-in.")
        #expect(said.footWords(.end, language: .taiwanese) == "m.example 給了 41 人，它算有 2,811 人：其餘的它沒有，或是不給這次登入看。")
        said.signedIn = false
        #expect(said.footWords(.end, language: en) == "m.example gave 41. It counts 2,811: the rest it does not hold, or does not give.")
        said.foot = .more
        #expect(said.short == nil && said.footWords(.more, language: en) == "More people can be read. Press here to read them.")
        #expect(said.footWords(.reading, language: en) == "Reading more people…")
        #expect(said.footWords(.failed, language: en) == "Could not read more people from m.example. Press here to try again.")

        for counted in [41, 12, nil] as [Int?] {
            let whole = PeopleSaid(list: PeopleList(.followers, of: Self.ada(followers: counted)), reading: .said, people: given, foot: .end)
            #expect(whole.short == nil && whole.footWords(.end, language: en) == "No more people: m.example has sent all it gives.")
        }
        let feet = [PeopleSaid.Foot.more, .reading, .end, .failed, .stopped]
        #expect(feet.map(\.presses) == [true, false, false, true, false])
        said.foot = .end
        #expect(Set(feet.map(said.footSymbol)).count == 5 && said.footSymbol(.end) != PeopleSaid(list: Self.followers).footSymbol(.end))
    }

    @Test("Every sentence of the page is written in each language the app speaks, with the places it fills, no figure through a bare number's place, and the two Chinese tables alike")
    func writtenInEveryLanguage() throws {
        let resources = Self.shell.deletingLastPathComponent().appending(path: "Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\"people.") || line.hasPrefix("\"work.purpose.people\"") else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        #expect(keys.count == 57 && keys.contains("people.requests.none") && keys.contains("people.foot.partial.unsigned") && keys.contains("work.purpose.people") && keys.contains("people.found.none"))
        func places(_ text: String) -> [String] {
            text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted()
        }
        for key in keys {
            let written = L10n.t(key, language: .english)
            #expect(written != key && !written.contains("%d") && !written.contains("$d"), "\(key)")
            for language in DummyLanguage.allCases {
                let other = L10n.t(key, language: language)
                #expect(other != key && places(other) == places(written), "\(key) in \(language)")
            }
        }
        let taiwan = try Data(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
        #expect(SourceWork.Purpose.people.isOfTheSource && SourceWork.Purpose.people.symbol != SourceWork.Purpose.person.symbol)
    }

    // MARK: - The row

    @Test("A row says who they are in the words made fit for a line, and the first line of their own words made one line of ours — cut at their first line, cleaned of what turns a line round, and bounded; what kind of account is a pill of ours, and a listener is read all of it as one sentence")
    func theRowsWords() throws {
        let en = DummyLanguage.english
        let plain = try MastodonPeople.person(from: Data(#"{"id":"7","acct":"bo","display_name":"Bo","note":"<p>Counts <b>birds</b><br>and maps</p><p>More below</p>"}"#.utf8), source: Self.source)
        #expect(PersonRow.firstLine(of: plain) == "Counts birds" && plain.words.contains("\n"))
        #expect(PersonRow.pills(of: plain).isEmpty)
        #expect(PersonRow.spoken(plain, language: en) == "Bo, @bo@m.example, Counts birds")

        let every = Person(
            source: Self.source, accountID: "8", handle: "@ev\u{202E}e@far.example", name: "E\u{202E}ve\nL",
            words: "\n\u{202E}turned\u{2066} round\tand on\nsecond", locked: true, sort: .automated
        )
        #expect(PersonRow.firstLine(of: every) == "turned round and on")
        #expect(PersonRow.pills(of: every, language: en) == ["Automated"])
        #expect(PersonRow.pills(of: Person(source: Self.source, accountID: "9", handle: "@g@m.example", name: "g", sort: .group), language: .taiwanese) == ["群組"])
        #expect(PersonRow.spoken(every, language: en) == "Eve L, @eve@far.example, Asks before anyone may follow, Automated, turned round and on")

        let silent = Person(source: Self.source, accountID: "9", handle: "@q@m.example", name: "", words: " \n ")
        #expect(PersonRow.firstLine(of: silent) == nil && PersonRow.spoken(silent, language: en) == "@q@m.example")
        let long = Person(source: Self.source, accountID: "9", handle: "@q@m.example", name: "q", words: String(repeating: "word ", count: 2_000))
        #expect((PersonRow.firstLine(of: long)?.count ?? 0) <= PersonRow.wordsLength + 1)

        // Opened, they are the person a row of their own posts opens: met through the source that listed them.
        let opened = DummyPerson(plain)
        #expect(opened.host == Self.host && opened.handle == "@bo@m.example" && opened.name == "Bo")
        #expect(opened.id == DummyPerson(making: Note(
            id: "https://m.example/bo/1", source: Self.source, author: "Bo", handle: "@bo@m.example", body: "",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []
        ))?.id)
        #expect(DummyPerson(every).name == "Eve L" && DummyPerson(every).handle == every.handle)
    }

    // MARK: - A step of the walk

    @Test("A list of people is one step of the walk: a row opened is the next, leaving it gives the row back, and leaving the list gives back the row it was opened from; the keys that leave, walk and ask again treat it as they treat somebody's page")
    func aStepOfTheWalk() throws {
        let bo = Person(source: Self.source, accountID: "7", handle: "@bo@m.example", name: "Bo")
        var walk = ShellWalk()
        _ = walk.walk(to: .people(Self.followers), from: "post")
        #expect(walk.openedPeople == Self.followers && walk.openedPerson == nil && walk.depth == 1)
        let twice = walk.walk(to: .people(Self.followers), from: "post")
        #expect(!twice, "a step onto the list in front is no step")
        _ = walk.walk(to: .person(DummyPerson(bo)), from: bo.id)
        #expect(walk.openedPeople == nil && walk.openedPerson?.handle == "@bo@m.example")
        let fromPerson = walk.back()
        #expect(fromPerson?.lamp == bo.id && walk.openedPeople == Self.followers)
        let fromList = walk.back()
        #expect(fromList?.lamp == "post" && walk.isEmpty)

        #expect(DummyCommand.walk.contains(.people) && DummyCommand.canWalk(whenOpen: [.people, .selection]))
        #expect(!DummyCommand.canWalk(whenOpen: [.viewer, .people]) && !DummyCommand.canEditTimeline(whenOpen: [.people]))
        #expect(DummyCommand.outermost(of: [.people, .search, .selection]) == .people)
        #expect(FediqoRootView.escapeSees([.people, .selection], place: .account) == [.selection])
        for asked in [true, false] {
            #expect(FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: [.people], personAsked: asked) == asked)
        }
        #expect(!FediqoRootView.canReload(place: .account, editing: false, hasSources: true, open: [.people], personAsked: true))
        var lamp: String? = "second", jump = 0
        let jumped = FediqoRootView.jumpedToTop(in: ["first", "second"], standing: .people(Self.followers), place: .timeline, selected: &lamp, jump: &jump)
        #expect(jumped && lamp == "first" && jump == 1)
        #expect(FediqoRootView.moved(in: ["first", "second"], from: "first", by: 1, open: [.people, .selection]) == "second")
        #expect(TimelinePane.page(.people(Self.followers)) == .opened && TimelinePane.openedID(.people(Self.followers)) == "people:" + Self.followers.id)
    }

    // MARK: - Laid out

    private func laidOut(_ person: Person, width: CGFloat, layout: ShellLayout, scheme: ColorScheme = .light, menu: Bool = false) -> (PersonRowProbe, CGFloat) {
        let probe = PersonRowProbe()
        let asks = Binding<ShellMoreAsk?>(get: { nil }, set: { _ in })
        let row = PersonRow(
            person: person, selected: scheme == .dark,
            menu: menu ? NoticeRow.Menu(more: { ShellMore(items: [.plain("xmark", "Remove", act: {})]) }, asks: asks) : nil,
            probe: probe
        )
        let hosted = NSHostingView(
            rootView: row.frame(width: width).environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
        )
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        return (probe, hosted.fittingSize.height)
    }

    @Test("A person's row is laid out to the width it is given, in light and in dark: the face a post row's size, nothing past the row's edge, their words one line however much they wrote, the pills beside the name on a wide page and on the handle's line on a narrow one, and the row's dots beside the name wide and beside the words narrow")
    func theRowLaidOut() throws {
        let long = String(repeating: "words and more words ", count: 40)
        let wordy = Person(
            source: Self.source, accountID: "7", handle: "@a-rather-long-handle-of-somebody@a-rather-long-instance-name.example",
            name: "Ada Augusta Lovelace of the Analytical Engine and More", words: long + "\nsecond line", locked: true, sort: .automated
        )
        let brief = Person(source: Self.source, accountID: "8", handle: "@bo@m.example", name: "Bo", words: "Hi", sort: .automated)
        let silent = Person(source: Self.source, accountID: "9", handle: "@cy@m.example", name: "Cy")
        for (layout, width, scheme) in [(ShellLayout.wide, CGFloat(720), ColorScheme.light), (.narrow, 390, .dark), (.narrow, 320, .light)] {
            let inside = width - 2 * ShellSpace.pad
            let (probe, height) = laidOut(wordy, width: width, layout: layout, scheme: scheme, menu: true)
            let (other, briefHeight) = laidOut(brief, width: width, layout: layout, scheme: scheme, menu: true)
            #expect(abs(height - briefHeight) < 0.5, "their words are one line at \(width): \(height) against \(briefHeight)")
            for part in [PersonRowProbe.Part.face, .name, .lock, .handle, .words, .pills, .more] {
                let frame = try #require(probe.frames[part], "\(part) was not laid out at \(width)")
                #expect(frame.minX >= -0.5 && frame.maxX <= inside + 0.5 && frame.width > 0, "\(part) runs past the row at \(width)")
            }
            let face = try #require(probe.frames[.face]), name = try #require(probe.frames[.name])
            let handle = try #require(probe.frames[.handle]), words = try #require(probe.frames[.words])
            let pills = try #require(probe.frames[.pills]), more = try #require(probe.frames[.more])
            #expect(face.width == DummyItemRow.Box.avatar && face.height == DummyItemRow.Box.avatar)
            #expect(name.minX > face.maxX && handle.minY >= name.maxY - 0.5 && words.minY >= handle.maxY - 0.5)
            #expect(words.height == (try #require(other.frames[.words])).height, "one line")
            if layout == .narrow {
                #expect(pills.midY > name.maxY && pills.midY < words.minY, "the pills are on the handle's line at \(width)")
                #expect(more.midY > handle.maxY, "the dots are beside the words at \(width)")
            } else {
                #expect(pills.midY < handle.minY && more.midY < handle.minY, "the pills and the dots are beside the name")
                #expect(more.minX >= pills.maxX)
            }
            // Nobody's words, and no dots: two lines, and shorter.
            let (bare, bareHeight) = laidOut(silent, width: width, layout: layout, scheme: scheme)
            #expect(bare.frames[.words] == nil && bare.frames[.pills] == nil && bare.frames[.more] == nil && bare.frames[.lock] == nil)
            #expect(bareHeight > 0 && bareHeight <= height)
            #expect(probe.spoken == PersonRow.spoken(wordy) && bare.spoken == "Cy, @cy@m.example".replacingOccurrences(of: ", ", with: L10n.t("people.row.between")))
        }
    }

    @Test("The head is laid out to its width and never past it: across a phone a handle too long for one line wraps and the head grows taller for it, and the figure's line is there only where the source said one — and the page itself, in each state it has, is built and laid out without a trap")
    func thePageLaidOut() {
        func head(_ list: PeopleList, _ width: CGFloat) -> CGSize {
            let hosted = NSHostingView(rootView: PeopleHead(list: list).frame(width: width))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let wordy = PeopleList(.following, of: Self.ada(handle: "@" + String(repeating: "long ", count: 30) + "@far.example"))
        for width in [CGFloat(720), 320] {
            let short = head(Self.followers, width), long = head(wordy, width)
            #expect(short.width == width && long.width == width, "never past its width at \(width)")
            #expect(short.height > 0 && long.height >= short.height, "\(long.height) against \(short.height) at \(width)")
        }
        #expect(head(wordy, 320).height > head(Self.followers, 320).height && head(wordy, 320).height > head(wordy, 720).height)
        let counted = head(Self.followers, 720).height
        #expect(head(PeopleList(.followers, of: Self.ada(followers: nil)), 720).height < counted, "the figure's line is there only where the source said one")

        let given = (0..<3).map { Person(source: Self.source, accountID: "\($0)", handle: "@p\($0)@m.example", name: "P\($0)", words: "Says \($0)") }
        let longList = PeopleList(.following, of: Self.ada(handle: "@" + String(repeating: "long", count: 30) + "@far.example"))
        let states = [
            PeopleSaid(list: Self.followers),
            PeopleSaid(list: Self.followers, reading: .failed),
            PeopleSaid(list: Self.followers, signedIn: true, reading: .said, againFailed: true, people: given, asking: true, foot: .more),
            PeopleSaid(list: Self.followers, reading: .said, people: given, foot: .end),
            PeopleSaid(list: Self.followers, reading: .said, people: given, foot: .stopped),
            PeopleSaid(list: PeopleList(.followers, of: Self.ada(hides: true)), reading: .said),
            PeopleSaid(list: longList, reading: .said, people: given, foot: .reading),
        ]
        for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 320)] {
            for said in states {
                let pane = PeoplePane(said: said, selectedID: .constant(given[1].id), onOpen: { _ in }, onBack: {})
                    .environment(\.shellLayout, layout)
                let hosted = NSHostingView(rootView: pane.frame(width: width, height: 700))
                hosted.layoutSubtreeIfNeeded()
                #expect(hosted.fittingSize == CGSize(width: width, height: 700))
            }
        }
    }
}
