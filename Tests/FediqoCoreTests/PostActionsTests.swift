import Foundation
import Testing
@testable import FediqoCore

/// What the reader did about a post, and where each kind of answer is kept.
@Suite("Doing something about a post")
struct PostActionsTests {
    private func store(with posts: [Post]) async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.save(posts, from: Server(host: "one.example", socialProtocol: .mastodon))
        return store
    }

    private var mine: String { "https://one.example/users/someone" }

    /// Never-told is not "no". The distinction is the reason this table exists at all, so it
    /// is asked of the store rather than trusted to the schema comment.
    @Test("A post nobody has told us about has no marks, which is not the same as none set")
    func neverTold() async throws {
        let post = makePost(uri: "a", at: 1)
        let store = try await self.store(with: [post])

        #expect(try await store.marks(of: [post.mergeKey], as: mine).isEmpty)
        #expect(PostMarks.unknown.favourited == nil)
        #expect(PostMarks.unknown.areKnown == false)
        #expect(PostMarks(favourited: false).areKnown)
    }

    @Test("A mark goes down and comes back up, and undoing leaves nothing behind")
    func markAndUnmark() async throws {
        let post = makePost(uri: "a", at: 1)
        let store = try await self.store(with: [post])

        try await store.mark(.favourite, on: post.mergeKey, as: mine, done: true)
        #expect(try await store.marks(of: [post.mergeKey], as: mine)[post.mergeKey]?.favourited == true)

        try await store.mark(.favourite, on: post.mergeKey, as: mine, done: false)
        // The row stays, the answer does not: undone is back to never-told, because
        // remembering that somebody unfavourited something is a reading record.
        #expect(try await store.marks(of: [post.mergeKey], as: mine)[post.mergeKey]?.favourited == nil)
    }

    @Test("The three marks are three answers, not one", arguments: PostAction.allCases)
    func eachMarkIsItsOwn(action: PostAction) async throws {
        let post = makePost(uri: "a", at: 1)
        let store = try await self.store(with: [post])

        try await store.mark(action, on: post.mergeKey, as: mine, done: true)
        let marks = try await store.marks(of: [post.mergeKey], as: mine)[post.mergeKey]
        #expect(marks?.value(of: action) == true)
        for other in PostAction.allCases where other != action {
            #expect(marks?.value(of: other) == nil)
        }
    }

    /// The whole reason it is keyed by two things: `posts` holds one row per post however many
    /// servers carried it, so an answer that belongs to an account cannot live on it.
    @Test("Two accounts have two answers about one post")
    func perAccount() async throws {
        let post = makePost(uri: "a", at: 1)
        let store = try await self.store(with: [post])
        let theirs = makePost(uri: "b", at: 2, from: "two.example",
                              authorId: "https://two.example/users/other")
        try await store.save([theirs], from: Server(host: "two.example", socialProtocol: .mastodon))

        try await store.mark(.favourite, on: post.mergeKey, as: mine, done: true)
        #expect(try await store.marks(of: [post.mergeKey], as: mine)[post.mergeKey]?.favourited == true)
        #expect(try await store.marks(of: [post.mergeKey], as: theirs.authorId).isEmpty)
    }

    /// A read as an account answers all three at once, and a `nil` among them must leave the
    /// column alone rather than clearing it: "this read said nothing" and "this account has
    /// not done it" are the two things the table exists to keep apart.
    @Test("What a read told us is written down, and what it did not is left alone")
    func recordingAPage() async throws {
        let post = makePost(uri: "a", at: 1)
        let store = try await self.store(with: [post])

        try await store.mark(.bookmark, on: post.mergeKey, as: mine, done: true)
        try await store.record([post.mergeKey: PostMarks(favourited: true, reblogged: false)], as: mine)

        let marks = try await store.marks(of: [post.mergeKey], as: mine)[post.mergeKey]
        #expect(marks?.favourited == true)
        #expect(marks?.reblogged == nil)     // told false, which this store keeps as "not set"
        #expect(marks?.bookmarked == true)   // untouched by a read that said nothing about it
    }

    @Test("Keeping a post is this device's answer, and no account's")
    func keeping() async throws {
        let post = makePost(uri: "a", at: 1)
        let store = try await self.store(with: [post])

        #expect(try await store.kept(among: [post.mergeKey]).isEmpty)
        try await store.keep(post.mergeKey, kept: true)
        #expect(try await store.kept(among: [post.mergeKey]) == [post.mergeKey])
        try await store.keep(post.mergeKey, kept: false)
        #expect(try await store.kept(among: [post.mergeKey]).isEmpty)
    }

    /// One target, two rules, kept apart on purpose: this app promises it can always say
    /// whether a rule of the reader's hid something or a server did.
    @Test("A local mute and a server's are two rows about one author")
    func mutesAreKeptApart() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([makePost(uri: "a", at: 1)],
                             from: Server(host: "one.example", socialProtocol: .mastodon))

        try await store.mute(.author, mine, muted: true)
        try await store.mute(.author, mine, on: "https://one.example", muted: true)

        let mutes = try await store.mutes()
        #expect(mutes.count == 2)
        #expect(mutes.filter(\.isLocal).count == 1)
        #expect(mutes.filter { !$0.isLocal }.count == 1)

        // Taking one down leaves the other standing.
        try await store.mute(.author, mine, on: "https://one.example", muted: false)
        let left = try await store.mutes()
        #expect(left.count == 1)
        #expect(left.first?.isLocal == true)
    }

    @Test("Muting the same thing twice is one row, with the later time on it")
    func mutingTwice() async throws {
        let store = try LocalStore.inMemory()
        let early = Date(timeIntervalSince1970: 1000)
        let late = Date(timeIntervalSince1970: 2000)

        try await store.mute(.host, "birch.example", muted: true, now: early)
        try await store.mute(.host, "birch.example", muted: true, now: late)

        let mutes = try await store.mutes()
        #expect(mutes.count == 1)
        #expect(mutes.first?.mutedAt == late)
        #expect(mutes.first?.kind == .host)
    }
}

/// The steps between a reader pressing a star and the store knowing about it.
@Suite("Acting on a post")
struct ActingTests {
    private let account = ActingAccount(host: "one.example",
                                        authorId: "https://one.example/users/someone",
                                        token: "t")

    private func wired(_ client: WritingClient) async throws -> (PostActions, LocalStore, Post) {
        let store = try LocalStore.inMemory()
        let post = makePost(uri: "a", at: 1)
        try await store.save([post], from: Server(host: "one.example", socialProtocol: .mastodon))
        return (PostActions(registry: SourceRegistry(clients: [.mastodon: client]), store: store),
                store, post)
    }

    @Test("A post the acting server already holds costs nothing to reach")
    func alreadyThere() async throws {
        let client = WritingClient(holding: true)
        let (actions, store, post) = try await wired(client)

        let reach = try await actions.perform(.favourite, on: post, as: account,
                                              done: true, fetching: false)
        #expect(reach == .alreadyThere)
        #expect(await client.sent == [.favourite])
        #expect(try await store.marks(of: [post.mergeKey], as: account.authorId)[post.mergeKey]?.favourited == true)
    }

    /// The refusal that matters: a reader who has not agreed to their server fetching a post
    /// gets an honest error rather than a quiet federation request in their name.
    @Test("Without leave to fetch, a post the server has never seen is refused, not fetched")
    func refusedRatherThanFetched() async throws {
        let client = WritingClient(holding: false)
        let (actions, store, post) = try await wired(client)

        await #expect(throws: SourceFailure.self) {
            try await actions.perform(.favourite, on: post, as: account, done: true, fetching: false)
        }
        #expect(await client.sent.isEmpty)
        #expect(try await store.marks(of: [post.mergeKey], as: account.authorId).isEmpty)
    }

    @Test("With leave, the server goes and gets it, and says that is what happened")
    func fetched() async throws {
        let client = WritingClient(holding: false)
        let (actions, _, post) = try await wired(client)

        let reach = try await actions.perform(.reblog, on: post, as: account,
                                              done: true, fetching: true)
        #expect(reach == .fetched)
        #expect(await client.sent == [.reblog])
    }

    /// The one moment this app is ever told what an account had already done: every timeline
    /// read here goes out as a stranger, and a stranger is told none of it.
    @Test("What the lookup saw is kept, not thrown away")
    func marksFromTheLookup() async throws {
        let client = WritingClient(holding: true, marks: PostMarks(bookmarked: true))
        let (actions, store, post) = try await wired(client)

        try await actions.perform(.favourite, on: post, as: account, done: true, fetching: false)
        let marks = try await store.marks(of: [post.mergeKey], as: account.authorId)[post.mergeKey]
        #expect(marks?.bookmarked == true)
        #expect(marks?.favourited == true)
    }

    /// The local half is the reader's own rule and never leaves the machine, so it stands
    /// whether or not a server was asked and whether or not the asking worked.
    @Test("A mute with no account behind it is still this device's rule")
    func mutingLocally() async throws {
        let client = WritingClient(holding: true)
        let (actions, store, _) = try await wired(client)

        try await actions.setMute(.host, "birch.example", muted: true)
        #expect(try await store.mutes().first?.isLocal == true)
        #expect(await client.muted.isEmpty)
    }

    @Test("A mute with an account behind it is written here and asked of the server")
    func mutingOnAServer() async throws {
        let client = WritingClient(holding: true)
        let (actions, store, _) = try await wired(client)

        try await actions.setMute(.author, "https://birch.example/users/x", muted: true, as: account)
        #expect(try await store.mutes().first?.isLocal == false)
        #expect(await client.muted == ["https://birch.example/users/x"])
    }
}

/// A server that can be written to, and remembers what it was asked.
actor WritingClient: SourceClient {
    private let holding: Bool
    private let marks: PostMarks
    private(set) var sent: [PostAction] = []
    private(set) var muted: [String] = []
    private(set) var reported: [String] = []

    init(holding: Bool, marks: PostMarks = .unknown) {
        self.holding = holding
        self.marks = marks
    }

    func localId(of post: Post, as account: ActingAccount, fetching: Bool) async throws -> Located {
        if holding { return Located(id: "1", reach: .alreadyThere, marks: marks) }
        guard fetching else { throw SourceFailure.notItsPost(post.uri) }
        return Located(id: "1", reach: .fetched, marks: marks)
    }

    func setMark(_ action: PostAction, on id: String, as account: ActingAccount, done: Bool) async throws {
        sent.append(action)
    }

    func setMute(_ kind: Mute.Kind, _ value: String, as account: ActingAccount, muted: Bool) async throws {
        self.muted.append(value)
    }

    func report(_ post: Post, id: String, as account: ActingAccount, comment: String) async throws {
        reported.append(comment)
    }

    // Nothing here reads anything; this double exists for the writing half alone.
    func instance(host: String) async throws -> InstanceInfo { InstanceInfo(host: host, title: host, summary: "") }
    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post] { [] }
    func home(host: String, limit: Int, before: Post?, token: String) async throws -> [Post] { [] }
    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }
    func context(of post: Post, host: String, token: String?) async throws -> Conversation { Conversation(post: post) }
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }
}
