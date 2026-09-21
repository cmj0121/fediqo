import FediqoCore
import ImageIO
import SwiftUI

/// Every picture the shell draws, held somewhere a view cannot lose it.
///
/// **The bug this exists for.** `AsyncImage` keeps its result for the lifetime of the view that
/// asked for it and nowhere else, so a row rebuilt for any reason starts again from nothing.
/// Whether a reader ever sees a picture then comes down to whether the rebuilding stops before
/// they look. A taller row means more re-measuring, and the reader's largest text means more
/// again, so what a reader ends up seeing is decided by how much layout their screen happens to
/// be doing. A cache that outlives the view is the only thing that makes the answer the same
/// every time.
///
/// Kept by address, by screen, and by tier. **Not** by the size it is drawn at: that is unbounded
/// — an avatar at 28pt, a slot at 96pt, a viewer at whatever the window is — and would decode one
/// photograph three times over. A tier is a decode budget with exactly two values chosen by what
/// the call site is *for* rather than how large it happens to be, so the number of decodes per
/// address is bounded by construction.
///
/// Nothing is fetched directly. Every request goes through an `HTTPClient`, which is what keeps
/// `file:` and `data:` addresses — and anything else a hostile instance puts in an `avatar`
/// field — from ever reaching a socket: `URLSessionClient` refuses everything but `https`.
///
/// ## What admission rests on
///
/// Room is made by recency, and **admission by recency requires that the set of things wanted be
/// established before any of them is satisfied.** This holds because SwiftUI cannot run a `.task`
/// during `body` evaluation — the modifier is not attached until `body` returns — so every
/// visible body reads before any task fires. Reads batch; completions scatter, so a fetch is
/// judged on the interest its row carries **at the moment it lands**, not the one it carried when
/// it was commissioned — a row still being drawn has re-stamped every pass since.
///
/// There is no safe direction to err in. Declining used to look like the cautious answer; with
/// `.crowded` terminal it is not, because an over-decline is permanent damage to a row the reader
/// can see rather than a delay.
///
/// **Never `await fetch` sequentially in a loop.** A call site that reads and satisfies in the
/// same pass defeats admission entirely, because the newcomer is then genuinely the most recently
/// wanted thing every time.
///
/// **I8 — every visible key's `interest` must be re-stamped between one arrival and the next
/// `startedAt` sample.** This comes from `pictures` being a single coarse-grained `@Observable`
/// property read inside `RemoteImage.body`, so an eviction re-runs every visible body. Narrowing
/// that invalidation, or moving the read out of `body`, makes the admission check unreachable and
/// the refetch chain unbounded — **the latch does not cover this, because the declining branch
/// that writes `.crowded` is never taken.**
///
/// Three changes the design cannot tolerate, two of them otherwise reasonable cleanups:
///
/// 1. An `EquatableView`, or any wrapper that lets SwiftUI skip a body when its inputs compare
///    equal.
/// 2. Splitting `pictures` into per-key observable storage.
/// 3. Moving the `cache.picture(…)` read out of `body` into `onAppear` or `task` — the natural
///    fix for "a view body must not mutate model state", and the one most likely to be proposed.
///
/// Each turns this file into one to six real multi-megabyte refetches per pass to a third-party
/// instance, forever, with nothing in the suite going red. Under narrow observation no other row
/// has re-run since its last admission, so the newcomer is structurally the newest thing in the
/// cache every time, there is always exactly one older key to evict, and nothing is ever
/// declined. It is the same structural failure as sampling the clock at task creation, arriving
/// from the other side: both make everything permanently evictable.
///
/// Two-phase ordering gives the order *within* a pass; I8 keeps it current *across* arrivals, and
/// I8 is the load-bearing one.
///
/// **I9 — `.crowded` is terminal until the reader says otherwise**, and is the backstop for I5
/// being violated. It is **not** a backstop for I8: when I8 is broken the branch that writes it
/// never runs. Relief must come from an event the crowded cohort cannot itself cause, and there
/// is exactly one: `forget(host:)`, driven by a press on Usage. Nothing automatic has ever
/// passed that test — see `Absence.crowded`.
///
/// The second face of that trade: a row which genuinely **scrolls away while its fetch is in the
/// air** lands, is correctly declined — nothing wants it any more — and is then terminally
/// marked, so scrolling back to it finds a `photo` glyph that will not clear. Sampling on arrival
/// does not fix this and nothing here does; it is the latch biting a row that did nothing wrong,
/// and it is reachable only where declining is reachable at all.
///
/// ## The contract this file is safe under
///
/// **At most three viewer-tier addresses alive at once** — unit 7's limit, and the reason is
/// consequence rather than headroom. At six keys the cache is full at viewer tier and the seventh
/// is the first that can be turned away; a full viewer tier is the only place admission can
/// decline; and a decline is permanent for the life of the process. Breaking this does not cost
/// memory, it strands rows with a `photo` glyph that scrolling away and back will not clear.
/// There is a debug tripwire on it in `keep`, counting addresses rather than keys.
///
/// **I2 — `budget ≥ 2 × viewerAddresses × Tier.viewer.ceiling`.** The factor of two is display
/// scale: a window dragged between a 2× and a 1× display holds both decodes of every address
/// until the stale-scale keys are evicted. **The contract counts addresses because that is what
/// the app draws; the budget must fund keys because that is what the cache holds.** Two
/// quantities, each in its natural unit, linked by scale.
///
/// **At the contract limit the margin is exactly zero, not two-fold.** Three addresses during a
/// scale change fills the viewer tier completely — safe, because full is not declining, but there
/// is nothing spare. If unit 7 ever raises three to four, the budget goes to 128MB in the same
/// commit. The old reading of this invariant — "six fit against the three the app shows, so
/// double the headroom" — was accidentally right: six *is* three addresses at two scales, and
/// there was never any headroom in it.
///
/// What bounds the duplication: a stale-scale key is read by nothing once the window has moved,
/// so it is immediately evictable and clears on the next admission. The two is a transient peak,
/// and funding that peak is what the budget is for. A three-display Mac could stage three scales
/// briefly; the self-clearing is why that is not worth planning for.
///
/// ## Which server a picture came through
///
/// **I10 — every held picture carries the set of sources it was read through, and nothing here
/// can work out that set for itself.** An attachment, an emoji or an avatar address usually
/// points at a CDN — `files.first.example`, an S3 bucket — and not at the instance the reader
/// added, so the host cannot be read back off the URL. It has to be attached by the call site
/// that knows it, which is why `host` is required on `picture`, `fetch` and `RemoteImage` for
/// the same reason `tier` is: a call site that forgets silently makes an entry the reader's
/// Clear button can never reach.
///
/// A **set**, because one address is read through two sources at once. The case that reaches
/// this today is **one avatar drawn by two rows that arrived through different servers** — the
/// same author, or the same CDN address, on two of the reader's timelines — and it is the read
/// in `picture(…)` that tags the second one. So `forget(host:)` strikes that host off each entry
/// and evicts only where no tagged source is left.
///
/// Not, note, a merged row: `RemoteImage.host` is one `String`, so a row folded from two servers
/// is tagged with the source it is drawn under and no other. If a later unit gives a row more
/// than one source, tagging it with all of them is a change here, not an emergent property.
///
/// **This is deliberately the opposite of `EmojiCatalogueStore`, which puts the host in the
/// key**, and the inconsistency is the design rather than a bug in one of them. Duplicating a
/// photograph is expensive, so this cache shares one entry between sources and pays for it with
/// a Clear that frees nothing until the last source goes. Duplicating an emoji costs about 10KB
/// against a 24MB budget, so that cache duplicates and buys a Clear that frees on the spot. Two
/// answers to one reader-facing promise, each right where it is.
///
/// **Two maps carry sources, and they are bounded differently.** `sources` rides along with
/// `pictures`: its key set is exactly `pictures`'s, so the byte budget and the count bound that
/// hold one hold the other, and it is maintained at the two ordered places a picture leaves.
/// `missingSources` cannot ride along the same way, because `missing` has a bound of its own and
/// drops an **arbitrary** key to stay under it — `Dictionary.keys` has no order and giving a
/// negative cache its own LRU would be a second eviction policy for nothing. A parallel map with
/// no order to follow has to be trimmed in the same loop, at the same key, in the same pass; so
/// `note` does both, and nothing else may remove from `missing` without removing from it. One
/// button clears both maps and neither bound is the other's.
///
/// ## What Clear means
///
/// **Clear drops the cache; it does not forget the server.** The reader is still reading that
/// server — its row is still on Usage, its timeline still theirs — so what the button
/// empties is what this device happens to be holding, and the pictures are read again as they
/// are wanted. The other reading, where the rows go too, is a much larger action than the word
/// says and belongs to a Remove button nobody has asked for.
///
/// That settles a question this file could not answer while nothing called `forget(host:)`:
/// **a row still on screen re-tags the host the reader just cleared**, because `picture(…)` puts
/// `host` back on every body pass and the generation bump guarantees a pass. Under "drop the
/// cache" that is correct rather than a leak — a source drawing a picture is a source holding
/// it, and the entry is re-earned by something the reader is looking at. It has one consequence
/// worth naming: a **shared** entry two sources are both drawing can never be freed by clearing
/// them one after the other, because the first one's row puts it back before the second press.
/// Two servers on screen showing one photograph is one photograph, and that is the same trade
/// the set was chosen for.
///
/// **What keeps the button from appearing to do nothing** is navigation rather than anything
/// here: Usage is a *place*, so on macOS the timeline is not in the view tree while the
/// reader is pressing Clear, nothing re-tags, and the readout beside the button falls to zero
/// where they can see it. On iOS compact the pages are tabs and the timeline's tree is alive
/// behind, so the same press frees less and the number recovers. **If a later unit makes
/// Usage a sheet over the timeline, Clear stops freeing and starts refetching on every
/// platform** — the behaviour is still correct and the screen stops being able to show it.
@MainActor
@Observable
final class ShellPictures {
    static let shared = ShellPictures()

    /// How much of a picture this call site can afford to hold, which is not the same as how
    /// large it is drawn. Two values, not a size: the slot and the avatar want a thumbnail, and
    /// `v` over the whole app wants the photograph. A third tier would be a size in disguise.
    enum Tier: String, Hashable, Sendable, CaseIterable {
        /// The 96pt slot, the edges under it, the avatar, an emoji still.
        case deck
        /// `v`, over the whole app.
        case viewer

        var maxPixels: Int {
            switch self {
            case .deck: 320
            case .viewer: 2048
            }
        }

        /// The most one decode in this tier can ever cost. Holds only because `normalise`
        /// guarantees at most four bytes to the pixel.
        var ceiling: Int { maxPixels * maxPixels * 4 }
    }

    struct Key: Hashable {
        let url: URL
        let scale: CGFloat
        let tier: Tier
    }

    /// Why there is no picture — and, more to the point, whether asking again could ever change
    /// the answer.
    enum Absence: Error, Sendable {
        /// Something answered, and the answer was not a picture: a refusal, an address that is
        /// not fetchable, or bytes that will not decode. Waiting changes none of that.
        case refused
        /// Nothing answered. The address may be perfectly good and the network simply dark, so
        /// this is forgotten the moment anything at all gets through.
        case unreachable
        /// The screen is asking for more picture than the cache is allowed to hold, and keeping
        /// this one would mean dropping one a row is drawing right now. Declined rather than
        /// admitted, because admitting it starts a refetch that never ends: what is dropped is
        /// re-asked for, and re-asking drops another.
        ///
        /// A floor, not a mechanism. With two decode tiers no layout this app can draw reaches
        /// it. If a reader ever sees it, a unit has drawn more at once than the contract allows,
        /// and the visible symptom is the point — a screen of `photo` glyphs gets reported; two
        /// thousand silent requests to somebody else's server do not.
        ///
        /// This mark is **permanent for the life of the process**, and that is not an oversight.
        /// Every automatic recovery tried re-opened the livelock: the cohort's own re-asking
        /// produces the evictions that would trigger the next recovery, so the relief signal sits
        /// inside the loop it is meant to end. `heldBytes` cannot serve either — LRU frees
        /// exactly enough to fit, so once full it is pinned at budget and no threshold on it ever
        /// fires again.
        ///
        /// **Any future relief must be driven by an event this cohort cannot itself cause** — a
        /// deliberate, external one: the viewer closing, the place changing, the app returning
        /// from background. It is the same rule as the generation split: bulk, deliberate
        /// invalidations bump; anything the cache can reach on its own does not.
        ///
        /// **There is exactly one such relief, and it is the reader's Clear button.** A press on
        /// Usage is the permitted class by construction: a crowded cohort cannot reach a
        /// button, so the signal is outside the loop it ends rather than inside it, which is what
        /// every rejected automatic relief got wrong. `forget(host:)` lifts this mark for the
        /// source it was noted under, alongside `.refused` and `.unreachable` and by the same
        /// rule — a mark shared with a second source survives until that source is cleared too.
        /// "Permanent for the life of the process" now means "until the reader says otherwise",
        /// which is the sentence decision 14 was always going to turn it into.
        case crowded

        /// Whether asking again could ever change the answer by itself.
        var asksAgain: Bool { self == .unreachable }
    }

    /// The most of a response that will be accepted — see `body` for what that does and does not
    /// buy, which is less than it ought to.
    nonisolated static let maxBytes = 20 * 1024 * 1024

    /// How many fetches may be in the air at once.
    ///
    /// Not about politeness. The transport bounds **one** response and says so: the count
    /// belongs to the caller, because the caller is the only layer that knows how many rows are
    /// on screen. Without this, thirty rows each holding a body inside the ceiling is thirty
    /// times the ceiling resident at once, and `httpMaximumConnectionsPerHost` does not bound it
    /// — it is unenforced here, and it would count hosts rather than bytes anyway.
    ///
    /// So the resident worst case is exactly this times `maxBytes`. The tier caps what a decode
    /// costs and does nothing for the download; this is what caps the download.
    nonisolated static let maxInFlight = 4

    /// How much decoded picture is kept, in bytes rather than in entries.
    ///
    /// Counting entries was the wrong bound: a hundred and twenty of these at their largest is
    /// most of a gigabyte, and a hundred and twenty thumbnails is nothing at all. The same number
    /// cannot describe both, and what runs a device out of memory is the bytes.
    ///
    /// Six viewer decodes or two hundred and forty-five deck ones. The slack over the four or so
    /// a screen can want is deliberate: at a tighter budget the viewer tier starts declining
    /// while units 6 and 7 are still drawing, and four against three is not a margin.
    nonisolated static let budget = 96 * 1024 * 1024

    /// How many refusals are worth remembering. Bounded for the reason the pictures are: a
    /// collection that only grows is the leak this class exists in order not to have.
    nonisolated static let refusals = 512

    /// Unit 7's limit: at most this many viewer-tier **addresses** alive at once.
    ///
    /// One number, read by the budget invariant, by the debug tripwire in `keep`, and by the test
    /// that ties them together — so raising it fails the budget assertion rather than quietly
    /// stranding rows.
    nonisolated static let viewerAddresses = 3

    /// How many pictures are kept, however small they are.
    ///
    /// The byte budget is the memory bound and it is the important one, but it is not a bound on
    /// *count*. Emoji and avatars come through here too and those are cheap, so a reader who
    /// scrolls far enough accumulates tens of thousands of entries well inside the budget — and
    /// every one of them is length in the dictionaries this walks on the main actor. Two bounds,
    /// because they answer two different questions.
    nonisolated static let held = 512

    /// How many keys' worth of interest is remembered.
    ///
    /// At least twice `held`, and that ratio is load-bearing: `trimInterest` may never drop a
    /// key that has a picture, so it can only reach its low-water mark out of the keys that do
    /// not. With half the map guaranteed disposable, trimming always succeeds in one pass.
    nonisolated static let remembered = 2 * held

    private struct Held {
        let picture: Image
        let cost: Int
    }

    private var pictures: [Key: Held] = [:]

    /// Which sources each held picture was read through — I10.
    ///
    /// **Its key set is exactly `pictures`'s**, which is what makes it bounded without a bound of
    /// its own: it is written only where a picture is admitted and where one is read back, and
    /// cleared at both of the two places a picture leaves — the eviction loop in `keep` and
    /// `forget(host:)`.
    ///
    /// Beside `pictures` rather than inside `Held` because tagging happens on a **read**, and
    /// `picture(…)` is called from `RemoteImage.body`. Mutating an observed property there would
    /// invalidate every visible body on the spot — which is a refetch storm wearing the costume
    /// of a one-line tidy-up. `interest` sits out here for the same reason.
    @ObservationIgnored private(set) var sources: [Key: Set<String>] = [:]

    /// What has been asked for and answered with nothing, and why. Held so a picture that is not
    /// there is drawn as absent rather than as forever arriving — and so it is asked for once
    /// rather than on every rebuild of every row that shows it.
    private(set) var missing: [Key: Absence] = [:]

    /// Which sources each record of nothing was noted under — I10's other half, and the thing
    /// that makes a Clear reach a mark rather than only a picture.
    ///
    /// Without it, a surviving `.refused` for a cleared server means the device still remembers
    /// "that server's avatar is not there" and declines to ask again: the reader clears, re-adds,
    /// and gets a blank row for the rest of the run. `.crowded` is the same shape with a longer
    /// shadow — see `Absence.crowded`.
    ///
    /// **Its key set is exactly `missing`'s, and it is kept so by hand rather than by ordering.**
    /// See the header: `missing` drops an arbitrary key at its bound, so this is trimmed in the
    /// same loop in `note`. Every removal from `missing` removes from here too, and
    /// `theMapsOfNothingAgree` holds the pair.
    @ObservationIgnored private(set) var missingSources: [Key: Set<String>] = [:]

    /// Bumped only by a **cohort** changing its mind — a network that came back, or a reader
    /// clearing one server. That is a fact about a set of addresses which no single view can
    /// observe for itself.
    ///
    /// Ordinary eviction deliberately does **not** bump it. Eviction is a fact about one key, and
    /// the view that lost its picture already sees `have` go true→false through `pictures`, which
    /// is observed. Telling every other view as well is what turns one eviction into a storm, and
    /// the storm into a refetch loop.
    ///
    /// **And a third case, which is neither**: a single deliberate drop whose only observer is
    /// going away — `releaseViewerTier()`. It is deliberate, so the eviction clause does not
    /// cover it; it is one key and nobody is owed a fresh ask, so the cohort clause does not
    /// either. The test is not "was this deliberate" but "is there a row still on screen that
    /// needs telling". Written down here rather than left to be guessed at the next call site.
    private(set) var generation = 0

    /// A fetch on the wire, and which sources are still waiting on it.
    ///
    /// The set is what stops `forget(host:)` being undone a moment later by work that was already
    /// running — see `forget(host:)`. It is also how a second source joining an existing fetch is
    /// recorded, since the picture that lands is then tagged for both.
    struct Fetch {
        var hosts: Set<String>
        let task: Task<Void, Never>
    }

    /// The task drawing each picture while it is being drawn, so every view wanting the same one
    /// waits on the same work and a view going away does not take that work with it.
    @ObservationIgnored private(set) var inFlight: [Key: Fetch] = [:]

    /// Held keys, least recently wanted first.
    ///
    /// Worked out when it is needed rather than maintained as it changes. Keeping a list in step
    /// costs an O(n) removal inside `picture`, which runs once per visible row per frame; this
    /// runs once per admission, which is once per fetch. The hot path is the one that has to be
    /// cheap.
    /// Each clock is looked up once and then sorted on, rather than looked up inside the
    /// comparator: a `Key` hashes a `URL`, and a comparator does that twice per comparison.
    ///
    /// The `?? 0` is the same belt as the one at the eviction site and is equally unreachable,
    /// because `trimInterest` never drops a key that has a picture. Removing it is not a
    /// tidy-up: a held key with no stamp sorts to the front at zero, and the eviction site reads
    /// `0 < startedAt` and drops it immediately. That is the I7 thrash, restored in silence.
    var order: [Key] {
        pictures.keys
            .map { ($0, interest[$0] ?? 0) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    @ObservationIgnored private(set) var heldBytes = 0

    /// Counts every expression of interest, so "wanted since this fetch began" is answerable.
    @ObservationIgnored private(set) var clock = 0

    /// When each key was last asked about — **whether or not there was anything to give back.**
    ///
    /// Recording the misses is what makes admission work. A row whose picture has been declined
    /// still reads for it on every pass, so its interest keeps up with its neighbours'; without
    /// that the cache cannot tell a row that is still on screen from one that scrolled away, and
    /// every newcomer looks like the most-wanted thing in the cache.
    @ObservationIgnored private(set) var interest: [Key: Int] = [:]

    @ObservationIgnored private var active = 0
    @ObservationIgnored private var queued: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored let http: any HTTPClient

    /// The copies of pictures already on this device, where there are any to keep.
    ///
    /// Read before the network and written after it, so a picture fetched once is drawn from this
    /// device on every launch after. Nothing where the caller keeps none — a test, a preview.
    /// Settable because `shared` is built before the app knows where its caches live; the app
    /// hands it over once, at launch, before any row asks for a picture. See `DiskCopies` for
    /// why every touch goes through one queue.
    @ObservationIgnored var disk: DiskCopies?

    /// Whether this cache holds its caller to unit 7's viewer-tier contract in debug builds.
    ///
    /// Scoped on intent rather than on being the shared instance. "Nothing else builds one" is
    /// true today and enforced by nothing, and a convention that cannot be checked is the shape
    /// of argument this file has already had falsified more than once. Saying `false` here is
    /// self-documenting and visible in review, which is the whole of what it needs to be.
    @ObservationIgnored private let enforcingViewerContract: Bool

    init(
        http: any HTTPClient = ShellPictures.live,
        disk: (any MediaCopies)? = nil,
        enforcingViewerContract: Bool = true
    ) {
        self.http = http
        self.disk = disk.map { DiskCopies($0) }
        self.enforcingViewerContract = enforcingViewerContract
    }

    /// The picture, where it is already in hand. Draws on the first pass, which is what removes
    /// the flash of the waiting shape every time a reader scrolls back to a row.
    ///
    /// `host` is the source this row is being read under, and a hit tags the entry with it — I10.
    /// Tagging on the read is what lets one picture belong to two sources without either of them
    /// having to know about the other: whichever source fetched it, every source that draws it
    /// says so on its own next pass.
    func picture(_ url: URL?, scale: CGFloat, tier: Tier, host: String) -> Image? {
        guard let url else { return nil }
        let key = Key(url: url, scale: scale, tier: tier)
        wanted(key)
        guard let held = pictures[key] else { return nil }
        sources[key, default: []].insert(Self.tag(host))
        return held.picture
    }

    /// Whether this one has been asked for and came back with nothing. Every kind of nothing says
    /// yes: the reader is shown the same mark either way, and only `fetch` cares which it was.
    func isMissing(_ url: URL?, scale: CGFloat, tier: Tier) -> Bool {
        guard let url else { return false }
        return missing[Key(url: url, scale: scale, tier: tier)] != nil
    }

    /// Fetches and decodes it, unless somebody already is, or already has, or already found out
    /// that asking again cannot help.
    ///
    /// `host` is required for the reason `tier` is — see I10.
    func fetch(_ url: URL?, scale: CGFloat, tier: Tier, host: String) async {
        guard let url else { return }
        let key = Key(url: url, scale: scale, tier: tier)
        guard pictures[key] == nil, missing[key]?.asksAgain ?? true else { return }
        await work(for: key, host: Self.tag(host)).value
    }

    /// A press asking again: lifts the mark of nothing for this address and runs the same
    /// `fetch` a first ask does. Does not bump `generation`, so a retry of one picture is not
    /// a cohort of every other miss. A nil URL is still nothing to try. A second miss writes
    /// over the first — `note` replaces, it does not append.
    func retry(_ url: URL?, scale: CGFloat, tier: Tier, host: String) async {
        guard let url else { return }
        let key = Key(url: url, scale: scale, tier: tier)
        missing.removeValue(forKey: key)
        missingSources.removeValue(forKey: key)
        await fetch(url, scale: scale, tier: tier, host: host)
    }

    private func work(for key: Key, host: String) -> Task<Void, Never> {
        if let running = inFlight[key] {
            // A second source wanting the same picture joins this fetch rather than starting
            // another, and is tagged on what lands — two rows from two servers drawing one
            // address, which is the case I10's set is for. Not a merged row: see the header.
            inFlight[key]?.hosts.insert(host)
            return running.task
        }
        let client = http
        let disk = disk
        // Unstructured on purpose: the caller is a view's `.task`, and that is cancelled by any
        // rebuild. What it cancels has to be this view's waiting and not the work itself.
        //
        // The task is created and registered eagerly so that dedup still works and every asker
        // waits on this one piece of work; only the network call queues behind the gate.
        let started = Task { @MainActor in
            // **The copy on this device first, and outside the gate.** The gate bounds what is
            // on the wire; a read from disk puts nothing there.
            let answer: Result<Loaded, Absence>
            if let disk, let kept = await Self.copy(of: key.url, in: disk, host: host, maxPixels: key.tier.maxPixels) {
                answer = .success(Loaded(image: kept, fresh: nil))
            } else {
                await self.enter()
                answer = await Self.load(key.url, using: client, maxPixels: key.tier.maxPixels)
                self.leave()
            }
            defer { self.inFlight[key] = nil }

            // **The guard that stops a `forget` being undone by work already running.** This
            // exact bug has been through here twice — `EmojiCatalogueStore` had it and the emoji
            // cache had it: clearing the stored state alone leaves a fetch in the air which lands
            // a moment later and files the entry back under the host the reader just cleared. The
            // mechanism is the catalogue's: the in-flight record carries who the work belongs to,
            // `forget(host:)` strikes that host off it, and the task re-reads the record **after**
            // its suspension rather than trusting what it captured before.
            //
            // **Above the switch, so it covers the failure too.** An answer nobody is waiting for
            // any more is dropped whichever kind of answer it is.
            //
            // This guard used to be justified by `.refused` being unliftable — `missing` carried
            // no host to clear by — and **that justification is now false**: `missingSources`
            // carries it, and `forget(host:)` lifts the mark. The guard stays, on the two reasons
            // that were always the real ones. A mark noted here would be **filed under the host
            // the reader just cleared**, which re-files their cleared server into both maps a
            // moment after they emptied it — the twice-shipped bug above, arriving through the
            // failure branch instead of the success one. And the work itself is a request to a
            // stranger's server that nobody is waiting for. Neither is repaired by the mark being
            // liftable later; the reader would have to press Clear a second time to undo the
            // first one's own wake.
            let tagged = self.inFlight[key]?.hosts ?? []
            guard !tagged.isEmpty else { return }

            switch answer {
            case .success(let loaded):
                let decoded = loaded.image
                // Who the copy is kept under is decided **after** the guard above and on this
                // actor, so a Clear that struck every host off this fetch also stops its bytes
                // being written back under the host it just emptied. The asker's host while it
                // is still tagged, otherwise whoever is still waiting.
                let owner = tagged.contains(host) ? host : tagged.min()
                if let fresh = loaded.fresh, let disk, let owner {
                    disk.store(fresh, host: owner, url: key.url)
                }
                self.keep(
                    Image(decorative: decoded, scale: key.scale),
                    cost: decoded.height * decoded.bytesPerRow,
                    for: key,
                    // **Sampled here, on arrival, not where the task was created.** The
                    // question `startedAt` answers is "when was this newcomer wanted", and at
                    // the moment of the decision the honest answer is its *current* interest: a
                    // row still being drawn is still wanted and has re-stamped every pass since
                    // it was commissioned, so a creation stamp understates its claim and
                    // declines rows that deserve admission. Measured, arrival is never worse —
                    // same termination, same request count, and strictly fewer permanent marks.
                    //
                    // Zero when no body has asked at all, which is a fetch nobody is drawing
                    // yet: a neighbour read ahead of the scroll, or a kick on becoming active.
                    // **Speculative work never displaces work a view has actually asked for** —
                    // with nothing older than it, such a fetch can evict nothing and is
                    // admitted only if it fits outright.
                    startedAt: self.interest[key] ?? 0,
                    hosts: tagged
                )
            case .failure(let absence):
                self.note(absence, for: key, hosts: tagged)
            }
        }
        inFlight[key] = Fetch(hosts: [host], task: started)
        return started
    }

    private func enter() async {
        if active < Self.maxInFlight {
            active += 1
            return
        }
        // Resumed holding the slot the leaver handed over, so `active` does not move.
        await withCheckedContinuation { queued.append($0) }
    }

    private func leave() {
        if queued.isEmpty {
            active -= 1
        } else {
            queued.removeFirst().resume()
        }
    }

    /// Admits a decoded picture, or declines it.
    ///
    /// Room is made oldest-first, but never past something a view has wanted since this fetch
    /// began. When room cannot be made without dropping a picture that is being drawn right now,
    /// the newcomer is declined instead — that branch is the only thing that ends the loop where
    /// what is dropped is re-asked for and re-asking drops another.
    ///
    /// `hosts` is who this picture was read through, and it is unioned rather than replaced: a
    /// picture re-fetched for one source does not forget the others that were drawing it. Empty
    /// is not a legal argument — see I10 — which is why there is no default.
    func keep(_ picture: Image, cost: Int, for key: Key, startedAt: Int, hosts: Set<String>) {
        // Debug-only tripwire on I10, the same convention as the viewer contract below and for
        // the same kind of reason. "No default" stops a call site omitting the argument; it does
        // not stop one passing an empty `Set`, and an entry admitted with no source is one the
        // reader's Clear button can never reach — which is the whole of what making `host`
        // required was for. Key-set parity survives it, so no invariant test catches it either.
        //
        // It fires *before* `forgottenDuringAFetchDoesNotComeBack` can report, so deleting the
        // in-flight guard in `work` aborts the suite here rather than failing that test. That is
        // louder, not quieter — but if you are reading this from a crash log, the guard above the
        // `switch` in `work` is what you removed.
        assert(!hosts.isEmpty, "A picture kept under no source is one no Clear can reach. See I10.")

        let already = pictures[key]?.cost ?? 0
        var bytes = heldBytes - already + cost
        var count = pictures.count + (already > 0 ? 0 : 1)
        var evictable: [Key] = []

        // A `startedAt` of zero can outrank nothing, so there is no order worth working out —
        // the speculative case skips the sort entirely rather than sorting to find that out.
        if bytes > Self.budget || count > Self.held, startedAt > 0 {
            // `order` is sorted by interest, so the first key that is too recent to evict means
            // every key after it is too. Both guards stop the walk rather than filtering it.
            for old in order {
                guard bytes > Self.budget || count > Self.held else { break }
                // The zero is a belt: `trimInterest` never drops a key that has a picture, so every
                // key in `order` has an interest entry.
                guard old != key, let held = pictures[old],
                      interest[old] ?? 0 < startedAt else { break }
                evictable.append(old)
                bytes -= held.cost
                count -= 1
            }
        }

        guard (bytes <= Self.budget && count <= Self.held) || pictures.isEmpty else {
            note(.crowded, for: key, hosts: hosts)
            return
        }
        for old in evictable {
            if let gone = pictures.removeValue(forKey: old) { heldBytes -= gone.cost }
            sources.removeValue(forKey: old)
        }

        heldBytes -= already
        pictures[key] = Held(picture: picture, cost: cost)
        heldBytes += cost
        sources[key, default: []].formUnion(hosts.lazy.map(Self.tag))
        missing.removeValue(forKey: key)
        missingSources.removeValue(forKey: key)
        wanted(key)

        // Something got through, so the network is back, so everything written off while it was
        // down deserves another go. Nothing similar happens for `.crowded`: see `Absence`.
        forgetUnreachable()

        // Debug-only tripwire on the unit 7 contract. Counting, not inferring.
        //
        // Counts **addresses**, which is what the contract limits, and not keys. A key carries
        // the screen's scale, so a window dragged from a 2× display to a 1× one turns three
        // addresses into six keys while unit 7 sits exactly inside its budget.
        //
        // No slack, deliberately. A `+1` sized against key-counting intuition is exactly what
        // breaks here: four addresses across two scales is eight keys, six fit, and keys seven
        // and eight decline permanently — while a `<= 4` assert stays silent. At three the worst
        // case is six keys, which is full, and full cannot decline: the seventh is the first that
        // can. A fourth address is a contract change rather than a transient, so tripping on it
        // is correct.
        //
        // The price of this is an init parameter on every test that exceeds the contract on
        // purpose, and it is worth paying for one specific reason rather than a general one:
        // this contract is the only thing standing between unit 7 and stranded rows.
        //
        // The latch has since gained exactly one relief — the reader's Clear button, see
        // `Absence.crowded` — and that is the revisit this comment used to ask for. It does not
        // retire the tripwire. Relief a **reader** has to find and press is not relief the app
        // provides: a row stranded by unit 7 drawing more at once than the contract allows is
        // still stranded for every reader who never opens Usage, and "press Clear" is not
        // an answer anybody would arrive at from a `photo` glyph. What the relief changes is the
        // consequence of being wrong, from permanent to recoverable; what it does not change is
        // that being wrong is a defect.
        assert(
            !enforcingViewerContract
                || Set(pictures.keys.lazy.filter { $0.tier == .viewer }.map(\.url)).count
                <= Self.viewerAddresses,
            "More viewer-tier addresses held than the unit 7 contract allows "
                + "(\(Self.viewerAddresses)). Past 6 keys the declining branch becomes reachable "
                + "and a decline is permanent. See I9."
        )
    }

    /// Writes down why there is nothing, bounded, and under whose sources.
    ///
    /// The entry dropped to stay under the bound is an arbitrary one rather than the oldest:
    /// `Dictionary.keys` has no order and giving this its own ordering would be a second LRU for
    /// a negative cache. Losing the wrong refusal costs one extra request; it cannot loop,
    /// because the entry just written is never the one removed.
    ///
    /// `hosts` is required, and for the same reason it is required on `keep`: a mark filed under
    /// no source is one the reader's Clear button can never lift, which is exactly the blank row
    /// this whole map was given sources for. Both production call sites hold the set already —
    /// the failure branch in `work` holds who is still waiting on the fetch, and the declining
    /// branch in `keep` holds who the picture was read through — so neither has to invent one.
    /// It is unioned rather than replaced: two servers drawing one broken address have both been
    /// told the same thing.
    func note(_ absence: Absence, for key: Key, hosts: Set<String>) {
        assert(!hosts.isEmpty, "A mark noted under no source is one no Clear can lift. See I10.")
        missing[key] = absence
        missingSources[key, default: []].formUnion(hosts.lazy.map(Self.tag))
        // The parallel map is trimmed here and only here, because this is where the arbitrary
        // choice of victim is made. See the header on why it has no ordering to inherit.
        while missing.count > Self.refusals,
              let spare = missing.keys.first(where: { $0 != key }) {
            missing.removeValue(forKey: spare)
            missingSources.removeValue(forKey: spare)
        }
    }

    private func forgetUnreachable() {
        guard missing.contains(where: { $0.value == .unreachable }) else { return }
        // Over a copy, because the body writes back into the map it is walking — the same
        // reason, and the same shape, as the two sweeps in `forget(host:)`. Three loops that do
        // the same thing should not be written three ways: a reader who finds one of them
        // different will assume the difference is meant.
        let noted = missing
        for (key, absence) in noted where absence == .unreachable {
            missing.removeValue(forKey: key)
            missingSources.removeValue(forKey: key)
        }
        generation += 1
    }

    /// Records that somebody asked about this key. Runs inside a view's body, once per visible
    /// row per frame, so it does no work that grows with what the cache is holding.
    private func wanted(_ key: Key) {
        clock += 1
        interest[key] = clock
        trimInterest()
    }

    /// Drops everything this device holds from one server: the reader pressing Clear on that row.
    ///
    /// **A host is struck off each entry, and an entry goes only when no tagged source is left**
    /// — I10. A picture two sources are both reading is one picture, so clearing the first frees
    /// nothing; that is the price of not holding it twice, and it is the right price for a
    /// photograph. The emoji cache, where a duplicate is 10KB, took the other side of the trade.
    ///
    /// **Bumps the generation**, unlike ordinary eviction. This is the split the file's header
    /// states: a bulk, deliberate invalidation is a fact about a cohort no single view can see
    /// for itself, and what a row still on screen is owed afterwards is a fresh ask. Eviction is
    /// a fact about one key and stays silent. It bumps whether or not anything was held, because
    /// a reader who presses Clear has made a decision, not a query.
    ///
    /// Work already in flight is struck off too, so the answer cannot land behind the reader and
    /// file itself back under the host they just cleared. The in-flight entries are **not**
    /// removed: the task still has to tidy its own record away, and a fetch another source is
    /// still waiting on is still that source's fetch.
    ///
    /// **Two sweeps, because there are two things a Clear has to reach.** The pictures are the
    /// obvious half; the marks saying why a picture is absent are the half that is reader-visible
    /// and was missing. A `.refused` surviving for a cleared server means the device still
    /// remembers "that avatar is not there" and will not ask again, so a reader who clears a
    /// server and re-adds it gets a blank row for the rest of the run — decision 14's promise not
    /// kept. A `.crowded` surviving is the same bug with I9's shadow over it, and lifting it here
    /// is permitted rather than a hole in I9: a crowded cohort cannot press a button, so this
    /// signal sits outside the loop it ends.
    ///
    /// Both sweeps strike the host off and drop only where no source is left, so one rule covers
    /// both maps: a picture two servers are drawing, and a refusal two servers were both told,
    /// each survive until the last of them is cleared.
    func forget(host: String) {
        let host = Self.tag(host)
        strike { $0 == host }
        // The copies on this device go with the pictures in memory, whole: a copy on disk is
        // filed under one host only, so there is no second source for it to survive for.
        disk?.forget(host: host)
    }

    /// Drops every picture this device holds, in memory and on disk: the drop by cache (#7).
    ///
    /// `forget(host:)` for every host at once, through the same `strike`: nothing in flight lands
    /// behind it, the marks of absence go, and the generation bumps so every row on screen asks
    /// its hyperlink afresh. The rows themselves are the store's and are not touched here.
    func forgetAll() {
        strike { _ in true }
        disk?.removeAll()
    }

    /// Strikes every host `goes` names off work in flight, off the pictures held and off the marks
    /// of absence, dropping an entry where no host is left on it; then bumps the generation. The
    /// one body behind both `forget(host:)` and `forgetAll()`.
    private func strike(_ goes: (String) -> Bool) {
        // Over a copy of the keys, because the body writes back into the map it is walking.
        for (key, fetch) in inFlight where fetch.hosts.contains(where: goes) {
            inFlight[key]?.hosts = fetch.hosts.filter { !goes($0) }
        }
        // Likewise over a copy. What is evicted here keeps its `interest` stamp: I7 forbids a
        // held key without one and says nothing about a stamp without a picture, which is the
        // ordinary state of every address a row has ever read. `trimInterest` clears those.
        let tagging = sources
        for (key, tagged) in tagging where tagged.contains(where: goes) {
            let rest = tagged.filter { !goes($0) }
            guard rest.isEmpty else {
                sources[key] = rest
                continue
            }
            if let gone = pictures.removeValue(forKey: key) { heldBytes -= gone.cost }
            sources.removeValue(forKey: key)
        }
        let noted = missingSources
        for (key, tagged) in noted where tagged.contains(where: goes) {
            let rest = tagged.filter { !goes($0) }
            guard rest.isEmpty else {
                missingSources[key] = rest
                continue
            }
            missing.removeValue(forKey: key)
            missingSources.removeValue(forKey: key)
        }
        generation += 1
    }

    /// What each host's copies on this device weigh, read off the main actor. Empty where this
    /// cache keeps no copies on disk.
    func diskBytes(hosts: [String]) async -> [String: Int] {
        await disk?.bytes(hosts: hosts.map(Self.tag)) ?? [:]
    }

    /// Lets go of everything held at viewer tier, when the viewer stops drawing it.
    ///
    /// **This is what makes the unit 7 contract hold by construction rather than by discipline.**
    /// The contract counts *held* viewer-tier addresses, not live ones, and it has to: I2 funds
    /// what the cache holds, and the declining branch is reachable only when the viewer tier is
    /// full, which is a fact about held entries. Nothing here has a notion of "live" and acquiring
    /// one cheaply is the `interest` problem again.
    ///
    /// Without this, four addresses arrive at viewer tier from perfectly ordinary use — `v` on
    /// four posts in turn, or `v` and then three presses of `m` on a post carrying four pictures —
    /// and the tripwire is right to trip. With it, what is held is what the one open viewer is
    /// drawing, which is one. The assert stops being the thing standing between unit 7 and
    /// permanently stranded rows and becomes what an assert should be: a regression tripwire.
    ///
    /// **No generation bump**, and the rule on `generation` now names this case. The viewer is
    /// closing or turning; the deck behind it draws a different key at a different tier. Telling
    /// every visible body to re-ask would be the storm, for nobody's benefit.
    ///
    /// **It cannot livelock.** It frees bytes rather than asking for them, which is the helping
    /// direction, and it is driven by a reader's own action from outside this cache's loop. It is
    /// also, precisely, the "deliberate external event the crowded cohort cannot itself cause"
    /// that `Absence.crowded` names as the one legitimate relief signal. **It does not build that
    /// relief** — nothing here clears a `.crowded` mark — but this is where it would go.
    ///
    /// The `interest` stamps stay, for the reason `forget(host:)` leaves them: I7 forbids a held
    /// key without a stamp and says nothing about a stamp without a picture, which is the
    /// ordinary state of every address a row has ever read.
    func releaseViewerTier() {
        // Over a copy of the keys, because the body writes back into the map it is walking.
        for key in Array(pictures.keys) where key.tier == .viewer {
            if let gone = pictures.removeValue(forKey: key) { heldBytes -= gone.cost }
            sources.removeValue(forKey: key)
        }
    }

    /// What this device is holding that was read through one source: how many pictures, and what
    /// they cost. The reading beside the reader's Clear button, and the number that has to fall
    /// where they can see it — a button that appears to do nothing is the failure mode this
    /// screen is designed against.
    ///
    /// **Reads both observed properties this answer depends on, on purpose.** The loop walks
    /// `pictures` rather than `sources` so that a body calling this registers the observation
    /// even when nothing is held — a count that stops updating once it reaches zero is a readout
    /// that lies the moment anything arrives.
    ///
    /// But the loop *answers* from `sources`, which is `@ObservationIgnored` by design (see its
    /// own doc: it is written from `picture(…)` inside a view body, and an observed write there
    /// is a refetch storm). So there is one way this answer moves with `pictures` untouched:
    /// **a Clear that strikes a host off a shared entry.** Nothing in the loop would notice, and
    /// the reading would freeze at the pre-Clear figure — silently, and only for the shared case,
    /// which is the one hardest to notice by looking.
    ///
    /// `generation` closes it, because `forget(host:)` bumps it unconditionally. The read below
    /// exists for its side effect on observation and not for its value, which is exactly the kind
    /// of line a later tidy-up deletes; it is written as a discard with this paragraph over it so
    /// that deleting it has to be a decision.
    func holding(host: String) -> (count: Int, bytes: Int) {
        _ = generation
        let host = Self.tag(host)
        var count = 0
        var bytes = 0
        for (key, held) in pictures where sources[key]?.contains(host) == true {
            count += 1
            bytes += held.cost
        }
        return (count, bytes)
    }

    /// **Decision 21 — a host is folded once, where it enters, and every consumer may then
    /// compare exactly.** A hostname is case-insensitive by DNS, so two spellings of one host is
    /// an *ingestion* defect and not a comparison one — the same boundary logic as decision 9's
    /// `https` rule, which is enforced where the address arrives rather than at each socket.
    ///
    /// The boundaries are `Host.parse` for what the reader typed and `Source.init` for what came
    /// off the wire; both fold, and so do `EmojiCatalogue` and `EmojiCatalogueStore.key`. This
    /// fold and `EmojiCache.Key`'s are belt rather than the statement of the rule.
    ///
    /// **Bare `lowercased()`, never `lowercased(with: .current)`.** Unicode default case
    /// conversion is locale-independent; the Turkish locale maps `I` to `ı`, which for a hostname
    /// is a real difference rather than a theoretical one — a reader with a Turkish device would
    /// file `first.example` somewhere nobody else could find it. Every fold in this project is
    /// the bare form; keep it that way.
    private static func tag(_ host: String) -> String { host.lowercased() }

    /// Keeps `interest` bounded, oldest first.
    ///
    /// **Never drops a key there is a picture for.** The eviction predicate reads `interest`, so
    /// a held key missing from it would look infinitely stale and be evictable no matter how
    /// recently it was drawn — which is the thrash this whole mechanism exists to stop. The
    /// clause is load-bearing, not tidiness.
    ///
    /// Trims to three quarters rather than to the bound, so this does its sorting once every few
    /// hundred reads instead of on every read once the map is full.
    ///
    /// Named apart from `forget(host:)` on purpose: that one drops pictures a reader asked to be
    /// rid of, this one only forgets that a key was ever asked about.
    private func trimInterest() {
        guard interest.count > Self.remembered else { return }
        let target = Self.remembered * 3 / 4
        let spare = interest
            .filter { pictures[$0.key] == nil }
            .sorted { $0.value < $1.value }
            .map(\.key)
        for key in spare {
            interest.removeValue(forKey: key)
            if interest.count <= target { return }
        }
    }

    /// Off the main actor start to finish: a reader scrolling is the one thing this must not
    /// stand in the way of, and decoding a photograph is long enough to be felt.
    ///
    /// `@concurrent` rather than a bare `nonisolated async`, which today means the same thing and
    /// under a later language mode would not: the function would run on whatever actor called it,
    /// and what calls this is the main one.
    @concurrent
    nonisolated static func load(
        _ url: URL,
        using http: any HTTPClient,
        maxPixels: Int
    ) async -> Result<Loaded, Absence> {
        switch await body(url, using: http) {
        case .success(let data):
            guard let decoded = decode(data, maxPixels: maxPixels) else { return .failure(.refused) }
            return .success(Loaded(image: decoded, fresh: data))
        case .failure(let absence):
            return .failure(absence)
        }
    }

    /// A decoded picture, and the bytes it came from where they came off the network — which are
    /// what is worth keeping on disk. Nothing where it was read from disk in the first place.
    struct Loaded: Sendable {
        let image: CGImage
        let fresh: Data?
    }

    /// The copy of `url` already on this device under `host`, decoded, or nothing. A copy that
    /// will not decode is deleted and treated as no copy, so it is not read again on every ask:
    /// the network is asked, and what it sends takes its place.
    @concurrent
    nonisolated static func copy(
        of url: URL,
        in disk: DiskCopies,
        host: String,
        maxPixels: Int
    ) async -> CGImage? {
        guard let data = await disk.data(host: host, url: url) else { return nil }
        guard let decoded = decode(data, maxPixels: maxPixels) else {
            disk.remove(host: host, url: url)
            return nil
        }
        return decoded
    }

    /// Returns once every write and delete asked of the copies on this device has run.
    func diskSettled() async {
        await disk?.settled()
    }

    /// What the response carries, and only if it is worth carrying.
    ///
    /// The ceiling is enforced on the wire, not here: `live` builds its client with `maxBytes`,
    /// and the transport refuses a body that declares itself too big before any of it moves, and
    /// stops one that declared nothing at the byte it trips. This `data.count` check is the last
    /// belt on a client that does neither — a test fake, or a future transport — and it is what
    /// makes the guarantee true of every `HTTPClient` and not only of the live one: **nothing
    /// past `maxBytes` is ever decoded, kept, or drawn.**
    @concurrent
    nonisolated static func body(
        _ url: URL,
        using http: any HTTPClient
    ) async -> Result<Data, Absence> {
        do {
            let (data, response) = try await http.data(from: url)
            guard (200 ..< 300).contains(response.statusCode) else { return .failure(.refused) }
            guard data.count <= maxBytes else { return .failure(.refused) }
            return .success(data)
        } catch {
            return .failure(absence(from: error))
        }
    }

    /// A refusal is about the address and is worth remembering; a dark network is about right now
    /// and is not. Anything that is not plainly the second is treated as the first, because a
    /// refusal remembered wrongly costs one picture and an outage remembered wrongly costs all of
    /// them until the app is killed.
    nonisolated static func absence(from error: any Error) -> Absence {
        guard let error = error as? URLError else { return .refused }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .dnsLookupFailed:
            return .unreachable
        // A reader walking away is not a fact about the address. Nothing here can cancel today —
        // the work task is unstructured on purpose — so this is insurance against a later change
        // that makes it cancellable, which would otherwise write a scroll down as a refusal and
        // leave the row permanently blank.
        case .cancelled:
            return .unreachable
        default:
            return .refused
        }
    }

    /// The first frame of whatever it is, no larger than `maxPixels` on its longest edge and
    /// never more than four bytes to the pixel.
    ///
    /// `ImageIO` rather than `NSImage`/`UIImage` because it is the one API on both platforms that
    /// reads every format a server sends without being told which it is — and because it is the
    /// one that can be told to stop short. A thumbnail is never scaled *up*, so a small picture
    /// comes back at the size it was sent.
    nonisolated static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return normalise(thumbnail)
    }

    /// Eight bits to the channel, whatever arrived.
    ///
    /// `kCGImageSourceThumbnailMaxPixelSize` caps pixels, not bytes: ImageIO carries a 16-bit
    /// source's depth straight through the thumbnail, so a hostile instance halves every bound in
    /// this file for free by sending a 16-bit PNG. Measured: 2048² at 16bpc is 32MB, at 8bpc
    /// 16MB. Neither `ShouldAllowFloat: false` nor `DecodeRequest: DecodeToSDR` prevents it; both
    /// were tried. Redrawing does, and it is the only thing that does.
    ///
    /// A 16-bit picture at the viewer's full size would be half the entire budget on its own, so
    /// while it is on screen it is never `order.first` and evicts everything else to stay — which
    /// is what halved the threshold this guards. Weaker now that the depth cannot survive, but
    /// the shape of it is why the cap has to be in bytes and not in pixels.
    ///
    /// The colour space is carried over, so a Display P3 photograph stays Display P3 — what goes
    /// is the precision between the 8th and 16th bit, which nothing downstream of here can show.
    /// An 8-bit source is returned untouched and costs nothing at all. Both fallbacks return the
    /// original rather than failing the fetch: the cost accounting stays honest either way, and
    /// only the bound is weaker for that one picture.
    nonisolated static func normalise(_ image: CGImage) -> CGImage {
        guard image.bitsPerComponent > 8 else { return image }
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// Where pictures actually come from, and what refuses every address that is not fetchable —
    /// which is what keeps a `file:` or `data:` address in somebody's `avatar` field from ever
    /// being opened.
    ///
    /// Built with this caller's own ceiling rather than the transport's default. That default is
    /// a last line against a hostile instance, not a working size, and a caller asking for a
    /// thumbnail should say so: left alone it would put the worst case at `maxInFlight` times
    /// 128 MiB instead of `maxInFlight` times 20.
    nonisolated static let live: any HTTPClient = URLSessionClient(byteLimit: maxBytes)
}

/// An avatar, a thumbnail, a picture opened over the app: the same fetch and the same marks
/// wherever a picture comes off a server rather than out of the bundle.
///
/// Drawn from the cache rather than from an `AsyncImage`, so a rebuilt row keeps what it had.
/// The frame belongs to whoever draws this — the slot is a fixed square, the viewer is whatever
/// the window is — and all this says is how to fill the space it is handed.
///
/// **Do not wrap this in `EquatableView`, and do not move the `cache.picture(…)` read out of
/// `body`.** Both are the obvious optimisation and both silently restore an unbounded refetch
/// chain against third-party servers. The cache's admission control depends on every visible
/// `RemoteImage` re-reading — and so re-stamping its interest — whenever any picture changes.
/// See `ShellPictures`, I8.
struct RemoteImage: View {
    /// What is drawn where a picture is not. A face and a photograph want different marks: a
    /// person's silhouette over a missing attachment would be worse than no mark at all.
    enum Standing {
        case avatar
        case picture
    }

    /// What this view is waiting on. The address alone is not it: the cache is keyed by the
    /// screen and the tier as well, so a window dragged onto a display of another scale wants a
    /// picture nobody has asked for — and a `.task` keyed on the address would never ask.
    ///
    /// `have` is the same problem from the other end. The cache drops what it cannot afford to
    /// keep, and what it drops can belong to a row still on screen; because `pictures` is
    /// observed, that row redraws, `have` goes true→false, and this changes. The generation is
    /// for what no single view can see for itself: a cohort of addresses worth trying again
    /// because the network came back or room did.
    ///
    /// Visible rather than private so that `theGateIsInTheTaskIdentity` can hold the one property
    /// that is easy to get wrong and impossible to see: `active` must be *in* the identity.
    struct Wanted: Equatable {
        let url: URL?
        let scale: CGFloat
        let tier: ShellPictures.Tier
        let have: Bool
        let generation: Int
        /// Here so that the same address drawn under a second source commissions a fetch under
        /// that source, which is what tags the entry for it — I10.
        let host: String
        /// Decision 20's gate, **in the identity and not only in the guard.** The guard alone
        /// would stop the fetch and nothing would restart it: a tab that was inactive when the
        /// task last ran never re-runs it on becoming active, so the reader switches back to a
        /// page of empty wells that will not fill. Carrying it here means becoming active is a
        /// change of identity and re-fires. Becoming *inactive* re-fires too and the guard
        /// returns at once, which costs a task creation and nothing else.
        let active: Bool
    }

    let url: URL?

    /// How much picture this call site can afford. **No default on purpose**: a `.deck` default
    /// quietly makes the viewer soft, and a `.viewer` default quietly lets a row of thumbnails
    /// decode at full size, each the first time a call site forgets to say. The compiler asks
    /// instead.
    let tier: ShellPictures.Tier

    /// Which source this picture is being read through. **No default on purpose**, for the same
    /// reason `tier` has none: the address points at a CDN and cannot be traced back to a server,
    /// so a call site that forgets to say makes a picture the reader's Clear button can never
    /// reach. See `ShellPictures`, I10.
    let host: String

    var standing: Standing = .picture
    var contentMode: ContentMode = .fill

    /// What the author said this picture is. Given one, this stops being decoration and becomes
    /// something a reader who cannot see it can still be told about.
    var alt: String?

    /// Whether this view is the waiting place, or one picture inside a place the surface speaks
    /// for. False is silence, not an empty label — the same switch `ShellWaiting(speaks:)` is.
    /// A plate standing alone speaks; a row that already speaks as a post passes false so every
    /// arriving avatar does not shout "on its way".
    var speaks: Bool = true

    var radius: CGFloat = ShellSpace.tight

    /// What fills the frame this view was handed. The frame itself belongs to the call site —
    /// an avatar side, a thumb side — and none of these is an empty view that would let it
    /// collapse. Held is a copy already in hand: no plate, no flicker. Failed is a wait that
    /// ended with nothing, in the same frame, with a press to ask again.
    enum Fill: Equatable, Sendable {
        case held
        case waiting
        case failed
        case absent
    }

    /// Silent so this view is the only thing a reader lands on, the way a waiting row's plates
    /// stay silent while the group speaks.
    static let plateSpeaks = false

    /// The still-coming branch is the shell's plate filling this frame, not a second well.
    static func waitingPlate() -> ShellWaiting {
        ShellWaiting(speaks: plateSpeaks)
    }

    /// Reduce Motion is the shell's clock, so a waiting picture stops with the rest of the app.
    static func clock(reduceMotion: Bool) -> TimeInterval? {
        ShellWaiting.clock(reduceMotion: reduceMotion)
    }

    /// Held wins: a copy this device already has is drawn at once, even if a mark says it was
    /// once gone. Still coming is a URL that has not been answered yet. A URL that was asked
    /// for and came back with nothing is failed — the wait ended, and a press asks again. A
    /// nil URL is still absent: there is nothing to try.
    static func fill(have: Bool, url: URL?, missing: Bool) -> Fill {
        if have { return .held }
        guard url != nil else { return .absent }
        return missing ? .failed : .waiting
    }

    /// What a screen reader is told. Waiting reuses the shell's one sentence; arrived keeps
    /// the author's alt; a nil URL stays silent unless it already had one. Failed names the
    /// source that did not answer, even when this view is one picture inside a row — the
    /// retry has to be reachable.
    static func voice(fill: Fill, alt: String?, speaks: Bool, source: String = "") -> String? {
        switch fill {
        case .held, .absent:
            return alt
        case .waiting:
            return ShellWaiting.voice(speaks: speaks)
        case .failed:
            return ShellFailure.spoken([source])
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.shellPlaceIsActive) private var placeIsActive

    private var cache: ShellPictures { .shared }

    var body: some View {
        let picture = cache.picture(url, scale: displayScale, tier: tier, host: host)
        let fill = Self.fill(
            have: picture != nil,
            url: url,
            missing: cache.isMissing(url, scale: displayScale, tier: tier)
        )
        let sentence = Self.voice(fill: fill, alt: alt, speaks: speaks, source: host)
        return voiced(
            Group {
                if let picture {
                    // The well sits behind it rather than only where a picture is absent: fitted
                    // inside a fixed slot, a picture leaves the rest of that slot over, and what is
                    // left over is this colour and not whatever happens to be under the row.
                    ShellChrome.well(colorScheme).overlay {
                        picture.resizable().aspectRatio(contentMode: contentMode)
                    }
                } else if fill == .waiting {
                    // Still coming, and there is somewhere for it to come from. The shell's plate
                    // fills the same frame the picture will, so text around it never moves.
                    Self.waitingPlate()
                } else if fill == .failed {
                    // The wait ended and nothing came. The same failure place a timeline uses,
                    // filling this frame; a press runs the same fetch a first ask does.
                    ShellFailure(source: host) {
                        Task { await cache.retry(url, scale: displayScale, tier: tier, host: host) }
                    }
                } else {
                    absent
                }
            },
            fill: fill,
            sentence: sentence
        )
        .task(
            id: Wanted(
                url: url,
                scale: displayScale,
                tier: tier,
                have: picture != nil,
                generation: cache.generation,
                host: host,
                active: placeIsActive
            )
        ) {
            // Decision 20. **Only the fetch is gated** — `cache.picture(…)` above still runs and
            // still stamps interest, on every pass, on every page. Gating the read instead would
            // break I8: admission terminates because every visible key re-stamps between one
            // arrival and the next, and a row that stops stamping looks infinitely stale and
            // becomes evictable however recently it was drawn.
            //
            // An inactive deck-tier row therefore still competes for admission with active ones,
            // which is fine and was checked rather than assumed: 96MB holds 245 deck entries, and
            // the tripwire that matters is viewer-tier.
            guard placeIsActive else { return }
            await cache.fetch(url, scale: displayScale, tier: tier, host: host)
        }
    }

    /// VoiceOver on the place itself. Failed keeps the retry as an action a reader can activate;
    /// the inner `ShellFailure` button is the finger's path and is ignored here so the sentence
    /// is said once.
    private func voiced<V: View>(_ view: V, fill: Fill, sentence: String?) -> some View {
        let clipped = view.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        return Group {
            if fill == .failed {
                clipped
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(sentence ?? ""))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text(ShellFailure.retryName))
                    .accessibilityAction(named: Text(ShellFailure.retryName)) {
                        Task { await cache.retry(url, scale: displayScale, tier: tier, host: host) }
                    }
            } else {
                clipped
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(sentence ?? ""))
                    .accessibilityHidden(sentence == nil)
                    .accessibilityAddTraits(fill == .waiting && sentence != nil ? .updatesFrequently : [])
            }
        }
    }

    /// Nothing to come, or nothing came. To a reader those are one thing — there is no picture
    /// here — so they get one mark, and it says which kind of nothing it is. Quiet: it is a fact
    /// about the row, not a fault anyone has to do something about. A wait that ended with
    /// nothing is `Fill.failed`, not this.
    private var absent: some View {
        ShellChrome.well(colorScheme)
            .overlay {
                Image(systemName: standing == .avatar ? "person.fill" : "photo")
                    .shellFont(standing == .avatar ? .meta : .body)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
    }
}
