import Foundation
import Testing
@testable import FediqoCore

/// #419: what Fediqo believes a Mastodon says of the hashtags it knows and the sites its links
/// come from, held against the real one this checkout brings up (`make servers`, Mastodon
/// 4.6.6) — read and changed through this app's own reader, `MastodonAdminTaxonomies`.
///
/// **What is changed here is #419's own** (`servers/mastodon/seed.rb`): a hashtag and a site no
/// other check reads, never #384's. A check **leaves them kept back** — so nothing another check
/// reads begins to rise — and the seed puts them back to waiting on its next run.
@Suite("What a Mastodon says to those who tend it of the hashtags it knows and the sites its links come from", .enabled(if: LocalServers.requested), .serialized)
struct MastodonAdminTaxonomiesSaysTests {
    private static let host = LocalServers.mastodon
    private static let tagName = "Fediqo419"
    private static let site = "fediqo419.example"

    private static func reader(_ who: String) throws -> MastodonAdminTaxonomies {
        let data = try Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/mastodon-tokens.json"))
        let all = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tending = try #require(all["tending"] as? [String: Any], "seeded before tending was: run `make servers` again")
        let token = MastodonToken(
            host: host, accessToken: try #require((tending[who] as? [String: Any])?["token"] as? String), clientID: "x", clientSecret: "x"
        )
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return MastodonAdminTaxonomies(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    private static func every<Item>(_ read: (String?) async throws -> FederationStretch<Item>) async throws -> [Item] {
        var items: [Item] = [], next: String?
        repeat {
            let stretch = try await read(next)
            items += stretch.items
            next = stretch.next
        } while next != nil
        return items
    }

    @Test("The Admin reads #419's hashtag and site among all the server knows, each waiting; the Moderator, whose role answers for them, reads them too; somebody with no such role is refused")
    func whatIsRead() async throws {
        try await LocalServers.requireHealthy()
        let admin = try Self.reader("admin")
        let tag = try #require(try await Self.every { try await admin.tags(after: $0) }.first { $0.tag.tag.name == Self.tagName }, "run `make servers` again")
        #expect(tag.waiting && !tag.rises && tag.usable && tag.listable, "reviewed by a check before: run `make servers` again")
        let site = try #require(try await Self.every { try await admin.sites(after: $0) }.first { $0.domain == Self.site }, "run `make servers` again")
        #expect(site.waiting && site.rises == nil, "reviewed by a check before: run `make servers` again")

        let mod = try Self.reader("mod")
        #expect(try await !mod.tags().items.isEmpty)
        #expect(try await !mod.sites().items.isEmpty)
        let writer = try Self.reader("writer")
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await writer.tags() }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await writer.sites() }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await writer.changeTag(tag.id, rises: false) }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await writer.reviewSite(site.id, rise: false) }
    }

    @Test("A hashtag let rise and then kept back, unused and unlisted, and a site let rise and then kept back, each answer as the server then holds them, and read so after")
    func keptBack() async throws {
        try await LocalServers.requireHealthy()
        let admin = try Self.reader("admin")
        let tag = try #require(try await Self.every { try await admin.tags(after: $0) }.first { $0.tag.tag.name == Self.tagName })
        #expect(try await admin.changeTag(tag.id, rises: true).rises)
        let kept = try await admin.changeTag(tag.id, rises: false, usable: false, listable: false)
        #expect(!kept.rises && !kept.usable && !kept.listable && !kept.waiting)
        #expect(try await admin.tag(tag.id) == kept)

        let site = try #require(try await Self.every { try await admin.sites(after: $0) }.first { $0.domain == Self.site })
        #expect(try await admin.reviewSite(site.id, rise: true).rises == true)
        let back = try await admin.reviewSite(site.id, rise: false)
        #expect(back.rises == false && !back.waiting)
        #expect(try await Self.every { try await admin.sites(after: $0) }.first { $0.id == site.id }?.rises == false)
    }
}
