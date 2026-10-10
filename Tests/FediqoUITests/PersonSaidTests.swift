import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A source that answers by path and query, with a `Link` header where it is given one, and
/// remembers what it was asked and as whom. **An ask it holds waits until it is let go**, and
/// says when it arrived — the seam a test waits on, in place of a clock.
///
/// **And every wait here ends by itself.** No check waits on the clock: each waits on an ask
/// arriving or being let go. But a wait for something that never comes — the code under test
/// broken so that an ask is never made, or never answered — must fail the check and not park
/// the run, so a held ask is let go, and a wait for an arrival given up, after `patience`.
private actor PageServer: HTTPClient, HTTPSender {
    struct Answer: Sendable {
        var body: String
        var link: String?
        var status = 200
        /// Answered as a request the asker walked away from.
        var cancelled = false
    }

    private var routes: [String: Answer]
    private(set) var asked: [String] = []
    private(set) var bearers: [String] = []
    private var held: Set<String> = []
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var arrivals: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var arrived: [String: Int] = [:]
    private var gaveUp: Set<String> = []
    /// How long a held ask is held, and an arrival waited for, before the seam ends by itself.
    static let patience: Duration = .seconds(15)

    init(_ routes: [String: Answer]) {
        self.routes = routes
    }

    func answer(_ ask: String, _ answer: Answer?) {
        routes[ask] = answer
    }

    /// Every later ask of `ask` waits until `release`.
    func hold(_ ask: String) {
        held.insert(ask)
        Task {
            try? await Task.sleep(for: Self.patience)
            self.release(ask)
        }
    }

    /// Lets the ask of `ask` that has waited longest go, and goes on holding the rest.
    func releaseOne(_ ask: String) {
        guard var waiting = gates[ask], !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
        gates[ask] = waiting
    }

    /// Lets every held ask of `ask` go, and holds no more.
    func release(_ ask: String) {
        held.remove(ask)
        for gate in gates.removeValue(forKey: ask) ?? [] { gate.resume() }
    }

    /// Returns once `ask` has arrived `times` times.
    func arrival(of ask: String, times: Int = 1) async {
        guard arrived[ask, default: 0] < times, !gaveUp.contains(ask) else { return }
        Task {
            try? await Task.sleep(for: Self.patience)
            self.giveUp(on: ask)
        }
        await withCheckedContinuation { arrivals[ask, default: []].append($0) }
        await arrival(of: ask, times: times)
    }

    /// An arrival that never came: whoever waits on it goes on, and the check they are in fails
    /// on what it then finds.
    private func giveUp(on ask: String) {
        guard !(arrivals[ask] ?? []).isEmpty else { return }
        gaveUp.insert(ask)
        for waiting in arrivals.removeValue(forKey: ask) ?? [] { waiting.resume() }
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let ask = url.path + (url.query.map { "?\($0)" } ?? "")
        asked.append(ask)
        bearers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        arrived[ask, default: 0] += 1
        for waiting in arrivals.removeValue(forKey: ask) ?? [] { waiting.resume() }
        if held.contains(ask) { await withCheckedContinuation { gates[ask, default: []].append($0) } }
        guard let answer = routes[ask] else { throw URLError(.notConnectedToInternet) }
        if answer.cancelled { throw URLError(.cancelled) }
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.link.map { ["Link": $0] }
        )!
        return (Data(answer.body.utf8), response)
    }
}

/// #310, the page: what a person's page is handed, what is asked for it and when, and what it
/// says in each state — and that the page of somebody whose source is not asked who people are
/// is the page it was.
@MainActor
@Suite("Somebody's page as their source says it", .serialized, .timeLimit(.minutes(1)))
struct PersonSaidTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let ada = someone("Ada", "@ada@m.example", at: source)

    /// Somebody as a row of theirs names them: the one way a person is made.
    private static func someone(_ name: String, _ handle: String?, at source: Source) -> DummyPerson {
        DummyPerson(making: Note(
            id: "https://\(source.host)/\(name)/1", source: source, author: name, handle: handle ?? "", body: "",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []
        ))!
    }
    private static let lookup = "/api/v1/accounts/lookup?acct=ada"
    private static let statuses = "/api/v1/accounts/42/statuses"

    private static func account(_ more: String = "") -> String {
        #"""
        {"id":"42","acct":"ada","display_name":"Ada","note":"<p>Counts things</p>","followers_count":8,
         "following_count":4,"statuses_count":10,"fields":[{"name":"Site","value":"example.org","verified_at":"2026-10-01T00:00:00.000Z"}]\#(more)}
        """#
    }

    private static func status(_ id: Int) -> String {
        #"""
        {"id":"\#(id)","uri":"https://m.example/users/ada/statuses/\#(id)","created_at":"2026-10-0\#(id % 9 + 1)T00:00:00.000Z",
         "content":"<p>post \#(id)</p>","visibility":"public","account":{"acct":"ada","display_name":"Ada"}}
        """#
    }

    private static func stretch(_ ids: [Int], next: Int? = nil) -> PageServer.Answer {
        PageServer.Answer(
            body: "[" + ids.map(status).joined(separator: ",") + "]",
            link: next.map { #"<https://m.example\#(statuses)?max_id=\#($0)>; rel="next""# }
        )
    }

    private static func served(_ more: [String: PageServer.Answer] = [:]) -> [String: PageServer.Answer] {
        [lookup: PageServer.Answer(body: account()), statuses: stretch([9, 8, 7], next: 7)].merging(more) { $1 }
    }

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

    // MARK: - What is asked, and when

    @Test("Opening somebody's page asks their source who they are and for their newest posts — two asks, listed in the run's record as that, and nothing held — and the page is handed what it said: the person, their posts newest first, and that older ones can be read")
    func openingAsksTwice() async throws {
        let (session, server, work) = await session(Self.served())
        let pages = ShellPersonPages()
        #expect(pages.said(of: Self.ada, in: session) == PersonSaid(source: Self.host, reading: .asking), "before anything answered")

        await pages.opened(Self.ada, in: session)
        #expect(await server.asked == [Self.lookup, Self.statuses])
        let acts = work.record.filter { $0.reached == Self.host }
        #expect(acts.count == 2 && acts.allSatisfy { $0.purpose == .person && $0.source == Self.host })

        let said = try #require(pages.said(of: Self.ada, in: session))
        #expect(said.person?.accountID == "42" && said.person?.tally.followers == 8)
        #expect(said.posts?.map(\.statusID) == ["9", "8", "7"] && said.foot == .more && !said.askingPosts)
        #expect(pages.walked(of: Self.ada, in: session) == said.posts && pages.canAskAgain(Self.ada, in: session))
        #expect(session.notes.isEmpty, "a post read for a page is no item")
        #expect(await session.store.held(host: Self.host).isEmpty)

        // Opened again this run, it is drawn from what was answered: nobody is asked.
        await pages.opened(Self.ada, in: session)
        #expect(await server.asked.count == 2)
    }

    @Test("Older posts are read only when the foot is pressed, a stretch a press, to the end the source names: nothing twice, and then the foot says it has sent all it gives")
    func readingOnIsPressed() async throws {
        let (session, server, _) = await session(Self.served([
            "\(Self.statuses)?max_id=7": Self.stretch([7, 6, 5], next: 5), "\(Self.statuses)?max_id=5": Self.stretch([4]),
        ]))
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        await pages.readOn(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.posts?.map(\.statusID) == ["9", "8", "7", "6", "5"])
        #expect(pages.said(of: Self.ada, in: session)?.foot == .more)
        await pages.readOn(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.posts?.map(\.statusID) == ["9", "8", "7", "6", "5", "4"])
        #expect(pages.said(of: Self.ada, in: session)?.foot == .end)
        await pages.readOn(Self.ada, in: session)
        #expect(await server.asked.count == 4, "nothing is asked past the end")

        // A stretch that does not come is said at the foot, changes nothing drawn, and a press asks again.
        let (other, flaky, _) = await self.session(Self.served())
        let again = ShellPersonPages()
        await again.opened(Self.ada, in: other)
        await again.readOn(Self.ada, in: other)
        #expect(again.said(of: Self.ada, in: other)?.foot == .failed)
        #expect(again.said(of: Self.ada, in: other)?.posts?.count == 3)
        await flaky.answer("\(Self.statuses)?max_id=7", Self.stretch([6]))
        await again.readOn(Self.ada, in: other)
        #expect(again.said(of: Self.ada, in: other)?.posts?.map(\.statusID) == ["9", "8", "7", "6"])
        #expect(again.said(of: Self.ada, in: other)?.foot == .end)
    }

    @Test("A source that has not heard of them says so and is asked nothing more; one that fails says it failed, keeps what it said before, and is asked again by the press — and reading the newest again puts what is newer on top")
    func unheardOfFailedAndAgain() async throws {
        let (session, server, _) = await session([Self.lookup: PageServer.Answer(body: #"{"error":"Record not found"}"#, status: 404)])
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session) == PersonSaid(source: Self.host, reading: .unheardOf))
        #expect(await server.asked == [Self.lookup], "their posts are not asked of a source that knows nobody")
        #expect(pages.walked(of: Self.ada, in: session) == session.heldPosts(of: Self.ada), "the keys walk what this device holds")

        await server.answer(Self.lookup, nil)
        await pages.again(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session) == PersonSaid(source: Self.host, reading: .failed))

        await server.answer(Self.lookup, PageServer.Answer(body: Self.account()))
        await server.answer(Self.statuses, Self.stretch([9, 8]))
        await pages.again(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.posts?.map(\.statusID) == ["9", "8"])
        // Their posts fail while who they are answers: the person stands, and the foot says so.
        await server.answer(Self.statuses, nil)
        await pages.again(Self.ada, in: session)
        let said = try #require(pages.said(of: Self.ada, in: session))
        #expect(said.person != nil && said.posts?.count == 2 && said.foot == .failed && said.again == nil)
        // Newer posts, reaching what is held: on top, and nothing twice.
        await server.answer(Self.statuses, Self.stretch([11, 10, 9]))
        await pages.again(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.posts?.map(\.statusID) == ["11", "10", "9", "8"])
        #expect(session.notes.isEmpty)
    }

    @Test("Once a source has said who somebody is, asking again and failing — or being told it no longer knows them — keeps what it said and says the trouble in a line of its own, never that what is below is only what this device holds; asking again and being answered takes the line away")
    func troubleAfterAnAnswer() async throws {
        let en = DummyLanguage.english
        let (session, server, _) = await session(Self.served())
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        for (answer, trouble, words) in [
            (nil, PersonSaid.Trouble.failed, "Could not ask m.example again. What it said before is still here."),
            (PageServer.Answer(body: "{}", status: 404), .unheardOf, "m.example no longer knows them. What it said before is still here."),
        ] as [(PageServer.Answer?, PersonSaid.Trouble, String)] {
            await server.answer(Self.lookup, answer)
            await pages.again(Self.ada, in: session)
            let said = try #require(pages.said(of: Self.ada, in: session))
            #expect(said.person?.accountID == "42" && said.again == trouble && said.posts?.count == 3 && said.foot == .more)
            #expect(said.stateLine(of: "@ada@m.example", language: en) == words && said.offersAgain)
            #expect(PersonPane.emptyLine(said, held: 0, language: en) == nil)
        }
        await server.answer(Self.lookup, PageServer.Answer(body: Self.account()))
        await pages.again(Self.ada, in: session)
        let said = try #require(pages.said(of: Self.ada, in: session))
        #expect(said.again == nil && said.stateLine(of: "@ada@m.example") == nil && !said.offersAgain)
    }

    // MARK: - What happens while an ask is on the wire

    @Test("An ask is the pages' and not the pane's: the pane that opened a page leaving does not stop it, it lands for the next visit, and opening again while it is on the wire waits on it and asks nothing more")
    func theAskOutlivesThePane() async throws {
        let (session, server, _) = await session(Self.served())
        let pages = ShellPersonPages()
        await server.hold(Self.lookup)
        let pane = Task { await pages.opened(Self.ada, in: session) }
        await server.arrival(of: Self.lookup)
        pane.cancel()
        #expect(pages.said(of: Self.ada, in: session)?.reading == .asking)

        // The next visit, while the first ask is still out: it waits on that ask.
        let again = Task { await pages.opened(Self.ada, in: session) }
        await server.release(Self.lookup)
        await again.value
        let said = try #require(pages.said(of: Self.ada, in: session))
        #expect(said.person?.accountID == "42" && said.posts?.count == 3 && !said.askingPosts)
        #expect(await server.asked == [Self.lookup, Self.statuses], "asked once, whoever came and went")
        await pane.value
    }

    @Test("An ask that was stopped before it came to anything leaves a page that is asked again when it is opened — stopped before either answer, or between who they are and their posts — and never one that says Asking for the rest of the run")
    func aStoppedAskIsAskedAgain() async throws {
        let stopped = PageServer.Answer(body: "", cancelled: true)
        let (session, server, _) = await session(Self.served([Self.lookup: stopped]))
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session) == PersonSaid(source: Self.host, reading: .asking), "nothing is said of an ask that was stopped")

        // Between the two: who they are stands, and their posts were never answered.
        await server.answer(Self.lookup, PageServer.Answer(body: Self.account()))
        await server.answer(Self.statuses, stopped)
        await pages.opened(Self.ada, in: session)
        let between = try #require(pages.said(of: Self.ada, in: session))
        #expect(between.person != nil && between.posts == nil && !between.askingPosts && between.foot == nil)

        await server.answer(Self.statuses, Self.stretch([9, 8, 7]))
        await pages.opened(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.posts?.count == 3)
        #expect(await server.asked == [Self.lookup, Self.lookup, Self.statuses, Self.lookup, Self.statuses])
        // Settled now: opened again, nobody is asked.
        await pages.opened(Self.ada, in: session)
        #expect(await server.asked.count == 5)
    }

    @Test("Asking again while an ask is on the wire asks nothing, however often it is pressed; and asking again while older posts are being read takes the foot off Reading — the older stretch, answered late, does not land")
    func pressedWhileOnTheWire() async throws {
        let (session, server, _) = await session(Self.served(["\(Self.statuses)?max_id=7": Self.stretch([6, 5], next: 5)]))
        let pages = ShellPersonPages()
        await server.hold(Self.lookup)
        let opening = Task { await pages.opened(Self.ada, in: session) }
        await server.arrival(of: Self.lookup)
        for _ in 0..<3 { await pages.again(Self.ada, in: session) }
        await pages.readOn(Self.ada, in: session)
        #expect(await server.asked == [Self.lookup], "one ask on the wire, and nothing beside it")
        await server.release(Self.lookup)
        await opening.value
        #expect(await server.asked == [Self.lookup, Self.statuses])

        // Older posts are not asked for while the page is being asked again.
        await server.hold(Self.lookup)
        let asking = Task { await pages.again(Self.ada, in: session) }
        await server.arrival(of: Self.lookup, times: 2)
        await pages.readOn(Self.ada, in: session)
        #expect(await server.asked == [Self.lookup, Self.statuses, Self.lookup])
        await server.release(Self.lookup)
        await asking.value
        #expect(await server.asked.count == 4)

        // `r` during a reading-on.
        let older = "\(Self.statuses)?max_id=7"
        await server.hold(older)
        let reading = Task { await pages.readOn(Self.ada, in: session) }
        await server.arrival(of: older)
        #expect(pages.said(of: Self.ada, in: session)?.foot == .reading)
        await pages.readOn(Self.ada, in: session)
        #expect(await server.asked.count == 5, "one stretch at a time")
        await pages.again(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.foot == .more, "the foot is no longer Reading")
        await server.release(older)
        await reading.value
        let said = try #require(pages.said(of: Self.ada, in: session))
        #expect(said.posts?.map(\.statusID) == ["9", "8", "7"] && said.foot == .more, "the late stretch did not land")
        // And the foot reads on as it did.
        await pages.readOn(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.posts?.map(\.statusID) == ["9", "8", "7", "6", "5"])
    }

    @Test("A page is what the source gave whoever asked: read with no sign-in it is not there for a reader who has since signed in, nor a signed-in reader's for somebody signed out or another reader — each is asked afresh, as themself, and an answer to the one before, come late, lands nowhere and asks nothing more")
    func asWhoeverAsked() async throws {
        let (session, server, _) = await session(Self.served([
            "/api/v1/accounts/verify_credentials": PageServer.Answer(body: #"{"id":"1","acct":"me"}"#),
        ]))
        let pages = ShellPersonPages()
        #expect(ShellPersonPages.askedAs(at: Self.host, in: session) == .nobody)

        // Nobody asks who they are, and the answer is slow.
        await server.hold(Self.lookup)
        let unsigned = Task { await pages.opened(Self.ada, in: session) }
        await server.arrival(of: Self.lookup)

        // The reader signs in meanwhile: nobody's page is not theirs, and theirs is asked as them.
        let token = MastodonToken(host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s")
        try session.mastodon.tokens.save(token)
        session.mastodon.refresh()
        #expect(ShellPersonPages.askedAs(at: Self.host, in: session) == .reader(nil))
        let signed = Task { await pages.opened(Self.ada, in: session) }
        await server.arrival(of: Self.lookup, times: 2)
        // Nobody's answer comes late: it lands nowhere, and their posts are not asked for it.
        await server.releaseOne(Self.lookup)
        await unsigned.value
        #expect(await server.asked == [Self.lookup, Self.lookup])
        #expect(pages.said(of: Self.ada, in: session) == PersonSaid(source: Self.host, reading: .asking, askingPosts: true))
        await server.release(Self.lookup)
        await signed.value
        #expect(await server.bearers == ["", "Bearer tok", "Bearer tok"])
        #expect(pages.said(of: Self.ada, in: session)?.posts?.map(\.statusID) == ["9", "8", "7"])

        // Who they are there becomes known: the page asked a moment before is the same reader's,
        // stays drawn, and is not asked again — on screen, nothing would ask it.
        let settled = await server.asked.count
        await session.mastodon.learnWho(host: Self.host)
        #expect(ShellPersonPages.askedAs(at: Self.host, in: session) == .reader("@me@m.example"))
        #expect(pages.said(of: Self.ada, in: session)?.posts?.count == 3 && pages.said(of: Self.ada, in: session)?.person != nil)
        await pages.opened(Self.ada, in: session)
        #expect(await server.asked.filter { $0 != "/api/v1/accounts/verify_credentials" }.count == settled)
        // Named now, it is that reader's and no other's.
        await server.answer("/api/v1/accounts/verify_credentials", PageServer.Answer(body: #"{"id":"2","acct":"you"}"#))
        await session.mastodon.learnWho(host: Self.host)
        #expect(ShellPersonPages.askedAs(at: Self.host, in: session) == .reader("@you@m.example"))
        #expect(pages.said(of: Self.ada, in: session) == PersonSaid(source: Self.host, reading: .asking))
        await pages.opened(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.posts?.count == 3)
        #expect(ShellPersonPages.AskedAs.reader(nil).isTheSame(as: .reader("a")) && !ShellPersonPages.AskedAs.reader("a").isTheSame(as: .reader("b")))
        #expect(!ShellPersonPages.AskedAs.nobody.isTheSame(as: .reader(nil)) && !ShellPersonPages.AskedAs.reader(nil).isTheSame(as: .nobody))

        // The reader asks again, and signs out while their posts are on the wire.
        await server.answer(Self.statuses, Self.stretch([12, 9]))
        await server.hold(Self.statuses)
        let asked = await server.asked.filter { $0 == Self.statuses }.count
        let reader = Task { await pages.again(Self.ada, in: session) }
        await server.arrival(of: Self.statuses, times: asked + 1)
        _ = try session.mastodon.tokens.forget(token)
        session.mastodon.refresh()
        #expect(pages.said(of: Self.ada, in: session) == PersonSaid(source: Self.host, reading: .asking), "the reader's page is not nobody's")
        await pages.readOn(Self.ada, in: session)
        let nobody = Task { await pages.opened(Self.ada, in: session) }
        await server.arrival(of: Self.statuses, times: asked + 2)
        // The reader's posts come late — and are not shown to nobody.
        await server.releaseOne(Self.statuses)
        await reader.value
        #expect(pages.said(of: Self.ada, in: session)?.posts == nil)
        await server.answer(Self.statuses, Self.stretch([9, 8, 7]))
        await server.release(Self.statuses)
        await nobody.value
        #expect(pages.said(of: Self.ada, in: session)?.posts?.map(\.statusID) == ["9", "8", "7"])
        #expect(await server.bearers.suffix(2) == ["", ""])
    }

    @Test("A sign-out the signed-in door confirmed is told to the session only where whoever asks now is still who the ask was made as: an answer come late, after that reader has gone, ends nobody's sign-in")
    func aLateSignOutEndsNobodyElse() async throws {
        let refused = PageServer.Answer(body: #"{"error":"The access token was revoked"}"#, status: 401)
        let token = MastodonToken(host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s")
        for gone in [false, true] {
            let (session, server, _) = await session([Self.lookup: refused, "/api/v1/accounts/verify_credentials": refused])
            try session.mastodon.tokens.save(token)
            session.mastodon.refresh()
            let pages = ShellPersonPages()
            await server.hold(Self.lookup)
            let asking = Task { await pages.opened(Self.ada, in: session) }
            await server.arrival(of: Self.lookup)
            if gone {
                // The reader signs out while the ask is out; the same token is then kept again
                // by another road, which this session has not looked at.
                _ = try session.mastodon.tokens.forget(token)
                session.mastodon.refresh()
                try session.mastodon.tokens.save(token)
                #expect(ShellPersonPages.askedAs(at: Self.host, in: session) == .nobody)
            }
            await server.release(Self.lookup)
            await asking.value
            #expect(try session.mastodon.tokens.token(host: Self.host) == nil, "the door's own check took the token")
            #expect(session.mastodon.ended == (gone ? [] : [Self.host]), "gone: \(gone)")
        }
    }

    @Test("A source that stops handing its posts on in order ends the list there, with its own sentence and no press: it is not asked again by the foot")
    func aSourceNotPaging() async throws {
        let ring = PageServer.Answer(body: "[" + Self.status(6) + "]", link: #"<https://m.example/x?max_id=7>; rel="next""#)
        let (session, server, _) = await session(Self.served(["\(Self.statuses)?max_id=7": ring]))
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        await pages.readOn(Self.ada, in: session)
        let said = try #require(pages.said(of: Self.ada, in: session))
        #expect(said.foot == .stopped && said.posts?.count == 3)
        #expect(!PersonSaid.Foot.stopped.presses)
        #expect(PersonSaid.Foot.stopped.words("m.example", language: .english) == "m.example stopped handing older posts on in order. The list ends here.")
        await pages.readOn(Self.ada, in: session)
        #expect(await server.asked.count == 3)
        // Asked again from the top, the page reads on again.
        await server.answer("\(Self.statuses)?max_id=7", Self.stretch([6]))
        await pages.again(Self.ada, in: session)
        await pages.readOn(Self.ada, in: session)
        #expect(pages.said(of: Self.ada, in: session)?.foot == .end)
    }

    @Test("A post on the page becomes an item when it is opened, and not before: it is then held, and its row is drawn from what is held; and one the store will not take is said so, and nothing is done with it")
    func aPostIsHeldWhenOpened() async throws {
        let (session, _, _) = await session(Self.served())
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        let rows = try #require(pages.said(of: Self.ada, in: session)?.posts)
        let row = rows[1].id
        #expect(pages.isOnlyOnPage(row, of: Self.ada, in: session) && session.held(row) == nil)

        #expect(await pages.holding(row, of: Self.ada, in: session)?.id == row)
        #expect(session.notes.map(\.statusID) == ["8"] && !pages.isOnlyOnPage(row, of: Self.ada, in: session))
        #expect(pages.isOnlyOnPage(rows[0].id, of: Self.ada, in: session) && session.toast == nil)

        // The held copy is what the row is: a mark the store holds shows on the page.
        #expect(await session.store.setKept(true, for: try #require(session.heldNote(row)).key))
        await session.reloadFromStore()
        let drawn = try #require(pages.said(of: Self.ada, in: session)?.posts)
        #expect(drawn.map(\.statusID) == ["9", "8", "7"] && drawn[1].kept && !drawn[0].kept)
        #expect(pages.walked(of: Self.ada, in: session) == drawn)

        // The store will not take it — here, its source is gone from it: the person is told.
        _ = await session.store.remove(host: Self.host)
        #expect(await pages.holding(rows[0].id, of: Self.ada, in: session) == nil)
        #expect(session.toast?.text == L10n.t("person.unheld"))
    }

    @Test("A mark pressed on a post that is on the page only holds the post and then acts on what is held — the act the press named, once — where a held post's mark acts at once; taking back is not offered until it is held")
    func aMarkHoldsThenActs() async throws {
        let (session, _, _) = await session(Self.served())
        let pages = ShellPersonPages()
        await pages.opened(Self.ada, in: session)
        let rows = try #require(pages.said(of: Self.ada, in: session)?.posts)
        let (pressed, presses) = AsyncStream<String>.makeStream()
        func held(_ item: DummyItem) -> ItemActing {
            let isHeld = session.held(item.id) != nil
            return ItemActing(
                acts: .none, perform: { presses.yield("\($0) \(item.statusID ?? "") held:\(isHeld)") },
                keep: { presses.yield("keep \(item.statusID ?? "") held:\(isHeld)") },
                ask: { presses.yield("ask \($0) \(item.statusID ?? "") held:\(isHeld)") },
                withdraw: ItemActing.Withdraw(asks: { ShellQuestion.withdraw(item) }, yes: {})
            )
        }
        var heard = pressed.makeAsyncIterator()
        let onPage = pages.acting(rows[0], of: Self.ada, in: session, held: held)
        #expect(onPage.withdraw == nil && session.notes.isEmpty)
        onPage.perform?(.favourite)
        #expect(await heard.next() == "favourite 9 held:true")
        #expect(session.notes.map(\.statusID) == ["9"], "held by the press")

        pages.acting(rows[1], of: Self.ada, in: session, held: held).keep?()
        #expect(await heard.next() == "keep 8 held:true")
        pages.acting(rows[2], of: Self.ada, in: session, held: held).ask?(.bookmark)
        #expect(await heard.next() == "ask bookmark 7 held:true")

        // Held now, its marks are the held post's own.
        let now = try #require(pages.said(of: Self.ada, in: session)?.posts)
        let own = pages.acting(now[0], of: Self.ada, in: session, held: held)
        #expect(own.withdraw != nil)
        own.perform?(.boost)
        #expect(await heard.next() == "boost 9 held:true")
    }

    // MARK: - A source that is not asked who people are

    @Test("A forum's author is asked of nobody: their page is handed nothing, opening it asks nothing, the keys walk what this device holds — and the page handed nothing says what it always said")
    func aForumAuthorIsAsIs() async throws {
        let (session, server, work) = await session(Self.served())
        let pages = ShellPersonPages()
        let author = Self.someone("bob", nil, at: Self.forum)
        for who in [author, Self.someone("bob", "@bob@forum.example", at: Self.forum),
                    Self.someone("x", "@x@gone.example", at: Source(host: "gone.example", kind: .mastodon)),
                    Self.someone("no handle", nil, at: Self.source)] {
            #expect(pages.said(of: who, in: session) == nil)
            await pages.opened(who, in: session)
            await pages.again(who, in: session)
            await pages.readOn(who, in: session)
            #expect(pages.walked(of: who, in: session) == session.heldPosts(of: who) && !pages.canAskAgain(who, in: session))
        }
        #expect(await server.asked.isEmpty && work.record.isEmpty)

        for language in [DummyLanguage.english, .taiwanese] {
            let through = String(format: L10n.t("person.through", language: language), author.host)
            #expect(PersonPane.viewLine(of: author, said: nil, language: language) == through)
        }
        #expect(PersonPane.viewLine(of: author, said: nil) == String(format: L10n.t("person.through"), "forum.example"))
        #expect(PersonPane.heldLine(3, said: nil) == PersonPane.heldLine(3) && PersonPane.heldLine(3) == L10n.count("person.held", 3))
        #expect(PersonPane.heldLine(3, said: PersonSaid(source: Self.host, reading: .asking)) == nil)
    }

    @Test("The page decides by what it is handed and by no check of which kind of source it is: its file names no kind of source")
    func thePageNamesNoKind() throws {
        for file in ["PersonPane.swift", "PersonSaid.swift"] {
            let text = try String(contentsOf: Self.shell.appending(path: file), encoding: .utf8)
            for word in ["ProtocolKind", ".kind", "isForum", ".mastodon", ".discuz", ".discourse", "offers."] {
                #expect(!text.contains(word), "\(file) names \(word)")
            }
        }
        // The one fact is read where the page is handed its word, and nowhere a kind is.
        let asked = try String(contentsOf: Self.shell.appending(path: "ShellPerson.swift"), encoding: .utf8)
        #expect(asked.contains("source.kind.offers.people") && !asked.contains("ProtocolKind") && !asked.contains("kind =="))
    }

    private static var shell: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI/Shell")
    }

    // MARK: - What the page says

    private func person(_ more: String) throws -> Person {
        try MastodonPeople.person(from: Data(Self.account(more).utf8), source: Self.source)
    }

    @Test("Whose view the page is is said by the source's name, and where they live elsewhere by their home exactly as it is held — the one spelling a host has, never turned back into a stranger's letters; with no home, the source alone")
    func whoseView() throws {
        let en = DummyLanguage.english
        #expect(PersonSaid.whoseView("m.example", person: nil, language: en) == "As m.example says.")
        #expect(PersonSaid.whoseView("m.example", person: try person(""), language: en) == "As m.example says.")
        let far = try MastodonPeople.person(from: Data(#"{"id":"1","acct":"a@bücher.example"}"#.utf8), source: Self.source)
        #expect(far.home == "xn--bcher-kva.example")
        #expect(PersonSaid.whoseView("m.example", person: far, language: en) == "As m.example says. They live on xn--bcher-kva.example.")
        let turned = try MastodonPeople.person(from: Data(#"{"id":"1","acct":"a@‮moc.elgoog"}"#.utf8), source: Self.source)
        #expect(PersonSaid.whoseView("m.example", person: turned, language: en) == "As m.example says.")
        let said = PersonSaid(source: "m.example", reading: .said(far))
        #expect(PersonPane.viewLine(of: Self.ada, said: said, language: en).hasSuffix("xn--bcher-kva.example."))
    }

    @Test("A suspended, moved, limited, locked, automated or group account each has its line, as has somebody the source knows only part of; an ordinary person living here has none")
    func theLinesAnAccountEarns() throws {
        let en = DummyLanguage.english
        #expect(PersonSaid.lines(of: try person(""), source: Self.host, language: en).isEmpty)
        let every = try person(#","suspended":true,"limited":true,"locked":true,"bot":true,"moved":{"id":"7","acct":"ada@new.example"}"#)
        #expect(PersonSaid.lines(of: every, source: Self.host, language: en).map(\.words) == [
            "m.example says this account is suspended.", "They moved to @ada@new.example.", "m.example limits this account.",
            "An automated account.",
        ])
        // The lock is the heading's, after the name the source gave, and said in words there.
        #expect(every.locked && PersonSaid.locked(language: en) == "Asks before anyone may follow")
        let far = try MastodonPeople.person(from: Data(#"{"id":"1","acct":"a@far.example","group":true}"#.utf8), source: Self.source)
        #expect(PersonSaid.lines(of: far, source: Self.host, language: en).map(\.words) == [
            "A group account.", "m.example knows only part of someone who lives elsewhere.",
        ])
        let lines = PersonSaid.lines(of: every, source: Self.host) + PersonSaid.lines(of: far, source: Self.host)
        #expect(Set(lines.map(\.symbol)).count == 6, "each line its own mark")
    }

    @Test("The counts are the source's figures, each one it said and none it did not; and where it gave no posts the page says the source gave none — beside a count that is not nothing it says so — and never that there are none, nor why")
    func countsAndNothingGiven() throws {
        let en = DummyLanguage.english
        #expect(PersonSaid.counts(of: Person.Tally(posts: 1204, following: 310, followers: 1), language: en) == ["1,204 posts", "Follows 310", "1 follower"])
        // A figure past what thirty-two bits hold is said whole.
        #expect(PersonSaid.counts(of: Person.Tally(followers: 3_000_000_000), language: en) == ["3,000,000,000 followers"])
        #expect(PersonSaid.counts(of: Person.Tally(posts: 1204), language: .taiwanese) == ["1,204 則貼文"])
        #expect(PersonSaid.gaveNone("m.example", counted: 1, language: en) == "m.example counts 1 post of theirs and did not give it here.")
        #expect(PersonSaid.gaveNone("m.example", counted: 1204, language: en) == "m.example counts 1,204 posts of theirs and gave none of them here.")
        #expect(PersonSaid.counts(of: Person.Tally(posts: 1, followers: nil), language: en) == ["1 post"])
        #expect(PersonSaid.counts(of: Person.Tally(), language: en).isEmpty)

        #expect(PersonSaid.gaveNone("m.example", counted: 10, language: en) == "m.example counts 10 posts of theirs and gave none of them here.")
        for counted in [nil, 0] as [Int?] {
            #expect(PersonSaid.gaveNone("m.example", counted: counted, language: en) == "m.example gave no posts of theirs.")
        }
        var said = PersonSaid(source: Self.host, reading: .said(try person("")), posts: [])
        #expect(PersonPane.emptyLine(said, held: 5, language: en) == "m.example counts 10 posts of theirs and gave none of them here.")
        said.foot = .failed
        #expect(PersonPane.emptyLine(said, held: 0, language: en) == nil, "a stretch that did not come is the foot's to say")
        said = PersonSaid(source: Self.host, reading: .said(try person(#","suspended":true"#)), posts: [])
        #expect(PersonPane.emptyLine(said, held: 0, language: en) == nil, "its line has said so")
        #expect(PersonPane.emptyLine(PersonSaid(source: Self.host, reading: .asking), held: 0, language: en) == nil)
        for reading in [PersonSaid.Reading.unheardOf, .failed] {
            let none = PersonSaid(source: Self.host, reading: reading)
            #expect(PersonPane.emptyLine(none, held: 0, language: en) == L10n.t("person.none", language: en))
            #expect(PersonPane.emptyLine(none, held: 2, language: en) == nil)
        }
    }

    @Test("Each state of the asking has its sentence, about the source by name: asking, not heard of — which is no failure — and failed; and each foot its own, with a press only where a press reads")
    func theStatesSaid() {
        let en = DummyLanguage.english
        func line(_ reading: PersonSaid.Reading) -> String? {
            PersonSaid(source: "m.example", reading: reading).stateLine(of: "@ada@m.example", language: en)
        }
        #expect(line(.asking) == "Asking m.example for @ada@m.example…")
        #expect(line(.unheardOf) == "m.example has not heard of them. What this device holds of theirs is below.")
        #expect(line(.failed) == "Could not ask m.example for @ada@m.example. What this device holds of theirs is below.")
        #expect(line(.said(Person(source: Self.source, accountID: "1", handle: "@a@m.example", name: "a"))) == nil)
        // The name asked for is a stranger's word, and is made fit for the sentence it is set in.
        let turned = PersonSaid(source: "m.example", reading: .failed).stateLine(of: "@a\u{202E}da\nx@m.example", language: en)
        #expect(turned == "Could not ask m.example for @ada x@m.example. What this device holds of theirs is below.")
        let long = PersonSaid(source: "m.example", reading: .asking).stateLine(of: String(repeating: "a", count: 5_000), language: en) ?? ""
        #expect(long.count < 200)
        #expect(PersonSaid(source: "m.example", reading: .failed).offersAgain && !PersonSaid(source: "m.example", reading: .unheardOf).offersAgain)

        #expect(PersonSaid.Foot.more.words("m.example", language: en) == "Older posts can be read. Press here to read them.")
        #expect(PersonSaid.Foot.end.words("m.example", language: en) == "No older posts: m.example has sent all it gives.")
        #expect(PersonSaid.Foot.failed.words("m.example", language: en).hasPrefix("Could not read older posts from m.example."))
        let feet = [PersonSaid.Foot.more, .reading, .end, .failed, .stopped]
        #expect(feet.map(\.presses) == [true, false, false, true, false] && Set(feet.map(\.symbol)).count == 5)
    }

    @Test("Every sentence of the page is written in each language the app speaks, with the places it fills")
    func writtenInEveryLanguage() {
        let keys = [
            "work.purpose.person", "person.said.by", "person.said.elsewhere", "person.asking", "person.unheardOf",
            "person.failed", "person.retry", "person.line.suspended", "person.line.moved", "person.line.limited",
            "person.line.locked", "person.line.automated", "person.line.group", "person.line.partial",
            "person.count.posts", "person.count.following", "person.count.followers", "person.posts.none",
            "person.posts.noneOf", "person.field.checked", "person.foot.more", "person.foot.reading", "person.foot.end",
            "person.foot.failed", "person.foot.stopped", "person.again.failed", "person.again.unheardOf", "person.unheld",
        ]
        func places(_ text: String) -> [String] {
            text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted()
        }
        // No figure is written through `%d`: a count is said whole, grouped, as its own words.
        for key in keys { #expect(!L10n.t(key, language: .english).contains("%d") && !L10n.t(key, language: .english).contains("$d"), "\(key)") }
        for key in keys {
            let english = L10n.t(key, language: .english)
            #expect(english != key, "\(key) is not written")
            for language in DummyLanguage.allCases {
                let written = L10n.t(key, language: language)
                #expect(written != key && places(written) == places(english), "\(key) in \(language)")
            }
        }
        #expect(SourceWork.Purpose.person.isOfTheSource)
    }

    @Test("Once the source has said who somebody is, the heading is its word and not the row's: the name and the handle the answer carried, made fit for a line, its pictures and its face — so an answer about somebody else shows as somebody else; until then, and on a page handed nothing, the row's")
    func theHeadingIsTheSourcesWord() throws {
        let row = PersonPane.named(Self.ada, said: nil)
        #expect(row.name == "Ada" && row.handle == "@ada@m.example")
        #expect(PersonPane.named(Self.ada, said: PersonSaid(source: Self.host, reading: .asking)).name == "Ada")
        #expect(PersonPane.face(of: Self.ada, said: PersonSaid(source: Self.host, reading: .failed)) == Self.ada.avatarURL)

        let other = try MastodonPeople.person(from: Data(#"""
        {"id":"7","acct":"eve@far.example","display_name":"E\u202Eve\nL","avatar":"https://m.example/eve.png",
         "emojis":[{"shortcode":"x","url":"https://m.example/x.png"}]}
        """#.utf8), source: Self.source)
        let said = PersonSaid(source: Self.host, reading: .said(other))
        let named = PersonPane.named(Self.ada, said: said)
        #expect(named.name == "Eve L" && named.handle == "@eve@far.example" && named.emojis.map(\.shortcode) == ["x"])
        #expect(PersonPane.face(of: Self.ada, said: said)?.absoluteString == "https://m.example/eve.png")
        // The source says they have no picture: none is drawn, and not the one a row carried.
        let faceless = PersonSaid(source: Self.host, reading: .said(try person("")))
        let carried = DummyPerson(making: Note(
            id: "https://m.example/a/2", source: Self.source, author: "Ada", handle: "@ada@m.example", body: "",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [], avatarURL: URL(string: "https://m.example/old.png")
        ))!
        #expect(carried.avatarURL != nil && PersonPane.face(of: carried, said: faceless) == nil)
        #expect(PersonPane.face(of: carried, said: nil) == carried.avatarURL)
    }

    // MARK: - Laid out

    private func height<Content: View>(_ view: Content, width: CGFloat, layout: ShellLayout, scheme: ColorScheme) -> CGFloat {
        let hosted = NSHostingView(
            rootView: view.frame(width: width).environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
        )
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize.height
    }

    @Test("What the source says is laid out to the width it is given and grows with what there is to say: an account with every line, a header, words and fields stands taller than a bare one, a narrow page no shorter than a wide one, and every foot has a height — at a wide page and across a phone, in light and in dark")
    func laidOut() throws {
        let bare = try MastodonPeople.person(from: Data(#"{"id":"1","acct":"a"}"#.utf8), source: Self.source)
        let plain = try person("")
        let long = String(repeating: "word ", count: 80)
        let every = try person(#","suspended":true,"limited":true,"bot":true,"moved":{"id":"7","acct":"ada@new.example"},"header":"https://m.example/h.png","note":"<p>\#(long)</p>""#)
        for scheme in [ColorScheme.light, .dark] {
            var before: [CGFloat]?
            for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 390), (.narrow, 320)] {
                let heights = [bare, plain, every].map {
                    height(PersonSaidBlock(person: $0, source: Self.host), width: width, layout: layout, scheme: scheme)
                }
                #expect(heights[0] > 0 && heights[1] > heights[0] && heights[2] > heights[1], "\(heights) at \(width)")
                if let before { #expect(heights[2] >= before[2], "the long words wrap: \(heights[2]) at \(width) after \(before[2])") }
                before = heights
                for foot in [PersonSaid.Foot.more, .reading, .end, .failed, .stopped] {
                    #expect(height(PersonFootRow(foot: foot, source: Self.host, onPress: {}), width: width, layout: layout, scheme: scheme) > 0)
                }
            }
        }
        // The page itself, in each state it has, is built and laid out without a trap.
        let rows = [DummyItem(Note(
            id: "https://m.example/a/1", source: Self.source, author: "Ada", handle: "@ada@m.example", body: "a post",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []
        ))]
        for said in [nil, PersonSaid(source: Self.host, reading: .asking), PersonSaid(source: Self.host, reading: .unheardOf),
                     PersonSaid(source: Self.host, reading: .said(every), again: .failed, posts: rows, foot: .stopped),
                     PersonSaid(source: Self.host, reading: .said(plain), posts: [], foot: nil)] as [PersonSaid?] {
            let pane = PersonPane(
                person: Self.ada, items: rows, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), selectedID: .constant(nil),
                decks: .constant(ShellDecks()), playback: ShellPlayback(), onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in },
                onOpenThread: { _ in }, jumpToTop: 0, onBack: {}, said: said
            )
            let hosted = NSHostingView(rootView: pane.frame(width: 320, height: 700))
            hosted.layoutSubtreeIfNeeded()
            #expect(hosted.fittingSize.height == 700)
        }
    }
}
