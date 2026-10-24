import Foundation
import Testing
@testable import FediqoCore

/// #384: what Fediqo believes a Mastodon says of what waits to rise on it, of how it is doing and
/// of its rules, held against the real one this checkout brings up (`make servers`, Mastodon
/// 4.6.6) — read and reviewed through this app's own reader, `MastodonAdminServer`.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`). **What a check reviews it
/// leaves kept back** — never let rise, so nothing another check reads begins to rise — and the
/// seed puts it back to waiting on its next run, which the checks of waiting ask for.
@Suite("What a Mastodon says to those who tend it of what rises, how it does, and its rules", .enabled(if: LocalServers.requested), .serialized)
struct MastodonAdminServerSaysTests {
    private static let host = LocalServers.mastodon

    private static func seeded() throws -> [String: Any] {
        let data = try Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/mastodon-tokens.json"))
        let all = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(all["tending"] as? [String: Any], "seeded before tending was: run `make servers` again")
    }

    private static func reader(_ who: String) throws -> MastodonAdminServer {
        let token = MastodonToken(
            host: host, accessToken: try #require((seeded()[who] as? [String: Any])?["token"] as? String), clientID: "x", clientSecret: "x"
        )
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return MastodonAdminServer(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    private static func waiting() throws -> [String: String] {
        try #require(seeded()["server"] as? [String: Any], "seeded before #384: run `make servers` again")
            .compactMapValues { $0 as? String }
    }

    @Test("The Admin reads a hashtag, a link and a post waiting to be reviewed, the figures of the last week and the rules in order; the Moderator, whose role answers for what rises and the figures, reads them too; somebody with no such role is refused")
    func whatIsRead() async throws {
        try await LocalServers.requireHealthy()
        let ids = try Self.waiting()
        let admin = try Self.reader("admin")
        for (kind, key) in [(RisingKind.tags, "tag"), (.links, "link"), (.posts, "post")] {
            let listed = try await admin.rising(kind).items
            let one = try #require(listed.first { $0.id == ids[key] }, "\(kind): run `make servers` again")
            #expect(one.waiting, "\(kind) waits for review — reviewed by a check before: run `make servers` again")
        }
        let said = try await admin.measures(days: 7)
        #expect(said.measures.map(\.key) == [.joined, .active, .reported] && said.measures.allSatisfy { $0.total >= 0 })
        #expect(try await admin.rules().map(\.text).suffix(2) == ["fediqo381seed rule", "fediqo384seed second rule"])

        let mod = try Self.reader("mod")
        #expect(try await !mod.rising(.tags).items.isEmpty)
        #expect(try await mod.measures(days: 30).measures.count == 3)
        let writer = try Self.reader("writer")
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await writer.measures(days: 7) }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await writer.review(.tags, ids["tag"] ?? "", rise: false) }
    }

    @Test("A hashtag let rise and then kept back, a link and a post kept back, each answer as the server then holds them; what is kept back is not among what the server tells anyone is rising")
    func keptBack() async throws {
        try await LocalServers.requireHealthy()
        let ids = try Self.waiting()
        let admin = try Self.reader("admin")
        let tag = try #require(ids["tag"]), link = try #require(ids["link"]), post = try #require(ids["post"])
        #expect(try await admin.review(.tags, tag, rise: true).rises == true)
        let kept = try await admin.review(.tags, tag, rise: false)
        #expect(!kept.waiting && kept.rises == false)
        #expect(try await admin.rising(.tags).items.first { $0.id == tag }?.rises == false)
        #expect(try await !admin.review(.links, link, rise: false).waiting)
        #expect(try await !admin.review(.posts, post, rise: false).waiting)
        #expect(try await admin.rising(.links).items.first { $0.id == link }?.waiting == false)

        let anyone = MastodonRising(http: try LocalHTTP.client(), host: Self.host)
        #expect(try await !anyone.tags().contains { $0.tag.name == "FediqoWaiting" })
        #expect(try await !anyone.links().contains { $0.link.host == "waiting.example" })
    }
}
