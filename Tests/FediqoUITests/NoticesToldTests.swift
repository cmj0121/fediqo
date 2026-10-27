import Foundation
import Synchronization
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// The system's notices, held: what it says it allows, how often it was asked, what it showed.
private final class HeldSystem: SystemNotices, Sendable {
    private let state: Mutex<(standing: SystemNoticeStanding, answer: Bool, asked: Int, posted: [String])>

    init(_ standing: SystemNoticeStanding, answer: Bool = true) {
        state = Mutex((standing, answer, 0, []))
    }

    var asked: Int { state.withLock { $0.asked } }
    var posted: [String] { state.withLock { $0.posted } }

    func standing() async -> SystemNoticeStanding { state.withLock { $0.standing } }

    func ask() async -> Bool {
        state.withLock {
            $0.asked += 1
            $0.standing = $0.answer ? .allowed : .refused
            return $0.answer
        }
    }

    func post(id: String, title: String, body: String) async {
        state.withLock { $0.posted.append(id) }
    }
}

/// One line held by the check, handing over what it yields.
private final class OneLine: LineOpener, Sendable {
    private let state = Mutex<(opened: Int, told: AsyncThrowingStream<LineEvent, any Error>.Continuation?)>((0, nil))

    var opened: Int { state.withLock { $0.opened } }
    var told: AsyncThrowingStream<LineEvent, any Error>.Continuation? { state.withLock { $0.told } }

    func open(_ request: URLRequest) async throws -> OpenLine {
        let (events, told) = AsyncThrowingStream<LineEvent, any Error>.makeStream()
        state.withLock {
            $0.opened += 1
            $0.told = told
        }
        return OpenLine(
            response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, events: events
        )
    }
}

/// A source that holds no notices yet, read one at a time, and what was asked of it.
private actor NoticeServer: HTTPSender {
    private(set) var asked: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        asked.append(path)
        let (status, body) = switch path {
        case "/api/v2/notifications": (404, "{}")
        case "/api/v1/notifications": (200, "[]")
        default: (200, #"{"id":"9","acct":"reader"}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
@Suite("A new notice is told while Fediqo runs", .watched)
struct NoticesToldTests {
    private static let host = "social.example"
    private static let forum = "forum.example"

    private static func mention(_ id: String) -> LineEvent {
        LineEvent(name: "notification", data: #"{"id":"\#(id)","type":"mention","created_at":"2026-10-27T00:00:00.000Z","group_key":"ungrouped-\#(id)","account":{"id":"7","username":"ada","acct":"ada","display_name":"Ada"},"status":{"id":"5\#(id)","uri":"https://social.example/users/ada/statuses/5\#(id)","created_at":"2026-10-27T00:00:00.000Z","content":"<p>@reader hello</p>","account":{"id":"7","username":"ada","acct":"ada","display_name":"Ada"}}}"#)
    }

    private static func follow(_ id: String) -> LineEvent {
        LineEvent(name: "notification", data: #"{"id":"\#(id)","type":"follow","created_at":"2026-10-27T00:00:00.000Z","group_key":"follow-1","account":{"id":"8","username":"bo","acct":"bo","display_name":"Bo"}}"#)
    }

    private func make(
        signedIn: Bool = true, notices: Bool = true, system: HeldSystem = HeldSystem(.unasked), line: OneLine = OneLine(),
        defaults: UserDefaults? = nil
    ) async throws -> (ShellSession, NoticeServer) {
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(
                host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s",
                scopes: MastodonOAuth.scopes(writing: false, notices: notices)
            ))
        }
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.add(Source(host: Self.forum, kind: .discourse))
        let server = NoticeServer()
        let session = ShellSession(http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        session.lines = ShellLines(opener: line, sleep: TurnedClock().sleep)
        session.noticesTold = ShellNoticesTold(defaults: defaults, system: system)
        session.mastodon.refresh()
        await session.reloadFromStore()
        return (session, server)
    }

    @Test("Off until chosen; chosen, a source signed in with notices holds its line while Fediqo runs, whatever page is in front, and for nothing else")
    func wanted() async throws {
        let (session, _) = try await make()
        #expect(session.lines.wants(running: true, in: session).isEmpty)
        session.noticesTold.choose(true, host: Self.host)
        session.noticesTold.choose(true, host: Self.forum)
        #expect(session.lines.wants(running: true, in: session) == [ShellLines.Want(host: Self.host, home: false, notices: true)])
        #expect(session.lines.wants(running: false, in: session).isEmpty, "not while the window is in the background")
    }

    @Test("Signed in without notices it is not offered, and says the part's own sentence; signed out it asks to sign in; a forum tells none; the choice is kept")
    func offer() async throws {
        let defaults = try #require(UserDefaults(suiteName: "fediqo.told.\(UUID().uuidString)"))
        let (session, _) = try await make(defaults: defaults)
        #expect(session.noticesTold.offer(host: Self.host, in: session) == .choice(.init(), systemRefused: false))
        session.noticesTold.choose(true, host: Self.host)
        session.noticesTold.tell("favourite", false, host: Self.host)
        #expect(ShellNoticesTold(defaults: defaults).choice(host: Self.host) == .init(on: true, system: false, off: ["favourite"]))
        #expect(session.noticesTold.offer(host: Self.forum, in: session) == .cannot("forum.example tells no notices. It is read as before."))

        let (lacking, _) = try await make(notices: false)
        lacking.noticesTold.choose(true, host: Self.host)
        guard case .locked(let sentence) = lacking.noticesTold.offer(host: Self.host, in: lacking) else {
            Issue.record("offered without the notices part")
            return
        }
        #expect(!sentence.isEmpty)
        #expect(lacking.noticesTold.hosts(in: lacking).isEmpty, "no line for a sign-in that cannot read notices")

        let (signedOut, _) = try await make(signedIn: false)
        #expect(signedOut.noticesTold.offer(host: Self.host, in: signedOut)
            == .signIn("Sign in to social.example, with its notices, to be told of new ones while Fediqo runs."))
        signedOut.noticesTold.press(host: Self.host, in: signedOut)
        #expect(signedOut.signInChoice == Self.host)
        #expect(signedOut.partAsks.signInTicks(host: Self.host)?.parts == [.notices], "the question names notices before the page opens")
    }

    @Test("A notice told on the line is counted where notices are reached, listed by the page's own read, and asks nothing for Home; the page in front counts nothing")
    func told() async throws {
        let line = OneLine()
        let (session, server) = try await make(line: line)
        session.noticesTold.choose(true, host: Self.host)
        let wants = session.lines.wants(running: true, in: session)
        let hearing = Task { await session.lines.hear(wants, in: session) }
        defer { hearing.cancel() }
        let open = await met("the line open", by: hearing) { if case .open? = session.lines.standing[Self.host] { true } else { false } }
        try #require(open)
        line.told?.yield(Self.mention("1"))
        let counted = await met("the notice counted", by: hearing) { session.noticesTold.count == 1 }
        try #require(counted)
        let listed = await met("the page's read asked", by: hearing) { await server.asked.contains("/api/v1/notifications") }
        #expect(listed)
        #expect(await !server.asked.contains("/api/v1/timelines/home"), "a line for notices reads no Home")

        session.noticesTold.pageInFront = true
        #expect(session.noticesTold.count == 0, "the page in front: nothing waits")
        line.told?.yield(Self.mention("2"))
        let read = await met("listed again", by: hearing) {
            await server.asked.filter { $0 == "/api/v1/notifications" }.count >= 2
        }
        #expect(read)
        #expect(session.noticesTold.count == 0)
    }

    @Test("A kind switched off tells nothing — no count, no system notice — and is still listed")
    func kindOff() async throws {
        let system = HeldSystem(.allowed)
        let (session, server) = try await make(system: system)
        session.noticesTold.choose(true, host: Self.host)
        await session.noticesTold.chooseSystem(true, host: Self.host)
        session.noticesTold.tell("follow", false, host: Self.host)
        let source = Source(host: Self.host, kind: .mastodon)
        await session.noticesTold.told(try #require(MastodonNotices.told(Self.follow("3"), source: source)), in: session)
        #expect(session.noticesTold.count == 0)
        #expect(system.posted.isEmpty)
        #expect(await server.asked.contains("/api/v1/notifications"), "still listed")
        await session.noticesTold.told(try #require(MastodonNotices.told(Self.mention("4"), source: source)), in: session)
        #expect(session.noticesTold.count == 1)
        #expect(system.posted.count == 1)
    }

    @Test("The system is asked only when its switch is turned on, never before; refused, the switch stays off, says so, nothing asks again, and the count works")
    func system() async throws {
        let refusing = HeldSystem(.unasked, answer: false)
        let (session, _) = try await make(system: refusing)
        session.noticesTold.choose(true, host: Self.host)
        #expect(refusing.asked == 0, "never asked by choosing to be told")
        let source = Source(host: Self.host, kind: .mastodon)
        await session.noticesTold.told(try #require(MastodonNotices.told(Self.mention("5"), source: source)), in: session)
        #expect(refusing.posted.isEmpty, "off by default")
        await session.noticesTold.chooseSystem(true, host: Self.host)
        #expect(refusing.asked == 1)
        #expect(session.noticesTold.choice(host: Self.host).system == false)
        #expect(session.noticesTold.offer(host: Self.host, in: session) == .choice(
            .init(on: true, system: false, off: []), systemRefused: true
        ))
        await session.noticesTold.chooseSystem(true, host: Self.host)
        #expect(refusing.asked == 1, "nothing asks again")
        await session.noticesTold.told(try #require(MastodonNotices.told(Self.mention("6"), source: source)), in: session)
        #expect(session.noticesTold.count == 2)
        #expect(refusing.posted.isEmpty)

        let allowing = HeldSystem(.unasked)
        let (allowed, _) = try await make(system: allowing)
        allowed.noticesTold.choose(true, host: Self.host)
        await allowed.noticesTold.chooseSystem(true, host: Self.host)
        await allowed.noticesTold.told(try #require(MastodonNotices.told(Self.mention("7"), source: source)), in: allowed)
        #expect(allowing.asked == 1 && allowing.posted.count == 1)
    }

    @Test("Every word it says is in each language", arguments: [
        "source.told", "source.told.help", "source.told.system", "source.told.system.help", "source.told.system.refused",
        "source.told.kinds", "source.told.signIn", "source.told.cannot", "rail.count",
    ])
    func words(key: String) {
        for language in DummyLanguage.allCases {
            #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
        }
    }
}
