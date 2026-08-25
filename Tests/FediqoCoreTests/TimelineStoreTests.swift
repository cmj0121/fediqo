import Foundation
import Testing
@testable import FediqoCore

/// The reader's own timelines: written down, read back, and — once they exist — theirs.
@Suite("The timelines a reader makes")
struct TimelineStoreTests {
    private func made(_ name: String, template: String = "public", position: Int = 0) -> Timeline {
        Timeline(id: name, name: name, summary: "what \(name) is for",
                 source: TimelineTemplate.named(template)?.source ?? .public,
                 template: template, position: position)
    }

    @Test("A timeline goes in whole and comes back whole, rules and all")
    func roundTrip() async throws {
        let store = try LocalStore.inMemory()
        var timeline = made("swift")
        timeline.filters = [TimelineFilter(kind: .tag, value: "#Swift"),
                            TimelineFilter(kind: .media, negate: true)]
        try await store.save(timeline)

        let kept = try await store.timelines()
        #expect(kept == [timeline])
        // `#Swift` went in and `swift` came out: a rule about a tag is kept the one way the
        // store keeps tags, so a reader typing the hash gets the timeline they meant.
        #expect(kept.first?.filters.first?.value == "swift")
    }

    @Test("Editing rewrites the rules rather than adding to them")
    func rulesAreRewritten() async throws {
        let store = try LocalStore.inMemory()
        var timeline = made("swift")
        timeline.filters = [TimelineFilter(kind: .tag, value: "swift")]
        try await store.save(timeline)
        timeline.filters = [TimelineFilter(kind: .author, value: "@ada@one.example")]
        timeline.name = "Ada"
        try await store.save(timeline)

        let kept = try await store.timelines()
        #expect(kept.count == 1)
        #expect(kept.first?.name == "Ada")
        #expect(kept.first?.filters.map(\.kind) == [.author])
    }

    @Test("Seeding writes once; a reader who deletes one has deleted it")
    func seedingIsOnlyEverTheFirstTime() async throws {
        let store = try LocalStore.inMemory()
        #expect(try await store.seedTimelines([made("public", position: 0), made("trend", template: "trend", position: 1)]))
        try await store.deleteTimeline("trend")
        #expect(try await store.seedTimelines([made("public"), made("trend", template: "trend")]) == false)
        #expect(try await store.timelines().map(\.id) == ["public"])
    }

    @Test("Deleting a timeline takes its rules and not one post")
    func deletingKeepsThePosts() async throws {
        let store = try LocalStore.inMemory()
        let server = makeServer("one.example")
        try await store.save([makePost(uri: "https://one.example/1", at: 100)], from: server)
        var timeline = made("swift")
        timeline.filters = [TimelineFilter(kind: .tag, value: "swift")]
        try await store.save(timeline)
        try await store.deleteTimeline(timeline.id)

        #expect(try await store.timelines().isEmpty)
        #expect(try await count(store, "SELECT count(*) FROM timeline_filters") == 0)
        #expect(try await count(store, "SELECT count(*) FROM posts") == 1)
    }

    @Test("The order the reader put them in is the order they come back in")
    func orderIsKept() async throws {
        let store = try LocalStore.inMemory()
        for (position, name) in ["a", "b", "c"].enumerated() {
            try await store.save(made(name, position: position))
        }
        try await store.reorderTimelines(["c", "a", "b"])
        #expect(try await store.timelines().map(\.id) == ["c", "a", "b"])
    }

    @Test("A template seeds a timeline and then has nothing more to say to it")
    func aTemplateIsASeed() async throws {
        let store = try LocalStore.inMemory()
        let template = try #require(TimelineTemplate.named("tag"))
        var made = template.timeline(named: "Swift", summary: "posts about Swift", about: "swift")
        try await store.save(made)

        made.name = "Everything Swift"
        made.filters = []
        try await store.save(made)

        let kept = try await store.timelines()
        // Still says where it came from, and no longer takes anything from there.
        #expect(kept.first?.template == "tag")
        #expect(kept.first?.name == "Everything Swift")
        #expect(kept.first?.filters.isEmpty == true)
    }
}
