import Foundation
import Testing
@testable import FediqoCore

/// What stays here, and for how long.
///
/// #7 asks for three things at once and this suite is mostly about the two it forbids: a
/// rotation that took what somebody kept, or what they wrote themselves, would be worse than no
/// rotation at all.
@Suite("What ages out, and what never does")
struct RotationTests {
    private let server = Server(host: "one.example", socialProtocol: .mastodon)
    /// A fixed present, so "a hundred days ago" means the same thing every run.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(_ id: String, daysAgo: Double) -> Post {
        makePost(uri: "https://one.example/api/v1/statuses/\(id)",
                 originURI: "https://one.example/users/a/statuses/\(id)",
                 at: now.addingTimeInterval(-daysAgo * 24 * 60 * 60).timeIntervalSince1970,
                 text: id)
    }

    private func stored(_ posts: [Post]) async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.save(posts, from: server)
        return store
    }

    private func left(_ store: LocalStore) async throws -> Set<String> {
        Set(try await store.timeline().map(\.text))
    }

    @Test("What is older than the window goes; what is inside it stays")
    func theWindowIsTheWindow() async throws {
        let store = try await stored([post("fresh", daysAgo: 10), post("stale", daysAgo: 100)])

        let gone = try await store.rotate(keeping: .month, now: now)

        #expect(gone == 1)
        #expect(try await left(store) == ["fresh"])
    }

    /// The promise the whole feature stands on. Age is not the question for a kept post.
    @Test("A kept post survives any rotation, however old")
    func keptSurvives() async throws {
        let old = post("kept", daysAgo: 900)
        let store = try await stored([old, post("unkept", daysAgo: 900)])
        try await store.keep(old.mergeKey, kept: true)

        try await store.rotate(keeping: .week, now: now)

        #expect(try await left(store) == ["kept"])
    }

    /// A post the reader wrote is not somebody else's timeline passing through. Rotating it out
    /// would be this app deleting their own writing to save room.
    @Test("A post this device published is not rotated out")
    func whatWasWrittenHereStays() async throws {
        let host = "rot-pub.test"
        stubRoutes.on(host, "/api/v1/statuses", status: 200, body: """
        {
          "id": "1", "uri": "https://\(host)/users/ada/statuses/1", "url": null,
          "created_at": "2026-01-01T10:00:00.000Z", "content": "<p>mine</p>",
          "visibility": "public",
          "account": { "id": "1", "url": "https://\(host)/@ada", "username": "ada",
                       "acct": "ada", "display_name": "Ada", "avatar": null },
          "media_attachments": [], "tags": []
        }
        """)
        let store = try LocalStore.inMemory()
        let actions = PostActions(registry: SourceRegistry(clients: [.mastodon: MastodonClient(session: stubbedSession())]),
                                  store: store)
        _ = await actions.publish(Draft(text: "mine"),
                                  as: [ActingAccount(host: host, authorId: "https://\(host)/@ada", token: "t")])
        try await store.save([post("theirs", daysAgo: 900)], from: server)

        try await store.rotate(keeping: .week, now: now)

        #expect(try await left(store) == ["mine"])
    }

    /// `forever` is a real answer, and it does nothing rather than a very large number of days.
    @Test("Forever keeps everything, however old")
    func foreverKeepsEverything() async throws {
        let store = try await stored([post("ancient", daysAgo: 5_000)])

        let gone = try await store.rotate(keeping: .forever, now: now)

        #expect(gone == 0)
        #expect(try await left(store) == ["ancient"])
    }

    /// The window is measured from when a post was written, not from when it arrived — so a
    /// post from last year that turned up this morning is a year old.
    @Test("Age is when it was written, not when it arrived")
    func ageIsWhenItWasWritten() async throws {
        let store = try LocalStore.inMemory()
        // Saved now; written a year ago.
        try await store.save([post("late", daysAgo: 365)], from: server, now: now)

        try await store.rotate(keeping: .month, now: now)

        #expect(try await left(store).isEmpty)
    }

    /// Every window the reader can choose is a window, and `forever` is the only one that is not.
    @Test("Every choice but forever has an end", arguments: Retention.allCases)
    func everyChoiceMeansSomething(choice: Retention) {
        #expect((choice.days == nil) == (choice == .forever))
        #expect((choice.cutoff(from: now) == nil) == (choice == .forever))
        if let cutoff = choice.cutoff(from: now) { #expect(cutoff < now) }
    }
}
