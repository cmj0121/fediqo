import Foundation
import Observation
import FediqoCore

/// Whether anything is on its way, and what the last asking said about the servers.
///
/// The third of the three jobs `FeedModel` used to do in one object (#70): the loading. It
/// writes the list through `FeedPosts` and tells `FeedPlace` where a page landed, and it holds
/// nothing either of them holds.
///
/// The point of the division is what a screen watching a spinner is now watching. `loading` and
/// `bottom` change several times a second at the foot of a cold start; while they lived beside
/// the posts, a view that read both read one object, and the list was rebuilt for a spinner.
@MainActor
@Observable
final class FeedPaging {
    private(set) var loading = false

    /// The three things the foot of a list can be, and the moment between two of them.
    ///
    /// `arrived` and `ended` are the same place; they differ only in whether it has been said
    /// yet. Keeping them apart in one value is what makes "announce once" a step the value
    /// takes rather than a second flag standing beside it for somebody else to lower.
    enum Bottom: Sendable, Equatable {
        /// Nothing is out and the reading is not over. The foot of the list says nothing.
        case idle
        /// A reach is out — the whole of it, the derived round included.
        ///
        /// The screen shows it at the foot of the list, because a cold start can take several
        /// rounds before anything lands below the reader and a bottom that merely sits there
        /// is indistinguishable from a finished one.
        ///
        /// `fromTheEnd` is where the reach left from, and is what stops the reader being told
        /// twice: a reach that goes out from the end and comes back to find the same end is
        /// the reader coming back to the foot of the list, not a second arrival at it.
        case reading(fromTheEnd: Bool)
        /// The reading ended on the reach that has just come back, and is being said.
        case arrived
        /// The reading is over and has been said. The marker stays; the moment is spent.
        case ended

        /// A reach is out, wherever it left from.
        var isReading: Bool { if case .reading = self { true } else { false } }
        /// Every server has said it has nothing older, and nothing is coming.
        ///
        /// The foot of the list is the end of the reading and not a pause on the way to it,
        /// which is why `reading` is not this however long it has been out: a reach that is
        /// still out owns the foot, and the end is what is left when nothing is coming.
        var isTheEnd: Bool { self == .arrived || self == .ended }
    }

    /// Where the reading has got to at the foot of the list.
    ///
    /// One value, because the foot of a list says one thing at a time, and two members that
    /// can disagree are two things it might say at once.
    ///
    /// It is also the one guard on the reach trigger. A scroll is as tireless as a clock:
    /// without this, crossing the threshold once a frame would ask once a frame. `ServerPaging`
    /// keeps each server from being asked twice; this keeps the reach itself from stacking,
    /// which is a page from the store as much as one from the network. Because `reading`
    /// covers the round as well, it also bounds the `reconcile` pass each round ends with — a
    /// reader scrolling fast through a well-stocked store would otherwise finish a reach every
    /// few hundred milliseconds, and each of those spending a pass is a burst of single-post
    /// requests at other people's servers.
    private(set) var bottom: Bottom = .idle

    /// A reach that arrived while one was already out, kept rather than dropped.
    ///
    /// The trigger fires on a change and not on a state: `onScrollGeometryChange` says
    /// "you have just crossed the line", never "you are still past it". So a reader who is
    /// sitting still at the foot of the list gets one crossing and no more, and a reach turned
    /// away by the guard is a reach that never happens — no page, no spinner, and nothing
    /// coming, until they scroll away and back to ask again by hand. This is the reach being
    /// remembered instead, and run the moment the one in front of it is done.
    ///
    /// A flag and not a count. Ten crossings while a page is out are one ask, not ten.
    @ObservationIgnored private var reachWaiting = false

    /// How long `arrived` lasts before it settles into `ended`.
    ///
    /// The moment has a length and the length is the model's, because the moment is. A screen
    /// that owned it would have to take it down again, and a screen that had stepped away
    /// while it happened would come back to a moment nobody had ended.
    ///
    /// A `var` so that a test can shorten it to nothing and await `settling`, rather than
    /// wait out a toast in real seconds.
    @ObservationIgnored var announcementLasts = Duration.milliseconds(2500)

    /// The step from `arrived` to `ended`, in flight.
    ///
    /// Kept so that a second arrival can cancel the first one's clock: two moments overlapping
    /// would have the older one end the newer one early.
    @ObservationIgnored private(set) var settling: Task<Void, Never>?

    /// What is still wrong with each server, by `Server.endpoint`, kept across loads.
    ///
    /// A load's own result is replaced whole every time, and a server inside its wait is not
    /// in it at all — so a screen reading the last load alone would take a broken server's
    /// line down and put it back up every cycle, though nothing about the server changed. This
    /// is the standing answer instead: it survives the loads that did not ask, and it clears
    /// the moment the server answers one that did, or stops being one of ours.
    private(set) var failures: [String: SourceFailure] = [:]

    /// Why the stored timeline could not be read for the page under the reader, where that is
    /// what happened, and nothing where the last reach read one fine.
    ///
    /// Not one of `failures`, which are keyed by endpoint and belong to servers. This is our
    /// own database, and no server has anything to do with it — it is kept apart so that it
    /// can be said as what it is rather than blamed on whoever was about to be asked.
    private(set) var storeFailure: SourceFailure?

    /// The servers the last load asked, by `Server.id`, sorted — and `nil` until there has
    /// been one. An empty list is an answer rather than the absence of one: an app with no
    /// sources loads nothing, and that load counts, so "never asked" needs its own value.
    @ObservationIgnored private var loadedFor: [String]?

    /// What this feed reads through. Handed out for one other question — the conversation
    /// around a post the reader opened — because it already knows the store and who is signed
    /// in, and a second loader would be a second set of that.
    let loader: TimelineLoader

    /// Told, by `Server.endpoint`, when a server turned down the token a read carried. The
    /// posts still arrived — the loader asked again as a stranger — so this marks the
    /// account and never the column.
    var onTokenRejected: (@MainActor (String) -> Void)?

    private let posts: FeedPosts
    private let place: FeedPlace

    init(posts: FeedPosts, place: FeedPlace, loader: TimelineLoader) {
        self.posts = posts
        self.place = place
        self.loader = loader
    }

    /// The next `loadIfNeeded` asks again, whatever it asked last time. What a change of
    /// question means for the loading, said by `FeedModel` where the list's half is said too.
    func forgetTheLoad() {
        loadedFor = nil
    }

    /// Reloads only when the set of servers actually changed, so leaving this feed and
    /// coming back to it — another tab, another page — does not re-ask every server every
    /// time. What decides is whether the servers differ from the ones the last load asked,
    /// never whether that load found anything: a feed that legitimately came back empty has
    /// still been read, and asking again on every visit would punish the quiet server rather
    /// than the changed one. Before the first load, what the store holds is shown before any
    /// server is asked; a store that cannot be read is simply skipped on the way there.
    func loadIfNeeded(servers: [Server]) async {
        if loadedFor == nil, posts.isEmpty,
           let stored = try? await loader.stored(posts.timeline.query), !stored.isEmpty {
            posts.stocked(with: stored)
        }
        let signature = servers.map(\.id).sorted()
        guard signature != loadedFor else { return }
        let known = Set(loadedFor ?? [])
        await load(servers: servers)
        // A load asks everyone for their newest page, which for a server just added is the top
        // of a timeline the reader has already scrolled past. Everything that server carried
        // inside the stretch they are holding would sit below the fold and be reached only by
        // scrolling to the bottom and back (#92).
        //
        // So the added ones are walked back to where the reader is. Only the added ones: the
        // servers that were already being read have been read down to here already.
        let added = servers.filter { !known.contains($0.id) }
        if !known.isEmpty, !added.isEmpty { await catchUp(added) }
    }

    /// Walks servers the reader has just added back to the foot of what they are already
    /// holding, and shows what that turns up.
    ///
    /// Nothing happens where there is nothing to catch up to — a feed with no posts is one the
    /// ordinary load has just filled, and the newest page is the whole of it.
    private func catchUp(_ added: [Server]) async {
        guard let oldest = posts.visible.last?.createdAt else { return }
        for server in added {
            _ = await loader.catchUp(server, downTo: oldest, query: posts.timeline.query)
        }
        // Asked of the store rather than merged from the answers: what came back is that
        // server's own page order, and one stream out of several is the store's job — the same
        // fold that makes two servers carrying one post into one row.
        if let filled = try? await loader.stored(posts.timeline.query), !filled.isEmpty {
            posts.showing(filled)
        }
    }

    /// `refresh` says who asked. The reader by default — the refresh button, and the first
    /// load of a screen — so that everything is asked at once, whatever it did last time.
    func load(servers: [Server], refresh: Refresh = .manual) async {
        loading = true
        let loaded = await loader.load(servers: servers, query: posts.timeline.query, refresh: refresh)
        posts.replace(with: loaded, asked: servers)
        note(loaded, from: servers)
        loadedFor = servers.map(\.id).sorted()
        loading = false
        // A refresh spends a pass at the suspects too, and not only because it is a convenient
        // moment: its own newest page raises questions of its own — the top of the timeline is
        // the one stretch paging never revisits, and a post pulled down moments after it went
        // up sits exactly there. Leaving the queue to the reach-down alone would have a reader
        // who never scrolls collect suspicions and answer none of them.
        if posts.timeline.source.isThreadOfTime {
            posts.drop(await loader.reconcile())
            // Asked again here because the answer can change without a reach: the chosen list
            // is what it is asked of, so a source added while the reader sat at the end is a
            // server nobody has asked anything, and the marker must come down. Not announced —
            // a refresh is about the top of the list, and arriving at the bottom is something
            // the reader does rather than something that happens to them.
            await noteTheEnd(of: servers)
        }
    }

    /// What a load said about the servers, whichever kind of load it was: the standing reason
    /// each one has, and the accounts whose credential was turned down. The posts are not this
    /// function's business — a refresh replaces them and a reach appends to them, and those
    /// are two different things.
    private func note(_ loaded: TimelineResult, from servers: [Server]) {
        failures = loaded.failures(carrying: failures, of: servers)
        // Only what this load was told, not the standing answer: a credential is turned down
        // once and marked once, rather than again on every tick that skips the server.
        for (endpoint, failure) in loaded.failures {
            if case .tokenRejected = failure { onTokenRejected?(endpoint) }
        }
    }

    // MARK: - Reaching the bottom

    /// Reaching the bottom asks for the page before what is shown, and keeps a reach that
    /// arrives while one is out rather than dropping it.
    ///
    /// Only a timeline. A trending list is a snapshot a server curated in the order it chose,
    /// and "what came before it" means nothing — `SourceClient.trending` takes no cursor and
    /// says why. The two tabs are one screen, so the trigger fires on both and the answer to
    /// that has to be here rather than in the scroll view.
    func loadOlder(servers: [Server]) async {
        guard posts.timeline.source.isThreadOfTime else { return }
        guard !bottom.isReading else { reachWaiting = true; return }
        bottom = .reading(fromTheEnd: bottom.isTheEnd)
        // Cleared before the reach rather than after it, so a crossing that arrives while this
        // one is running is kept — clearing afterwards would throw away exactly the ask this
        // exists to catch. One more pass at most per reach that was actually asked for.
        repeat {
            reachWaiting = false
            await reach(servers)
        } while reachWaiting
        // After the whole reach and not after each round, because a round is not the reader's
        // unit: the eight of a cold start are one journey to the bottom, and the answer is only
        // worth having once they have stopped.
        await noteTheEnd(of: servers, announcing: true)
    }

    /// Where the reach leaves the foot of the list: not reading any more, and at the end or
    /// not — and, where this reach is what brought the end about, in the moment of saying so.
    ///
    /// Read from `TimelineLoader.reachedTheEnd(of:)` rather than guessed from an empty page: a
    /// round that brings nothing back is a round in which everybody was spent, waiting, or
    /// still out, and only the first of those three is an end. It is a standing fact about the
    /// servers, so it is asked afresh each time rather than latched — a server added, or one
    /// that has more to give after all, takes the end away again.
    ///
    /// The crossing is what announces, never the state: a reader already at the end who
    /// reaches again finds the same answer and is told nothing, which is the whole difference
    /// between the marker and the toast.
    private func noteTheEnd(of servers: [Server], announcing: Bool = false) async {
        guard await loader.reachedTheEnd(of: servers) else { return settle(into: .idle) }
        let already = switch bottom {
        case .reading(let fromTheEnd): fromTheEnd
        case .arrived, .ended: true
        case .idle: false
        }
        guard announcing, !already else { return settle(into: .ended) }
        settle(into: .arrived)
        settling = Task { [announcementLasts] in
            try? await Task.sleep(for: announcementLasts)
            guard !Task.isCancelled else { return }
            // Only this arrival's own moment ends here. Anything else that has happened since
            // is somebody else's value to hold.
            if self.bottom == .arrived { self.bottom = .ended }
        }
    }

    /// Puts the foot of the list somewhere, and stops whatever moment was running.
    private func settle(into place: Bottom) {
        settling?.cancel()
        settling = nil
        bottom = place
    }

    /// One reach, handed to the loader.
    ///
    /// What is left here is what is genuinely a screen's: which page joins the shown list, what
    /// each server's answer does to the lines under the list, and where the ring lands. How many
    /// times anybody's server is asked, and in what order the store and the servers are asked at
    /// all, is #66's — it went to `TimelineLoader.reachOlder`, beside the other request budgets
    /// and out of reach of a main actor.
    private func reach(_ servers: [Server]) async {
        guard let foot = posts.result.posts.last else { return }
        let gone = await loader.reachOlder(than: foot, matching: posts.timeline.query,
                                           servers: servers) { arrival in
            await MainActor.run {
                switch arrival {
                case .fromTheStore(let landed, let failure):
                    storeFailure = failure
                    return landed.isEmpty ? 0 : join(landed)
                case .fromServers(let older):
                    note(older, from: servers)
                    return join(older.posts)
                }
            }
        }
        posts.drop(gone)
    }

    /// A page joining the list, and the ring going with it where the reader was waiting for it.
    /// How many landed is what the reach steers by.
    private func join(_ older: [Post]) -> Int {
        let joining = posts.append(older)
        place.land(theRingOn: joining)
        return joining.count
    }
}
