import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// A star pressed on the opened post, and the row in the list behind it.
///
/// They are two copies of one post, so neither the mark nor the number may live on the post
/// itself — both live on the app, keyed by `mergeKey`, and both copies read the same answer.
/// What used to go wrong here was that the answer could be taken back: a page read landing
/// between the press and the server's reply handed the star back to what the store held, where
/// it stayed until the next read.
@Suite("A post, marked")
@MainActor
struct MarkedPostTests {
    private func post(_ id: String, favourites: Int? = 3) -> Post {
        Post(uri: "https://one.example/api/v1/statuses/\(id)",
             originURI: "https://one.example/users/a/statuses/\(id)",
             socialProtocol: .mastodon, sourceURL: "https://one.example",
             createdAt: Date(timeIntervalSince1970: 100), authorId: "https://one.example/@a",
             authorName: "A", authorHandle: "@a@one.example", text: id,
             counts: Counts(replies: 0, reblogs: 1, favourites: favourites))
    }

    /// The bug, named. The write is held open, a page read lands in the gap, and the star has
    /// to still be there when the reader looks — which is what pressing it promised.
    @Test("A page read landing while the write is out does not take the star back")
    func aReadInTheGapTakesNothingBack() async throws {
        let gate = Gate()
        let posts = [post("a")]
        let app = try await signedInApp("marked-gap", posts: posts,
                                        client: WriteDouble(gate: gate))

        let acting = Task { await app.act(.favourite, on: posts[0]) }
        await gate.waitUntilEntered()
        #expect(app.marks(of: posts[0]).favourited == true)

        // The timeline reads its page again — a refresh, or the rows coming back. The store
        // has not been told yet, and its answer must not win.
        await app.loadMarks(for: posts)
        #expect(app.marks(of: posts[0]).favourited == true)

        await gate.open()
        await acting.value
        #expect(app.marks(of: posts[0]).favourited == true)
        #expect(app.actionFailure == nil)
    }

    /// And once the write has landed, a page read is reading the same answer rather than
    /// overriding it — the store was told on the way past.
    @Test("After the write has landed, a page read agrees with the screen")
    func afterTheWriteTheStoreAgrees() async throws {
        let posts = [post("a")]
        let app = try await signedInApp("marked-after", posts: posts, client: WriteDouble())

        await app.act(.favourite, on: posts[0])
        await app.loadMarks(for: posts)

        #expect(app.marks(of: posts[0]).favourited == true)
        #expect(app.actingOn.isEmpty)
    }

    /// The number, which used to sit still through every press. It moves to what the server's
    /// own answer to the write said — not to what this app worked out, because never-told is
    /// not "no" and a reader who had already favourited it elsewhere would be counted twice.
    @Test("The number becomes what the write's answer said it is now")
    func theNumberMoves() async throws {
        let posts = [post("a", favourites: 3)]
        let app = try await signedInApp(
            "marked-count", posts: posts,
            client: WriteDouble(answering: Marked(marks: PostMarks(favourited: true),
                                                  counts: Counts(replies: 0, reblogs: 1, favourites: 4))))

        #expect(app.counts(of: posts[0]).favourites == 3)
        await app.act(.favourite, on: posts[0])
        #expect(app.counts(of: posts[0]).favourites == 4)
    }

    /// A server that said nothing about the numbers has one invented for it by nobody. The row
    /// goes on showing what the post arrived with, which is the only number anybody has said.
    @Test("A write that said nothing about the numbers leaves the row's own number alone")
    func silenceLeavesTheNumber() async throws {
        let posts = [post("a", favourites: 3)]
        let app = try await signedInApp("marked-quiet", posts: posts, client: WriteDouble())

        await app.act(.favourite, on: posts[0])

        #expect(app.marks(of: posts[0]).favourited == true)
        #expect(app.counts(of: posts[0]).favourites == 3)
    }

    /// The reason none of this lives on the post: the opened page and the row in the list hold
    /// two copies of it, and one press has to move both.
    @Test("The opened post and the row in the list read one answer")
    func bothCopiesAgree() async throws {
        let posts = [post("a", favourites: 3)]
        let app = try await signedInApp(
            "marked-copies", posts: posts,
            client: WriteDouble(answering: Marked(counts: Counts(favourites: 4))))

        app.expand(posts[0])
        let opened = try #require(app.expanded)
        await app.act(.favourite, on: opened)

        // A separately-built value for the same post — which is what the list is holding.
        #expect(app.marks(of: post("a")).favourited == true)
        #expect(app.counts(of: post("a")).favourites == 4)
    }

    /// A refused write puts the star back where it was, and claims nothing about the numbers.
    @Test("A write the server refuses puts the star back")
    func arefusalPutsItBack() async throws {
        let posts = [post("a", favourites: 3)]
        let app = try await signedInApp("marked-refused", posts: posts,
                                        client: WriteDouble(refusing: true))

        await app.act(.favourite, on: posts[0])

        #expect(app.marks(of: posts[0]).favourited == nil)
        #expect(app.counts(of: posts[0]).favourites == 3)
        #expect(app.actionFailure != nil)
        #expect(app.actingOn.isEmpty)
    }
}

/// A write that can be held open, so a test can put something else in the gap between the
/// press and the answer.
///
/// It counts arrivals and holds all of them, rather than one: a reader can have two marks out
/// on the same post at once, and a gate that only remembered the last would let one of them
/// through and hang the other.
actor Gate {
    private(set) var entered = 0
    private var opened = false
    private var waitingForEntry: [CheckedContinuation<Void, Never>] = []
    private var waitingToLeave: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the write: says it has started, then waits to be let go.
    func enter() async {
        entered += 1
        let waiting = waitingForEntry
        waitingForEntry = []
        for continuation in waiting { continuation.resume() }
        guard !opened else { return }
        await withCheckedContinuation { waitingToLeave.append($0) }
    }

    /// Waits until at least `count` writes are being held.
    func waitUntilEntered(_ count: Int = 1) async {
        while entered < count {
            await withCheckedContinuation { waitingForEntry.append($0) }
        }
    }

    func open() {
        opened = true
        let waiting = waitingToLeave
        waitingToLeave = []
        for continuation in waiting { continuation.resume() }
    }
}

/// A server that can be written to: it agrees, it can be made to refuse, and it can be held
/// open. What it answers with is what a real one answers with — the status, and the numbers in
/// it.
final class WriteDouble: SourceClient, @unchecked Sendable {
    private let gate: Gate?
    private let answer: Marked
    private let refusing: Bool

    init(gate: Gate? = nil, answering answer: Marked = Marked(), refusing: Bool = false) {
        self.gate = gate
        self.answer = answer
        self.refusing = refusing
    }

    func localId(of post: Post, as account: ActingAccount, fetching: Bool) async throws -> Located {
        Located(id: "1", reach: .alreadyThere)
    }

    func setMark(_ action: PostAction, on id: String, as account: ActingAccount,
                 done: Bool) async throws -> Marked {
        await gate?.enter()
        if refusing { throw SourceFailure.http(422, Data()) }
        return answer
    }

    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "")
    }

    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post] { [] }
    func home(host: String, limit: Int, before: Post?, token: String) async throws -> [Post] { [] }
    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }
    func context(of post: Post, host: String, token: String?) async throws -> Conversation {
        Conversation(post: post)
    }
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }
}
