import Foundation
import Testing
@testable import FediqoCore

/// A post sent to three servers is one row, and the row can say all three.
///
/// This is #5's rule with better evidence. Two servers carrying somebody else's post are
/// collapsed because they agree on a canonical address — an inference. A post this app sent to
/// three accounts is three posts whose addresses agree about nothing, and it is one because
/// this app was there.
@Suite("One entry, however many places")
struct OneEntryTests {
    private let hosts = ["one-a.test", "one-b.test", "one-c.test"]

    private func account(_ host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/@ada", token: "t")
    }

    /// Each server makes its own post with its own number, so nothing about the three addresses
    /// suggests they are one.
    private func answering(_ hosts: [String]) {
        for (index, host) in hosts.enumerated() {
            stubRoutes.on(host, "/api/v1/statuses", status: 200, body: """
            {
              "id": "\(index + 100)", "uri": "https://\(host)/users/ada/statuses/\(index + 100)",
              "url": "https://\(host)/@ada/\(index + 100)",
              "created_at": "2026-08-31T10:00:00.000Z", "content": "<p>hello</p>",
              "visibility": "public",
              "account": { "id": "1", "url": "https://\(host)/@ada", "username": "ada",
                           "acct": "ada", "display_name": "Ada", "avatar": null },
              "media_attachments": [], "tags": []
            }
            """)
        }
    }

    private func wired() throws -> (PostActions, LocalStore) {
        let store = try LocalStore.inMemory()
        return (PostActions(registry: SourceRegistry(clients: [.mastodon: MastodonClient(session: stubbedSession())]),
                            store: store), store)
    }

    @Test("Three servers, one row, and the row says three")
    func onePostThreePlaces() async throws {
        answering(hosts)
        let (actions, store) = try wired()

        let sent = await actions.publish(Draft(text: "hello"), as: hosts.map(account))
        #expect(sent.count == 3)

        // One row in `posts`, whatever the three servers called it.
        #expect(try await count(store, "SELECT count(*) FROM posts") == 1)

        // And the row says every place it went — the same `sources` a post carried by two
        // servers has always had, reached the same way.
        let timeline = try await store.timeline()
        #expect(timeline.count == 1)
        #expect(Set(timeline[0].sources) == Set(hosts))
    }

    /// From the moment it is sent, not from the next refresh: the row is one row before
    /// anything is read back from anybody.
    @Test("It is one row before any server is read")
    func oneRowFromTheStart() async throws {
        answering(hosts)
        let (actions, store) = try wired()

        _ = await actions.publish(Draft(text: "hello"), as: hosts.map(account))

        #expect(try await store.timeline().count == 1)
        #expect(try await count(store, "SELECT count(*) FROM post_origins") == 3)
    }

    /// The one that matters weeks later: a copy read back through a home timeline carries that
    /// server's own address and nothing else, and still folds into the row it belongs to.
    @Test("A copy read back from one of them folds into the row it belongs to")
    func aCopyComingBackIsNotAStranger() async throws {
        answering(hosts)
        let (actions, store) = try wired()
        _ = await actions.publish(Draft(text: "hello"), as: hosts.map(account))

        // What server C's own home timeline would hand back about the post it made: its own
        // number, its own canonical address, and no idea that two other servers have it too.
        let comingBack = try MastodonClient.decoder.decode([MastodonDTO.Status].self, from: Data("""
        [{
          "id": "102", "uri": "https://one-c.test/users/ada/statuses/102",
          "url": "https://one-c.test/@ada/102",
          "created_at": "2026-08-31T10:00:00.000Z", "content": "<p>hello</p>",
          "visibility": "public",
          "account": { "id": "1", "url": "https://one-c.test/@ada", "username": "ada",
                       "acct": "ada", "display_name": "Ada", "avatar": null },
          "media_attachments": [], "tags": []
        }]
        """.utf8)).map { $0.asPost(from: "one-c.test") }
        // On its own it is a different post entirely.
        #expect(comingBack[0].mergeKey != (try await store.timeline()[0].mergeKey))

        try await store.save(comingBack, from: Server(host: "one-c.test", socialProtocol: .mastodon),
                             into: .home, as: "https://one-c.test/@ada")

        #expect(try await count(store, "SELECT count(*) FROM posts") == 1)
        #expect(try await store.timeline().count == 1)
    }

    /// Nothing changes for a post this app did not send. Two servers carrying somebody else's
    /// post collapse the way they always did, by the address they agree on.
    @Test("Somebody else's post is merged exactly as it was")
    func nothingChangesForAnybodyElse() async throws {
        let (_, store) = try wired()
        let carried = ["else-a.test", "else-b.test"].map { host in
            makePost(uri: "https://\(host)/api/v1/statuses/5",
                     originURI: "https://elsewhere.test/users/x/statuses/5", at: 1, from: host)
        }
        for post in carried {
            try await store.save([post], from: Server(host: LocalStore.host(of: post.sourceURL),
                                                      socialProtocol: .mastodon))
        }

        #expect(try await count(store, "SELECT count(*) FROM posts") == 1)
        #expect(try await count(store, "SELECT count(*) FROM publications") == 0)
        #expect(Set(try await store.timeline()[0].sources) == Set(["else-a.test", "else-b.test"]))
    }
}
