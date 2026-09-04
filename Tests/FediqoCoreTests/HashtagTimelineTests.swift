import Foundation
import Testing
import GRDB
@testable import FediqoCore

/// A timeline whose contents are asked for by a hashtag rather than sieved out of one that was
/// asked for something else (#104).
///
/// The old `tag` template was the public timeline with a tag rule over it, so it showed the posts
/// carrying that tag which the public timeline *happened to hand over*. On a quiet server that
/// looks like it works. On a busy one the public timeline is thousands of posts a minute, the
/// sieve catches almost nothing, and the reader is left thinking the tag is quiet.
@Suite("A timeline made of hashtags")
struct HashtagTimelineTests {
    private let server = Server(host: "tags.example", socialProtocol: .mastodon)

    // MARK: - what a timeline is made of

    @Test("A base and the tags beside it are the readings it is made of")
    func readingsAreBaseAndTags() {
        let timeline = Timeline(name: "n", source: .public, tags: ["swift", "gardening"],
                                template: "public")
        #expect(timeline.query.readings == [.base(.public), .tag("swift"), .tag("gardening")])
    }

    /// #104's "a base of nothing", spelled as the thing it actually reads rather than as an
    /// absence: a timeline based on `tag` reads nothing but its own tags.
    @Test("A timeline based on its tags reads nothing else")
    func abaseOfNothing() {
        let timeline = Timeline(name: "n", source: .tag, tags: ["swift"], template: "tag")
        #expect(timeline.query.readings == [.tag("swift")])
    }

    /// And with no tags it asks nobody, rather than quietly showing the public timeline.
    @Test("A timeline based on its tags with no tags asks nobody")
    func abaseOfNothingWithNothingInIt() {
        let timeline = Timeline(name: "n", source: .tag, template: "tag")
        #expect(timeline.query.readings.isEmpty)
    }

    @Test("A post that arrived by a tag is written down as having arrived by one")
    func thereadingSaysHowItArrived() {
        #expect(TimelineQuery.Reading.tag("swift").source == .tag)
        #expect(TimelineQuery.Reading.base(.home).source == .home)
    }

    // MARK: - one tag, however it is typed

    /// `#Swift`, `#swift` and `＃swift` are one tag, the way the store already keeps them — so
    /// they are one subscription and one question, not three of each.
    @Test("Every spelling of a tag is one subscription")
    func onespellingOfATag() {
        let timeline = Timeline(name: "n", source: .tag,
                                tags: ["#Swift", "swift", "＃swift", "SWIFT"], template: "tag")
        #expect(timeline.tags == ["swift"])
    }

    @Test("The order they were added in is the order they are kept in")
    func theorderTheyWereAdded() {
        let timeline = Timeline(name: "n", source: .tag, tags: ["b", "a", "c"], template: "tag")
        #expect(timeline.tags == ["b", "a", "c"])
    }

    // MARK: - through the store and back

    @Test("A timeline remembers what it subscribed to")
    func roundTrip() async throws {
        let store = try LocalStore.inMemory()
        try await store.save(Timeline(id: "t", name: "Swift", source: .tag,
                                      tags: ["swift", "gardening"], template: "tag"))
        #expect(try await store.timelines().first?.tags == ["swift", "gardening"])
    }

    /// Rewritten rather than merged: a tag the reader took off is a tag that has to be gone.
    @Test("A tag taken off is gone")
    func atagTakenOff() async throws {
        let store = try LocalStore.inMemory()
        var timeline = Timeline(id: "t", name: "n", source: .tag, tags: ["swift", "rust"],
                                template: "tag")
        try await store.save(timeline)
        timeline.tags = ["swift"]
        try await store.save(timeline)
        #expect(try await store.timelines().first?.tags == ["swift"])
    }

    @Test("A hashtag is a way a post can arrive")
    func tagIsAFeed() async throws {
        let store = try LocalStore.inMemory()
        let feeds = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT feed FROM feeds ORDER BY feed")
        }
        #expect(feeds.contains("tag"))
    }

    // MARK: - two subscriptions do not read each other's posts

    /// `post_origins` records the reading and not its subject, so `feed = 'tag'` on its own is
    /// every tag anybody here subscribes to. The tag itself comes from `post_tags`.
    @Test("A hashtag timeline shows its own tag and not somebody else's")
    func twoSubscriptionsDoNotMix() async throws {
        let store = try LocalStore.inMemory()
        let swift = makePost(uri: "https://tags.example/1", at: 200, from: "tags.example",
                             text: "about swift", tags: ["swift"])
        let rust = makePost(uri: "https://tags.example/2", at: 100, from: "tags.example",
                            text: "about rust", tags: ["rust"])
        try await store.save([swift, rust], from: server, into: .tag, as: nil)

        let mine = TimelineQuery(source: .tag, tags: ["swift"])
        let read = try await store.timeline(matching: mine)
        #expect(read.map(\.text) == ["about swift"])
    }

    /// A base and a tag together are one page: the base's posts and the tag's, merged newest
    /// first, which is the order everything in this app is merged in.
    @Test("A base and a tag are one page, newest first")
    func abaseAndATagAreOnePage() async throws {
        let store = try LocalStore.inMemory()
        let fromPublic = makePost(uri: "https://tags.example/3", at: 300, from: "tags.example",
                                  text: "from the public timeline")
        let fromTag = makePost(uri: "https://tags.example/4", at: 400, from: "tags.example",
                               text: "from the tag", tags: ["swift"])
        try await store.save([fromPublic], from: server, into: .public, as: nil)
        try await store.save([fromTag], from: server, into: .tag, as: nil)

        let both = TimelineQuery(source: .public, tags: ["swift"])
        #expect(try await store.timeline(matching: both).map(\.text)
                == ["from the tag", "from the public timeline"])
    }

    /// The one that would have been quiet and catastrophic: no readings must not read as no
    /// condition, which is every post this device holds.
    @Test("A timeline that asked nobody reads nothing, not everything")
    func nothingIsNotEverything() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([makePost(uri: "https://tags.example/5", at: 1, from: "tags.example")],
                             from: server, into: .public, as: nil)
        let empty = TimelineQuery(source: .tag)
        #expect(try await store.timeline(matching: empty).isEmpty)
    }

    // MARK: - it is asked for, not sieved

    @Test("Each tag is asked of each server, by name")
    func eachTagIsAsked() async throws {
        let asked = Asking()
        let loader = TimelineLoader(registry: SourceRegistry(clients: [.mastodon: asked]),
                                    limit: 40, secrets: InMemorySecretStore())
        _ = await loader.load(servers: [server],
                              query: TimelineQuery(source: .public, tags: ["swift", "rust"]))
        #expect(await asked.tags.sorted() == ["rust", "swift"])
        #expect(await asked.timelines == 1)
    }

    /// A tag a server has no timeline for must not take the base down with it: a reader whose
    /// public timeline arrived and whose one hashtag did not has more of their page than nothing.
    @Test("A tag that cannot be asked leaves the rest of the page alone")
    func onerefusalIsNotThePage() async throws {
        let loader = TimelineLoader(registry: SourceRegistry(clients: [.mastodon: Refusing()]),
                                    limit: 40, secrets: InMemorySecretStore())
        let result = await loader.load(servers: [server],
                                       query: TimelineQuery(source: .public, tags: ["swift"]))
        #expect(result.posts.count == 1)
        #expect(result.failures[server.endpoint] != nil)
    }

    /// Counts what it was asked, and answers nothing.
    private actor Asking: StubClient {
        private(set) var tags: [String] = []
        private(set) var timelines = 0

        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] {
            timelines += 1
            return []
        }

        func tag(_ tag: String, host: String, limit: Int, before: Post?, after: Post?,
                 token: String?) async throws -> [Post] {
            tags.append(tag)
            return []
        }
    }

    /// Answers the public timeline and has no hashtag timeline at all — which is the default in
    /// `SourceClient`, left unoverridden here on purpose.
    private struct Refusing: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] {
            [makePost(uri: "https://tags.example/6", at: 1, from: "tags.example")]
        }
    }
}
