import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #416, the place: Admin is a place of its own, kept by the standing each sign-in was last told
/// — through a check that fails, not past a sign-out or another account; it opens on the list of
/// hosts, a host opens its page with its tabs, and every way in that the walk's step had — the
/// Account `…`, a notice, the keys — lands there.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`); every deadline is on a
/// clock nobody turns.
@MainActor
@Suite("The Admin place", .serialized, .watched)
struct AdminPlaceTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let tending = "\(reads) admin:read admin:write"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let open = "/api/v1/admin/reports?resolved=false"
    private static let closed = "/api/v1/admin/reports?resolved=true"
    private static let pending = "/api/v2/admin/accounts?status=pending"
    /// A Moderator: reports, people, the dashboard and what rises.
    private static let moderator = "1115420"
    private static let row = AdminFront.hostRow(host)

    private static func check(permissions: String?) -> PageServer.Answer {
        let role = permissions.map { #","role":{"id":"1","name":"Moderator","permissions":"\#($0)"}"# } ?? ""
        return PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"\#(role)}"#)
    }

    private static func report(_ id: String) -> String {
        #"""
        {"id":"\#(id)","action_taken":false,"category":"spam","comment":"","forwarded":false,"created_at":"2026-10-22T02:00:00.000Z",
         "account":{"id":"5","username":"other","account":{"id":"5","acct":"other","username":"other"}},
         "target_account":{"id":"42","username":"ada","account":{"id":"42","acct":"ada","username":"ada"}},
         "assigned_account":null,"statuses":[],"rules":[]}
        """#
    }

    private static let reports: [String: PageServer.Answer] = [
        open: PageServer.Answer(body: "[" + report("2") + "," + report("1") + "]"),
        closed: PageServer.Answer(body: "[]"),
        pending: PageServer.Answer(body: "[]"),
    ]

    private func session(
        _ routes: [String: PageServer.Answer] = reports, permissions: String? = moderator, holding scopes: String = tending,
        checked: Bool = true
    ) async throws -> (ShellSession, PageServer, ShellPersonPages) {
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
        if checked { await session.mastodon.learnWho(host: Self.host) }
        let pages = ShellPersonPages()
        session.personPages = pages
        return (session, server, pages)
    }

    private func signIn(_ session: ShellSession, as token: String) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: token, clientID: "c", clientSecret: "s", scopes: Self.tending, asked: Self.tending
        ))
        session.mastodon.refresh()
    }

    // MARK: - The standing, per sign-in (D1)

    @Test("The place is there while the sign-in's last known standing is: kept through a check that fails and a look that could not be had — the place never left — and let go at once by a check naming none, a sign-out, or another account, also while the check cannot be had")
    func theStandingIsKeptPerSignIn() async throws {
        let (session, server, pages) = try await session()
        #expect(session.availability.adminHosts == [Self.host] && session.mastodon.standingKnown(host: Self.host))

        // A check that fails under the same sign-in keeps it.
        await server.answer(Self.who, PageServer.Answer(body: "", status: 503))
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.availability.adminHosts == [Self.host], "a failed check keeps the place")
        #expect(session.availability.placing(.admin, as: .admin) == .admin)

        // A look that could not be had keeps it too: the host listed, its page not drawn meanwhile.
        let tokens = try #require(session.mastodon.tokens as? MemoryMastodonTokens)
        tokens.refuse(.looking, times: 100)
        session.mastodon.refresh()
        #expect(ShellTending.entry(at: Self.host, in: session) == nil, "nothing of tending believed of whatever is filed now")
        #expect(session.availability.allows(.admin), "the place is not taken from under the person")
        var front = AdminFront(page: Tending(host: Self.host, tab: .reports))
        let did1 = front.settle(in: session)
        #expect(front.shown(in: session) == nil && did1 == nil, "the page waits, under the list")
        #expect(AdminHostsList.said(in: session, tending: pages.tending).map(\.standing) == [.unknown])
        tokens.refuse(.looking, times: 0)
        session.mastodon.refresh()
        #expect(front.shown(in: session) == front.page)

        // A check that names no standing takes it up.
        await server.answer(Self.who, Self.check(permissions: nil))
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.availability.adminHosts.isEmpty && !session.availability.allows(.admin))
        let did2 = front.settle(in: session)
        #expect(did2 == Tending(host: Self.host, tab: .reports) && front.page == nil)
    }

    @Test("A sign-out, or another account at the host, lets the standing go at once — while the check cannot be had as much as when it can — and the next account's own check lays down its own")
    func aSignOutOrSwitchLetsItGo() async throws {
        let (session, server, _) = try await session()
        await server.answer(Self.who, PageServer.Answer(body: "", status: 503))
        // Another account: nothing of the one before is believed of it, and its check is offline.
        try signIn(session, as: "other")
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.mastodon.lastStanding(host: Self.host) == nil && session.availability.adminHosts.isEmpty)
        #expect(!session.mastodon.standingKnown(host: Self.host))
        await server.answer(Self.who, Self.check(permissions: Self.moderator))
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.availability.adminHosts == [Self.host], "its own check lays down its own")

        // Signed out, with the check offline: gone at once.
        await server.answer(Self.who, PageServer.Answer(body: "", status: 503))
        _ = try session.mastodon.tokens.forget(try #require(try session.mastodon.tokens.token(host: Self.host)))
        session.mastodon.refresh()
        #expect(session.mastodon.lastStanding(host: Self.host) == nil && !session.availability.allows(.admin))
        #expect(session.availability.placing(.admin, as: .admin) != .admin, "the person is moved out of the place")
    }

    @Test("Signed out is known by the look at the sign-ins alone: where the filings beside them cannot be read, the standing still goes with the sign-in")
    func aSignOutIsKnownWithoutTheFilings() async throws {
        let (session, _, _) = try await session()
        _ = try session.mastodon.tokens.forget(try #require(try session.mastodon.tokens.token(host: Self.host)))
        let tokens = try #require(session.mastodon.tokens as? MemoryMastodonTokens)
        // The look at the sign-ins is had, and the one at their filings refused.
        tokens.refuse(.looking, times: 1, after: 1)
        session.mastodon.refresh()
        #expect(session.mastodon.grantsKnown && !session.mastodon.partsKnown)
        #expect(session.mastodon.lastStanding(host: Self.host) == nil && !session.availability.allows(.admin))
    }

    // MARK: - The list, and a host's page (D2, D3)

    @Test("The place opens on the list of hosts, even of one: each row its host, the tabs its standing allows and its figures, each a press that opens its tab; a sign-in without the word that reads is the lock's row, whose press asks for it alone")
    func theListOfHosts() async throws {
        let (session, _, pages) = try await session()
        let tending = pages.tending
        await tending.headOpened(Tending(host: Self.host, tab: .reports), in: session)
        let rows = AdminHostsList.said(in: session, tending: tending)
        let open = AdminHostsList.Row.Standing.open(
            tabs: [.reports, .people, .dashboard, .rising],
            counts: [TendingCount(tab: .reports, count: 2, more: false), TendingCount(tab: .people, count: 0, more: false)],
            acts: true
        )
        #expect(rows == [AdminHostsList.Row(host: Self.host, standing: open)])
        let spoken = AdminHostsList.spoken(rows[0], language: .english)
        #expect(spoken.hasPrefix("m.example") && spoken.contains("Reports, People, Dashboard, Trends") && spoken.contains("2 open reports"))
        var front = AdminFront()
        #expect(front.page == nil && front.rows(in: session, tending: tending) == [Self.row], "one host still shows its list")
        // A figure pressed opens its tab.
        let did3 = front.open(Self.host, on: .people, in: session)
        #expect(did3 && front.page == Tending(host: Self.host, tab: .people))

        let (locked, _, lockedPages) = try await self.session(holding: Self.reads)
        guard case .lock(let place) = AdminHostsList.said(in: locked, tending: lockedPages.tending).first?.standing else {
            Issue.record("no lock row")
            return
        }
        #expect(place.asks)
        var lockedFront = AdminFront()
        let did4 = lockedFront.open(Self.host, in: locked)
        #expect(did4 && lockedFront.page == nil, "the words asked, nothing opened")
        #expect(locked.partAsks.open?.ticked == [.tending])
    }

    @Test("A host opens its page on its first tab; j and k walk the tab's rows and g goes to the top; Tab turns round the tabs the standing allows, in place, and a tab it lacks is refused; Back gives the list again, lit on the host left; `r` asks the tab in front again")
    func aHostsPageAndItsKeys() async throws {
        let (session, server, pages) = try await session()
        let tending = pages.tending
        var front = AdminFront()
        let did5 = front.move(by: 1, among: front.rows(in: session, tending: tending))
        #expect(did5 && front.lamp == Self.row)
        let host = try #require(AdminFront.host(ofRow: Self.row))
        let did6 = front.open(host, in: session)
        #expect(did6)
        let page = try #require(front.shown(in: session))
        #expect(page == Tending(host: Self.host, tab: .reports) && front.lamp == nil)
        await tending.opened(page, in: session)
        let rows = front.rows(in: session, tending: tending)
        #expect(rows == ["2", "1"].map(TendingReportsSaid.rowID))
        let did7 = front.move(by: 1, among: rows)
        let did8 = front.move(by: 1, among: rows)
        #expect(did7 && did8 && front.lamp == rows[1])
        let did9 = front.move(by: -1, among: rows)
        #expect(did9 && front.lamp == rows[0])
        let did10 = front.top(among: rows)
        #expect(did10 && front.lamp == rows[0] && front.jump == 1)

        // ⌘R: the tab in front asked again, from the top.
        #expect(tending.canAskAgain(page, in: session))
        await tending.again(page, in: session)
        #expect(await server.arrivals(of: Self.open) == 2)

        // Tab, and a tab pressed.
        let did11 = front.rotate(by: 1, covered: true, tending: tending, in: session)
        #expect(!did11, "under the viewer the key is not the page's")
        let did12 = front.rotate(by: 1, covered: false, tending: tending, in: session)
        #expect(did12 && front.page?.tab == .people && front.lamp == nil)
        let did13 = front.rotate(by: -2, covered: false, tending: tending, in: session)
        #expect(did13 && front.page?.tab == .rising)
        let did14 = front.turn(to: .federation, tending: tending, in: session)
        #expect(!did14, "a tab the standing lacks is no tab")
        let did15 = front.turn(to: .dashboard, tending: tending, in: session)
        #expect(did15 && front.page?.tab == .dashboard)
        let did16 = front.turn(to: .dashboard, tending: tending, in: session)
        #expect(!did16, "already on it")

        // Back: the list, lit on the host.
        let did17 = front.back()
        #expect(did17 == Tending(host: Self.host, tab: .dashboard))
        let did18 = front.back()
        #expect(front.page == nil && front.lamp == Self.row && did18 == nil)
    }

    @Test("On the People tab the lamp walks the accounts, and the one it is on names a person, as any person's row opens them")
    func peopleRowsOpenThePerson() async throws {
        let account = #"""
        {"id":"3","username":"ann","domain":null,"created_at":"2026-10-22T02:00:00.000Z","email":"ann@example.com",
         "ip":null,"confirmed":true,"approved":false,"disabled":false,"silenced":false,"suspended":false,
         "sensitized":false,"invite_request":null,
         "account":{"id":"3","acct":"ann","username":"ann","display_name":"ann"}}
        """#
        let (session, _, pages) = try await session(Self.reports.merging([Self.pending: PageServer.Answer(body: "[" + account + "]")]) { $1 })
        var front = AdminFront()
        _ = front.open(Self.host, on: .people, in: session)
        let page = try #require(front.shown(in: session))
        await pages.tending.opened(page, in: session)
        let rows = front.rows(in: session, tending: pages.tending)
        #expect(rows == [TendingPeopleSaid.rowID("3")])
        let did19 = front.move(by: 1, among: rows)
        #expect(did19)
        let lamp = try #require(front.lamp)
        let person = try #require(pages.tending.people.account(lamp, of: page, in: session)?.person)
        #expect(person.handle == "@ann@m.example")
        // Return: that person, for their page.
        let entered = front.enter(in: session, tending: pages.tending)
        #expect(entered == .person(DummyPerson(person)))
        // On Reports a row opens nothing: its acts are its `…`.
        let turned = front.turn(to: .reports, tending: pages.tending, in: session)
        await pages.tending.opened(try #require(front.shown(in: session)), in: session)
        let reportRows = front.rows(in: session, tending: pages.tending)
        let lit = front.move(by: 1, among: reportRows)
        let onReport = front.enter(in: session, tending: pages.tending)
        #expect(turned && lit && onReport == nil)
    }

    @Test("Return on the list opens the host the lamp is on, and with no lamp does nothing; Escape stops the tab's ask, then puts the lamp out, then goes back to the list, then is not Admin's")
    func returnAndEscape() async throws {
        let (session, server, pages) = try await session()
        let tending = pages.tending
        var front = AdminFront()
        let none = front.enter(in: session, tending: tending)
        #expect(none == nil)
        front.lamp = Self.row
        let opened = front.enter(in: session, tending: tending)
        #expect(opened == .host && front.page == Tending(host: Self.host, tab: .reports))
        let page = try #require(front.shown(in: session))
        await tending.opened(page, in: session)

        // An ask on the wire: Escape stops it first.
        await server.hold(Self.open)
        defer { Task { await server.release(Self.open) } }
        let held = watching("the reports, held at their server") { await server.release(Self.open) }
        defer { held.cancel() }
        let again = Task { await tending.again(page, in: session) }
        await server.arrival(of: Self.open, times: 2, by: again)
        let stopped = front.dismiss(in: session, tending: tending)
        #expect(stopped == .stopped && tending.ask(of: page).stopped)
        await server.release(Self.open)
        await again.value
        front.lamp = TendingReportsSaid.rowID("2")
        let lampOut = front.dismiss(in: session, tending: tending)
        #expect(lampOut == .lampOut && front.lamp == nil)
        let left = front.dismiss(in: session, tending: tending)
        #expect(left == .left(page) && front.page == nil && front.lamp == Self.row)
        front.lamp = nil
        let nothing = front.dismiss(in: session, tending: tending)
        #expect(nothing == nil)
    }

    @Test("⌘R asks again the tab in front where it may be asked; on the list, each host's reports, whose figure it draws; with nothing to ask, nothing — and `r` is not taken")
    func reloadAsksWhatIsInFront() async throws {
        let (session, _, pages) = try await session()
        var front = AdminFront()
        #expect(front.reloads(in: session, tending: pages.tending) == [Tending(host: Self.host, tab: .reports)])
        _ = front.open(Self.host, on: .people, in: session)
        #expect(front.reloads(in: session, tending: pages.tending) == [Tending(host: Self.host, tab: .people)])

        let (locked, _, lockedPages) = try await self.session(holding: Self.reads)
        #expect(AdminFront().reloads(in: locked, tending: lockedPages.tending).isEmpty, "a lock's row has nothing to read")
    }

    // MARK: - The ways in (D4)

    @Test("Account's `…` offers Tend where the standing allows it, under the Admin place's own glyph, and lands on that host's page; without the standing nothing is offered")
    func theAccountItemLandsInThePlace() async throws {
        let (session, _, _) = try await session()
        let entry = try #require(ShellTending.entry(at: Self.host, in: session))
        guard case .open(let page) = entry else {
            Issue.record("no page")
            return
        }
        let item = try #require(SourceRow.tendItem(entry, host: Self.host, actsLive: true, press: {}, language: .english))
        #expect(item.name == "Tend m.example" && item.symbol == ShellPlace.admin.symbolName)
        var front = AdminFront()
        let did20 = front.open(page.host, on: page.tab, in: session)
        #expect(did20 && front.page == page)

        let (plain, _, _) = try await self.session(permissions: "65536")
        #expect(ShellTending.entry(at: Self.host, in: plain) == nil && !plain.availability.allows(.admin))
    }

    @Test("A notice of a new report lands on the host's Reports lit on that report, which is brought in at the top; one of a sign-up on People, lit on who signed up once found — and only while that page is still in front")
    func aNoticeLandsInThePlace() async throws {
        let (session, _, pages) = try await session(Self.reports.merging([
            "/api/v1/admin/reports/9": PageServer.Answer(body: Self.report("9")),
        ]) { $1 })
        var front = AdminFront()
        let landing = front.noticePressed(Self.notice(report: "9"), in: session)
        let page = Tending(host: Self.host, tab: .reports)
        #expect(landing == .page(page) && front.awaited == nil)
        let left = front.land(.page(page), from: Self.notice(report: "9"), in: session)
        #expect(left == nil && front.page == page && front.lamp == TendingReportsSaid.rowID("9"))
        await pages.tending.bringIn("9", of: page, in: session)
        #expect(pages.tending.walked(page, in: session).first == front.lamp, "brought in, at the top, where the lamp is")

        let signUp = Self.signUp()
        let people = Tending(host: Self.host, tab: .people)
        let signedUp = front.noticePressed(signUp, in: session)
        #expect(signedUp == .page(people))
        _ = front.land(.page(people), from: signUp, in: session)
        #expect(front.page == people && front.lamp == nil, "no report to light: found among those waiting first")
        front.lit(TendingPeopleSaid.rowID("3"), on: people)
        #expect(front.lamp == TendingPeopleSaid.rowID("3"))
        front.lit(TendingPeopleSaid.rowID("4"), on: page)
        #expect(front.lamp == TendingPeopleSaid.rowID("3"), "a page no longer in front is lit no more")
        front.lit(nil, on: people)
        #expect(front.lamp == TendingPeopleSaid.rowID("3"))

        // A notice that is no Admin's lands nowhere and waits for nothing.
        let follow = Notice(source: Self.source, handle: .one(id: "7"), kind: .follow, people: [], at: Date(timeIntervalSince1970: 1), newestID: "7", oldestID: "7")
        var other = AdminFront()
        let nowhere = other.noticePressed(follow, in: session)
        #expect(nowhere == nil && other.awaited == nil)
    }

    @Test("A notice pressed before its host's standing is known waits, and lands once it is known; known to give none, it waits no more and the line opens what it always did")
    func aNoticeWaitsForTheStanding() async throws {
        let notice = Self.notice(report: "9")
        let (early, server, _) = try await session(checked: false)
        var waiting = AdminFront()
        let kept = waiting.noticePressed(notice, in: early)
        #expect(kept == .waiting && waiting.awaited == notice)
        let unknown = waiting.settled(in: early)
        #expect(unknown.left == nil && unknown.opens == nil && waiting.awaited == notice, "not known yet: still waiting")
        await early.mastodon.learnWho(host: Self.host)
        let known = waiting.settled(in: early)
        let opens = try #require(known.opens)
        #expect(opens.0 == .page(Tending(host: Self.host, tab: .reports)) && opens.1 == notice)
        _ = waiting.land(opens.0, from: opens.1, in: early)
        #expect(waiting.awaited == nil && waiting.lamp == TendingReportsSaid.rowID("9"))

        let (none, noneServer, _) = try await self.session(checked: false)
        var lost = AdminFront()
        _ = lost.noticePressed(notice, in: none)
        await noneServer.answer(Self.who, Self.check(permissions: nil))
        await none.mastodon.learnWho(host: Self.host)
        let gone = lost.settled(in: none)
        #expect(gone.opens == nil && lost.awaited == nil, "known to give none: waits no more")
        let again = lost.noticePressed(notice, in: none)
        #expect(again == nil && lost.awaited == nil, "and pressed again it is the line's own")
        _ = server
    }

    @Test("A notice whose host is listed and whose page cannot open — the sign-in lacking the word that reads — lands on the list, that host lit, and its lock asks for the word: never a dead press")
    func aNoticeFallsBackToTheList() async throws {
        let (locked, _, _) = try await session(holding: Self.reads)
        var front = AdminFront(page: Tending(host: "n.example", tab: .reports))
        let landing = front.noticePressed(Self.notice(report: "9"), in: locked)
        #expect(landing == .list(Self.host) && front.awaited == nil)
        let left = front.land(.list(Self.host), from: Self.notice(report: "9"), in: locked)
        #expect(left == Tending(host: "n.example", tab: .reports), "the page left is let go")
        #expect(front.page == nil && front.lamp == Self.row)
        #expect(locked.partAsks.open?.ticked == [.tending], "the lock asks for its word")
    }

    private static func notice(report: String) -> Notice {
        Notice(
            source: source, handle: .one(id: report), kind: .server("admin.report"), people: [], at: Date(timeIntervalSince1970: 1),
            newestID: report, oldestID: report, report: report
        )
    }

    private static func signUp() -> Notice {
        Notice(
            source: source, handle: .one(id: "8"), kind: .server("admin.sign_up"),
            people: [NoticePerson(handle: "@ann@m.example", name: "ann")], at: Date(timeIntervalSince1970: 1), newestID: "8", oldestID: "8"
        )
    }

    @Test("A change's sheet sends on the page of the tab its list stands on: servers on Federation, mail domains and ranges on Blocks")
    func sheetsSendOnTheirTab() {
        #expect(FederationAsk(host: Self.host, kind: .block(nil)).list.tab == .federation)
        #expect(FederationAsk(host: Self.host, kind: .allow).list.tab == .federation)
        #expect(FederationAsk(host: Self.host, kind: .mail).list.tab == .blocks)
        #expect(FederationAsk(host: Self.host, kind: .address).list.tab == .blocks)
        #expect(ServerPart.measures.tab == .dashboard && ServerPart.rising.tab == .rising && ServerPart.rules.tab == .rules)
    }

    @Test("Every tab is its own flag's, in the order the page draws them, and its words are in each language the app speaks — Trends among them, named apart from the Trends place")
    func theTabs() {
        #expect(AdminTab.allCases == [.reports, .people, .federation, .blocks, .dashboard, .rising, .rules])
        #expect(AdminTab.allowed(by: .manageBlocks) == [.blocks] && AdminTab.allowed(by: .manageRules) == [.rules])
        #expect(AdminTab.allowed(by: MastodonStaff(rawValue: 65536)).isEmpty && AdminTab.allowed(by: nil).isEmpty)
        #expect(AdminTab.rising.titleKey != "shell.trends.title")
        for language in DummyLanguage.allCases {
            for tab in AdminTab.allCases { #expect(L10n.t(tab.titleKey, language: language) != tab.titleKey, "\(tab) in \(language)") }
        }
        #expect(L10n.t(AdminTab.rising.titleKey, language: .english) == "Trends")
    }
}
