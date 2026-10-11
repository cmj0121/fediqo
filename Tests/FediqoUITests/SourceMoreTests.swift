import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #321, on a source's own page: what is asked of a host for its longer account, the servers
/// it knows and how busy it has been, when, and what the page is handed and says in each state
/// — and that a source which is not asked who people are is handed nothing and asked nothing.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), and each ends by
/// itself: a held ask is let go in a `defer`, and by the server after its patience.
@MainActor
@Suite("What a source says of itself beyond its document, on its page", .serialized, .timeLimit(.minutes(1)))
struct SourceMoreTests {
    typealias Told = SourceMoreSaid.Told
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let document = "/api/v2/instance"
    private static let account = "/api/v1/instance/extended_description"
    private static let servers = "/api/v1/instance/peers"
    private static let activity = "/api/v1/instance/activity"

    private static func served(_ more: [String: PageServer.Answer] = [:]) -> [String: PageServer.Answer] {
        [
            document: PageServer.Answer(body: #"{"domain":"m.example","version":"4.6.6","configuration":{"accounts":{"max_featured_tags":10}}}"#),
            account: PageServer.Answer(body: #"{"updated_at":null,"content":"<p>Run by friends.</p>"}"#),
            servers: PageServer.Answer(body: #"["a.example","b.example"]"#),
            activity: PageServer.Answer(body: #"[{"week":"1700000000","statuses":"1204","logins":"31","registrations":"2"}]"#),
        ].merging(more) { $1 }
    }

    private static let off = PageServer.Answer(body: "", status: 404)
    private static let week = HostWeek(week: Date(timeIntervalSince1970: 1_700_000_000), posts: 1204, signIns: 31, newPeople: 2)
    private static let whole = SourceMoreSaid(
        source: host, account: .said(HostAccount(paragraphs: ["Run by friends."])),
        servers: .said(HostServers(counted: 2, names: ["a.example", "b.example"])), weeks: .said([week])
    )

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        let work = SourceWork()
        session.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    private func signIn(_ session: ShellSession, as access: String = "tok") throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) {
            _ = try session.mastodon.tokens.forget(held)
            session.mastodon.refresh()
        }
        try session.mastodon.tokens.save(MastodonToken(host: Self.host, accessToken: access, clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
    }

    /// The wires a transfer already ended is like: they go on answering an ask that was
    /// called off, so what such an answer may still do is what the check is of.
    private func bare(_ more: ShellSourceMore, _ server: PageServer) {
        more.reaching = { MastodonHostMore(http: server, host: $0) }
        more.hosts.reaching = { MastodonClient(http: server, host: $0) }
    }

    private func count(_ server: PageServer, _ ask: String) async -> Int {
        await server.asked.filter { $0 == ask }.count
    }

    // MARK: - What is asked, and when

    /// What the page holds once it has opened: the two asked for then, and the servers not yet.
    private static var opened: SourceMoreSaid {
        var said = whole
        said.servers = .waiting
        return said
    }

    /// `said` as somebody signed in is handed it: with the line to the people the source
    /// suggests, which nobody unsigned is offered (#315).
    private static func signedIn(_ said: SourceMoreSaid) -> SourceMoreSaid {
        var said = said
        said.suggested = true
        return said
    }

    @Test("Opening a source's page asks the host for its longer account and its weeks — two asks, of that host alone, with no sign-in, listed in the run's record — and not for the servers it knows, nor its document; opened again, nobody is asked. The servers are asked for at their line's press: one ask, and a second press asks nothing")
    func openingAsksTwoAndThePressOne() async throws {
        let (session, server, work) = await session(Self.served())
        let more = ShellPersonPages().more
        #expect(more.said(at: Self.host, in: session) == SourceMoreSaid(source: Self.host), "before anything answered")
        await more.opened(Self.host, in: session)
        #expect(await server.asked == [Self.account, Self.activity], "the servers it knows are not asked for by opening")
        #expect(await server.bearers.allSatisfy(\.isEmpty))
        #expect(work.record.map(\.purpose) == [.serverSays, .serverSays] && work.record.allSatisfy { $0.reached == Self.host && $0.source == Self.host })
        #expect(more.said(at: Self.host, in: session) == Self.opened)
        await more.opened(Self.host, in: session)
        #expect(await server.asked.count == 2)

        await more.servers(Self.host, in: session)
        #expect(await server.asked == [Self.account, Self.activity, Self.servers])
        #expect(more.said(at: Self.host, in: session) == Self.whole)
        await more.servers(Self.host, in: session)
        await more.opened(Self.host, in: session)
        #expect(await count(server, Self.servers) == 1, "folding the line and unfolding it asks nothing")
        #expect(await count(server, Self.document) == 0 && work.record.count == 3)
        #expect(session.notes.isEmpty)
    }

    @Test("A thing is absent where the host says its address is not there, remembered for the run and not asked for again — the servers' line from its press on; a record that is not there, a refusal and an unreadable answer are failures, and a failed list of servers is asked for again at its own press; a host asked and found with none of the three says so, with the press that asks again")
    func absentWhereTheHostSaysSo() async throws {
        let (session, server, _) = await session(Self.served([Self.servers: Self.off, Self.activity: PageServer.Answer(body: #"{"error":"Not Found"}"#, status: 404)]))
        let more = ShellPersonPages().more
        await more.opened(Self.host, in: session)
        #expect(more.said(at: Self.host, in: session)?.weeks == nil && more.said(at: Self.host, in: session)?.servers == .waiting)
        await more.servers(Self.host, in: session)
        let said = try #require(more.said(at: Self.host, in: session))
        #expect(said.servers == nil && said.account == Self.whole.account && !said.askingServers && !said.isAbsent(opensDirectory: false))
        #expect(more.hosts.has(.knownServers, at: Self.host) == .absent && more.hosts.has(.longerAccount, at: Self.host) == .unsaid)
        await more.servers(Self.host, in: session)
        await more.opened(Self.host, in: session)
        #expect(await server.asked.count == 3, "what is absent is not asked for again")

        let (other, flaky, _) = await self.session(Self.served([
            Self.account: PageServer.Answer(body: #"{"error":"Record not found"}"#, status: 404),
            Self.servers: PageServer.Answer(body: "", status: 429), Self.activity: PageServer.Answer(body: "<html>"),
        ]))
        let failing = ShellPersonPages().more
        await failing.opened(Self.host, in: other)
        await failing.servers(Self.host, in: other)
        let failed = try #require(failing.said(at: Self.host, in: other))
        #expect(failed.account == .failed && failed.servers == .failed && failed.weeks == .failed && !failed.asking)
        await failing.opened(Self.host, in: other)
        await failing.servers(Self.host, in: other)
        #expect(await flaky.asked == [Self.account, Self.activity, Self.servers, Self.servers], "its Try again asks for the servers alone")

        let (bare, none, _) = await self.session(Self.served([Self.account: Self.off, Self.servers: Self.off, Self.activity: Self.off]))
        let nothing = ShellPersonPages().more
        await nothing.opened(Self.host, in: bare)
        await nothing.servers(Self.host, in: bare)
        #expect(nothing.said(at: Self.host, in: bare)?.isAbsent(opensDirectory: false) == true)
        #expect(SourceMoreSaid.offersNone(Self.host, language: .english) == "m.example offers none of these here.")
        await none.answer(Self.account, Self.served()[Self.account])
        await nothing.again(Self.host, in: bare)
        #expect(nothing.said(at: Self.host, in: bare)?.account == Self.whole.account, "asked again, what it now gives is there")
        #expect(nothing.said(at: Self.host, in: bare)?.servers == .waiting && nothing.hosts.has(.knownServers, at: Self.host) == .unsaid)
    }

    @Test("Asking again lets go of what the run knew of the host and asks the two afresh, keeping what was said drawn until they land; the servers go back to being asked for at their press")
    func askingAgainIsAfresh() async throws {
        let (session, server, _) = await session(Self.served([Self.activity: PageServer.Answer(body: "", status: 500)]))
        let more = ShellPersonPages().more
        await more.opened(Self.host, in: session)
        await more.servers(Self.host, in: session)
        #expect(more.said(at: Self.host, in: session)?.weeks == .failed)
        await server.answer(Self.activity, Self.served()[Self.activity])
        await more.again(Self.host, in: session)
        #expect(more.said(at: Self.host, in: session) == Self.opened)
        #expect(await server.asked == [Self.account, Self.activity, Self.servers, Self.account, Self.activity])
        await more.servers(Self.host, in: session)
        #expect(await count(server, Self.servers) == 2 && more.said(at: Self.host, in: session) == Self.whole)
    }

    @Test("The list of servers has a ceiling of its own: one larger than a small ask may bring is read, counted whole and kept to its first names; one past the ceiling is cut off and said as more than is read here, not as a failure to ask")
    func theServersCeiling() async throws {
        let large = PageServer.Answer(body: "[" + String(repeating: #""a.example","#, count: 120_000) + #""b.example"]"#)
        let (session, _, _) = await session(Self.served([Self.servers: large]))
        let more = ShellPersonPages().more
        await more.servers(Self.host, in: session)
        guard case .said(let servers) = more.said(at: Self.host, in: session)?.servers else {
            Issue.record("a list past the small ceiling was not read")
            return
        }
        #expect(servers.counted == 120_001 && servers.names.count == HostServers.kept && large.body.utf8.count > SourceReach.smallBody)

        let huge = PageServer.Answer(body: "[" + String(repeating: #""a.example","#, count: 700_000) + #""b.example"]"#)
        let (other, _, _) = await self.session(Self.served([Self.servers: huge]))
        let cut = ShellPersonPages().more
        await cut.servers(Self.host, in: other)
        #expect(cut.said(at: Self.host, in: other)?.servers == .tooLarge && huge.body.utf8.count > SourceReach.serversBody)
        #expect(SourceMoreSaid.tooMany(Self.host, language: .english) == "m.example names more servers than Fediqo reads here.")
        let live = try #require(SourceReach.atItsHost(URLSessionClient(), under: SourceReach.serversBody) as? URLSessionClient)
        #expect(live.byteLimit == 8 << 20 && live.sameOriginOnly)
    }

    // MARK: - While an ask is out

    @Test("An ask is the pages' and not the sheet's: the sheet leaving stops neither the opening's asks nor the servers', each lands for the next visit, and opening, asking again or pressing the line again while its ask is out asks nothing more")
    func theAskOutlivesTheSheet() async throws {
        let (session, server, _) = await session(Self.served())
        let more = ShellPersonPages().more
        await server.hold(Self.activity)
        defer { Task { await server.release(Self.activity) } }
        let sheet = Task { await more.opened(Self.host, in: session) }
        await server.arrival(of: Self.activity)
        #expect(more.said(at: Self.host, in: session)?.asking == true && more.said(at: Self.host, in: session)?.weeks == .waiting)
        sheet.cancel()
        let second = Task { await more.opened(Self.host, in: session) }
        await more.again(Self.host, in: session)
        #expect(await server.asked == [Self.account, Self.activity])
        await server.release(Self.activity)
        await second.value
        await sheet.value
        #expect(more.said(at: Self.host, in: session) == Self.opened)

        await server.hold(Self.servers)
        defer { Task { await server.release(Self.servers) } }
        let press = Task { await more.servers(Self.host, in: session) }
        await server.arrival(of: Self.servers)
        #expect(more.said(at: Self.host, in: session)?.askingServers == true)
        press.cancel()
        let again = Task { await more.servers(Self.host, in: session) }
        await server.release(Self.servers)
        await again.value
        await press.value
        #expect(more.said(at: Self.host, in: session) == Self.whole)
        #expect(await count(server, Self.servers) == 1)
    }

    @Test("A round that was stopped before it answered leaves nothing saying Asking, and is asked again when the page next opens")
    func aStoppedRoundIsAskedAgain() async throws {
        let (session, server, _) = await session(Self.served([Self.activity: PageServer.Answer(body: "", cancelled: true)]))
        let more = ShellPersonPages().more
        await more.opened(Self.host, in: session)
        let stopped = try #require(more.said(at: Self.host, in: session))
        #expect(!stopped.asking && stopped.account == Self.whole.account && stopped.weeks == .waiting)
        await server.answer(Self.activity, Self.served()[Self.activity])
        await more.opened(Self.host, in: session)
        #expect(more.said(at: Self.host, in: session) == Self.opened)
    }

    @Test("What was asked as one sign-in is not shown to the next, and its answer, come late, lands nowhere: a not-found the first round brings late makes nothing absent, the round let go asks nothing more, and a list of servers asked for by one reader, come back after another has taken their place, is not drawn for them")
    func asWhoeverAsked() async throws {
        let (session, server, _) = await session(Self.served([Self.account: Self.off]))
        let more = ShellPersonPages().more
        bare(more, server)
        await server.hold(Self.account)
        defer { Task { await server.release(Self.account) } }
        let unsigned = Task { await more.opened(Self.host, in: session) }
        await server.arrival(of: Self.account)
        try signIn(session)
        #expect(more.said(at: Self.host, in: session) == Self.signedIn(SourceMoreSaid(source: Self.host)), "nobody's answers are not the reader's")
        let signed = Task { await more.opened(Self.host, in: session) }
        await server.arrival(of: Self.account, times: 2)
        await server.releaseOne(Self.account)
        await unsigned.value
        #expect(more.hosts.has(.longerAccount, at: Self.host) == .unsaid, "a late not-found makes nothing absent")
        #expect(more.said(at: Self.host, in: session)?.asking == true)
        #expect(await count(server, Self.activity) == 0, "and the round let go asks nothing more")
        await server.answer(Self.account, Self.served()[Self.account])
        await server.release(Self.account)
        await signed.value
        #expect(more.said(at: Self.host, in: session) == Self.signedIn(Self.opened))

        await server.hold(Self.servers)
        defer { Task { await server.release(Self.servers) } }
        let press = Task { await more.servers(Self.host, in: session) }
        await server.arrival(of: Self.servers)
        try signIn(session, as: "another")
        await more.opened(Self.host, in: session)
        #expect(more.said(at: Self.host, in: session)?.askingServers == false, "a sign-in change lets the ask go")
        await server.release(Self.servers)
        await press.value
        #expect(more.said(at: Self.host, in: session) == Self.signedIn(Self.opened), "the first reader's list is not the second's")
        await more.servers(Self.host, in: session)
        #expect(more.said(at: Self.host, in: session) == Self.signedIn(Self.whole))
        #expect(await count(server, Self.servers) == 2)
    }

    @Test("A host's document is asked for once a run and waited on by whoever wants it meanwhile; one that did not come is owed still; and one asked for before the host was let go, come late, is not believed")
    func theDocumentOnce() async throws {
        let (session, server, work) = await session([:])
        let hosts = ShellPersonPages().more.hosts
        await hosts.hear(Self.host, in: session)
        #expect(!hosts.heard(Self.host), "a document that did not come is not heard")
        await server.answer(Self.document, PageServer.Answer(body: #"{"domain":"m.example","version":"4.6.6","configuration":{"accounts":{"max_featured_tags":0}}}"#))
        await server.hold(Self.document)
        defer { Task { await server.release(Self.document) } }
        let first = Task { await hosts.hear(Self.host, in: session) }
        await server.arrival(of: Self.document, times: 2)
        let second = Task { await hosts.hear("M.Example", in: session) }
        await server.release(Self.document)
        await first.value
        await second.value
        #expect(hosts.heard(Self.host) && hosts.has(.featuredTags, at: Self.host) == .absent)
        #expect(await count(server, Self.document) == 2, "the second waited on the first, and asked nothing")
        await hosts.hear(Self.host, in: session)
        #expect(await count(server, Self.document) == 2, "and once had, it is not asked for again")
        #expect(work.record.allSatisfy { $0.purpose == .serverCheck && $0.reached == Self.host })

        // Let go while its document is on the wire: what that brings is not believed.
        hosts.reaching = { MastodonClient(http: server, host: $0) }
        hosts.askAfresh(Self.host)
        #expect(!hosts.heard(Self.host) && hosts.has(.featuredTags, at: Self.host) == .unsaid)
        await server.hold(Self.document)
        let late = Task { await hosts.hear(Self.host, in: session) }
        await server.arrival(of: Self.document, times: 3)
        hosts.notFound(.activity, at: Self.host, round: hosts.round(at: Self.host))
        hosts.askAfresh(Self.host)
        #expect(hosts.has(.activity, at: Self.host) == .unsaid)
        await server.release(Self.document)
        await late.value
        #expect(!hosts.heard(Self.host) && hosts.has(.featuredTags, at: Self.host) == .unsaid, "a late document is not believed")
        await hosts.hear(Self.host, in: session)
        #expect(hosts.heard(Self.host) && hosts.has(.featuredTags, at: Self.host) == .absent)
        #expect(await count(server, Self.document) == 4)
        // Another program's document at the same address came, and says nothing of these things.
        await server.answer(Self.document, PageServer.Answer(body: #"{"version":"2.7.2 (compatible; Pleroma 2.6.0)","configuration":{"accounts":{"max_featured_tags":0}}}"#))
        hosts.askAfresh(Self.host)
        await hosts.hear(Self.host, in: session)
        #expect(hosts.heard(Self.host) && hosts.has(.featuredTags, at: Self.host) == .unsaid)
    }

    @Test("The asks go out under the small body's ceiling and kept to the host asked: the ceiling is on the plain client before it is listed and bounded, and the live client refuses every redirect off that host")
    func smallAndOfThatHost() async throws {
        let live = try #require(SourceReach.smallAtItsHost(URLSessionClient()) as? URLSessionClient)
        #expect(live.byteLimit == SourceReach.smallBody && live.sameOriginOnly)
        // A test's client is refused what it brought past the ceiling.
        let big = PageServer.Answer(body: #"{"content":"\#(String(repeating: "words ", count: 200_000))"}"#)
        let (session, _, _) = await session(Self.served([Self.account: big]))
        let more = ShellPersonPages().more
        await more.opened(Self.host, in: session)
        #expect(more.said(at: Self.host, in: session)?.account == .failed && more.said(at: Self.host, in: session)?.weeks == Self.whole.weeks)
    }

    // MARK: - A forum

    @Test("A source that is not asked who people are is handed nothing and asked nothing, and one that is gone likewise: its page draws no block and is the page it was — and the files that draw and ask name no kind of source")
    func aForumReadsTheSame() async throws {
        let (session, server, work) = await session(Self.served())
        let more = ShellPersonPages().more
        for host in [Self.forum.host, "gone.example"] {
            #expect(more.said(at: host, in: session) == nil)
            await more.opened(host, in: session)
            await more.again(host, in: session)
        }
        #expect(await server.asked.isEmpty && work.record.isEmpty)

        func height<Block: View>(_ block: Block) -> CGFloat {
            let hosted = NSHostingView(rootView: VStack(spacing: 0) { block }.frame(width: 460))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize.height
        }
        #expect(height(SourceMoreBlock(host: Self.forum.host, more: more, session: session)) == 0, "a forum's page gains nothing")
        #expect(height(SourceMoreBlock(host: Self.host, more: more, session: session)) > 0)
        #expect(await server.asked.isEmpty, "drawing asks nobody: the asking is the page opening")

        for file in ["SourceMore.swift", "ShellSourceMore.swift", "ShellHosts.swift"] {
            let text = try String(contentsOf: Self.shell.appending(path: file), encoding: .utf8)
            // The keeper of what hosts have reaches a host's document, and hands the kind that
            // document names to the one place the fact is read: it decides nothing by it itself.
            let reaches = file == "ShellHosts.swift" ? [".kind)", ".mastodon"] : []
            for word in ["ProtocolKind", ".kind ", ".kind)", ".kind.", "isForum", ".mastodon", ".discuz", ".discourse", "offers."] {
                #expect(!text.contains(word) || reaches.contains(word), "\(file) names \(word)")
            }
            #expect(!text.contains("== .mastodon") && !text.contains("case .mastodon"), "\(file) checks a kind")
        }
        let asked = try String(contentsOf: Self.shell.appending(path: "ShellSourceMore.swift"), encoding: .utf8)
        #expect(asked.contains("ShellPersonPages.source(at:"), "the one fact is read where a person's page reads it")
        let hosts = try String(contentsOf: Self.shell.appending(path: "ShellHosts.swift"), encoding: .utf8)
        #expect(hosts.contains("ShellPersonPages.saysPeople(Source(host: host, kind: said.kind))"))
        let kept = try String(contentsOf: Self.shell.appending(path: "ShellSession.swift"), encoding: .utf8)
        #expect(!kept.contains("MastodonHostsKnown") && !kept.contains("ShellHostsKnown"), "the session keeps none of it")
    }

    private static var shell: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI/Shell")
    }

    // MARK: - What the page says

    @Test("Each line says what it is and whose word it is: the count of servers is the source's figure written whole; a week's figures are written whole, with a dash and 'not said' where the source gave none; the foot under the names says how many of how many are drawn, that these are all, or how many are kept of how many it named")
    func theWords() {
        #expect(SourceMoreSaid.title("m.example", language: .english) == "More from m.example")
        #expect(SourceMoreSaid.askingLine("m.example", language: .english) == "Asking m.example…")
        #expect(SourceMoreSaid.Part.allCases.map { SourceMoreSaid.label($0, language: .english) } == ["More about it", "Servers it knows", "How busy it has been"])
        #expect(SourceMoreSaid.nothing(.account, source: "m.example", language: .english) == "m.example has written no longer account of itself.")
        #expect(SourceMoreSaid.nothing(.servers, source: "m.example", language: .english) == "m.example names no server it knows.")
        #expect(SourceMoreSaid.failed(.activity, source: "m.example", language: .english) == "Could not ask m.example how busy it has been.")

        let many = HostServers(counted: 4_112, names: (0..<2_000).map { "h\($0).example" })
        #expect(SourceMoreSaid.serversFigure(many, language: .english) == "4,112")
        #expect(SourceMoreSaid.spoken(.servers, figure: "4,112", language: .english) == "Servers it knows: 4,112")
        #expect(SourceMoreSaid.spoken(.account, figure: nil, language: .english) == "More about it")
        #expect(SourceMoreSaid.serversFoot(many, shown: 100, source: "m.example", language: .english) == "Showing 100 of 4,112.")
        #expect(SourceMoreSaid.offersMore(many, shown: 100) && !SourceMoreSaid.offersMore(many, shown: 2_000) && SourceMoreSaid.serversStep == 100)
        #expect(SourceMoreSaid.serversFoot(many, shown: 2_100, source: "m.example", language: .english) == "m.example names 4,112. Fediqo keeps the first 2,000 names.")
        let few = HostServers(counted: 2, names: ["a.example", "b.example"])
        #expect(SourceMoreSaid.serversFoot(few, shown: 100, source: "m.example", language: .english) == "These are all 2." && !SourceMoreSaid.offersMore(few, shown: 100))

        #expect(SourceMoreSaid.figure(1_204, language: .english) == "1,204" && SourceMoreSaid.figure(nil, language: .english) == "–")
        #expect(SourceMoreSaid.day(Self.week, language: .english).contains("2023"))
        let silent = HostWeek(week: Self.week.week, posts: 1_204)
        #expect(SourceMoreSaid.spoken(silent, language: .english) == "Week of \(SourceMoreSaid.day(silent, language: .english)): posts 1,204, sign-ins not said, new people not said.")
        #expect(SourceMoreSaid.cutLine(language: .english) == "This is the beginning of it. Fediqo reads the first 12,000 characters.")
        let dated = HostAccount(paragraphs: ["a"], updated: Self.week.week)
        #expect(SourceMoreSaid.updatedLine(dated, source: "m.example", language: .english)?.hasPrefix("m.example says it last wrote this on ") == true)
        #expect(SourceMoreSaid.updatedLine(HostAccount(paragraphs: ["a"]), source: "m.example") == nil)
    }

    @Test("Every sentence of the block is written in each language the app speaks, with the places it fills, no figure through a bare number's place, and the two Chinese tables alike")
    func writtenInEveryLanguage() throws {
        let resources = Self.shell.deletingLastPathComponent().appending(path: "Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\"source.more.") || line.hasPrefix("\"work.purpose.serverSays\"") else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        #expect(keys.count == 38 && keys.contains("source.more.servers.kept") && keys.contains("work.purpose.serverSays"))
        func places(_ text: String) -> [String] {
            text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted()
        }
        for key in keys {
            let written = L10n.t(key, language: .english)
            #expect(written != key && !written.contains("%d") && !written.contains("$d"), "\(key)")
            for language in DummyLanguage.allCases {
                let other = L10n.t(key, language: language)
                #expect(other != key && places(other) == places(written), "\(key) in \(language)")
            }
        }
        let taiwan = try Data(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
        #expect(SourceWork.Purpose.serverSays.isOfTheSource && !SourceWork.Purpose.serverSays.gathers)
        #expect(Set(SourceWork.Purpose.allCases.map(\.symbol)).contains(SourceWork.Purpose.serverSays.symbol))
    }

    @Test("The block is laid out to the width it is given and never past it, in light and in dark, in each state it has: asking, each line folded and unfolded, a failure, nothing written — taller unfolded than folded, and nothing at all for a host with none of the three")
    func theBlockLaidOut() {
        func size(_ said: SourceMoreSaid, _ width: CGFloat, scheme: ColorScheme = .light, unfolded: Set<SourceMoreSaid.Part> = []) -> CGSize {
            let block = VStack(spacing: 0) { SourceMoreSection(said: said, unfolded: unfolded) }
                .frame(width: width)
                .environment(\.colorScheme, scheme)
            let hosted = NSHostingView(rootView: block)
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let long = HostAccount(paragraphs: Array(repeating: String(repeating: "words and more words ", count: 30), count: 4), cut: true, updated: Self.week.week)
        let many = HostServers(counted: 4_112, names: (0..<2_000).map { "a-rather-long-name-of-a-server-number-\($0).a-rather-long-instance-name.example" })
        let weeks = (0..<12).map { HostWeek(week: Date(timeIntervalSince1970: 1_700_000_000 - Double($0) * 604_800), posts: 1_204_000, signIns: nil, newPeople: 31) }
        let full = SourceMoreSaid(source: Self.host, account: .said(long), servers: .said(many), weeks: .said(weeks))
        let states = [
            SourceMoreSaid(source: Self.host, asking: true), Self.whole, full,
            SourceMoreSaid(source: Self.host, account: .failed, servers: .failed, weeks: .failed),
            SourceMoreSaid(
                source: Self.host, account: .said(HostAccount(paragraphs: [])), servers: .said(HostServers(counted: 0, names: [])),
                weeks: .said([])
            ),
            SourceMoreSaid(source: Self.host, account: nil, servers: .said(many), weeks: nil, asking: true),
        ]
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (460, .dark), (390, .light), (320, .dark)] {
            for said in states {
                let folded = size(said, width, scheme: scheme)
                #expect(folded.width == width && folded.height > 0, "at \(width)")
                let open = size(said, width, scheme: scheme, unfolded: Set(SourceMoreSaid.Part.allCases))
                #expect(open.width == width && open.height >= folded.height, "unfolded at \(width)")
            }
            #expect(size(full, width, unfolded: [.servers]).height > size(full, width).height)
            #expect(size(full, width, unfolded: [.activity]).height > size(full, width).height)
            #expect(size(full, width, unfolded: [.account]).height > size(full, width).height)
            // Asked and found with none of the three: the heading, a sentence saying so, and the press.
            let bareHead = size(SourceMoreSaid(source: Self.host, account: .waiting, servers: nil, weeks: nil), width).height
            #expect(size(SourceMoreSaid(source: Self.host, account: nil, servers: nil, weeks: nil), width).height > bareHead)
            #expect(size(SourceMoreSaid(source: Self.host, servers: .tooLarge), width).height > size(SourceMoreSaid(source: Self.host, servers: nil), width).height)
        }
        // A hundred names are drawn, however many are held.
        #expect(size(full, 460, unfolded: [.servers]).height < size(full, 460).height + 110 * 40)
    }
}
