import Foundation
import Testing
@testable import FediqoCore

/// A timeline is a question asked of the one copy of each post: which base source carried it,
/// and which of the reader's rules keep it. The rules are written twice — once in Swift for a
/// page off the network, once in SQL for the store — so the last test here is the one that
/// matters most: the two spellings must never disagree.
@Suite("A timeline is a filter over one copy of each post")
struct TimelineQueryTests {
    private static let server = makeServer("one.example")
    private static let elsewhere = makeServer("two.example")

    /// A corpus with something for every rule to catch: tags, mentions, media, two authors,
    /// two servers, and a boost.
    private static let corpus: [Post] = [
        Post(uri: "https://one.example/1", socialProtocol: .mastodon, sourceURL: "https://one.example",
             createdAt: Date(timeIntervalSince1970: 100), authorId: "https://one.example/users/ada",
             authorName: "Ada", authorHandle: "@ada@one.example", text: "on swift",
             attachments: [Attachment(kind: .image, url: URL(string: "https://one.example/pic.png"))],
             tags: ["swift"],
             mentions: [Mention(uri: "https://two.example/users/bo", handle: "@bo@two.example")]),
        Post(uri: "https://one.example/2", socialProtocol: .mastodon, sourceURL: "https://one.example",
             createdAt: Date(timeIntervalSince1970: 200), authorId: "https://one.example/users/bo",
             authorName: "Bo", authorHandle: "@bo@one.example", text: "no tags here"),
        Post(uri: "https://two.example/3", socialProtocol: .mastodon, sourceURL: "https://two.example",
             createdAt: Date(timeIntervalSince1970: 300), authorId: "https://two.example/users/ada",
             authorName: "Ada", authorHandle: "@ada@two.example", text: "#Swift again",
             tags: ["Swift"]),
    ]

    private func stocked(into feed: BaseSource = .public, as reader: String? = nil) async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.save(Array(Self.corpus.prefix(2)), from: Self.server, into: feed, as: reader)
        try await store.save([Self.corpus[2]], from: Self.elsewhere, into: feed, as: reader)
        return store
    }

    @Test("The base source decides what is in the timeline at all")
    func theBaseSourceIsTheFirstRule() async throws {
        let store = try await stocked(into: .public)
        #expect(try await store.timeline(matching: TimelineQuery(source: .public)).count == 3)
        // The posts are all still there; a home timeline simply never contained them.
        #expect(try await store.timeline(matching: TimelineQuery(source: .home)).isEmpty)
        #expect(try await store.timeline().count == 3)
    }

    @Test("A home timeline is one reader's, and another reader's home is not it")
    func homeIsPerReader() async throws {
        let store = try LocalStore.inMemory()
        let secrets = InMemorySecretStore()
        try await signInRows("t0ken", to: Self.server, store: store, secrets: secrets)
        let ada = "\(Self.server.endpoint)/@ada"
        try await store.save([Self.corpus[0]], from: Self.server, into: .home, as: ada)

        #expect(try await store.timeline(matching: TimelineQuery(source: .home, account: ada)).count == 1)
        #expect(try await store.timeline(matching: TimelineQuery(source: .home,
                                                                 account: "https://one.example/@someone-else")).isEmpty)
        // Naming nobody means every home this device reads, which is what a timeline made
        // before a second account existed asks for.
        #expect(try await store.timeline(matching: TimelineQuery(source: .home)).count == 1)
    }

    @Test("A rule adds or removes and never moves", arguments: [
        (TimelineFilter(kind: .tag, value: "#Swift"), ["https://one.example/1", "https://two.example/3"]),
        (TimelineFilter(kind: .author, value: "@ada@one.example"), ["https://one.example/1"]),
        (TimelineFilter(kind: .mention, value: "@bo@two.example"), ["https://one.example/1"]),
        (TimelineFilter(kind: .server, value: "two.example"), ["https://two.example/3"]),
        (TimelineFilter(kind: .media), ["https://one.example/1"]),
    ])
    func oneRule(filter: TimelineFilter, kept: [String]) async throws {
        let store = try await stocked()
        let shown = try await store.timeline(matching: TimelineQuery(source: .public, filters: [filter]))
        #expect(Set(shown.map(\.uri)) == Set(kept))
        // Whatever is left is still in the timeline's own order, newest first.
        #expect(shown == shown.sorted { Post.isOlder($1, than: $0) })
    }

    @Test("Negating a rule keeps exactly what it did not")
    func negationIsTheRest() async throws {
        let store = try await stocked()
        let rule = TimelineFilter(kind: .tag, value: "swift")
        let kept = try await store.timeline(matching: TimelineQuery(source: .public, filters: [rule]))
        let rest = try await store.timeline(matching: TimelineQuery(
            source: .public, filters: [TimelineFilter(kind: .tag, value: "swift", negate: true)]))
        #expect(Set(kept.map(\.uri)).union(rest.map(\.uri)).count == 3)
        #expect(Set(kept.map(\.uri)).isDisjoint(with: rest.map(\.uri)))
    }

    /// The one that matters: `TimelineFilter.admits` is the definition and the SQL is the
    /// same rule spelled for the store. Two spellings can drift, and a rule that drifts
    /// silently shows a reader a different timeline depending on whether a post came from
    /// the network or from disk.
    @Test("The store's rules and the app's rules answer the same")
    func theTwoSpellingsAgree() async throws {
        let store = try await stocked()
        let rules: [TimelineFilter] = [
            TimelineFilter(kind: .tag, value: "swift"),
            TimelineFilter(kind: .tag, value: "swift", negate: true),
            TimelineFilter(kind: .author, value: "https://one.example/users/ada"),
            TimelineFilter(kind: .author, value: "@bo@one.example", negate: true),
            TimelineFilter(kind: .mention, value: "https://two.example/users/bo"),
            TimelineFilter(kind: .server, value: "https://one.example"),
            TimelineFilter(kind: .media),
            TimelineFilter(kind: .media, negate: true),
        ]
        for rule in rules {
            let query = TimelineQuery(source: .public, filters: [rule])
            let fromTheStore = try await store.timeline(matching: query).map(\.uri).sorted()
            let fromTheRules = query.admitted(Self.corpus).map(\.uri).sorted()
            #expect(fromTheStore == fromTheRules, "\(rule.kind) negate=\(rule.negate)")
        }
    }

    @Test("A ranked source answers its whole list and ignores a cursor that means nothing there")
    func rankedTakesNoCursor() async throws {
        let store = try await stocked(into: .trend)
        try await store.recordTrending(Self.corpus, from: Self.server)
        let all = try await store.timeline(matching: TimelineQuery(source: .trend))
        let again = try await store.timeline(matching: TimelineQuery(source: .trend), before: all.first)
        #expect(again.map(\.uri) == all.map(\.uri))
    }
}
