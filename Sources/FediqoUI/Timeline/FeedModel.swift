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
        result = TimelineResult(posts: loaded.posts(carrying: result.posts, asked: servers),
                                failures: loaded.failures)
        failures = loaded.failures(carrying: failures, of: servers)
        // Only what this load was told, not the standing answer: a credential is turned down
        // once and marked once, rather than again on every tick that skips the server.
        for (endpoint, failure) in loaded.failures {
            if case .tokenRejected = failure { onTokenRejected?(endpoint) }
        }
        loadedFor = servers.map(\.id).sorted()
        loading = false
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
    @discardableResult
    func moveSelection(by steps: Int) -> Bool {
        let shown = rules()
        guard !shown.posts.isEmpty else { return false }
        let landing: Int
        if let here = selection.flatMap({ shown.index[$0] }) {
            landing = min(max(here + steps, 0), shown.posts.count - 1)
        } else {
            landing = 0
        }
        let key = shown.posts[landing].mergeKey
        guard key != selection else { return false }
        selection = key
        return true
    }

    /// Back to the top: the ring is let go, because a reader taken to the top with the ring
    /// still on a post a thousand rows down is being told two different places.
    func goToTop() {
        selection = nil
        topRequests += 1
    }
}
