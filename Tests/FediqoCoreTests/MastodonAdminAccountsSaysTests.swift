import Foundation
import Testing
@testable import FediqoCore

/// #382: what Fediqo believes a Mastodon says of its accounts to those who answer for it, held
/// against the real one this checkout brings up (`make servers`, Mastodon 4.6.6) — read and acted
/// on through this app's own reader, `MastodonAdminAccounts`.
///
/// **Everything here is seeded** (`servers/mastodon/seed.rb`): three sign-ups waiting, one this
/// check lets in and one it turns away — which the server deletes — and somebody it acts on and
/// takes each act back from, **never the writer**. **What a check changes is put back**: every
/// act is taken back here, and the seed lets the two sign-ups wait again on its next run; a run
/// that finds them already let in or turned away says to seed again.
@Suite("What a Mastodon says of its accounts to those who answer for it", .enabled(if: LocalServers.requested), .serialized)
struct MastodonAdminAccountsSaysTests {
    private static let host = LocalServers.mastodon

    private struct Seeded {
        let admin: String
        let mod: String
        let writer: String
        let waiting: [String: String]
        let actedOn: String
    }

    private static func seeded() throws -> Seeded {
        let data = try Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/mastodon-tokens.json"))
        let all = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tending = try #require(all["tending"] as? [String: Any], "seeded before tending was: run `make servers` again")
        func token(_ who: String) throws -> String { try #require((tending[who] as? [String: Any])?["token"] as? String) }
        let waiting = try #require(tending["waiting"] as? [String: [String: String]], "seeded before #382: run `make servers` again")
        return Seeded(
            admin: try token("admin"), mod: try token("mod"), writer: try token("writer"),
            waiting: waiting.compactMapValues { $0["id"] },
            actedOn: try #require((tending["actedOn"] as? [String: String])?["id"])
        )
    }

    private static func reader(_ accessToken: String) throws -> MastodonAdminAccounts {
        let token = MastodonToken(host: host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return MastodonAdminAccounts(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    @Test("Those waiting are read with what they wrote, by the Admin and the Moderator alike; found by name; and refused to the writer, whose role answers for nothing")
    func whoWaits() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let stays = try #require(seeded.waiting["stays"])
        for token in [seeded.admin, seeded.mod] {
            let waiting = try await Self.reader(token).stretch(AdminAccountFilter(state: .pending))
            let one = try #require(waiting.accounts.first { $0.id == stays })
            #expect(one.waiting && one.reason == "I read the rules and would like to write here." && one.person?.handle == "@asks_382@\(Self.host)")
        }
        let found = try await Self.reader(seeded.admin).stretch(AdminAccountFilter(state: .active, words: "acted_382"))
        #expect(found.accounts.map(\.id) == [seeded.actedOn])
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await Self.reader(seeded.writer).stretch(AdminAccountFilter()) }
    }

    @Test("Somebody waiting is let in, and is then no longer waiting; somebody turned away is gone from the server")
    func letInAndTurnedAway() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let admin = try Self.reader(seeded.admin)
        let letIn = try #require(seeded.waiting["letIn"]), away = try #require(seeded.waiting["turnedAway"])
        let before = try await admin.stretch(AdminAccountFilter(state: .pending)).accounts.map(\.id)
        try #require(Set([letIn, away]).isSubset(of: Set(before)), "a run before let them in or turned them away: run `make servers` again")
        let approved = try await admin.approve(letIn)
        #expect(approved.approved && !approved.waiting)
        try await admin.reject(away)
        let after = try await admin.stretch(AdminAccountFilter(state: .pending)).accounts.map(\.id)
        #expect(!after.contains(letIn) && !after.contains(away))
        await #expect(throws: MastodonAuthError.http(404)) { _ = try await admin.account(away) }
    }

    @Test("Each act shows on the account as the server then holds it — warned, marked sensitive, frozen, limited, suspended — and each that can be taken back is, leaving it held in nothing; the writer is refused every one")
    func actsAndTakingBack() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let admin = try Self.reader(seeded.admin)
        let id = seeded.actedOn
        try await admin.act(.warn, on: id, words: "fediqo382 a warning", tell: false)
        for act in AccountAct.allCases where act.undoes {
            try await admin.act(act, on: id, words: "fediqo382 \(act.rawValue)", tell: false)
            #expect(try await admin.account(id).holds(act), "\(act)")
            let back = try await admin.undo(act, on: id)
            #expect(!back.holds(act), "\(act) taken back")
        }
        let now = try await admin.account(id)
        #expect(!now.disabled && !now.silenced && !now.suspended && !now.sensitized)
        await #expect(throws: MastodonAdminError.notAllowed) {
            try await Self.reader(seeded.writer).act(.limit, on: id, words: "", tell: false)
        }
    }
}
