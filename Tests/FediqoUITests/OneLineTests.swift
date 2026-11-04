import Foundation
import Synchronization
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Lines held by the check, by the path each was opened for.
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

/// A source answering every read with nothing, and saying who the reader is; what was asked is kept.
private actor QuietServer: HTTPSender {
    private(set) var asked: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        asked.append(path)
        let body = path.hasPrefix("/api/v1/accounts") ? #"{"id":"7","acct":"me"}"# : "[]"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Everything heard from one source comes on one line (#459).
@MainActor
@Suite("Everything heard from one source comes on one line", .serialized, .watched)
struct OneLineTests {
    private static let host = "m.example"

    private static func status(_ id: String) -> String {
        #"{"id":"\#(id)","uri":"https://m.example/users/ada/statuses/\#(id)","created_at":"2026-11-02T00:00:0\#(id.suffix(1)).000Z","content":"<p>post \#(id)</p>","account":{"username":"ada","acct":"ada","display_name":"Ada"}}"#
    }

    /// What the socket says of `event` on `stream`, with `payload` as the text it carries.
    private static func said(_ stream: String, _ event: String, payload: String?) -> String {
        var frame: [String: Any] = ["stream": [stream], "event": event]
        if let payload { frame["payload"] = payload }
        return String(decoding: try! JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    private func make(
        sockets: HeldSockets, lines: PathLines = PathLines(), linger: TurnedClock = TurnedClock()
    ) async throws -> (ShellSession, QuietServer, SourceWork) {
        let server = QuietServer()
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        session.lines = ShellLines(
            opener: lines, sleep: TurnedClock().sleep, gather: {},
            sockets: ShellSockets(opener: sockets, linger: { try await linger.sleep(for: ShellSockets.lingering) })
        )
        await session.store.add(Source(host: Self.host, kind: .mastodon))
        session.sources = await session.store.sources()
        let scopes = "read:statuses read:lists read:accounts read:notifications write:conversations"
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes,
            accountID: "7", handle: "@me@m.example"
        ))
        session.mastodon.refresh()
        session.lines.choose(true, host: Self.host)
        return (session, server, work)
    }

    private func lineActs(_ work: SourceWork) -> [SourceAct] {
        work.record.filter { $0.purpose == .line }
    }

    @Test("Home and direct posts are heard on one socket, each asked for on it by name, and one act on the record")
    func oneSocket() async throws {
        let sockets = HeldSockets()
        let (session, server, work) = try await make(sockets: sockets)
        let home = Task { await session.lines.hear([Self.host], in: session) }
        defer { home.cancel() }
        let open = await met("Home heard", by: home) { if case .open? = session.lines.standing[Self.host] { true } else { false } }
        try #require(open)
        await session.directs.show(Self.host, in: session)
        let direct = Task { await session.lines.hearDirect(Self.host, in: session) }
        defer { direct.cancel() }
        let both = await met("direct posts asked for", by: direct) { sockets.sent.contains(MastodonSocket.subscribe(.direct)) }
        try #require(both)

        #expect(sockets.opened == 1, "one socket for both")
        #expect(sockets.sent == [MastodonSocket.subscribe(.user), MastodonSocket.subscribe(.direct)])
        #expect(sockets.asked.first?.url?.absoluteString == "https://m.example/api/v1/streaming")
        #expect(sockets.asked.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(lineActs(work).count == 1, "one act on the record")
        #expect(session.lines.heldHosts == [Self.host], "held, so its filters are read again as Fediqo comes forward (#461)")

        sockets.told?.yield(Self.said("user", "update", payload: Self.status("2")))
        let landed = await met("a post told lands in Home", by: home) { session.lines.above == 1 }
        #expect(landed)
        let before = await server.asked.filter { $0 == "/api/v1/conversations" }.count
        sockets.told?.yield(Self.said("direct", "conversation", payload: "{}"))
        let read = await met("the conversations read again", by: direct) {
            await server.asked.filter { $0 == "/api/v1/conversations" }.count > before
        }
        #expect(read)
    }

    @Test("Leaving direct posts lets their stream go on the same socket; letting everything go closes it after a moment")
    func letGo() async throws {
        let sockets = HeldSockets()
        let linger = TurnedClock()
        let (session, _, work) = try await make(sockets: sockets, linger: linger)
        let home = Task { await session.lines.hear([Self.host], in: session) }
        defer { home.cancel() }
        let direct = Task { await session.lines.hearDirect(Self.host, in: session) }
        let both = await met("both asked for", by: direct) {
            sockets.sent.contains(MastodonSocket.subscribe(.direct)) && sockets.sent.contains(MastodonSocket.subscribe(.user))
        }
        try #require(both)

        direct.cancel()
        let left = await met("direct posts let go", by: home) { sockets.sent.contains(MastodonSocket.unsubscribe(.direct)) }
        #expect(left)
        #expect(sockets.opened == 1)
        #expect(session.lines.sockets.heldHosts.contains(Self.host), "Home is still heard on it")

        home.cancel()
        let lingering = await met("held a moment carrying nothing") { linger.sleeping == 1 }
        try #require(lingering)
        #expect(session.lines.sockets.heldHosts.contains(Self.host))
        linger.turn()
        let closed = await met("closed") { !session.lines.sockets.heldHosts.contains(Self.host) }
        #expect(closed)
        let ended = await met("its act ends") { self.lineActs(work).allSatisfy { $0.until != nil } }
        #expect(ended)
        #expect(lineActs(work).count == 1)
    }

    @Test("A stream let go and asked again within the moment opens nothing")
    func askedAgain() async throws {
        let sockets = HeldSockets()
        let linger = TurnedClock()
        let (session, _, _) = try await make(sockets: sockets, linger: linger)
        let first = Task { await session.lines.hearDirect(Self.host, in: session) }
        let asked = await met("asked for", by: first) { sockets.sent.contains(MastodonSocket.subscribe(.direct)) }
        try #require(asked)
        first.cancel()
        let lingering = await met("held a moment") { linger.sleeping == 1 }
        try #require(lingering)
        let again = Task { await session.lines.hearDirect(Self.host, in: session) }
        defer { again.cancel() }
        let twice = await met("asked again", by: again) { sockets.sent.filter { $0 == MastodonSocket.subscribe(.direct) }.count == 2 }
        #expect(twice)
        linger.turn()
        #expect(sockets.opened == 1, "the same socket")
        #expect(session.lines.sockets.heldHosts.contains(Self.host))
    }

    @Test("A source that will not open a socket is heard line by line, as before, and its page says so")
    func refusedSocket() async throws {
        let sockets = HeldSockets(refuse: 404)
        let lines = PathLines()
        let (session, _, _) = try await make(sockets: sockets, lines: lines)
        let home = Task { await session.lines.hear([Self.host], in: session) }
        defer { home.cancel() }
        let open = await met("Home heard on a line of its own", by: home) {
            if case .open? = session.lines.standing[Self.host] { true } else { false }
        }
        try #require(open)
        #expect(lines.told("/api/v1/streaming/user") != nil)
        #expect(session.lines.sockets.heardApart(Self.host))
        let direct = Task { await session.lines.hearDirect(Self.host, in: session) }
        defer { direct.cancel() }
        let apart = await met("direct posts on a line of their own", by: direct) { lines.told("/api/v1/streaming/direct") != nil }
        #expect(apart)
        #expect(sockets.asked.count == 1, "not asked again this run")
        #expect(LineControl.line(.open(since: Date()), host: Self.host, apart: true)
            == "The line to m.example is open, one for each thing heard: it would not carry them all on one.")
    }

    @Test("A socket that fails to open twice running, nothing answered, is not asked again: the lines are heard as before")
    func neverOpens() async throws {
        struct Failing: SocketOpener {
            func open(_ request: URLRequest) async throws -> OpenSocket { throw URLError(.badServerResponse) }
        }
        let lines = PathLines()
        let (session, _, _) = try await make(sockets: HeldSockets(), lines: lines)
        let sockets = ShellSockets(opener: Failing(), linger: {})
        let token = try #require(session.mastodon.token(host: Self.host))
        await #expect(throws: URLError.self) {
            _ = try await sockets.hear(.user, host: Self.host, token: token, work: session.mastodon.work)
        }
        #expect(!sockets.heardApart(Self.host), "once may be the network")
        let second = try await sockets.hear(.user, host: Self.host, token: token, work: session.mastodon.work)
        #expect(second == nil)
        #expect(sockets.heardApart(Self.host))
    }

    @Test("A socket that drops ends every stream it carried as a dropped line; the next ask opens it again")
    func dropped() async throws {
        let sockets = HeldSockets()
        let clock = TurnedClock()
        let (session, _, _) = try await make(sockets: sockets)
        session.lines = ShellLines(
            opener: PathLines(), sleep: clock.sleep, gather: {}, sockets: ShellSockets(opener: sockets, linger: {})
        )
        session.lines.choose(true, host: Self.host)
        let home = Task { await session.lines.hear([Self.host], in: session) }
        defer { home.cancel() }
        let open = await met("open", by: home) { if case .open? = session.lines.standing[Self.host] { true } else { false } }
        try #require(open)
        sockets.told?.finish(throwing: URLError(.networkConnectionLost))
        // Asleep on the wait, not only said to be waiting: a turn before the sleep wakes nothing.
        let waiting = await met("waiting after the drop", by: home) { clock.sleeping == 1 }
        try #require(waiting)
        #expect(session.lines.standing[Self.host] == .waiting)
        #expect(!session.lines.sockets.heldHosts.contains(Self.host))
        clock.turn()
        let again = await met("opened again", by: home) { sockets.opened == 2 }
        #expect(again)
    }
}
