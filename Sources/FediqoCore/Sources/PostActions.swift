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

/// What became of one destination of one composed post.
///
/// A per-destination answer and not a whole. A post that reached two servers of three is exactly
/// that — two that went and one that did not — and flattening it into a success or a failure
/// would mean either claiming the third or unclaiming the two.
public struct Sent: Sendable {
    /// The account it was sent as.
    public let authorId: String
    /// The server it was sent to, bare.
    public let host: String
    /// The post that server made, or nothing where it refused.
    public let post: Post?
    /// Why it refused, or nothing where it did not.
    public let failure: SourceFailure?

    public var went: Bool { post != nil }

    public init(authorId: String, host: String, post: Post? = nil, failure: SourceFailure? = nil) {
        self.authorId = authorId
        self.host = host
        self.post = post
        self.failure = failure
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

    /// Sends a draft, and keeps what came back.
    ///
    /// The post the server made is written down like any arrival from that server, into the
    /// same feed a home timeline lands in — because that is what it is. So the reader's own
    /// timeline has it now rather than at the next refresh, and it is there with the same
    /// columns, the same merge key and the same order as everything beside it.
    ///
    /// A draft with nothing in it is refused here rather than sent for a server to refuse:
    /// whitespace is not a post, and the round trip would only be a slower way of saying so.
    @discardableResult
    public func publish(_ draft: Draft, as account: ActingAccount, to socialProtocol: SocialProtocol = .mastodon,
                        now: Date = Date()) async throws -> Post {
        guard !draft.isEmpty else { throw SourceFailure.emptyDraft }
        guard let client = registry.client(for: socialProtocol) else {
            throw SourceFailure.unsupported(socialProtocol)
        }
        let post = try await client.publish(draft, as: account)
        // Kept where it can fail without unsending anything. The post is on the server whatever
        // this database does next, and a store that would not take it is a fact about this
        // machine — reported by the caller, never by pretending the post did not go.
        try await store?.save([post], from: Server(host: account.host, socialProtocol: socialProtocol),
                              into: .home, as: account.authorId, now: now)
        return post
    }

    /// One composed post, several accounts, one action — and the record of what went where.
    ///
    /// **Nothing throws.** A destination is a thing that can fail on its own, and every one of
    /// them reports itself: what comes back is a list as long as the list that went in, in the
    /// same order, each saying whether it went and why not. A single error would have to choose
    /// between claiming what did not happen and unclaiming what did.
    ///
    /// **Nothing is retried anywhere else.** A post that one server would not take did not go to
    /// that server, and no other one is quietly offered it — the reader chose these accounts,
    /// and choosing again is theirs.
    ///
    /// They go one at a time rather than at once. Publishing is not a read: a reader watching
    /// three servers be asked in parallel cannot be told which of them was slow, and an app that
    /// gave up halfway through a parallel send would not know what it had done. One after
    /// another, each written down as it lands.
    ///
    /// The record is written once, at the end, for the destinations that went. It is one act, so
    /// it is one transaction: half of it would tell #5 that two of three posts are one post and
    /// leave the third looking like somebody else's.
    public func publish(_ draft: Draft, as accounts: [ActingAccount],
                        to socialProtocol: SocialProtocol = .mastodon,
                        composition: String = UUID().uuidString,
                        now: Date = Date()) async -> [Sent] {
        guard !draft.isEmpty else {
            return accounts.map { Sent(authorId: $0.authorId, host: $0.host, failure: .emptyDraft) }
        }
        guard let client = registry.client(for: socialProtocol) else {
            return accounts.map { Sent(authorId: $0.authorId, host: $0.host,
                                       failure: .unsupported(socialProtocol)) }
        }

        var sent: [Sent] = []
        for account in accounts {
            do {
                sent.append(Sent(authorId: account.authorId, host: account.host,
                                 post: try await client.publish(draft, as: account)))
            } catch {
                sent.append(Sent(authorId: account.authorId, host: account.host,
                                 failure: SourceFailure.of(error)))
            }
        }

        // Keeping it comes after sending all of it, and in an order the store depends on.
        //
        // The first that went is the row the others live in — one composed post is one row here,
        // the way one post carried by two servers has always been one row. So that post is
        // written first, then the record naming every destination against it, and only then the
        // rest: `save` reads that record to decide which row a post belongs in, and a post saved
        // before the record existed would have made a row of its own.
        //
        // A store that will not keep any of this has not unsent anything. Nothing here can undo
        // what the servers already did, so a refusal from this machine's own database is
        // reported like any other and the posts stand.
        let went = sent.compactMap(\.post)
        if let primary = went.first {
            let server = { (post: Post) in
                Server(host: LocalStore.host(of: post.sourceURL), socialProtocol: socialProtocol)
            }
            try? await store?.save([primary], from: server(primary), into: .home,
                                   as: sent.first(where: { $0.post != nil })?.authorId, now: now)
            // The other destinations, before the record that names them: `publications` points
            // at a server and an account, and the ones whose posts are not written yet have
            // neither.
            try? await store?.remember(referencesOf: Array(went.dropFirst()), now: now)
            let published = zip(sent.filter { $0.post != nil }, went).map { destination, post in
                Publication(authorId: destination.authorId, serverURL: "https://\(destination.host)",
                            mergeKey: primary.mergeKey, uri: post.originURI ?? post.uri)
            }
            try? await store?.recordPublication(composition, of: published, now: now)
            for (destination, post) in zip(sent.filter { $0.post != nil }, went).dropFirst() {
                try? await store?.save([post], from: server(post), into: .home,
                                       as: destination.authorId, now: now)
            }
        }
        return sent
    }

    /// What each of these servers would refuse before a word of it is sent.
    ///
    /// The half of #8 that is easy to get backwards: *"A network that cannot take part of it
    /// says so before sending, not after."* Asking is a request per destination, so it is asked
    /// when the reader chooses who to send to rather than on every keystroke, and the answer is
    /// a rule of that server's rather than a number of ours — a server that says nothing about
    /// its limit is a server this cannot speak for, and it is left out rather than guessed at.
    public func refusals(of draft: Draft, from accounts: [ActingAccount],
                         to socialProtocol: SocialProtocol = .mastodon) async -> [String: SourceFailure] {
        guard let client = registry.client(for: socialProtocol) else { return [:] }
        var refused: [String: SourceFailure] = [:]
        for account in accounts {
            guard let rules = try? await client.instance(host: account.host) else { continue }
            if let refusal = Self.refusal(of: draft, against: rules) {
                refused[account.host] = refusal
            }
        }
        return refused
    }

    /// What one server would refuse about one draft, or nothing where it would take it.
    ///
    /// Separated from the asking so that the rule and the request are two things: this needs no
    /// network, which is what makes it something a test can hold to account rather than something
    /// a test has to imitate.
    ///
    /// **Every rule is skipped where the server did not state it.** The same care `maxCharacters`
    /// gets, and for the same reason: a server that did not say has not said zero, and a composer
    /// refusing a picture because it had not been told a limit is enforcing a rule nobody made.
    /// An empty list of kinds is a server that said nothing useful, not one that takes nothing.
    ///
    /// The first refusal is the answer. A reader told three things at once about one picture is
    /// a reader reading a list instead of fixing the thing.
    public static func refusal(of draft: Draft, against rules: InstanceInfo) -> SourceFailure? {
        if let limit = rules.maxCharacters, draft.length > limit {
            return .tooLong(rules.host, limit)
        }
        // Asked before a byte goes up (#89): a reader who has waited for three photographs and
        // is then told the server takes two has spent their connection on being refused.
        if let most = rules.maxAttachments, draft.pictures.count > most {
            return .tooManyPictures(rules.host, most)
        }
        for picture in draft.pictures {
            if let kinds = rules.mediaKinds, !kinds.isEmpty, !kinds.contains(picture.mime) {
                return .pictureNotTaken(rules.host, picture.filename, kinds)
            }
            if let biggest = rules.mediaSizeLimit, picture.size > biggest {
                return .pictureTooLarge(rules.host, picture.filename, biggest)
            }
        }
        return nil
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
