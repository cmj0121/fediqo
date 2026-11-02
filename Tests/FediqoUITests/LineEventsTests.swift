import Foundation
import Synchronization
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// The lines held by the check, one by the path it was opened for, handing over what each yields.
private final class PathLines: LineOpener, Sendable {
    private let lines = Mutex<[String: AsyncThrowingStream<LineEvent, any Error>.Continuation]>([:])

    func told(_ path: String) -> AsyncThrowingStream<LineEvent, any Error>.Continuation? { lines.withLock { $0[path] } }

    func open(_ request: URLRequest) async throws -> OpenLine {
        let (events, told) = AsyncThrowingStream<LineEvent, any Error>.makeStream()
        lines.withLock { $0[request.url?.path ?? ""] = told }
        return OpenLine(
            response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, events: events
        )
    }
}

/// #427: what else a line says shows by itself, read again as its own page reads it, and no line is
/// held that nobody chose. The event names are the ones `MastodonLiveCaptures` records.
@MainActor
@Suite("A direct post, an announcement and a changed filter while Fediqo is open", .serialized, .watched)
struct LineEventsTests {
    private static let host = "m.example"
    private static let userLine = "/api/v1/streaming/user"
    private static let directLine = "/api/v1/streaming/direct"
    private static let conversations = "/api/v1/conversations?limit=20"
    private static let announcements = "/api/v1/announcements"
    private static let filters = "/api/v2/filters"

    private func make(_ routes: [String: PageServer.Answer], lines: PathLines = PathLines()) async throws -> (ShellSession, PageServer) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        session.lines = ShellLines(opener: lines, sleep: TurnedClock().sleep)
        await session.store.add(Source(host: Self.host, kind: .mastodon))
        session.sources = await session.store.sources()
        let scopes = "read:statuses read:lists read:accounts read:filters write:filters write:conversations"
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes,
            accountID: "7", handle: "@me@m.example"
        ))
        session.mastodon.refresh()
        return (session, server)
    }

    private static func conversation(_ id: String) -> String {
        #"{"id":"\#(id)","unread":true,"accounts":[{"display_name":"Ada","acct":"ada","username":"ada"}],"last_status":{"id":"9\#(id)","uri":"https://m.example/s/9\#(id)","created_at":"2026-11-02T00:00:00.000Z","content":"<p>hi</p>","visibility":"direct","account":{"id":"1","display_name":"Ada","acct":"ada","username":"ada"}}}"#
    }

    private func count(_ server: PageServer, _ ask: String) async -> Int {
        await server.asked.filter { $0 == ask }.count
    }

    @Test("No line is held that nobody chose: not for a source's page, nor for its conversations")
    func noLineUnchosen() async throws {
        let (session, _) = try await make([:])
        session.lines.sourcePage = Self.host
        session.directs.shown = Self.host
        #expect(session.lines.wants(running: true, in: session).isEmpty)
        #expect(session.lines.directWanted(running: true, in: session) == nil)
    }

    @Test("Chosen, the source's page in front holds its own line, for neither Home nor notices, and only while it is")
    func pageHoldsLine() async throws {
        let (session, _) = try await make([:])
        session.lines.choose(true, host: Self.host)
        #expect(session.lines.wants(running: true, in: session).isEmpty, "no timeline, and no page in front")
        session.lines.sourcePage = Self.host
        #expect(session.lines.wants(running: true, in: session) == [ShellLines.Want(host: Self.host, home: false, notices: false)])
        #expect(session.lines.wants(running: false, in: session).isEmpty)
        session.lines.sourcePage = nil
        #expect(session.lines.wants(running: true, in: session).isEmpty)
    }

    @Test("Chosen, a direct post told on the direct line lands in the list open, at its head, over what was read on to")
    func directLands() async throws {
        let lines = PathLines()
        let (session, server) = try await make(
            [Self.conversations: PageServer.Answer(body: "[\(Self.conversation("1"))]")], lines: lines
        )
        session.lines.choose(true, host: Self.host)
        #expect(session.lines.directWanted(running: true, in: session) == nil, "the list is not up")
        await session.directs.show(Self.host, in: session)
        #expect(session.lines.directWanted(running: true, in: session) == Self.host)
        #expect(session.lines.directWanted(running: false, in: session) == nil)
        #expect(session.directs.said(at: Self.host, in: session)?.lines.map(\.id) == ["1"])

        let hearing = Task { await session.lines.hearDirect(Self.host, in: session) }
        defer { hearing.cancel() }
        let open = await met("the direct line open", by: hearing) { lines.told(Self.directLine) != nil }
        try #require(open)
        #expect(lines.told(Self.userLine) == nil, "the direct line is its own")
        await server.answer(Self.conversations, PageServer.Answer(body: "[\(Self.conversation("2"))]"))
        lines.told(Self.directLine)?.yield(LineEvent(name: "conversation", data: Self.conversation("2")))
        let landed = await met("the new one listed", by: hearing) {
            session.directs.said(at: Self.host, in: session)?.lines.map(\.id) == ["2", "1"]
        }
        #expect(landed, "the source's read says what is drawn, and what was listed below stays")
    }

    @Test("A direct line refused is not asked again this run, and the list stands")
    func directRefused() async throws {
        struct Refusing: LineOpener {
            func open(_ request: URLRequest) async throws -> OpenLine {
                let (events, _) = AsyncThrowingStream<LineEvent, any Error>.makeStream()
                return OpenLine(
                    response: HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, events: events
                )
            }
        }
        let (session, _) = try await make([Self.conversations: PageServer.Answer(body: "[\(Self.conversation("1"))]")])
        session.lines = ShellLines(opener: Refusing(), sleep: TurnedClock().sleep)
        session.lines.choose(true, host: Self.host)
        await session.directs.show(Self.host, in: session)
        await session.lines.hearDirect(Self.host, in: session)
        #expect(session.lines.directWanted(running: true, in: session) == nil)
        #expect(session.directs.said(at: Self.host, in: session)?.lines.map(\.id) == ["1"])
    }

    @Test("Each thing said of an announcement reads it again at once, within the fifteen minutes, and only the source's read is drawn", arguments: [
        "announcement", "announcement.reaction", "announcement.delete",
    ])
    func announced(event: String) async throws {
        let lines = PathLines()
        let people = ShellPersonPages()
        let (session, server) = try await make([Self.announcements: PageServer.Answer(body: "[]")], lines: lines)
        session.lines.choose(true, host: Self.host)
        session.lines.announced = { host in await people.announcements.heard(host, in: session) }
        await people.announcements.opened(Self.host, in: session)
        let before = await count(server, Self.announcements)
        #expect(before == 1)

        session.lines.sourcePage = Self.host
        let wants = session.lines.wants(running: true, in: session)
        let hearing = Task { await session.lines.hear(wants, in: session) }
        defer { hearing.cancel() }
        let open = await met("the line open", by: hearing) { if case .open? = session.lines.standing[Self.host] { true } else { false } }
        try #require(open)
        lines.told(Self.userLine)?.yield(LineEvent(name: event, data: "3"))
        let read = await met("read again", by: hearing) { await count(server, Self.announcements) == before + 1 }
        #expect(read)
    }

    @Test("A filters event reads a list already read, and never one no page has asked for")
    func filtersChanged() async throws {
        let (session, server) = try await make([Self.filters: PageServer.Answer(body: "[]")])
        await session.serverFilters.heard(host: Self.host, in: session)
        #expect(await count(server, Self.filters) == 0)
        await session.serverFilters.read(host: Self.host, in: session)
        await session.serverFilters.heard(host: Self.host, in: session)
        #expect(await count(server, Self.filters) == 2)
    }

    /// A line that opens with `status`, and ends at once.
    private struct Opening: LineOpener {
        let status: Int
        func open(_ request: URLRequest) async throws -> OpenLine {
            let (events, told) = AsyncThrowingStream<LineEvent, any Error>.makeStream()
            told.finish()
            return OpenLine(
                response: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, events: events
            )
        }
    }

    /// One pass of a direct line: the wait after it ends the holding.
    private func oneOpen(_ session: ShellSession, status: Int) async {
        let chosen = session.lines.chosen
        session.lines = ShellLines(opener: Opening(status: status), sleep: { _ in throw CancellationError() })
        for host in chosen { session.lines.choose(true, host: host) }
        await session.lines.hearDirect(Self.host, in: session)
    }

    @Test("Every open of the direct line reads the list, the first of a new holding too: what came with none open is not missed")
    func directCatchesUp() async throws {
        let (session, server) = try await make([Self.conversations: PageServer.Answer(body: "[\(Self.conversation("1"))]")])
        session.lines.choose(true, host: Self.host)
        await session.directs.show(Self.host, in: session)
        #expect(await count(server, Self.conversations) == 1)
        await oneOpen(session, status: 200)
        #expect(await count(server, Self.conversations) == 2)
    }

    @Test("A direct line's busy answer or a doubted sign-in stops nothing for good; a real refusal does, until the sign-in changes", arguments: [429, 401])
    func directRefusalNarrow(status: Int) async throws {
        let (session, _) = try await make([Self.conversations: PageServer.Answer(body: "[]")])
        session.lines.choose(true, host: Self.host)
        await session.directs.show(Self.host, in: session)
        await oneOpen(session, status: status)
        #expect(session.lines.directWanted(running: true, in: session) == Self.host)

        await oneOpen(session, status: 403)
        #expect(session.lines.directWanted(running: true, in: session) == nil)
        let scopes = "read:statuses read:lists read:accounts"
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "new", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes,
            accountID: "7", handle: "@me@m.example"
        ))
        session.mastodon.refresh()
        #expect(session.lines.directWanted(running: true, in: session) == Self.host, "a new sign-in is asked afresh")
    }

    @Test("A direct post told while somebody else's read of the list is out is read after it, by whoever owns that read")
    func directToldDuringAnotherRead() async throws {
        let (session, server) = try await make([Self.conversations: PageServer.Answer(body: "[]")])
        await session.directs.show(Self.host, in: session)
        await server.hold(Self.conversations)
        let other = Task { await session.directs.again(Self.host, in: session) }
        await met("the other read out", by: other) { await server.arrivals(of: Self.conversations) == 2 }
        await session.directs.heard(Self.host, in: session)
        await server.release(Self.conversations)
        await other.value
        #expect(await count(server, Self.conversations) == 3)
    }

    @Test("An announcement told while somebody else's read is out is read after it, by whoever owns that read")
    func announcedDuringAnotherRead() async throws {
        let people = ShellPersonPages()
        let (session, server) = try await make([Self.announcements: PageServer.Answer(body: "[]")])
        await server.hold(Self.announcements)
        let opening = Task { await people.announcements.opened(Self.host, in: session) }
        await met("the opening read out", by: opening) { await server.arrivals(of: Self.announcements) == 1 }
        await people.announcements.heard(Self.host, in: session)
        await server.release(Self.announcements)
        await opening.value
        #expect(await count(server, Self.announcements) == 2)
    }
}
