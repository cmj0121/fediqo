import Foundation
import Testing
@testable import FediqoCore

/// #92: the middle of a timeline a reader has already read.
///
/// A page is asked for by where it ends, so the timeline only ever asks two questions — the newest
/// page, and the page before the oldest thing it holds. Refreshing covers the top and paging walks
/// away from it, and nothing returns to what is between them. When a reader adds a server, or signs
/// in to one, or a server backfills from another, posts that belong in that stretch come into
/// existence and nobody goes and gets them.
///
/// These are the reproduction. They describe what a reader should be given and what the app
/// currently asks for, and the gap between the two is the bug.
@Suite("The middle of a timeline you have already read")
struct TheMiddleTests {
    private let path = "/api/v1/timelines/public"

    private var client: MastodonClient {
        MastodonClient(session: stubbedSession(), ledger: APILedger())
    }

    // MARK: - what the app can ask for today

    /// The whole of the vocabulary, as it stands. Two questions and no third one.
    @Test("A timeline can be asked for its newest page, or for what came before one post")
    func onlyTwoQuestions() async throws {
        let host = "middle-vocabulary.test"
        stubRoutes.on(host, path, status: 200, body: oneStatusJSON)

        _ = try await client.timeline(host: host, limit: 7, before: nil, token: nil)
        _ = try await client.timeline(host: host, limit: 7,
                                      before: handedOver("42", from: host), token: nil)

        #expect(stubRoutes.requests(for: host, path).map(\.query) == [
            ["limit": "7"],
            ["limit": "7", "max_id": "42"],
        ])
    }

    /// **The reproduction.** A stretch is two ends, and asking for one needs both of them said.
    ///
    /// Mastodon's word for the other end is `min_id`, and this app already speaks it — `notices`
    /// sends it for "newer than". A timeline cannot: there is no argument for it and no request
    /// that carries it, so the question "what is in the stretch I already hold" cannot be put.
    ///
    /// **This test fails until #92 is fixed**, and it is written as the shape the fix should take
    /// rather than as a description of the shape that is there.
    @Test("A stretch already read can be asked for again, by both of its ends")
    func aStretchCanBeAsked() async throws {
        let host = "middle-stretch.test"
        stubRoutes.on(host, path, status: 200, body: oneStatusJSON)

        _ = try await client.timeline(host: host, limit: 7,
                                      before: handedOver("42", from: host),
                                      after: handedOver("17", from: host), token: nil)

        #expect(stubRoutes.requests(for: host, path).map(\.query) == [
            ["limit": "7", "max_id": "42", "min_id": "17"],
        ])
    }

    /// One end and not the other is still a stretch: everything newer than something, with no
    /// older end named. It is what a server is asked after a gap has been noticed at the top.
    @Test("The newer end alone is a question too")
    func theNewerEndAlone() async throws {
        let host = "middle-after.test"
        stubRoutes.on(host, path, status: 200, body: oneStatusJSON)

        _ = try await client.timeline(host: host, limit: 7, before: nil,
                                      after: handedOver("17", from: host), token: nil)

        #expect(stubRoutes.requests(for: host, path).map(\.query) == [
            ["limit": "7", "min_id": "17"],
        ])
    }

    /// A cursor from somewhere else is refused at both ends, for the reason it always was: a
    /// number another server gave a post means nothing here, and sending it asks for a page
    /// nobody wanted.
    @Test("A foreign post is no more a stretch's end than it is a page's")
    func aForeignEndNeverLeaves() async throws {
        let host = "middle-foreign.test"
        stubRoutes.on(host, path, status: 200, body: oneStatusJSON)
        let elsewhere = handedOver("42", from: "somewhere.else.test")

        await #expect(throws: SourceFailure.self) {
            _ = try await client.timeline(host: host, limit: 7, before: nil,
                                          after: elsewhere, token: nil)
        }
        #expect(stubRoutes.requests(for: host, path).isEmpty)
    }
}
