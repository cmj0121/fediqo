import Foundation
import Testing
@testable import FediqoCore

/// #418: what Fediqo believes a Mastodon says of how it is doing, broken down and by who stays,
/// held against the real one this checkout brings up (`make servers`, Mastodon 4.6.6) — read
/// through this app's own reader, `MastodonAdminDashboard`. Nothing here changes anything.
@Suite("What a Mastodon says to those who tend it of how it is doing, broken down and by who stays", .enabled(if: LocalServers.requested), .serialized)
struct MastodonAdminDashboardSaysTests {
    private static let host = LocalServers.mastodon

    private static func reader(_ who: String) throws -> MastodonAdminDashboard {
        let data = try Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/mastodon-tokens.json"))
        let all = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tending = try #require(all["tending"] as? [String: Any], "seeded before tending was: run `make servers` again")
        let token = MastodonToken(
            host: host, accessToken: try #require((tending[who] as? [String: Any])?["token"] as? String), clientID: "x", clientSecret: "x"
        )
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return MastodonAdminDashboard(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    @Test("The Admin reads every breakdown over the last week — this server among the servers, Mastodon among the software, each store's space in bytes — and who stayed by month; the Moderator, whose role answers for the figures, reads them too; somebody with no such role is refused")
    func whatIsRead() async throws {
        try await LocalServers.requireHealthy()
        let admin = try Self.reader("admin")
        let said = try await admin.breakdowns(days: 7)
        #expect(said.notGiven.isEmpty)
        #expect(said.breakdown(.servers)?.rows.contains { $0.id == Self.host && ($0.figure ?? 0) > 0 } == true)
        #expect(said.breakdown(.software)?.rows.first { $0.id == "mastodon" }?.value.hasPrefix("4.") == true)
        #expect(said.breakdown(.space)?.rows.allSatisfy { $0.unit == "bytes" && $0.figure != nil } == true)
        let stayed = try await admin.retention(months: 3)
        #expect(stayed.cohorts.count == 3 && stayed.cohorts.map(\.points.count) == [3, 2, 1])
        #expect(stayed.cohorts.allSatisfy { $0.points.allSatisfy { (0...1).contains($0.rate) && $0.count >= 0 } })

        let mod = try Self.reader("mod")
        #expect(try await mod.breakdowns([.languages], days: 30).breakdown(.languages) != nil)
        let writer = try Self.reader("writer")
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await writer.breakdowns(days: 7) }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await writer.retention(months: 3) }
    }
}
