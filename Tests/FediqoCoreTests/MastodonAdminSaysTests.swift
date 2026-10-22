import Foundation
import Testing
@testable import FediqoCore

/// #380 and #381: what Fediqo believes a Mastodon says to those who answer for it, held against
/// the real one this checkout brings up (`make servers`, Mastodon 4.6.6) — read through this
/// app's own readers, `MastodonWho` and `MastodonAdminReports`.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`): an Admin and a Moderator,
/// the writer holding tending's words with no standing, and two open reports. **What a check
/// changes it puts back**: a report taken on, closed or opened again ends as the seed left it,
/// and the seed puts it back on every run besides.
@Suite("What a Mastodon says to those who answer for it", .enabled(if: LocalServers.requested), .serialized)
struct MastodonAdminSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    private struct Seeded {
        let admin: String
        let mod: String
        let writer: String
        let reports: [String]
    }

    private static func seeded() throws -> Seeded {
        let data = try Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/mastodon-tokens.json"))
        let all = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tending = try #require(all["tending"] as? [String: Any], "seeded before tending was: run `make servers` again")
        func token(_ who: String) throws -> String {
            try #require((tending[who] as? [String: Any])?["token"] as? String)
        }
        return Seeded(
            admin: try token("admin"), mod: try token("mod"), writer: try token("writer"),
            reports: try #require(tending["reports"] as? [String])
        )
    }

    private static func door(_ accessToken: String) throws -> MastodonAuthorized {
        let token = MastodonToken(host: host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens)
    }

    private func status(_ path: String, as accessToken: String) async throws -> Int {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await LocalHTTP.client().send(request).1.statusCode
    }

    @Test("The standing each account's check says is the one the server holds it to: the Admin and the Moderator read the reports, the Moderator is refused the servers it blocks, and the writer — holding tending's words, with everybody's role — is refused both and has no standing for any task")
    func standingIsTheRole() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let admin = try #require(try await Self.door(seeded.admin).who().staff)
        let mod = try #require(try await Self.door(seeded.mod).who().staff)
        let writer = try #require(try await Self.door(seeded.writer).who().staff)
        #expect(admin.allows(.manageReports) && admin.allows(.manageFederation))
        #expect(mod.allows(.manageReports) && !mod.allows(.manageFederation))
        #expect(!writer.allows(.manageReports) && !writer.allows(.manageFederation) && !writer.allows(.manageUsers))

        for (token, reports, servers) in [(seeded.admin, 200, 200), (seeded.mod, 200, 403), (seeded.writer, 403, 403)] {
            #expect(try await status("/api/v1/admin/reports", as: token) == reports)
            #expect(try await status("/api/v1/admin/domain_blocks", as: token) == servers)
        }
        await #expect(throws: MastodonAdminError.notAllowed) {
            try await MastodonAdminReports(door: try Self.door(seeded.writer)).stretch(resolved: false)
        }
    }

    @Test("The open reports are read whole and read on to the end; one is taken on, handed back, closed — and is then among the closed and not the open — and opened again, each answered with the report as it now stands; the writer is refused the act")
    func readAndActedOn() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let reports = MastodonAdminReports(door: try Self.door(seeded.admin))
        var open = try await reports.stretch(resolved: false)
        var all = open.reports
        while let next = open.next {
            open = try await reports.stretch(resolved: false, after: next)
            all += open.reports
        }
        #expect(Set(seeded.reports).isSubset(of: Set(all.map(\.id))), "every seeded report is open")
        let id = try #require(seeded.reports.first)
        let seen = try #require(all.first { $0.id == id })
        #expect(seen.category == "violation" && seen.rules == ["fediqo381seed rule"] && seen.posts.count == 1)
        #expect(seen.reporter?.handle == "@fediqo_other@\(Self.host)" && seen.target?.handle == "@fediqo_person@\(Self.host)")

        await #expect(throws: MastodonAdminError.notAllowed) {
            try await MastodonAdminReports(door: try Self.door(seeded.writer)).act(.close, on: id)
        }
        let taken = try await reports.act(.take, on: id)
        #expect(taken.takenBy == "@fediqo_admin@\(Self.host)")
        #expect(try await reports.act(.handBack, on: id).takenBy == nil)
        let closed = try await reports.act(.close, on: id)
        #expect(closed.closed)
        let resolved = try await reports.stretch(resolved: true).reports.map(\.id)
        let stillOpen = try await reports.stretch(resolved: false).reports.map(\.id)
        #expect(resolved.contains(id) && !stillOpen.contains(id))
        let reopened = try await reports.act(.reopen, on: id)
        #expect(!reopened.closed && reopened.takenBy == nil)
        let again = try await reports.report(id)
        #expect(again.id == id && !again.closed)
    }
}
