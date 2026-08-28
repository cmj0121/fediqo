import Foundation
import Testing
@testable import FediqoCore

/// A hostname is asked whether it is a Mastodon server before it is written down as one.
@Suite("Probing a server before trusting it")
struct MastodonClientTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    @Test("v2 answers, and its description arrives as plain text")
    func viaV2() async throws {
        let host = "v2.test"
        stubRoutes.on(host, "/api/v2/instance", status: 200, body: """
        {"domain": "v2.test", "title": "Vee Two", "description": "<p>A &amp; B</p>"}
        """)

        let instance = try await client.instance(host: "HTTPS://V2.test/")

        #expect(instance.host == host)
        #expect(instance.title == "Vee Two")
        #expect(instance.summary == "A & B")
    }

    @Test("Where v2 is missing, v1 is tried, and its short description is used")
    func fallsBackToV1() async throws {
        let host = "v1.test"
        stubRoutes.on(host, "/api/v2/instance", status: 404)
        stubRoutes.on(host, "/api/v1/instance", status: 200, body: """
        {"uri": "v1.test", "title": "Vee One", "short_description": "older"}
        """)

        let instance = try await client.instance(host: host)

        #expect(instance.title == "Vee One")
        #expect(instance.summary == "older")
        #expect(stubRoutes.paths(for: host) == ["/api/v2/instance", "/api/v1/instance"])
    }

    @Test("v2's picture, languages and monthly figure come back with it")
    func v2Metadata() async throws {
        let host = "rich.test"
        stubRoutes.on(host, "/api/v2/instance", status: 200, body: """
        {"domain": "rich.test", "title": "Rich", "description": "<p>Hello</p>",
         "thumbnail": {"url": "https://rich.test/thumb.png", "blurhash": "ignored"},
         "languages": ["en", "zh-TW"],
         "version": "4.4.0",
         "registrations": {"enabled": true, "approval_required": false},
         "rules": [{"id": "1", "text": "Be kind", "hint": "<p>Or &amp; else</p>"},
                   {"id": "2", "text": "No spam"},
                   {"id": "3", "text": ""}],
         "usage": {"users": {"active_month": 4321}}}
        """)

        let instance = try await client.instance(host: host)

        #expect(instance.thumbnailURL == URL(string: "https://rich.test/thumb.png"))
        #expect(instance.languages == ["en", "zh-TW"])
        #expect(instance.activeMonthlyUsers == 4321)
        #expect(instance.version == "4.4.0")
        #expect(instance.registrationsOpen == true)
        // A rule with no words is not a rule, and the hint arrives as plain text like the
        // description does.
        #expect(instance.rules == [InstanceRule(text: "Be kind", detail: "Or & else"),
                                   InstanceRule(text: "No spam", detail: nil)])
        // v2 counts nobody the older way, and says so by saying nothing.
        #expect(instance.totalUsers == nil)
        #expect(instance.posts == nil)
    }

    @Test("v1 spells the picture as a bare address and counts different things")
    func v1Metadata() async throws {
        let host = "old.test"
        stubRoutes.on(host, "/api/v2/instance", status: 404)
        stubRoutes.on(host, "/api/v1/instance", status: 200, body: """
        {"uri": "old.test", "title": "Old", "short_description": "older",
         "thumbnail": "https://old.test/thumb.png",
         "languages": ["ja"],
         "registrations": false,
         "stats": {"user_count": 99, "status_count": 12345}}
        """)

        let instance = try await client.instance(host: host)

        #expect(instance.thumbnailURL == URL(string: "https://old.test/thumb.png"))
        // v1 answers this with a bare yes or no rather than a dictionary, and it still reads.
        #expect(instance.registrationsOpen == false)
        #expect(instance.rules.isEmpty)
        #expect(instance.languages == ["ja"])
        #expect(instance.totalUsers == 99)
        #expect(instance.posts == 12345)
        // There is no monthly figure in the older API, and inventing one would be worse.
        #expect(instance.activeMonthlyUsers == nil)
    }

    @Test("A server that says none of it is still a server")
    func bareMetadata() async throws {
        let host = "bare.test"
        stubRoutes.on(host, "/api/v2/instance", status: 200, body: """
        {"domain": "bare.test", "title": "Bare"}
        """)

        let instance = try await client.instance(host: host)

        #expect(instance.title == "Bare")
        #expect(instance.thumbnailURL == nil)
        #expect(instance.languages.isEmpty)
        #expect(instance.activeMonthlyUsers == nil)
    }

    @Test("A host that answers as something else is refused")
    func notMastodon() async {
        let host = "elsewhere.test"
        stubRoutes.on(host, "/api/v2/instance", status: 500)
        stubRoutes.on(host, "/api/v1/instance", status: 500)

        await #expect(throws: SourceFailure.notThatKind(.mastodon, host)) {
            try await client.instance(host: host)
        }
    }

    @Test("Something that is not a hostname is refused before anything is asked of the network")
    func badHostNeverLeaves() async {
        await #expect(throws: SourceFailure.badHost("not a host")) {
            try await client.instance(host: "not a host")
        }
        #expect(stubRoutes.paths(for: "not a host").isEmpty)
    }

    @Test("Every failure can say something for itself")
    func everyFailureSpeaks() {
        let failures: [SourceFailure] = [
            .badHost("a.test"), .notThatKind(.mastodon, "a.test"), .unsupported(.nostr), .needsSignIn("a.test"),
            .tokenRejected("a.test"), .http(503, Data()), .transport("offline"),
        ]
        #expect(failures.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }
}
