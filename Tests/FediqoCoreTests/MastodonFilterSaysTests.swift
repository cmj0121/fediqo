import Foundation
import Testing
@testable import FediqoCore

/// The person's filters at a real Mastodon (#338), as `MastodonFilterCaptures` records them: made,
/// changed and removed through `MastodonFilters` by the writer's full sign-in, and acting for
/// another reader of the same account — the writer's sign-in of `read:statuses` alone — which is
/// told which filter caught a post and may not see the filters themselves.
@Suite("What a Mastodon says of the person's filters", .enabled(if: LocalServers.requested), .watched)
struct MastodonFilterSaysTests {
    private static let host = LocalServers.mastodon

    private func door(_ token: String) throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        let held = MastodonToken(host: Self.host, accessToken: token, clientID: "", clientSecret: "")
        try tokens.save(held)
        return MastodonAuthorized(token: held, sender: try LocalHTTP.client(), store: tokens)
    }

    @Test("A filter made here is told of a post read by another reader of the account; changed keyword by keyword; removed, and removed again is done; a sign-in without the part is refused")
    func tended() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded()
        let narrow = try #require(seeded.people?.narrow?.token, "a seed older than #321")
        let filters = MastodonFilters(door: try door(seeded.writer))
        let word = "quince\(UUID().uuidString.prefix(6).lowercased())"
        let made = try await filters.make(ServerFilterDraft(
            title: "Said here", context: ["home", "public"], action: .warn, lasts: 3600,
            keywords: [.init(keyword: word, wholeWord: true), .init(keyword: "pear\(word)", wholeWord: false)]
        ))
        #expect(made.title == "Said here" && made.action == .warn && made.expiresAt != nil)
        #expect(made.keywords.map(\.keyword) == [word, "pear\(word)"])

        let other = MastodonAuthorized(
            token: MastodonToken(host: Self.host, accessToken: seeded.other, clientID: "", clientSecret: ""),
            sender: try LocalHTTP.client(), store: MemoryMastodonTokens()
        )
        let posted = try JSONSerialization.jsonObject(with: try await other.post(
            path: "/api/v1/statuses", form: [("status", "a \(word) tart"), ("visibility", "public")]
        )) as? [String: Any]
        let id = try #require(posted?["id"] as? String)
        let read = try await door(narrow).get(path: "/api/v1/statuses/\(id)")
        let note = try MastodonJSON.decoder.decode(StatusDTO.self, from: read)
            .asNote(source: Source(host: Self.host, kind: .mastodon), category: .public, sent: .now())
        #expect(note.serverFiltered?.map(\.filterID) == [made.id], "acts for another reader of the account")

        var draft = ServerFilterDraft(
            title: "Said here, changed", context: ["home"], action: .hide, lasts: nil,
            keywords: [.init(id: made.keywords[0].id, keyword: word, wholeWord: false), .init(keyword: "plum\(word)", wholeWord: true)]
        )
        let changed = try await filters.change(made, to: draft)
        #expect(changed.title == "Said here, changed" && changed.action == .hide && changed.expiresAt == nil)
        #expect(changed.keywords.map(\.keyword) == [word, "plum\(word)"])
        #expect(changed.keywords.first?.wholeWord == false)

        draft.title = ""
        await #expect(throws: MastodonFilterRefused.self) { _ = try await filters.change(changed, to: draft) }
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await MastodonFilters(door: door(narrow)).list() }

        try await filters.remove(changed)
        try await filters.remove(changed)
        #expect(try await filters.list().allSatisfy { $0.id != made.id })
        _ = try await other.delete(path: "/api/v1/statuses/\(id)")
    }
}
