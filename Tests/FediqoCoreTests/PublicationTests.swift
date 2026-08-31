import Foundation
import Testing
@testable import FediqoCore

/// One composed post, several accounts, and the record of what went where.
@Suite("What went where")
struct PublicationTests {
    private func account(_ host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/@ada", token: "t")
    }

    private func answering(_ hosts: [String], refusing: Set<String> = [], id: String = "9") {
        for host in hosts {
            if refusing.contains(host) {
                stubRoutes.on(host, "/api/v1/statuses", status: 422, body: #"{"error":"no"}"#)
            } else {
                stubRoutes.on(host, "/api/v1/statuses", status: 200, body: """
                {
                  "id": "\(id)", "uri": "https://\(host)/users/ada/statuses/\(id)",
                  "url": "https://\(host)/@ada/\(id)",
                  "created_at": "2026-08-31T10:00:00.000Z", "content": "<p>hello</p>",
                  "visibility": "public",
                  "account": { "id": "1", "url": "https://\(host)/@ada", "username": "ada",
                               "acct": "ada", "display_name": "Ada", "avatar": null },
                  "media_attachments": [], "tags": []
                }
                """)
            }
        }
    }

    private func wired() throws -> (PostActions, LocalStore) {
        let store = try LocalStore.inMemory()
        return (PostActions(registry: SourceRegistry(clients: [.mastodon: MastodonClient(session: stubbedSession())]),
                            store: store), store)
    }

    @Test("One post, three accounts, one action")
    func onePostToThree() async throws {
        let hosts = ["went-a.test", "went-b.test", "went-c.test"]
        answering(hosts)
        let (actions, _) = try wired()

        let sent = await actions.publish(Draft(text: "hello"), as: hosts.map(account))

        #expect(sent.count == 3)
        let allWent = sent.allSatisfy(\.went)
        #expect(allWent)
        #expect(sent.map(\.host) == hosts)      // in the order they were given
        for host in hosts {
            #expect(stubRoutes.requests(for: host, "/api/v1/statuses").count == 1)
        }
    }

    /// A row per destination, and that record is what #5 collapses on: three posts on three
    /// servers that agree about nothing, known to be one because this app sent them.
    @Test("What went where is written down, and can be asked of any of them")
    func theRecordIsKept() async throws {
        let hosts = ["record-a.test", "record-b.test"]
        answering(hosts)
        let (actions, store) = try wired()

        let sent = await actions.publish(Draft(text: "hello"), as: hosts.map(account))
        let first = try #require(sent.first?.post)
        let second = try #require(sent.last?.post)
        // Two posts, two servers, and nothing about their addresses says they are one.
        #expect(first.mergeKey != second.mergeKey)

        let everywhere = try await store.published(with: first.mergeKey)
        #expect(everywhere.count == 2)
        #expect(Set(everywhere.map(\.serverURL)) == Set(hosts.map { "https://\($0)" }))
        // Asked of either of them, the answer is the same: this is one composed post.
        let fromTheOther = try await store.published(with: second.mergeKey)
        #expect(fromTheOther.count == 2)
    }

    /// A partial failure is a list of what happened, never a whole that succeeded or failed.
    @Test("One server refusing does not stop the others, and reports itself")
    func aRefusalIsItsOwn() async throws {
        let hosts = ["part-a.test", "part-b.test", "part-c.test"]
        answering(hosts, refusing: ["part-b.test"])
        let (actions, store) = try wired()

        let sent = await actions.publish(Draft(text: "hello"), as: hosts.map(account))

        #expect(sent.filter(\.went).map(\.host) == ["part-a.test", "part-c.test"])
        let refused = try #require(sent.first { !$0.went })
        #expect(refused.host == "part-b.test")
        #expect(refused.failure != nil)

        // Nothing is retried anywhere else: the one that refused was asked once, and the two
        // that took it were asked once each.
        for host in hosts {
            #expect(stubRoutes.requests(for: host, "/api/v1/statuses").count == 1)
        }
        // And nothing was written down about the one that did not happen.
        let went = try #require(sent.first?.post)
        let recorded = try await store.published(with: went.mergeKey)
        #expect(recorded.count == 2)
    }

    /// The half of #8 that is easy to get backwards: a server that will not take it says so
    /// **before** sending, not after.
    @Test("A server that will not take it says so before a word is sent")
    func refusedBeforeSending() async throws {
        let roomy = "long-roomy.test"
        let narrow = "long-narrow.test"
        stubRoutes.on(roomy, "/api/v2/instance", status: 200, body: """
        {"domain": "\(roomy)", "title": "Roomy", "configuration": {"statuses": {"max_characters": 500}}}
        """)
        stubRoutes.on(narrow, "/api/v2/instance", status: 200, body: """
        {"domain": "\(narrow)", "title": "Narrow", "configuration": {"statuses": {"max_characters": 10}}}
        """)
        let (actions, _) = try wired()
        let draft = Draft(text: String(repeating: "a", count: 40))

        let refusals = await actions.refusals(of: draft, from: [account(roomy), account(narrow)])

        #expect(refusals[roomy] == nil)
        #expect(refusals[narrow] == .tooLong(narrow, 10))
        // Asked, and nothing sent: the reader chooses again rather than finding out afterwards.
        let asked = stubRoutes.paths(for: narrow).contains { $0.contains("/api/v1/statuses") }
        #expect(!asked)
    }

    /// A server that says nothing about its limit is a server this cannot speak for. It is left
    /// alone rather than held to a number of ours.
    @Test("A server that never said its limit is not refused on our authority")
    func silenceIsNotARefusal() async throws {
        let quiet = "long-quiet.test"
        stubRoutes.on(quiet, "/api/v2/instance", status: 200, body: """
        {"domain": "\(quiet)", "title": "Quiet"}
        """)
        let (actions, _) = try wired()

        let refusals = await actions.refusals(of: Draft(text: String(repeating: "a", count: 9_000)),
                                              from: [account(quiet)])
        #expect(refusals.isEmpty)
    }

    @Test("A draft of nothing goes nowhere, and every destination says so")
    func nothingGoesNowhere() async throws {
        let hosts = ["empty-a.test", "empty-b.test"]
        let (actions, _) = try wired()

        let sent = await actions.publish(Draft(text: "  "), as: hosts.map(account))

        #expect(sent.count == 2)
        let allEmpty = sent.allSatisfy { $0.failure == .emptyDraft }
        #expect(allEmpty)
        let nothingSent = hosts.allSatisfy { stubRoutes.paths(for: $0).isEmpty }
        #expect(nothingSent)
    }
}
