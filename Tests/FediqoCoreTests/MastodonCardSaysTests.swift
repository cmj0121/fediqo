import Foundation
import Testing
@testable import FediqoCore

/// #335: what Fediqo makes of the preview a real Mastodon attaches to a post that links a page —
/// held against the one this checkout brings up with its worker (`FEDIQO_SERVERS_WORKER=1 make
/// servers`, Mastodon 4.6.6), every line of `MastodonCardCaptures`, through this app's own code:
/// the post written by `MastodonWrite.post`, read again by `MastodonPost.post(id:source:)`, and
/// landed in an `ItemStore` as any read lands.
///
/// **Passed over unless the worker was asked for**, and failing where it was asked for and does not
/// attach the card: only the worker fetches a page.
///
/// **This writes one post, and takes it back** however the check ends.
@Suite("What a Mastodon's worker attaches to a post that links a page", .enabled(if: LocalServers.workerRequested), .serialized)
struct MastodonCardSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    private static func door() throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: host, accessToken: try LocalServers.seeded().writer, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens)
    }

    @Test("A post that links the fixture's page is taken with no card; a moment later the source reads it with the page's preview, cleaned as this app reads every card, and the row takes it — and a read sent before it came does not take it away")
    func theWorkerAttachesIt() async throws {
        try await LocalServers.requireHealthy()
        let door = try Self.door()
        let store = ItemStore()
        await store.add(Self.source)
        let written = try await MastodonWrite(door: door, store: store)
            .post("a page to see http://card.example.com/ \(UUID().uuidString.prefix(8))", visibility: .unlisted)
        let id = try #require(written.statusID)
        let thrown: (any Error)?
        do {
            #expect(written.card == nil, "no preview as the post is taken: the worker fetches it after")
            // A read of the post sent now, before the worker has attached anything.
            let early = try await MastodonPost(door: door).post(id: id, source: Self.source)

            var read: Note?
            let gained = await met("the worker gives the post its preview") {
                try? await Task.sleep(for: .seconds(1))
                read = try? await MastodonPost(door: door).post(id: id, source: Self.source)
                return read?.card != nil
            }
            try #require(gained)
            let card = try #require(read?.card)
            #expect(card.title == "A page with a preview")
            #expect(card.description == "A page this machine serves, for a post to link to and gain a card.")
            #expect(card.provider == "Fediqo fixture" && card.author == nil && card.missingAttribution == false)
            #expect(card.url == nil, "an http page is no link this app follows")
            #expect(card.image?.host() == Self.host && card.width == 64 && card.height == 32)

            await store.refresh([try #require(read)], ifSourceHere: Self.host)
            #expect(await store.note(written.key)?.card == card)
            await store.refresh([early], ifSourceHere: Self.host)
            #expect(await store.note(written.key)?.card == card, "the read on its way says nothing of the card")
            thrown = nil
        } catch {
            thrown = error
        }
        _ = try? await door.delete(path: "/api/v1/statuses/\(id)")
        if let thrown { throw thrown }
    }
}
