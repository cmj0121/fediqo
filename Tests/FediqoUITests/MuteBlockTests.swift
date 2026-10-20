import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #314, on somebody's page: muting and blocking them, and blocking the whole server they live
/// on — what the `…` offers and where the sign-in holds less, the sheet each is asked on, what
/// the source is sent and what the page then says, and what this device does with what it held
/// of them as the person answered. A press that does not arrive changes nothing here.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made the ask; every deadline is on a clock nobody turns.
@MainActor
@Suite("Muting and blocking somebody, and their server, from their page", .serialized, .watched)
struct MuteBlockTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let follows = "\(reads) read:follows write:follows"
    /// A sign-in that sees and changes who the reader follows, and mutes and blocks.
    private static let blocking = "\(follows) read:mutes write:mutes read:blocks write:blocks"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let lookup = "/api/v1/accounts/lookup?acct=ada"
    private static let farLookup = "/api/v1/accounts/lookup?acct=far@far.example"
    private static let stands = "/api/v1/accounts/relationships?id%5B%5D=42"
    private static let farStands = "/api/v1/accounts/relationships?id%5B%5D=43"
    private static let mute = "/api/v1/accounts/42/mute"
    private static let unmute = "/api/v1/accounts/42/unmute"
    private static let block = "/api/v1/accounts/42/block"
    private static let servers = "/api/v1/domain_blocks"

    private static let ada = DummyPerson(handle: "@ada@m.example", host: host)!
    private static let far = DummyPerson(handle: "@far@far.example", host: host)!

    /// One standing in the shape a real server's has (`MastodonBlocksCaptures`), with the parts
    /// a check names.
    private static func standing(
        _ id: String = "42", following: Bool = false, muting: Bool = false, notices: Bool = true, until: String? = nil,
        blocking: Bool = false, server: Bool = false
    ) -> String {
        #"{"id":"\#(id)","following":\#(following),"showing_reblogs":\#(following),"notifying":false,"languages":null,"followed_by":false,"blocking":\#(blocking),"blocked_by":false,"muting":\#(muting),"muting_notifications":\#(muting && notices),"muting_expires_at":\#(until.map { "\"\($0)\"" } ?? "null"),"requested":false,"requested_by":false,"domain_blocking":\#(server),"endorsed":false,"note":""}"#
    }

    private static func said(_ standing: String) -> PageServer.Answer { PageServer.Answer(body: "[\(standing)]") }
    private static func answered(_ standing: String) -> PageServer.Answer { PageServer.Answer(body: standing) }
    private static let down = PageServer.Answer(body: "<html>", status: 500)

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let me = PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#)
        let base: [String: PageServer.Answer] = [
            Self.who: me,
            Self.lookup: PageServer.Answer(body: #"{"id":"42","acct":"ada","display_name":"Ada"}"#),
            Self.farLookup: PageServer.Answer(body: #"{"id":"43","acct":"far@far.example","display_name":"Far"}"#),
        ]
        let server = PageServer(routes.merging(base) { mine, _ in mine })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    private func signIn(_ session: ShellSession, holding scopes: String = MuteBlockTests.blocking) async throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
    }

    /// The page of `who` opened, and how the reader stands to them asked.
    private func opened(_ who: DummyPerson, in session: ShellSession) async -> ShellPersonPages {
        let pages = ShellPersonPages()
        await pages.opened(who, in: session)
        await pages.standsOpened(to: who, in: session)
        return pages
    }

    /// Posts this device holds: two of Ada's, one of them kept, and one of somebody else's.
    private func hold(_ session: ShellSession) async {
        func note(_ id: String, _ handle: String, kept: Bool = false) -> Note {
            var note = Note(
                id: "https://m.example/\(id)", source: Self.source, author: "Somebody", handle: handle, body: "words of \(id)",
                postedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id.count)), categories: [.public], statusID: id
            )
            note.kept = kept
            return note
        }
        await session.store.ingest([
            note("1", "@ada@m.example"), note("22", "@ada@m.example", kept: true), note("333", "@bea@m.example"),
            note("4444", "@far@far.example"),
        ])
        await session.reloadFromStore()
    }

    private func asked(_ server: PageServer) async -> [String] {
        await server.asked.filter { $0 != Self.who }
    }

    private func sent(_ server: PageServer, to ask: String) async -> [String] {
        await server.sent.filter { $0.ask == ask }.map { "\($0.method) \($0.body)" }
    }

    // MARK: - What is offered

    @Test("Of somebody the source said how the reader stands to, the `…` offers Mute and Block after following's items; of somebody whose server is not the source's own, Block all of that server too, named; once muted or blocked, Unmute and Unblock instead — and nothing is guessed before the source has said")
    func whatIsOffered() async throws {
        let (session, _, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.farStands: Self.said(Self.standing("43", muting: true, blocking: true, server: true)),
        ])
        try await signIn(session)
        let pages = await opened(Self.ada, in: session)
        let ada = try #require(pages.stands(to: Self.ada, in: session))
        #expect(ada.keeping == [.mute, .block] && ada.server == nil && ada.blocksLock == nil)
        let menu = ada.menu(head: ["Ada"]) { _ in }
        #expect(Array(menu.items.map(\.name).suffix(3)) == ["Mute…", "Block…", "Report…"] && menu.head.first == "Ada")
        #expect(menu.items.suffix(3).prefix(2).allSatisfy { $0.look == .live && !$0.isDanger }, "each asks on its own sheet")

        let farPages = await opened(Self.far, in: session)
        let far = try #require(farPages.stands(to: Self.far, in: session))
        #expect(far.keeping == [.unmute, .unblock, .unblockServer] && far.server == "far.example")
        #expect(far.marks(language: .english).map(\.words).suffix(3) == ["Muted", "Blocked", "Their server blocked"])
        #expect(Array(far.menu(head: []) { _ in }.items.map(\.name).suffix(4).prefix(3)) == ["Unmute", "Unblock", "Unblock far.example"])
        #expect(PersonActing.name(.blockServer, server: "far.example", language: .english) == "Block all of far.example…")

        let unsaid = PersonActing(source: Self.host, named: "@ada", reading: .asking, changes: true)
        #expect(unsaid.keeping.isEmpty && !PersonHeadActs.draws(unsaid), "nothing before the source has said")
    }

    @Test("Signed in for less than muting and blocking need, each is in the `…` dim with the lock, its sentence once at the menu's head; its press only asks for the part, naming it, and nothing is sent — and a sign-in that sees and may not change is told so in its own words")
    func signedInForLess() async throws {
        let (session, server, _) = await session([Self.stands: Self.said(Self.standing())])
        try await signIn(session, holding: Self.follows)
        let pages = await opened(Self.ada, in: session)
        let acting = try #require(pages.stands(to: Self.ada, in: session))
        let lock = try #require(acting.blocksLock)
        #expect(lock.asks && acting.asksForPart(.mute) && acting.asksForPart(.block) && !acting.asksForPart(.unfollow))
        let menu = acting.menu(head: ["Ada"]) { _ in }
        let unasked = L10n.t("part.blocks.unasked")
        #expect(Array(menu.head.prefix(2)) == ["Ada", unasked] && menu.head.filter { $0 == unasked }.count == 1, "said once for the two")
        #expect(menu.items.suffix(3).prefix(2).allSatisfy { $0.look == .dim(.askAgain) && $0.symbol == SourceRow.permissionSymbol && $0.answers })

        await pages.act(.mute, on: Self.ada, in: session)
        #expect(pages.standingAsk == nil, "no sheet")
        #expect(session.partAsks.open?.ticked == [.blocks])
        #expect(await sent(server, to: Self.mute).isEmpty)
        #expect(ShellQuestion.part(try #require(session.partAsks.open), language: .english).title == "Ask m.example to allow muting and blocking?")

        try await signIn(session, holding: "\(Self.follows) read:mutes read:blocks")
        let seeing = await opened(Self.ada, in: session)
        #expect(seeing.stands(to: Self.ada, in: session)?.blocksLock?.key == "part.blocks.partly.changing")
        for language in [DummyLanguage.english, .taiwanese] {
            for key in ["part.blocks.unasked", "part.blocks.partly.changing", "part.blocks.partly.seeing", "part.blocks.name"] {
                #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
            }
        }
    }

    // MARK: - The sheet

    @Test("Mute and Block are asked on a sheet first: it names them, the source and what it takes away, how much this device holds of them, how long a mute lasts — and leaving it sends nothing and changes nothing")
    func theSheet() async throws {
        let (session, server, _) = await session([Self.stands: Self.said(Self.standing())])
        try await signIn(session)
        await hold(session)
        let pages = await opened(Self.ada, in: session)
        await pages.act(.mute, on: Self.ada, in: session)
        let ask = try #require(pages.standingAsk)
        #expect(ask.act == .mute && ask.handle == "@ada@m.example" && ask.source == Self.host && ask.held == 2 && ask.server == nil)
        let said = StandingSheetSaid(ask: ask)
        #expect(said.title(language: .english) == "Mute @ada@m.example?")
        #expect(said.line(language: .english).hasPrefix("m.example stops handing you @ada@m.example's posts and boosts."))
        #expect(said.heldTitle(language: .english) == "This device holds 2 posts of @ada@m.example:" && said.asksLength && !said.destructive)
        #expect(StandingChoice.lengths.map { StandingSheetSaid.length($0, language: .english) } == [
            "Until you unmute them", "For 30 minutes", "For 1 hour", "For 6 hours", "For 1 day", "For 3 days", "For 7 days",
        ])
        #expect(StandingChoice.Held.allCases.map { StandingSheetSaid.held($0, language: .taiwanese) }.allSatisfy { !$0.hasPrefix("standing.") })
        // A second press while it is up asks nothing more.
        await pages.act(.block, on: Self.ada, in: session)
        #expect(pages.standingAsk == ask)

        // Put down: nothing is sent, and nothing here changes.
        pages.standingAsk = nil
        await pages.answer(ask, StandingChoice(), in: session)
        #expect(await sent(server, to: Self.mute).isEmpty && session.hides.hides.isEmpty && session.notes.count == 4)

        await pages.act(.block, on: Self.ada, in: session)
        let blocking = StandingSheetSaid(ask: try #require(pages.standingAsk))
        #expect(blocking.title(language: .english) == "Block @ada@m.example?" && !blocking.asksLength && blocking.yes(language: .english) == "Block")
    }

    // MARK: - Done, and what is held

    @Test("Muted for an hour without notices, hiding what is held: the source is sent exactly that, the page says muted and until when, and each post of theirs is drawn as hidden here saying why — nobody else's; unmuted, the source is told and they show again")
    func mutedAndHidden() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()),
            // An end far off, so the hide stands whenever the check runs: what it is checked at is said below.
            Self.mute: Self.answered(Self.standing(muting: true, notices: false, until: "2126-10-20T12:02:07Z")),
            Self.unmute: Self.answered(Self.standing()),
        ])
        try await signIn(session)
        await hold(session)
        let pages = await opened(Self.ada, in: session)
        await pages.act(.mute, on: Self.ada, in: session)
        let ask = try #require(pages.standingAsk)
        await pages.answer(ask, StandingChoice(held: .hide, notices: false, seconds: 3600), in: session)

        #expect(await sent(server, to: Self.mute) == ["POST notifications=false&duration=3600"])
        let after = try #require(pages.stands(to: Self.ada, in: session))
        #expect(after.shown?.muting == true && after.shown?.mutesNotices == false && after.shown?.mutedUntil != nil)
        #expect(after.keeping.first == .unmute && after.missed == nil && pages.standingAsk == nil)
        let hide = try #require(session.hides.hides.first)
        #expect(session.hides.hides.count == 1 && hide.why == .muted && hide.handle == "@ada@m.example" && hide.until == after.shown?.mutedUntil)

        let rows = session.heldPosts(of: Self.ada)
        #expect(rows.count == 2)
        let end = try #require(hide.until)
        #expect(rows.allSatisfy { session.hides.hide(of: $0, at: end.addingTimeInterval(-60)) != nil })
        #expect(rows.allSatisfy { session.hides.hide(of: $0, at: end.addingTimeInterval(1)) == nil }, "the mute's end is the hide's")
        #expect(rows.allSatisfy { session.acting(on: $0).hidden?.words == "Hidden here: you muted @ada@m.example at m.example." })
        let bea = try #require(DummyPerson(handle: "@bea@m.example", host: Self.host))
        let other = try #require(session.heldPosts(of: bea).first)
        #expect(session.acting(on: other).hidden == nil)
        #expect(session.notes.count == 4, "nothing is let go: hidden is drawn, not gone")

        await pages.act(.unmute, on: Self.ada, in: session)
        #expect(await asked(server).contains(Self.unmute))
        #expect(session.hides.hides.isEmpty && rows.allSatisfy { session.acting(on: $0).hidden == nil })
    }

    @Test("Blocked, letting what is held go: the source is sent the block, and every post this device held of them goes but the one the person keeps; nobody else's moves")
    func blockedAndLetGo() async throws {
        let (session, _, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.block: Self.answered(Self.standing(blocking: true)),
        ])
        try await signIn(session)
        await hold(session)
        let pages = await opened(Self.ada, in: session)
        await pages.act(.block, on: Self.ada, in: session)
        await pages.answer(try #require(pages.standingAsk), StandingChoice(held: .letGo), in: session)
        #expect(pages.stands(to: Self.ada, in: session)?.shown?.blocking == true)
        #expect(session.notes.map(\.statusID).compactMap { $0 }.sorted() == ["22", "333", "4444"])
        #expect(session.hides.hides.isEmpty)
    }

    @Test("Blocked, leaving what is held: the block is sent, and everything held stays as it was, drawn as it was")
    func blockedAndLeft() async throws {
        let (session, _, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.block: Self.answered(Self.standing(blocking: true)),
        ])
        try await signIn(session)
        await hold(session)
        let pages = await opened(Self.ada, in: session)
        await pages.act(.block, on: Self.ada, in: session)
        await pages.answer(try #require(pages.standingAsk), StandingChoice(held: .leave), in: session)
        #expect(pages.stands(to: Self.ada, in: session)?.shown?.blocking == true)
        #expect(session.notes.count == 4 && session.hides.hides.isEmpty)
    }

    @Test("A source that fails or refuses says so under the heading, and nothing on this device changes: no hide, nothing let go, the standing as it last said")
    func aFailureChangesNothing() async throws {
        let (session, _, _) = await session([Self.stands: Self.said(Self.standing()), Self.block: Self.down])
        try await signIn(session)
        await hold(session)
        let pages = await opened(Self.ada, in: session)
        for held in StandingChoice.Held.allCases {
            await pages.act(.block, on: Self.ada, in: session)
            await pages.answer(try #require(pages.standingAsk), StandingChoice(held: held), in: session)
            let after = try #require(pages.stands(to: Self.ada, in: session))
            #expect(after.missed == .block && after.shown?.blocking == false)
            #expect(after.headWords(language: .english) == ["Could not block @ada@m.example at m.example."])
            #expect(session.notes.count == 4 && session.hides.hides.isEmpty, "\(held)")
        }
    }

    @Test("A read of how the reader stands, on its way when the mute is pressed, does not undo it: it lands after the answer, and the page goes on saying muted")
    func aReadOnItsWay() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()), Self.mute: Self.answered(Self.standing(muting: true)),
        ])
        try await signIn(session)
        let pages = await opened(Self.ada, in: session)
        await server.hold(Self.stands)
        defer { Task { await server.release(Self.stands) } }
        let standsGuard = watching("the ask of \(Self.stands), held at its server") { await server.release(Self.stands) }
        defer { standsGuard.cancel() }
        let reading = Task { await pages.acts.again(Self.ada, said: pages.said(of: Self.ada, in: session), in: session) }
        await server.arrival(of: Self.stands, times: 2, by: reading)

        await pages.act(.mute, on: Self.ada, in: session)
        await pages.answer(try #require(pages.standingAsk), StandingChoice(held: .leave), in: session)
        #expect(pages.stands(to: Self.ada, in: session)?.shown?.muting == true)
        await server.release(Self.stands)
        await reading.value
        #expect(pages.stands(to: Self.ada, in: session)?.shown?.muting == true, "the read is told to nobody")
    }

    // MARK: - A whole server

    @Test("Blocking the whole server somebody lives on asks first on a sheet that says what it takes away, drawn as a loss; yes, it is one post naming the server, the source is read after, and what this device holds of everybody there is hidden saying so — and it is never offered of somebody of the source's own server")
    func aWholeServer() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()),
            Self.farStands: Self.said(Self.standing("43")),
            Self.servers: PageServer.Answer(body: "{}"),
        ])
        try await signIn(session)
        await hold(session)
        let pages = await opened(Self.far, in: session)
        #expect(pages.stands(to: Self.far, in: session)?.keeping == [.mute, .block, .blockServer])
        await pages.act(.blockServer, on: Self.far, in: session)
        let ask = try #require(pages.standingAsk)
        let said = StandingSheetSaid(ask: ask)
        #expect(ask.server == "far.example" && ask.held == 1 && said.destructive && !said.asksLength)
        #expect(said.title(language: .english) == "Block all of far.example?")
        #expect(said.line(language: .english).contains("Everybody you follow there is unfollowed"))
        #expect(said.heldTitle(language: .english) == "This device holds 1 post from somebody on far.example:")

        await server.answer(Self.farStands, Self.said(Self.standing("43", server: true)))
        await pages.answer(ask, StandingChoice(held: .hide), in: session)
        #expect(await sent(server, to: Self.servers) == ["POST domain=far.example"])
        #expect(pages.stands(to: Self.far, in: session)?.shown?.serverBlocked == true)
        #expect(session.hides.hides.map(\.why) == [.server] && session.hides.hides.first?.server == "far.example")
        let row = try #require(session.heldPosts(of: Self.far).first)
        #expect(session.acting(on: row).hidden?.words == "Hidden here: you blocked everybody on far.example at m.example.")
        #expect(session.heldPosts(of: Self.ada).allSatisfy { session.acting(on: $0).hidden == nil })

        await server.answer(Self.servers, PageServer.Answer(body: "{}"))
        await server.answer(Self.farStands, Self.said(Self.standing("43")))
        await pages.act(.unblockServer, on: Self.far, in: session)
        #expect(await sent(server, to: Self.servers).last == "DELETE domain=far.example")
        #expect(session.hides.hides.isEmpty && pages.stands(to: Self.far, in: session)?.shown?.serverBlocked == false)

        let local = await opened(Self.ada, in: session)
        #expect(local.stands(to: Self.ada, in: session)?.keeping.contains(.blockServer) == false)
        await local.act(.blockServer, on: Self.ada, in: session)
        #expect(local.standingAsk == nil)
    }

    // MARK: - Done at the source, whatever became of the page

    @Test("A server blocked at the source is treated as answered though how it stands could not be read after: what is held of everybody there is hidden; and taken back the same way, it shows again")
    func doneThoughUnread() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing()),
            Self.farStands: Self.said(Self.standing("43")),
            Self.servers: PageServer.Answer(body: "{}"),
        ])
        try await signIn(session)
        await hold(session)
        let pages = await opened(Self.far, in: session)
        await pages.act(.blockServer, on: Self.far, in: session)
        let ask = try #require(pages.standingAsk)
        await server.answer(Self.farStands, Self.down)
        await pages.answer(ask, StandingChoice(held: .hide), in: session)
        #expect(await sent(server, to: Self.servers) == ["POST domain=far.example"])
        #expect(pages.stands(to: Self.far, in: session)?.reading == .failed, "how it stands could not be read")
        #expect(session.hides.hides.map(\.server) == ["far.example"], "and it was done all the same")

        await server.answer(Self.farStands, Self.said(Self.standing("43", server: true)))
        await pages.acts.again(Self.far, said: pages.said(of: Self.far, in: session), in: session)
        await server.answer(Self.farStands, Self.down)
        await pages.act(.unblockServer, on: Self.far, in: session)
        #expect(await sent(server, to: Self.servers).last == "DELETE domain=far.example")
        #expect(session.hides.hides.isEmpty)
    }

    @Test("A mute taken back at the source while its page was let go still shows what was hidden of them: the source did it")
    func undoneThoughLetGo() async throws {
        let (session, server, _) = await session([
            Self.stands: Self.said(Self.standing(muting: true)), Self.unmute: Self.answered(Self.standing()),
        ])
        try await signIn(session)
        session.hides.hide("@ada@m.example", at: Self.host, .muted)
        let pages = await opened(Self.ada, in: session)
        await server.hold(Self.unmute)
        defer { Task { await server.release(Self.unmute) } }
        let unmuteGuard = watching("the ask of \(Self.unmute), held at its server") { await server.release(Self.unmute) }
        defer { unmuteGuard.cancel() }
        let pressed = Task { await pages.act(.unmute, on: Self.ada, in: session) }
        await server.arrival(of: Self.unmute, by: pressed)
        pages.acts.letGo(at: Self.host)
        await server.release(Self.unmute)
        await pressed.value
        #expect(session.hides.hides.isEmpty)
    }

    // MARK: - Taken back elsewhere

    @Test("A mute or a block taken back elsewhere hides nothing more once a read here says so — of a page and of a row of a list alike — but a read that set out before a hide was made says nothing of it")
    func takenBackElsewhere() async throws {
        let (session, server, _) = await session([Self.stands: Self.said(Self.standing())])
        try await signIn(session)
        session.hides.hide("@ada@m.example", at: Self.host, .muted)
        session.hides.hide("@ada@m.example", at: Self.host, .blocked)
        _ = await opened(Self.ada, in: session)
        #expect(session.hides.hides.isEmpty, "the source says neither is so")

        // A read on its way when the hide is made is older than it.
        let pages = await opened(Self.ada, in: session)
        await server.hold(Self.stands)
        defer { Task { await server.release(Self.stands) } }
        let standsGuard = watching("the ask of \(Self.stands), held at its server") { await server.release(Self.stands) }
        defer { standsGuard.cancel() }
        let reading = Task { await pages.acts.again(Self.ada, said: pages.said(of: Self.ada, in: session), in: session) }
        await server.arrival(of: Self.stands, times: 3, by: reading)
        session.hides.hide("@ada@m.example", at: Self.host, .muted)
        await server.release(Self.stands)
        await reading.value
        #expect(session.hides.hides.map(\.why) == [.muted])

        // A row of the reader's list of whom they mute, which the source says they no longer do.
        let lists = pages.lists
        await server.answer("/api/v1/mutes?limit=80", PageServer.Answer(body: #"[{"id":"42","acct":"ada","username":"ada"}]"#))
        await lists.opened(PeopleList(.muted, at: Self.host), in: session)
        #expect(session.hides.hides.isEmpty)
    }

    // MARK: - What is kept

    @Test("What is hidden is kept as the person's own list: written down, read back by the next launch, never written over what could not be read, and let go with its source")
    func theHidesAreKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "fediqo.hides.\(UUID().uuidString)"))
        let kept = ShellHides(defaults: defaults)
        kept.hide("@ada@m.example", at: "M.Example", .blocked)
        kept.hide(server: "Far.Example", at: Self.host)
        let again = ShellHides(defaults: defaults)
        #expect(again.hides == kept.hides && again.hides.count == 2)
        again.letGo(at: Self.host)
        #expect(ShellHides(defaults: defaults).hides.isEmpty)

        defaults.set(Data("not a list".utf8), forKey: ShellHides.key)
        let unread = ShellHides(defaults: defaults)
        unread.hide("@ada@m.example", at: Self.host, .muted)
        #expect(unread.unreadable && defaults.data(forKey: ShellHides.key) == Data("not a list".utf8))

        // Readable later — a device unlocked after the launch: read again before it is next
        // asked, with what was chosen meanwhile laid over it and written down.
        let written = try #require(UserDefaults(suiteName: "fediqo.hides.\(UUID().uuidString)"))
        written.set(Data("locked".utf8), forKey: ShellHides.key)
        let later = ShellHides(defaults: written)
        later.hide("@ada@m.example", at: Self.host, .muted)
        #expect(later.unreadable && later.hides.count == 1)
        // What the other run had written is now readable.
        let other = try #require(UserDefaults(suiteName: "fediqo.hides.\(UUID().uuidString)"))
        let writer = ShellHides(defaults: other)
        writer.hide("@bea@m.example", at: Self.host, .blocked)
        written.set(other.data(forKey: ShellHides.key), forKey: ShellHides.key)
        let row = try #require(DummyItem(Note(
            id: "https://m.example/9", source: Self.source, author: "Bea", handle: "@bea@m.example", body: "x",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public]
        )) as DummyItem?)
        #expect(later.hide(of: row)?.why == .blocked && !later.unreadable)
        #expect(Set(later.hides.compactMap(\.handle)) == ["@ada@m.example", "@bea@m.example"])
        #expect(Set(ShellHides(defaults: written).hides.compactMap(\.handle)) == ["@ada@m.example", "@bea@m.example"], "and written down")
    }
}
