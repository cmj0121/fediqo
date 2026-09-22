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

    /// One read of a stranger's server, with its failure kept as a value rather than thrown.
    ///
    /// The ladder is the one the public timeline has always climbed, moved here so that both
    /// reads climb it and the decision can be made on the pair. The `JoinError` it hands back is
    /// the sentence **this read alone** would earn a reader; which sentence the join actually
    /// throws is `refusal(_:_:)`'s, and that is asked only when both reads failed.
    ///
    /// Cancellation is the one failure that is not a value. A reader who walked away is not a
    /// server that would not answer, and must leave no source behind, so it is rethrown for the
    /// caller to abandon the join on before anything is added. `Cancellation.happened` and not
    /// `catch is CancellationError`, because `URLSession` hands a cancelled transfer back as
    /// `URLError(.cancelled)`, which the tidy spelling never sees.
    private static func read(
        _ fetch: @Sendable () async throws -> [Note]
    ) async throws -> Result<[Note], JoinError> {
        do {
            return .success(try await fetch())
        } catch let error where Cancellation.happened(error) {
            throw CancellationError()
        } catch let error as MastodonRequestError where Self.isRefusal(error) {
            return .failure(.publicTimelineFailed)
        } catch is DecodingError {
            // It answered; the answer was not a timeline. A proxy page, a fork with a
            // schema of its own, a date nobody can parse — the host is reachable and
            // the reader would waste their time looking at the network.
            return .failure(.publicTimelineFailed)
        } catch {
            // No answer at all: a dropped connection, a TLS failure, a name that does
            // not resolve. That one is worth checking a network over.
            return .failure(.unreachable)
        }
    }

    /// Neither read came back with anything. Which sentence the reader gets for that.
    ///
    /// **The distinction between the two errors is unchanged**, and both are still worth having:
    /// `publicTimelineFailed` is "it answered, and the answer was not a timeline", and
    /// `unreachable` is "no answer at all" — the only one worth sending somebody to look at a
    /// network over. All that a second read changes is where the answer is allowed to come from.
    /// A server that answered **either** endpoint, with a status or with a body no decoder could
    /// read, is a server that answered; `unreachable` is kept for a host that said nothing to
    /// both, which is what a host that is simply not there does.
    private static func refusal(_ publicRead: JoinError, _ trendingRead: JoinError) -> JoinError {
        publicRead == .unreachable && trendingRead == .unreachable
            ? .unreachable
            : .publicTimelineFailed
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
        } catch let error where Cancellation.happened(error) {
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
    ///
    /// **Asked before it is added**, the same ordering `DiscourseJoin` and `DiscuzJoin` carry:
    /// nothing reaches `store.add` until both reads are in and the decision is made, so a server
    /// that answers the detector and then shows this reader nothing leaves no source behind.
    func ingest(host: String) async throws {
        let source = Source(host: host, kind: .mastodon)
        let client = MastodonClient(http: http, host: host)

        // Both started together and **both awaited before anything is decided**. Awaiting one
        // and throwing on it discarded a read that had already succeeded, unread.
        async let pub = Self.read { try await client.publicTimeline(source: source) }
        async let trend = Self.read { try await client.trending(source: source) }
        let publicRead = try await pub
        let trendingRead = try await trend

        // **The rule did not change; the reading of it was wrong.** `read before added` says
        // that something arrived, not that the *public timeline* arrived — and a server that
        // closes its timeline to a signed-out reader while still answering trends has content to
        // show, which `ShellSession.hasTrends` gives a tab of its own. Refusing it here was too
        // strict an implementation of a rule that is not too strict. So the join is refused only
        // where **both** reads came back with nothing; restoring a throw on the public timeline
        // alone is not a fix for anything (decision 18).
        if case .failure(let publicError) = publicRead,
           case .failure(let trendingError) = trendingRead {
            throw Self.refusal(publicError, trendingError)
        }

        // Trends are still allowed to fail on their own — a server without them has a timeline —
        // and now so is the timeline, on a server that has trends.
        let publicNotes = (try? publicRead.get()) ?? []
        let trendingNotes = (try? trendingRead.get()) ?? []

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
        } catch let error where Cancellation.happened(error) {
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
        } catch let error where Cancellation.happened(error) {
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
        //
        // `.noPosts` is here to be answered for rather than because it can arrive: joining a
        // forum reads its index and its boards and never opens a thread, so nothing on this
        // path can raise it. It is filed with `.noThreads` because it is the same sentence one
        // page further down — it answered, and there was nothing in it this device could read.
        // Left out of the list it would have been a `default:`, which this branch has twice
        // recorded as a silent wrong answer rather than a safe one.
        case .noThreads, .noPosts, .http, .invalidURL, .undecodable:
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

    /// The same offer, with `found` drawn under the board `parent` — **D29's page half** (#161).
    ///
    /// **A board already on the offer is not listed again**, wherever it is and whatever it was
    /// found as: a sub-board the front page named and the parent's own page named too is one
    /// board, and two rows for it would be two ticks for one subscription. The front page's
    /// copy is the one kept, because it was there first and the reader may already have
    /// ticked it.
    ///
    /// **Under a board and never under a sub-board**, which is `DiscuzBoard.depth`'s one level;
    /// and only under a board this offer lists, so a parent the forum no longer offers takes its
    /// children with it rather than leaving them hanging under nothing. They go after the
    /// parent's existing children, filed in its section, in the order they were found.
    ///
    /// **Nothing is ticked.** Listing a parent's children does not pick them, and a picked
    /// parent does not pick them either: each is its own `fid` and its own pick.
    public func adding(_ found: [DiscuzBoard], under parent: Int) -> JoinOffer {
        guard let above = boards.first(where: { $0.fid == parent }), above.parent == nil else {
            return self
        }
        var listed = Set(boards.map(\.fid))
        let added = found
            .filter { $0.fid != parent && listed.insert($0.fid).inserted }
            .map { $0.placed(under: above) }
        guard !added.isEmpty else { return self }
        var placed = false
        let categories = categories.map { category -> DiscuzCategory in
            guard !placed,
                  let at = category.boards.firstIndex(where: { $0.fid == parent })
            else { return category }
            placed = true
            var boards = category.boards
            var end = at + 1
            while end < boards.count, boards[end].parent == parent { end += 1 }
            boards.insert(contentsOf: added, at: end)
            return DiscuzCategory(gid: category.gid, name: category.name, boards: boards)
        }
        return JoinOffer(host: host, kind: kind, categories: categories)
    }
}

extension JoinOffer {
    /// The section a board the reader already reads is filed in when the list in hand does not
    /// place it anywhere. Negative, because every Discuz! section number is positive.
    public static let keptSection = -1

    /// The same offer, with every board in `subscribed` that it does not list added — **so a
    /// board the reader reads is never off the list they are changing** (#161).
    ///
    /// A board can be absent from the list in hand without being gone from the forum: a
    /// sub-board the front page never names is absent until its own page has been read. Left
    /// off, it could not be ticked, and the next press would unsubscribe a board the reader
    /// never touched. So it is listed at the top level, under the name it was subscribed by, in
    /// a section of its own named `section` — and taken out of there by the next `applied`
    /// that files it under its parent, because this runs last and adds only what is missing.
    public func keeping(_ subscribed: [BoardSubscription], section: String) -> JoinOffer {
        let listed = Set(boards.map(\.fid))
        var seen = Set<Int>()
        let missing = subscribed
            .filter { !listed.contains($0.fid) && seen.insert($0.fid).inserted }
            .map {
                DiscuzBoard(fid: $0.fid, name: $0.name, category: section, gid: Self.keptSection)
            }
        guard !missing.isEmpty else { return self }
        return JoinOffer(
            host: host,
            kind: kind,
            categories: categories
                + [DiscuzCategory(gid: Self.keptSection, name: section, boards: missing)]
        )
    }
}

/// What this run has learned about one forum's sub-boards from pages it was reading anyway.
///
/// **D29's page half, for a reader changing boards they already have** (#161). A forum whose
/// front page never names a sub-board still writes it on its parent's page, and on its own:
/// a reload reads every subscribed board's page for its threads, so the boards under it — and,
/// for a sub-board, the board it is under — are on this device already, with no request spent
/// on them. Held for the run and never stored: the next reload says it again, and the store's
/// schema is not this question's to change.
///
/// Without it a restate would open on the front page alone, and a sub-board the reader had
/// picked would not be on it — so it could not be ticked, and the next press would drop it.
public struct DiscuzSubBoards: Sendable, Equatable {
    /// Each parent's children, in the order its page wrote them.
    private var under: [Int: [DiscuzBoard]] = [:]

    public init() {}

    public var isEmpty: Bool { under.isEmpty }

    /// One board's page, read: what it says is under it, and what it is under.
    ///
    /// The page's own list comes first and carries its figures; a board learned earlier and not
    /// on it stays after it, because a page that has stopped naming a board is not evidence the
    /// reader may not pick it. A board learned only from its own trail carries no figures —
    /// its own page does not state them, and this file's rule is nothing rather than zero.
    public mutating func learn(_ page: DiscuzBoardPage, of board: BoardSubscription) {
        if !page.subBoards.isEmpty {
            let fresh = Set(page.subBoards.map(\.fid))
            under[board.fid] = page.subBoards
                + (under[board.fid] ?? []).filter { !fresh.contains($0.fid) }
        }
        if let parent = page.parent, parent != board.fid,
           !(under[parent] ?? []).contains(where: { $0.fid == board.fid }) {
            under[parent, default: []].append(DiscuzBoard(
                fid: board.fid, name: board.name, category: "", gid: 0, parent: parent
            ))
        }
    }

    /// `offer`, with everything learned drawn under its parent. See `JoinOffer.adding`.
    public func applied(to offer: JoinOffer) -> JoinOffer {
        under.keys.sorted().reduce(offer) { offer, parent in
            offer.adding(under[parent] ?? [], under: parent)
        }
    }
}

/// How far `SourceJoin.begin(host:)` got.
///
/// Two cases and no third, because there are exactly two answers a host can give to "add this":
/// either it is a thing this app can read straight off — and it has been — or it is a forum, and
/// the reader has a choice to make first.
///
/// **The preview is not a third case, and this is where that was decided.** A reader now looks at
/// a source before subscribing to it, and the pause that puts in front of the journey is
/// `SourcePreview` — a separate type, returned by a separate call. Filed here it would make
/// `.joined` unreachable on a first call for every protocol, and it would put a pause *before* a
/// journey inside an enum whose whole subject is a pause *inside* one.
public enum JoinStep: Sendable, Equatable {
    /// The source is added and its timeline is in the store. Nothing more to ask.
    case joined
    /// **Nothing has been added.** These are the boards; call `subscribe` with the reader's pick.
    case chooseBoards(JoinOffer)
}

/// A source looked at and **nothing added** — the preview stage, as a value.
///
/// **This is not a `JoinStep` and must never become one.** `JoinStep` answers *how far adding
/// got*, and both its cases are answers to that question; this is the stage before adding begins,
/// and it adds nothing. See the note on `JoinStep` for why a third case there would be wrong.
///
/// **It carries no client and no `SourceJoin`, on purpose.** An engine can come into existence
/// between the look and the press — the reader is offered a sign-in on a refusal and takes it — so
/// the transport has to be chosen again at `begin`, against what this run holds *then*. A preview
/// holding the client it was read through would hand the press a client that was never there, and
/// the reader would watch a sheet clear a challenge and then get the same refusal back.
///
/// Identified by host, so one host is one preview: the same rule as `Source` (D26).
public struct SourcePreview: Identifiable, Sendable, Hashable {
    public var id: String { host }
    public let host: String
    public let kind: ProtocolKind
    public let profile: ProfileAnswer
    /// The forum's index, where looking at this host meant reading one — and **empty where it did
    /// not**, which is every protocol that publishes a document instead, and a forum whose index
    /// could not be read.
    ///
    /// **Carried so the press does not ask a second time.** A Discuz! has no document to describe
    /// itself, so the look asks its index instead (see `look`) — and `DiscuzClient.boards()`
    /// throws rather than returning nothing, so a non-empty list here means exactly "the look got
    /// an index" and an empty one means exactly "it did not". `begin(_:)` reads this and reaches
    /// for the wire only where it is empty; asking a stranger's forum for the same page twice in
    /// one errand is the spend `SourceJoin` refuses in as many words.
    ///
    /// **This does not contradict the no-client rule above.** That rule is about *transports*,
    /// which can change between the look and the press when a reader signs in. Parsed categories
    /// cannot: they are what the forum said, and it does not unsay it.
    public let boards: [DiscuzCategory]

    public init(
        host: String,
        kind: ProtocolKind,
        profile: ProfileAnswer,
        boards: [DiscuzCategory] = []
    ) {
        self.host = host
        self.kind = kind
        self.profile = profile
        self.boards = boards
    }
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
        } catch let error where Cancellation.happened(error) {
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
    /// **A reader who leaves part-way through is that same nothing, and the loop stops.** This is
    /// the paragraph above carried one step further rather than an exception to it: a pick where
    /// some boards read and the reader then walked away is still a pick they never finished, so
    /// `CancellationError` leaves and the store is untouched — no source, no subscription, no
    /// threads. The alternative is the one this method must not do, and did: file the leaving as
    /// an unreadable board, keep asking the forum for the rest, and then write down a partial
    /// answer to a question nobody is waiting for.
    ///
    /// **One board at a time, on purpose.** Eight parallel requests into a stranger's forum for
    /// one button press is the traffic this package already refuses to spend elsewhere — see
    /// `SourceJoin`, "one detection, not one per protocol". A forum's page is not a resource
    /// anybody owes this app.
    ///
    /// **`keeping` is what the reader is already subscribed to, and it is correctness before it
    /// is traffic.** A board named there that is still in `picks` is carried through unchanged and
    /// never asked for again. Without that, a reader with eight boards who adds a ninth spends
    /// nine sequential full-HTML fetches — which the paragraph above measures in seconds — and,
    /// the half that matters, a board that reads perfectly today and happens to time out during
    /// the ninth pick lands in `unread`, falls out of `subscribed`, and is therefore
    /// **unsubscribed from a subscription the reader never touched**. Re-reading a board to
    /// confirm a subscription that already exists is not a check, it is a chance to lose it.
    ///
    /// **What is skipped is the fetch, and only the fetch — the name is taken fresh.** A kept
    /// board still gets its `BoardSubscription` built from the `DiscuzBoard` in `picks`, which
    /// came from the index read on *this* press, so a board renamed on the forum is stored under
    /// the name the forum uses now. `Source.boards` states the rule this follows: "the number is
    /// the subscription and the name is the label", and a moderator renaming a board does not
    /// change the `fid` it is served at. Keeping a stale label with a fresh one already in hand
    /// honours neither half of that.
    ///
    /// **The mixed row is what settles it.** Appending the *stored* subscription would give a
    /// newly ticked board the fresh index name and a kept board the old one, so one press could
    /// leave a row listing the same forum's boards under two generations of naming — and the
    /// picker, drawn from the index, would disagree with the row, drawn from the store, about a
    /// board neither of them changed.
    ///
    /// **A board in `keeping` and not in `picks` is dropped, and that is the untick.** The final
    /// list walks `picks`, which is already the forum's own index order, so what comes back is
    /// what the reader now wants and nothing else. `ItemStore.subscribe(host:to:)` then restates
    /// the set, which is the act this whole path is.
    ///
    /// **No default on `keeping:`.** A caller that means "this is a first join" says `[]` in as
    /// many words: this repo deleted `DummySource.unsigned`'s default argument after a wrong one
    /// drew a microblog's globe over every joined forum, and a wrong one here would silently
    /// re-fetch — or silently drop — a reader's whole subscription.
    @discardableResult
    func subscribe(
        host: String,
        to picks: [DiscuzBoard],
        keeping: [BoardSubscription]
    ) async throws -> JoinOutcome {
        // **The source stamped into a note carries no subscriptions, and the one in the store
        // does.** A note records which server it came from; it is not a live view of that
        // server's settings, and it would go stale the moment the reader picked a ninth board.
        let stamp = Source(host: host, kind: .discuz)
        let client = DiscuzClient(http: http, host: host)
        // `fid` and nothing else, because `fid` is the identity — a board renamed between two
        // reads is the same board, and a board's name is written down in this repo as the
        // thing that is *not* the identity. A set rather than a map of the stored
        // subscriptions, so there is nothing stale here to reach for by accident.
        let held = Set(keeping.map(\.fid))

        var subscribed: [BoardSubscription] = []
        var unread: [UnreadBoard] = []
        var threads: [Note] = []
        for board in picks {
            // Already subscribed and still picked: not asked for. Built from the board in hand,
            // so the subscription that survives carries the forum's current name for it.
            if held.contains(board.fid) {
                subscribed.append(BoardSubscription(board))
                continue
            }
            do {
                threads += try await client.threads(board: board, source: stamp)
                subscribed.append(BoardSubscription(board))
            }
            // **Thrown out of the loop, which is the whole of the fix here.** A reader who walks
            // away mid-pick is not a board that could not be read: filing them under `unread`
            // records somebody's working board as broken, and — because this ran on past it —
            // spent one more request per remaining pick on a reader who had gone, and then wrote
            // all three of `add`, `subscribe` and `ingest` behind them. Leaving stops the loop
            // and reaches none of that, which is the same nothing the paragraph above promises
            // for a pick where nothing read.
            catch let error where Cancellation.happened(error) {
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
        _ = try await begin(host: host, kind: kind, askingBoards: false)
    }

    /// Looks, and **adds nothing**. One detection and, where the protocol publishes one, one
    /// profile request.
    ///
    /// This is the first half of what "subscribe" became: the reader sees what the server says
    /// about itself, and only then presses. Hand the `SourcePreview` it gives back to
    /// `begin(_:)` — and to a `SourceJoin` built then, not this one; see `SourcePreview` for why
    /// the preview carries no client.
    ///
    /// Throws exactly what `begin(host:)` throws for the same host: `.invalidHost` for a host that
    /// is not one, `.unreachable` for one that did not answer, `.unsupportedKind` for one that
    /// speaks something this app does not read, `.refused` where something in front of it turned
    /// this app away.
    ///
    /// **A profile that could not be read is not one of them.** It arrives as
    /// `ProfileAnswer.unread` and the reader may still subscribe — a Mastodon older than 4.0
    /// serves no `/api/v2/instance` at all and reads its timeline perfectly. Reporting that as a
    /// failed look would talk a reader out of a server that works.
    ///
    /// **A forum with no document is asked a different question, not left unasked.** Discuz!
    /// publishes nothing about itself, so what this asks it is not what it *says* but whether it
    /// will show a signed-out reader anything at all — which is the one fact about it the reader
    /// needs and the only one it can give. That answer is `readsWithoutAccount`, the field
    /// Discourse's `login_required` already means, rather than a second field meaning the same
    /// thing for one protocol.
    ///
    /// **No `default:`.** The two groups below are a decision about how a protocol can be asked
    /// about itself, so the next one added breaks the build here and has to answer it.
    public func look(host raw: String) async throws -> SourcePreview {
        let (host, kind) = try await self.kind(of: raw)
        guard Self.reads(kind) else { throw JoinError.unsupportedKind(kind) }
        switch kind {
        case .discuz:
            let (profile, categories) = try await lookAtForum(host: host, kind: kind)
            return SourcePreview(host: host, kind: kind, profile: profile, boards: categories)
        case .mastodon, .discourse, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube,
             .friendica, .gotosocial, .unknown:
            let profile = try await SourceProfiles(http: http).answer(host: host, kind: kind)
            return SourcePreview(host: host, kind: kind, profile: profile)
        }
    }

    /// A forum's index, read once, and what it says about the forum.
    ///
    /// **The index is the self-description, for a protocol that has no other.** A signed-out
    /// reader who is shown boards can read this forum; one who is turned away cannot, and that is
    /// a stated fact rather than a failed request — so it is `.stated` with the one field it can
    /// fill, and the reader sees the warning *before* the press instead of the refusal after it.
    ///
    /// **A refusal here does not throw, and that is the whole point of the ruling.** `look`
    /// throwing would put the reader back where they were: told no, after a press. The press is
    /// still allowed to fail, and it still offers the sign-in that can fix it.
    ///
    /// **Who said no decides which sentence it is, and the two are not folded.** `.stated` is a
    /// claim *by the forum about itself*, and `SourceProfile`'s own invariant is that nothing in
    /// it is there because a request failed. So:
    ///
    /// - **The forum answered, about itself** — its notice page, or an index with no board this
    ///   reader may see. That is its policy, it is what an account would change, and it is
    ///   `readsWithoutAccount: false`.
    /// - **Something in front of the forum answered, and the forum said nothing** — a filter's
    ///   challenge page, or a status that says no the way a filter says it (`DiscuzRequestError`
    ///   calls that one "in the way a filter says it" in as many words). Recording a doorman as
    ///   the forum's policy would assert "reading this needs an account" about a forum that may
    ///   well read perfectly to a signed-out human — and unit 5 caches and draws that claim. It
    ///   is `.unread(.refused)`, which the preview warns about in its own words.
    ///
    /// **Read through `DiscuzClient` rather than `DiscuzBoardJoin.index`**, because `index` maps
    /// all of these onto `JoinError.refused(403)` — the right answer for *joining*, where the
    /// reader only needs the sentence and the sign-in, and the wrong one here, where which of
    /// them it was is the whole question.
    ///
    /// The two that are neither: a forum that did not answer at all, and one that answered with
    /// something that was not an index. Neither is a fact about who may read it.
    private func lookAtForum(
        host: String,
        kind: ProtocolKind
    ) async throws -> (ProfileAnswer, [DiscuzCategory]) {
        func stated(_ reads: Bool) -> ProfileAnswer {
            .stated(SourceProfile(host: host, kind: kind, readsWithoutAccount: reads))
        }
        do {
            return (stated(true), try await DiscuzClient(http: http, host: host).boards())
        } catch let error where Cancellation.happened(error) {
            throw CancellationError()
        } catch let error as DiscuzRequestError {
            // **No `default:`.** Which of these arrived decides what the reader is told about a
            // server they have not joined, and a case swept into somebody else's sentence here is
            // a policy invented for a forum that never stated one.
            switch error {
            case .restricted, .noBoards:
                return (stated(false), [])
            // 403 because a challenge page is routinely dressed as a 200, and 403 is the number
            // refusal means in this app — `SourceJoin.kind(of:)` states the same rule.
            case .challenged:
                return (.unread(host: host, kind: kind, .refused(403)), [])
            // Its own number, kept: this one arrived with a status that meant it.
            case .refused(let status):
                return (.unread(host: host, kind: kind, .refused(status)), [])
            case .noThreads, .noPosts, .http, .invalidURL, .undecodable:
                return (.unread(host: host, kind: kind, .unreadable), [])
            }
        } catch {
            return (.unread(host: host, kind: kind, .unreachable), [])
        }
    }

    /// The reader looked and said yes. The second half of the two-stage subscribe.
    ///
    /// **Nothing is detected again.** The preview carries what the host turned out to speak, which
    /// is the same reason `subscribe(_:to:)` reads it off the offer: asking a stranger's server
    /// what it is twice for one errand is traffic nobody owes this app.
    public func begin(_ preview: SourcePreview) async throws -> JoinStep {
        try await begin(
            host: preview.host,
            kind: preview.kind,
            askingBoards: true,
            index: preview.boards
        )
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
        return try await begin(host: host, kind: kind, askingBoards: true)
    }

    /// Every door's dispatch, in one place.
    ///
    /// **No `default:`.** A protocol falling through a switch here is a silent wrong answer, not a
    /// safe one — the same shape that once had a Discuz! source drawing every thread as a
    /// microblog post with its title nowhere, and the compiler saying nothing. Every case is
    /// named, so the next protocol added breaks the build here instead — and here is now the only
    /// place it has to, which is what folding three doors into one switch bought.
    ///
    /// `askingBoards` is the single difference between the doors, and it is about a forum only:
    /// `true` is D28's pause, where the index is read and the reader picks; `false` is the one-shot
    /// `join(host:)`, which takes the whole guide page at once. Everything else answers `.joined`
    /// either way, because for everything else there is nothing to pause for.
    private func begin(
        host: String,
        kind: ProtocolKind,
        askingBoards: Bool,
        index: [DiscuzCategory] = []
    ) async throws -> JoinStep {
        switch kind {
        case .mastodon:
            try await MastodonJoin(http: http, store: store, catalogues: catalogues)
                .ingest(host: host)
            return .joined
        case .discourse:
            try await DiscourseJoin(http: http, store: store).ingest(host: host)
            return .joined
        case .discuz:
            guard askingBoards else {
                try await DiscuzJoin(http: http, store: store).ingest(host: host)
                return .joined
            }
            // **Read at the look and carried here, so the forum is asked once per errand.** Empty
            // means the look never got an index — it was refused, or it was not one — and then
            // there is nothing to reuse and the wire is the only place the answer is. That read
            // is also what produces the reader's sentence and the sign-in it offers.
            let categories = try index.isEmpty
                ? await DiscuzBoardJoin(http: http, store: store).index(host: host)
                : index
            return .chooseBoards(JoinOffer(host: host, kind: kind, categories: categories))
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
            .unknown:
            throw JoinError.unsupportedKind(kind)
        }
    }

    /// Whether this app can read a source of this kind at all.
    ///
    /// **A second exhaustive switch, and what it does and does not guarantee.** The dispatcher
    /// above answers *who reads this*; this answers *can it be read*, one step earlier and with
    /// nothing added, so that `look` refuses a protocol at the field rather than showing a reader
    /// a preview whose Subscribe could only ever fail.
    ///
    /// Neither has a `default:`, so a protocol **added** to `ProtocolKind` breaks the build in
    /// both. That is the whole of the compiler's help, and it is not enough: a protocol **moved
    /// between the groups here** while the dispatcher still refuses it compiles clean and ships
    /// the screen this comment used to claim it prevented — a rendered preview whose Subscribe
    /// can only throw. Moving cases between groups is exactly what unlocking the Mastodon family
    /// is, five times over. What actually holds the two together is
    /// `everyProtocolAgreesAboutWhetherItCanBeRead`, which walks `allCases` and asks both.
    /// **`public` because the browser's first step is this list** — decision 19. The picker
    /// offers the protocols this app can read, and a second list written in the UI would be a
    /// second answer to a question this function already owns: it would go on offering a protocol
    /// the day this one stopped reading it, and the reader would meet the refusal after the press.
    public static func reads(_ kind: ProtocolKind) -> Bool {
        switch kind {
        case .mastodon, .discourse, .discuz:
            true
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
            .unknown:
            false
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
    ///
    /// `keeping` is what this host is subscribed to now — `[]` from a join, the source's own
    /// boards from a restate. See `DiscuzBoardJoin.subscribe` for what it costs to get it wrong,
    /// and for why it has no default.
    @discardableResult
    public func subscribe(
        _ offer: JoinOffer,
        to picks: [DiscuzBoard],
        keeping: [BoardSubscription]
    ) async throws -> JoinOutcome {
        switch offer.kind {
        case .discuz:
            return try await DiscuzBoardJoin(http: http, store: store)
                .subscribe(host: offer.host, to: picks, keeping: keeping)
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
            .gotosocial, .discourse, .unknown:
            throw JoinError.unsupportedKind(offer.kind)
        }
    }

    /// The boards of a source the reader **already has**, so they can change which of them they
    /// read.
    ///
    /// **Detects nothing, and that is the whole reason this exists rather than a reuse.** This
    /// host is in the reader's list because it was detected once already, and the kind travelled
    /// with the `Source`; asking a stranger's forum what it is a second time for an errand that
    /// begins with knowing is the spend this type refuses in as many words. Every other route in
    /// is wrong for a reason of its own: `look` refuses a host that is added, `begin(host:)`
    /// detects, and `begin(_:)` wants a `SourcePreview` — which could only be fabricated here with
    /// an invented `ProfileAnswer`, and `ShellSession.profiles` is the map the source row draws
    /// from, so the lie would be drawn.
    ///
    /// **Nothing is added and nothing is changed.** This is the index, as a value; the restate
    /// itself is `subscribe(_:to:keeping:)`, and the reader can still cancel.
    ///
    /// **No `default:`.** A protocol with no boards has no answer to this and says so, rather than
    /// inheriting Discuz!'s — decision 6 leaves open whether Lemmy needs a picker at all, and unit
    /// 7 has to answer it here rather than find it already answered.
    ///
    /// Throws `JoinError.unsupportedKind` for a source whose protocol has no boards, and whatever
    /// reading the index throws — `.unreachable`, `.refused`, `.publicTimelineFailed`.
    public func boards(of source: Source) async throws -> JoinOffer {
        switch source.kind {
        case .discuz:
            let categories = try await DiscuzBoardJoin(http: http, store: store)
                .index(host: source.host)
            return JoinOffer(host: source.host, kind: source.kind, categories: categories)
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
            .gotosocial, .discourse, .unknown:
            throw JoinError.unsupportedKind(source.kind)
        }
    }

    /// The boards one board's own page writes under it — read because the reader just ticked
    /// that board in the picker (#161).
    ///
    /// **One page, for one board the reader has shown they want**, and never before: the
    /// picker does not read any board's page ahead of the reader choosing. Nothing is added
    /// and nothing is ticked; the caller files what comes back with `JoinOffer.adding`.
    ///
    /// Throws `JoinError.unsupportedKind` for an offer from a kind that has no boards, and what
    /// reading the page throws, as `index` names it.
    public func subBoards(of board: DiscuzBoard, in offer: JoinOffer) async throws -> [DiscuzBoard] {
        switch offer.kind {
        case .discuz:
            do {
                return try await DiscuzClient(http: http, host: offer.host).subBoards(of: board)
            } catch let error where Cancellation.happened(error) {
                throw CancellationError()
            } catch let error as DiscuzRequestError {
                throw DiscuzJoin.refusal(error)
            } catch {
                throw JoinError.unreachable
            }
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
            .gotosocial, .discourse, .unknown:
            throw JoinError.unsupportedKind(offer.kind)
        }
    }

    /// One board's own page, read for the boards around it — see `DiscuzClient.around(_:)`.
    ///
    /// Read by a restate for each board the reader already reads, when the picker opens.
    public func around(_ fid: Int, in offer: JoinOffer) async throws -> DiscuzBoardPage {
        switch offer.kind {
        case .discuz:
            do {
                return try await DiscuzClient(http: http, host: offer.host).around(fid)
            } catch let error where Cancellation.happened(error) {
                throw CancellationError()
            } catch let error as DiscuzRequestError {
                throw DiscuzJoin.refusal(error)
            } catch {
                throw JoinError.unreachable
            }
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
        } catch let error where Cancellation.happened(error) {
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
