import Foundation
import Testing
@testable import FediqoCore

/// W0 (#333, #335): what a Mastodon does by itself once its worker runs beside its web process —
/// a post given a time goes out at that time with nobody asking, and a post that links a page
/// gains that page's preview. Neither happens on the server `make servers` brings up, which runs
/// no queued job but the ones its seed runs; both do with `FEDIQO_SERVERS_WORKER=1 make servers`.
///
/// **Passed over unless asked for**, and failing — not passing — where it was asked for and the
/// worker is not up: what only the worker does does not happen, and the wait for it is let go
/// when the run has gone still.
///
/// **The page linked** is `servers/card`, served by the fixture's Caddy as `card.example.com` to
/// whoever asks from inside the compose network, which is the worker and nothing on this machine.
///
/// **Not `.watched`.** One check waits out the five minutes the server makes a post wait, which
/// is as long as the run may be still; a wait parked over the whole check would be let go for it.
@Suite("What a Mastodon does with its worker running", .enabled(if: LocalServers.workerRequested))
struct MastodonWorkerSaysTests {
    private static let host = LocalServers.mastodon

    private struct Answer {
        let status: Int
        let body: Data

        var object: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var list: [[String: Any]] { (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] ?? [] }
        var error: String? { object["error"] as? String }
    }

    private func ask(_ method: String = "GET", _ path: String, _ form: [(String, String)] = []) async throws -> Answer {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(try LocalServers.seeded().writer)", forHTTPHeaderField: "Authorization")
        if !form.isEmpty {
            var fields = URLComponents()
            fields.queryItems = form.map { URLQueryItem(name: $0.0, value: $0.1) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data((fields.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        }
        let (body, response) = try await LocalHTTP.client().send(request)
        return Answer(status: response.statusCode, body: body)
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// The server's times, which carry milliseconds: `2026-10-20T23:30:37.000Z`.
    private static func date(_ text: Any?) -> Date? {
        guard let text = text as? String else { return nil }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Asks again a second after the last answer: the server is asked at a person's pace, and
    /// what is waited for is the server's own change, not a moment.
    private func paced<T>(_ look: () async throws -> T) async -> T? {
        try? await Task.sleep(for: .seconds(1))
        return try? await look()
    }

    @Test("A post given a time five minutes ahead is taken as a waiting post and refused nearer; at its time the worker publishes it with nobody asking, and it is waiting no more")
    func aPostGoesAtItsTime() async throws {
        try await LocalServers.requireHealthy()
        let words = "goes later \(UUID().uuidString.prefix(8))"

        let near = try await ask("POST", "/api/v1/statuses", [
            ("status", words), ("visibility", "public"), ("scheduled_at", Self.time(Date().addingTimeInterval(4 * 60))),
        ])
        #expect(near.status == 422, "a time four minutes ahead was taken")
        #expect(near.error == "Validation failed: Scheduled at date must be in the future")

        // Five minutes is the least the server takes, counted on its own clock as the post
        // arrives: fifteen seconds over it, for the ask to get there.
        let at = Date().addingTimeInterval(5 * 60 + 15)
        let made = try await ask("POST", "/api/v1/statuses", [
            ("status", words), ("visibility", "public"), ("scheduled_at", Self.time(at)),
        ])
        #expect(made.status == 200, "the waiting post was not taken: \(made.error ?? "")")
        let waiting = made.object
        let id = try #require(waiting["id"] as? String)
        #expect(waiting["status"] == nil, "a waiting post, not a post")
        let given = try #require(Self.date(waiting["scheduled_at"]))
        #expect(abs(given.timeIntervalSince(at)) < 1)
        #expect((waiting["params"] as? [String: Any])?["text"] as? String == words)
        #expect(try await ask("GET", "/api/v1/scheduled_statuses/\(id)").status == 200)

        // The one pause here that is a clock: it waits for nothing but the time the server was
        // given, before which nothing is to happen. The worker's own round comes every five
        // minutes and hands on whatever falls due in the five after it, so the post goes at its
        // time and not at the round's.
        try await Task.sleep(until: .now + .seconds(given.timeIntervalSinceNow), clock: .continuous)

        let gone = await met("the worker publishes the waiting post") {
            await paced { try await ask("GET", "/api/v1/scheduled_statuses/\(id)").status } == 404
        }
        try #require(gone)
        let me = try #require(try await ask("GET", "/api/v1/accounts/verify_credentials").object["id"] as? String)
        let own = try await ask("GET", "/api/v1/accounts/\(me)/statuses?limit=10").list
        let published = try #require(own.first { ($0["content"] as? String)?.contains(words) == true }, "published, and among the writer's own")
        let when = try #require(Self.date(published["created_at"]))
        #expect(when >= given.addingTimeInterval(-1), "not before its time: \(when) for \(given)")
        #expect(published["visibility"] as? String == "public")
    }

    @Test("A post that links a page with Open Graph tags gains that page's preview, fetched by the worker: its title, words, site, language, kind, address and picture with its size, and no author")
    func aLinkGainsItsPreview() async throws {
        try await LocalServers.requireHealthy()
        let made = try await ask("POST", "/api/v1/statuses", [
            ("status", "a page to see http://card.example.com/ \(UUID().uuidString.prefix(8))"), ("visibility", "public"),
        ])
        #expect(made.status == 200, "the post was not taken: \(made.error ?? "")")
        let id = try #require(made.object["id"] as? String)
        // Mostly no preview as the post is taken — the worker fetches it after — but the worker can
        // be quicker than the answer: a card already there is the preview, and nothing is waited for.
        var card = made.object["card"] as? [String: Any] ?? [:]
        let gained = await met("the worker gives the post its preview") {
            guard card.isEmpty else { return true }
            guard let found = await paced({ try await ask("GET", "/api/v1/statuses/\(id)").object["card"] as? [String: Any] }) ?? nil
            else { return false }
            card = found
            return true
        }
        try #require(gained)
        #expect(card["url"] as? String == "http://card.example.com/")
        #expect(card["title"] as? String == "A page with a preview")
        #expect(card["description"] as? String == "A page this machine serves, for a post to link to and gain a card.")
        #expect(card["provider_name"] as? String == "Fediqo fixture")
        // The page names no author the server reads, so the preview names none and is not said
        // to want one.
        #expect(card["author_name"] as? String == "" && (card["authors"] as? [Any])?.isEmpty == true)
        #expect(card["missing_attribution"] as? Bool == false)
        #expect(card["language"] as? String == "en")
        #expect(card["type"] as? String == "link")
        #expect(card["width"] as? Int == 64 && card["height"] as? Int == 32)
        let picture = try #require(card["image"] as? String, "the picture, kept by the server")
        #expect(URL(string: picture)?.host() == Self.host)
        #expect((card["blurhash"] as? String)?.isEmpty == false)
    }
}
