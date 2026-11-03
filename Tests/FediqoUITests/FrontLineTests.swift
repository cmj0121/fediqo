import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A source answering every timeline with nothing, and saying who the reader is; what was asked kept.
private actor FrontServer: HTTPSender {
    private(set) var asked: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        asked.append(path)
        let body = path.hasPrefix("/api/v1/accounts") ? #"{"id":"7","acct":"me"}"# : "[]"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// A list, a tag or the public timeline in front arrives as it happens (#460).
@MainActor
@Suite("A list, a tag or the public timeline in front arrives as it happens", .serialized, .watched)
struct FrontLineTests {
    private static let host = "m.example"
    private static let list = ListSubscription(id: "5", name: "Friends")
    private static let tag = PostTag("#Fediqo")!

    private static func status(_ id: String, words: String = "post") -> String {
        #"{"id":"\#(id)","uri":"https://m.example/users/ada/statuses/\#(id)","created_at":"2026-11-02T00:00:0\#(id.suffix(1)).000Z","content":"<p>\#(words) \#(id)</p>","account":{"username":"ada","acct":"ada","display_name":"Ada"}}"#
    }

    private static func said(_ stream: [String], _ event: String, payload: String) -> String {
        let frame: [String: Any] = ["stream": stream, "event": event, "payload": payload]
        return String(decoding: try! JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    private func make(sockets: HeldSockets = HeldSockets(), chosen: Bool = true) async throws -> (ShellSession, FrontServer) {
        let server = FrontServer()
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        session.lines = ShellLines(
            sleep: TurnedClock().sleep, gather: {}, sockets: ShellSockets(opener: sockets, linger: {})
        )
        await session.store.add(Source(host: Self.host, kind: .mastodon))
        await session.store.subscribe(host: Self.host, toLists: [Self.list])
        session.sources = await session.store.sources()
        let scopes = "read:statuses read:lists read:accounts"
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes,
            accountID: "7", handle: "@me@m.example"
        ))
        session.mastodon.refresh()
        if chosen { session.lines.choose(true, host: Self.host) }
        return (session, server)
    }

    private func want(_ stream: MastodonStream, tag: PostTag? = nil) -> ShellLines.FrontWant {
        ShellLines.FrontWant(host: Self.host, stream: stream, tag: tag)
    }

    // MARK: - What is wanted

    @Test("The lists a timeline in front reads are wanted, and the public timeline only where a rule names it; nothing not chosen, nor out of front")
    func wanted() async throws {
        let (session, _) = try await make()
        session.lines.front = ShellLines.Front(timeline: .all, inFront: true)
        #expect(session.lines.frontWants(running: true, in: session) == [want(.list(id: "5"))], "the usual reads: the list, not the public timeline")
        #expect(session.lines.frontWants(running: false, in: session).isEmpty)
        session.lines.front = ShellLines.Front(timeline: .all, inFront: false)
        #expect(session.lines.frontWants(running: true, in: session).isEmpty)
        session.lines.front = ShellLines.Front(timeline: .trends, inFront: true)
        #expect(session.lines.frontWants(running: true, in: session).isEmpty)

        let federated = TimelineDefinition(name: "Everyone", rules: [
            try #require(Rule.category(.public, in: .source(host: Self.host), sources: session.sources)),
        ])
        session.written = [federated]
        session.lines.front = ShellLines.Front(timeline: .written(federated.id), inFront: true)
        #expect(session.lines.frontWants(running: true, in: session) == [want(.federated)])

        let (unchosen, _) = try await make(chosen: false)
        unchosen.lines.front = ShellLines.Front(timeline: .all, inFront: true)
        #expect(unchosen.lines.frontWants(running: true, in: unchosen).isEmpty, "no line nobody chose")
    }

    @Test("A hashtag's page up wants its stream at the sources it asks")
    func tagWanted() async throws {
        let (session, _) = try await make()
        await session.reload.tag(Self.tag, timeline: .all, in: session)
        #expect(session.lines.frontWants(running: true, in: session) == [want(.hashtag(Self.tag), tag: Self.tag)])
        session.reload.endTag()
        #expect(session.lines.frontWants(running: true, in: session).isEmpty)
    }

    // MARK: - Heard

    @Test("A list in front is asked for on the one line by its id, read up to now first, and a post told lands in it, said above")
    func list() async throws {
        let sockets = HeldSockets()
        let (session, server) = try await make(sockets: sockets)
        let hearing = Task { await session.lines.hearFront([want(.list(id: "5"))], in: session) }
        defer { hearing.cancel() }
        let asked = await met("the list asked for", by: hearing) { sockets.sent.contains(MastodonSocket.subscribe(.list(id: "5"))) }
        try #require(asked)
        #expect(MastodonSocket.subscribe(.list(id: "5")) == #"{"list":"5","stream":"list","type":"subscribe"}"#)
        let caughtUp = await met("read up to now", by: hearing) { await server.asked.contains("/api/v1/timelines/list/5") }
        try #require(caughtUp)

        sockets.told?.yield(Self.said(["list", "5"], "update", payload: Self.status("2")))
        let landed = await met("the post lands", by: hearing) { session.lines.above == 1 }
        try #require(landed)
        let key = NoteKey(host: Self.host, id: "https://m.example/users/ada/statuses/2")
        #expect(await session.store.note(key)?.listed[.list(id: "5")] == "2")

        hearing.cancel()
        let left = await met("let go when it leaves") { sockets.sent.contains(MastodonSocket.unsubscribe(.list(id: "5"))) }
        #expect(left)
    }

    @Test("The public timeline in front is heard and read up to now as it opens")
    func federated() async throws {
        let sockets = HeldSockets()
        let (session, server) = try await make(sockets: sockets)
        let hearing = Task { await session.lines.hearFront([want(.federated)], in: session) }
        defer { hearing.cancel() }
        let caughtUp = await met("read up to now", by: hearing) { await server.asked.contains("/api/v1/timelines/public") }
        try #require(caughtUp)
        #expect(sockets.sent == [MastodonSocket.subscribe(.federated)])
        sockets.told?.yield(Self.said(["public"], "update", payload: Self.status("3")))
        let landed = await met("the post lands", by: hearing) { session.lines.above == 1 }
        try #require(landed)
        let key = NoteKey(host: Self.host, id: "https://m.example/users/ada/statuses/3")
        #expect(await session.store.note(key)?.categories == [.public])
    }

    @Test("A hashtag's page up hears its posts by the tag's name, lands them as the page holds them, and is no timeline read on")
    func hashtag() async throws {
        let sockets = HeldSockets()
        let (session, server) = try await make(sockets: sockets)
        let hearing = Task { await session.lines.hearFront([want(.hashtag(Self.tag), tag: Self.tag)], in: session) }
        defer { hearing.cancel() }
        let asked = await met("the tag asked for", by: hearing) { !sockets.sent.isEmpty }
        try #require(asked)
        #expect(sockets.sent == [#"{"stream":"hashtag","tag":"fediqo","type":"subscribe"}"#])
        sockets.told?.yield(Self.said(["hashtag", "Fediqo"], "update", payload: Self.status("4", words: "about #Fediqo")))
        let key = NoteKey(host: Self.host, id: "https://m.example/users/ada/statuses/4")
        let landed = await met("the post lands under the tag", by: hearing) {
            session.reload.sentUnderTag[HeldUnderTag.folded(Self.tag)]?.contains(key) == true
        }
        #expect(landed)
        #expect(await session.store.note(key)?.categories.isEmpty == true, "through no category, as the page's read")
        #expect(session.lines.above == 0, "nothing said above a timeline it is not in")
        #expect(await server.asked.allSatisfy { !$0.hasPrefix("/api/v1/timelines") }, "nothing read on")
    }

    @Test("Refused on a line of its own, a stream in front is not asked again this run")
    func refused() async throws {
        struct Refusing: LineOpener {
            func open(_ request: URLRequest) async throws -> OpenLine {
                let (events, told) = AsyncThrowingStream<LineEvent, any Error>.makeStream()
                told.finish()
                return OpenLine(
                    response: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, events: events
                )
            }
        }
        let (session, _) = try await make()
        session.lines = ShellLines(opener: Refusing(), sleep: TurnedClock().sleep, gather: {})
        session.lines.choose(true, host: Self.host)
        session.lines.front = ShellLines.Front(timeline: .all, inFront: true)
        await session.lines.hearFront([want(.list(id: "5"))], in: session)
        #expect(session.lines.frontWants(running: true, in: session).isEmpty)
    }
}
