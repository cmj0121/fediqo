import Foundation
import Synchronization
import Testing
@testable import FediqoCore

/// The reader's own line at a real Mastodon telling notices (#324), as `MastodonNoticeLineCaptures`
/// records it: a sign-in that reads notices is told each as it happens, and one the server holds
/// back is not told at all.
///
/// **Passed over unless asked for**, as `MastodonLineSaysTests` is.
@Suite("What a Mastodon tells of notices on the reader's own line", .enabled(if: LocalServers.streamingRequested), .serialized, .watched)
struct MastodonNoticeLineSaysTests {
    private static let host = LocalServers.mastodon

    private final class Heard: Sendable {
        private let events = Mutex<[LineEvent]>([])
        func add(_ event: LineEvent) { events.withLock { $0.append(event) } }
        var all: [LineEvent] { events.withLock { $0 } }
    }

    private func act(_ token: String, _ method: String, _ path: String, _ form: [(String, String)] = []) async throws -> [String: Any] {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

    @Test("A mention is told as a notice of one, read as the single read reads it; a private mention the server holds back is not told")
    func tellsNotices() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded()
        let hidden = try #require(seeded.people?.hidden.token, "a seed older than #309")
        let token = MastodonToken(host: Self.host, accessToken: seeded.writer, clientID: "", clientSecret: "")
        let events = try await MastodonLine(token: token, opener: try LocalHTTP.lines()).open()
        let heard = Heard()
        let reading = Task {
            do { for try await event in events { heard.add(event) } } catch {}
        }
        defer { reading.cancel() }
        let source = Source(host: Self.host, kind: .mastodon)

        let held = "just you \(UUID().uuidString.prefix(8))"
        _ = try await act(hidden, "POST", "/api/v1/statuses", [("status", "@fediqo \(held)"), ("visibility", "direct")])
        let words = "named \(UUID().uuidString.prefix(8))"
        let named = try #require(try await act(seeded.other, "POST", "/api/v1/statuses", [("status", "@fediqo \(words)")])["id"] as? String)

        let told = await met("the mention told on the line", by: reading) {
            heard.all.contains { MastodonNotices.told($0, source: source)?.post?.statusID == named }
        }
        try #require(told)
        let notice = try #require(heard.all.compactMap { MastodonNotices.told($0, source: source) }.first { $0.post?.statusID == named })
        #expect(notice.kind == .mention)
        #expect(notice.count == 1)
        guard case .one = notice.handle else {
            Issue.record("not a notice of one: \(notice.handle)")
            return
        }
        #expect(notice.people.first?.handle.contains("fediqo_other") == true)
        #expect(!heard.all.contains { $0.data.contains(held) }, "a mention held back is not told")
        _ = try await act(seeded.other, "DELETE", "/api/v1/statuses/\(named)")
    }

    @Test("The count is the source's own, falls when it is told, and is never moved back (#429)")
    func unreadCount() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded()
        let token = MastodonToken(host: Self.host, accessToken: seeded.writer, clientID: "", clientSecret: "")
        let door = MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: MemoryMastodonTokens())
        let notices = MastodonNotices(door: door)
        let source = Source(host: Self.host, kind: .mastodon)
        // The worker may still be handing over what an earlier check did: told again until quiet.
        let quiet = await met("the source says nothing is unread") {
            guard let newest = try? await notices.page(source: source, gathered: false).notices.first?.newestID else { return false }
            try? await notices.tellRead(upTo: newest)
            return (try? await notices.unreadCount()) == 0
        }
        try #require(quiet)
        try await notices.tellRead(upTo: "1")
        #expect(try await notices.unreadCount() == 0, "a lower place is not told: the source would have gone back")
    }

    @Test("A request let through with others in one ask leaves, the rest stay, and the source says when it has moved them (#431)")
    func requestsTogether() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded()
        let token = MastodonToken(host: Self.host, accessToken: seeded.writer, clientID: "", clientSecret: "")
        let notices = MastodonNotices(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: MemoryMastodonTokens()))
        let source = Source(host: Self.host, kind: .mastodon)
        // One of the seed's strangers: letting a person through stops holding them for good, so never
        // the one `tellsNotices` needs held. Each run uses one up, as the checks that dismiss do.
        let all = try await notices.requests(source: source)
        let chosen = Array(all.filter { $0.person.handle.contains("fediqo_stranger") }.prefix(2))
        try #require(chosen.count == 2, "seed the servers again")
        try await notices.letThrough(chosen)
        let after = try await notices.requests(source: source)
        #expect(!after.contains { chosen.contains($0) })
        #expect(Set(after.map(\.id)) == Set(all.map(\.id)).subtracting(chosen.map(\.id)), "the rest stay as they were")
        let merged = await met("the source finished") { (try? await notices.merged()) == true }
        #expect(merged)
    }
}
