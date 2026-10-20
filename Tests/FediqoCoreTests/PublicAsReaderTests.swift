import Foundation
import Testing

@testable import FediqoCore

/// The public timeline read as the reader (#283): through the sign-in's door where the client was
/// handed one for its own host, and without a token otherwise.
@Suite("The public timeline is read as the reader where a sign-in is handed in")
struct PublicAsReaderCoreTests {
    private static let host = "social.example"

    /// Answers every ask with `status` and `body`, and keeps each request as it came.
    actor Recorder: HTTPClient, HTTPSender {
        private let status: Int
        private let body: String
        private(set) var requests: [URLRequest] = []

        init(status: Int = 200, body: String = "[]") {
            self.status = status
            self.body = body
        }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            try await send(URLRequest(url: url))
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let url = request.url!
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    private func door(_ sender: Recorder, host: String = host) -> MastodonAuthorized {
        MastodonAuthorized(
            token: MastodonToken(host: host, accessToken: "tok", clientID: "c", clientSecret: "s"),
            sender: sender, store: MemoryMastodonTokens()
        )
    }

    private let source = Source(host: host, kind: .mastodon)

    @Test("Through a sign-in, every ask of the public timeline carries it, and none goes without")
    func carries() async throws {
        let bare = Recorder()
        let signed = Recorder()
        let client = MastodonClient(http: bare, host: Self.host).reading(as: door(signed))

        _ = try await client.publicTimeline(source: source, readingOnFrom: "100")
        _ = try await client.publicTimeline(source: source, olderThan: "50")

        let asked = await signed.requests
        #expect(asked.count >= 2)
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
        #expect(asked.allSatisfy { $0.url?.path == "/api/v1/timelines/public" && $0.url?.host() == Self.host })
        #expect(asked.contains { $0.url?.query?.contains("min_id=99") == true })
        #expect(asked.contains { $0.url?.query?.contains("max_id=50") == true })
        #expect(await bare.requests.isEmpty)
    }

    @Test("Without one, the public timeline is asked bare")
    func bare() async throws {
        let bare = Recorder()
        _ = try await MastodonClient(http: bare, host: Self.host).publicTimeline(source: source)
        let asked = await bare.requests
        #expect(asked.count == 1)
        #expect(asked.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A sign-in to another host is never handed this host's asks")
    func otherHost() async throws {
        let bare = Recorder()
        let signed = Recorder()
        let client = MastodonClient(http: bare, host: Self.host).reading(as: door(signed, host: "other.example"))
        _ = try await client.publicTimeline(source: source)
        #expect(await signed.requests.isEmpty)
        #expect(await bare.requests.count == 1)
    }

    @Test("A 422 to an ask made bare is the source asking a sign-in; the same through a sign-in is not")
    func refusal() async throws {
        let said = #"{"error":"This method requires an authenticated user"}"#
        let bare = MastodonClient(http: Recorder(status: 422, body: said), host: Self.host)
        let thrown = await #expect(throws: MastodonRequestError.http(422)) {
            try await bare.publicTimeline(source: source, readingOnFrom: nil)
        }
        #expect(thrown.map(MastodonClient.asksSignIn) == true)

        let signed = Recorder(status: 422, body: said)
        let asYou = MastodonClient(http: Recorder(), host: Self.host).reading(as: door(signed))
        let refused = await #expect(throws: MastodonAuthError.http(422)) {
            try await asYou.publicTimeline(source: source, readingOnFrom: nil)
        }
        #expect(refused.map(MastodonClient.asksSignIn) == false)
    }
}
