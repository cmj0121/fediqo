import Foundation

public enum JoinError: Error, Equatable, Sendable {
    case invalidHost
    case unreachable
    case unsupportedKind(ProtocolKind)
    case publicTimelineFailed
    /// The server answered with a refusal of its own — a filter in front of it decided this app
    /// was a robot, or the forum requires a key. Distinct from every other failure because it is
    /// the only one where the host is fine, the spelling is fine, and the reader is being turned
    /// away on purpose.
    case refused(Int)
}

public struct MastodonJoin: Sendable {
    /// The server answered, with a status that says no.
    private static func isRefusal(_ error: MastodonRequestError) -> Bool {
        if case .http = error { return true }
        return false
    }

    private let http: any HTTPClient
    private let store: ItemStore
    private let catalogues: EmojiCatalogueStore

    public init(http: any HTTPClient, store: ItemStore, catalogues: EmojiCatalogueStore) {
        self.http = http
        self.store = store
        self.catalogues = catalogues
    }

    public func join(host raw: String) async throws {
        let host: String
        do {
            host = try Host.parse(raw)
        } catch is HostError {
            throw JoinError.invalidHost
        }

        let kind: ProtocolKind
        do {
            kind = try await Detector(http: http).detect(raw)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DetectError {
            switch error {
            case .invalidHost: throw JoinError.invalidHost
            case .unreachable: throw JoinError.unreachable
            // 403 because that is the number refusal means in this app — see `DiscuzJoin`'s own
            // rule. A challenge is routinely dressed as a 200, so its literal status is not worth
            // carrying; what the reader needs is the sentence that offers them a sign-in.
            case .challenged: throw JoinError.refused(403)
            }
        } catch {
            throw JoinError.unreachable
        }

        guard kind == .mastodon else { throw JoinError.unsupportedKind(kind) }
        try await ingest(host: host)
    }

    /// Everything after the host is known to speak Mastodon. Separate so that a dispatcher that
    /// has already asked what a host speaks does not ask a stranger's server twice.
    func ingest(host: String) async throws {
        let source = Source(host: host, kind: .mastodon)
        let client = MastodonClient(http: http, host: host)

        async let pub = client.publicTimeline(source: source)
        async let trend: [Note] = {
            do {
                return try await client.trending(source: source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return []
            }
        }()

        let publicNotes: [Note]
        do {
            publicNotes = try await pub
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MastodonRequestError where Self.isRefusal(error) {
            throw JoinError.publicTimelineFailed
        } catch is DecodingError {
            // It answered; the answer was not a timeline. A proxy page, a fork with a
            // schema of its own, a date nobody can parse — the host is reachable and
            // the reader would waste their time looking at the network.
            throw JoinError.publicTimelineFailed
        } catch {
            // No answer at all: a dropped connection, a TLS failure, a name that does
            // not resolve. That one is worth checking a network over.
            throw JoinError.unreachable
        }
        let trendingNotes = try await trend

        await store.add(source)
        await store.ingest(publicNotes + trendingNotes)

        // Last, and not waited for. The reader pressed a button to get a timeline and the
        // timeline is now in the store; a catalogue is the largest of the answers a big
        // instance sends, and holding the join open for it would spend the reader's whole wait
        // on pictures for shortcodes that may not be on the page. Asked only for a server that
        // was actually joined, so a host this device refused leaves nothing behind.
        await catalogues.refresh(host: host) { try await client.customEmojis() }
    }
}

/// A forum joined, and its front page read.
///
/// The same shape as the microblog join and for the same reasons: the host is asked for its front
/// page **before** it is added, so a server that answers the detector and then refuses the thing
/// the reader actually wants does not leave a source behind that draws an empty timeline.
///
/// No catalogue is fetched. A forum's emoji are not a per-server dictionary a client can read the
/// way Mastodon's are, so there is nothing to hold and nothing to clear.
public struct DiscourseJoin: Sendable {
    private let http: any HTTPClient
    private let store: ItemStore

    public init(http: any HTTPClient, store: ItemStore) {
        self.http = http
        self.store = store
    }

    func ingest(host: String) async throws {
        let source = Source(host: host, kind: .discourse)
        let client = DiscourseClient(http: http, host: host)

        let topics: [Note]
        do {
            topics = try await client.latest(source: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DiscourseRequestError {
            switch error {
            // The server answered, and the answer was no. Kept apart from every other failure
            // because it is the one the reader can sometimes do something about, and the one
            // that is never their spelling.
            case .refused(let status): throw JoinError.refused(status)
            case .http, .invalidURL: throw JoinError.publicTimelineFailed
            }
        } catch is DecodingError {
            // It answered, and the answer was not a forum's front page. A filter's challenge
            // page and a fork with a schema of its own arrive here alike.
            throw JoinError.publicTimelineFailed
        } catch {
            throw JoinError.unreachable
        }

        await store.add(source)
        await store.ingest(topics)
    }
}

/// A Discuz! forum joined, and its front page read.
///
/// `DiscourseJoin`'s shape exactly, and for the same reason rather than out of symmetry: the host
/// is asked for the page the reader actually wants **before** the source is added, so a server
/// that answers the detector and then hands back a challenge, a notice page or markup nobody can
/// read does not leave a source behind that draws nothing forever.
///
/// That reason is stronger here than it was there. Discourse's front page is a documented public
/// read and five forums in six answer it; Discuz!'s is a page, and `install-e.example` — an
/// install that detects perfectly — shows a signed-out reader **no threads at all**, on every
/// board and on the guide page alike. Joining it on the strength of the detection would be
/// exactly the empty source this ordering exists to prevent.
///
/// No catalogue is fetched, for the reason `DiscourseJoin` gives: a forum's emoji are not a
/// per-server dictionary a client can read, so there is nothing to hold and nothing to clear.
public struct DiscuzJoin: Sendable {
    private let http: any HTTPClient
    private let store: ItemStore

    public init(http: any HTTPClient, store: ItemStore) {
        self.http = http
        self.store = store
    }

    func ingest(host: String) async throws {
        let source = Source(host: host, kind: .discuz)
        let client = DiscuzClient(http: http, host: host)

        let threads: [Note]
        do {
            threads = try await client.latest(source: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DiscuzRequestError {
            throw Self.refusal(error)
        } catch {
            throw JoinError.unreachable
        }

        await store.add(source)
        await store.ingest(threads)
    }

    /// What a reader should be told about one of Discuz!'s answers.
    ///
    /// Written once and used by both doors — the one-shot join above and the paused one below —
    /// because a second copy is a second place for the 200-dressed challenge to be reported as a
    /// success. That is this branch's own convention: the guarantee goes at the boundary, not in
    /// a rule each consumer remembers.
    static func refusal(_ error: DiscuzRequestError) -> JoinError {
        switch error {
        // The server answered, and the answer was no. Its own number, kept.
        case .refused(let status):
            return JoinError.refused(status)
        // **Also a refusal, and it gets 403 whatever status it arrived with.** A challenge
        // page is a filter turning this app away and is routinely dressed as a 200; the
        // forum's own notice page is the forum turning this reader away and is *always* a
        // 200. Reporting either as its literal status would tell the reader "that worked",
        // and `JoinError.refused` is the one case that says the host is fine, the spelling is
        // fine, and somebody said no on purpose — which is true of both. 403 is the number
        // that refusal means, and it is what the reader's message is written from.
        case .challenged, .restricted:
            return JoinError.refused(403)
        // **A forum with no board this reader may see is a refusal too.** `install-e.example`
        // serves a signed-out reader a complete, unchallenged, entirely ordinary index page
        // with not one board on it — the boards are there and an account is what would show
        // them. That is `refused` word for word: the host is fine, the spelling is fine, and
        // somebody decided who may read this. Filing it under "check the address" would send
        // the reader looking for a fault of theirs that does not exist.
        case .noBoards:
            return JoinError.refused(403)
        // It answered, and there was no forum front page in it: a 404, bytes in no encoding
        // this device knows, or a page whose thread table nobody could find. A reader sent to
        // check their spelling by one of these is being sent to look for a fault that might
        // well be theirs — which is the distinction `refused` above is protecting.
        case .noThreads, .http, .invalidURL, .undecodable:
            return JoinError.publicTimelineFailed
        }
    }
}

// MARK: - A join that can be paused

/// A forum that has been read but not joined: what there is to subscribe to, and nothing added.
///
/// **This is the pause itself** (D28). `SourceJoin.join(host:)` means "returns when the source is
/// added and its timeline is in the store", and a forum cannot honour that — the reader has to
/// choose before there is a timeline to fetch at all. So `begin` stops here and hands this back,
/// and `subscribe` takes it plus the reader's pick.
///
/// It carries the host **and what the host turned out to speak**, so that the second half of the
/// conversation never asks a stranger's server what it is a second time.
public struct JoinOffer: Sendable, Hashable {
    public let host: String
    public let kind: ProtocolKind
    public let categories: [DiscuzCategory]

    public init(host: String, kind: ProtocolKind, categories: [DiscuzCategory]) {
        self.host = host
        self.kind = kind
        self.categories = categories
    }

    /// Every board on the forum, flat and in the order the index listed them. The categories are
    /// what a picker groups by; this is what it iterates.
    public var boards: [DiscuzBoard] { categories.flatMap(\.boards) }
}

/// How far `SourceJoin.begin(host:)` got.
///
/// Two cases and no third, because there are exactly two answers a host can give to "add this":
/// either it is a thing this app can read straight off — and it has been — or it is a forum, and
/// the reader has a choice to make first.
public enum JoinStep: Sendable, Equatable {
    /// The source is added and its timeline is in the store. Nothing more to ask.
    case joined
    /// **Nothing has been added.** These are the boards; call `subscribe` with the reader's pick.
    case chooseBoards(JoinOffer)
}

/// A board that was picked and could not be read, and why.
public struct UnreadBoard: Sendable, Equatable {
    public let board: DiscuzBoard
    public let error: JoinError

    public init(board: DiscuzBoard, error: JoinError) {
        self.board = board
        self.error = error
    }
}

/// What came of the reader's pick.
public struct JoinOutcome: Sendable, Equatable {
    /// The boards that read, and that the source in the store now carries.
    public let subscribed: [BoardSubscription]
    /// The boards that were picked and did not read. **These were not subscribed to**, because a
    /// board in the rail whose timeline can never load is the same failure as a source in the
    /// list whose timeline can never load. They are named so somebody can say why.
    public let unread: [UnreadBoard]

    public init(subscribed: [BoardSubscription], unread: [UnreadBoard]) {
        self.subscribed = subscribed
        self.unread = unread
    }
}

/// The Core half of the conversation D28 describes: read the index, hand back the boards, and add
/// nothing until the reader has picked.
///
/// **No view is named here and none is needed.** The seam is two calls and a value between them,
/// so the thing that drives it can be a sheet, a test, or a command line. `JoinOffer` is the
/// whole of what a picker needs to draw and the whole of what `subscribe` needs to act.
public struct DiscuzBoardJoin: Sendable {
    private let http: any HTTPClient
    private let store: ItemStore

    public init(http: any HTTPClient, store: ItemStore) {
        self.http = http
        self.store = store
    }

    /// The forum's index, and **nothing added**.
    func index(host: String) async throws -> [DiscuzCategory] {
        do {
            return try await DiscuzClient(http: http, host: host).boards()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DiscuzRequestError {
            throw DiscuzJoin.refusal(error)
        } catch {
            throw JoinError.unreachable
        }
    }

    /// The reader has picked. Read those boards, then add the source carrying them.
    ///
    /// **Read before added, per board**, which is `DiscourseJoin`'s rule one level down. A board
    /// that cannot be read is left out of the subscription rather than subscribed to and left
    /// permanently blank — `install-a.example` board 37 is a live example, a real board whose
    /// threads are served as pictures and not as a list at all.
    ///
    /// **Nothing at all is added where nothing read.** Where the reader picked boards and not one
    /// of them answered, the first failure is thrown and the store is untouched, so the reader
    /// gets a sentence about a forum rather than a blank server in their list. Where they picked
    /// nothing, nothing is what happens: an empty pick is not a failure, it is a reader who
    /// changed their mind, and there is no error for that because there is nothing wrong.
    ///
    /// **One board at a time, on purpose.** Eight parallel requests into a stranger's forum for
    /// one button press is the traffic this package already refuses to spend elsewhere — see
    /// `SourceJoin`, "one detection, not one per protocol". A forum's page is not a resource
    /// anybody owes this app.
    @discardableResult
    func subscribe(host: String, to picks: [DiscuzBoard]) async throws -> JoinOutcome {
        // **The source stamped into a note carries no subscriptions, and the one in the store
        // does.** A note records which server it came from; it is not a live view of that
        // server's settings, and it would go stale the moment the reader picked a ninth board.
        let stamp = Source(host: host, kind: .discuz)
        let client = DiscuzClient(http: http, host: host)

        var subscribed: [BoardSubscription] = []
        var unread: [UnreadBoard] = []
        var threads: [Note] = []
        for board in picks {
            do {
                threads += try await client.threads(board: board, source: stamp)
                subscribed.append(BoardSubscription(board))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DiscuzRequestError {
                unread.append(UnreadBoard(board: board, error: DiscuzJoin.refusal(error)))
            } catch {
                unread.append(UnreadBoard(board: board, error: .unreachable))
            }
        }

        guard !subscribed.isEmpty else {
            if let first = unread.first { throw first.error }
            return JoinOutcome(subscribed: [], unread: [])
        }

        // Added where this host is new, and restated where it is not — a reader opening the
        // picker a second time is changing one source, not joining a second one (D26).
        await store.add(Source(host: host, kind: .discuz, boards: subscribed))
        await store.subscribe(host: host, to: subscribed)
        await store.ingest(threads)
        return JoinOutcome(subscribed: subscribed, unread: unread)
    }
}

/// What a reader's "add a source" actually calls. Asks the host what it speaks, once, and hands
/// it to whoever reads that.
///
/// **One detection, not one per protocol.** Every join used to begin by asking a stranger's server
/// what it was; a dispatcher that let each of them ask again would double that traffic for every
/// protocol added, against servers that did nothing to deserve it.
public struct SourceJoin: Sendable {
    private let http: any HTTPClient
    private let store: ItemStore
    private let catalogues: EmojiCatalogueStore

    public init(http: any HTTPClient, store: ItemStore, catalogues: EmojiCatalogueStore) {
        self.http = http
        self.store = store
        self.catalogues = catalogues
    }

    /// The one-shot door: returns when the source is added and its timeline is in the store.
    ///
    /// A Discuz! joined through here is read as **one** timeline — the whole guide page, every
    /// board at once — which is what F1 built and what the reader asked to be able to stop doing.
    /// `begin`/`subscribe` below is the conversation D28 describes; this is kept beside it
    /// because it is the only door a host with no boards to choose between needs, and because a
    /// reader who wants the whole forum is still entitled to it.
    public func join(host raw: String) async throws {
        let (host, kind) = try await self.kind(of: raw)

        // **No `default:`.** A protocol falling through a switch here is a silent wrong answer,
        // not a safe one — the same shape that once had a Discuz! source drawing every thread as
        // a microblog post with its title nowhere, and the compiler saying nothing. Every case is
        // named, so the next protocol added breaks the build here instead.
        switch kind {
        case .mastodon:
            try await MastodonJoin(http: http, store: store, catalogues: catalogues)
                .ingest(host: host)
        case .discourse:
            try await DiscourseJoin(http: http, store: store).ingest(host: host)
        case .discuz:
            try await DiscuzJoin(http: http, store: store).ingest(host: host)
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
            .unknown:
            throw JoinError.unsupportedKind(kind)
        }
    }

    /// The paused door — D28, and the first half of what a forum join actually is.
    ///
    /// For everything that is not a forum with boards, this is `join(host:)` and answers
    /// `.joined`. For a Discuz!, it detects, reads the index, and **returns without adding
    /// anything**, because the reader has to choose before there is a timeline to fetch. Hand the
    /// `JoinOffer` it gives back to `subscribe(_:to:)` with their pick.
    ///
    /// Throws `JoinError.invalidHost` for a host that is not one, `.unreachable` for one that did
    /// not answer, `.unsupportedKind` for one that speaks something this app does not read,
    /// `.refused` where the forum or something in front of it said no — which includes a forum
    /// whose index has no board a signed-out reader may see — and `.publicTimelineFailed` where
    /// it answered with something that was not a forum index.
    public func begin(host raw: String) async throws -> JoinStep {
        let (host, kind) = try await self.kind(of: raw)

        switch kind {
        case .mastodon:
            try await MastodonJoin(http: http, store: store, catalogues: catalogues)
                .ingest(host: host)
            return .joined
        case .discourse:
            try await DiscourseJoin(http: http, store: store).ingest(host: host)
            return .joined
        case .discuz:
            let categories = try await DiscuzBoardJoin(http: http, store: store).index(host: host)
            return .chooseBoards(JoinOffer(host: host, kind: kind, categories: categories))
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
            .unknown:
            throw JoinError.unsupportedKind(kind)
        }
    }

    /// The second half: the reader has picked, so read those boards and add the source.
    ///
    /// **The offer is what says which host and what it speaks**, so nothing here asks a
    /// stranger's server what it is a second time — the detection happened in `begin` and the
    /// answer travelled in the value.
    ///
    /// Throws `JoinError.unsupportedKind` for an offer from a kind that has no boards,
    /// `.unreachable`, `.refused` or `.publicTimelineFailed` where **every** picked board failed,
    /// each carrying that board's own reason. A pick where some boards read and some did not does
    /// not throw: the ones that read are subscribed and the rest come back in
    /// `JoinOutcome.unread`.
    @discardableResult
    public func subscribe(_ offer: JoinOffer, to picks: [DiscuzBoard]) async throws -> JoinOutcome {
        switch offer.kind {
        case .discuz:
            return try await DiscuzBoardJoin(http: http, store: store)
                .subscribe(host: offer.host, to: picks)
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
            .gotosocial, .discourse, .unknown:
            throw JoinError.unsupportedKind(offer.kind)
        }
    }

    /// The host, parsed, and what it says it speaks — asked exactly once per join.
    private func kind(of raw: String) async throws -> (host: String, kind: ProtocolKind) {
        let host: String
        do {
            host = try Host.parse(raw)
        } catch is HostError {
            throw JoinError.invalidHost
        }

        do {
            return (host, try await Detector(http: http).detect(raw))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DetectError {
            switch error {
            case .invalidHost: throw JoinError.invalidHost
            case .unreachable: throw JoinError.unreachable
            // 403 because that is the number refusal means in this app — see `DiscuzJoin`'s own
            // rule. A challenge is routinely dressed as a 200, so its literal status is not worth
            // carrying; what the reader needs is the sentence that offers them a sign-in.
            case .challenged: throw JoinError.refused(403)
            }
        } catch {
            throw JoinError.unreachable
        }
    }
}
