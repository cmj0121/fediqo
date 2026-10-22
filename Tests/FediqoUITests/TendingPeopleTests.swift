import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #382, the page: the People tab of tending a server — those waiting asked first, let in or
/// turned away; accounts found by state and name; each acted on, on a sheet, with the words the
/// server sends, and each act taken back; what only staff see of somebody on their About; the
/// head's figures; a notice of a sign-up opening it — each write by the rules #381's acts keep.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`); every deadline is on a
/// clock nobody turns.
@MainActor
@Suite("Tending a server: its people", .serialized, .watched)
struct TendingPeopleTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let tending = "\(reads) admin:read admin:write"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let list = "/api/v2/admin/accounts"
    private static let one = "/api/v1/admin/accounts"
    private static let pending = "\(list)?status=pending"
    private static let moderator = "1115420"
    /// A role that answers for reports and not for users.
    private static let reportsOnly = "16"
    private static let page = Tending(host: host, tab: .people)

    private static func check(permissions: String?) -> PageServer.Answer {
        let role = permissions.map { #","role":{"id":"1","name":"Moderator","permissions":"\#($0)"}"# } ?? ""
        return PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"\#(role)}"#)
    }

    private static func account(
        _ id: String, _ name: String, approved: Bool = true, silenced: Bool = false, suspended: Bool = false, wrote: String? = nil
    ) -> String {
        let request = wrote.map { "\"\($0)\"" } ?? "null"
        return #"""
        {"id":"\#(id)","username":"\#(name)","domain":null,"created_at":"2026-10-22T02:00:00.000Z","email":"\#(name)@example.com",
         "ip":null,"confirmed":true,"approved":\#(approved),"disabled":false,"silenced":\#(silenced),"suspended":\#(suspended),
         "sensitized":false,"invite_request":\#(request),
         "account":{"id":"\#(id)","acct":"\#(name)","username":"\#(name)","display_name":"\#(name)"}}
        """#
    }

    private static func accounts(_ accounts: [String], next: String? = nil) -> PageServer.Answer {
        PageServer.Answer(
            body: "[" + accounts.joined(separator: ",") + "]",
            link: next.map { #"<https://m.example/api/v2/admin/accounts?max_id=\#($0)>; rel="next""# }
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

    // MARK: - The tab

    @Test("The People tab is the role's: a Moderator has it, a role that answers only for reports does not — and has no trace of it — while an act on an account stays open to both from a report")
    func theTabIsTheRoles() async throws {
        let (session, _, _) = try await session([:])
        #expect(ShellTending.tabs(at: Self.host, in: session).contains(.people))
        #expect(ShellTendingPeople.manages(at: Self.host, in: session) && ShellTendingPeople.actsOn(at: Self.host, in: session))
        let (reports, _, _) = try await self.session([:], permissions: Self.reportsOnly)
        #expect(ShellTending.tabs(at: Self.host, in: reports) == [.reports])
        #expect(!ShellTendingPeople.manages(at: Self.host, in: reports) && ShellTendingPeople.actsOn(at: Self.host, in: reports))
        #expect(!ShellTending.drawn(Self.page, in: reports))
    }

    @Test("Opening asks for those waiting, newest first, each with what they wrote; reading on goes by the server's next; another state or a name asks again from the top")
    func waitingFirstThenFound() async throws {
        let (session, server, pages) = try await session([
            Self.pending: Self.accounts([Self.account("3", "ann", approved: false, wrote: "Let me in")], next: "3"),
            "\(Self.pending)&max_id=3": Self.accounts([Self.account("2", "bo", approved: false)]),
            "\(Self.list)?status=silenced&username=cy": Self.accounts([Self.account("1", "cy", silenced: true)]),
        ])
        let people = pages.tending.people
        await pages.tending.opened(Self.page, in: session)
        await pages.tending.readOn(Self.page, pressed: false, in: session)
        let said = people.said(of: Self.page, in: session, language: .english)
        #expect(said.accounts.map(\.id) == ["3", "2"] && said.filter.state == .pending && said.foot == .end)
        #expect(AccountRowView.lines(said.accounts[0], language: .english) == ["Waiting to join", "ann@example.com", "Wrote: Let me in"])
        #expect(people.walked(Self.page, in: session) == ["3", "2"].map(TendingPeopleSaid.rowID))

        await people.find(AdminAccountFilter(state: .silenced, words: "cy"), on: Self.page, in: session)
        let found = people.said(of: Self.page, in: session)
        #expect(found.accounts.map(\.id) == ["1"] && found.filter.state == .silenced)
        #expect(await server.asked.filter { $0.hasPrefix(Self.list) } == [Self.pending, "\(Self.pending)&max_id=3", "\(Self.list)?status=silenced&username=cy"])
        #expect(pages.tending.ask(of: Self.page) == PageAsking())
    }

    @Test("None of a state says so; a role the server refuses says that and lists nothing; a stretch that did not come is the toast's, and the foot waits for a press")
    func whatIsNotAnswered() async throws {
        let (session, _, pages) = try await session([Self.pending: Self.accounts([])])
        await pages.tending.opened(Self.page, in: session)
        #expect(pages.tending.people.said(of: Self.page, in: session, language: .english).quiet == "m.example has no accounts like these.")

        let (refused, _, others) = try await self.session([Self.pending: PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403)])
        await others.tending.opened(Self.page, in: refused)
        #expect(others.tending.people.said(of: Self.page, in: refused, language: .english).quiet == "m.example did not allow this for your standing there.")

        let (failing, server, third) = try await self.session([
            Self.pending: Self.accounts([Self.account("3", "ann", approved: false)], next: "3"),
            "\(Self.pending)&max_id=3": PageServer.Answer(body: "", status: 503),
        ])
        await third.tending.opened(Self.page, in: failing)
        await third.tending.readOn(Self.page, pressed: false, in: failing)
        #expect(third.tending.ask(of: Self.page) == PageAsking(failed: [Self.host]))
        for _ in 0..<3 { await third.tending.readOn(Self.page, pressed: false, in: failing) }
        #expect(await server.arrivals(of: "\(Self.pending)&max_id=3") == 1)
    }

    // MARK: - Letting in, turning away, taking back

    @Test("Somebody waiting is let in — their row the account the server answers — or turned away, which asks first in one line that it cannot be undone, and their row goes")
    func letInOrTurnAway() async throws {
        let (session, server, pages) = try await session([
            Self.pending: Self.accounts([Self.account("3", "ann", approved: false), Self.account("2", "bo", approved: false)]),
            "\(Self.one)/3/approve": PageServer.Answer(body: Self.account("3", "ann")),
            "\(Self.one)/2/reject": PageServer.Answer(body: "{}"),
        ])
        let people = pages.tending.people
        await pages.tending.opened(Self.page, in: session)
        let said = people.said(of: Self.page, in: session)
        let more = AccountRowView.more(
            said.accounts[1], host: Self.host, acts: said.acts, manages: said.manages, acting: false, lock: nil,
            actions: TendingPeopleActs(), language: .english
        )
        #expect(more.items.map(\.name) == ["Let in", "Turn away"])
        let question = AccountRowView.turnAwayQuestion("@bo@m.example", host: Self.host, language: .english)
        #expect(question.line == "m.example deletes their sign-up. This cannot be undone." && question.warns)

        await people.letIn("3", of: Self.page, in: session)
        #expect(people.said(of: Self.page, in: session).accounts.first?.waiting == false)
        await people.turnAway("2", of: Self.page, in: session)
        #expect(people.said(of: Self.page, in: session).accounts.map(\.id) == ["3"])
        #expect(await server.asked.filter { $0.hasPrefix(Self.one) } == ["\(Self.one)/3/approve", "\(Self.one)/2/reject"])
    }

    @Test("An account held in a state offers its act and taking each state back; taken back, its row is the account as the server answers; a refusal says the server's words and changes nothing")
    func takenBack() async throws {
        let (session, _, pages) = try await session([
            "\(Self.list)?status=silenced": Self.accounts([Self.account("1", "cy", silenced: true)]),
            "\(Self.one)/1/unsilence": PageServer.Answer(body: Self.account("1", "cy")),
            "\(Self.one)/1/unsuspend": PageServer.Answer(body: #"{"error":"Validation failed: no"}"#, status: 422),
        ])
        let people = pages.tending.people
        await people.find(AdminAccountFilter(state: .silenced), on: Self.page, in: session)
        let said = people.said(of: Self.page, in: session)
        let more = AccountRowView.more(
            said.accounts[0], host: Self.host, acts: said.acts, manages: said.manages, acting: false, lock: nil,
            actions: TendingPeopleActs(), language: .english
        )
        #expect(more.items.map(\.name) == ["Act on @cy@m.example…", "Lift the limit"])
        await people.undo(.limit, on: "1", of: Self.page, in: session)
        #expect(people.said(of: Self.page, in: session).accounts.first?.silenced == false)
        await people.undo(.suspend, on: "1", of: Self.page, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.act.refused"), Self.host, "Validation failed: no"))
    }

    @Test("A read sent while a write is on the wire lands after it without undoing it; a write whose page was asked afresh as another reader writes nothing there")
    func writesKeepTheirRows() async throws {
        let unsilence = "\(Self.one)/1/unsilence"
        let silenced = "\(Self.list)?status=silenced"
        let (session, server, pages) = try await session([
            silenced: Self.accounts([Self.account("1", "cy", silenced: true)]),
            unsilence: PageServer.Answer(body: Self.account("1", "cy")),
        ])
        let people = pages.tending.people
        await people.find(AdminAccountFilter(state: .silenced), on: Self.page, in: session)
        await server.hold(unsilence)
        await server.hold(silenced)
        defer {
            Task {
                await server.release(unsilence)
                await server.release(silenced)
            }
        }
        let held = watching("the write and the read, held at their server") {
            await server.release(unsilence)
            await server.release(silenced)
        }
        defer { held.cancel() }
        let writing = Task { await people.undo(.limit, on: "1", of: Self.page, in: session) }
        await server.arrival(of: unsilence, by: writing)
        let reading = Task { await people.again(Self.page, in: session) }
        await server.arrival(of: silenced, times: 2, by: reading)
        await server.release(unsilence)
        await writing.value
        await server.release(silenced)
        await reading.value
        #expect(people.said(of: Self.page, in: session).accounts.first?.silenced == false, "the read sent before the write answered did not undo it")
    }

    // MARK: - The sheet

    @Test("The sheet: opened only where the reader may act; a warning says in one line that it cannot be taken back; suspending asks once more and sends nothing until its yes; sent, the act carries its type, words, mail and report, closes, and the row and the staff block are the account read again")
    func theSheet() async throws {
        let (session, server, pages) = try await session([
            "\(Self.list)?status=active": Self.accounts([Self.account("1", "cy")]),
            "\(Self.one)/1/action": PageServer.Answer(body: "{}"),
            "\(Self.one)/1": PageServer.Answer(body: Self.account("1", "cy", suspended: true)),
        ])
        let people = pages.tending.people
        await people.find(AdminAccountFilter(state: .active), on: Self.page, in: session)
        #expect(AccountActSheet.line(.warn, language: .english).hasSuffix("A warning cannot be taken back."))
        #expect(AccountAct.allCases.filter { !$0.undoes } == [.warn])

        people.openAct(on: "1", handle: "@cy@m.example", local: true, at: Self.host, report: "9", in: session)
        people.asking?.act = .suspend
        people.asking?.words = "Spam."
        await people.sendAct(in: session, confirmed: true)
        #expect(people.asking?.stage == .asking, "a yes not from the question puts the question")
        #expect(await server.sent.isEmpty)
        people.asking?.stage = .writing
        await people.sendAct(in: session)
        #expect(people.asking?.stage == .asking)
        #expect(await server.sent.isEmpty, "suspending asks before anything is sent")
        await people.sendAct(in: session, confirmed: true)
        #expect(people.asking == nil && session.toast?.text == String(format: L10n.t("tend.act.done.suspend"), "@cy@m.example"))
        let body = try #require(await server.sent.first { $0.ask == "\(Self.one)/1/action" }?.body)
        #expect(body.contains("type=suspend") && body.contains("text=Spam.") && body.contains("send_email_notification=true") && body.contains("report_id=9"))
        #expect(people.said(of: Self.page, in: session).accounts.first?.suspended == true)

        let (plain, _, others) = try await self.session([:], permissions: "65536")
        others.tending.people.openAct(on: "1", handle: "@cy", local: true, at: Self.host, in: plain)
        #expect(others.tending.people.asking == nil, "no standing, no sheet")
    }

    @Test("A refused act stays on the sheet in the server's words, and nothing else changes")
    func aRefusedActStays() async throws {
        let (session, _, pages) = try await session([
            "\(Self.one)/1/action": PageServer.Answer(body: #"{"error":"Validation failed: Type is not included in the list"}"#, status: 422),
        ])
        let people = pages.tending.people
        people.openAct(on: "1", handle: "@cy@m.example", local: true, at: Self.host, in: session)
        await people.sendAct(in: session)
        #expect(people.asking?.stage == .failed(String(format: L10n.t("tend.act.refused"), Self.host, "Validation failed: Type is not included in the list")))
        people.closeAct()
        #expect(people.asking == nil)
    }

    // MARK: - On their page, the head, a notice

    @Test("What only staff see of somebody is asked as their page's About comes up and drawn there — mail, states, what they wrote — and nothing of it without the standing")
    func theStaffBlock() async throws {
        let (session, server, pages) = try await session([
            "\(Self.one)/3": PageServer.Answer(body: Self.account("3", "ann", approved: false, wrote: "Let me in")),
        ])
        let ann = Person(source: Self.source, accountID: "3", handle: "@ann@m.example", name: "ann")
        let people = pages.tending.people
        #expect(people.staffOpening(of: ann, in: session) != nil)
        await people.staffOpened(of: ann, in: session)
        let staff = try #require(people.staffSaid(of: ann, in: session))
        #expect(staff.acts)
        let lines = TendingStaffSaid.lines(staff, language: .english)
        #expect(lines.first == "What only those who answer for m.example see" && lines.contains("Mail: ann@example.com"))
        #expect(lines.contains("Waiting to join") && lines.contains("Wrote: Let me in"))
        await people.staffOpened(of: ann, in: session)
        #expect(await server.arrivals(of: "\(Self.one)/3") == 1, "asked once")

        let (plain, _, others) = try await self.session([:], permissions: "65536")
        #expect(others.tending.people.staffOpening(of: ann, in: plain) == nil && others.tending.people.staffSaid(of: ann, in: plain) == nil)
    }

    @Test("The head's figures are the open reports and those waiting, each opening its tab; a notice of a new sign-up opens the People tab and lights the one who signed up")
    func headAndNotice() async throws {
        let (session, _, pages) = try await session([
            "/api/v1/admin/reports?resolved=false": PageServer.Answer(body: "[]"),
            Self.pending: Self.accounts([Self.account("3", "ann", approved: false)], next: "3"),
            "\(Self.pending)&username=ann": Self.accounts([Self.account("3", "ann", approved: false)]),
        ])
        await pages.tending.headOpened(Self.page, in: session)
        let counts = pages.tending.counts(of: Self.page, in: session)
        #expect(counts.map(\.tab) == [.reports, .people])
        #expect(counts.map { $0.figure(language: .english) } == ["0", "1+"])
        #expect(counts[1].spoken(language: .english) == "1+ waiting to join")

        let notice = Notice(
            source: Self.source, handle: .one(id: "9"), kind: .server("admin.sign_up"),
            people: [NoticePerson(handle: "@ann@m.example", name: "ann")], at: Date(timeIntervalSince1970: 1), newestID: "9", oldestID: "9"
        )
        #expect(FediqoRootView.tendingOpened(by: notice, in: session) == Self.page)
        // A notice that gives no id: found among those waiting by name.
        #expect(await pages.tending.people.lightSignUp(notice.people[0], on: Self.page, in: session) == TendingPeopleSaid.rowID("3"))
    }

    @Test("Somebody turned away while a read of those waiting is on its way stays gone when the read lands")
    func turnedAwayStaysGone() async throws {
        let reject = "\(Self.one)/2/reject"
        let (session, server, pages) = try await session([
            Self.pending: Self.accounts([Self.account("3", "ann", approved: false), Self.account("2", "bo", approved: false)]),
            reject: PageServer.Answer(body: "{}"),
        ])
        let people = pages.tending.people
        await pages.tending.opened(Self.page, in: session)
        await server.hold(reject)
        await server.hold(Self.pending)
        defer {
            Task {
                await server.release(reject)
                await server.release(Self.pending)
            }
        }
        let held = watching("the turning away and the read, held at their server") {
            await server.release(reject)
            await server.release(Self.pending)
        }
        defer { held.cancel() }
        let turning = Task { await people.turnAway("2", of: Self.page, in: session) }
        await server.arrival(of: reject, by: turning)
        let reading = Task { await people.again(Self.page, in: session) }
        await server.arrival(of: Self.pending, times: 2, by: reading)
        await server.release(reject)
        await turning.value
        await server.release(Self.pending)
        await reading.value
        #expect(people.said(of: Self.page, in: session).accounts.map(\.id) == ["3"], "the one turned away came back")
    }

    @Test("Freezing is offered only of somebody of this server, and only to a role that manages accounts")
    func freezeOnlyWhereItCan() async throws {
        let (session, _, pages) = try await session([:])
        let people = pages.tending.people
        people.openAct(on: "1", handle: "@far@elsewhere.example", local: false, at: Self.host, in: session)
        #expect(people.asking?.offered.contains(.freeze) == false)
        people.closeAct()
        people.openAct(on: "1", handle: "@cy@m.example", local: true, at: Self.host, in: session)
        #expect(people.asking?.offered == AccountAct.allCases)
        people.asking?.act = .freeze
        let (reports, _, others) = try await self.session([:], permissions: Self.reportsOnly)
        others.tending.people.openAct(on: "1", handle: "@cy@m.example", local: true, at: Self.host, in: reports)
        #expect(others.tending.people.asking?.offered.contains(.freeze) == false)
    }

    @Test("The figure of those waiting follows a let-in and a turn-away; a notice that gives the one who signed up by id brings them in, and the tab's search is left as it was")
    func countsAndNoticeById() async throws {
        let (session, _, pages) = try await session([
            Self.pending: Self.accounts([Self.account("3", "ann", approved: false), Self.account("2", "bo", approved: false)]),
            "\(Self.list)?status=active&username=cy": Self.accounts([Self.account("1", "cy")]),
            "\(Self.one)/3/approve": PageServer.Answer(body: Self.account("3", "ann")),
            "\(Self.one)/2/reject": PageServer.Answer(body: "{}"),
            "\(Self.one)/2": PageServer.Answer(body: Self.account("2", "bo", approved: false)),
        ])
        let people = pages.tending.people
        await people.countWaiting(Self.page, in: session)
        #expect(people.waiting(at: Self.host, in: session)?.count == 2)
        await people.opened(Self.page, in: session)
        await people.letIn("3", of: Self.page, in: session)
        #expect(people.waiting(at: Self.host, in: session)?.count == 1)

        await people.find(AdminAccountFilter(state: .active, words: "cy"), on: Self.page, in: session)
        let bo = NoticePerson(handle: "@bo@m.example", name: "bo", accountID: "2")
        #expect(await people.lightSignUp(bo, on: Self.page, in: session) == TendingPeopleSaid.rowID("2"))
        let said = people.said(of: Self.page, in: session)
        #expect(said.filter == AdminAccountFilter(state: .active, words: "cy"), "the search was left alone")
        #expect(said.accounts.map(\.id) == ["2", "1"])
        await people.turnAway("2", of: Self.page, in: session)
        #expect(people.waiting(at: Self.host, in: session)?.count == 0)
    }

    @Test("What only staff see of somebody is let go as their page goes")
    func theStaffBlockIsLetGo() async throws {
        let (session, server, pages) = try await session(["\(Self.one)/3": PageServer.Answer(body: Self.account("3", "ann"))])
        let ann = Person(source: Self.source, accountID: "3", handle: "@ann@m.example", name: "ann")
        let people = pages.tending.people
        await people.staffOpened(of: ann, in: session)
        #expect(people.staffSaid(of: ann, in: session) != nil)
        people.forgetStaff(of: ann)
        #expect(people.staffSaid(of: ann, in: session) == nil)
        await people.staffOpened(of: ann, in: session)
        #expect(await server.arrivals(of: "\(Self.one)/3") == 2, "asked again when the page comes back")
    }

    @Test("A report's `…` offers an act on the account it names, where the reader may act")
    func theReportsAccountAct() throws {
        let ada = Person(source: Self.source, accountID: "42", handle: "@ada@m.example", name: "Ada")
        let report = AdminReport(id: "1", closed: false, category: "spam", target: ada)
        let more = ReportRowView.more(
            report, host: Self.host, acts: true, acting: false, onAct: { _, _ in }, onOpenPage: { _ in }, onActOnAccount: { _ in },
            language: .english
        )
        #expect(more.items.map(\.name) == ["Take it on", "Close", "Act on @ada@m.example…", "Write a note on m.example's page"])
    }

    @Test("Every word of the tab and the sheet is in each language the app speaks")
    func wordsInEveryLanguage() {
        var keys = [
            "tend.tab.people", "tend.count.reports", "tend.count.people", "tend.act.account", "tend.people.foot.more",
            "tend.people.foot.end", "tend.people.none", "tend.people.asking", "tend.people.reading", "tend.people.unlisted",
            "tend.people.state", "tend.people.find", "tend.people.wrote", "tend.people.letIn", "tend.people.turnAway",
            "tend.people.turnAway.title", "tend.people.turnAway.line", "tend.act.title", "tend.act.words", "tend.act.tell",
            "tend.act.suspend.ask", "tend.staff.act", "tend.staff.title", "tend.staff.since", "tend.staff.email", "tend.staff.ip",
        ]
        keys += AdminAccountState.allCases.map { "tend.people.state.\($0.rawValue)" }
        keys += ["waiting", "frozen", "limited", "sensitive", "suspended", "unconfirmed"].map { "tend.people.is.\($0)" }
        for act in AccountAct.allCases {
            let name = String(describing: act)
            keys += ["tend.act.line.\(name)", "tend.act.name.\(name)", "tend.act.send.\(name)", "tend.act.done.\(name)"]
            if act.undoes { keys.append("tend.undo.\(name)") }
        }
        for language in DummyLanguage.allCases {
            for key in keys { #expect(L10n.t(key, language: language) != key, "\(key) in \(language)") }
        }
    }
}
