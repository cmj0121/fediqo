import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #339: a post or a person reported to those who answer for the source — where it is offered and
/// where the sign-in holds less, the sheet it is written on, what the source is sent and what the
/// sheet then says, and that leaving it, or a source refusing it, changes nothing here.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`); every deadline is on a
/// clock nobody turns.
@MainActor
@Suite("A post or a person reported to the server", .serialized, .watched)
struct ReportTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let follows = "\(reads) read:follows write:follows"
    private static let reporting = "\(follows) read:mutes write:mutes read:blocks write:blocks write:reports"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let lookup = "/api/v1/accounts/lookup?acct=ada"
    private static let farLookup = "/api/v1/accounts/lookup?acct=far@far.example"
    private static let rules = "/api/v1/instance/rules"
    private static let reports = "/api/v1/reports"
    private static let stands = "/api/v1/accounts/relationships?id%5B%5D=42"

    private static let ada = DummyPerson(handle: "@ada@m.example", host: host)!
    private static let far = DummyPerson(handle: "@far@far.example", host: host)!

    private static let rulesSaid = PageServer.Answer(
        body: #"[{"id":"1","text":"No spam, please.","hint":"Posts made only to sell or to be seen.","translations":{}},{"id":"2","text":"Be kind to one another","hint":"","translations":{}}]"#
    )

    private static func taken(_ account: String, forwarded: Bool = false) -> PageServer.Answer {
        PageServer.Answer(body: #"{"id":"4","action_taken":false,"category":"violation","comment":"","forwarded":\#(forwarded),"status_ids":[],"rule_ids":["1"],"target_account":{"id":"\#(account)","acct":"x"}}"#)
    }

    private static let standing = PageServer.Answer(
        body: #"[{"id":"42","following":false,"showing_reblogs":false,"notifying":false,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}]"#
    )

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer) {
        let base: [String: PageServer.Answer] = [
            Self.who: PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#),
            Self.lookup: PageServer.Answer(body: #"{"id":"42","acct":"ada","display_name":"Ada"}"#),
            Self.farLookup: PageServer.Answer(body: #"{"id":"43","acct":"far@far.example","display_name":"Far"}"#),
            Self.rules: Self.rulesSaid,
            Self.stands: Self.standing,
        ]
        let server = PageServer(routes.merging(base) { mine, _ in mine })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        await session.store.ingest([
            note("11", "@ada@m.example", "Buy now, cheap"), note("12", "@ada@m.example", "Buy again"),
            note("13", "@me@m.example", "my own"), note("14", "@far@far.example", "far words"),
            Note(id: "f1", source: Self.forum, author: "Forumite", handle: "", body: "a thread", postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []),
        ])
        await session.reloadFromStore()
        return (session, server)
    }

    private func note(_ id: String, _ handle: String, _ body: String) -> Note {
        Note(
            id: "https://m.example/\(id)", source: Self.source, author: "Somebody", handle: handle, body: body,
            postedAt: Date(timeIntervalSince1970: 1_700_000_000 + (Double(id) ?? 0)), categories: [.public], statusID: id
        )
    }

    private func signIn(_ session: ShellSession, holding scopes: String = ReportTests.reporting) async throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
    }

    private func sent(_ server: PageServer) async -> [String] {
        await server.sent.filter { $0.ask == Self.reports }.map(\.body)
    }

    // MARK: - Where it is offered

    @Test("Somebody else's post at a source where things are reported offers Report post in its `…`; the reader's own, a forum's and a post at a source nobody is signed in to do not; signed in for less, it is dim with the lock, its sentence at the menu's head, and its press only asks")
    func whereOffered() async throws {
        let (session, _) = await session([:])
        let theirs = try #require(session.heldPosts(of: Self.ada).first)
        #expect(session.reportOffer(on: theirs) == nil, "nobody signed in")
        try await signIn(session)
        let offer = try #require(session.reportOffer(on: theirs))
        #expect(offer.who.id == Self.ada.id && offer.post == theirs.statusID && offer.lock == nil)
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        #expect(session.heldPosts(of: me).allSatisfy { session.reportOffer(on: $0) == nil }, "the reader's own")
        let forumite = DummyItem(try #require(session.notes.first { $0.source == Self.forum }))
        #expect(session.reportOffer(on: forumite) == nil, "a kind of source with no reports")

        var acting = session.acting(on: theirs)
        acting.report = ItemActing.Report(lock: offer.lock) {}
        let menu = ItemActs.more(on: theirs, acting: acting, language: .english)
        #expect(menu.items.last?.name == "Report post…" && menu.items.last?.look == .live)

        try await signIn(session, holding: Self.follows)
        let locked = try #require(session.reportOffer(on: theirs)?.lock)
        acting.report = ItemActing.Report(lock: locked) {}
        let dim = ItemActs.more(on: theirs, acting: acting, language: .english)
        #expect(dim.items.last?.look == .dim(.askAgain) && dim.items.last?.answers == true)
        #expect(dim.whys.contains(L10n.t("part.reports.unasked", language: .english)))

        let pages = ShellPersonPages()
        await pages.reports.start(Self.ada, post: theirs.statusID, people: pages, in: session)
        #expect(pages.reports.open == nil && session.partAsks.open?.ticked == [.reports], "the press only asks")
    }

    @Test("Somebody's page offers Report… last in its `…`, whatever the source said of how the reader stands, and its press puts the sheet up and sends nothing")
    func onTheirPage() async throws {
        let (session, server) = await session([:])
        try await signIn(session)
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        await pages.standsOpened(to: Self.ada, in: session)
        let acting = try #require(pages.stands(to: Self.ada, in: session))
        #expect(acting.reporting == [.report] && acting.reportsLock == nil)
        #expect(acting.menu { _ in }.items.last?.name == "Report…")
        await pages.act(.report, on: Self.ada, in: session)
        #expect(pages.reports.open?.who == Self.ada && pages.reports.open?.post == nil)
        #expect(await sent(server).isEmpty)
    }

    // MARK: - The sheet

    @Test("The sheet names whom it reports and who is told, offers the four kinds, the server's rules as the server words them only for a violation, the posts of theirs this device holds with the one it began from chosen, and a few words; Send waits for a rule where it is a violation")
    func theSheet() async throws {
        let (session, server) = await session([:])
        try await signIn(session)
        let pages = ShellPersonPages()
        await pages.reports.start(Self.ada, post: "12", people: pages, in: session)
        let askedOf = await server.asked
        #expect(askedOf.contains(Self.rules) && askedOf.contains(Self.lookup))
        var said = try #require(pages.reports.said(people: pages, in: session))
        #expect(said.title(language: .english) == "Report @ada@m.example" && said.known && said.server == nil)
        #expect(said.told(language: .english).hasPrefix("Those who answer for m.example are told"))
        #expect(said.posts.map(\.id) == ["12", "11"] && said.draft.posts == ["12"])
        #expect(said.posts.first?.line == "Buy again")
        #expect(said.forwardWords() == nil, "somebody of this server: nobody else to tell")
        #expect(ReportCategory.allCases.map { ReportSaid.category($0, language: .english) } == [
            "Spam", "Against the law", "Against the server's rules", "Something else",
        ])
        #expect(said.sends && !said.asksRules)

        pages.reports.draft.category = .violation
        said = try #require(pages.reports.said(people: pages, in: session))
        #expect(said.asksRules && !said.sends, "a violation names a rule")
        #expect(said.ruleList.map(\.text) == ["No spam, please.", "Be kind to one another"])
        #expect(said.ruleList.first?.hint == "Posts made only to sell or to be seen." && said.ruleList.last?.hint == nil)
        pages.reports.draft.rules = ["1"]
        #expect(pages.reports.said(people: pages, in: session)?.sends == true)
        pages.reports.draft.words = String(repeating: "a", count: MastodonReports.wordsLength + 1)
        #expect(pages.reports.said(people: pages, in: session)?.sends == false)
        #expect(pages.reports.said(people: pages, in: session)?.wordsCount(language: .english) == "1001 of 1000 letters")

        // Leaving before sending sends nothing, and keeps nothing of what was written.
        pages.reports.close()
        #expect(pages.reports.open == nil && pages.reports.draft == ReportDraft())
        #expect(await sent(server).isEmpty)
    }

    @Test("Sent, the source is told exactly what was written: the account, each post chosen, the words, that nobody else is told, the kind and the rule; the sheet says the source has it, and offers what the person can do themselves — mute or block")
    func sent() async throws {
        let (session, server) = await session([Self.reports: Self.taken("42")])
        try await signIn(session)
        let pages = ShellPersonPages()
        await pages.reports.start(Self.ada, post: "12", people: pages, in: session)
        pages.reports.draft.category = .violation
        pages.reports.draft.rules = ["1"]
        pages.reports.draft.posts.insert("11")
        pages.reports.draft.words = "Selling things"
        #expect(await pages.reports.send(people: pages, in: session))
        #expect(await sent(server) == [
            "account_id=42&status_ids%5B%5D=12&status_ids%5B%5D=11&comment=Selling%20things&forward=false&category=violation&rule_ids%5B%5D=1",
        ])
        let said = try #require(pages.reports.said(people: pages, in: session))
        #expect(said.isSent && said.stageLine(language: .english) == "m.example has the report.")
        #expect(said.afterwards == [.mute, .block])
        #expect(!(await pages.reports.send(people: pages, in: session)), "sent once")
        #expect(session.notes.count == 5 && session.hides.hides.isEmpty, "nothing here changes")

        pages.reports.afterwards(.block, people: pages, in: session)
        #expect(pages.reports.open == nil && pages.standingAsk == nil, "nothing more is put up while the sheet comes down")
        pages.reports.dismissed(people: pages, in: session)
        #expect(pages.standingAsk?.act == .block && pages.standingAsk?.who == Self.ada)
        pages.reports.dismissed(people: pages, in: session)
        #expect(pages.reports.following == nil, "once")
    }

    @Test("Of somebody of another server, the sheet offers to tell that server too, naming it, off until the person turns it on: sent as they left it, and the sheet says the other server was told only where the source says it was")
    func toldOrNot() async throws {
        let (session, server) = await session([Self.reports: Self.taken("43", forwarded: true)])
        try await signIn(session)
        let pages = ShellPersonPages()
        await pages.reports.start(Self.far, post: "14", people: pages, in: session)
        let said = try #require(pages.reports.said(people: pages, in: session))
        #expect(said.server == "far.example" && !said.draft.forward)
        #expect(said.forwardWords(language: .english) == "Tell far.example as well")
        #expect(said.forwardLine(language: .english)?.contains("Only if you turn this on is far.example sent a copy") == true)
        await pages.reports.send(people: pages, in: session)
        #expect(await sent(server).first?.contains("&forward=false&") == true, "nothing forwarded unless chosen")
        pages.reports.close()

        await pages.reports.start(Self.far, post: "14", people: pages, in: session)
        pages.reports.draft.forward = true
        await pages.reports.send(people: pages, in: session)
        #expect(await sent(server).last?.contains("&forward=true&") == true)
        #expect(pages.reports.said(people: pages, in: session)?.stageLine(language: .english) == "m.example has the report, and told far.example.")
    }

    @Test("A source that refuses says so in its own words, and one that fails says it did not take it: the sheet keeps what was written to send again, and nothing on this device changes")
    func refused() async throws {
        let (session, server) = await session([
            Self.reports: PageServer.Answer(body: #"{"error":"Validation failed: Rule ids does not reference valid rules"}"#, status: 422),
        ])
        try await signIn(session)
        let pages = ShellPersonPages()
        await pages.reports.start(Self.ada, people: pages, in: session)
        pages.reports.draft.category = .other
        pages.reports.draft.words = "words"
        #expect(!(await pages.reports.send(people: pages, in: session)))
        var said = try #require(pages.reports.said(people: pages, in: session))
        #expect(said.stageLine(language: .english) == "m.example did not take the report: Validation failed: Rule ids does not reference valid rules")
        #expect(said.sends && said.draft.words == "words", "kept, to send again")
        await server.answer(Self.reports, PageServer.Answer(body: "<html>", status: 500))
        #expect(!(await pages.reports.send(people: pages, in: session)))
        said = try #require(pages.reports.said(people: pages, in: session))
        #expect(said.stageLine(language: .english)?.hasPrefix("m.example did not take the report.") == true)
        #expect(session.notes.count == 5 && session.hides.hides.isEmpty)
    }

    @Test("A reader who changed while the sheet was up sends nothing, and is told it was not taken")
    func anotherReader() async throws {
        let (session, server) = await session([Self.reports: Self.taken("42")])
        try await signIn(session)
        let pages = ShellPersonPages()
        await pages.reports.start(Self.ada, people: pages, in: session)
        try await signIn(session, holding: Self.reporting + " write:statuses")
        #expect(!(await pages.reports.send(people: pages, in: session)))
        #expect(await sent(server).isEmpty)
    }

    @Test("The reader is never reported: not from their own page or post, not before the source has said who the reader is, and not where somebody named another way turns out to be them")
    func neverTheReader() async throws {
        let (session, server) = await session([
            "/api/v1/accounts/lookup?acct=alias": PageServer.Answer(body: #"{"id":"7","acct":"alias","display_name":"Me"}"#),
        ])
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        let pages = ShellPersonPages()
        try await signIn(session)
        await pages.reports.start(me, people: pages, in: session)
        #expect(pages.reports.open == nil)
        let alias = try #require(DummyPerson(handle: "@alias@m.example", host: Self.host))
        await pages.reports.start(alias, people: pages, in: session)
        #expect(pages.reports.open == nil, "the source said it is the reader")
        let person = try MastodonPeople.person(from: Data(#"{"id":"7","acct":"alias"}"#.utf8), source: Self.source)
        #expect(!ShellReports.isSomebodyElse(person, at: Self.host, in: session))
        await pages.opened(Self.ada, in: session)
        #expect(pages.stands(to: Self.ada, in: session)?.reporting == [.report])
        #expect(await sent(server).isEmpty)
    }

    @Test("Every sentence of the report is written in each language, with the places it fills")
    func written() {
        for key in ["report.title", "report.told", "report.forward", "report.forward.line", "report.sent", "report.sent.forwarded",
                    "report.failed", "report.failed.said", "report.rules.failed", "report.posts.none", "item.act.report",
                    "person.act.report", "part.reports.unasked", "part.reports.ask.title", "part.reports.name"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
            }
        }
    }
}
