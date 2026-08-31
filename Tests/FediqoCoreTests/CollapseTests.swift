import Foundation
import Testing
@testable import FediqoCore

/// What was collapsed, and why.
///
/// #5's last promise is about being wrong rather than being right: every other line of it is a
/// rule the app follows silently, and this is the one that says a reader must be able to check
/// it. So what is held here is that the list says which decision was made and on what grounds.
@Suite("What was collapsed, and why")
struct CollapseTests {
    private func carried(_ id: String, by host: String, origin: String) -> Post {
        makePost(uri: "https://\(host)/api/v1/statuses/\(id)",
                 originURI: origin, at: 100, from: host, text: "carried by two")
    }

    /// One post, two servers, and the address they agreed on — which is the reasoning, and the
    /// thing to look at first if the answer is ever wrong.
    @Test("Two servers agreeing on an address is a collapse, and it names the address")
    func agreementIsShown() async throws {
        let store = try LocalStore.inMemory()
        let origin = "https://elsewhere.test/users/x/statuses/5"
        for host in ["cx-a.test", "cx-b.test"] {
            try await store.save([carried("5", by: host, origin: origin)],
                                 from: Server(host: host, socialProtocol: .mastodon))
        }

        let collapses = try await store.collapses()
        #expect(collapses.count == 1)
        #expect(collapses[0].sources == ["cx-a.test", "cx-b.test"])
        #expect(collapses[0].reason == .sameAddress(origin))
        #expect(collapses[0].says == "carried by two")
    }

    /// The other reason, and it is a different kind of thing: not an inference from what two
    /// servers said, but a record of what this app did.
    @Test("A post this app published says so, rather than naming an address it agreed on")
    func publishingIsItsOwnReason() async throws {
        let hosts = ["cx-pub-a.test", "cx-pub-b.test"]
        for (index, host) in hosts.enumerated() {
            stubRoutes.on(host, "/api/v1/statuses", status: 200, body: """
            {
              "id": "\(index + 1)", "uri": "https://\(host)/users/ada/statuses/\(index + 1)",
              "url": "https://\(host)/@ada/\(index + 1)",
              "created_at": "2026-08-31T10:00:00.000Z", "content": "<p>sent from here</p>",
              "visibility": "public",
              "account": { "id": "1", "url": "https://\(host)/@ada", "username": "ada",
                           "acct": "ada", "display_name": "Ada", "avatar": null },
              "media_attachments": [], "tags": []
            }
            """)
        }
        let store = try LocalStore.inMemory()
        let actions = PostActions(registry: SourceRegistry(clients: [.mastodon: MastodonClient(session: stubbedSession())]),
                                  store: store)
        _ = await actions.publish(Draft(text: "sent from here"),
                                  as: hosts.map { ActingAccount(host: $0, authorId: "https://\($0)/@ada", token: "t") })

        let collapses = try await store.collapses()
        #expect(collapses.count == 1)
        #expect(collapses[0].reason == .published)
        #expect(Set(collapses[0].sources) == Set(hosts))
    }

    /// A post one server handed over is not a decision. The list is decisions, not posts.
    @Test("A post only one server carried is not in the list")
    func oneServerIsNotACollapse() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([makePost(uri: "https://cx-one.test/api/v1/statuses/1", at: 1,
                                       from: "cx-one.test")],
                             from: Server(host: "cx-one.test", socialProtocol: .mastodon))

        #expect(try await store.collapses().isEmpty)
    }

    /// And the one #5 forbids: a boost and its original were never one row, so they are never
    /// one entry here. Not filtered out — `mergeKey` carries the booster, so the question never
    /// arises.
    @Test("A boost and its original are not one collapse, because they were never one row")
    func aBoostIsNotItsOriginal() async throws {
        let store = try LocalStore.inMemory()
        let origin = "https://elsewhere.test/users/x/statuses/9"
        let original = makePost(uri: "https://cx-boost.test/api/v1/statuses/9",
                                originURI: origin, at: 100, from: "cx-boost.test")
        let boost = makePost(uri: "https://cx-boost.test/api/v1/statuses/10",
                             originURI: origin, at: 101, from: "cx-boost.test", boostedBy: "dag")
        try await store.save([original, boost],
                             from: Server(host: "cx-boost.test", socialProtocol: .mastodon))

        #expect(try await count(store, "SELECT count(*) FROM posts") == 2)
        #expect(try await store.collapses().isEmpty)
    }
}
