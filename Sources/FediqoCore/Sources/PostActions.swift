import Foundation

/// What came of doing something to a post: what it cost to reach, and what the server's own
/// answer said the numbers are now.
///
/// The numbers are `nil` where nobody said. That is a different fact from "nothing has been
/// done to this post", and the screen keeps them apart the way it does everywhere else: what
/// it shows is what it was told, and where it was told nothing it goes on showing the number
/// the post arrived with.
public struct Acted: Sendable, Hashable {
    public let reach: Reach
    public let counts: Counts?

    public init(reach: Reach, counts: Counts? = nil) {
        self.reach = reach
        self.counts = counts
    }
}

/// Doing something to a post: finding it on the acting server, asking that server, and writing
/// down what came of it.
///
/// It lives here rather than in a screen for the reason everything else about a timeline does:
/// none of it is about what is drawn. What a screen decides is *which* account acts, because
/// that is a preference; what happens after that decision is the same three steps every time,
/// and they are here so there is one of them.
public struct PostActions: Sendable {
    private let registry: SourceRegistry
    private let store: LocalStore?

    public init(registry: SourceRegistry = .standard(), store: LocalStore? = nil) {
        self.registry = registry
        self.store = store
    }

    /// Whether acting on this post would make the acting server go and fetch it.
    ///
    /// Asked before doing anything, so a screen can say what it is about to cost. It is a
    /// question and not a promise: between asking and acting the server's answer can change,
    /// which is why `perform` takes its own `fetching` and does not trust this.
    public func reach(of post: Post, as account: ActingAccount) async -> Reach {
        guard let client = registry.client(for: post.socialProtocol) else { return .fetched }
        let found = try? await client.localId(of: post, as: account, fetching: false)
        return found == nil ? .fetched : .alreadyThere
    }

    /// Favourite, boost or bookmark, or take it back.
    ///
    /// `fetching` is the reader's answer to "may this server go and get the post": `false`
    /// refuses rather than asking quietly, and a post the server has never seen then throws
    /// instead of being fetched in the reader's name.
    ///
    /// What the lookup saw is written down alongside what we just did. It is the one moment
    /// this app is ever told whether an account of the reader's had already favourited
    /// something — every timeline read here goes out as a stranger — so throwing it away
    /// would mean a star that is empty until this app itself fills it.
    @discardableResult
    public func perform(_ action: PostAction, on post: Post, as account: ActingAccount,
                        done: Bool, fetching: Bool, now: Date = Date()) async throws -> Acted {
        guard let client = registry.client(for: post.socialProtocol) else {
            throw SourceFailure.unsupported(post.socialProtocol)
        }
        let found = try await client.localId(of: post, as: account, fetching: fetching)
        if found.marks.areKnown {
            try? await store?.record([post.mergeKey: found.marks], as: account.authorId, now: now)
        }
        let marked = try await client.setMark(action, on: found.id, as: account, done: done)
        try await store?.mark(action, on: post.mergeKey, as: account.authorId, done: done, now: now)
        // The numbers the write's own answer carried. Kept where the store has a row for the
        // post, so a screen built from the store the next time round starts from the same
        // numbers the screen that pressed the key is showing.
        if let counts = marked.counts {
            try? await store?.recount(post.mergeKey, as: counts, now: now)
        }
        return Acted(reach: found.reach, counts: marked.counts)
    }

    /// A mute, put up or taken down, in one or both of the two places it can live.
    ///
    /// `on` names a server to carry it out, or is nil for a rule this device keeps to itself.
    /// The local half never leaves the machine and is always available; the remote half needs
    /// an account and can fail on its own, which is why the store is written first — a mute
    /// the reader asked for and a server refused is still their rule here.
    public func setMute(_ kind: Mute.Kind, _ value: String, muted: Bool,
                        as account: ActingAccount? = nil, now: Date = Date()) async throws {
        let carrier = account.map { "https://\($0.host)" }
        try await store?.mute(kind, value, on: carrier, muted: muted, now: now)
        guard let account, let client = registry.client(for: .mastodon) else { return }
        try await client.setMute(kind, value, as: account, muted: muted)
    }

    /// A report, which has no local half: one that goes nowhere is not a report.
    public func report(_ post: Post, as account: ActingAccount, comment: String,
                       fetching: Bool) async throws {
        guard let client = registry.client(for: post.socialProtocol) else {
            throw SourceFailure.unsupported(post.socialProtocol)
        }
        let found = try await client.localId(of: post, as: account, fetching: fetching)
        try await client.report(post, id: found.id, as: account, comment: comment)
    }
}
