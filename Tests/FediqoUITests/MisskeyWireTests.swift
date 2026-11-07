import Foundation
import os
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Misskey is asked by POST, and the wire a reload builds once could only GET: `wire` handed back
/// a `Deadline` over a client, which has no sender, and a POST through it failed at run time
/// rather than at the compiler (#486). What is pinned here is the stack the app really builds —
/// listed, bounded, gated and, for a join, stopped by a Remove — carrying the request whole.
@MainActor
@Suite("A Misskey is asked by POST through the wired stack", .watched)
struct MisskeyWireTests {
    fileprivate nonisolated static let host = "misskey.example"
    private static let source = Source(host: host, kind: .misskey)
    private static let timeline = "/api/notes/local-timeline"

    fileprivate nonisolated static let note = #"""
    [{
      "id": "9xk2a1b2c3", "createdAt": "2026-11-06T09:15:30.123Z",
      "user": { "id": "9aaa", "username": "wren", "name": "Wren", "host": null, "avatarUrl": null },
      "text": "Kettle's on.", "cw": null, "files": [], "repliesCount": 0, "renoteCount": 0,
      "uri": null, "url": null
    }]
    """#

    private static func routes() -> [String: FixtureHTTP.Outcome] {
        [
            "/": .text(#"<html><body><script>window.__misskey_boot__ = {};</script></body></html>"#),
            timeline: .text(note),
            "/api/meta": .text(#"{"name":"Misskey Example","description":"A kettle."}"#),
        ]
    }

    /// A session over `fixture`, holding `sources`.
    private func shell(_ fixture: any HTTPClient, holding sources: [Source]) async -> ShellSession {
        let store = ItemStore()
        for source in sources { await store.add(source) }
        let session = ShellSession(http: fixture, store: store)
        session.deadlinesUnturned()
        // Governed, as the app's is: only the sources added, and a host the person named, pass.
        let work = SourceWork()
        work.govern(sources: sources.map(\.host))
        session.work = work
        await session.reloadFromStore()
        return session
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The local timeline goes out as one POST with its limit, and its place below where one is given")
    func aTimelineIsPosted() async throws {
        let fixture = FixtureHTTP(Self.routes())
        let session = await shell(fixture, holding: [Self.source])
        let client = session.reach.misskey(Self.host, for: .timeline, within: .seconds(10))

        let notes = try await client.localTimeline(source: Self.source)
        #expect(notes.map(\.id) == ["misskey:\(Self.host):9xk2a1b2c3"])
        let first = try #require(await fixture.sent.first)
        #expect(await fixture.sent.count == 1)
        #expect(first.httpMethod == "POST")
        #expect(first.url?.path == Self.timeline)
        #expect(first.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let asked = try Self.body(first)
        #expect(asked["limit"] as? Int == MisskeyClient.limit)
        #expect(asked["untilId"] == nil, "the newest is asked with no place at all")

        _ = try await client.localTimeline(source: Self.source, untilID: "9xk2a1b2c3")
        let below = try Self.body(try #require(await fixture.sent.last))
        #expect(below["untilId"] as? String == "9xk2a1b2c3")
    }

    @Test("A host that is no source is not asked: the gate refuses the POST as it refuses a GET")
    func aStrangerIsRefused() async {
        let fixture = FixtureHTTP(Self.routes())
        let session = await shell(fixture, holding: [])
        let client = session.reach.misskey(Self.host, for: .timeline, within: .seconds(10))

        await #expect(throws: OutwardRefusal.noSource) {
            _ = try await client.localTimeline(source: Self.source)
        }
        #expect(await fixture.sent.isEmpty)
    }

    @Test("A join of a Misskey asks what it says of itself and its local timeline, both by POST")
    func aJoinPosts() async throws {
        let fixture = FixtureHTTP(Self.routes())
        let session = await shell(fixture, holding: [])
        session.hostname = Self.host
        await session.add()
        #expect(session.stage?.inlinePreview?.host == Self.host, "the premise: the look came back")
        await session.confirm()

        let posts = await fixture.sent.filter { $0.httpMethod == "POST" }.compactMap(\.url?.path)
        #expect(posts.contains("/api/meta"))
        #expect(posts.contains(Self.timeline))
        #expect(await session.store.sources() == [Self.source])
    }

    @Test("Every ask of a Misskey is kept to its host: a POST redirected off it is refused, not carried on with its body, and the timeline keeps a Mastodon's ceiling")
    func aRedirectOffTheHostIsRefused() throws {
        let sent = try #require(SourceReach.misskeySent(URLSessionClient()) as? URLSessionClient)
        #expect(sent.sameOriginOnly && sent.byteLimit == URLSessionClient.defaultByteLimit)
        var post = URLRequest(url: URL(string: "https://\(Self.host)\(Self.timeline)")!)
        post.httpMethod = "POST"
        post.httpBody = Data(#"{"limit":40}"#.utf8)
        #expect(!CappedBody.mayFollow(from: post, to: URL(string: "https://\(MovedOff.elsewhere)\(Self.timeline)")!, sameOriginOnly: sent.sameOriginOnly))
        #expect(CappedBody.mayFollow(from: post, to: URL(string: "https://\(Self.host)/moved")!, sameOriginOnly: sent.sameOriginOnly))
    }

    @Test("On the live client, a Misskey that points its POSTs at another host is not followed there: not by a reload, not by the look, not by the join")
    func theLiveWireStaysOnTheHost() async throws {
        let configuration = URLSessionClient.memoryOnlyConfiguration()
        configuration.protocolClasses = [MovedOff.self]
        let live = URLSessionClient(session: URLSession(configuration: configuration))
        MovedOff.reset()
        defer { MovedOff.reset() }

        let read = await shell(live, holding: [Self.source])
        await #expect(throws: (any Error).self, "a reload followed the redirect") {
            _ = try await read.reach.misskey(Self.host, for: .timeline, within: .seconds(10)).localTimeline(source: Self.source)
        }
        #expect(MovedOff.asked.contains(Self.timeline), "the premise: the timeline was asked of its host")

        let join = await shell(live, holding: [])
        join.hostname = Self.host
        await join.add()
        let preview = try #require(join.stage?.inlinePreview, "the premise: the look came back")
        guard case .unread = preview.profile else {
            Issue.record("the look read what another host said: \(preview.profile)")
            return
        }
        #expect(MovedOff.asked.contains("/api/meta"), "the premise: the look asked its host")
        await join.confirm()
        #expect(await join.store.sources().isEmpty, "the join landed a timeline another host gave")
        #expect(MovedOff.asked.filter { $0 == Self.timeline }.count == 2, "the premise: the join asked its host")

        #expect(MovedOff.followed.isEmpty, "a POST was carried to another host: \(MovedOff.followed)")
    }

    @Test("What a Misskey says of itself at a look is held to a small body: an answer past it is not read, and the timeline that follows still is")
    func anOversizedMetaIsRefused() async throws {
        let look = try #require(SourceReach.misskeyLook(URLSessionClient()) as? URLSessionClient)
        #expect(look.byteLimit == SourceReach.smallBody && look.sameOriginOnly)

        var routes = Self.routes()
        let words = String(repeating: "kettle ", count: SourceReach.smallBody / 6)
        routes["/api/meta"] = .text(#"{"name":"Misskey Example","description":"\#(words)"}"#)
        let fixture = FixtureHTTP(routes)
        let session = await shell(fixture, holding: [])
        session.hostname = Self.host
        await session.add()
        let preview = try #require(session.stage?.inlinePreview, "the premise: the look came back")
        guard case .unread = preview.profile else {
            Issue.record("an answer past the small body was read: \(preview.profile)")
            return
        }
        #expect(await fixture.sent.contains { $0.url?.path == "/api/meta" }, "the premise: it was asked")
        await session.confirm()
        #expect(await session.store.sources() == [Self.source], "the timeline is not held to the look's ceiling")
    }
}

/// A Misskey that answers its page as one and moves every POST to another host with a 307 — the
/// redirect that carries the method and the body on. The other host answers as a Misskey would,
/// so an ask that followed would succeed and say so; what it was asked is kept in `followed`.
private final class MovedOff: URLProtocol, @unchecked Sendable {
    static let elsewhere = "elsewhere.example"

    private struct Heard {
        var asked: [String] = []
        var followed: [String] = []
    }

    private static let heard = OSAllocatedUnfairLock(initialState: Heard())

    /// The paths asked of the Misskey itself, in order.
    static var asked: [String] { heard.withLock { $0.asked } }
    /// The paths asked of the other host — none, where every redirect was refused.
    static var followed: [String] { heard.withLock { $0.followed } }

    static func reset() {
        heard.withLock { $0 = Heard() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path
        guard url.host() == MisskeyWireTests.host else {
            Self.heard.withLock { $0.followed.append(path) }
            answer(url, 200, path == "/api/meta" ? #"{"name":"Elsewhere"}"# : MisskeyWireTests.note)
            return
        }
        Self.heard.withLock { $0.asked.append(path) }
        guard request.httpMethod == "POST" else {
            answer(url, path == "/" ? 200 : 404, #"<html><body><script>window.__misskey_boot__ = {};</script></body></html>"#)
            return
        }
        var moved = request
        moved.url = URL(string: "https://\(Self.elsewhere)\(path)")
        let response = HTTPURLResponse(
            url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": moved.url!.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: moved, redirectResponse: response)
        // A declined redirect leaves this protocol holding the task: finish it, or the request
        // sits until it times out.
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func answer(_ url: URL, _ status: Int, _ body: String) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
