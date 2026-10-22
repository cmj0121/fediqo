import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #380 and #381, the page: who is offered tending a server and how — by the role its own check
/// says, never by the words a sign-in holds; the Reports tab asked, read on to every report the
/// server keeps, open ones first, and acted on, each act's answer the row; a read that left
/// before an act never undoing it; what is refused said and nothing changed; and a notice of a
/// new report opening the report.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`); every deadline is on a
/// clock nobody turns.
@MainActor
@Suite("Tending a server: its reports", .serialized, .watched)
struct TendingTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let tending = "\(reads) admin:read admin:write"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let open = "/api/v1/admin/reports?resolved=false"
    private static let closed = "/api/v1/admin/reports?resolved=true"
    /// The role flags of a Moderator, and of everybody.
    private static let moderator = "1115420"
    private static let everybody = "65536"

    private static func check(permissions: String?) -> PageServer.Answer {
        let role = permissions.map { #","role":{"id":"1","name":"Moderator","permissions":"\#($0)"}"# } ?? ""
        return PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"\#(role)}"#)
    }

    private static func account(_ id: String, _ acct: String) -> String {
        #"{"id":"\#(id)","username":"\#(acct)","account":{"id":"\#(id)","acct":"\#(acct)","username":"\#(acct)","display_name":"\#(acct)"}}"#
    }

    private static func report(_ id: String, closed: Bool = false, takenBy: String? = nil, words: String = "bad") -> String {
        let taken = takenBy.map { account("7", $0) } ?? "null"
        return #"""
        {"id":"\#(id)","action_taken":\#(closed),"category":"violation","comment":"\#(words)","forwarded":false,"created_at":"2026-10-22T02:00:00.000Z",
         "account":\#(account("5", "other")),"target_account":\#(account("42", "ada")),"assigned_account":\#(taken),
         "statuses":[{"id":"1\#(id)","uri":"https://m.example/1\#(id)","created_at":"2026-10-22T01:00:00.000Z","content":"<p>spam \#(id)</p>",
           "visibility":"public","account":{"id":"42","acct":"ada","username":"ada","display_name":"Ada"}}],
         "rules":[{"id":"1","text":"Be kind"}]}
        """#
    }

    private static func list(_ reports: [String], next: String? = nil) -> PageServer.Answer {
        PageServer.Answer(
            body: "[" + reports.joined(separator: ",") + "]",
            link: next.map { #"<https://m.example/api/v1/admin/reports?max_id=\#($0)>; rel="next""# }
        )
    }

    private func session(
        _ routes: [String: PageServer.Answer], permissions: String? = moderator, holding scopes: String = tending
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
        await session.mastodon.learnWho(host: Self.host)
        let pages = ShellPersonPages()
        session.personPages = pages
        return (session, server, pages)
    }

    private static let page = Tending(host: host, tab: .reports)

    // MARK: - Who is offered it

    @Test("Tending is offered by the role the server's own check names, and by nothing else: a Moderator holding its words is offered the page on Reports; holding none of them, the part's lock, whose press asks for them alone; everybody's role, or no role, is offered nothing — whatever the sign-in holds — and no trace is drawn")
    func offeredByTheRole() async throws {
        let (session, _, _) = try await session([:])
        #expect(ShellTending.tabs(at: Self.host, in: session) == [.reports, .people, .server], "a Moderator manages reports and users, and sees the figures and what rises")
        #expect(ShellTending.entry(at: Self.host, in: session) == .open(Self.page))
        #expect(ShellTending.acts(at: Self.host, in: session) && ShellTending.drawn(Self.page, in: session))
        let item = try #require(SourceRow.tendItem(.open(Self.page), host: Self.host, actsLive: true, press: {}, language: .english))
        #expect(item.name == "Tend m.example" && item.look == .live)

        let (unasked, _, _) = try await self.session([:], holding: Self.reads)
        guard case .lock(let place) = ShellTending.entry(at: Self.host, in: unasked) else {
            Issue.record("no lock")
            return
        }
        #expect(place.kind == .unasked && place.key == "part.tending.unasked")
        #expect(!ShellTending.drawn(Self.page, in: unasked))
        let lock = try #require(SourceRow.tendItem(.lock(place), host: Self.host, actsLive: true, press: {}, language: .english))
        #expect(lock.name == "This sign-in was not asked to tend the server. Update permission")

        for permissions in [Self.everybody, nil] {
            let (plain, _, _) = try await self.session([:], permissions: permissions)
            #expect(ShellTending.tabs(at: Self.host, in: plain).isEmpty && ShellTending.entry(at: Self.host, in: plain) == nil, "\(permissions ?? "no role")")
            #expect(!ShellTending.drawn(Self.page, in: plain))
            #expect(SourceRow.tendItem(nil, host: Self.host, actsLive: true, press: {}) == nil)
        }
        #expect(TendingTab.allowed(by: MastodonStaff(rawValue: 1)) == [.reports, .people, .servers, .server], "the administrator is allowed every tab")
    }

    @Test("Holding only tending's word that reads, the page lists and offers no act: every act is dim, and pressed sends nothing")
    func readOnlyListsAndDoesNotAct() async throws {
        let (session, server, pages) = try await session([Self.open: Self.list([Self.report("1")])], holding: "\(Self.reads) admin:read")
        #expect(ShellTending.drawn(Self.page, in: session) && !ShellTending.acts(at: Self.host, in: session))
        await pages.tending.opened(Self.page, in: session)
        let said = pages.tending.said(of: Self.page, in: session)
        #expect(said.reports.map(\.id) == ["1"] && !said.acts)
        // Its acts give way to tending's lock, which asks for the words that act, alone.
        let lock = try #require(said.lock)
        #expect(lock.kind == .partly && lock.key == "part.tending.partly.changing")
        let more = ReportRowView.more(
            said.reports[0], host: Self.host, acts: said.acts, acting: false, lock: lock, onAct: { _, _ in },
            onOpenPage: { _ in }, language: .english
        )
        #expect(more.items.map(\.name) == ["This sign-in was not asked to act for the server. Update permission", "Write a note on m.example's page"])
        #expect(more.items.allSatisfy { $0.look == .live })
        // Where the words may not be asked for, the acts are dim for good.
        let never = ReportRowView.more(said.reports[0], host: Self.host, acts: false, acting: false, onAct: { _, _ in }, onOpenPage: { _ in })
        #expect(never.items.prefix(2).allSatisfy { $0.look == .dim(.never) })
        await pages.tending.act(.close, on: "1", of: Self.page, in: session)
        #expect(await server.asked.filter { $0.contains("/resolve") }.isEmpty)
        #expect(TendingHead.spoken(Self.host, acts: false, language: .english).contains("may read these and not act on them"))
    }

    // MARK: - Read, and read on

    @Test("Opening asks for the open reports, newest first; reading on goes on to the closed ones and to the end, so every report the server keeps is reached — open ones first — and reached at the foot only after a stretch that came")
    func readOnToEveryReport() async throws {
        let (session, server, pages) = try await session([
            Self.open: Self.list([Self.report("3")], next: "3"),
            "\(Self.open)&max_id=3": Self.list([Self.report("2")]),
            Self.closed: Self.list([Self.report("1", closed: true)]),
        ])
        await pages.tending.opened(Self.page, in: session)
        #expect(pages.tending.said(of: Self.page, in: session).foot == .more)
        await pages.tending.readOn(Self.page, pressed: false, in: session)
        await pages.tending.readOn(Self.page, pressed: false, in: session)
        let said = pages.tending.said(of: Self.page, in: session, language: .english)
        #expect(said.reports.map(\.id) == ["3", "2", "1"] && said.reports.map(\.closed) == [false, false, true])
        #expect(said.foot == .end && said.quiet == nil)
        #expect(await server.asked.filter { $0.hasPrefix("/api/v1/admin") } == [Self.open, "\(Self.open)&max_id=3", Self.closed])
        #expect(pages.tending.walked(Self.page, in: session) == said.reports.map { TendingReportsSaid.rowID($0.id) })
        let row = try #require(said.reports.first)
        let between = L10n.t("people.row.between", language: .english)
        #expect(ReportRowView.spoken(row, language: .english).hasPrefix(
            "Open · Against the rules\(between)About @ada@m.example — Reported by @other@m.example\(between)bad"
        ))
        #expect(ReportRowView.spoken(row, language: .english).contains("Rules: Be kind"))
        #expect(pages.tending.ask(of: Self.page) == PageAsking())
    }

    @Test("A stretch that did not come is the toast's, and the foot waits for a press; a server that keeps none says so; one that refuses this account's standing says that, and lists nothing")
    func whatIsNotAnswered() async throws {
        let (session, server, pages) = try await session([
            Self.open: Self.list([Self.report("3")], next: "3"),
            "\(Self.open)&max_id=3": PageServer.Answer(body: "", status: 503),
        ])
        await pages.tending.opened(Self.page, in: session)
        await pages.tending.readOn(Self.page, pressed: false, in: session)
        #expect(pages.tending.ask(of: Self.page) == PageAsking(failed: [Self.host]))
        #expect(pages.tending.said(of: Self.page, in: session).foot == .more)
        for _ in 0..<3 { await pages.tending.readOn(Self.page, pressed: false, in: session) }
        #expect(await server.arrivals(of: "\(Self.open)&max_id=3") == 1, "reached after a failure, nothing is asked")

        let (none, _, empty) = try await self.session([Self.open: Self.list([]), Self.closed: Self.list([])])
        await empty.tending.opened(Self.page, in: none)
        await empty.tending.readOn(Self.page, pressed: false, in: none)
        #expect(empty.tending.said(of: Self.page, in: none, language: .english).quiet == "m.example keeps no reports.")

        let refused = PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403)
        let (gone, _, noRole) = try await self.session([Self.open: refused])
        await noRole.tending.opened(Self.page, in: gone)
        let said = noRole.tending.said(of: Self.page, in: gone, language: .english)
        #expect(said.reports.isEmpty && said.quiet == "m.example did not allow this for your standing there." && said.foot == nil)
    }

    // MARK: - Acts

    @Test("Each act is sent once and its row is the report as the server answers: taken on, handed back, closed, opened again; the row's menu offers the act that fits its state, and the report's own page on the server for a note or an act on the account")
    func actsReplaceTheRow() async throws {
        let base = "/api/v1/admin/reports/1/"
        let (session, server, pages) = try await session([
            Self.open: Self.list([Self.report("1")]),
            base + "assign_to_self": PageServer.Answer(body: Self.report("1", takenBy: "me")),
            base + "unassign": PageServer.Answer(body: Self.report("1")),
            base + "resolve": PageServer.Answer(body: Self.report("1", closed: true)),
            base + "reopen": PageServer.Answer(body: Self.report("1")),
        ])
        await pages.tending.opened(Self.page, in: session)
        func row() -> AdminReport? { pages.tending.said(of: Self.page, in: session).reports.first }
        func names() -> [String] {
            ReportRowView.more(try! #require(row()), host: Self.host, acts: true, acting: false, onAct: { _, _ in }, onOpenPage: { _ in }, language: .english)
                .items.map(\.name)
        }
        #expect(names() == ["Take it on", "Close", "Write a note on m.example's page"])
        await pages.tending.act(.take, on: "1", of: Self.page, in: session)
        #expect(row()?.takenBy == "@me@m.example" && names().first == "Hand it back")
        await pages.tending.act(.handBack, on: "1", of: Self.page, in: session)
        #expect(row()?.takenBy == nil)
        await pages.tending.act(.close, on: "1", of: Self.page, in: session)
        #expect(row()?.closed == true && names()[1] == "Open again")
        await pages.tending.act(.reopen, on: "1", of: Self.page, in: session)
        #expect(row()?.closed == false)
        #expect(await server.asked.filter { $0.hasPrefix(base) } == ["assign_to_self", "unassign", "resolve", "reopen"].map { base + $0 })
        #expect(await server.sent.filter { $0.ask.hasPrefix(base) }.allSatisfy { $0.method == "POST" })
        #expect(MastodonAdminReports.page(of: "1", host: Self.host)?.absoluteString == "https://m.example/admin/reports/1")
    }

    @Test("A read that left before an act lands after it without undoing it: the act's row stands")
    func aReadBeforeAnActDoesNotUndoIt() async throws {
        let (session, server, pages) = try await session([
            Self.open: Self.list([Self.report("1")]),
            "/api/v1/admin/reports/1/resolve": PageServer.Answer(body: Self.report("1", closed: true)),
        ])
        await pages.tending.opened(Self.page, in: session)
        await server.hold(Self.open)
        defer { Task { await server.release(Self.open) } }
        let held = watching("the read of the reports, held at its server") { await server.release(Self.open) }
        defer { held.cancel() }
        let again = Task { await pages.tending.again(Self.page, in: session) }
        await server.arrival(of: Self.open, times: 2, by: again)
        await pages.tending.act(.close, on: "1", of: Self.page, in: session)
        #expect(pages.tending.said(of: Self.page, in: session).reports.first?.closed == true)
        await server.release(Self.open)
        await again.value
        #expect(pages.tending.said(of: Self.page, in: session).reports.first?.closed == true, "the open copy the read brought did not undo the close")
    }

    @Test("An act the server refuses says the server's words, or that the standing does not allow it, and the row stays as it was")
    func refusedActsChangeNothing() async throws {
        let (session, _, pages) = try await session([
            Self.open: Self.list([Self.report("1")]),
            "/api/v1/admin/reports/1/resolve": PageServer.Answer(body: #"{"error":"Validation failed: no"}"#, status: 422),
            "/api/v1/admin/reports/1/assign_to_self": PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
        ])
        await pages.tending.opened(Self.page, in: session)
        await pages.tending.act(.close, on: "1", of: Self.page, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.act.refused"), Self.host, "Validation failed: no"))
        await pages.tending.act(.take, on: "1", of: Self.page, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.act.notAllowed"), Self.host))
        let row = try #require(pages.tending.said(of: Self.page, in: session).reports.first)
        #expect(!row.closed && row.takenBy == nil)
    }

    @Test("Pressing tending's lock asks for its words alone; the sign-in the page gives keeps the standing its own check said, so Tend opens the page at once — no other check asked for")
    func theLockGivesThePageAtOnce() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: Self.host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.reads, asked: Self.reads
        ))
        let server = PartServer(tokens: tokens)
        await server.answer(PartServer.check, .body(#"{"id":"7","acct":"me","role":{"permissions":"1115420"}}"#))
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server))
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        session.mastodon.deadlineSleep = TurnedClock().sleep
        session.mastodon.refresh()
        // What the app does as it starts: the check of who the sign-in held is.
        await session.mastodon.learnWho(host: Self.host)
        guard case .lock(let place) = ShellTending.entry(at: Self.host, in: session) else {
            Issue.record("no lock")
            return
        }
        #expect(place.asks)
        #expect(session.askFor([.tending], host: Self.host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.ticked == [.tending])
        let page = PartPage()
        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: Self.host)
        #expect(page.scopes.count == 1 && page.scopes.first?.hasSuffix("admin:read admin:write") == true)
        let checks = await server.paths.filter { $0 == PartServer.check }.count
        #expect(ShellTending.entry(at: Self.host, in: session) == .open(Self.page), "the new sign-in carries its own check's standing")
        let after = await server.paths.filter { $0 == PartServer.check }.count
        #expect(after == checks, "nothing more was asked to know it")
    }

    @Test("An act on the wire while a read is sent: the read lands after the act and does not undo it")
    func aReadSentDuringAnActDoesNotUndoIt() async throws {
        let resolve = "/api/v1/admin/reports/1/resolve"
        let (session, server, pages) = try await session([
            Self.open: Self.list([Self.report("1")]),
            resolve: PageServer.Answer(body: Self.report("1", closed: true)),
        ])
        await pages.tending.opened(Self.page, in: session)
        await server.hold(resolve)
        await server.hold(Self.open)
        defer {
            Task {
                await server.release(resolve)
                await server.release(Self.open)
            }
        }
        let held = watching("the act and the read, held at their server") {
            await server.release(resolve)
            await server.release(Self.open)
        }
        defer { held.cancel() }
        let acting = Task { await pages.tending.act(.close, on: "1", of: Self.page, in: session) }
        await server.arrival(of: resolve, by: acting)
        let reading = Task { await pages.tending.again(Self.page, in: session) }
        await server.arrival(of: Self.open, times: 2, by: reading)
        await server.release(resolve)
        await acting.value
        #expect(pages.tending.said(of: Self.page, in: session).reports.first?.closed == true)
        await server.release(Self.open)
        await reading.value
        #expect(pages.tending.said(of: Self.page, in: session).reports.first?.closed == true, "the read sent before the act answered did not undo it")
    }

    @Test("An act whose page was asked afresh as another reader while it was on the wire writes nothing into that page")
    func anActLandsOnlyOnItsOwnPage() async throws {
        let resolve = "/api/v1/admin/reports/1/resolve"
        let (session, server, pages) = try await session([
            Self.open: Self.list([Self.report("1")]),
            resolve: PageServer.Answer(body: Self.report("1", closed: true)),
        ])
        await pages.tending.opened(Self.page, in: session)
        await server.hold(resolve)
        defer { Task { await server.release(resolve) } }
        let held = watching("the act, held at its server") { await server.release(resolve) }
        defer { held.cancel() }
        let acting = Task { await pages.tending.act(.close, on: "1", of: Self.page, in: session) }
        await server.arrival(of: resolve, by: acting)
        // Another sign-in filed at the host: the page is asked afresh as them.
        _ = try session.mastodon.tokens.forget(try #require(try session.mastodon.tokens.token(host: Self.host)))
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "other", clientID: "c", clientSecret: "s", scopes: Self.tending, asked: Self.tending
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        await pages.tending.opened(Self.page, in: session)
        await server.release(resolve)
        await acting.value
        let said = pages.tending.said(of: Self.page, in: session)
        #expect(said.reports.first?.closed == false && said.acting.isEmpty, "the act wrote into a page it was not pressed on")
    }

    @Test("A notice lights a report the page has not read: it is asked for, and stands at the top; one the server does not give is said")
    func aLitReportIsBroughtIn() async throws {
        let (session, server, pages) = try await session([
            Self.open: Self.list([Self.report("3")]),
            "/api/v1/admin/reports/1": PageServer.Answer(body: Self.report("1", closed: true)),
            "/api/v1/admin/reports/2": PageServer.Answer(body: #"{"error":"Record not found"}"#, status: 404),
        ])
        await pages.tending.bringIn("1", of: Self.page, in: session)
        #expect(pages.tending.said(of: Self.page, in: session).reports.map(\.id) == ["1", "3"])
        await pages.tending.bringIn("3", of: Self.page, in: session)
        #expect(await server.asked.filter { $0.hasPrefix("/api/v1/admin/reports/3") }.isEmpty, "one already read is not asked for")
        await pages.tending.bringIn("2", of: Self.page, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.reports.unlisted"), Self.host))
    }

    @Test("A report fetched in that the server fails to give for another reason than not having it says the failure, or that the standing does not allow it — never that the server did not give it")
    func aFailedBringInSaysTheFailure() async throws {
        let (session, _, pages) = try await session([
            Self.open: Self.list([Self.report("3")]),
            "/api/v1/admin/reports/4": PageServer.Answer(body: "", status: 503),
            "/api/v1/admin/reports/5": PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
        ])
        await pages.tending.bringIn("4", of: Self.page, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.act.failed"), Self.host))
        await pages.tending.bringIn("5", of: Self.page, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.act.notAllowed"), Self.host))
        #expect(pages.tending.said(of: Self.page, in: session).reports.map(\.id) == ["3"])
    }

    @Test("Closed where who is filed could not be looked at: a look that fails leaves no standing believed — none of tending is offered — until a look is had again")
    func aFailedLookBelievesNoStanding() async throws {
        let (session, _, _) = try await session([:])
        #expect(ShellTending.entry(at: Self.host, in: session) == .open(Self.page))
        let tokens = try #require(session.mastodon.tokens as? MemoryMastodonTokens)
        tokens.refuse(.looking, times: 100)
        session.mastodon.refresh()
        #expect(session.mastodon.staff(host: Self.host) == nil && ShellTending.entry(at: Self.host, in: session) == nil)
        tokens.refuse(.looking, times: 0)
        session.mastodon.refresh()
        #expect(session.mastodon.staff(host: Self.host) != nil, "the same sign-in, looked at again, keeps what its check said")
    }

    // MARK: - A notice of a new report

    @Test("A notice of a new report opens the server's reports where the reader may tend them, on the report it names; without the standing it opens what it always did")
    func aNoticeOpensTheReport() async throws {
        let (session, _, _) = try await session([:])
        let notice = Notice(
            source: Self.source, handle: .one(id: "9"), kind: .server("admin.report"), people: [], at: Date(timeIntervalSince1970: 1),
            newestID: "9", oldestID: "9", report: "1"
        )
        #expect(FediqoRootView.tendingOpened(by: notice, in: session) == Self.page)
        #expect(notice.report.map(TendingReportsSaid.rowID) == TendingReportsSaid.rowID("1"))
        let other = Notice(source: Self.source, handle: .one(id: "8"), kind: .follow, people: [], at: Date(timeIntervalSince1970: 1), newestID: "8", oldestID: "8")
        #expect(FediqoRootView.tendingOpened(by: other, in: session) == nil)
        let (plain, _, _) = try await self.session([:], permissions: Self.everybody)
        #expect(FediqoRootView.tendingOpened(by: notice, in: plain) == nil)
    }

    // MARK: - The page

    @Test("The page is one of its own: a page of rows on the people's layer, its own toast and Stop, no timelines' head over it, the stream in its stead once the standing is gone")
    func thePage() async throws {
        let (session, _, pages) = try await session([:])
        let step = ShellStep.server(Self.page)
        #expect(step.layer == .people && step.tabKey == .tending(Self.page) && step.isKind(of: .server(Tending(host: "x", tab: .reports))))
        var walk = ShellWalk()
        _ = walk.walk(to: step, from: nil)
        #expect(walk.openedTending == Self.page && walk.openedPeople == nil)
        #expect(TimelinePane.askInFront(step, rising: nil, of: pages, in: session) == .tending(Self.page))
        #expect(TimelinePane.drawn(step, of: pages, in: session).drawn && !TimelinePane.headDrawn(over: step))
        #expect(TimelinePane.openedID(step) == "server:m.example\u{1e}reports")
        // Tab turns round the tabs the standing allows, in place; covered, it is not the page's.
        var lamp: String? = "x"
        #expect(!pages.tending.rotate(&walk, by: 1, covered: true, lamp: &lamp, in: session))
        #expect(pages.tending.rotate(&walk, by: 1, covered: false, lamp: &lamp, in: session) && walk.openedTending?.tab == .people && lamp == nil)
        #expect(walk.depth == 1, "a tab is no step")
        #expect(pages.tending.rotate(&walk, by: 1, covered: false, lamp: &lamp, in: session) && walk.openedTending?.tab == .server)
        #expect(pages.tending.rotate(&walk, by: 1, covered: false, lamp: &lamp, in: session) && walk.openedTending == Self.page)
        #expect(!pages.tending.turn(&walk, to: .reports, lamp: &lamp, in: session), "already on it")
        session.sources = []
        #expect(!TimelinePane.drawn(step, of: pages, in: session).drawn)
    }

    @Test("Every word of the page, the item and the part is in each language the app speaks")
    func wordsInEveryLanguage() {
        let keys = [
            "tend.item", "tend.title", "tend.line", "tend.readOnly", "tend.tab.reports", "tend.asking", "tend.reports.none",
            "tend.reports.open", "tend.reports.closed", "tend.reports.by", "tend.reports.byServer", "tend.reports.about",
            "tend.reports.takenBy", "tend.reports.rules", "tend.reports.forwarded", "tend.reports.posts",
            "tend.reports.category.spam", "tend.reports.category.legal", "tend.reports.category.violation",
            "tend.reports.category.other", "tend.act.take", "tend.act.handBack", "tend.act.close", "tend.act.reopen",
            "tend.act.page", "tend.act.notAllowed", "tend.act.refused", "tend.act.failed", "tend.more.label",
            "tend.foot.more", "tend.foot.end", "tend.reports.unlisted", "work.purpose.tending",
        ]
        for language in DummyLanguage.allCases {
            for key in keys { #expect(L10n.t(key, language: language) != key, "\(key) in \(language)") }
        }
    }
}
