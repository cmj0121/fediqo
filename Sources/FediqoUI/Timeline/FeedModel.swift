import Foundation
import Observation
import FediqoCore

@MainActor
@Observable
final class FeedModel {
    let mode: FeedMode

    private(set) var result = TimelineResult(posts: [], failures: [:]) {
        // Which list is being shown, counted rather than compared: telling two lists of posts
        // apart costs what filtering them costs, and not paying that on every keystroke is the
        // whole of why the filtered list is kept at all.
        didSet { generation += 1 }
    }
    /// What is still wrong with each server, by `Server.endpoint`, kept across loads.
    ///
    /// `result` is replaced whole every time, and a server inside its wait is not in it at
    /// all — so a screen reading the last load alone would take a broken server's line down
    /// and put it back up every cycle, though nothing about the server changed. This is the
    /// standing answer instead: it survives the loads that did not ask, and it clears the
    /// moment the server answers one that did, or stops being one of ours.
    private(set) var failures: [String: SourceFailure] = [:]
    private(set) var loading = false
    /// Whether a reach for the bottom is out — the whole of it, the derived round included.
    /// The screen shows it at the foot of the list, because a cold start can take several
    /// rounds before anything lands below the reader and a bottom that merely sits there is
    /// indistinguishable from a finished one.
    ///
    /// It is also the one guard on the trigger. A scroll is as tireless as a clock: without
    /// this, crossing the threshold once a frame would ask once a frame. `ServerPaging` keeps
    /// each server from being asked twice; this keeps the reach itself from stacking, which is
    /// a page from the store as much as one from the network.
    ///
    /// Because it covers the round as well, it also bounds the `reconcile` pass each round
    /// ends with. A reader scrolling fast through a well-stocked store would otherwise finish
    /// a reach every few hundred milliseconds, and each of those spending a pass is a burst of
    /// single-post requests at other people's servers.
    private(set) var loadingOlder = false
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
    /// Why the stored timeline could not be read for the page under the reader, where that is
    /// what happened, and nothing where the last reach read one fine.
    ///
    /// Not one of `failures`, which are keyed by endpoint and belong to servers. This is our
    /// own database, and no server has anything to do with it — it is kept apart so that it
    /// can be said as what it is rather than blamed on whoever was about to be asked.
    private(set) var storeFailure: SourceFailure?
    /// Whether the ring is waiting for a post that does not exist yet — `j` pressed on the
    /// last post there is. The first post to arrive takes it.
    ///
    /// Every press answers this afresh, so a reader who asked for more and then went back up
    /// is no longer waiting and the page that arrives leaves their ring alone.
    @ObservationIgnored private(set) var awaitingOlder = false
    /// The post the ring is on, by `Post.mergeKey`, or nothing when the reader is at the top
    /// of the list rather than on a row.
    ///
    /// A key rather than a position, because `result` is replaced whole by every load: an
    /// index would quietly become a different post the moment anything new arrived above it,
    /// and the ring would wander down the timeline on its own. A key names the post itself,
    /// so a refresh that brings ten new posts leaves the ring where the reader put it.
    ///
    /// It lives on the feed rather than on `AppState` for the same reason the posts do: the
    /// two tabs are two lists, and each keeps its own place in itself.
    private(set) var selection: String?
    /// How many times the reader has asked to be taken back to the top.
    ///
    /// Going to the top is an event, not a state — pressing `g` twice means it twice, and
    /// asking for it while nothing is selected still means it — so there is nothing for the
    /// screen to watch but the fact that it was asked again. The screen owns the scrolling;
    /// this is only the asking.
    private(set) var topRequests = 0
    /// The servers the last load asked, by `Server.id`, sorted — and `nil` until there has
    /// been one. An empty list is an answer rather than the absence of one: an app with no
    /// sources loads nothing, and that load counts, so "never asked" needs its own value.
    private var loadedFor: [String]?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var filtered: Filtered?

    /// The rules applied, and everything applying them gave: the list the reader is looking
    /// at, and where each post in it sits. The two are thrown away together because they are
    /// worked out from the same three things — the posts, and the two rules.
    ///
    /// The index is derived and rebuilt with the list; it is never stored across loads, which
    /// is why the ring itself is still a `mergeKey` rather than one of these numbers.
    private struct Filtered {
        let generation: Int
        let showBoosts: Bool
        let mediaOnly: Bool
        let posts: [Post]
        let index: [String: Int]
    }

    private let preferences: Preferences
    private let loader: TimelineLoader

    /// Told, by `Server.endpoint`, when a server turned down the token a read carried. The
    /// posts still arrived — the loader asked again as a stranger — so this marks the
    /// account and never the column.
    var onTokenRejected: (@MainActor (String) -> Void)?

    init(mode: FeedMode, preferences: Preferences, loader: TimelineLoader = TimelineLoader()) {
        self.mode = mode
        self.preferences = preferences
        self.loader = loader
    }

    /// Reloads only when the set of servers actually changed, so leaving this feed and
    /// coming back to it — another tab, another page — does not re-ask every server every
    /// time. What decides is whether the servers differ from the ones the last load asked,
    /// never whether that load found anything: a feed that legitimately came back empty has
    /// still been read, and asking again on every visit would punish the quiet server rather
    /// than the changed one. Before the first load, what the store holds is shown before any
    /// server is asked; a store that cannot be read is simply skipped on the way there.
    func loadIfNeeded(servers: [Server]) async {
        if loadedFor == nil, result.isEmpty,
           let stored = try? await loader.stored(mode: mode), !stored.isEmpty {
            result = TimelineResult(posts: stored, failures: [:])
        }
        let signature = servers.map(\.id).sorted()
        guard signature != loadedFor else { return }
        await load(servers: servers)
    }

    /// `refresh` says who asked. The reader by default — the refresh button, and the first
    /// load of a screen — so that everything is asked at once, whatever it did last time.
    func load(servers: [Server], refresh: Refresh = .manual) async {
        loading = true
        let loaded = await loader.load(servers: servers, mode: mode, refresh: refresh)
        // The whole result, `skipped` and all: a server inside its wait is neither in the
        // posts nor in the failures, and a rebuild that leaves it out of the third place too
        // loses the difference between a server that had nothing to say and one nobody asked.
        result = TimelineResult(posts: loaded.posts(carrying: result.posts, asked: servers),
                                failures: loaded.failures, skipped: loaded.skipped)
        note(loaded, from: servers)
        loadedFor = servers.map(\.id).sorted()
        loading = false
        // A refresh spends a pass at the suspects too, and not only because it is a convenient
        // moment: its own newest page raises questions of its own — the top of the timeline is
        // the one stretch paging never revisits, and a post pulled down moments after it went
        // up sits exactly there. Leaving the queue to the reach-down alone would have a reader
        // who never scrolls collect suspicions and answer none of them.
        if mode == .timeline { drop(await loader.reconcile()) }
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

    /// How many rounds one reach for the bottom may take.
    ///
    /// A round is one page from every server, and on a cold start every one of them lands
    /// above the reader rather than below. The cursors start empty, so the first page a server
    /// gives is its newest — which the store already had and the reader has already read — and
    /// the next is the one before that, on down to wherever they have got to. One round and a
    /// shrug is "I reached the bottom and nothing happened", so the reach keeps asking until
    /// something appears beneath them.
    ///
    /// Eight, the same handful `TimelineLoader.confirmationsPerPass` is and for its reason: a
    /// reach already costs a request per server, and eight rounds of a handful of servers is a
    /// burst somebody else's machine can wear. It does not promise to clear a deep store in
    /// one reach — a store holding two thousand posts is fifty rounds down. What it promises
    /// is progress that never unwinds: every round moves every cursor a page further down, so
    /// the cliff is eight pages shorter after each reach and never grows back, and the foot of
    /// the list says the app is working rather than finished while it happens.
    static let roundsPerReach = 8

    /// Reaching the bottom asks for the page before what is shown, and keeps a reach that
    /// arrives while one is out rather than dropping it.
    ///
    /// Only a timeline. A trending list is a snapshot a server curated in the order it chose,
    /// and "what came before it" means nothing — `SourceClient.trending` takes no cursor and
    /// says why. The two tabs are one screen, so the trigger fires on both and the answer to
    /// that has to be here rather than in the scroll view.
    func loadOlder(servers: [Server]) async {
        guard mode == .timeline else { return }
        guard !loadingOlder else { reachWaiting = true; return }
        loadingOlder = true
        defer { loadingOlder = false }
        // Cleared before the reach rather than after it, so a crossing that arrives while this
        // one is running is kept — clearing afterwards would throw away exactly the ask this
        // exists to catch. One more pass at most per reach that was actually asked for.
        repeat {
            reachWaiting = false
            await reach(servers)
        } while reachWaiting
    }

    /// One reach: the store's page where it has one, and the servers either way.
    ///
    /// The store answers first, because it can answer now and the reader is waiting. The
    /// servers are asked either way — that is the whole of what makes a post one of them has
    /// stopped handing over noticeable — but where the store had the page they are asked
    /// behind it rather than in front of it, and for one round rather than eight. What that
    /// round is for is the evidence it leaves with `reconcile`; whatever of it belongs below
    /// the reader is appended like any other page, but that is not why it was sent.
    ///
    /// The round belongs to the reach rather than to a task alongside it. Detached, it
    /// outlived the `loadingOlder` that stood for it: the next reach found the store empty,
    /// ran into the round still out, and was turned away with no page, no spinner and nothing
    /// coming — a reach swallowed in silence, which is the one thing this must never do.
    private func reach(_ servers: [Server]) async {
        guard let foot = result.posts.last else { return }
        let page = await loader.storedOlder(than: foot)
        storeFailure = page.failure
        guard page.posts.isEmpty else {
            append(page.posts)
            return await askServers(servers, rounds: 1)
        }
        // A store that would not answer is not a store that has run out, and only the second
        // is the cold-start cliff eight rounds are the answer to. Paying that burst at other
        // people's servers for our own database's bad moment would be charging them for it, so
        // this asks exactly what a reach the store did answer asks.
        await askServers(servers, rounds: page.failure == nil ? Self.roundsPerReach : 1)
    }

    /// The servers asked for what came before, round after round until a page lands below the
    /// reader — or until the ceiling, or until there is nobody left to ask.
    ///
    /// One reach at a time is `loadingOlder`'s to keep and there is no second guard here: the
    /// round belongs to the reach that started it, so there is never a second one in flight
    /// for another flag to bound.
    private func askServers(_ servers: [Server], rounds: Int) async {
        guard !servers.isEmpty else { return }
        for _ in 0..<rounds {
            let older = await loader.loadOlder(servers: servers)
            note(older, from: servers)
            // Nobody said anything at all — every server is spent, waiting or still out — so
            // asking again this instant would ask the same nobody. That covers the end of the
            // reading too: the round in which the last server runs out is a round in which it
            // was the only one asked and it answered with an empty page.
            if older.posts.isEmpty, older.failures.isEmpty { break }
            if append(older.posts) > 0 { break }
        }
        drop(await loader.reconcile())
    }

    /// Older posts joining the end of the list, and how many of them did.
    ///
    /// Two rules, and together they are the promise a reach-down makes: nothing already read
    /// moves, and nothing already read is replaced. A post the list already has is dropped
    /// rather than merged over the top of it — a page arriving is more of the timeline, not a
    /// new version of what is on the screen. And a post *newer* than the foot belongs above
    /// the reader rather than below: the loader wrote it to the store either way, and a
    /// refresh is what brings it down.
    ///
    /// The foot is read here rather than handed in, so a round that comes back while the store
    /// has appended another page in front of it joins the list as it is now.
    @discardableResult
    private func append(_ older: [Post]) -> Int {
        guard let foot = result.posts.last else { return 0 }
        // Only against itself. The shown list runs from the top of the timeline down to
        // `foot` without a break, so nothing older than `foot` can already be in it — and
        // rebuilding a key set over the whole list every round would be the one cost a cold
        // start pays eight times over for nothing.
        var known: Set<String> = []
        // Both lists arrive in the timeline's own order, so what survives the filter is still
        // in it and goes on the end as it stands. Sorting again would be the one thing this
        // must not do.
        let joining = older.filter {
            Post.isOlder($0, than: foot) && known.insert($0.mergeKey).inserted
        }
        guard !joining.isEmpty else { return 0 }
        showing(result.posts + joining)
        land(theRingOn: joining)
        return joining.count
    }

    /// The ring, where `j` asked for a post that had not arrived yet: it lands on the first of
    /// the new posts the reader can actually see, and a page the filters hide entirely leaves
    /// it waiting for the next one.
    ///
    /// The rules are applied to the arriving page rather than read off the shown list, because
    /// the shown list has just changed under it: asking `rules()` here is a guaranteed miss and
    /// a rebuild of the whole index, to answer a question about forty posts.
    private func land(theRingOn joining: [Post]) {
        guard awaitingOlder else { return }
        let visible = TimelineLoader.apply(showBoosts: preferences.showBoosts,
                                           mediaOnly: preferences.showMediaOnly, to: joining)
        guard let landing = visible.first else { return }
        selection = landing.mergeKey
        awaitingOlder = false
    }

    /// The posts an authority has confirmed it will not hand over any more, taken off the
    /// screen. It removes and it never moves: everything else stays exactly where it was.
    ///
    /// A pass asks about at most a handful and most passes settle none of them on this screen,
    /// so whether anything here is going is asked before a new list is built rather than after
    /// one has been built and thrown away.
    private func drop(_ gone: Set<String>) {
        guard !gone.isEmpty, result.posts.contains(where: { gone.contains($0.mergeKey) })
        else { return }
        showing(result.posts.filter { !gone.contains($0.mergeKey) })
    }

    /// These posts, and everything else about the last load left as it was. What a reach and a
    /// reconcile both do: they change the list and say nothing new about any server, so the
    /// standing `failures` and `skipped` are not theirs to rewrite — and writing them out by
    /// hand at each place is how `skipped` came to be dropped once already.
    private func showing(_ posts: [Post]) {
        result = TimelineResult(posts: posts, failures: result.failures, skipped: result.skipped)
    }

    /// The posts this feed is holding, put here rather than loaded.
    ///
    /// `load` is how they arrive in the running app, and it needs servers to ask and a
    /// network to ask them over. This is the other door, and it is here so that the keys
    /// which move through a feed can be pressed on a feed with real posts in it — the wired
    /// path, from the press to the address that is opened, and no server anywhere in it.
    func show(_ posts: [Post]) {
        result = TimelineResult(posts: posts, failures: [:])
    }

    /// The rules, applied. They add and remove; they never move.
    ///
    /// Worked out once per list and once per change of rule rather than once per pass of a
    /// screen's body: a key that moves the ring redraws the timeline, and filtering every
    /// post again on every press of `j` is a cost paid for nothing.
    var visible: [Post] { rules().posts }

    private func rules() -> Filtered {
        // Read before the cache is asked rather than after, so that a screen reading `visible`
        // still depends on the posts and on the two rules. A hit that touched neither would
        // leave the list standing through the load that replaced it.
        let posts = result.posts
        let showBoosts = preferences.showBoosts
        let mediaOnly = preferences.showMediaOnly
        if let filtered, filtered.generation == generation,
           filtered.showBoosts == showBoosts, filtered.mediaOnly == mediaOnly {
            return filtered
        }
        let shown = TimelineLoader.apply(showBoosts: showBoosts, mediaOnly: mediaOnly, to: posts)
        var index: [String: Int] = [:]
        index.reserveCapacity(shown.count)
        // The first of a repeated key wins, which is what walking the list to find one did.
        for (position, post) in shown.enumerated() where index[post.mergeKey] == nil {
            index[post.mergeKey] = position
        }
        let answer = Filtered(generation: generation, showBoosts: showBoosts, mediaOnly: mediaOnly,
                              posts: shown, index: index)
        filtered = answer
        return answer
    }

    // MARK: - Where the reader is

    /// The post the ring is on, if the list still has it.
    ///
    /// Nothing is pruned when a load drops the selected post — the key is simply a key the
    /// list no longer answers to, so no ring is drawn and there is nothing to open. Should
    /// the post come back — a filter turned off again, a later load carrying it — the ring
    /// comes back with it, which is what a reader who turned a filter on and off again
    /// would expect. What does not happen either way is the list moving under them.
    var selectedPost: Post? {
        let shown = rules()
        return selection.flatMap { shown.index[$0] }.map { shown.posts[$0] }
    }

    /// Where `Return` would take the reader, and nothing when there is nowhere: no ring, a
    /// ring on a post this list no longer has, or a post the server gave no address for.
    var selectedURL: URL? { selectedPost?.webURL }

    /// Moves the ring `steps` along the list, and says whether it moved.
    ///
    /// This is the one rotation in the app that does not wrap, and the difference is the
    /// list rather than the rule: the rail is four things a reader can see all of at once,
    /// where coming round again is a convenience. A timeline is a line with a top and a
    /// bottom and a thousand posts in between, and `k` at the top throwing the reader onto
    /// the oldest post they have is the opposite of the small step they asked for. So it
    /// stops at both ends, and `g` is how the long journey is made on purpose.
    ///
    /// With nothing selected — or with the ring on a post this list no longer has — the
    /// first press starts at the first post, whichever direction it asked for. There is no
    /// "where you were" to step from, and the top of the list is where the reader is.
    ///
    /// The bottom is the one end that is not a wall. There is nowhere to step to, so nothing
    /// moves and the press says so — but the ring is left waiting, and whoever holds the
    /// servers takes that as the ask for what came before. `k` at the top has no such
    /// counterpart: what is above the newest post is a refresh, and refreshing already exists.
    @discardableResult
    func moveSelection(by steps: Int) -> Bool {
        let shown = rules()
        let here = selection.flatMap { shown.index[$0] }
        // One write, and every press makes it: an empty list and a ring the list no longer
        // has both fall to false, which is right — neither is a reader standing at the end.
        awaitingOlder = steps > 0 && here == shown.posts.count - 1
        guard !shown.posts.isEmpty else { return false }
        let landing = here.map { min(max($0 + steps, 0), shown.posts.count - 1) } ?? 0
        let key = shown.posts[landing].mergeKey
        guard key != selection else { return false }
        selection = key
        return true
    }

    /// Back to the top: the ring is let go, because a reader taken to the top with the ring
    /// still on a post a thousand rows down is being told two different places.
    func goToTop() {
        selection = nil
        // A reader taken to the top is not waiting at the bottom any more, and a page landing
        // a moment later must not drag the ring back down there.
        awaitingOlder = false
        topRequests += 1
    }
}
