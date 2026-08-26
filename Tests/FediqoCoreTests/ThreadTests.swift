import Foundation
import Testing
@testable import FediqoCore

/// The conversation around a post: what the store can piece together on its own, and what one
/// request to the post's own server adds to it.
@Suite("The conversation around a post")
struct ThreadTests {
    private let host = "one.example"

    /// A post on `host` whose address is the one `in_reply_to_uri` points at.
    private func post(_ id: String, at seconds: TimeInterval, answering parent: String? = nil) -> Post {
        Post(uri: "https://\(host)/api/v1/statuses/\(id)",
             originURI: "https://\(host)/users/a/statuses/\(id)",
             socialProtocol: .mastodon, sourceURL: "https://\(host)",
             createdAt: Date(timeIntervalSince1970: seconds), authorId: "https://\(host)/@a",
             authorName: "A", authorHandle: "@a@\(host)", text: id,
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
}
