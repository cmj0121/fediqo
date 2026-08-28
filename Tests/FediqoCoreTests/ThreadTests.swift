import Foundation
import Testing
@testable import FediqoCore

/// The conversation around a post: what the store can piece together on its own, and what one
/// request to the post's own server adds to it.
@Suite("The conversation around a post")
struct ThreadTests {
    private let host = "one.example"

    /// A post on `host` whose address is the one `in_reply_to_uri` points at.
    private func post(_ id: String, at seconds: TimeInterval, answering parent: String? = nil,
                      by who: String = "a") -> Post {
        Post(uri: "https://\(host)/api/v1/statuses/\(id)",
             originURI: "https://\(host)/users/\(who)/statuses/\(id)",
             socialProtocol: .mastodon, sourceURL: "https://\(host)",
             createdAt: Date(timeIntervalSince1970: seconds), authorId: "https://\(host)/@\(who)",
             authorName: who.uppercased(), authorHandle: "@\(who)@\(host)", text: id,
             inReplyToURI: parent.map { "https://\(host)/api/v1/statuses/\($0)" })
    }

    @Test("A thread is walked out of what is already here, up and down")
    func walksBothWays() async throws {
        let store = try LocalStore.inMemory()
        let root = post("1", at: 100)
        let middle = post("2", at: 200, answering: "1")
        let leaf = post("3", at: 300, answering: "2")
        let sibling = post("4", at: 250, answering: "1")
        try await store.save([root, middle, leaf, sibling], from: makeServer(host))

        let thread = try await store.thread(around: middle)
        #expect(thread.ancestors.map(\.text) == ["1"])
        #expect(thread.descendants.map(\.text) == ["3"])
        // From the root, both of its replies and the reply under one of them, oldest first.
        let whole = try await store.thread(around: root)
        #expect(whole.ancestors.isEmpty)
        #expect(whole.descendants.map(\.text) == ["2", "4", "3"])
    }

    @Test("A parent nobody handed us is simply absent")
    func aMissingParentIsNotAnError() async throws {
        let store = try LocalStore.inMemory()
        let orphan = post("2", at: 200, answering: "1")
        try await store.save([orphan], from: makeServer(host))

        let thread = try await store.thread(around: orphan)
        #expect(thread.ancestors.isEmpty)
        #expect(thread.isAlone)
    }

    @Test("Two posts answering each other do not walk for ever")
    func cyclesAreBounded() async throws {
        let store = try LocalStore.inMemory()
        // A server can write this, so the walk has to survive it.
        let first = post("1", at: 100, answering: "2")
        let second = post("2", at: 200, answering: "1")
        try await store.save([first, second], from: makeServer(host))

        let thread = try await store.thread(around: first, depth: 5)
        #expect(thread.ancestors.count <= 5)
        #expect(thread.descendants.count <= 5)
    }

    @Test("What a server says about a conversation is kept, and says how it arrived")
    func aFetchedThreadIsKept() async throws {
        let store = try LocalStore.inMemory()
        let opened = post("2", at: 200, answering: "1")
        try await store.save([opened], from: makeServer(host))

        let context = Conversation(ancestors: [post("1", at: 100)], post: opened,
                                   descendants: [post("3", at: 300, answering: "2")])
        try await store.save(context.ancestors + context.descendants, from: makeServer(host), into: .thread)

        // The posts are here, and each one can say it arrived through a conversation rather
        // than through anybody's timeline.
        #expect(try await count(store, "SELECT count(*) FROM posts") == 3)
        #expect(try await count(store, "SELECT count(*) FROM post_origins WHERE feed = 'thread'") == 2)
        // So the walk now finds the whole of it without asking again.
        let thread = try await store.thread(around: opened)
        #expect(thread.ancestors.map(\.text) == ["1"])
        #expect(thread.descendants.map(\.text) == ["3"])
    }

    @Test("A conversation is not a timeline: no template offers it and it pages nowhere")
    func threadIsNotSomewhereToRead() {
        #expect(BaseSource.thread.isThreadOfTime == false)
        #expect(BaseSource.thread.ranked == false)
        #expect(TimelineTemplate.all.allSatisfy { $0.source != .thread })
    }

    @Test("The replies are in the order they were written, not the order they were found")
    func inTheOrderItHappened() async throws {
        let store = try LocalStore.inMemory()
        let root = post("1", at: 100)
        // Somebody answers the post, somebody answers that answer, and then somebody comes
        // back to the post itself an hour later. By generation that last one comes second; by
        // the clock — which is how a conversation is read — it is last.
        let first = post("2", at: 200, answering: "1")
        let under = post("3", at: 210, answering: "2")
        let late = post("4", at: 300, answering: "1")
        try await store.save([root, first, under, late], from: makeServer(host))

        let thread = try await store.thread(around: root)
        #expect(thread.descendants.map(\.text) == ["2", "3", "4"])
    }

    @Test("Each reply knows how deep it sits, and whom it is answering")
    func theShapeOfIt() {
        let root = post("1", at: 100, by: "a")
        let first = post("2", at: 200, answering: "1", by: "b")
        let under = post("3", at: 210, answering: "2", by: "c")
        let deeper = post("4", at: 220, answering: "3", by: "d")
        let late = post("5", at: 300, answering: "1", by: "e")
        let laid = Conversation(post: root, descendants: [first, under, deeper, late]).laidOut()

        #expect(laid.map(\.post.text) == ["2", "3", "4", "5"])
        #expect(laid.map(\.depth) == [1, 2, 3, 1])
        // A reply to the post says nothing: the post is what the page already is.
        #expect(laid.map(\.answering) == [nil, "@b@one.example", "@c@one.example", nil])
    }

    @Test("A reply whose parent nobody handed us sits one step under the post")
    func anOrphanIsNotGuessedAt() {
        let root = post("1", at: 100)
        let orphan = post("9", at: 400, answering: "missing", by: "z")
        let laid = Conversation(post: root, descendants: [orphan]).laidOut()
        #expect(laid.map(\.depth) == [1])
        // Nothing is claimed about whom it answers, because nothing is known.
        #expect(laid[0].answering == nil)
    }

    @Test("Two replies answering each other do not walk for ever")
    func aCycleInTheRepliesEnds() {
        let root = post("1", at: 100)
        let left = post("2", at: 200, answering: "3", by: "b")
        let right = post("3", at: 210, answering: "2", by: "c")
        let laid = Conversation(post: root, descendants: [left, right]).laidOut()
        #expect(laid.count == 2)
        #expect(laid.allSatisfy { $0.depth <= 3 })
    }
}
