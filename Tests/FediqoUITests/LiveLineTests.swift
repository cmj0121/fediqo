import Foundation
import Synchronization
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Lines held by the check (#325): each open answers `status` and hands over a stream of its own,
/// which the check yields on or ends.
private final class Lines: LineOpener, Sendable {
    let status: Int
    private let state = Mutex<(requests: [URLRequest], told: [AsyncThrowingStream<LineEvent, any Error>.Continuation])>(([], []))

    init(status: Int = 200) {
        self.status = status
    }

    var opened: Int { state.withLock { $0.requests.count } }
    /// The line opened last.
    var last: AsyncThrowingStream<LineEvent, any Error>.Continuation? { state.withLock { $0.told.last } }

    func open(_ request: URLRequest) async throws -> OpenLine {
        let (events, told) = AsyncThrowingStream<LineEvent, any Error>.makeStream()
        state.withLock {
            $0.requests.append(request)
            $0.told.append(told)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!
        if !(200..<300).contains(status) { told.finish() }
        return OpenLine(response: response, events: events)
    }
}

/// Home as the source answers it, and what was asked of it.
private actor HomeServer: HTTPSender {
    var home = "[]"
    private(set) var asked: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        asked.append(path)
        let body = path == "/api/v1/timelines/home" ? home : #"{"id":"9","acct":"reader"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func answer(_ home: String) { self.home = home }
}

@MainActor
@Suite("What is new in Home arrives as it happens", .watched)
struct LiveLineTests {
    private static let host = "social.example"
    private static let forum = "forum.example"

    private static func status(_ id: String, words: String = "post") -> String {
        #"{"id":"\#(id)","uri":"https://social.example/users/ada/statuses/\#(id)","created_at":"2026-10-27T00:00:0\#(id.suffix(1)).000Z","content":"<p>\#(words) \#(id)</p>","account":{"username":"ada","acct":"ada","display_name":"Ada"}}"#
    }

    private func make(
        signedIn: Bool = true, lines: Lines = Lines(), clock: TurnedClock = TurnedClock(), defaults: UserDefaults? = nil
    ) async throws -> (ShellSession, HomeServer, SourceWork) {
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(
                host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s", scopes: MastodonOAuth.reading
            ))
        }
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.add(Source(host: Self.forum, kind: .discourse))
        let server = HomeServer()
        let session = ShellSession(http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        session.lines = ShellLines(defaults: defaults, opener: lines, sleep: clock.sleep)
        session.mastodon.refresh()
        await session.reloadFromStore()
        return (session, server, work)
    }

    // MARK: - Which lines are wanted

    @Test("A line is wanted only for a source chosen, signed in, a Mastodon, whose Home the timeline in front reads; never on Trends nor with the timeline not in front")
    func wanted() async throws {
        let (session, _, _) = try await make()
        #expect(session.lines.wanted(timeline: .all, inFront: true, in: session).isEmpty, "off until chosen")
        session.lines.choose(true, host: Self.host)
        session.lines.choose(true, host: Self.forum)
        #expect(session.lines.wanted(timeline: .all, inFront: true, in: session) == [Self.host])
        #expect(session.lines.wanted(timeline: .all, inFront: false, in: session).isEmpty)
        #expect(session.lines.wanted(timeline: .trends, inFront: true, in: session).isEmpty)

        let (signedOut, _, _) = try await make(signedIn: false)
        signedOut.lines.choose(true, host: Self.host)
        #expect(signedOut.lines.wanted(timeline: .all, inFront: true, in: signedOut).isEmpty)
    }

    @Test("The source's page offers the switch where signed in, asks to sign in where not, and says a forum cannot; the choice is kept")
    func offer() async throws {
        let defaults = try #require(UserDefaults(suiteName: "fediqo.lines.\(UUID().uuidString)"))
        let (session, _, _) = try await make(defaults: defaults)
        #expect(session.lines.offer(host: Self.host, in: session) == .choice(on: false, standing: nil))
        session.lines.choose(true, host: Self.host)
        #expect(session.lines.offer(host: Self.host, in: session) == .choice(on: true, standing: nil))
        #expect(ShellLines(defaults: defaults).chosen == [Self.host], "kept for the next launch")
        #expect(session.lines.offer(host: Self.forum, in: session)
            == .cannot("forum.example does not say what is new as it happens. It is read as before."))

        let (signedOut, _, _) = try await make(signedIn: false)
        let offered = signedOut.lines.offer(host: Self.host, in: signedOut)
        #expect(offered == .signIn("Sign in to social.example to have new posts in Home arrive as they happen."))
        signedOut.lines.pressSignIn(host: Self.host, in: signedOut)
        #expect(signedOut.signInChoice == Self.host, "the read-or-act question, which says what is asked before the page opens")
    }

    // MARK: - A line held

    @Test("Held, the line is one act on the record; Home is read up to now first; a post told lands once and is said above; a deletion marks it gone; let go, the act says until when")
    func held() async throws {
        let lines = Lines()
        let (session, server, work) = try await make(lines: lines)
        await server.answer("[" + Self.status("1") + "]")
        let hearing = Task { await session.lines.hear([Self.host], in: session) }
        defer { hearing.cancel() }

        let open = await met("the line open", by: hearing) {
            if case .open? = session.lines.standing[Self.host] { return true }
            return false
        }
        try #require(open)
        #expect(await server.asked.contains("/api/v1/timelines/home"), "Home read up to now as the line opened")
        #expect(await session.store.all().count == 1)
        let acts = work.record.filter { $0.purpose == .line }
        #expect(acts.count == 1 && acts.first?.source == Self.host && acts.first?.until == nil)

        lines.last?.yield(LineEvent(name: "update", data: Self.status("2")))
        let arrived = await met("the post told lands", by: hearing) { session.lines.above == 1 }
        try #require(arrived)
        let key = NoteKey(host: Self.host, id: "https://social.example/users/ada/statuses/2")
        #expect(await session.store.note(key)?.listed[.home] == "2")
        lines.last?.yield(LineEvent(name: "update", data: Self.status("2")))
        lines.last?.yield(LineEvent(name: "delete", data: "2"))
        let gone = await met("the deletion lands", by: hearing) { await session.store.note(key)?.goneSince != nil }
        #expect(gone)
        #expect(session.lines.above == 1, "told twice, one post above")
        #expect(await session.store.all().count == 2)

        session.lines.seen(top: key.rowID)
        #expect(session.lines.above == 0, "up as far as it, nothing is above")

        hearing.cancel()
        let ended = await met("the line let go") { session.lines.standing[Self.host] == nil }
        #expect(ended)
        let closed = await met("the record says until when") { work.record.first { $0.purpose == .line }?.until != nil }
        #expect(closed)
        #expect(work.record.filter { $0.purpose == .line }.count == 1, "one ask, open for as long as it was")
    }

    @Test("Dropped, nothing is said, and after the wait the line is opened again and Home read up to now again")
    func dropped() async throws {
        let lines = Lines()
        let clock = TurnedClock()
        let (session, server, _) = try await make(lines: lines, clock: clock)
        let hearing = Task { await session.lines.hear([Self.host], in: session) }
        defer { hearing.cancel() }
        let open = await met("the line open", by: hearing) { if case .open? = session.lines.standing[Self.host] { true } else { false } }
        try #require(open)
        lines.last?.finish(throwing: URLError(.networkConnectionLost))
        let waiting = await met("waiting after the drop", by: hearing) { clock.sleeping == 1 }
        try #require(waiting)
        #expect(session.lines.standing[Self.host] == .waiting)
        #expect(LineControl.line(.waiting, host: Self.host) == nil, "a drop says nothing")
        let homeReads = await server.asked.filter { $0 == "/api/v1/timelines/home" }.count
        clock.turn()
        let again = await met("opened again", by: hearing) { lines.opened == 2 && session.lines.standing[Self.host] != .waiting }
        #expect(again)
        let reread = await met("Home read again", by: hearing) {
            await server.asked.filter { $0 == "/api/v1/timelines/home" }.count == homeReads + 1
        }
        #expect(reread)
    }

    @Test("Refused, it is said on the source's page, not asked again this run, and nothing held changes")
    func refused() async throws {
        let lines = Lines(status: 401)
        let (session, server, _) = try await make(lines: lines)
        session.lines.choose(true, host: Self.host)
        await session.lines.hear([Self.host], in: session)
        #expect(session.lines.standing[Self.host] == .refused(401))
        #expect(session.lines.wanted(timeline: .all, inFront: true, in: session).isEmpty)
        #expect(await server.asked.isEmpty, "Home is not read for a line that never opened")
        #expect(await session.store.all().isEmpty)
        #expect(session.mastodon.isSignedIn(host: Self.host), "a line's refusal signs nobody out")
        #expect(LineControl.line(.refused(401), host: Self.host) == "social.example refused the line (401). Home is read as before.")
    }

    @Test("Every word it says is in each language, and the two Chinese tables are one", arguments: [
        "work.purpose.line", "activity.detail.until", "activity.detail.stillOpen", "source.line", "source.line.help",
        "source.line.open", "source.line.refused", "source.line.signIn", "source.line.cannot", "timeline.line.above",
        "timeline.line.above.one", "timeline.line.above.hint",
    ])
    func words(key: String) {
        for language in DummyLanguage.allCases {
            #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
        }
    }
}
