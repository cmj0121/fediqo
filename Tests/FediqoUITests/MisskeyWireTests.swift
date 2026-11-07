import Foundation
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
    private static let host = "misskey.example"
    private static let source = Source(host: host, kind: .misskey)
    private static let timeline = "/api/notes/local-timeline"

    private static let note = #"""
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
    private func shell(_ fixture: FixtureHTTP, holding sources: [Source]) async -> ShellSession {
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
}
