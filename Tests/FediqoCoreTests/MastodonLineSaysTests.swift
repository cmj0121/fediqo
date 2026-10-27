import Foundation
import Synchronization
import Testing
@testable import FediqoCore

/// The reader's own line at a real Mastodon (#325), asked as `MastodonLineCaptures` records it:
/// opened by a sign-in of `read:statuses` alone, and told what the second person — whom the writer
/// follows — posts, changes and deletes. Each event lands in a store as a read of Home lands it.
///
/// **Passed over unless asked for**: the streaming service and the worker are both brought up only
/// where they are asked for (`FEDIQO_SERVERS_WORKER=1 FEDIQO_SERVERS_STREAMING=1 make servers`),
/// and the line tells nothing without the worker. Asked for and not up, it fails.
@Suite("What a Mastodon tells on the reader's own line", .enabled(if: LocalServers.streamingRequested), .watched)
struct MastodonLineSaysTests {
    private static let host = LocalServers.mastodon

    /// What the line has told so far, read on by a task of its own.
    private final class Heard: Sendable {
        private let events = Mutex<[LineEvent]>([])
        private let ended = Mutex(false)

        func add(_ event: LineEvent) { events.withLock { $0.append(event) } }
        func end() { ended.withLock { $0 = true } }
        var all: [LineEvent] { events.withLock { $0 } }
        var over: Bool { ended.withLock { $0 } }
    }

    private static func narrow() throws -> MastodonToken {
        let token = try #require(try LocalServers.seeded().people?.narrow?.token, "a seed older than #321")
        return MastodonToken(host: host, accessToken: token, clientID: "", clientSecret: "", scopes: "read:statuses")
    }

    private func act(_ method: String, _ path: String, _ form: [(String, String)] = []) async throws -> [String: Any] {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try LocalServers.seeded().other)", forHTTPHeaderField: "Authorization")
        if !form.isEmpty {
            var fields = URLComponents()
            fields.queryItems = form.map { URLQueryItem(name: $0.0, value: $0.1) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data((fields.percentEncodedQuery ?? "").utf8)
        }
        let (body, response) = try await LocalHTTP.client().send(request)
        #expect(response.statusCode == 200, "\(method) \(path): \(response.statusCode)")
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    @Test("Opened by a sign-in of read:statuses alone, the line tells a post, the post changed and the post deleted, each landing as Home's read lands it")
    func tellsHome() async throws {
        try await LocalServers.requireHealthy()
        let line = MastodonLine(token: try Self.narrow(), opener: try LocalHTTP.lines())
        let events = try await line.open()
        let heard = Heard()
        let reading = Task {
            do {
                for try await event in events { heard.add(event) }
            } catch {}
            heard.end()
        }
        defer { reading.cancel() }

        let source = Source(host: Self.host, kind: .mastodon)
        let store = ItemStore()
        await store.add(source)

        let words = "a line \(UUID().uuidString.prefix(8))"
        let id = try #require(try await act("POST", "/api/v1/statuses", [("status", words), ("visibility", "public")])["id"] as? String)
        let told = await met("the post told on the line", by: reading) {
            heard.all.contains { $0.name == "update" && $0.data.contains("\"id\":\"\(id)\"") }
        }
        try #require(told)
        let update = try #require(heard.all.first { $0.name == "update" && $0.data.contains("\"id\":\"\(id)\"") })
        guard case .arrived(let key, true) = await MastodonLine.land(update, of: source, in: store) else {
            Issue.record("the post did not land")
            return
        }
        let landed = try #require(await store.note(key))
        #expect(landed.categories == [.home])
        #expect(landed.listed[.home] == id)
        #expect(landed.body.contains(words))
        #expect(await store.newestListedID(host: Self.host, category: .home) == id)

        _ = try await act("PUT", "/api/v1/statuses/\(id)", [("status", "\(words), changed")])
        let changed = await met("the change told on the line", by: reading) {
            heard.all.contains { $0.name == "status.update" && $0.data.contains("\"id\":\"\(id)\"") }
        }
        try #require(changed)
        let change = try #require(heard.all.first { $0.name == "status.update" && $0.data.contains("\"id\":\"\(id)\"") })
        #expect(await MastodonLine.land(change, of: source, in: store) == .changed(key))
        #expect(await store.note(key)?.body.contains("changed") == true)

        _ = try await act("DELETE", "/api/v1/statuses/\(id)")
        let deleted = await met("the deletion told on the line", by: reading) {
            heard.all.contains { $0.name == "delete" && $0.data == id }
        }
        try #require(deleted)
        let delete = try #require(heard.all.first { $0.name == "delete" && $0.data == id })
        #expect(await MastodonLine.land(delete, of: source, in: store) == .gone([key]))
        #expect(await store.note(key)?.goneSince != nil)
        #expect(await MastodonLine.land(delete, of: source, in: store) == .gone([]), "told twice, marked once")
        #expect(!heard.over, "the line is still open")
    }

    @Test("With no sign-in, or one that is not, the line is refused 401 and nothing opens")
    func refused() async throws {
        try await LocalServers.requireHealthy()
        let stranger = MastodonToken(host: Self.host, accessToken: "not-a-token", clientID: "", clientSecret: "")
        await #expect(throws: MastodonLineRefused(status: 401)) {
            _ = try await MastodonLine(token: stranger, opener: try LocalHTTP.lines()).open()
        }
    }
}
