import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// Walking into a conversation, and back out of it a step at a time.
///
/// `Space` on a reply opens that reply's own thread over the one being read, `j`/`k` move the
/// ring wherever the reader is, and `Escape` comes back out one level per press. The way down
/// and the way back up are the same path — which is the whole reason the app holds a stack of
/// conversations rather than one.
@Suite("Walking into a conversation")
@MainActor
struct ThreadStackTests {
    /// Three instants, so the conversation has one order rather than whichever order the
    /// store happened to hand back: a reply is after what it answers.
    private static let posted = ["a": 100.0, "b": 200.0, "c": 300.0]

    private func post(_ id: String, answering parent: String? = nil) -> Post {
        Post(uri: "https://one.example/api/v1/statuses/\(id)",
             socialProtocol: .mastodon, sourceURL: "https://one.example",
             createdAt: Date(timeIntervalSince1970: Self.posted[id] ?? 100),
             authorId: "https://one.example/@a",
             authorName: "A", authorHandle: "@a@one.example", text: id,
             inReplyToURI: parent.map { "https://one.example/api/v1/statuses/\($0)" })
    }

    /// A chain three deep — a post, a reply to it, and a reply to that — in the store, so the
    /// conversation at every level comes from this machine and nothing is asked of anybody.
    private func app(_ name: String, counting: CountingClient = CountingClient())
    async throws -> AppState {
        let store = try LocalStore.inMemory()
        let posts = [post("a"), post("b", answering: "a"), post("c", answering: "b")]
        try await store.save(posts, from: makeServer("one.example"))

        let app = AppState(preferences: Preferences(defaults: scratch(name)),
                           serverStore: EmptyServerStore(), store: store,
                           registry: SourceRegistry(clients: [.mastodon: counting]))
        app.railItem = .timeline
        app.currentTimeline = "public"
        app.feed(for: .publicFixture).show(posts)
        return app
    }

    /// The press this suite exists for. `Space` inside a conversation used to reach past the
    /// reader for the timeline's own selection, so it reopened the post they were already
    /// reading; now it opens the one the ring is on.
    @Test("Space on a reply opens that reply's conversation over the one being read")
    func spaceOpensTheReply() async throws {
        let app = try await self.app("thread-stack-open")
        #expect(app.perform(.nextPost))
        #expect(app.perform(.expandPost))
        await app.thread?.read()
        #expect(app.expanded?.text == "a")

        #expect(app.perform(.nextPost))                 // the ring moves to the reply
        #expect(app.thread?.selected?.text == "b")
        #expect(app.perform(.expandPost))

        #expect(app.expanded?.text == "b")
        #expect(app.threads.count == 2)
        // And the level underneath is still there, still around the post it was opened on.
        #expect(app.threads.first?.root.text == "a")
    }

    @Test("The same press again goes a level deeper, and the levels stack")
    func theStackKeepsGrowing() async throws {
        let app = try await self.app("thread-stack-deeper")
        app.expand(post("a"))
        await app.thread?.read()
        app.perform(.nextPost)
        app.perform(.expandPost)
        await app.thread?.read()

        #expect(app.perform(.nextPost))
        #expect(app.thread?.selected?.text == "c")
        #expect(app.perform(.expandPost))

        #expect(app.threads.map(\.root.text) == ["a", "b", "c"])
    }

    /// The way back. One press, one level — and the last of them is the one that returns the
    /// reader to the list, which still has its scroll position and its ring.
    @Test("Escape comes back out one level per press, and the list is where it was")
    func escapeUnwindsOneLevel() async throws {
        let app = try await self.app("thread-stack-escape")
        let feed = app.feed(for: .publicFixture)
        app.perform(.nextPost)
        let ringInTheList = feed.selection
        app.perform(.expandPost)
        await app.thread?.read()
        app.perform(.nextPost)
        app.perform(.expandPost)
        await app.thread?.read()
        app.perform(.nextPost)
        app.perform(.expandPost)
        #expect(app.threads.count == 3)

        #expect(app.perform(.dismiss))
        #expect(app.expanded?.text == "b")
        #expect(app.perform(.dismiss))
        #expect(app.expanded?.text == "a")
        #expect(app.perform(.dismiss))
        #expect(app.expanded == nil)
        #expect(app.thread == nil)
        // Nothing left to close, and the list underneath never moved.
        #expect(app.perform(.dismiss) == false)
        #expect(feed.selection == ringInTheList)
    }

    /// Coming back down lands the reader where they left, not at the top of the conversation:
    /// the level kept its own ring while the one above it was being read.
    @Test("A level keeps its ring while the level above it is open")
    func aLevelKeepsItsRing() async throws {
        let app = try await self.app("thread-stack-ring")
        app.expand(post("a"))
        await app.thread?.read()
        app.perform(.nextPost)
        app.perform(.expandPost)

        app.perform(.dismiss)
        #expect(app.thread?.selected?.text == "b")
    }

    /// The one press refused. A level around the post the reader is already reading would be
    /// a step they have to take back twice for nothing.
    @Test("Space on the post the conversation is already around opens nothing")
    func theRootIsNotReopened() async throws {
        let app = try await self.app("thread-stack-root")
        app.expand(post("a"))
        await app.thread?.read()

        #expect(app.perform(.expandPost) == false)
        #expect(app.threads.count == 1)
    }

    /// A click comes from the list, which is behind the whole stack — so it starts a new one
    /// rather than adding a level to whatever the reader left standing.
    @Test("A click from the list starts the stack again")
    func aClickStartsAgain() async throws {
        let app = try await self.app("thread-stack-click")
        app.expand(post("a"))
        await app.thread?.read()
        app.perform(.nextPost)
        app.perform(.expandPost)
        #expect(app.threads.count == 2)

        app.expand(post("c"))
        #expect(app.threads.map(\.root.text) == ["c"])
    }

    /// Walking back down a level must not ask its server all over again. The page appears
    /// once per visit and there can now be many visits, so the "only once per opening" the
    /// read has always promised is kept by the level rather than by the view.
    @Test("Coming back to a level asks its server nothing a second time")
    func aLevelIsReadOnce() async throws {
        let counting = CountingClient()
        let app = try await self.app("thread-stack-once", counting: counting)
        app.expand(post("a"))
        await app.thread?.read()
        #expect(counting.asked == ["a"])

        app.perform(.nextPost)
        app.perform(.expandPost)
        await app.thread?.read()
        #expect(counting.asked == ["a", "b"])

        // Back down to the first level, and its page asks again as a page does.
        app.perform(.dismiss)
        await app.thread?.read()
        #expect(counting.asked == ["a", "b"])
    }
}

/// A server that answers every conversation with the post alone, and remembers who it was
/// asked about. What the levels draw comes from the store; this is here to be counted.
final class CountingClient: SourceClient, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var asked: [String] { lock.withLock { log } }

    func context(of post: Post, host: String, token: String?) async throws -> Conversation {
        lock.withLock { log.append(post.text) }
        return Conversation(post: post)
    }

    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "")
    }

    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post] { [] }
    func home(host: String, limit: Int, before: Post?, token: String) async throws -> [Post] { [] }
    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }
}
