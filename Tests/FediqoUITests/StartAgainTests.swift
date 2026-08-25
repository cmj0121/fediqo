import Foundation
import GRDB
import Testing
import FediqoCore
@testable import FediqoUI

/// Starting again: the one thing in the app allowed to destroy what a network handed over,
/// because it is the reader asking for their device back.
@Suite("Starting again")
@MainActor
struct StartAgainTests {
    private func stocked(_ name: String) async throws -> (AppState, LocalStore) {
        let store = try LocalStore.inMemory()
        let server = Server(host: "one.example", socialProtocol: .mastodon, title: "One")
        try await store.save([Post(uri: "https://one.example/1", socialProtocol: .mastodon,
                                   sourceURL: server.endpoint, createdAt: Date(timeIntervalSince1970: 100),
                                   authorId: "https://one.example/users/ada", authorName: "Ada",
                                   authorHandle: "@ada@one.example", text: "hello")],
                             from: server)
        let preferences = Preferences(defaults: scratch(name))
        preferences.theme = .light
        preferences.showBoosts = false
        preferences.offeredHomeTimeline = true
        let app = AppState(preferences: preferences, serverStore: EmptyServerStore(), store: store)
        app.add(server)
        await app.openTimelines()
        return (app, store)
    }

    @Test("Everything on the device goes: posts, servers, timelines, preferences")
    func everythingGoes() async throws {
        let (app, store) = try await stocked("start-again-everything")
        var made = TimelineTemplate.named("tag")!.timeline(named: "Swift", about: "swift")
        made.summary = "posts about Swift"
        app.add(made)
        await app.settled()
        #expect(try await count(store, "SELECT count(*) FROM posts") == 1)

        await app.startAgain()
        await app.settled()

        #expect(try await count(store, "SELECT count(*) FROM posts") == 0)
        #expect(try await count(store, "SELECT count(*) FROM servers") == 0)
        #expect(app.servers.isEmpty)
        // The store is a database again rather than an empty file: the schema is back, and the
        // timelines a fresh install ships with are in it.
        #expect(try await store.timelines().map(\.template) == ["public", "trend"])
        #expect(app.timelines.map(\.template) == ["public", "trend"])
        // Preferences are what a first launch would have given them.
        #expect(app.preferences.theme == .dark)
        #expect(app.preferences.showBoosts)
        #expect(app.preferences.offeredHomeTimeline == false)
        // And the reader is back at the beginning.
        #expect(app.route == .landing)
    }

    @Test("A write still in flight cannot land in the fresh store")
    func nothingSurvivesTheErase() async throws {
        let (app, store) = try await stocked("start-again-inflight")
        // Made and erased in the same breath, with the save not yet on disk.
        app.add(TimelineTemplate.named("tag")!.timeline(named: "Swift", about: "swift"))
        await app.startAgain()
        await app.settled()

        #expect(try await store.timelines().map(\.template) == ["public", "trend"])
    }
}

/// One number out of the store — the UI suites' own copy, since `PostFixtures` is Core's.
private func count(_ store: LocalStore, _ sql: String) async throws -> Int {
    try await store.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
}
