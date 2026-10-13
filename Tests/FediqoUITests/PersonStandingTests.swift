import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #310, #313, on somebody's page: how the reader stands to them as the source last said, the
/// press that follows them and the `…` that stops — what is asked for it and when, how a press
/// is guarded against a read on its way, and what stands there where the sign-in was not given
/// who the reader follows.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), and each ends by
/// itself: a held ask is let go in a `defer`, and by the server after its patience.
@MainActor
@Suite("How the reader stands to somebody, and following them, on their page", .serialized, .timeLimit(.minutes(1)))
struct PersonStandingTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let seeing = "\(reads) read:follows"
    /// A sign-in that reads and holds who the reader follows, and nothing else that acts.
    private static let follows = "\(seeing) write:follows"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let stands = "/api/v1/accounts/relationships?id%5B%5D=42"
    private static let follow = "/api/v1/accounts/42/follow"
    private static let unfollow = "/api/v1/accounts/42/unfollow"

    private static let ada = DummyPerson(handle: "@ada@m.example", host: host)!
    private static let me = DummyPerson(handle: "@me@m.example", host: host)!

    /// One standing in the shape a real server's has (`MastodonStandingCaptures`), made up
    /// here with the parts a check names.
    private static func standing(
        following: Bool = false, followedBy: Bool = false, requested: Bool = false, muting: Bool = false,
        until: String? = nil, blocking: Bool = false, blockedBy: Bool = false
    ) -> String {
        #"{"id":"42","following":\#(following),"showing_reblogs":\#(following),"notifying":false,"languages":null,"followed_by":\#(followedBy),"blocking":\#(blocking),"blocked_by":\#(blockedBy),"muting":\#(muting),"muting_notifications":\#(muting),"muting_expires_at":\#(until.map { "\"\($0)\"" } ?? "null"),"requested":\#(requested),"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#
    }

    private static func said(_ standing: String) -> PageServer.Answer { PageServer.Answer(body: "[\(standing)]") }
    private static func answered(_ standing: String) -> PageServer.Answer { PageServer.Answer(body: standing) }
    /// As a real server refuses a follow that is not allowed (`MastodonStandingCaptures.notAllowed`).
    private static let refused = PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403)
    private static let down = PageServer.Answer(body: "<html>", status: 500)

    /// What their page says of them: the source's own account of somebody, read as it is read.
    private static func page(_ more: String = "", acct: String = "ada") throws -> PersonSaid {
        let person = try MastodonPeople.person(
            from: Data(#"{"id":"42","acct":"\#(acct)","display_name":"Ada","statuses_count":3\#(more)}"#.utf8), source: source
        )
        return PersonSaid(source: host, reading: .said(person), posts: [])
    }

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let me = PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#)
        let server = PageServer(routes.merging([Self.who: me]) { one, _ in one })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
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

    /// Signs in, and has the source say who the reader is there: nobody stands to anybody
    /// until it has.
    private func signIn(
        _ session: ShellSession, as access: String = "tok", holding scopes: String = PersonStandingTests.follows,
        asked: String? = nil, refused: String? = nil, named: Bool = true
    ) async throws {
        try signOut(session)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: access, clientID: "c", clientSecret: "s", scopes: scopes, asked: asked ?? scopes,
            refused: refused
        ))
        session.mastodon.refresh()
        if named { await session.mastodon.learnWho(host: Self.host) }
    }

    /// What the server was asked, but for who the reader is.
    private func asked(_ server: PageServer) async -> [String] {
        await server.asked.filter { $0 != Self.who }
    }

    private func acts() -> ShellPersonActs { ShellPersonPages().acts }

    // MARK: - As the source last said

    @Test("Following, followed by, asked, muted, muted until a day, and blocked each show as a pill in the order they are drawn, in both languages; blocked by them is said in words as decided, and Follow is not offered")
    func shownAsTheSourceSaid() {
        func acting(_ standing: PersonStanding, asksFirst: Bool = false) -> PersonActing {
            PersonActing(source: Self.host, named: "@ada", asksFirst: asksFirst, reading: .said(standing), changes: true)
        }
        let nobody = acting(PersonStanding(accountID: "42"))
        #expect(nobody.pills(language: .english).isEmpty && nobody.blockedWords() == nil)
        #expect(nobody.press == .follow && nobody.more.isEmpty)

        let until = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")
        let every = acting(PersonStanding(
            accountID: "42", following: true, followedBy: true, requested: true, muting: true, mutedUntil: until, blocking: true
        ))
        let english = every.pills(language: .english)
        #expect(english.count == 5)
        #expect(Array(english.prefix(3)) == ["Follows you", "You follow them", "Asked"])
        #expect(english[3].hasPrefix("Muted until ") && english[3].contains("14") && english[4] == "Blocked")
        let taiwanese = every.pills(language: .taiwanese)
        #expect(Array(taiwanese.prefix(3)) == ["跟隨你", "你跟隨他們", "已請求"] && taiwanese[3].hasPrefix("靜音到 ") && taiwanese[4] == "已封鎖")
        #expect(acting(PersonStanding(accountID: "42", muting: true)).pills(language: .english) == ["Muted"])

        let blockedBy = acting(PersonStanding(accountID: "42", blockedBy: true))
        #expect(blockedBy.blockedWords(language: .english) == "@ada has blocked you. m.example shows you none of their posts.")
        #expect(blockedBy.blockedWords(language: .taiwanese) == "@ada 封鎖了你。m.example 不給你看他們的任何貼文。")
        #expect(blockedBy.press == nil, "Follow is not offered")
        #expect(blockedBy.pills(language: .english).isEmpty)

        // Nor where the reader blocks them, where they are followed or asked already, where
        // they moved or are gone, or before the source has said.
        #expect(acting(PersonStanding(accountID: "42", blocking: true)).press == nil)
        #expect(acting(PersonStanding(accountID: "42", following: true)).press == nil)
        #expect(acting(PersonStanding(accountID: "42", requested: true)).press == nil)
        var moved = nobody
        moved.followable = false
        #expect(moved.press == nil)
        for unsaid in [PersonActing.Reading.asking, .unsaid, .failed] {
            let waiting = PersonActing(source: Self.host, named: "@ada", reading: unsaid, changes: true)
            #expect(waiting.press == nil && waiting.pills().isEmpty && waiting.more.isEmpty, "\(unsaid)")
        }
    }

    @Test("Where a signed-in reader is given none of the posts a source counts, the posts' place says only that the source gives this sign-in none of them: where they block the reader, and where how the reader stands is not known — the follows part not held, the ask out, failed, or answered with nothing; where the source has said how the reader stands and it is no block, and where nobody stands to them here, the place says what it gave and counts, as before")
    func whatStandsWherePostsWould() throws {
        let said = try Self.page()
        let decided = "m.example gives this sign-in none of them."
        func acting(_ reading: PersonActing.Reading?, lock: PartWords.Place? = nil) -> PersonActing {
            PersonActing(source: Self.host, named: "@ada", reading: reading, lock: lock, changes: lock == nil)
        }
        func line(_ standing: PersonActing?, of said: PersonSaid) -> String? {
            PersonPane.emptyLine(said, held: 0, standing: standing, language: .english)
        }
        let blockedBy = acting(.said(PersonStanding(accountID: "42", blockedBy: true)))
        #expect(line(blockedBy, of: said) == decided)
        #expect(PersonPane.emptyLine(said, held: 0, standing: blockedBy, language: .taiwanese) == "m.example 一則也沒給這次登入。")

        // Not known why: the decided sentence alone, with no figure and no reason.
        let notHeld = acting(nil, lock: PartWords.Place(kind: .unasked, key: "part.follows.unasked"))
        for unknown in [notHeld, acting(.asking), acting(.failed), acting(.unsaid)] {
            #expect(line(unknown, of: said) == decided, "\(String(describing: unknown.reading))")
        }

        // The source said how the reader stands, and it is no block: what it counts and gave.
        let counts = "m.example counts 3 posts of theirs and gave none of them here."
        #expect(line(acting(.said(PersonStanding(accountID: "42"))), of: said) == counts)
        #expect(line(acting(.said(PersonStanding(accountID: "42", following: true))), of: said) == counts)
        // Nobody stands to them here — no sign-in, their own page: as it always was.
        #expect(line(nil, of: said) == counts)

        // A source that counts none, or says no figure, gave none: there is nothing withheld to speak of.
        let none = PersonSaid(
            source: Self.host,
            reading: .said(try MastodonPeople.person(from: Data(#"{"id":"42","acct":"ada","statuses_count":0}"#.utf8), source: Self.source)),
            posts: []
        )
        for standing in [notHeld, acting(.asking), acting(.said(PersonStanding(accountID: "42"))), nil] {
            #expect(line(standing, of: none) == "m.example gave no posts of theirs.")
        }
        #expect(line(blockedBy, of: none) == decided, "blocked by them, the reason is known whatever it counts")
    }

    // MARK: - What is asked, and when

    @Test("Once their page has said who they are, the source is asked how the reader stands to them — one ask, by the id it gave, as the reader, listed in the run's record — and the page shows what it said; opened again nothing more is asked, and `r` asks once more")
    func askedOnceAsTheReader() async throws {
        let (session, server, work) = await session([Self.stands: Self.said(Self.standing(followedBy: true))])
        try await signIn(session)
        let acts = acts(), page = try Self.page()
        #expect(acts.acting(of: Self.ada, said: nil, in: session) == nil, "nothing until the page says who they are")
        #expect(acts.opening(Self.ada, said: nil, in: session) == nil)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.reading == .asking, "before anything answered")
        let opening = try #require(acts.opening(Self.ada, said: page, in: session))
        #expect(opening.accountID == "42")

        await acts.opened(Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands])
        #expect(await server.bearers.last == "Bearer tok")
        #expect(work.record.last?.purpose == .person && work.record.last?.reached == Self.host)
        let shown = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(shown.reading == .said(PersonStanding(accountID: "42", followedBy: true)))
        #expect(shown.pills(language: .english) == ["Follows you"] && shown.press == .follow && shown.lock == nil)
        #expect(shown.pressWords(language: .english) == "Follow")
        #expect(shown.pressSpoken(language: .english) == "Follow @ada@m.example at m.example")

        await acts.opened(Self.ada, said: page, in: session)
        #expect(await asked(server).count == 1, "answered: not asked again while the page stands")
        #expect(acts.opening(Self.ada, said: page, in: session) == opening)

        await server.answer(Self.stands, Self.said(Self.standing(following: true, followedBy: true)))
        await acts.again(Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands, Self.stands])
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.pills(language: .english) == ["Follows you", "You follow them"])
    }

    @Test("With no sign-in nothing is drawn and nobody is asked; nor for a forum's author, the reader's own page, or a reader the source has not named; a suspended account has no standing, and one the source could not be asked about says so and offers asking again")
    func onlyWhereSomebodyStands() async throws {
        let (session, server, _) = await session([Self.stands: Self.said(Self.standing())])
        let acts = acts(), page = try Self.page()
        #expect(acts.acting(of: Self.ada, said: page, in: session) == nil, "nobody signed in: the line is absent")
        await acts.opened(Self.ada, said: page, in: session)
        await acts.again(Self.ada, said: page, in: session)
        await acts.press(.follow, on: Self.ada, said: page, in: session)
        #expect(await asked(server).isEmpty)

        try await signIn(session, named: false)
        #expect(acts.acting(of: Self.ada, said: page, in: session) == nil, "a reader nobody named is told from nobody")
        await acts.opened(Self.ada, said: page, in: session)
        #expect(await asked(server).isEmpty)

        try await signIn(session)
        #expect(acts.acting(of: Self.me, said: page, in: session) == nil, "their own page")
        let author = try #require(DummyPerson(handle: "@ada@forum.example", host: Self.forum.host))
        #expect(acts.acting(of: author, said: PersonSaid(source: Self.forum.host, reading: page.reading), in: session) == nil)
        await acts.opened(Self.me, said: page, in: session)
        await acts.opened(author, said: page, in: session)
        #expect(await asked(server).isEmpty)

        // The source answers, and has no entry for them: an account it suspended.
        await server.answer(Self.stands, PageServer.Answer(body: "[]"))
        let gone = try Self.page(#","suspended":true"#)
        await acts.opened(Self.ada, said: gone, in: session)
        let unsaid = try #require(acts.acting(of: Self.ada, said: gone, in: session))
        #expect(unsaid.reading == .unsaid && unsaid.press == nil && !PersonStandingLines.draws(unsaid))

        let (other, failing, _) = await self.session([Self.stands: Self.down])
        try await signIn(other)
        let again = self.acts()
        await again.opened(Self.ada, said: page, in: other)
        let failed = try #require(again.acting(of: Self.ada, said: page, in: other))
        #expect(failed.reading == .failed && failed.offersAgain && failed.press == nil && failed.pills().isEmpty)
        #expect(failed.failedWords(language: .english) == "Could not ask m.example how you stand to them.")
        #expect(other.mastodon.signedInHosts.contains(Self.host), "a failed read signs nobody out")
        await failing.answer(Self.stands, Self.said(Self.standing()))
        await again.again(Self.ada, said: page, in: other)
        #expect(again.acting(of: Self.ada, said: page, in: other)?.press == .follow)
    }

    // MARK: - Signed in for less

    @Test("Where the sign-in does not see who the reader follows nothing is asked and nothing is guessed — no pill, no sentence about a block — only the lock of how it stands, and Follow dim with the lock; only a lock that asks raises the question, which names following and sends nothing; a sign-in that sees and may not change is shown how the reader stands, and its Follow asks")
    func signedInForLess() async throws {
        let (session, server, _) = await session([Self.stands: Self.said(Self.standing(blockedBy: true))])
        let acts = acts(), page = try Self.page()

        try await signIn(session, holding: Self.reads)
        let unasked = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(unasked.reading == nil && unasked.pills().isEmpty && unasked.blockedWords() == nil, "nothing is guessed")
        #expect(unasked.lock == PartWords.Place(kind: .unasked, key: "part.follows.unasked"))
        #expect(unasked.lockWords(language: .english) == "This sign-in was not asked how you stand to people. Update permission")
        #expect(unasked.press == .ask && unasked.more.isEmpty && PersonStandingLines.draws(unasked))
        #expect(unasked.pressSpoken(language: .english).contains("This sign-in was not asked how you stand to people"))
        #expect(acts.opening(Self.ada, said: page, in: session) == nil)
        await acts.opened(Self.ada, said: page, in: session)
        await acts.again(Self.ada, said: page, in: session)
        await acts.press(.follow, on: Self.ada, said: page, in: session)
        #expect(await asked(server).isEmpty, "nothing is asked to draw a lock")

        try await signIn(session, holding: Self.reads, refused: "read:follows write:follows")
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.lock == PartWords.Place(kind: .refused, key: "part.ask.refused"))
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.press == .ask)

        try await signIn(session, holding: Self.reads, asked: Self.follows)
        let none = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(none.lock == PartWords.Place(kind: .none, key: "part.ask.none"))
        #expect(none.press == nil, "a source with none is not asked again, and Follow is not drawn")

        // The press on a lock that asks raises the question about following at that source.
        try await signIn(session, holding: Self.reads)
        #expect(session.partAsks.open == nil)
        #expect(session.askFor([PersonAct.follow.needs], host: Self.host))
        #expect(session.partAsks.open?.ticked == [.follows] && session.partAsks.open?.host == Self.host)
        let question = try #require(session.partAsks.open.map { ShellQuestion.part($0, language: .english) })
        #expect(question.title == "Ask m.example to allow following?")
        #expect((question.line + (question.help ?? "")).contains("who you follow"), "what more will be asked is said before the server's page")
        #expect(await asked(server).isEmpty)

        // Seeing, and not changing: how the reader stands is read and shown, and Follow asks.
        try await signIn(session, holding: Self.seeing)
        #expect(acts.opening(Self.ada, said: page, in: session) != nil)
        await acts.opened(Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands])
        let sees = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(sees.blockedWords(language: .english) == "@ada@m.example has blocked you. m.example shows you none of their posts.")
        #expect(sees.lock == PartWords.Place(kind: .partly, key: "part.follows.partly.changing") && !sees.changes)
        await server.answer(Self.stands, Self.said(Self.standing(following: true)))
        await acts.again(Self.ada, said: page, in: session)
        let followed = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(followed.pills(language: .english) == ["You follow them"] && followed.more.isEmpty && followed.press == .ask)
        await acts.press(.unfollow, on: Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands, Self.stands], "and nothing is sent that it may not send")
    }

    @Test("After a yes on the question the place reads again and offers Follow: a sign-in given follows is another opening of the page, and nobody is followed unpressed")
    func aSignInGivenFollowsOpensAgain() async throws {
        let (session, server, _) = await session([Self.stands: Self.said(Self.standing())])
        let acts = acts(), page = try Self.page()
        try await signIn(session, holding: Self.reads)
        #expect(acts.opening(Self.ada, said: page, in: session) == nil)
        try await signIn(session, as: "wider")
        let opening = try #require(acts.opening(Self.ada, said: page, in: session))
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.reading == .asking)
        await acts.opened(Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands], "read, and not acted")
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.press == .follow)
        #expect(acts.opening(Self.ada, said: page, in: session) == opening)
    }

    // MARK: - Following, unfollowing, withdrawing

    @Test("Following shows on the server and on the page: one post to their own address as the reader, listed as a write, shown at the press as followed and then as the source answered; unfollowing is in the `…` alone, and does the same; a second press while one is out sends nothing")
    func followingAndUnfollowing() async throws {
        let (session, server, work) = await session([
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true)),
            Self.unfollow: Self.answered(Self.standing()),
        ])
        try await signIn(session)
        let acts = acts(), page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.more.isEmpty == true, "nothing to stop: no `…`")

        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let pressed = Task { await acts.press(.follow, on: Self.ada, said: page, in: session) }
        await server.arrival(of: Self.follow)
        let out = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(out.doing == .follow && out.pills(language: .english) == ["You follow them"], "shown at the press")
        #expect(out.press == nil && out.more.isEmpty, "and nothing more is offered while it is out")
        await acts.press(.follow, on: Self.ada, said: page, in: session)
        await acts.press(.unfollow, on: Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands, Self.follow], "pressed again meanwhile, nothing more is sent")
        await server.release(Self.follow)
        await pressed.value
        #expect(await server.bearers.last == "Bearer tok")
        #expect(work.record.last?.purpose == .write)

        let followed = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(followed.reading == .said(PersonStanding(accountID: "42", following: true)) && followed.doing == nil)
        #expect(followed.press == nil && followed.more == [.unfollow] && followed.missed == nil)
        #expect(!followed.asksBefore(.unfollow), "somebody anyone may follow is unfollowed in one press")
        let menu = followed.menu(head: ["Ada"], act: { _ in })
        #expect(menu.head == ["Ada"] && menu.items.map(\.name) == [PersonActing.name(.unfollow)] && menu.dangers.isEmpty)
        #expect(PersonActing.name(.unfollow, language: .english) == "Unfollow")

        await acts.press(.unfollow, on: Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands, Self.follow, Self.unfollow])
        let unfollowed = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(unfollowed.pills().isEmpty && unfollowed.press == .follow && unfollowed.more.isEmpty)
    }

    @Test("Somebody who must agree reads Ask to follow, is shown as asked at the press and as the source answers; the request is withdrawn from the `…`, which the source is sent as an unfollow; and unfollowing them once followed is asked about first")
    func somebodyWhoMustAgree() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(requested: true)),
            Self.unfollow: Self.answered(Self.standing()),
        ])
        try await signIn(session)
        let acts = acts(), page = try Self.page(#","locked":true"#)
        await acts.opened(Self.ada, said: page, in: session)
        let offered = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(offered.press == .follow && offered.pressWords(language: .english) == "Ask to follow")
        #expect(offered.pressWords(language: .taiwanese) == "請求跟隨")
        #expect(offered.pressSpoken(language: .english) == "Ask to follow @ada@m.example at m.example")

        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let pressed = Task { await acts.press(.follow, on: Self.ada, said: page, in: session) }
        await server.arrival(of: Self.follow)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.pills(language: .english) == ["Asked"], "asked, at the press")
        await server.release(Self.follow)
        await pressed.value

        let asked = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(asked.pills(language: .english) == ["Asked"] && asked.press == nil && asked.more == [.withdraw] && asked.missed == nil)
        #expect(!asked.asksBefore(.withdraw))
        #expect(PersonActing.name(.withdraw, language: .english) == "Withdraw your request to follow")
        await acts.press(.withdraw, on: Self.ada, said: page, in: session)
        #expect(await self.asked(server) == [Self.stands, Self.follow, Self.unfollow])
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.press == .follow)

        // Followed, they are unfollowed only after a question that says what is lost.
        let following = PersonActing(
            source: Self.host, named: "@ada@m.example", asksFirst: true,
            reading: .said(PersonStanding(accountID: "42", following: true)), changes: true
        )
        #expect(following.more == [.unfollow] && following.asksBefore(.unfollow))
        var chosen: [PersonAct] = []
        let item = try #require(following.menu(head: [], act: { chosen.append($0) }).dangers.first)
        let question = try #require(item.question)
        #expect(question == ShellQuestion.unfollow("@ada@m.example", at: Self.host))
        let english = ShellQuestion.unfollow("@ada@m.example", at: Self.host, language: .english)
        #expect(english.title == "Unfollow @ada@m.example at m.example?")
        #expect(english.line == "They ask before anyone may follow them. To follow them again, you would have to ask again.")
        #expect(english.chorded?.label == "Unfollow" && english.cancel != nil)
        var put: ShellMoreAsk?
        item.press { put = $0 }
        #expect(chosen.isEmpty, "choosing it only asks")
        put?.answered(try #require(question.chorded?.id))
        #expect(chosen == [.unfollow])
    }

    @Test("Following somebody of another server is settled by a read and by nothing else: the press is answered followed, the source is read while the press is still out, and the page says what that read said — asked — never what the press was answered")
    func somebodyLivingElsewhere() async throws {
        let far = try #require(DummyPerson(handle: "@ada@elsewhere.example", host: Self.host))
        let page = try Self.page(acct: "ada@elsewhere.example")
        #expect(page.person?.livesHere == false)
        let routes = [Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true))]

        // With nothing held: the press is not over until the read has landed.
        let (session, server, work) = await session(routes)
        try await signIn(session)
        let acts = acts()
        await acts.opened(far, said: page, in: session)
        await server.answer(Self.stands, Self.said(Self.standing(requested: true)))
        await acts.press(.follow, on: far, said: page, in: session)
        try #require(await asked(server) == [Self.stands, Self.follow, Self.stands], "the source is read once the press is answered")
        #expect(work.record.suffix(2).map(\.purpose) == [.write, .person])
        let settled = try #require(acts.acting(of: far, said: page, in: session))
        #expect(settled.reading == .said(PersonStanding(accountID: "42", requested: true)))
        #expect(settled.pills(language: .english) == ["Asked"] && settled.more == [.withdraw] && settled.missed == nil && settled.doing == nil)

        // While that read is out the page draws the press, and offers nothing.
        let (other, held, _) = await self.session(routes)
        try await signIn(other)
        let again = self.acts()
        await again.opened(far, said: page, in: other)
        await held.answer(Self.stands, Self.said(Self.standing(requested: true)))
        await held.hold(Self.stands)
        defer { Task { await held.release(Self.stands) } }
        let pressed = Task { await again.press(.follow, on: far, said: page, in: other) }
        await held.arrival(of: Self.stands, times: 2)
        let out = try #require(again.acting(of: far, said: page, in: other))
        #expect(out.doing == .follow && out.press == nil && out.more.isEmpty, "still the press: no Unfollow over what nobody said")
        #expect(out.reading == .said(PersonStanding(accountID: "42")), "what the press was answered is written nowhere")
        await again.press(.follow, on: far, said: page, in: other)
        #expect(await asked(held) == [Self.stands, Self.follow, Self.stands], "and pressed again meanwhile, nothing is sent")
        await held.release(Self.stands)
        await pressed.value
        #expect(again.acting(of: far, said: page, in: other)?.pills(language: .english) == ["Asked"])

        // Somebody of this server is taken at the press's answer: no read follows it.
        let (near, local, _) = await self.session(routes)
        try await signIn(near)
        let here = self.acts(), ada = try Self.page()
        await here.opened(Self.ada, said: ada, in: near)
        await here.press(.follow, on: Self.ada, said: ada, in: near)
        #expect(await asked(local) == [Self.stands, Self.follow])
    }

    @Test("Where the read after following somebody of another server fails, the page does not say followed: it draws no standing and no Unfollow, says it could not ask how the reader stands, and offers asking again — which then says what the source says")
    func theSettlingReadFailing() async throws {
        let far = try #require(DummyPerson(handle: "@ada@elsewhere.example", host: Self.host))
        let page = try Self.page(acct: "ada@elsewhere.example")
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true)),
        ])
        try await signIn(session)
        let acts = acts()
        await acts.opened(far, said: page, in: session)
        let failures: [PageServer.Answer?] = [Self.down, nil, PageServer.Answer(body: "{}")]
        for failing in failures {
            await server.answer(Self.stands, failing)
            await acts.press(.follow, on: far, said: page, in: session)
            let unread = try #require(acts.acting(of: far, said: page, in: session))
            #expect(unread.reading == .failed && unread.offersAgain, "\(String(describing: failing?.body))")
            #expect(unread.pills().isEmpty && unread.more.isEmpty && unread.press == nil && unread.doing == nil)
            #expect(unread.missed == nil, "the press arrived: it is not said to have failed")
            #expect(unread.failedWords(language: .english) == "Could not ask m.example how you stand to them.")
            #expect(PersonStandingLines.draws(unread))
            #expect(session.mastodon.signedInHosts.contains(Self.host))

            // Try again, and the source's own word stands: asked. Withdrawn, to press once more.
            await server.answer(Self.stands, Self.said(Self.standing(requested: true)))
            await acts.again(far, said: page, in: session)
            let asked = try #require(acts.acting(of: far, said: page, in: session))
            #expect(asked.pills(language: .english) == ["Asked"] && asked.more == [.withdraw])
            await server.answer(Self.unfollow, Self.answered(Self.standing()))
            await acts.press(.withdraw, on: far, said: page, in: session)
            #expect(acts.acting(of: far, said: page, in: session)?.press == .follow)
        }

        // Answered with no entry for them, the page has no standing to draw, and says none.
        await server.answer(Self.stands, PageServer.Answer(body: "[]"))
        await acts.press(.follow, on: far, said: page, in: session)
        let unsaid = try #require(acts.acting(of: far, said: page, in: session))
        #expect(unsaid.reading == .unsaid && unsaid.pills().isEmpty && unsaid.more.isEmpty && unsaid.press == nil)
    }

    // MARK: - A press and a read on its way

    @Test("An act taken while a read is on its way is not undone by it: the read set out before the press, lands after its answer with what the source said then, and the page goes on saying what the act was answered")
    func aReadLandingAfterTheAct() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true)),
        ])
        try await signIn(session)
        let acts = acts(), page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)

        await server.hold(Self.stands)
        defer { Task { await server.release(Self.stands) } }
        let reading = Task { await acts.again(Self.ada, said: page, in: session) }
        await server.arrival(of: Self.stands, times: 2)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.press == .follow, "what it said before stays drawn, and pressed")

        await acts.press(.follow, on: Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands, Self.stands, Self.follow])
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.pills(language: .english) == ["You follow them"])

        // The read answers now, with what was so when it set out: not followed.
        await server.release(Self.stands)
        await reading.value
        let after = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(after.reading == .said(PersonStanding(accountID: "42", following: true)), "the read is told to nobody")
        #expect(after.more == [.unfollow] && after.press == nil && after.missed == nil)
        await acts.opened(Self.ada, said: page, in: session)
        #expect(await asked(server).count == 3, "and the page is left asking nothing")
    }

    @Test("A read that lands while a press is out changes nothing on screen: the page draws the press until its own answer, whatever the read brought")
    func aReadLandingWhileThePressIsOut() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true)),
        ])
        try await signIn(session)
        let acts = acts(), page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)

        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let pressed = Task { await acts.press(.follow, on: Self.ada, said: page, in: session) }
        await server.arrival(of: Self.follow)
        await acts.again(Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands, Self.follow, Self.stands], "the read went, and answered not followed")
        let out = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(out.doing == .follow && out.pills(language: .english) == ["You follow them"] && out.press == nil)

        await server.release(Self.follow)
        await pressed.value
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.reading == .said(PersonStanding(accountID: "42", following: true)))
    }

    @Test("A press the source refused, or that did not arrive, leaves the page as the source last said and says so under the heading, in both languages; pressed again the sentence goes; and an answer that is not what was pressed for is said as not done")
    func aPressThatDidNotArrive() async throws {
        let (session, server, _) = await session([Self.stands: Self.said(Self.standing()), Self.follow: Self.refused])
        try await signIn(session)
        let acts = acts(), page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        await acts.press(.follow, on: Self.ada, said: page, in: session)
        let missed = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(missed.missed == .follow && missed.doing == nil && missed.pills().isEmpty && missed.press == .follow)
        #expect(missed.missedWords(language: .english) == "Could not follow @ada@m.example at m.example.")
        #expect(missed.missedWords(language: .taiwanese) == "無法在 m.example 跟隨 @ada@m.example。")
        #expect(PersonStandingLines.draws(missed))
        #expect(session.mastodon.signedInHosts.contains(Self.host), "a refusal signs nobody out")

        await server.answer(Self.follow, nil)
        await acts.press(.follow, on: Self.ada, said: page, in: session)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.missed == .follow, "it did not arrive")

        // Answered, and not with what was pressed for: the source's word stands, and it is said.
        await server.answer(Self.follow, Self.answered(Self.standing()))
        await acts.press(.follow, on: Self.ada, said: page, in: session)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.missed == .follow)

        await server.answer(Self.follow, Self.answered(Self.standing(following: true)))
        await acts.press(.follow, on: Self.ada, said: page, in: session)
        let done = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(done.missed == nil && done.pills(language: .english) == ["You follow them"])
        for act in PersonAct.allCases {
            let failed = PersonActing(source: Self.host, named: "@ada", missed: act)
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(failed.missedWords(language: language)?.contains("@ada") == true, "\(act) \(language)")
            }
        }
    }

    @Test("A press whose reader signed out while it was out is told to nobody: nothing is drawn for the next reader, who is asked afresh, and nothing is said to have failed")
    func letGoWithItsReader() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true)),
        ])
        try await signIn(session, as: "first")
        let acts = acts(), page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let pressed = Task { await acts.press(.follow, on: Self.ada, said: page, in: session) }
        await server.arrival(of: Self.follow)

        try await signIn(session, as: "second")
        let next = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(next.reading == .asking && next.doing == nil, "the first reader's page and press are not the second's")
        await acts.opened(Self.ada, said: page, in: session)
        #expect(await server.bearers.last == "Bearer second")
        await server.release(Self.follow)
        await pressed.value
        let after = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(after.reading == .said(PersonStanding(accountID: "42")) && after.missed == nil && after.doing == nil)
    }

    @Test("A press let go of is told to nobody even where the same sign-in is held again when it answers: the entry is no longer that press's, so nothing is written and the page made since is not asked again for it")
    func anAnswerToAPressLetGoOf() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true)),
        ])
        try await signIn(session, as: "first")
        let acts = acts(), page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let pressed = Task { await acts.press(.follow, on: Self.ada, said: page, in: session) }
        await server.arrival(of: Self.follow)

        // Somebody else, whose look lets the press go — and then the first reader again, under
        // the very token the press went with, on a page made since.
        try await signIn(session, as: "second")
        await acts.opened(Self.ada, said: page, in: session)
        try await signIn(session, as: "first")
        await acts.opened(Self.ada, said: page, in: session)
        #expect(await asked(server) == [Self.stands, Self.follow, Self.stands, Self.stands])
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.doing == nil, "the press is not drawn again")

        await server.release(Self.follow)
        await pressed.value
        let after = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(after.reading == .said(PersonStanding(accountID: "42")) && after.missed == nil && after.doing == nil)
        // Whatever read the answer might have begun is waited on here, and there is none.
        await acts.opened(Self.ada, said: page, in: session)
        #expect(await asked(server).count == 4, "and nothing more is asked on its account")
    }

    @Test("A press whose sign-in was replaced while it was out, with nobody having looked since, is written nowhere: the page pressed on still stands for all this device has seen, and the answer was given to another sign-in")
    func anAnswerToAnotherSignIn() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true)),
        ])
        try await signIn(session, as: "first")
        let acts = acts(), page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let pressed = Task { await acts.press(.follow, on: Self.ada, said: page, in: session) }
        await server.arrival(of: Self.follow)

        // The token swapped under the session, as another window's sign-in does: no look at
        // it, no page opened, and what the session last knew of the sign-in unchanged.
        let held = try #require(try session.mastodon.tokens.token(host: Self.host))
        _ = try session.mastodon.tokens.forget(held)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "second", clientID: "c", clientSecret: "s", scopes: Self.follows, asked: Self.follows
        ))
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.doing == .follow, "nothing has looked: the press is still drawn")

        await server.release(Self.follow)
        await pressed.value
        let after = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(after.reading == .said(PersonStanding(accountID: "42")), "the first sign-in's answer is not this one's")
        #expect(after.doing == nil && after.missed == nil)
        #expect(await asked(server) == [Self.stands, Self.follow])
    }

    // MARK: - The pages' own way in, the key, and the page laid out

    @Test("Through the pages a person's page is asked how the reader stands once it has said who they are, `r` asks both again, and `l` follows where the page offers it — and raises the sign-in's question where its Follow is the lock")
    func throughThePagesAndTheKey() async throws {
        let lookup = "/api/v1/accounts/lookup?acct=ada", statuses = "/api/v1/accounts/42/statuses"
        let (session, server, _) = await session([
            lookup: PageServer.Answer(body: #"{"id":"42","acct":"ada","display_name":"Ada"}"#), statuses: PageServer.Answer(body: "[]"),
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true)),
        ])
        try await signIn(session)
        let pages = ShellPersonPages()
        #expect(pages.stands(to: Self.ada, in: session) == nil && pages.standsOpening(to: Self.ada, in: session) == nil)
        #expect(!pages.followByKey(Self.ada, in: session), "nothing to follow before the source has said")
        await pages.opened(Self.ada, in: session)
        #expect(pages.standsOpening(to: Self.ada, in: session) != nil)
        await pages.standsOpened(to: Self.ada, in: session)
        #expect(await asked(server) == [lookup, statuses, Self.stands])
        #expect(pages.stands(to: Self.ada, in: session)?.press == .follow)

        await pages.again(Self.ada, in: session)
        #expect(await asked(server) == [lookup, statuses, Self.stands, lookup, statuses, Self.stands])

        await pages.act(.follow, on: Self.ada, in: session)
        #expect(pages.stands(to: Self.ada, in: session)?.more == [.unfollow])
        #expect(!pages.followByKey(Self.ada, in: session), "followed already: the key does nothing")

        try await signIn(session, as: "narrow", holding: Self.reads)
        await pages.opened(Self.ada, in: session)
        #expect(session.partAsks.open == nil)
        #expect(pages.followByKey(Self.ada, in: session))
        #expect(session.partAsks.open?.ticked == [.follows])

        #expect(DummyCommand.from("l") == DummyCommand.follow)
        #expect(DummyCommand.from("l", typing: true) == nil)
        #expect(DummyCommand.from("l", fieldFocused: true) == nil)
        let line = try #require(DummyShortcut.all.first { $0.commands == [.follow] })
        #expect(line.keys == ["l"])
    }

    private static let tagged = "/api/v1/tags/swift"
    private static let tagFollow = "/api/v1/tags/swift/follow"
    private static let tagUnfollow = "/api/v1/tags/swift/unfollow"

    /// A hashtag as a source says it to a sign-in, made up here in the shape a real one has
    /// (`MastodonTagFollowCaptures`).
    private static func tag(_ following: Bool) -> PageServer.Answer {
        PageServer.Answer(body: #"{"id":"2","name":"swift","url":"https://m.example/tags/swift","history":[],"following":\#(following),"featuring":false}"#)
    }

    @Test("`l` answers only where a page of the walk may be in front — on the timeline's place, with nothing over the walk — and there follows whoever's page it is, or the hashtag whose page it is at the first source that offers it")
    func theKeyWhereverItIsPressed() async throws {
        let lookup = "/api/v1/accounts/lookup?acct=ada", statuses = "/api/v1/accounts/42/statuses"
        let (session, server, _) = await session([
            lookup: PageServer.Answer(body: #"{"id":"42","acct":"ada","display_name":"Ada"}"#), statuses: PageServer.Answer(body: "[]"),
            Self.stands: Self.said(Self.standing()), Self.follow: Self.answered(Self.standing(following: true)),
            Self.tagged: Self.tag(false), Self.tagFollow: Self.tag(true), Self.tagUnfollow: Self.tag(false),
        ])
        try await signIn(session)
        let pages = ShellPersonPages(), swift = try #require(PostTag("#swift"))
        await pages.opened(Self.ada, in: session)
        await pages.standsOpened(to: Self.ada, in: session)
        await pages.tags.opened(swift, in: session)
        let before = await asked(server)

        func key(_ place: ShellPlace, _ open: Set<DummyLayer>, person: DummyPerson? = nil, tag: PostTag? = nil) -> Bool {
            pages.followByKey(place: place, open: open, person: person, tag: tag, in: session)
        }
        // Not from another place, and not under the viewer or the keys' own list.
        for place in ShellPlace.allCases where place != .timeline {
            #expect(!key(place, [.person], person: Self.ada), "\(place)")
            #expect(!key(place, [.tag], tag: swift), "\(place)")
        }
        for over in [DummyLayer.viewer, .shortcuts] {
            #expect(!key(.timeline, [.person, over], person: Self.ada), "\(over)")
            #expect(!key(.timeline, [.tag, over], tag: swift), "\(over)")
        }
        #expect(!key(.timeline, []), "neither page in front")
        #expect(session.partAsks.open == nil)
        #expect(await asked(server) == before, "a key that does not answer sends nothing")

        // A hashtag's page: followed at the source whose line offers it.
        #expect(key(.timeline, [.tag], tag: swift))
        await server.arrival(of: Self.tagFollow)
        #expect(await asked(server) == before + [Self.tagFollow])

        // Somebody's page, a row of it lit.
        #expect(key(.timeline, [.person, .selection], person: Self.ada))
        await server.arrival(of: Self.follow)
        #expect(await asked(server) == before + [Self.tagFollow, Self.follow])
    }

    @Test("The key's press on a hashtag is sent as a follow and as nothing else: taken where the source says it is followed already — a read having landed since the key looked — it sends nothing, where the line's own press would unfollow")
    func theKeyOnlyEverFollows() async throws {
        let (session, server, _) = await session([
            Self.tagged: Self.tag(true), Self.tagFollow: Self.tag(true), Self.tagUnfollow: Self.tag(false),
        ])
        try await signIn(session)
        let tags = ShellPersonPages().tags, swift = try #require(PostTag("#swift"))
        await tags.opened(swift, in: session)
        #expect(tags.lines(of: swift, in: session).map(\.standing) == [.said(true)])
        #expect(tags.followByKey(swift, in: session) == nil, "followed already: the key does nothing")

        // The press the key's task makes, landing on a line that now says followed.
        await tags.press(swift, at: Self.host, only: true, in: session)
        #expect(await asked(server) == [Self.tagged], "nothing is sent")
        #expect(tags.lines(of: swift, in: session).map(\.standing) == [.said(true)])
        // And the other way: a press that means unfollow, where it is not followed.
        await tags.press(swift, at: Self.host, only: false, in: session)
        #expect(await asked(server) == [Self.tagged, Self.tagUnfollow])
        await tags.press(swift, at: Self.host, only: false, in: session)
        #expect(await asked(server) == [Self.tagged, Self.tagUnfollow], "not followed: nothing to stop")
        // Not followed, the key follows — by the press it hands back.
        await tags.followByKey(swift, in: session)?.value
        #expect(await asked(server) == [Self.tagged, Self.tagUnfollow, Self.tagFollow])
        #expect(tags.lines(of: swift, in: session).map(\.standing) == [.said(true)])
    }

    private func height<Content: View>(_ view: Content, width: CGFloat, layout: ShellLayout, scheme: ColorScheme) -> CGFloat {
        let hosted = NSHostingView(
            rootView: view.frame(width: width).environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
        )
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize.height
    }

    @Test("The page lays out with every standing it may be handed — none, asking, pills and Follow, the `…`, blocked by them, the lock, a failure, a press that did not arrive — at a wide page and across a phone, in light and in dark; and what stands under the heading has a height only where there is something to say")
    func laidOut() throws {
        let page = try Self.page()
        let every = PersonStanding(accountID: "42", following: true, followedBy: true, muting: true, blocking: true)
        func acting(_ reading: PersonActing.Reading?, lock: PartWords.Place? = nil, missed: PersonAct? = nil) -> PersonActing {
            PersonActing(source: Self.host, named: "@ada@m.example", reading: reading, lock: lock, changes: lock == nil, missed: missed)
        }
        let handed: [PersonActing?] = [
            nil, acting(.asking), acting(.said(PersonStanding(accountID: "42"))), acting(.said(every)),
            acting(.said(PersonStanding(accountID: "42", blockedBy: true))),
            acting(nil, lock: PartWords.Place(kind: .unasked, key: "part.follows.unasked")),
            acting(.failed), acting(.said(PersonStanding(accountID: "42")), missed: .follow),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 390), (.narrow, 320)] {
                for standing in handed {
                    let pane = PersonPane(
                        person: Self.ada, items: [], catalogues: EmojiCatalogueStore(), posts: ForumPosts(), selectedID: .constant(nil),
                        decks: .constant(ShellDecks()), playback: ShellPlayback(), onPlayRow: { _ in }, onViewRow: { _ in },
                        onTurnRow: { _ in }, onOpenThread: { _ in }, jumpToTop: 0, onBack: {}, said: page, standing: standing
                    )
                    let hosted = NSHostingView(
                        rootView: pane.frame(width: width, height: 700).environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                    )
                    hosted.layoutSubtreeIfNeeded()
                    #expect(hosted.fittingSize.height == 700, "\(String(describing: standing?.reading)) at \(width)")
                    guard let standing else { continue }
                    let lines = height(PersonStandingLines(acting: standing, onAsk: {}, onAgain: {}), width: width, layout: layout, scheme: scheme)
                    #expect((lines > 0) == PersonStandingLines.draws(standing), "\(standing) at \(width)")
                    let acts = height(PersonHeadActs(acting: standing, onAct: { _ in }, onAsk: {}), width: width, layout: layout, scheme: scheme)
                    #expect((acts > 0) == PersonHeadActs.draws(standing), "\(standing) at \(width)")
                    #expect((height(PersonStandingPills(pills: standing.pills()), width: width, layout: layout, scheme: scheme) > 0) == !standing.pills().isEmpty)
                }
            }
        }
    }

    @Test("Every sentence this page says is written in each language, and none is its own key")
    func everySentenceIsWritten() {
        let keys = [
            "person.stands.followsYou", "person.stands.following", "person.stands.asked", "person.stands.muted",
            "person.stands.mutedUntil", "person.stands.blocked", "person.stands.blockedBy", "person.stands.failed",
            "person.posts.noneGiven", "person.act.follow", "person.act.askToFollow", "person.act.unfollow", "person.act.withdraw",
            "person.act.follow.spoken", "person.act.askToFollow.spoken", "person.act.follow.failed", "person.act.unfollow.failed",
            "person.act.withdraw.failed", "person.unfollow.ask.title", "person.unfollow.ask.line", "shortcut.follow",
        ]
        for key in keys {
            let english = L10n.t(key, language: .english), taiwanese = L10n.t(key, language: .taiwanese)
            #expect(english != key && taiwanese != key && english != taiwanese, "\(key)")
        }
    }
}
