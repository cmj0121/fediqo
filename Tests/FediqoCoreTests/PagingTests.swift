import Foundation
import Testing
@testable import FediqoCore

/// Asking for what came before: the one cursor is a post already read, and each side of the
/// app turns it into its own words — Mastodon's `max_id`, the store's `(posted_at, merge_key)`.
@Suite("Asking a server for what came before")
struct SourcePagingTests {
    private let path = "/api/v1/timelines/public"

    private var client: MastodonClient {
        MastodonClient(session: stubbedSession(), ledger: APILedger())
    }

    /// A post as `host` would have handed it over — the address `asPost` writes.
    private func handedOver(_ id: String, from host: String) -> Post {
        makePost(uri: "https://\(host)/api/v1/statuses/\(id)", at: 100, from: host)
    }

    @Test("Without a cursor the newest page is asked for, exactly as it always was")
    func newestPageSaysNothingMore() async throws {
        let host = "newest.paging.test"
        stubRoutes.on(host, path, status: 200, body: oneStatusJSON)

        _ = try await client.timeline(host: host, limit: 7, before: nil, token: nil)

        #expect(stubRoutes.requests(for: host, path).map(\.query) == [["limit": "7"]])
    }

    @Test("A cursor is sent as max_id, read out of the address the server itself handed over")
    func cursorBecomesMaxId() async throws {
        let host = "cursor.paging.test"
        stubRoutes.on(host, path, status: 200, body: oneStatusJSON)

        _ = try await client.timeline(host: host, limit: 7, before: handedOver("42", from: host), token: nil)

        #expect(stubRoutes.requests(for: host, path).map(\.query) == [["limit": "7", "max_id": "42"]])
    }

    @Test("A boost pages by the number the server gave the boost, like any other row")
    func aBoostIsAnOrdinaryCursor() throws {
        let host = "boost.paging.test"
        let boost = makePost(uri: "https://\(host)/api/v1/statuses/99",
                             originURI: "https://elsewhere.test/users/a/statuses/1",
                             at: 100, from: host, boostedBy: "someone else")

        #expect(try MastodonClient.statusId(of: boost, on: host) == "99")
    }

    @Test("A cursor that is not a status on this server is refused, and nothing is sent")
    func aForeignCursorNeverLeaves() async throws {
        let refusing = "refuse.paging.test"
        stubRoutes.on(refusing, path, status: 200, body: oneStatusJSON)
        // What another protocol's post looks like, and what another Mastodon server's does:
        // neither carries a number this server could be asked about.
        let strangers = [
            makePost(uri: "at://did:plc:abc/app.bsky.feed.post/3k", at: 100, from: refusing, socialProtocol: .atProto),
            handedOver("7", from: "other.test"),
        ]

        for stranger in strangers {
            await #expect(throws: SourceFailure.notItsPost(stranger.uri)) {
                try await client.timeline(host: refusing, limit: 7, before: stranger, token: nil)
            }
        }
        #expect(stubRoutes.requests(for: refusing, path).isEmpty)
    }
}

/// The store read a page at a time, backwards, with nothing skipped and nothing repeated.
@Suite("Reading the store back a page at a time")
struct StorePagingTests {
    private let one = Server(host: "one.example", socialProtocol: .mastodon, title: "One")

    private func uri(_ id: String) -> String { "https://one.example/api/v1/statuses/\(id)" }

    /// Six posts, two of them posted in the same millisecond — the case `merge_key` is in the
    /// index for. Newest first, the order is 5, 4, 3a, 3b, 2, 1.
    private func stocked() async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.save([
            makePost(uri: uri("5"), at: 500),
            makePost(uri: uri("4"), at: 400),
            makePost(uri: uri("3a"), at: 300),
            makePost(uri: uri("3b"), at: 300),
            makePost(uri: uri("2"), at: 200),
            makePost(uri: uri("1"), at: 100),
        ], from: one)
        return store
    }

    @Test("Without a cursor, the newest page, exactly as it always was")
    func noCursorIsTheNewestPage() async throws {
        let store = try await stocked()

        let page = try await store.timeline(limit: 2)

        #expect(page.map(\.uri) == [uri("5"), uri("4")])
    }

    @Test("Page after page reads the whole timeline once: no post skipped, none read twice")
    func pagesJoinWithoutSeamOrHole() async throws {
        let store = try await stocked()
        let whole = try await store.timeline()

        var paged: [Post] = []
        var cursor: Post?
        while true {
            let page = try await store.timeline(limit: 2, before: cursor)
            guard !page.isEmpty else { break }
            paged += page
            cursor = page.last
        }

        #expect(paged == whole)
        #expect(Set(paged.map(\.mergeKey)).count == paged.count)
    }

    @Test("A page boundary inside one instant neither repeats the post before it nor skips the one after")
    func oneInstantAcrossTwoPages() async throws {
        let store = try await stocked()

        let first = try await store.timeline(limit: 3)
        let second = try await store.timeline(limit: 3, before: first.last)

        // The boundary falls between two posts sharing a timestamp: `posted_at` alone could
        // not tell them apart, so one of them would have been lost or handed over twice.
        #expect(first.map(\.uri) == [uri("5"), uri("4"), uri("3a")])
        #expect(second.map(\.uri) == [uri("3b"), uri("2"), uri("1")])
    }

    @Test("Before the oldest post there is nothing, and it says so rather than starting again")
    func pastTheEndIsEmpty() async throws {
        let store = try await stocked()
        let whole = try await store.timeline()

        #expect(try await store.timeline(limit: 2, before: whole.last).isEmpty)
    }
}
