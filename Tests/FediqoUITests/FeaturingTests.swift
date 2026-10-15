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
        #expect(menu.head == ["Ada"])
        #expect(menu.items.map(\.name) == [PersonActing.name(.feature), PersonActing.name(.unfollow)])
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
        #expect(menu.head == ["Ada", "This sign-in was not asked to change your profile. Update permission"])
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
        #expect(refused.missedWords(language: .taiwanese) == "無法在 m.example 的個人檔案上推薦 @ada@m.example。")

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
        #expect(said.tags.map(\.name) == ["swift", "maps"] && !said.tagsAsking && !said.tagsFailed)
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

    @Test("Absent where the host has none: a not-found of the people featured is written down for the run and not asked again; a not-found of somebody's featured hashtags draws no block and is never taken for the host having none; with no sign-in a refusal draws no block and ends no sign-in; a failure says so with the press that asks again")
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
        #expect(failed.tagsDrawn && failed.tagsFailed && failed.failedWords(language: .english) == "Could not ask m.example for the hashtags they feature.")
        #expect(failed.press(on: FeaturedSaid.tagsID) == .again)
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
        #expect(!refused.tagsDrawn && !refused.tagsFailed && refused.people == nil)
        #expect(unsigned.mastodon.ended.isEmpty)
        #expect(anyone.more.hosts.has(.featuredTags, at: Self.host) != .absent)

        // A forum's author is asked nothing.
        let forumAuthor = DummyPerson(handle: "@ada@forum.example", host: "forum.example")!
        #expect(anyone.features.opening(forumAuthor, said: PersonSaid(source: "forum.example", reading: .said(page.person!), posts: []), in: unsigned) == nil)
    }

    // MARK: - A hashtag featured from its page

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
        #expect(keys.count == 32)
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
        var asking = about
        asking.featured = FeaturedSaid(source: Self.host, tagsAsking: true)
        var failed = about
        failed.featured = FeaturedSaid(source: Self.host, tagsFailed: true)
        let follow = TagFollowLine(host: Self.host, tag: Self.swift, standing: .said(true))
        let rows: [[TagFeatureLine]] = [
            [TagFeatureLine(host: Self.host, tag: Self.swift, standing: .said(false))],
            [TagFeatureLine(host: Self.host, tag: Self.swift, standing: .said(true))],
            [TagFeatureLine(host: Self.host, tag: Self.swift, standing: .said(false), missed: true, refused: "Tag has already been taken")],
            [TagFeatureLine(host: Self.host, tag: Self.swift, standing: .locked(PartWords.Place(kind: .unasked, key: "part.account.unasked")))],
        ]
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (390, .dark), (320, .light), (320, .dark)] {
            for said in [about, asking, failed] {
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
