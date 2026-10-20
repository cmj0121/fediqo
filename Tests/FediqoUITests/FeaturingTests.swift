import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #315, #318, featuring: somebody featured on the reader's profile from their page, a hashtag
/// from its page, and what somebody else features drawn on theirs — what is asked and when,
/// what stands where the sign-in lacks the account part, and what is absent where the host has
/// none of it, and from what alone that is concluded.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made the ask where a check can name it: a held ask is let go by the check, and by a guard
/// when the run has gone still; every deadline is on a clock nobody turns.
@MainActor
@Suite("Featuring people and hashtags on a profile", .serialized, .watched)
struct FeaturingTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let follows = "\(reads) read:follows write:follows"
    /// A sign-in that holds who the reader follows and the account part.
    private static let featuring = "\(follows) write:accounts"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let stands = "/api/v1/accounts/relationships?id%5B%5D=42"
    private static let endorse = "/api/v1/accounts/42/endorse"
    private static let unendorse = "/api/v1/accounts/42/unendorse"
    private static let theirTags = "/api/v1/accounts/42/featured_tags"
    private static let theirPeople = "/api/v1/accounts/42/endorsements?limit=1"
    private static let ownTags = "/api/v1/featured_tags"
    private static let tagAsked = "/api/v1/tags/swift"
    private static let swift = PostTag("#swift")!

    private static let ada = DummyPerson(handle: "@ada@m.example", host: host)!
    private static let notFound = PageServer.Answer(body: #"{"error":"Not Found"}"#, status: 404)
    private static let down = PageServer.Answer(body: "<html>", status: 500)

    private static func standing(following: Bool = true, endorsed: Bool = false) -> String {
        #"{"id":"42","following":\#(following),"showing_reblogs":\#(following),"notifying":false,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":\#(endorsed),"note":""}"#
    }

    private static func featured(_ name: String = "swift", id: String = "5", count: String = "41", last: String = "2026-10-03") -> String {
        #"{"id":"\#(id)","name":"\#(name)","url":"https://m.example/@ada/tagged/\#(name)","statuses_count":"\#(count)","last_status_at":"\#(last)"}"#
    }

    private static func tag(featuring: Bool?) -> PageServer.Answer {
        let said = featuring.map { #","featuring":\#($0)"# } ?? ""
        return PageServer.Answer(body: #"{"name":"swift","url":"https://m.example/tags/swift","history":[],"following":false\#(said)}"#)
    }

    private static func page() throws -> PersonSaid {
        let person = try MastodonPeople.person(
            from: Data(#"{"id":"42","acct":"ada","display_name":"Ada","statuses_count":3}"#.utf8), source: source
        )
        return PersonSaid(source: host, reading: .said(person), posts: [])
    }

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let me = PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#)
        let server = PageServer(routes.merging([Self.who: me]) { mine, _ in mine })
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

    private func signIn(_ session: ShellSession, holding scopes: String = FeaturingTests.featuring) async throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
    }

    private func asked(_ server: PageServer) async -> [String] {
        await server.asked.filter { $0 != Self.who }
    }

    // MARK: - Somebody featured from their page

    @Test("Somebody the source says the reader follows is offered Feature on your profile first in their page's `…`; pressed, it is one post to their own address as the reader, listed as a write, shown at once and then as the source answered — a mark of its own in the head and on About — and then Take off your profile is offered, which does the same")
    func featuringSomebodyFollowed() async throws {
        let (session, server, work) = await session([
            Self.stands: PageServer.Answer(body: "[\(Self.standing())]"),
            Self.endorse: PageServer.Answer(body: Self.standing(endorsed: true)),
            Self.unendorse: PageServer.Answer(body: Self.standing(endorsed: false)),
        ])
        try await signIn(session)
        let acts = ShellPersonPages().acts
        let page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        let before = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(before.more == [.feature, .unfollow] && before.featurable && before.accountLock == nil)
        let menu = before.menu(head: ["Ada"]) { _ in }
        // Muting and blocking follow them (#314), dim with their own lock where it is not held.
        #expect(menu.head.first == "Ada" && !menu.head.contains(L10n.t("part.account.unasked")))
        #expect(Array(menu.items.map(\.name).prefix(2)) == [PersonActing.name(.feature), PersonActing.name(.unfollow)])
        #expect(Array(menu.items.map(\.name).dropFirst(2)) == before.keeping.map { PersonActing.name($0, server: before.server) })
        #expect(menu.items.first?.isDanger == false && menu.items.first?.look == .live, "plain, and at once")
        #expect(PersonActing.name(.feature, language: .taiwanese) == "在個人檔案上推薦")

        await server.hold(Self.endorse)
        defer { Task { await server.release(Self.endorse) } }
        let endorseGuard = watching("the ask of \(Self.endorse), held at its server") { await server.release(Self.endorse) }
        defer { endorseGuard.cancel() }
        let press = Task { await acts.press(.feature, on: Self.ada, said: page, in: session) }
        await server.arrival(of: Self.endorse, by: press)
        let pressing = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(pressing.doing == .feature && pressing.shown?.featured == true && pressing.more.isEmpty)
        // A read set out while the press is out does not undo it.
        await server.hold(Self.stands)
        defer { Task { await server.release(Self.stands) } }
        let standsGuard = watching("the ask of \(Self.stands), held at its server") { await server.release(Self.stands) }
        defer { standsGuard.cancel() }
        let reading = Task { await acts.again(Self.ada, said: page, in: session) }
        await server.arrival(of: Self.stands, times: 2, by: reading)
        await server.release(Self.endorse)
        #expect(await press.value)
        await server.release(Self.stands)
        await reading.value
        let after = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(after.shown?.featured == true, "the read on its way is told to nobody")
        #expect(after.more == [.unfeature, .unfollow] && after.missed == nil)
        #expect(after.marks(language: .english).map(\.words) == ["You follow them", "On your profile"])
        #expect(after.marks().map(\.symbol).contains(PersonActing.featuredSymbol))
        #expect(work.record.contains { $0.purpose == .write && $0.reached == Self.host })
        #expect(await server.bearers.allSatisfy { $0 == "Bearer tok" })

        #expect(await acts.press(.unfeature, on: Self.ada, said: page, in: session))
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.shown?.featured == false)
        #expect(await asked(server).filter { $0 == Self.endorse || $0 == Self.unendorse } == [Self.endorse, Self.unendorse])
    }

    @Test("Feature is offered only of somebody followed, only where the source said which of the two it is, and only at a host that keeps people featured: absent, never grey, otherwise — and a press where it is not offered sends nothing")
    func featureOnlyWhereFollowed() async throws {
        let (session, server, _) = await session([Self.stands: PageServer.Answer(body: "[\(Self.standing(following: false))]")])
        try await signIn(session)
        let all = ShellPersonPages()
        let page = try Self.page()
        await all.acts.opened(Self.ada, said: page, in: session)
        let stranger = try #require(all.acts.acting(of: Self.ada, said: page, in: session))
        #expect(stranger.more.isEmpty && stranger.press == .follow)
        #expect(await !all.acts.press(.feature, on: Self.ada, said: page, in: session))
        #expect(await !(asked(server)).contains(Self.endorse))

        // Followed, with nothing said of featuring: neither item.
        var said = PersonActing(source: Self.host, named: "@ada", changes: true)
        said.featurable = true
        said.reading = .said(PersonStanding(accountID: "42", following: true))
        #expect(said.more == [.unfollow])
        said.reading = .said(PersonStanding(accountID: "42", following: true, featured: false))
        #expect(said.more == [.feature, .unfollow])
        said.featurable = false
        #expect(said.more == [.unfollow], "a host without people featured has no such item")

        // The host said so this run: no item on the page.
        await server.answer(Self.stands, PageServer.Answer(body: "[\(Self.standing())]"))
        await all.acts.again(Self.ada, said: page, in: session)
        #expect(all.acts.acting(of: Self.ada, said: page, in: session)?.more == [.feature, .unfollow])
        all.more.hosts.notFound(.featuredPeople, at: Self.host, round: all.more.hosts.round(at: Self.host))
        #expect(all.acts.acting(of: Self.ada, said: page, in: session)?.more == [.unfollow])
    }

    @Test("Where the sign-in lacks the account part, Feature is in the `…` dim with the lock, the part's sentence at the menu's head; its press only asks for the part, and nothing is sent")
    func featureWithoutThePart() async throws {
        let (session, server, _) = await session([Self.stands: PageServer.Answer(body: "[\(Self.standing())]")])
        try await signIn(session, holding: Self.follows)
        let acts = ShellPersonPages().acts
        let page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        let acting = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(acting.more == [.feature, .unfollow] && acting.asksForPart(.feature) && !acting.asksForPart(.unfollow))
        let lock = try #require(acting.accountLock)
        #expect(lock.asks)
        var pressed: [PersonAct] = []
        let menu = acting.menu(head: ["Ada"]) { pressed.append($0) }
        #expect(Array(menu.head.prefix(2)) == ["Ada", "This sign-in was not asked to change your profile. Update permission"])
        let item = try #require(menu.items.first)
        #expect(item.look == .dim(.askAgain) && item.symbol == SourceRow.permissionSymbol && item.answers)
        item.press { _ in }
        #expect(pressed == [.feature], "the dim item's press is the act's, which only asks")
        #expect(await !acts.press(.feature, on: Self.ada, said: page, in: session))
        #expect(await !(asked(server)).contains(Self.endorse), "nothing is sent")
        #expect(session.partAsks.open == nil)
        #expect(session.askFor([PersonAct.feature.needs], host: Self.host))
        #expect(session.partAsks.open?.ticked == [.account])
    }

    @Test("A featuring the source refuses says so under the figures, and the source's own sentence under that, in both languages; one the host has no address for is absent for the run, and nothing is said to have failed")
    func featuringRefused() async throws {
        let (session, server, _) = await session([
            Self.stands: PageServer.Answer(body: "[\(Self.standing())]"),
            Self.endorse: PageServer.Answer(body: #"{"error":"Validation failed: You must be following that person"}"#, status: 422),
        ])
        try await signIn(session)
        let all = ShellPersonPages()
        let page = try Self.page()
        await all.acts.opened(Self.ada, said: page, in: session)
        #expect(await !all.acts.press(.feature, on: Self.ada, said: page, in: session))
        let refused = try #require(all.acts.acting(of: Self.ada, said: page, in: session))
        #expect(refused.missed == .feature && refused.shown?.featured == false)
        #expect(refused.headWords(language: .english) == [
            "Could not feature @ada@m.example on your profile at m.example.",
            "m.example says: Validation failed: You must be following that person",
        ])
        #expect(refused.missedWords(language: .taiwanese) == "無法在 m.example 把 @ada@m.example 推薦到你的個人檔案上。")

        await server.answer(Self.endorse, Self.notFound)
        #expect(await !all.acts.press(.feature, on: Self.ada, said: page, in: session))
        let absent = try #require(all.acts.acting(of: Self.ada, said: page, in: session))
        #expect(all.more.hosts.has(.featuredPeople, at: Self.host) == .absent)
        #expect(absent.more == [.unfollow] && absent.missed == nil && absent.headWords().isEmpty)
    }

    // MARK: - What somebody features, on their page

    @Test("Their page opening asks what they feature — their hashtags, and one of the people they feature — as the reader, once a page; About draws the hashtags after their fields, each a row the lamp stops on whose press opens the hashtag, and the line to the people only where the source gave somebody")
    func whatTheyFeatureIsAskedOnOpening() async throws {
        let (session, server, work) = await session([
            Self.theirTags: PageServer.Answer(body: "[\(Self.featured()),\(Self.featured("maps", id: "6", count: "0", last: ""))]"),
            Self.theirPeople: PageServer.Answer(body: #"[{"id":"9","acct":"bea","display_name":"Bea"}]"#),
        ])
        try await signIn(session)
        let all = ShellPersonPages()
        let page = try Self.page()
        let features = all.features
        #expect(features.opening(Self.ada, said: page, in: session) != nil)
        #expect(features.said(of: Self.ada, said: page, own: false, in: session) == nil, "nothing before it is asked")
        await features.opened(Self.ada, said: page, in: session)
        #expect(Set(await asked(server)) == [Self.theirTags, Self.theirPeople])
        #expect(await server.bearers.filter { $0 != "" }.allSatisfy { $0 == "Bearer tok" })
        #expect(work.record.filter { $0.reached == Self.host && $0.purpose == .person }.count >= 2)

        let said = try #require(features.said(of: Self.ada, said: page, own: false, in: session))
        #expect(said.tags.map(\.name) == ["swift", "maps"] && features.ask(of: Self.ada, said: page, in: session) == PageAsking())
        #expect(said.tagsTitle(language: .english) == "Hashtags they feature")
        #expect(said.said(of: said.tags[0], language: .english) == "41 of their posts, the last on Oct 3")
        #expect(said.said(of: said.tags[1], language: .english) == "None of their posts yet")
        #expect(said.said(of: said.tags[1], language: .taiwanese) == "他們還沒有貼文用它")
        #expect(said.spoken(said.tags[0], language: .english).hasPrefix("#swift"))
        let people = try #require(said.people)
        #expect(people.which == .featured && people.accountID == "42" && people.thing == .featuredPeople)
        #expect(said.peopleWords(language: .english) == "People they feature")
        #expect(PeopleSaid.title(people, language: .english) == "People @ada@m.example features")
        #expect(said.press(on: FeaturedSaid.lamp(of: Self.swift)) == .tag(Self.swift))
        #expect(said.press(on: FeaturedSaid.peopleID) == .people(people))

        var about = PersonAboutSaid(source: Self.host, view: "", person: page.person)
        about.featured = said
        #expect(about.blocks.contains(.featuredTags) && about.blocks.contains(.featuredPeople))
        #expect(about.walked.contains(FeaturedSaid.lamp(of: Self.swift)) && about.walked.contains(FeaturedSaid.peopleID))
        #expect(about.press(on: FeaturedSaid.peopleID) == .featured(.people(people)))

        await features.opened(Self.ada, said: page, in: session)
        #expect(await asked(server).count == 2, "asked once a page")

        // Nothing given: no block, and no line.
        let (other, _, _) = await self.session([
            Self.theirTags: PageServer.Answer(body: "[]"), Self.theirPeople: PageServer.Answer(body: "[]"),
        ])
        try await signIn(other)
        let nobody = ShellPersonPages().features
        await nobody.opened(Self.ada, said: page, in: other)
        let none = try #require(nobody.said(of: Self.ada, said: page, own: false, in: other))
        #expect(!none.tagsDrawn && none.people == nil)
        var bare = PersonAboutSaid(source: Self.host, view: "", person: page.person)
        bare.featured = none
        #expect(!bare.blocks.contains(.featuredTags) && !bare.blocks.contains(.featuredPeople))
    }

    @Test("Absent where the host has none: a not-found of the people featured is written down for the run and not asked again; a not-found of somebody's featured hashtags draws no block and is never taken for the host having none; with no sign-in a refusal draws no block and ends no sign-in; a failure is said in the page's toast, and asked again by `r`")
    func absentOnlyFromItsOwnWord() async throws {
        let (session, server, _) = await session([Self.theirTags: Self.notFound, Self.theirPeople: Self.notFound])
        try await signIn(session)
        let all = ShellPersonPages()
        let page = try Self.page()
        await all.features.opened(Self.ada, said: page, in: session)
        let said = try #require(all.features.said(of: Self.ada, said: page, own: false, in: session))
        #expect(!said.tagsDrawn && said.people == nil)
        #expect(all.more.hosts.has(.featuredPeople, at: Self.host) == .absent)
        #expect(all.more.hosts.has(.featuredTags, at: Self.host) != .absent, "somebody's not-found says nothing of the host")

        // Opened afresh: the people featured are not asked again.
        let (again, server2, _) = await self.session([Self.theirTags: Self.down, Self.theirPeople: Self.notFound])
        try await signIn(again)
        let fresh = ShellPersonPages()
        await fresh.features.opened(Self.ada, said: page, in: again)
        await server2.answer(Self.theirTags, PageServer.Answer(body: "[\(Self.featured())]"))
        let failed = try #require(fresh.features.said(of: Self.ada, said: page, own: false, in: again))
        #expect(!failed.tagsDrawn && fresh.features.ask(of: Self.ada, said: page, in: again).failed == [Self.host], "the miss is the toast's")
        #expect(failed.press(on: FeaturedSaid.tagsID) == nil)
        await fresh.features.again(Self.ada, said: page, in: again)
        #expect(fresh.features.said(of: Self.ada, said: page, own: false, in: again)?.tags.map(\.name) == ["swift"])
        #expect(await server2.asked.filter { $0 == Self.theirPeople }.count == 1, "absent: asked no more")
        _ = server

        // With no sign-in, asked as anyone; a refusal is no block and no word about a sign-in.
        let (unsigned, server3, _) = await self.session([
            Self.theirTags: PageServer.Answer(body: #"{"error":"Unauthorized"}"#, status: 401),
            Self.theirPeople: PageServer.Answer(body: "[]"),
        ])
        let anyone = ShellPersonPages()
        await anyone.features.opened(Self.ada, said: page, in: unsigned)
        #expect(await server3.bearers.allSatisfy(\.isEmpty))
        let refused = try #require(anyone.features.said(of: Self.ada, said: page, own: false, in: unsigned))
        #expect(!refused.tagsDrawn && anyone.features.ask(of: Self.ada, said: page, in: unsigned).failed.isEmpty && refused.people == nil)
        #expect(unsigned.mastodon.ended.isEmpty)
        #expect(anyone.more.hosts.has(.featuredTags, at: Self.host) != .absent)

        // A forum's author is asked nothing.
        let forumAuthor = DummyPerson(handle: "@ada@forum.example", host: "forum.example")!
        #expect(anyone.features.opening(forumAuthor, said: PersonSaid(source: "forum.example", reading: .said(page.person!), posts: []), in: unsigned) == nil)
    }

    // MARK: - A hashtag featured from its page

    @Test("What they feature, being asked, is About's toast and a wait Stop stops: stopped, nothing is said to have failed, what comes late lands nowhere, and asking again says nothing of the stop")
    func stopOnWhatTheyFeature() async throws {
        let (session, server, _) = await session([
            Self.theirTags: PageServer.Answer(body: "[\(Self.featured())]"), Self.theirPeople: PageServer.Answer(body: "[]"),
        ])
        try await signIn(session)
        let features = ShellPersonPages().features
        let page = try Self.page()
        #expect(!features.stop(Self.ada), "nothing on the wire: nothing stopped")
        await server.hold(Self.theirTags)
        defer { Task { await server.release(Self.theirTags) } }
        let tagsGuard = watching("the ask of \(Self.theirTags), held at its server") { await server.release(Self.theirTags) }
        defer { tagsGuard.cancel() }
        let opening = Task { await features.opened(Self.ada, said: page, in: session) }
        await server.arrival(of: Self.theirTags, by: opening)
        #expect(features.ask(of: Self.ada, said: page, in: session, language: .english)
            == PageAsking(asking: "Asking m.example for the hashtags they feature…", stoppable: true))
        #expect(features.stop(Self.ada))
        #expect(features.ask(of: Self.ada, said: page, in: session) == PageAsking(stopped: true))
        await server.release(Self.theirTags)
        await opening.value
        #expect(features.said(of: Self.ada, said: page, own: false, in: session)?.tags.isEmpty == true, "what came late landed nowhere")
        await features.again(Self.ada, said: page, in: session)
        #expect(features.ask(of: Self.ada, said: page, in: session) == PageAsking())
        #expect(features.said(of: Self.ada, said: page, own: false, in: session)?.tags.count == 1)
    }

    /// Somebody's whole page as `again` asks it: who they are, how the reader stands, what they
    /// feature, and their posts and what they pinned.
    private static func wholePage(stands: PageServer.Answer = said(standing())) -> [String: PageServer.Answer] {
        [
            "/api/v1/accounts/lookup?acct=ada": PageServer.Answer(body: #"{"id":"42","acct":"ada","display_name":"Ada","statuses_count":3}"#),
            "/api/v1/accounts/42/statuses": PageServer.Answer(body: "[]"),
            "/api/v1/accounts/42/statuses?pinned=true": PageServer.Answer(body: "[]"),
            Self.stands: stands, Self.theirTags: PageServer.Answer(body: "[\(Self.featured())]"),
            Self.theirPeople: PageServer.Answer(body: "[]"),
        ]
    }

    private static func said(_ standing: String) -> PageServer.Answer { PageServer.Answer(body: "[\(standing)]") }

    private func opened(_ pages: ShellPersonPages, on tab: PersonTab, in session: ShellSession) async {
        await pages.opened(Self.ada, in: session)
        await pages.standsOpened(to: Self.ada, in: session)
        await pages.featuredOpened(Self.ada, in: session)
        turn(pages, to: tab, in: session)
        await pages.fronted(Self.ada, in: session)
    }

    private func turn(_ pages: ShellPersonPages, to tab: PersonTab, in session: ShellSession) {
        var lamp: String?
        _ = pages.turn(Self.ada, to: tab, lamp: &lamp, in: session)
    }

    @Test("Stop pressed while asking again reads how the reader stands, or what they feature, ends the press there: nothing after it is asked — not what they feature, not the tab in front — and the toast says the stop, and stays saying it")
    func stopEndsThePressAtItsStep() async throws {
        for held in [Self.stands, Self.theirTags] {
            let (session, server, _) = await session(Self.wholePage())
            try await signIn(session)
            let pages = ShellPersonPages()
            await opened(pages, on: .posts, in: session)
            if held == Self.theirTags {
                // Every tab holds something, so a press that went on past its stop would let it go.
                turn(pages, to: .pinned, in: session)
                await pages.fronted(Self.ada, in: session)
                turn(pages, to: .about, in: session)
            }
            let before = await server.asked
            await server.hold(held)
            defer { Task { await server.release(held) } }
            let heldGuard = watching("the ask of \(held), held at its server") { await server.release(held) }
            defer { heldGuard.cancel() }
            let pull = Task { await pages.again(Self.ada, in: session) }
            await server.arrival(of: held, times: 2, by: pull)
            #expect(pages.ask(of: Self.ada, in: session).stoppable, "\(held)")
            #expect(pages.stop(Self.ada, in: session))
            await server.release(held)
            await pull.value
            let after = Array(await server.asked.dropFirst(before.count))
            // The steps up to the one stopped, in the order `again` takes them, and nothing after.
            let steps = ["/api/v1/accounts/lookup?acct=ada", Self.stands] + (held == Self.stands ? [] : [Self.theirTags, Self.theirPeople])
            #expect(after.allSatisfy(steps.contains), "nothing after the stopped step was asked: \(after)")
            #expect(pages.ask(of: Self.ada, in: session) == PageAsking(stopped: true), "\(held)")
            // And nothing the other tabs held was let go for the press.
            #expect(pages.said(of: Self.ada, in: session)?.posts != nil, "Posts still holds its stretch: \(held)")
            if held == Self.theirTags {
                #expect(pages.pinned(of: Self.ada, in: session)?.answered == true, "Pinned still holds what it was given")
            }
        }
    }

    @Test("A Stop is the page's it was pressed on: Stop on somebody else's page, opened meanwhile, does not end a press still asking on this one, which goes on to its end")
    func aStopOnAnotherPageEndsNothingHere() async throws {
        let bo = try #require(DummyPerson(handle: "@bo@m.example", host: Self.host))
        let boLookup = "/api/v1/accounts/lookup?acct=bo"
        var routes = Self.wholePage()
        routes[boLookup] = PageServer.Answer(body: #"{"id":"43","acct":"bo","display_name":"Bo"}"#)
        let (session, server, _) = await session(routes)
        try await signIn(session)
        let pages = ShellPersonPages()
        await opened(pages, on: .posts, in: session)
        let tags = await server.arrivals(of: Self.theirTags), posts = await server.arrivals(of: "/api/v1/accounts/42/statuses")

        await server.hold(Self.stands)
        await server.hold(boLookup)
        defer { Task { await server.release(Self.stands); await server.release(boLookup) } }
        let heldGuard = watching("the asks of \(Self.stands) and \(boLookup), held at their server") {
            await server.release(Self.stands)
            await server.release(boLookup)
        }
        defer { heldGuard.cancel() }
        let pull = Task { await pages.again(Self.ada, in: session) }
        await server.arrival(of: Self.stands, times: 2, by: pull)
        let other = Task { await pages.opened(bo, in: session) }
        await server.arrival(of: boLookup, by: other)
        #expect(pages.stop(bo, in: session), "Bo's page had its ask out")
        await server.release(Self.stands)
        await pull.value
        #expect(await server.arrivals(of: Self.theirTags) == tags + 1, "what Ada features was asked again")
        #expect(await server.arrivals(of: "/api/v1/accounts/42/statuses") == posts + 1, "and her Posts from the top")
        #expect(!pages.ask(of: Self.ada, in: session).stopped && pages.ask(of: bo, in: session).stopped)
        await server.release(boLookup)
        await other.value
    }

    @Test("How the reader stands is waited on in the toast on every tab, as the head says it on every tab; that it failed is said on About and Posts, and not on a tab of what they pinned or of people")
    func whereTheStandingIsSaid() async throws {
        let (session, server, _) = await session(Self.wholePage(stands: Self.down))
        try await signIn(session)
        let pages = ShellPersonPages()
        await opened(pages, on: .posts, in: session)
        #expect(pages.ask(of: Self.ada, in: session).failed == [Self.host], "Posts")
        turn(pages, to: .about, in: session)
        #expect(pages.ask(of: Self.ada, in: session).failed == [Self.host], "About")
        turn(pages, to: .pinned, in: session)
        await pages.fronted(Self.ada, in: session)
        #expect(pages.ask(of: Self.ada, in: session) == PageAsking(), "Pinned says nothing of the standing's miss")

        await server.answer(Self.stands, Self.said(Self.standing()))
        await server.hold(Self.stands)
        defer { Task { await server.release(Self.stands) } }
        let standsGuard = watching("the ask of \(Self.stands), held at its server") { await server.release(Self.stands) }
        defer { standsGuard.cancel() }
        let asking = Task { await pages.acts.again(Self.ada, said: pages.said(of: Self.ada, in: session), in: session) }
        await server.arrival(of: Self.stands, times: 2, by: asking)
        #expect(pages.ask(of: Self.ada, in: session, language: .english)
            == PageAsking(asking: "Asking m.example how you stand to them…", stoppable: true), "its wait is said on Pinned too")
        await server.release(Self.stands)
        await asking.value
    }

    @Test("A hashtag's About has a feature row under each source's follow row; at a Mastodon whose answer says whether it is featured nothing more is asked; Feature is one post naming it, as the reader, listed as a write; then the row's `…` holds Take off your profile, which reads the reader's own featured hashtags for the featuring's id and takes it off")
    func aHashtagFeatured() async throws {
        let (session, server, work) = await session([
            Self.tagAsked: Self.tag(featuring: false),
            Self.ownTags: PageServer.Answer(body: "[\(Self.featured())]"),
            "/api/v1/featured_tags/5": PageServer.Answer(body: "{}"),
        ])
        try await signIn(session)
        let tags = ShellPersonPages().tags
        await tags.featuresOpened(Self.swift, in: session)
        #expect(await asked(server) == [Self.tagAsked], "the hashtag's own answer said: nothing more is asked")
        let lines = tags.featureLines(of: Self.swift, in: session)
        #expect(lines.map(\.standing) == [.said(false)])
        let line = try #require(lines.first)
        #expect(line.press == .feature && line.pressWords(language: .english) == "Feature")
        #expect(line.words(language: .english) == "At m.example: not on your profile.")
        #expect(line.pressSpoken(language: .english) == "Feature #swift on your profile at m.example")
        let about = try #require(tags.about(of: Self.swift, in: session))
        #expect(about.features == lines && about.walked.contains(line.id) && about.featurePress(on: line.id) == line)

        // The featuring made is answered alone; the list, when it is read, as a list.
        await server.answer(Self.ownTags, PageServer.Answer(body: Self.featured()))
        await tags.featurePressed(line, in: session)?.value
        let sent = await server.sent.filter { $0.ask == Self.ownTags }
        #expect(sent.map(\.method) == ["POST"] && sent.first?.body == "name=swift")
        #expect(work.record.contains { $0.purpose == .write })
        let featured = try #require(tags.featureLines(of: Self.swift, in: session).first)
        #expect(featured.standing == .said(true) && featured.press == nil && featured.offers == .unfeature)
        #expect(featured.more(act: {}) != nil && featured.words(language: .taiwanese) == "在 m.example：在你的個人檔案上。")

        await server.answer(Self.ownTags, PageServer.Answer(body: "[\(Self.featured())]"))
        await tags.unfeatured(featured, in: session)?.value
        #expect(await asked(server).suffix(2) == [Self.ownTags, "/api/v1/featured_tags/5"])
        #expect(tags.featureLines(of: Self.swift, in: session).map(\.standing) == [.said(false)])
    }

    @Test("Where the hashtag's answer does not say whether it is featured, the reader's own featured hashtags are asked of that source once a run and the hashtag found among them; the reader's own list answered not-found is absent for the run, and so is featuring one refused as not taken at all (405) — no row and no failure; a refusal in the source's words is said under the row")
    func aHashtagWhereTheAnswerDoesNotSay() async throws {
        let (session, server, _) = await session([
            Self.tagAsked: Self.tag(featuring: nil), Self.ownTags: PageServer.Answer(body: "[\(Self.featured("maps", id: "6"))]"),
        ])
        try await signIn(session)
        let all = ShellPersonPages()
        let tags = all.tags
        await tags.featuresOpened(Self.swift, in: session)
        #expect(await asked(server) == [Self.tagAsked, Self.ownTags])
        #expect(tags.featureLines(of: Self.swift, in: session).map(\.standing) == [.said(false)])
        tags.closed(Self.swift)
        await tags.featuresOpened(Self.swift, in: session)
        #expect(await asked(server).filter { $0 == Self.ownTags }.count == 1, "once a run a source")

        // Refused in the source's words.
        await server.answer(Self.ownTags, PageServer.Answer(body: #"{"error":"Validation failed: Tag has already been taken"}"#, status: 422))
        let line = try #require(tags.featureLines(of: Self.swift, in: session).first)
        await tags.featurePressed(line, in: session)?.value
        let refused = try #require(tags.featureLines(of: Self.swift, in: session).first)
        #expect(refused.standing == .said(false) && refused.missed == true)
        #expect(refused.missedWords(language: .english) == "Could not feature #swift on your profile at m.example.")
        #expect(refused.refusedWords(language: .english) == "m.example says: Validation failed: Tag has already been taken")

        // Not taken at all: absent for the run, with nothing said to have failed.
        await server.answer(Self.ownTags, PageServer.Answer(body: "", status: 405))
        await tags.featurePressed(refused, in: session)?.value
        #expect(all.more.hosts.has(.featuredTags, at: Self.host) == .absent)
        #expect(tags.featureLines(of: Self.swift, in: session).isEmpty)
        #expect(tags.about(of: Self.swift, in: session)?.features.isEmpty == true, "no row — never grey")

        // The reader's own list not found: absent too.
        let (other, otherServer, _) = await self.session([Self.tagAsked: Self.tag(featuring: nil), Self.ownTags: Self.notFound])
        try await signIn(other)
        let fresh = ShellPersonPages()
        await fresh.tags.featuresOpened(Self.swift, in: other)
        #expect(await otherServer.asked.contains(Self.ownTags))
        #expect(fresh.more.hosts.has(.featuredTags, at: Self.host) == .absent && fresh.tags.featureLines(of: Self.swift, in: other).isEmpty)
    }

    @Test("Where the sign-in lacks the account part the feature row is that part's lock, dim, and its press asks for the part and sends nothing; with no sign-in, or at a forum, there is no row")
    func aHashtagWithoutThePart() async throws {
        let (session, server, _) = await session([Self.tagAsked: Self.tag(featuring: false)])
        try await signIn(session, holding: Self.follows)
        let tags = ShellPersonPages().tags
        await tags.featuresOpened(Self.swift, in: session)
        let line = try #require(tags.featureLines(of: Self.swift, in: session).first)
        #expect(line.isLocked && line.offers == .ask && line.press == .ask)
        #expect(line.words(language: .english) == "At m.example: This sign-in was not asked to change your profile. Update permission")
        #expect(tags.featurePressed(line, in: session) == nil)
        #expect(session.partAsks.open?.ticked == [.account] && session.partAsks.open?.host == Self.host)
        #expect(await asked(server) == [Self.tagAsked], "nothing is sent")

        let (unsigned, _, _) = await self.session([:])
        #expect(ShellPersonPages().tags.featureLines(of: Self.swift, in: unsigned).isEmpty)
    }

    @Test("A signed-in reader refused what somebody features goes the way every read does — said as a failure, not as nothing; and a page let go of what it was told is asked afresh when it opens again")
    func aSignedInRefusalAndAPageLetGo() async throws {
        let (session, server, _) = await session([
            Self.theirTags: PageServer.Answer(body: #"{"error":"Unauthorized"}"#, status: 401),
            Self.theirPeople: PageServer.Answer(body: "[]"),
        ])
        try await signIn(session)
        let features = ShellPersonPages().features
        let page = try Self.page()
        await features.opened(Self.ada, said: page, in: session)
        #expect(features.ask(of: Self.ada, said: page, in: session).failed == [Self.host])

        features.forget(Self.ada.id)
        #expect(features.said(of: Self.ada, said: page, own: false, in: session) == nil)
        await features.opened(Self.ada, said: page, in: session)
        #expect(await server.asked.filter { $0 == Self.theirTags }.count == 2, "asked afresh")
    }

    @Test("A hashtag featured while a read of it is on its way stays featured when that read lands saying otherwise: the press is the newer word")
    func aHashtagFeaturedOverARead() async throws {
        let (session, server, _) = await session([
            Self.tagAsked: Self.tag(featuring: false), Self.ownTags: PageServer.Answer(body: Self.featured()),
        ])
        try await signIn(session)
        let tags = ShellPersonPages().tags
        await tags.featuresOpened(Self.swift, in: session)
        let line = try #require(tags.featureLines(of: Self.swift, in: session).first)

        await server.hold(Self.ownTags)
        defer { Task { await server.release(Self.ownTags) } }
        let ownGuard = watching("the ask of \(Self.ownTags), held at its server") { await server.release(Self.ownTags) }
        defer { ownGuard.cancel() }
        let press = tags.featurePressed(line, in: session)
        await server.arrival(of: Self.ownTags, by: try #require(press))
        #expect(tags.featureLines(of: Self.swift, in: session).map(\.standing) == [.doing(true)])

        // The page left and opened again while the press is out: its hashtag read again, and held.
        tags.closed(Self.swift)
        await server.hold(Self.tagAsked)
        defer { Task { await server.release(Self.tagAsked) } }
        let tagGuard = watching("the ask of \(Self.tagAsked), held at its server") { await server.release(Self.tagAsked) }
        defer { tagGuard.cancel() }
        let reading = Task { await tags.opened(Self.swift, in: session) }
        await server.arrival(of: Self.tagAsked, times: 2, by: reading)
        await server.release(Self.ownTags)
        await press?.value
        await server.release(Self.tagAsked)
        await reading.value
        #expect(tags.featureLines(of: Self.swift, in: session).map(\.standing) == [.said(true)], "the read on its way does not undo it")
    }

    // MARK: - On the reader's own page

    private static let me = DummyPerson(handle: "@me@m.example", host: host)!
    private static let myTags = "/api/v1/accounts/7/featured_tags"
    private static let myPeople = "/api/v1/accounts/7/endorsements?limit=1"
    private static let myList = "/api/v1/accounts/7/endorsements?limit=80"

    private static func myPage() throws -> PersonSaid {
        let person = try MastodonPeople.person(from: Data(#"{"id":"7","acct":"me","display_name":"Me"}"#.utf8), source: source)
        return PersonSaid(source: host, reading: .said(person), posts: [])
    }

    @Test("On the reader's own page a featured hashtag's row has Take off your profile in its `…`: plain, by the featuring's own id, the row leaving at the press and gone once answered, back with a sentence where it did not arrive; without the account part it is dim with the lock and its press asks; on anybody else's page there is no `…`")
    func takeOffOnYourOwnPage() async throws {
        let (session, server, _) = await session([
            Self.myTags: PageServer.Answer(body: "[\(Self.featured()),\(Self.featured("maps", id: "6"))]"),
            Self.myPeople: PageServer.Answer(body: "[]"),
            "/api/v1/featured_tags/5": PageServer.Answer(body: "{}"),
            "/api/v1/featured_tags/6": Self.down,
        ])
        try await signIn(session)
        let all = ShellPersonPages()
        let page = try Self.myPage()
        #expect(ShellPersonPages.own(at: Self.host, in: session)?.id == Self.me.id)
        await all.features.opened(Self.me, said: page, in: session)
        let said = try #require(all.featured(of: Self.me, in: session) ?? all.features.said(of: Self.me, said: page, own: true, in: session))
        #expect(said.own && said.takesOff && said.accountLock == nil)
        #expect(said.tagsTitle(language: .english) == "Hashtags you feature")
        let swift = try #require(said.tags.first)
        let more = try #require(said.more(of: swift, act: {}, language: .english))
        #expect(more.items.map(\.name) == ["Take off your profile"] && more.items.first?.isDanger == false)
        #expect(FeaturedSaid(source: Self.host, tags: said.tags).more(of: swift, act: {}) == nil, "nobody else's page has it")

        await all.features.takeOff(Self.swift, of: Self.me, said: page, in: session)
        #expect(await server.asked.contains("/api/v1/featured_tags/5"))
        let after = try #require(all.features.said(of: Self.me, said: page, own: true, in: session))
        #expect(after.tags.map(\.name) == ["maps"])

        await all.features.takeOff(PostTag("#maps")!, of: Self.me, said: page, in: session)
        let failed = try #require(all.features.said(of: Self.me, said: page, own: true, in: session))
        #expect(failed.tags.map(\.name) == ["maps"])
        #expect(failed.missed == [String(format: L10n.t("tag.feature.failed.unfeature"), "#maps", Self.host)])

        // Without the account part: dim with the lock, and the press asks.
        try await signIn(session, holding: Self.follows)
        await all.features.opened(Self.me, said: page, in: session)
        let locked = try #require(all.features.said(of: Self.me, said: page, own: true, in: session))
        let lock = try #require(locked.accountLock)
        #expect(lock.asks)
        let tag = try #require(locked.tags.first)
        let dim = try #require(locked.more(of: tag, act: {})?.items.first)
        #expect(dim.look == .dim(.askAgain) && dim.symbol == SourceRow.permissionSymbol)
        let sent = await server.asked.count
        await all.features.takeOff(tag.tag, of: Self.me, said: page, in: session)
        #expect(session.partAsks.open?.ticked == [.account])
        #expect(await server.asked.count == sent, "nothing is sent")
    }

    @Test("The reader's own people featured are their own list — titled so — and a row's `…` holds Take off your profile, plain, sent through the one sequence a press on somebody's page is: the row leaves and is gone once answered; without the account part it is dim and asks")
    func takeOffOnYourOwnList() async throws {
        let bea = #"{"id":"9","acct":"bea","display_name":"Bea"}"#
        let beaStands = "/api/v1/accounts/relationships?id%5B%5D=9"
        let standing = Self.standing(endorsed: true).replacingOccurrences(of: #""id":"42""#, with: #""id":"9""#)
        let unstanding = Self.standing(endorsed: false).replacingOccurrences(of: #""id":"42""#, with: #""id":"9""#)
        let (session, server, work) = await session([
            Self.myList: PageServer.Answer(body: "[\(bea)]"),
            beaStands: PageServer.Answer(body: "[\(standing)]"),
            "/api/v1/accounts/9/unendorse": PageServer.Answer(body: unstanding),
        ])
        try await signIn(session)
        let lists = ShellPersonPages().lists
        let me = try #require(try Self.myPage().person)
        let list = PeopleList(featuredBy: me)
        await lists.opened(list, in: session)
        let said = try #require(lists.said(of: list, in: session))
        #expect(said.own && said.acts == [.unfeature] && said.takesOff && said.accountLock == nil)
        #expect(said.title(language: .english) == "People you feature at m.example")
        #expect(said.title(language: .taiwanese) == "你在 m.example 推薦的人")
        #expect(PeopleSaid.title(list, language: .english) == "People @me@m.example features")
        let person = try #require(said.people.first)
        let menu = try #require(PeoplePane.menu(for: said, of: person, asks: .constant(nil)) { _ in })
        #expect(menu.more().items.map(\.name) == [PersonActing.name(.unfeature)] && menu.more().dangers.isEmpty)

        await lists.press(.unfeature, on: person, of: list, in: session)
        #expect(await server.asked.contains("/api/v1/accounts/9/unendorse"))
        #expect(work.record.contains { $0.purpose == .write })
        #expect(lists.said(of: list, in: session)?.people.isEmpty == true, "gone once answered")

        // Without the account part.
        try await signIn(session, holding: Self.follows)
        await lists.again(list, in: session)
        let locked = try #require(lists.said(of: list, in: session))
        #expect(locked.acts.isEmpty && locked.accountLock?.asks == true)
        let row = try #require(locked.people.first)
        let dim = try #require(PeoplePane.menu(for: locked, of: row, asks: .constant(nil)) { _ in }?.more().items.first)
        #expect(dim.look == .dim(.askAgain))
        let sent = await server.asked.count
        await lists.press(.unfeature, on: row, of: list, in: session)
        let after = await server.asked.count
        #expect(session.partAsks.open?.ticked == [.account] && after == sent)

        // Somebody else's list of the people they feature has no such item.
        let theirs = PeopleSaid(list: PeopleList(featuredBy: Person(source: Self.source, accountID: "42", handle: "@ada@m.example", name: "Ada")), reading: .said)
        #expect(!theirs.takesOff)
    }

    @Test("A hashtag taken off from the reader's own page while their hashtags are being read again stays off when that read lands still listing it: the answer is the newer word; a read begun after it is the list")
    func takeOffOverARead() async throws {
        let (session, server, _) = await session([
            Self.myTags: PageServer.Answer(body: "[\(Self.featured()),\(Self.featured("maps", id: "6"))]"),
            Self.myPeople: PageServer.Answer(body: "[]"),
            "/api/v1/featured_tags/5": PageServer.Answer(body: "{}"),
        ])
        try await signIn(session)
        let features = ShellPersonPages().features
        let page = try Self.myPage()
        await features.opened(Self.me, said: page, in: session)

        await server.hold(Self.myTags)
        defer { Task { await server.release(Self.myTags) } }
        let tagsGuard = watching("the ask of \(Self.myTags), held at its server") { await server.release(Self.myTags) }
        defer { tagsGuard.cancel() }
        let reading = Task { await features.again(Self.me, said: page, in: session) }
        await server.arrival(of: Self.myTags, times: 2, by: reading)
        #expect(features.said(of: Self.me, said: page, own: true, in: session)?.tags.map(\.name) == ["swift", "maps"], "what was said stands")
        await features.takeOff(Self.swift, of: Self.me, said: page, in: session)
        await server.release(Self.myTags)
        await reading.value
        #expect(features.said(of: Self.me, said: page, own: true, in: session)?.tags.map(\.name) == ["maps"], "the read on its way does not bring it back")

        await features.again(Self.me, said: page, in: session)
        #expect(features.said(of: Self.me, said: page, own: true, in: session)?.tags.map(\.name) == ["swift", "maps"], "a read begun after it is the source's word")
    }

    @Test("A Take off that did not arrive on the reader's own people featured is said under the row until that list is read again — reading another list holding them leaves it")
    func aMissedTakeOffStaysOnItsList() async throws {
        let bea = #"{"id":"9","acct":"bea","display_name":"Bea"}"#
        let standing = Self.standing(endorsed: true).replacingOccurrences(of: #""id":"42""#, with: #""id":"9""#)
        let (session, _, _) = await session([
            Self.myList: PageServer.Answer(body: "[\(bea)]"),
            "/api/v1/accounts/7/followers?limit=80": PageServer.Answer(body: "[\(bea)]"),
            "/api/v1/accounts/relationships?id%5B%5D=9": PageServer.Answer(body: "[\(standing)]"),
            "/api/v1/accounts/9/unendorse": Self.down,
        ])
        try await signIn(session)
        let lists = ShellPersonPages().lists
        let me = try #require(try Self.myPage().person)
        let featured = PeopleList(featuredBy: me)
        await lists.opened(featured, in: session)
        let person = try #require(lists.said(of: featured, in: session)?.people.first)
        await lists.press(.unfeature, on: person, of: featured, in: session)
        #expect(lists.said(of: featured, in: session)?.missed["9"] != nil)

        await lists.opened(PeopleList(.followers, of: me), in: session)
        #expect(lists.said(of: featured, in: session)?.missed["9"] != nil, "another list read from the top leaves it")
        await lists.again(featured, in: session)
        #expect(lists.said(of: featured, in: session)?.missed["9"] == nil, "its own list read again takes it down")
    }

    @Test("A person's page let go of the pages kept forgets what they feature: opened again, it is asked afresh")
    func aPageLetGoIsAskedAfresh() async throws {
        var routes: [String: PageServer.Answer] = [
            "/api/v1/accounts/0/featured_tags": PageServer.Answer(body: "[\(Self.featured())]"),
            "/api/v1/accounts/0/endorsements?limit=1": PageServer.Answer(body: "[]"),
        ]
        for n in 0...ShellPersonPages.kept {
            routes["/api/v1/accounts/lookup?acct=p\(n)"] = PageServer.Answer(body: #"{"id":"\#(n)","acct":"p\#(n)","display_name":"P\#(n)"}"#)
        }
        let (session, server, _) = await session(routes)
        try await signIn(session)
        let all = ShellPersonPages()
        let people = (0...ShellPersonPages.kept).map { DummyPerson(handle: "@p\($0)@m.example", host: Self.host)! }
        await all.opened(people[0], in: session)
        await all.featuredOpened(people[0], in: session)
        #expect(all.featured(of: people[0], in: session)?.tags.map(\.name) == ["swift"])
        for person in people.dropFirst() { await all.opened(person, in: session) }
        #expect(all.featured(of: people[0], in: session) == nil, "let go with the page")

        await all.opened(people[0], in: session)
        await all.featuredOpened(people[0], in: session)
        #expect(await server.asked.filter { $0 == "/api/v1/accounts/0/featured_tags" }.count == 2, "asked afresh")
        #expect(all.featured(of: people[0], in: session)?.tags.map(\.name) == ["swift"])
    }

    @Test("What somebody features, answered after the sign-in changed while it was out, lands nowhere: the next reader is shown none of it, and is asked for their own")
    func aLateAnswerLandsNowhere() async throws {
        let (session, server, _) = await session([
            Self.theirTags: PageServer.Answer(body: "[\(Self.featured())]"),
            Self.theirPeople: PageServer.Answer(body: #"[{"id":"9","acct":"bea"}]"#),
        ])
        try await signIn(session)
        let features = ShellPersonPages().features
        let page = try Self.page()
        await server.hold(Self.theirTags)
        await server.hold(Self.theirPeople)
        defer { Task { await server.release(Self.theirTags); await server.release(Self.theirPeople) } }
        let heldGuard = watching("the asks of what Ada features, held at their server") {
            await server.release(Self.theirTags)
            await server.release(Self.theirPeople)
        }
        defer { heldGuard.cancel() }
        let out = Task { await features.opened(Self.ada, said: page, in: session) }
        await server.arrival(of: Self.theirTags, by: out)
        await server.arrival(of: Self.theirPeople, by: out)

        // Signed in afresh, as somebody else, while both are out.
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "other", clientID: "c", clientSecret: "s", scopes: Self.featuring, asked: Self.featuring
        ))
        session.mastodon.refresh()
        await server.release(Self.theirTags)
        await server.release(Self.theirPeople)
        await out.value
        #expect(features.said(of: Self.ada, said: page, own: false, in: session) == nil, "what was asked as the reader before is not the next one's")

        await features.opened(Self.ada, said: page, in: session)
        #expect(await server.asked.filter { $0 == Self.theirTags }.count == 2, "asked afresh, as them")
        #expect(await server.bearers.last == "Bearer other")
        #expect(features.said(of: Self.ada, said: page, own: false, in: session)?.tags.map(\.name) == ["swift"])
    }

    // MARK: - Words and drawing




    @Test("Every sentence of featuring is written in each language the app speaks, with the places it fills, and the two Chinese tables alike")
    func theWords() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        let resources = url.appending(path: "Sources/FediqoUI/Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            let prefixes = ["\"person.act.feature", "\"person.act.unfeature", "\"person.featured.", "\"person.stands.featured", "\"people.featured.", "\"people.title.featured", "\"tag.feature."]
            guard prefixes.contains(where: { line.hasPrefix($0) }) else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        #expect(keys.count == 31)
        func places(_ text: String) -> [String] {
            text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted()
        }
        for key in keys {
            let written = L10n.t(key, language: .english)
            #expect(written != key, "\(key)")
            for language in DummyLanguage.allCases {
                let other = L10n.t(key, language: language)
                #expect(other != key && places(other) == places(written), "\(key) in \(language)")
            }
        }
        let taiwan = try Data(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
    }

    @Test("About with what somebody features, and a hashtag's About with its feature rows, are laid out to the width they are given and never past it, in light and in dark")
    func laidOut() throws {
        func size<Page: View>(_ page: Page, _ width: CGFloat, _ scheme: ColorScheme) -> CGSize {
            let hosted = NSHostingView(rootView: page.frame(width: width).environment(\.colorScheme, scheme))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let person = try #require(try Self.page().person)
        var featured = FeaturedSaid(source: Self.host)
        featured.tags = [FeaturedTag(id: "5", tag: Self.swift, count: 41, last: Date(timeIntervalSince1970: 1_790_000_000))]
        featured.people = PeopleList(featuredBy: person)
        var about = PersonAboutSaid(source: Self.host, view: "As m.example says", person: person)
        about.featured = featured
        var nothing = about
        nothing.featured = FeaturedSaid(source: Self.host)
        let follow = TagFollowLine(host: Self.host, tag: Self.swift, standing: .said(true))
        let rows: [[TagFeatureLine]] = [
            [TagFeatureLine(host: Self.host, tag: Self.swift, standing: .said(false))],
            [TagFeatureLine(host: Self.host, tag: Self.swift, standing: .said(true))],
            [TagFeatureLine(host: Self.host, tag: Self.swift, standing: .said(false), missed: true, refused: "Tag has already been taken")],
            [TagFeatureLine(host: Self.host, tag: Self.swift, standing: .locked(PartWords.Place(kind: .unasked, key: "part.account.unasked")))],
        ]
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (390, .dark), (320, .light), (320, .dark)] {
            for said in [about, nothing] {
                #expect(size(PersonAbout(said: said) { EmptyView() }, width, scheme).width == width)
            }
            for features in rows {
                var tagAbout = TagAboutSaid(follows: [follow])
                tagAbout.features = features
                #expect(size(TagAbout(said: tagAbout) { EmptyView() }, width, scheme).width == width)
            }
        }
    }
}
