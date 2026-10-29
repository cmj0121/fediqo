import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #384, #416, the page: the Dashboard, Trends and Rules tabs of a host's page — the server's
/// figures over a span chosen, said as of when they were read; what waits to rise, let rise or
/// kept back by the rules #381's acts keep; the rules, read, with the way to the server's own page
/// — each tab its own flag's.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`); every deadline is on a
/// clock nobody turns.
@MainActor
@Suite("A host's Dashboard, Trends and Rules tabs: how it is doing, what rises, and its rules", .serialized, .watched)
struct TendingServerTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let tending = "\(reads) admin:read admin:write"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let measures = "/api/v1/admin/measures"
    private static let tags = "/api/v1/admin/trends/tags?limit=20"
    private static let links = "/api/v1/admin/trends/links?limit=20"
    private static let posts = "/api/v1/admin/trends/statuses?limit=20"
    private static let rules = "/api/v1/instance/rules"
    private static let admin = "2097148"
    private static let moderator = "1115420"
    private static let rulesOnly = "4096"
    private static let reportsOnly = "16"
    private static let dashboard = Tending(host: host, tab: .dashboard)
    private static let risingPage = Tending(host: host, tab: .rising)
    private static let rulesPage = Tending(host: host, tab: .rules)
    private static let pages = [dashboard, risingPage, rulesPage]
    private static let now = Date(timeIntervalSince1970: 1_792_658_400)

    private static func check(permissions: String?) -> PageServer.Answer {
        let role = permissions.map { #","role":{"id":"1","name":"Admin","permissions":"\#($0)"}"# } ?? ""
        return PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"\#(role)}"#)
    }

    private static func tag(_ id: String, _ name: String, waiting: Bool = true, rises: Bool = false) -> String {
        #"{"id":"\#(id)","name":"\#(name)","url":"https://m.example/tags/\#(name)","requires_review":\#(waiting),"trendable":\#(rises),"history":[{"day":"1792627200","accounts":"12","uses":"12"},{"day":"1792540800","accounts":"3","uses":"3"}]}"#
    }

    private static let figures = #"""
    [{"key":"new_users","unit":null,"total":"51","previous_total":"4","data":[]},{"key":"active_users","unit":null,"total":"49","previous_total":"0","data":[]},{"key":"opened_reports","unit":null,"total":"2","data":[]}]
    """#

    private static func seeded(_ more: [String: PageServer.Answer] = [:]) -> [String: PageServer.Answer] {
        [
            measures: PageServer.Answer(body: figures),
            tags: PageServer.Answer(body: "[" + tag("23", "FediqoWaiting") + "," + tag("1", "FediqoRising", waiting: false, rises: true) + "]"),
            links: PageServer.Answer(body: #"[{"id":2,"url":"https://waiting.example/stories/waiting","title":"A story waiting","requires_review":true,"history":[]}]"#),
            posts: PageServer.Answer(body: "[]"),
            rules: PageServer.Answer(body: #"[{"id":"1","text":"Be kind","hint":""},{"id":"2","text":"No spam","hint":"None at all"}]"#),
        ].merging(more) { $1 }
    }

    private func session(
        _ routes: [String: PageServer.Answer], permissions: String? = admin, holding scopes: String = tending
    ) async throws -> (ShellSession, PageServer, ShellTendingServer, ShellPersonPages) {
        let server = PageServer(routes.merging([Self.who: Self.check(permissions: permissions)]) { mine, _ in mine })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        let pages = ShellPersonPages()
        session.personPages = pages
        pages.tending.server.now = { Self.now }
        return (session, server, pages.tending.server, pages)
    }

    // MARK: - The tab

    @Test("Each part is a tab of its own and its flag's: Dashboard the figures, Trends what rises, Rules the rules; each tab asks only its own part, so a role holding one flag never asks another's; a role with none has no trace of them, and asks nothing")
    func eachTabIsItsFlags() async throws {
        let (session, everything, server, _) = try await session(Self.seeded())
        #expect(ShellTendingServer.parts(at: Self.host, in: session) == [.measures, .rising, .rules])
        await server.opened(Self.dashboard, in: session)
        let tagsAsked = await everything.arrivals(of: Self.tags)
        let rulesAsked = await everything.arrivals(of: Self.rules)
        #expect(tagsAsked == 0 && rulesAsked == 0, "Dashboard asks nothing of the other tabs' parts")
        let figures = server.said(of: Self.dashboard, in: session)
        #expect(figures.measures != nil && figures.rising == nil && figures.rules == nil)

        let (moderated, modServer, mod, _) = try await self.session(Self.seeded(), permissions: Self.moderator)
        #expect(ShellTendingServer.parts(at: Self.host, in: moderated) == [.measures, .rising])
        for page in Self.pages { await mod.opened(page, in: moderated) }
        #expect(mod.said(of: Self.dashboard, in: moderated).measures != nil && mod.said(of: Self.risingPage, in: moderated).rising != nil)
        #expect(mod.said(of: Self.rulesPage, in: moderated).rules == nil)
        #expect(await modServer.arrivals(of: Self.rules) == 0, "nothing asked of a tab the role does not answer for")

        let (ruled, ruledServer, rul, _) = try await self.session(Self.seeded(), permissions: Self.rulesOnly)
        #expect(ShellTending.tabs(at: Self.host, in: ruled) == [.rules])
        for page in Self.pages { await rul.opened(page, in: ruled) }
        let rulSaid = rul.said(of: Self.rulesPage, in: ruled)
        #expect(rulSaid.measures == nil && rulSaid.rising == nil && rulSaid.rules?.rules.count == 2)
        let askedMeasures = await ruledServer.arrivals(of: Self.measures)
        let askedTags = await ruledServer.arrivals(of: Self.tags)
        #expect(askedMeasures == 0 && askedTags == 0, "nothing asked of a part the role does not answer for")

        let (reported, reportedServer, rep, _) = try await self.session(Self.seeded(), permissions: Self.reportsOnly)
        let repTabs = ShellTending.tabs(at: Self.host, in: reported)
        #expect(repTabs == [.reports] && !ShellTending.drawn(Self.rulesPage, in: reported))
        for page in Self.pages { await rep.opened(page, in: reported) }
        #expect(rep.said(of: Self.rulesPage, in: reported).rules == nil && rep.said(of: Self.dashboard, in: reported).measures == nil)
        #expect(await reportedServer.arrivals(of: Self.rules) == 0)
    }

    // MARK: - Reading

    @Test("Opening asks each part at once: the figures of the last seven days, said as the server's as of when they were read; what rises, each saying whether it waits; the rules in order, with the way to the server's page")
    func whatIsRead() async throws {
        let (session, server, tab, _) = try await session(Self.seeded())
        for page in Self.pages { await tab.opened(page, in: session) }
        let said = tab.said(of: Self.dashboard, in: session, language: .english)
        let figures = try #require(said.measures?.said)
        #expect(said.measures?.days == 7 && figures.asOf == Self.now)
        #expect(figures.measures.map { TendingServerSaid.figure($0, language: .english) } == [
            "Joined: 51 (4 the span before)", "Active: 49 (0 the span before)", "Reported: 2",
        ])
        #expect(TendingServerSaid.asOf(figures, host: Self.host, language: .english).hasPrefix("As m.example counted them at "))
        let body = try #require(await server.sent.first { $0.ask == Self.measures }?.body)
        #expect(body.contains("start_at=2026-10-") && body.contains("end_at=2026-10-"))

        let rising = try #require(tab.said(of: Self.risingPage, in: session, language: .english).rising)
        #expect(rising.map(\.kind) == [.tags, .links, .posts])
        let waiting = try #require(rising[0].items.first)
        #expect(TendingServerSaid.lines(waiting, language: .english) == ["#FediqoWaiting", "Waiting for review · 15 people over two days"])
        #expect(TendingServerSaid.lines(rising[0].items[1], language: .english).last?.hasPrefix("Let rise") == true)
        #expect(TendingServerSaid.lines(try #require(rising[1].items.first), language: .english).prefix(2) == ["A story waiting", "waiting.example"])
        #expect(rising[2].quiet == "No post is rising.")

        let rules = try #require(tab.said(of: Self.rulesPage, in: session, language: .english).rules)
        #expect(rules.rules.enumerated().map { TendingServerSaid.rule($1, at: $0, language: .english) } == ["1. Be kind", "2. No spam — None at all"])
        #expect(rules.page?.absoluteString == "https://m.example/admin/rules")
        #expect(tab.walked(Self.risingPage, in: session) == [
            TendingServerSaid.rowID(.tags, "23"), TendingServerSaid.rowID(.tags, "1"), TendingServerSaid.rowID(.links, "2"),
        ])
        #expect(tab.walked(Self.rulesPage, in: session) == [TendingServerSaid.ruleID("1"), TendingServerSaid.ruleID("2")])
        #expect(tab.walked(Self.dashboard, in: session).isEmpty)
    }

    @Test("Another span asks its figures; one chosen before it, answering after, is not drawn over it")
    func spans() async throws {
        let (session, server, tab, _) = try await session(Self.seeded())
        await tab.opened(Self.dashboard, in: session)
        await server.hold(Self.measures)
        defer { Task { await server.release(Self.measures) } }
        let held = watching("two spans' figures, held at their server") { await server.release(Self.measures) }
        defer { held.cancel() }
        let thirty = Task { await tab.choose(days: 30, on: Self.dashboard, in: session) }
        await server.arrival(of: Self.measures, times: 2, by: thirty)
        let ninety = Task { await tab.choose(days: 90, on: Self.dashboard, in: session) }
        await server.arrival(of: Self.measures, times: 3, by: ninety)
        await server.release(Self.measures)
        await thirty.value
        await ninety.value
        let said = try #require(tab.said(of: Self.dashboard, in: session).measures)
        #expect(said.days == 90 && said.said?.days == 90)
        await tab.choose(days: 5, on: Self.dashboard, in: session)
        #expect(await server.arrivals(of: Self.measures) == 3, "a span not offered is not asked")
    }

    @Test("Another span's figures are said as asked, and may be stopped; stopped, what answers after is not drawn")
    func aSpanAskedIsStoppable() async throws {
        let (session, server, tab, _) = try await session(Self.seeded())
        await tab.opened(Self.dashboard, in: session)
        await server.hold(Self.measures)
        defer { Task { await server.release(Self.measures) } }
        let held = watching("a span's figures, held at their server") { await server.release(Self.measures) }
        defer { held.cancel() }
        let thirty = Task { await tab.choose(days: 30, on: Self.dashboard, in: session) }
        await server.arrival(of: Self.measures, times: 2, by: thirty)
        let asking = tab.ask(of: Self.dashboard, language: .english)
        #expect(asking.asking != nil && asking.stoppable)
        #expect(tab.stop(Self.dashboard))
        await server.release(Self.measures)
        await thirty.value
        #expect(tab.ask(of: Self.dashboard).stopped && tab.ask(of: Self.dashboard).asking == nil)
        #expect(tab.said(of: Self.dashboard, in: session).measures?.said == nil, "stopped: what answered after is not drawn")
    }

    // MARK: - Reviews

    @Test("A hashtag kept back is the server's answer; its `…` offers what it is not; a refusal says so and changes nothing; without the word that changes, tending's lock stands in the acts' place")
    func reviewed() async throws {
        let reject = "/api/v1/admin/trends/tags/23/reject"
        let (session, server, tab, _) = try await session(Self.seeded([
            reject: PageServer.Answer(body: Self.tag("23", "FediqoWaiting", waiting: false, rises: false)),
            "/api/v1/admin/trends/links/2/approve": PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
        ]))
        await tab.opened(Self.risingPage, in: session)
        var said = tab.said(of: Self.risingPage, in: session, language: .english)
        let waiting = try #require(said.rising?[0].items.first)
        let more = TendingServerSaid.more(waiting, said: said, actions: TendingServerActs(), language: .english)
        #expect(more.items.map(\.name) == ["Let it rise", "Keep it back"])
        await tab.review(waiting, rise: false, on: Self.risingPage, in: session)
        said = tab.said(of: Self.risingPage, in: session, language: .english)
        let kept = try #require(said.rising?[0].items.first)
        #expect(!kept.waiting && kept.rises == false)
        #expect(TendingServerSaid.more(kept, said: said, actions: TendingServerActs(), language: .english).items.map(\.name) == ["Let it rise"])
        #expect(await server.arrivals(of: reject) == 1)

        let link = try #require(said.rising?[1].items.first)
        await tab.review(link, rise: true, on: Self.risingPage, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.act.notAllowed"), Self.host))
        #expect(tab.said(of: Self.risingPage, in: session).rising?[1].items.first?.waiting == true, "nothing changed here")

        let (locked, lockedServer, lockedTab, _) = try await self.session(Self.seeded(), holding: "\(Self.reads) admin:read")
        await lockedTab.opened(Self.risingPage, in: locked)
        let lockedSaid = lockedTab.said(of: Self.risingPage, in: locked, language: .english)
        #expect(!lockedSaid.acts && lockedSaid.rising?[0].items.count == 2)
        let item = try #require(lockedSaid.rising?[0].items.first)
        await lockedTab.review(item, rise: true, on: Self.risingPage, in: locked)
        #expect(await lockedServer.arrivals(of: "/api/v1/admin/trends/tags/23/approve") == 0)
        #expect(locked.toast?.text == String(format: L10n.t("tend.act.notAllowed"), Self.host))
    }

    @Test("A read sent while a review is on the wire lands after it without undoing it")
    func reviewsKeepTheirRows() async throws {
        let reject = "/api/v1/admin/trends/tags/23/reject"
        let (session, server, tab, _) = try await session(Self.seeded([
            reject: PageServer.Answer(body: Self.tag("23", "FediqoWaiting", waiting: false, rises: false)),
        ]))
        await tab.opened(Self.risingPage, in: session)
        let waiting = try #require(tab.said(of: Self.risingPage, in: session).rising?[0].items.first)
        await server.hold(reject)
        await server.hold(Self.tags)
        defer {
            Task {
                await server.release(reject)
                await server.release(Self.tags)
            }
        }
        let held = watching("the review and the read, held at their server") {
            await server.release(reject)
            await server.release(Self.tags)
        }
        defer { held.cancel() }
        let reviewing = Task { await tab.review(waiting, rise: false, on: Self.risingPage, in: session) }
        await server.arrival(of: reject, by: reviewing)
        let reading = Task { await tab.again(Self.risingPage, in: session) }
        await server.arrival(of: Self.tags, times: 2, by: reading)
        await server.release(reject)
        await reviewing.value
        await server.release(Self.tags)
        await reading.value
        #expect(tab.said(of: Self.risingPage, in: session).rising?[0].items.first?.waiting == false, "the read sent before the review answered did not undo it")
    }

    // MARK: - Let go

    @Test("What each tab said is let go when the page leaves; what rises is let go on its own when the role no longer answers for it, while the rules it still answers for are kept")
    func letGo() async throws {
        let (session, server, tab, pages) = try await session(Self.seeded())
        for page in Self.pages { await tab.opened(page, in: session) }
        pages.tending.letGo(at: Self.host)
        #expect(tab.said(of: Self.risingPage, in: session).rising?.allSatisfy(\.items.isEmpty) == true)
        #expect(tab.said(of: Self.dashboard, in: session).measures?.said == nil && tab.said(of: Self.rulesPage, in: session).rules?.rules.isEmpty == true)

        for page in Self.pages { await tab.opened(page, in: session) }
        await server.answer(Self.who, Self.check(permissions: Self.rulesOnly))
        await session.mastodon.learnWho(host: Self.host)
        await tab.opened(Self.rulesPage, in: session)
        await server.answer(Self.who, Self.check(permissions: Self.admin))
        await session.mastodon.learnWho(host: Self.host)
        #expect(tab.said(of: Self.risingPage, in: session).rising?.allSatisfy(\.items.isEmpty) == true, "let go with its flag")
        #expect(tab.said(of: Self.dashboard, in: session).measures?.said == nil, "let go with its flag")
        #expect(tab.said(of: Self.rulesPage, in: session).rules?.rules.count == 2, "kept with theirs")
    }

    @Test("Every word of the three tabs is in each language the app speaks")
    func wordsInEveryLanguage() {
        var keys = [
            "tend.tab.dashboard", "tend.tab.rising", "tend.tab.rules", "tend.server.asking", "tend.server.measures.title", "tend.server.measures.span",
            "tend.server.measures.days", "tend.server.measures.asOf", "tend.server.measure.line", "tend.server.measure.before",
            "tend.server.rising.waiting", "tend.server.rising.rises", "tend.server.rising.kept", "tend.server.rising.reviewed",
            "tend.server.rising.post", "tend.server.rising.people", "tend.server.rising.gone", "tend.server.rise", "tend.server.keep",
            "tend.server.rules.title", "tend.server.rules.change", "tend.server.rules.none",
        ]
        keys += ServerMeasure.Key.allCases.map { "tend.server.measure.\($0)" }
        for kind in RisingKind.allCases { keys += ["tend.server.rising.\(kind.rawValue)", "tend.server.rising.none.\(kind.rawValue)"] }
        for language in DummyLanguage.allCases {
            for key in keys { #expect(L10n.t(key, language: language) != key, "\(key) in \(language)") }
        }
    }
}
