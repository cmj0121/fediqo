import Foundation
import Synchronization
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// The system's notices, held: what it says it allows, how often it was asked, what it showed.
private final class HeldSystem: SystemNotices, Sendable {
    private let state: Mutex<(standing: SystemNoticeStanding, answer: Bool, asked: Int, posted: [String], front: Bool)>

    init(_ standing: SystemNoticeStanding, answer: Bool = true, front: Bool = false) {
        state = Mutex((standing, answer, 0, [], front))
    }

    func setFront(_ front: Bool) { state.withLock { $0.front = front } }
    func inFront() -> Bool { state.withLock { $0.front } }

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
    /// What was asked in whole, and each form sent.
    private(set) var queries: [String] = []
    private(set) var told: [String] = []
    /// What the source says is unread: its answer, and the status it comes with.
    var unread = (status: 200, count: 0)
    var list = "[]"
    var marker = "{}"

    func setUnread(_ count: Int, status: Int = 200) { unread = (status, count) }
    func setList(_ body: String) { list = body }
    func setMarker(_ body: String) { marker = body }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        asked.append(path)
        queries.append(request.url?.query ?? "")
        if request.httpMethod == "POST", path == "/api/v1/markers" {
            told.append(request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        let (status, body) = switch path {
        case "/api/v2/notifications": (404, "{}")
        case "/api/v1/notifications": (200, list)
        case "/api/v1/notifications/unread_count": (unread.status, #"{"count":\#(unread.count)}"#)
        case "/api/v1/markers": (200, marker)
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
        signedIn: Bool = true, notices: Bool = true, writing: Bool = false, system: HeldSystem = HeldSystem(.unasked), line: OneLine = OneLine(),
        defaults: UserDefaults? = nil
    ) async throws -> (ShellSession, NoticeServer) {
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(
                host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s",
                scopes: MastodonOAuth.scopes(writing: writing, notices: notices)
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

    @Test("A notice told on the line moves the count to the source's own word, is listed by the page's own read, and asks nothing for Home")
    func told() async throws {
        let line = OneLine()
        let (session, server) = try await make(line: line)
        session.noticesTold.choose(true, host: Self.host)
        let wants = session.lines.wants(running: true, in: session)
        let hearing = Task { await session.lines.hear(wants, in: session) }
        defer { hearing.cancel() }
        let open = await met("the line open", by: hearing) { if case .open? = session.lines.standing[Self.host] { true } else { false } }
        try #require(open)
        await server.setUnread(5)
        line.told?.yield(Self.mention("1"))
        let counted = await met("the source's count taken", by: hearing) { session.noticesTold.count == 5 }
        try #require(counted)
        let listed = await met("the page's read asked", by: hearing) { await server.asked.contains("/api/v1/notifications") }
        #expect(listed)
        #expect(await !server.asked.contains("/api/v1/timelines/home"), "a line for notices reads no Home")

        await server.setUnread(0)
        line.told?.yield(Self.mention("2"))
        let read = await met("the count read again, and fallen", by: hearing) { session.noticesTold.count == 0 }
        #expect(read, "read elsewhere: the next read says so")
    }

    @Test("The line opening reads the list, so what came while none was open is not missed")
    func caughtUpOnOpen() async throws {
        let line = OneLine()
        let (session, server) = try await make(line: line)
        session.noticesTold.choose(true, host: Self.host)
        let wants = session.lines.wants(running: true, in: session)
        let hearing = Task { await session.lines.hear(wants, in: session) }
        defer { hearing.cancel() }
        let read = await met("the list read as the line opens", by: hearing) {
            await server.asked.contains("/api/v1/notifications")
        }
        #expect(read)
        #expect(session.noticesTold.count == 0)
    }

    @Test("The source saying requests let through have landed reads the list")
    func mergedReads() async throws {
        let line = OneLine()
        let (session, server) = try await make(line: line)
        session.noticesTold.choose(true, host: Self.host)
        let wants = session.lines.wants(running: true, in: session)
        let hearing = Task { await session.lines.hear(wants, in: session) }
        defer { hearing.cancel() }
        let open = await met("the line open", by: hearing) { if case .open? = session.lines.standing[Self.host] { true } else { false } }
        try #require(open)
        let before = await server.asked.filter { $0 == "/api/v1/notifications" }.count
        line.told?.yield(LineEvent(name: "notifications_merged", data: "1"))
        let read = await met("listed again", by: hearing) {
            await server.asked.filter { $0 == "/api/v1/notifications" }.count > before
        }
        #expect(read)
        #expect(session.noticesTold.count == 0)
    }

    @Test("One notice told twice is shown by the system once, and the count is the source's whichever")
    func toldOnce() async throws {
        let system = HeldSystem(.allowed)
        let (session, server) = try await make(system: system)
        await server.setUnread(1)
        session.noticesTold.choose(true, host: Self.host)
        await session.noticesTold.chooseSystem(true, host: Self.host)
        let notice = try #require(MastodonNotices.told(Self.mention("5"), source: Source(host: Self.host, kind: .mastodon)))
        await session.noticesTold.told(notice, in: session)
        await session.noticesTold.told(notice, in: session)
        #expect(session.noticesTold.count == 1)
        #expect(system.posted.count == 1)
    }

    @Test("In front the system shows nothing and the count still rises; behind other windows it shows")
    func inFront() async throws {
        let system = HeldSystem(.allowed, front: true)
        let (session, server) = try await make(system: system)
        await server.setUnread(1)
        session.noticesTold.choose(true, host: Self.host)
        await session.noticesTold.chooseSystem(true, host: Self.host)
        let source = Source(host: Self.host, kind: .mastodon)
        await session.noticesTold.told(try #require(MastodonNotices.told(Self.mention("6"), source: source)), in: session)
        #expect(system.posted.isEmpty)
        #expect(session.noticesTold.count == 1)
        system.setFront(false)
        await session.noticesTold.told(try #require(MastodonNotices.told(Self.mention("7"), source: source)), in: session)
        #expect(system.posted.count == 1)
    }

    @Test("A press on the system's notice hands over that notice once; one this run did not tell hands over none")
    func pressed() async throws {
        let (session, _) = try await make(system: HeldSystem(.allowed))
        let notice = try #require(MastodonNotices.told(Self.mention("8"), source: Source(host: Self.host, kind: .mastodon)))
        await session.noticesTold.told(notice, in: session)
        let presses = SystemNoticePresses()
        presses.told = session.noticesTold
        presses.pressed(id: notice.id)
        #expect(session.noticesTold.pressedID == notice.id)
        #expect(session.noticesTold.takePressed()?.id == notice.id)
        #expect(session.noticesTold.pressedID == nil)
        presses.pressed(id: "not told")
        #expect(session.noticesTold.takePressed() == nil)
    }

    @Test("A press from before anybody was there to hear it waits for them")
    func pressWaits() async throws {
        let (session, _) = try await make()
        let presses = SystemNoticePresses()
        presses.pressed(id: "early")
        presses.told = session.noticesTold
        #expect(session.noticesTold.pressedID == "early")
    }

    @Test("A kind switched off shows no system notice, is asked to be left out of the source's count, and is still listed")
    func kindOff() async throws {
        let system = HeldSystem(.allowed)
        let (session, server) = try await make(system: system)
        session.noticesTold.choose(true, host: Self.host)
        await session.noticesTold.chooseSystem(true, host: Self.host)
        session.noticesTold.tell("follow", false, host: Self.host)
        let source = Source(host: Self.host, kind: .mastodon)
        await session.noticesTold.told(try #require(MastodonNotices.told(Self.follow("3"), source: source)), in: session)
        #expect(system.posted.isEmpty)
        #expect(await server.asked.contains("/api/v1/notifications"), "still listed")
        #expect(await server.queries.contains { $0.contains("exclude_types%5B%5D=follow") }, "left out by asking the source")
        await session.noticesTold.told(try #require(MastodonNotices.told(Self.mention("4"), source: source)), in: session)
        #expect(system.posted.count == 1)
    }

    @Test("The system is asked only when its switch is turned on, never before; refused, the switch stays off, says so, nothing asks again, and the count works")
    func system() async throws {
        let refusing = HeldSystem(.unasked, answer: false)
        let (session, server) = try await make(system: refusing)
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
        await server.setUnread(2)
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

    @Test("A source refusing or failing the count says so, once, and the count stands as it last said")
    func countFails() async throws {
        let (session, server) = try await make()
        session.noticesTold.choose(true, host: Self.host)
        await server.setUnread(4)
        await session.noticesTold.afterRead(in: session)
        #expect(session.noticesTold.count == 4)
        await server.setUnread(0, status: 500)
        await session.noticesTold.afterRead(in: session)
        #expect(session.noticesTold.count == 4)
        #expect(session.noticesTold.countWords(host: Self.host, in: session)?.contains("did not say") == true)
        await server.setUnread(9)
        await session.noticesTold.afterRead(in: session)
        #expect(session.noticesTold.count == 9)
    }

    @Test("A source with no such count says so, and nothing is drawn for it; turned off, its count goes")
    func noCount() async throws {
        let (session, server) = try await make()
        session.noticesTold.choose(true, host: Self.host)
        await server.setUnread(0, status: 404)
        await session.noticesTold.afterRead(in: session)
        #expect(session.noticesTold.counts.isEmpty && session.noticesTold.countSaid[Self.host] == ShellNoticesTold.CountSaid.none)
        await server.setUnread(3)
        await session.noticesTold.afterRead(in: session)
        #expect(session.noticesTold.count == 3)
        session.noticesTold.choose(false, host: Self.host)
        #expect(session.noticesTold.count == 0)
    }

    private static let list = "[" + Self.mention("120").data + "," + Self.mention("9").data + "]"

    @Test("The page in front tells the source the newest read, by the numbers' order, and then reads its count")
    func pageTells() async throws {
        let (session, server) = try await make(writing: true)
        session.noticesTold.choose(true, host: Self.host)
        await server.setList(Self.list)
        await server.setUnread(0)
        await session.noticeList.read(in: session)
        #expect(await server.told.isEmpty, "not in front: nothing is told")
        await session.noticesTold.pageCame(true, in: session)
        #expect(await server.told.count == 1)
        #expect(await server.told.first?.contains("=120") == true, "the newest, and 120 is newer than 9")
        #expect(session.noticesTold.count == 0)
    }

    @Test("A place the source already holds past what was read is never moved back")
    func neverBack() async throws {
        let (session, server) = try await make(writing: true)
        session.noticesTold.choose(true, host: Self.host)
        await server.setList(Self.list)
        await server.setMarker(#"{"notifications":{"last_read_id":"500","version":1,"updated_at":"2026-11-02T09:51:09.835Z"}}"#)
        await session.noticeList.read(in: session)
        await session.noticesTold.pageCame(true, in: session)
        #expect(await server.told.isEmpty)
    }

    @Test("A sign-in that only reads tells the source nothing, and the page says so")
    func readOnlyTellsNothing() async throws {
        let (session, server) = try await make(writing: false)
        session.noticesTold.choose(true, host: Self.host)
        await server.setList(Self.list)
        await server.setUnread(2)
        await session.noticeList.read(in: session)
        await session.noticesTold.pageCame(true, in: session)
        #expect(await server.told.isEmpty)
        #expect(session.noticesTold.count == 2, "the source's word, whatever is in front")
        #expect(session.noticesTold.countWords(host: Self.host, in: session)?.contains("only reads") == true)
    }

    @Test("A source that says it lacks a kind is offered no switch for it, and is never asked to leave it out")
    func lackedKinds() async throws {
        let (session, server) = try await make()
        let hosts = ShellHostsKnown(errands: PageErrands())
        session.quoting.hosts = hosts
        session.noticesTold.choose(true, host: Self.host)
        #expect(session.noticesTold.kinds(host: Self.host, in: session).contains("added_to_collection"), "unsaid: offered")
        session.noticesTold.tell("added_to_collection", false, host: Self.host)
        session.noticesTold.tell("follow", false, host: Self.host)
        await session.noticesTold.afterRead(in: session)
        #expect(await server.queries.last?.contains("exclude_types%5B%5D=added_to_collection") == true)

        hosts.notFound(.collections, at: Self.host, round: hosts.round(at: Self.host))
        #expect(!session.noticesTold.kinds(host: Self.host, in: session).contains("added_to_collection"))
        await session.noticesTold.afterRead(in: session)
        let last = try #require(await server.queries.last)
        #expect(!last.contains("added_to_collection") && last.contains("exclude_types%5B%5D=follow"))
    }

    @Test("It says plainly, in each language, that notices come only while Fediqo is open, and why", arguments: [
        "source.told.open", "source.told.help", "source.told.system.help",
    ])
    func saysOnlyWhileOpen(key: String) {
        #expect(L10n.t(key, language: .english).contains("only while Fediqo is open"))
        #expect(L10n.t(key, language: .english).contains("there is no Fediqo server"))
        #expect(L10n.t(key, language: .taiwanese).contains("只在 Fediqo 開著時"))
        #expect(L10n.t(key, language: .taiwanese).contains("沒有 Fediqo 服務端"))
    }

    @Test("Every word it says is in each language", arguments: [
        "source.told", "source.told.help", "source.told.system", "source.told.system.help", "source.told.system.refused",
        "source.told.kinds", "source.told.signIn", "source.told.cannot", "source.told.open", "rail.count",
        "source.told.count.failed", "source.told.count.none", "source.told.count.readOnly", "source.told.mark.failed",
    ])
    func words(key: String) {
        for language in DummyLanguage.allCases {
            #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
        }
    }
}
