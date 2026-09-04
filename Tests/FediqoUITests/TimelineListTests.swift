import Foundation
import GRDB
import Testing
import FediqoCore
@testable import FediqoUI

/// The row of timelines: what a fresh install has, what the reader does to it, and what
/// happens to the app's own state when they delete the one they were reading.
@Suite("The timelines the reader has")
@MainActor
struct TimelineListTests {
    @Test("A fresh install has the public timeline and trending, and no home")
    func shipped() {
        let app = freshApp("timelines-shipped")
        #expect(app.timelines.map(\.id) == ["public", "trend"])
        // Home is not among them: with nobody signed in anywhere there is no home to read,
        // and a page that can only ever be empty is not something to hand somebody first.
        #expect(app.timelines.allSatisfy { !$0.source.needsAccount })
    }

    /// **What these can and cannot check.** SwiftPM copies `Localizable.xcstrings` into the
    /// bundle without compiling it, so under `swift test` every lookup answers with its own
    /// key; only an Xcode build has the words. So these hold the mechanism — a timeline that
    /// ships carries no words of its own and asks its template, one the reader named carries
    /// theirs — and the words themselves are checked on a running app.
    @Test("The ones that ship carry no words of their own, and ask their template")
    func shippedNamesComeFromTheTemplate() {
        let app = freshApp("timelines-language")
        #expect(app.timelines.allSatisfy { $0.name.isEmpty && $0.summary.isEmpty })
        #expect(app.timelines.map(\.displayName) == [t("template.public.name"), t("template.trend.name")])
        #expect(app.timelines.map(\.displaySummary) == [t("template.public.summary"),
                                                       t("template.trend.summary")])
    }

    @Test("A name the reader wrote is theirs, and nothing translates it")
    func aWrittenNameIsNotTranslated() {
        let app = freshApp("timelines-written-name")
        var mine = app.timelines[0]
        mine.name = "Everything"
        app.update(mine)
        #expect(app.timelines[0].displayName == "Everything")
        #expect(app.timelines[0].name == "Everything")
    }

    @Test("Words an older build seeded are cleared, whatever they say")
    func seededWordsAreCleared() async throws {
        let store = try LocalStore.inMemory()
        // What older builds left behind, in two shapes: words in a wording this version no
        // longer uses, and a row a build in between half-cleared. Nothing about either row
        // says whether a reader wrote them, so both are cleared.
        try await store.save(Timeline(id: "public", name: "Public",
                                      summary: "Some sentence a previous version shipped.",
                                      source: .public, template: "public", position: 0))
        try await store.save(Timeline(id: "trend", name: "", summary: "An older wording.",
                                      source: .trend, template: "trend", position: 1))
        let preferences = Preferences(defaults: scratch("timelines-clear-seeded"))
        let app = AppState(preferences: preferences, serverStore: EmptyServerStore(), store: store)
        await app.openTimelines()
        await app.settled()

        #expect(app.timelines.allSatisfy { $0.name.isEmpty && $0.summary.isEmpty })
        #expect(try await store.timelines().allSatisfy { $0.name.isEmpty && $0.summary.isEmpty })
        #expect(app.timelines.map(\.displayName) == [t("template.public.name"), t("template.trend.name")])
        #expect(preferences.clearedSeededWording)
    }

    @Test("The repair runs once: a rename after it is the reader's and stays")
    func clearingHappensOnlyOnce() async throws {
        let store = try LocalStore.inMemory()
        let preferences = Preferences(defaults: scratch("timelines-clear-once"))
        let app = AppState(preferences: preferences, serverStore: EmptyServerStore(), store: store)
        await app.openTimelines()

        var mine = app.timelines[0]
        mine.name = "Everything"
        app.update(mine)
        await app.settled()

        // Another launch on the same install: the repair is behind it and does not run again,
        // so a name written after it is the reader's and stays theirs.
        let again = AppState(preferences: preferences, serverStore: EmptyServerStore(), store: store)
        await again.openTimelines()
        await again.settled()
        #expect(again.timelines[0].name == "Everything")
    }

    @Test("A timeline made from a template goes to the end of the row and is opened")
    func makingOne() {
        let app = freshApp("timelines-make")
        let template = TimelineTemplate.named("tag")!
        app.add(template.timeline(named: "Swift", summary: "posts about Swift", about: "#Swift"))

        #expect(app.timelines.count == 3)
        #expect(app.currentTimeline == app.timelines.last?.id)
        #expect(app.readingTimeline?.name == "Swift")
        // A subscription and not a sieve: this used to be a rule over the public timeline,
        // which showed the posts carrying the tag that the public timeline happened to hand
        // over — on a busy server, almost none of them (#104).
        #expect(app.readingTimeline?.filters == [])
        #expect(app.readingTimeline?.tags == ["swift"])
        #expect(app.readingTimeline?.source == .tag)
    }

    @Test("A copy is its own timeline, and editing it leaves the one it came from alone")
    func duplicating() {
        let app = freshApp("timelines-duplicate")
        let original = app.timelines[0]
        var copy = app.duplicate(original)
        copy.name = "Renamed"
        app.update(copy)

        #expect(app.timelines.count == 3)
        #expect(app.timeline(original.id)?.name == original.name)
        #expect(app.timeline(copy.id)?.name == "Renamed")
    }

    @Test("Deleting the one being read leaves the reader on another rather than on nothing")
    func deletingTheOneInFront() {
        let app = freshApp("timelines-delete")
        app.railItem = .timeline
        app.currentTimeline = "public"
        app.delete("public")

        #expect(app.timelines.map(\.id) == ["trend"])
        #expect(app.currentTimeline == "trend")
        #expect(app.readingTimeline?.id == "trend")
    }

    @Test("Deleting every one of them is allowed, and the page says so")
    func deletingAllOfThem() {
        let app = freshApp("timelines-delete-all")
        app.railItem = .timeline
        for timeline in app.timelines { app.delete(timeline.id) }
        #expect(app.timelines.isEmpty)
        #expect(app.readingTimeline == nil)
    }

    @Test("Tab goes along the row the reader built, and wraps")
    func rotating() {
        let app = freshApp("timelines-rotate")
        app.railItem = .timeline
        app.currentTimeline = "public"
        #expect(app.rotateTab(by: 1))
        #expect(app.currentTimeline == "trend")
        #expect(app.rotateTab(by: 1))
        #expect(app.currentTimeline == "public")
    }

    @Test("A row of one has nowhere to rotate to, so Tab is handed back")
    func rotatingOneTimeline() {
        let app = freshApp("timelines-rotate-one")
        app.railItem = .timeline
        app.delete("trend")
        #expect(app.rotateTab(by: 1) == false)
    }

    @Test("With nobody signed in there is no home to offer, and nothing is marked as offered")
    func homeIsNotOfferedToNobody() async throws {
        let app = AppState(preferences: Preferences(defaults: scratch("timelines-home-nobody")),
                           serverStore: EmptyServerStore(), store: try LocalStore.inMemory())
        await app.openTimelines()
        #expect(app.timelines.map(\.template) == ["public", "trend"])
        #expect(app.preferences.offeredHomeTimeline == false)
    }

    @Test("Home lands between the public timeline and trending, however late it arrives")
    func homeSitsWhereItsTemplateDoes() async throws {
        let store = try LocalStore.inMemory()
        try await signedIn(on: store)
        let app = AppState(preferences: Preferences(defaults: scratch("timelines-home-order")),
                           serverStore: EmptyServerStore(), store: store)
        await app.openTimelines()

        #expect(app.timelines.map(\.template) == ["public", "home", "trend"])
        #expect(app.timelines.map(\.position) == [0, 1, 2])
        // And the store agrees, so the next launch reads them back in the same order.
        await app.settled()
        #expect(try await store.timelines().map(\.template) == ["public", "home", "trend"])
    }

    @Test("A timeline with nowhere to read from is not somewhere Tab can land")
    func unreadableTimelinesAreNotStoppedOn() async throws {
        let store = try LocalStore.inMemory()
        try await signedIn(on: store)
        let app = AppState(preferences: Preferences(defaults: scratch("timelines-unreadable")),
                           serverStore: EmptyServerStore(), store: store)
        await app.openTimelines()
        app.railItem = .timeline
        app.currentTimeline = "public"

        // Nobody is signed in as far as the app is concerned — `SignInModel` has not been
        // asked — so home is there, drawn, and not reachable.
        #expect(app.signedInAnywhere == false)
        #expect(app.isReadable(app.timelines[1]) == false)
        #expect(app.rotateTab(by: 1))
        #expect(app.currentTimeline == "trend")
    }

    @Test("An account signed in before any of this still gets a home, and only once")
    func homeArrivesForAnAccountAlreadySignedIn() async throws {
        let store = try LocalStore.inMemory()
        try await signedIn(on: store)
        let app = AppState(preferences: Preferences(defaults: scratch("timelines-home-existing")),
                           serverStore: EmptyServerStore(), store: store)

        // Launch, not a sign-in: being signed in is a state, and a reader who signed in before
        // timelines existed never had the moment a sign-in would have given them.
        await app.openTimelines()
        #expect(app.timelines.map(\.template) == ["public", "home", "trend"])
        #expect(app.preferences.offeredHomeTimeline)
        // A tab appearing is announcement enough: the reader is left where they were.
        #expect(app.currentTimeline == "public")

        // And deleting it is a decision. Asked again, the app does not argue.
        app.delete(try #require(app.timelines.first { $0.template == "home" }).id)
        await app.offerHomeTimeline()
        #expect(app.timelines.map(\.template) == ["public", "trend"])
    }

    @Test("A timeline the reader edits hands its new question to the feed already reading it")
    func editingReachesTheFeed() {
        let app = freshApp("timelines-edit-feed")
        var timeline = app.timelines[0]
        let feed = app.feed(for: timeline)
        timeline.filters = [TimelineFilter(kind: .media)]
        app.update(timeline)
        #expect(feed.timeline.filters == [TimelineFilter(kind: .media)])
        #expect(app.feed(for: app.timelines[0]) === feed)
    }
}

/// One account signed in on one server, written the way `SignInCoordinator` writes it minus
/// the credential — the rows are what says who is signed in, and they are all this asks about.
private func signedIn(on store: LocalStore) async throws {
    try await store.write { db in
        try db.execute(sql: """
            INSERT INTO servers (url, host, proto, created_at)
            VALUES ('https://one.example', 'one.example', 'mastodon', 0)
            """)
        try db.execute(sql: """
            INSERT INTO accounts (author_id, proto, server_url, handle, created_at)
            VALUES ('https://one.example/@ada', 'mastodon', 'https://one.example', '@ada@one.example', 0)
            """)
        try db.execute(sql: """
            INSERT INTO owned_accounts (author_id, server_url, created_at)
            VALUES ('https://one.example/@ada', 'https://one.example', 0)
            """)
    }
}
