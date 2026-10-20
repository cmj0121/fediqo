import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #310, #313, on a list of people: a row says how the reader stands to them, as the source
/// last said — what is asked for it, of whom and when, where nobody is asked, what a failure
/// leaves, whose an answer is, and how the row draws it.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made the ask where a check can name it: a held ask is let go by the check, and by a guard
/// when the run has gone still; every deadline is on a clock nobody turns.
@MainActor
@Suite("How the reader stands to the people on a list", .serialized, .watched)
struct PeopleStandingTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    /// A sign-in that reads and sees who the reader follows, and changes nothing.
    private static let seeing = "\(reads) read:follows"
    private static let who = "/api/v1/accounts/verify_credentials"

    private static let ada = Person(
        source: source, accountID: "42", handle: "@ada@far.example", name: "Ada",
        tally: Person.Tally(following: 4, followers: 2811)
    )
    private static let followers = PeopleList(.followers, of: ada)
    private static let first = "/api/v1/accounts/42/followers?limit=80"
    private static let second = "\(first)&max_id=19"

    /// The one ask that names `ids`, as it goes out.
    private static func stands(_ ids: [Int]) -> String {
        "/api/v1/accounts/relationships?" + ids.map { "id%5B%5D=\($0)" }.joined(separator: "&")
    }

    /// The reader themselves, as the source lists them: by the handle it gave their sign-in.
    private static let me = 7

    private static func stretch(_ ids: [Int], next: Int? = nil) -> PageServer.Answer {
        PageServer.Answer(
            body: "[" + ids.map { #"{"id":"\#($0)","acct":"\#($0 == me ? "me" : "p\($0)")","display_name":"Person \#($0)"}"# }.joined(separator: ",") + "]",
            link: next.map { #"<https://m.example/api/v1/accounts/42/followers?limit=80&max_id=\#($0)>; rel="next""# }
        )
    }

    /// One standing in the shape a real server's has (`MastodonStandingCaptures`).
    private static func standing(
        _ id: Int, following: Bool = false, followedBy: Bool = false, requested: Bool = false, muting: Bool = false,
        blocking: Bool = false, blockedBy: Bool = false
    ) -> String {
        #"{"id":"\#(id)","following":\#(following),"showing_reblogs":\#(following),"notifying":false,"languages":null,"followed_by":\#(followedBy),"blocking":\#(blocking),"blocked_by":\#(blockedBy),"muting":\#(muting),"muting_notifications":\#(muting),"muting_expires_at":null,"requested":\#(requested),"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#
    }

    private static func said(_ standings: String...) -> PageServer.Answer {
        PageServer.Answer(body: "[" + standings.joined(separator: ",") + "]")
    }

    private static let down = PageServer.Answer(body: "<html>", status: 500)

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let me = PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#)
        let server = PageServer(routes.merging([Self.who: me]) { one, _ in one })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    /// Signs in, and has the source say who the reader is there.
    private func signIn(
        _ session: ShellSession, as access: String = "tok", holding scopes: String = PeopleStandingTests.seeing, named: Bool = true
    ) async throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: access, clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        if named { await session.mastodon.learnWho(host: Self.host) }
    }

    /// What the server was asked, but for who the reader is.
    private func asked(_ server: PageServer) async -> [String] {
        await server.asked.filter { $0 != Self.who }
    }

    private func stands(_ pages: ShellPeoplePages, _ session: ShellSession) -> [String: PersonStanding] {
        pages.said(of: Self.followers, in: session)?.stands ?? [:]
    }

    // MARK: - What is asked, and when

    @Test("A stretch that lands is asked about once — one ask, naming its people by the ids the source gave, as the reader, through the door the stretch came by and on the run's record as the list's — and each row is handed what the source said of them, and nothing of whoever it said nothing of; opened again, nobody is asked")
    func oneAskAStretch() async throws {
        let (session, server, work) = await session([
            Self.first: Self.stretch([3, 2, 1], next: 19),
            // In no order of the asking, and with no entry for one of them.
            Self.stands([3, 2, 1]): Self.said(Self.standing(1, following: true, muting: true), Self.standing(3, followedBy: true)),
        ])
        try await signIn(session)
        let pages = ShellPersonPages().lists
        #expect(stands(pages, session).isEmpty, "before anything answered")

        await pages.opened(Self.followers, in: session)
        #expect(await asked(server) == [Self.first, Self.stands([3, 2, 1])])
        #expect(await server.bearers.suffix(2) == ["Bearer tok", "Bearer tok"])
        let acts = work.record.filter { $0.reached == Self.host }.suffix(2)
        #expect(acts.count == 2 && acts.allSatisfy { $0.purpose == .people && $0.source == Self.host })

        let said = try #require(pages.said(of: Self.followers, in: session))
        #expect(said.stands == [
            "3": PersonStanding(accountID: "3", followedBy: true),
            "1": PersonStanding(
                accountID: "1", following: true, muting: true, showsBoosts: true, notifies: false, featured: false, mutesNotices: true
            ),
        ])
        #expect(said.reading == .said && said.foot == .more && said.stateLine() == nil && session.notes.isEmpty)
        #expect(PersonRow.standing(said.stands["3"], language: .english) == ["Follows you"])
        #expect(PersonRow.standing(said.stands["1"], language: .english) == ["You follow them", "Muted"])
        #expect(PersonRow.standing(said.stands["2"], language: .english).isEmpty, "the source said nothing of them")

        await pages.opened(Self.followers, in: session)
        #expect(await asked(server).count == 2, "answered: nobody is asked again while the list stands")
    }

    @Test("Reading on asks about the new stretch only, and never again about a row already asked about — nor about somebody a stretch brings a second time; what was said of the rows above stands; and asking the list again from the top asks about its first stretch once more")
    func readingOnAsksOfTheNewOnly() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1], next: 19), Self.second: Self.stretch([1, 9, 8]),
            Self.stands([3, 2, 1]): Self.said(Self.standing(3, followedBy: true)),
            Self.stands([9, 8]): Self.said(Self.standing(9, requested: true), Self.standing(8, blocking: true)),
        ])
        try await signIn(session)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.followers, in: session)
        await pages.readOn(Self.followers, in: session)
        #expect(await asked(server) == [Self.first, Self.stands([3, 2, 1]), Self.second, Self.stands([9, 8])])
        #expect(stands(pages, session) == [
            "3": PersonStanding(accountID: "3", followedBy: true), "9": PersonStanding(accountID: "9", requested: true),
            "8": PersonStanding(accountID: "8", blocking: true),
        ])
        await pages.readOn(Self.followers, in: session)
        await pages.opened(Self.followers, in: session)
        #expect(await asked(server).count == 4, "the end: nothing more is asked")

        // From the top: the list is read again whole, and its people asked about afresh.
        await server.answer(Self.stands([3, 2, 1]), Self.said(Self.standing(3, following: true, followedBy: true)))
        await pages.again(Self.followers, in: session)
        #expect(await asked(server).suffix(2) == [Self.first, Self.stands([3, 2, 1])])
        #expect(stands(pages, session) == ["3": PersonStanding(accountID: "3", following: true, followedBy: true, showsBoosts: true, notifies: false, featured: false)])
    }

    @Test("Asked again from the top, what the source said before stands until it answers; its answer is then its whole word of whoever it named — somebody it now says nothing of, or of whom its entry cannot be read, loses their word, and the others have what it says now; and an ask that fails takes no word away")
    func anAnswerIsTheSourcesWholeWord() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([4, 3, 2, 1]),
            Self.stands([4, 3, 2, 1]): Self.said(
                Self.standing(4, muting: true), Self.standing(3, followedBy: true), Self.standing(2, blocking: true),
                Self.standing(1, following: true)
            ),
        ])
        try await signIn(session)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.followers, in: session)
        let before = stands(pages, session)
        #expect(Set(before.keys) == ["4", "3", "2", "1"])

        await server.hold(Self.stands([4, 3, 2, 1]))
        defer { Task { await server.release(Self.stands([4, 3, 2, 1])) } }
        let stands4321Guard = watching("the ask of \(Self.stands([4, 3, 2, 1])), held at its server") { await server.release(Self.stands([4, 3, 2, 1])) }
        defer { stands4321Guard.cancel() }
        let again = Task { await pages.again(Self.followers, in: session) }
        await server.arrival(of: Self.stands([4, 3, 2, 1]), times: 2, by: again)
        #expect(stands(pages, session) == before, "until the source answers again")
        // No entry for one, an entry that leaves a part out for another, and a new word of a third.
        let partial = Self.standing(4, muting: true).replacingOccurrences(of: #""following":false,"#, with: "")
        await server.answer(Self.stands([4, 3, 2, 1]), Self.said(partial, Self.standing(3, following: true, followedBy: true), Self.standing(1, following: true)))
        await server.release(Self.stands([4, 3, 2, 1]))
        await again.value
        let now = [
            "3": PersonStanding(accountID: "3", following: true, followedBy: true, showsBoosts: true, notifies: false, featured: false), "1": PersonStanding(accountID: "1", following: true, showsBoosts: true, notifies: false, featured: false),
        ]
        #expect(stands(pages, session) == now, "nothing is said of 2 and of 4 any longer")

        await server.answer(Self.stands([4, 3, 2, 1]), Self.down)
        await pages.again(Self.followers, in: session)
        #expect(stands(pages, session) == now, "a failure takes nothing away")
    }

    @Test("A stretch longer than one ask names is asked about in one ask after another, of eighty at most each, and nobody in it is left unasked")
    func aStretchLongerThanOneAsk() async throws {
        let ids = Array(101 ... 181)
        let (session, server, _) = await session([
            Self.first: Self.stretch(ids),
            Self.stands(Array(ids.prefix(80))): Self.said(Self.standing(101, followedBy: true)),
            Self.stands([181]): Self.said(Self.standing(181, blocking: true)),
        ])
        try await signIn(session)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.followers, in: session)
        #expect(MastodonStanding.most == 80)
        #expect(await asked(server) == [Self.first, Self.stands(Array(ids.prefix(80))), Self.stands([181])])
        #expect(stands(pages, session) == [
            "101": PersonStanding(accountID: "101", followedBy: true), "181": PersonStanding(accountID: "181", blocking: true),
        ])
    }

    // MARK: - Where nobody is asked

    @Test("Nobody is asked how the reader stands where nobody is signed in, where the sign-in does not see who the reader follows, where the source has not named the reader, about the reader's own row, or at a forum — the rows are as they were")
    func nobodyAskedWhereNobodyIsTold() async throws {
        let routes = [
            Self.first: Self.stretch([3, Self.me, 1]),
            Self.stands([3, 1]): Self.said(Self.standing(3, followedBy: true)),
            Self.stands([3, Self.me, 1]): Self.said(Self.standing(3, followedBy: true), Self.standing(Self.me)),
        ]
        let (unsigned, nobody, _) = await session(routes)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.followers, in: unsigned)
        #expect(await asked(nobody) == [Self.first])
        let plain = try #require(pages.said(of: Self.followers, in: unsigned))
        #expect(plain.reading == .said && plain.people.map(\.accountID) == ["3", "7", "1"] && plain.stands.isEmpty)

        var signed = plain
        signed.signedIn = true
        for (scopes, named) in [(Self.reads, true), (Self.seeing, false)] {
            let (session, server, _) = await session(routes)
            try await signIn(session, holding: scopes, named: named)
            let pages = ShellPersonPages().lists
            await pages.opened(Self.followers, in: session)
            #expect(await asked(server) == [Self.first], "holding \(scopes), named \(named)")
            #expect(pages.said(of: Self.followers, in: session) == signed)
        }

        // The reader's own row is named in no ask, and a stretch of nobody else asks nothing.
        let (session, server, _) = await session(routes)
        try await signIn(session)
        let own = ShellPersonPages().lists
        await own.opened(Self.followers, in: session)
        #expect(await asked(server) == [Self.first, Self.stands([3, 1])])
        #expect(stands(own, session) == ["3": PersonStanding(accountID: "3", followedBy: true)])
        await server.answer(Self.first, Self.stretch([Self.me]))
        await own.again(Self.followers, in: session)
        #expect(await asked(server) == [Self.first, Self.stands([3, 1]), Self.first] && stands(own, session).isEmpty)

        let board = PeopleList(.followers, of: Person(source: Self.forum, accountID: "42", handle: "@bob@forum.example", name: "bob"))
        await own.opened(board, in: session)
        #expect(await asked(server).count == 3 && own.said(of: board, in: session) == nil)
    }

    // MARK: - An ask that fails, or is not answered

    @Test("An ask that fails, is answered with what cannot be read, or is still out leaves the rows exactly as they are with nobody asked: no pill, no line, nothing said and nobody signed out; it is not made again by the list opening or by reading on, which asks about its own stretch — only asking from the top asks again")
    func aFailedAskLeavesTheRows() async throws {
        let (unsigned, _, _) = await session([Self.first: Self.stretch([3, 2, 1], next: 19)])
        let untold = ShellPersonPages().lists
        await untold.opened(Self.followers, in: unsigned)
        var asIs = try #require(untold.said(of: Self.followers, in: unsigned))
        asIs.signedIn = true

        for answer in [Self.down, PageServer.Answer(body: "<html>"), PageServer.Answer(body: #"{"error":"no"}"#, status: 403)] {
            let (session, server, _) = await session([
                Self.first: Self.stretch([3, 2, 1], next: 19), Self.second: Self.stretch([9]),
                Self.stands([3, 2, 1]): answer, Self.stands([9]): Self.said(Self.standing(9, followedBy: true)),
            ])
            try await signIn(session)
            let pages = ShellPersonPages().lists
            await pages.opened(Self.followers, in: session)
            #expect(pages.said(of: Self.followers, in: session) == asIs, "\(answer.status) \(answer.body)")
            #expect(session.notes.isEmpty && session.mastodon.signedInHosts.contains(Self.host))

            await pages.opened(Self.followers, in: session)
            await pages.readOn(Self.followers, in: session)
            #expect(await asked(server) == [Self.first, Self.stands([3, 2, 1]), Self.second, Self.stands([9])])
            #expect(stands(pages, session) == ["9": PersonStanding(accountID: "9", followedBy: true)])

            await server.answer(Self.stands([3, 2, 1]), Self.said(Self.standing(2, blocking: true)))
            await pages.again(Self.followers, in: session)
            #expect(stands(pages, session) == ["2": PersonStanding(accountID: "2", blocking: true)])
        }

        // Still out: the list is the source's word already, and its rows say nothing yet.
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1], next: 19), Self.stands([3, 2, 1]): Self.said(Self.standing(3, followedBy: true)),
        ])
        try await signIn(session)
        let pages = ShellPersonPages().lists
        await server.hold(Self.stands([3, 2, 1]))
        defer { Task { await server.release(Self.stands([3, 2, 1])) } }
        let stands321Guard = watching("the ask of \(Self.stands([3, 2, 1])), held at its server") { await server.release(Self.stands([3, 2, 1])) }
        defer { stands321Guard.cancel() }
        let opening = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.stands([3, 2, 1]), by: opening)
        #expect(pages.said(of: Self.followers, in: session) == asIs)
        await server.release(Self.stands([3, 2, 1]))
        await opening.value
        #expect(stands(pages, session) == ["3": PersonStanding(accountID: "3", followedBy: true)])
    }

    // MARK: - Whose an answer is

    @Test("An answer is taken only by the reading of the list it was asked for: one about the list as it was read before it was asked again from the top, come late, is written nowhere — and the answer to the newer ask is what stands")
    func aLateAnswerAboutAnEarlierReading() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1], next: 19), Self.second: Self.stretch([9]),
            Self.stands([9]): Self.said(Self.standing(9)),
        ])
        try await signIn(session)
        let pages = ShellPersonPages().lists
        await server.hold(Self.stands([3, 2, 1]))
        defer { Task { await server.release(Self.stands([3, 2, 1])) } }
        let stands321Guard = watching("the ask of \(Self.stands([3, 2, 1])), held at its server") { await server.release(Self.stands([3, 2, 1])) }
        defer { stands321Guard.cancel() }
        let old = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.stands([3, 2, 1]), by: old)
        // Reading on takes the list's one ask over, so the first stretch's is called off by nobody.
        await pages.readOn(Self.followers, in: session)
        let new = Task { await pages.again(Self.followers, in: session) }
        await server.arrival(of: Self.stands([3, 2, 1]), times: 2, by: new)

        await server.answer(Self.stands([3, 2, 1]), Self.said(Self.standing(3, followedBy: true)))
        await server.releaseOne(Self.stands([3, 2, 1]))
        await old.value
        #expect(stands(pages, session).isEmpty, "the answer about the earlier reading lands nowhere")

        await server.answer(Self.stands([3, 2, 1]), Self.said(Self.standing(3, following: true)))
        await server.release(Self.stands([3, 2, 1]))
        await new.value
        #expect(stands(pages, session) == ["3": PersonStanding(accountID: "3", following: true, showsBoosts: true, notifies: false, featured: false)])
    }

    @Test("An answer is taken only by the reader it was asked for: where the reader changed while it was out, it is written nowhere — not on the list the next reader was given — and a stretch that lands after its reader changed is asked about for nobody")
    func aLateAnswerForAnotherReader() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1], next: 19), Self.second: Self.stretch([9]),
            Self.stands([9]): Self.said(Self.standing(9)),
        ])
        try await signIn(session, as: "first")
        let pages = ShellPersonPages().lists
        await server.hold(Self.stands([3, 2, 1]))
        defer { Task { await server.release(Self.stands([3, 2, 1])) } }
        let stands321Guard = watching("the ask of \(Self.stands([3, 2, 1])), held at its server") { await server.release(Self.stands([3, 2, 1])) }
        defer { stands321Guard.cancel() }
        let old = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.stands([3, 2, 1]), by: old)
        await pages.readOn(Self.followers, in: session)

        try await signIn(session, as: "second")
        let new = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.stands([3, 2, 1]), times: 2, by: new)
        #expect(await server.bearers.last == "Bearer second")
        await server.answer(Self.stands([3, 2, 1]), Self.said(Self.standing(3, followedBy: true)))
        await server.releaseOne(Self.stands([3, 2, 1]))
        await old.value
        #expect(stands(pages, session).isEmpty, "what the first reader was told is not the second's")

        await server.answer(Self.stands([3, 2, 1]), Self.said(Self.standing(3, blocking: true)))
        await server.release(Self.stands([3, 2, 1]))
        await new.value
        #expect(stands(pages, session) == ["3": PersonStanding(accountID: "3", blocking: true)])

        // A stretch still out when its reader changes: it lands for nobody, and asks about nobody.
        let (other, late, _) = await self.session([
            Self.first: Self.stretch([3, 2, 1]), Self.stands([3, 2, 1]): Self.said(Self.standing(3, followedBy: true)),
        ])
        try await signIn(other, as: "first")
        let lists = ShellPersonPages().lists
        await late.hold(Self.first)
        defer { Task { await late.release(Self.first) } }
        let lateFirstGuard = watching("the ask of \(Self.first), held at its server") { await late.release(Self.first) }
        defer { lateFirstGuard.cancel() }
        let opening = Task { await lists.opened(Self.followers, in: other) }
        await late.arrival(of: Self.first, by: opening)
        try await signIn(other, as: "second")
        await late.release(Self.first)
        await opening.value
        #expect(await asked(late) == [Self.first], "nobody is asked how the first reader stands")
        #expect(lists.said(of: Self.followers, in: other)?.stands.isEmpty == true)
    }

    @Test("A sign-out the signed-in door confirmed while asking how the reader stands is told to the session, although the list was read from the top meanwhile and the answer itself lands nowhere")
    func aSignOutLearnedLateIsTold() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1], next: 19), Self.second: Self.stretch([9]),
            Self.stands([9]): Self.said(Self.standing(9)),
        ])
        try await signIn(session)
        let pages = ShellPersonPages().lists
        await server.hold(Self.stands([3, 2, 1]))
        defer { Task { await server.release(Self.stands([3, 2, 1])) } }
        let stands321Guard = watching("the ask of \(Self.stands([3, 2, 1])), held at its server") { await server.release(Self.stands([3, 2, 1])) }
        defer { stands321Guard.cancel() }
        let old = Task { await pages.opened(Self.followers, in: session) }
        await server.arrival(of: Self.stands([3, 2, 1]), by: old)
        await pages.readOn(Self.followers, in: session)
        let new = Task { await pages.again(Self.followers, in: session) }
        await server.arrival(of: Self.stands([3, 2, 1]), times: 2, by: new)
        #expect(session.mastodon.ended.isEmpty)

        let refused = PageServer.Answer(body: #"{"error":"The access token was revoked"}"#, status: 401)
        await server.answer(Self.stands([3, 2, 1]), refused)
        await server.answer(Self.who, refused)
        await server.releaseOne(Self.stands([3, 2, 1]))
        await old.value
        #expect(session.mastodon.ended == [Self.host], "told by the ask about the earlier reading")
        await server.release(Self.stands([3, 2, 1]))
        await new.value
    }

    // MARK: - Drawn

    @Test("A row says how the reader stands in the words their page says it in, in its order and in both languages, after what kind of account it is; a listener is read them between the handle and their words; and a row handed nothing, or only that they block the reader, says nothing more than it did")
    func theRowsWords() {
        let bot = Person(source: Self.source, accountID: "8", handle: "@bo@m.example", name: "Bo", words: "Hi", sort: .automated)
        let every = PersonStanding(accountID: "8", following: true, followedBy: true, requested: true, muting: true, blocking: true, showsBoosts: true, notifies: false)
        #expect(PersonRow.standing(every, language: .english) == ["Follows you", "You follow them", "Asked", "Muted", "Blocked"])
        #expect(PersonRow.standing(every, language: .taiwanese) == ["跟隨你", "你跟隨他們", "已請求", "已靜音", "已封鎖"])
        let page = PersonActing(source: Self.host, named: "@bo", reading: .said(every), changes: true)
        #expect(PersonRow.standing(every, language: .english) == page.pills(language: .english), "their page's own words")

        let follows = PersonStanding(accountID: "8", followedBy: true)
        #expect(PersonRow.spoken(bot, stands: follows, language: .english) == "Bo, @bo@m.example, Automated, Follows you, Hi")
        for none in [nil, PersonStanding(accountID: "8"), PersonStanding(accountID: "8", blockedBy: true)] {
            #expect(PersonRow.standing(none, language: .english).isEmpty)
            #expect(PersonRow.spoken(bot, stands: none, language: .english) == PersonRow.spoken(bot, language: .english))
        }
    }

    private func laidOut(_ person: Person, stands: PersonStanding?, width: CGFloat, layout: ShellLayout, scheme: ColorScheme) -> (PersonRowProbe, CGFloat) {
        let probe = PersonRowProbe()
        let asks = Binding<ShellMoreAsk?>(get: { nil }, set: { _ in })
        let row = PersonRow(
            person: person, stands: stands, selected: scheme == .dark,
            menu: NoticeRow.Menu(more: { ShellMore(items: [.plain("xmark", "Remove", act: {})]) }, asks: asks), probe: probe
        )
        let hosted = NSHostingView(
            rootView: row.frame(width: width).environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
        )
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        return (probe, hosted.fittingSize.height)
    }

    @Test("How the reader stands is laid out with the row, in light and in dark, and never past its edge: beside the name on a wide page; on a narrow one beside the handle where it fits whole, and under the handle where it does not, the row growing taller for it — and a row handed nothing is laid out as it was")
    func theRowLaidOut() throws {
        let bo = Person(source: Self.source, accountID: "8", handle: "@bo@m.example", name: "Bo", words: "Hi")
        let wordy = Person(
            source: Self.source, accountID: "7", handle: "@a-rather-long-handle-of-somebody@a-rather-long-instance-name.example",
            name: "Ada Augusta Lovelace of the Analytical Engine and More", words: "Hi", sort: .automated
        )
        let one = PersonStanding(accountID: "8", followedBy: true)
        let many = PersonStanding(accountID: "7", following: true, followedBy: true, muting: true, blocking: true, showsBoosts: true, notifies: false)
        for (layout, width, scheme) in [(ShellLayout.wide, CGFloat(720), ColorScheme.light), (.narrow, 390, .dark), (.narrow, 320, .light)] {
            let inside = width - 2 * ShellSpace.pad
            let (bare, bareHeight) = laidOut(bo, stands: nil, width: width, layout: layout, scheme: scheme)
            let (brief, briefHeight) = laidOut(bo, stands: one, width: width, layout: layout, scheme: scheme)
            let (full, fullHeight) = laidOut(wordy, stands: many, width: width, layout: layout, scheme: scheme)
            for (probe, parts) in [(brief, [PersonRowProbe.Part.pills, .handle, .name, .more]), (full, [.pills, .handle, .name, .more])] {
                for part in parts {
                    let frame = try #require(probe.frames[part], "\(part) was not laid out at \(width)")
                    #expect(frame.minX >= -0.5 && frame.maxX <= inside + 0.5 && frame.width > 0, "\(part) runs past the row at \(width)")
                }
            }
            let told = try #require(brief.frames[.pills]), beside = try #require(brief.frames[layout == .narrow ? .handle : .name])
            #expect(bare.frames[.pills] == nil && bare.frames[.stands] == nil, "handed nothing, nothing is drawn at \(width)")
            // A row with one pill of another sort — what kind of account — is as tall.
            let bot = Person(source: Self.source, accountID: "8", handle: "@bo@m.example", name: "Bo", words: "Hi", sort: .automated)
            let (_, pilled) = laidOut(bot, stands: nil, width: width, layout: layout, scheme: scheme)
            #expect(brief.frames[.stands] == nil, "one pill fits on the line at \(width)")
            #expect(abs(briefHeight - pilled) < 0.5 && briefHeight >= bareHeight, "\(briefHeight) against \(pilled) at \(width)")
            #expect(told.midY > beside.minY && told.midY < beside.maxY && told.minX >= beside.maxX - 0.5)
            if layout == .narrow {
                let under = try #require(full.frames[.stands], "no room beside the handle at \(width)")
                let handle = try #require(full.frames[.handle])
                #expect(under.minY >= handle.maxY - 0.5 && under.minX >= -0.5 && under.maxX <= inside + 0.5)
                #expect(fullHeight > briefHeight, "the row grows for it at \(width)")
            } else {
                let name = try #require(full.frames[.name]), pills = try #require(full.frames[.pills])
                #expect(full.frames[.stands] == nil && abs(fullHeight - briefHeight) < 0.5)
                #expect(pills.minX >= name.maxX - 0.5 && name.width > 0, "beside the name, which keeps some room")
            }
            #expect(full.spoken == PersonRow.spoken(wordy, stands: many) && bare.spoken == PersonRow.spoken(bo))
        }
    }

    @Test("The page hands each row what its list says of that person and nothing of anybody else, and is laid out with them")
    func thePageHandsEachRowItsOwn() {
        let given = (0 ..< 3).map { Person(source: Self.source, accountID: "\($0)", handle: "@p\($0)@m.example", name: "P\($0)") }
        var said = PeopleSaid(list: Self.followers, signedIn: true, reading: .said, people: given, foot: .end)
        said.stands = ["1": PersonStanding(accountID: "1", following: true, followedBy: true, muting: true, blocking: true, showsBoosts: true, notifies: false)]
        for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 320)] {
            let pane = PeoplePane(said: said, selectedID: .constant(given[1].id), onOpen: { _ in }, onBack: {})
                .environment(\.shellLayout, layout)
            let hosted = NSHostingView(rootView: pane.frame(width: width, height: 700))
            hosted.layoutSubtreeIfNeeded()
            #expect(hosted.fittingSize == CGSize(width: width, height: 700))
        }
        #expect(given.map { PersonRow.standing(said.stands[$0.accountID], language: .english).count } == [0, 4, 0])
    }
}
