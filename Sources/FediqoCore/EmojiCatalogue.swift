import Foundation

/// One server's registered emoji, as they were at the moment they were fetched.
///
/// Held as a dictionary rather than as the list the server sent, because every reader asks the
/// same question — what picture does this shortcode stand for on this server — and nobody asks
/// what order they arrived in. That order is what arranges a picker, and this app has none.
public struct EmojiCatalogue: Sendable {
    /// How long a fetched catalogue is trusted before it is worth asking again.
    ///
    /// Twenty-four hours. The number is chosen against **how often an admin acts**, not against
    /// how often a reader reads: a server's emoji set moves when somebody uploads a pack, which
    /// is weeks or months apart, so a day is already generous — and when it is not, the reader
    /// has a button that drops one server's catalogue on the spot. A shorter life would spend a
    /// request per session on an answer that had not changed; a longer one is not worth the
    /// argument, since nothing here survives a relaunch anyway.
    ///
    /// This is a life *within one run*. Nothing on this branch is written to disk, so the app
    /// starts with no catalogue at all whatever this number says.
    public static let life: TimeInterval = 24 * 60 * 60

    /// The server that registered these, lowercased as `Source` lowercases it.
    ///
    /// Carried in the value and not only as the store's key, so that a catalogue handed to a
    /// screen still knows whose it is: a picture fetched out of one has to be filed under the
    /// server it came from, and an emoji address usually points at a CDN that cannot be read
    /// back as a host.
    public let host: String
    public let fetchedAt: Date
    private let byShortcode: [String: CustomEmoji]

    public init(_ emojis: [CustomEmoji], host: String, fetchedAt: Date) {
        self.host = host.lowercased()
        self.fetchedAt = fetchedAt
        // First spelling wins, as it does everywhere a shortcode is folded: one name is one
        // picture on one server, whatever the server listed twice.
        self.byShortcode = Dictionary(emojis.lazy.map { ($0.shortcode, $0) }) { first, _ in first }
    }

    /// How many shortcodes this server registered that this device would fetch a picture for.
    public var count: Int { byShortcode.count }

    /// Deliberately not public. A catalogue answering a bare shortcode is the reading server's
    /// picture with no regard for the post's own, which is the one mistake `EmojiAlphabet`
    /// exists to prevent — and `catalogue(host:)` would otherwise be that door one hop longer.
    /// What a screen needs from this value is `host`, `fetchedAt` and `count`.
    func lookup(_ shortcode: String) -> CustomEmoji? { byShortcode[shortcode] }

    /// Whether it has been held for `life` or longer, and so is worth fetching again.
    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) >= Self.life
    }
}

/// Every picture one post's words may be written in, and the order the two sources are asked in.
///
/// **A post's own list wins, and the server's catalogue is only the fallback.** A federated post
/// carries the pictures of the server that wrote it, and the server the reader is reading from
/// has its own registration of the same names: `:blobcat:` on two servers is two different
/// pictures, and drawing the reader's over the author's would quietly rewrite somebody's post.
/// So the catalogue answers only for a shortcode the post itself did not bring — which is the
/// case it exists for.
///
/// **This is the only public way to resolve a shortcode against a catalogue.** The order is
/// worth nothing if there is an unordered door beside it, so `EmojiCatalogueStore` hands out
/// one of these rather than answering a bare shortcode itself.
///
/// Built once per post and passed down. Both halves are already indexed: the post's own list is
/// a handful of names, and the catalogue is held by the store and copied in by reference, so a
/// view holding one of these costs nothing per line and builds no dictionary per render.
///
/// **Not `Equatable`, for now, and not for the reason you might assume.** `Dictionary.==` has a
/// storage-identity fast path and a count check before it compares anything, so one of these
/// copied down through a render tree is the *cheap* case, not the expensive one. The real cost
/// of leaving the conformance off is the other way round: a view storing an `EmojiAlphabet` has
/// no `==` to call and is treated as always-changed, so its body re-runs on every update of its
/// parent.
///
/// **The first consumer arrived and still does not want it.** `DummyItemRow` never stores one: a
/// view cannot await an actor in `body`, so the row asks in a `.task` — and what it keeps is the
/// short list of pictures its own lines are written in, not the alphabet that resolved them.
/// Keeping the alphabet would have meant keeping a big instance's whole catalogue on every row
/// to answer for a handful of names.
///
/// The fast path was measured rather than assumed, and it is real: comparing a 5,000-entry
/// dictionary with a copy of itself is free, against 333µs for a structurally equal rebuild. So
/// the O(1) identity on `host` and `fetchedAt` this comment used to recommend is not worth
/// writing, and is a trap besides — it names only the catalogue half, so two posts read through
/// one server at one fetch time would compare equal whatever pictures they each brought. A
/// derived `==` would already be free wherever the conformance would help.
public struct EmojiAlphabet: Sendable {
    private let own: [String: CustomEmoji]
    private let catalogue: EmojiCatalogue?

    public init(own: [CustomEmoji] = [], catalogue: EmojiCatalogue? = nil) {
        self.own = Dictionary(own.lazy.map { ($0.shortcode, $0) }) { first, _ in first }
        self.catalogue = catalogue
    }

    public func lookup(_ shortcode: String) -> CustomEmoji? {
        own[shortcode] ?? catalogue?.lookup(shortcode)
    }

    /// Whether there is any picture at all to find. A post written in letters alone, on a
    /// server with no catalogue, and the scan can be skipped entirely.
    public var isEmpty: Bool { own.isEmpty && (catalogue?.count ?? 0) == 0 }

    /// Cuts `text` into runs, resolving each shortcode in this alphabet's order.
    public func runs(in text: String) -> [EmojiRun] {
        guard !isEmpty else { return CustomEmoji.plainRuns(text) }
        return CustomEmoji.scan(text, lookup: lookup)
    }

    /// The pictures one line is actually written in, resolved in this alphabet's order.
    ///
    /// **This is how the order reaches a screen.** A screen cannot be handed the alphabet
    /// itself: a big instance's catalogue is thousands of names and a line is written in a
    /// handful, so anything downstream that took the whole of it would ask for the whole of it.
    /// What a line needs is the short list of pictures it actually spells — and narrowing is
    /// exactly where the two sources have to be asked in order, so the two happen together
    /// here and the order is applied in one place.
    ///
    /// One shortcode appears once however often the line spells it, first resolution winning,
    /// the way every other folding of a shortcode in this file works.
    public func emojis(in text: String) -> [CustomEmoji] {
        var seen: Set<String> = []
        return runs(in: text).compactMap { run in
            guard case .emoji(let emoji) = run, seen.insert(emoji.shortcode).inserted else {
                return nil
            }
            return emoji
        }
    }
}

/// Each server's emoji catalogue, for as long as this run lasts.
///
/// A catalogue is fetched once per server and held. What ages it is `EmojiCatalogue.life`, and
/// what drops it early is the reader.
///
/// **The fetch is owned here, not by the caller.** "Once per server" is not a promise a caller
/// can keep: asking whether a fetch is needed and then starting one are two hops with a network
/// in between, and two joins of one host racing through that gap make two requests. The actor
/// holds the work in flight, so the second caller joins the first one's fetch instead of
/// starting its own.
///
/// **A fetch that failed is not written down.** A server that does not serve the endpoint, or
/// one that was unreachable for a moment, leaves no entry — so the host reads as missing and
/// the next caller may ask again. Recording an absence would make one bad minute permanent for
/// the life of the process, with nothing in it to say why.
public actor EmojiCatalogueStore {
    /// A fetch on the wire, and which one it is.
    ///
    /// The number is what lets a task tell whether the entry filed under its host is still its
    /// own. Without it, a task that was cancelled and replaced would clear its successor's
    /// entry as it unwound, and a third caller would start a second fetch beside the second.
    private struct Fetch {
        let generation: Int
        let task: Task<Void, Never>
    }

    private var catalogues: [String: EmojiCatalogue] = [:]
    private var inFlight: [String: Fetch] = [:]
    private var generation = 0
    private let now: @Sendable () -> Date

    /// `now` is injected so that a test can age a catalogue without waiting a day for it.
    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Fetch and hold this server's catalogue, unless one is already held and still young, or
    /// one is already on its way.
    ///
    /// **Returns as soon as the work is under way.** A join must not wait for this: the reader
    /// pressed a button to get a timeline, they have one, and a catalogue is the largest of the
    /// four answers a big instance sends. A caller that does need it in hand waits with
    /// `settle(host:)`.
    ///
    /// Whatever `fetch` throws is dropped, which is the whole of "a missing catalogue must not
    /// cost the reader the source": `/api/v1/custom_emojis` is optional, some forks do not serve
    /// it, and a status still carries its own pictures either way.
    public func refresh(host: String, using fetch: @escaping @Sendable () async throws -> [CustomEmoji]) {
        let key = Self.key(host)
        // A cancelled fetch is not one to wait behind. `forget(host:)` leaves its entry in
        // place so that `settle(host:)` can still be waited on and so that the task can tidy
        // after itself — but a reader who cleared this server and asked again is owed a fetch,
        // and treating the corpse as work in progress would silently start none at all.
        if let running = inFlight[key], !running.task.isCancelled { return }
        if let held = catalogues[key], !held.isStale(at: now()) { return }

        generation += 1
        let mine = generation
        // Registered before the first suspension, so a second caller arriving while this one is
        // on the network finds it rather than starting a second fetch. Nothing between here and
        // the assignment suspends, so there is no window to arrive in.
        inFlight[key] = Fetch(generation: mine, task: Task { [self] in
            let emojis = try? await fetch()
            // Only if this is still the fetch on record. A cancelled one that has since been
            // replaced must not strike its successor off.
            if inFlight[key]?.generation == mine { inFlight[key] = nil }
            // Cancelled means `forget(host:)` ran while this was on the wire: the reader asked
            // for this server's catalogue to be dropped, and an answer arriving behind them is
            // one they did not ask to keep. A client that does not honour cancellation and
            // hands back a body anyway is stopped here rather than on the network.
            guard !Task.isCancelled, let emojis else { return }
            catalogues[key] = EmojiCatalogue(emojis, host: key, fetchedAt: now())
        })
    }

    /// Wait for a fetch already on its way for this host. Nothing on its way is not a wait.
    public func settle(host: String) async {
        await inFlight[Self.key(host)]?.task.value
    }

    public func catalogue(host: String) -> EmojiCatalogue? { catalogues[Self.key(host)] }

    /// This post's alphabet on this server: its own pictures first, the catalogue behind them.
    ///
    /// The one way out of this store to a resolved shortcode, so that no screen can reach the
    /// catalogue without the order that says a federated post's own pictures come first.
    public func alphabet(own: [CustomEmoji], host: String) -> EmojiAlphabet {
        EmojiAlphabet(own: own, catalogue: catalogues[Self.key(host)])
    }

    /// Whether this host's catalogue is missing or has been held too long — the one question a
    /// caller asks before deciding to fetch.
    public func needsFetch(host: String) -> Bool {
        guard let held = catalogues[Self.key(host)] else { return true }
        return held.isStale(at: now())
    }

    /// Drop one server's catalogue: the reader pressing Clear on that row. A fetch on its way
    /// for that server goes with it, so the catalogue they dropped cannot arrive behind them.
    ///
    /// Cancelled and not struck off, so that the task can still be waited on and can still tidy
    /// its own entry away. It does not stand in the way of asking again: `refresh` steps over a
    /// cancelled entry rather than waiting behind it.
    public func forget(host: String) {
        let key = Self.key(host)
        catalogues[key] = nil
        inFlight[key]?.task.cancel()
    }

    /// Drop every server's.
    public func forget() {
        catalogues.removeAll()
        for fetch in inFlight.values { fetch.task.cancel() }
    }

    /// `Source` lowercases the host it was given and so does this. `first.example` and
    /// `first.example` are one server, and a catalogue filed under the spelling the reader
    /// happened to type is a second copy that nothing will ever find.
    private static func key(_ host: String) -> String { host.lowercased() }
}
