import Foundation
import Observation
import FediqoCore

/// What the feed is showing, and the rules that decide it.
///
/// One of the three jobs `FeedModel` used to do in one object (#70). This one is the list: what
/// arrived, what the reader's two switches let through, and the cache that keeps the answer
/// from being worked out again on every pass of a screen's body.
///
/// Not where the reader is standing in it, and not whether anything is on its way — those are
/// `FeedPlace` and `FeedPaging`. They were together, and a write to any one of the fifteen
/// stored properties invalidated every view reading any of the others: a spinner appearing
/// redrew the header, the tabs and the whole list.
@MainActor
@Observable
final class FeedPosts {
    /// Which timeline this is reading — its base source, its rules, and the name the reader
    /// gave it. Held whole rather than as an id, because everything done with it is asking it
    /// what to read; and replaced when the reader edits it, so a rule taken off changes the
    /// page rather than waiting for the next launch.
    ///
    /// What a change of question does to the list and to the load is `FeedModel`'s to say: it
    /// is one rule about two objects, so it is stated once where both are in reach.
    var timeline: Timeline

    private(set) var result = TimelineResult(posts: [], failures: [:]) {
        // Which list is being shown, counted rather than compared: telling two lists of posts
        // apart costs what filtering them costs, and not paying that on every keystroke is the
        // whole of why the filtered list is kept at all.
        didSet { generation += 1 }
    }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var filtered: Filtered?

    /// The rules applied, and everything applying them gave: the list the reader is looking
    /// at, and where each post in it sits. The two are thrown away together because they are
    /// worked out from the same three things — the posts, and the two rules.
    ///
    /// The index is derived and rebuilt with the list; it is never stored across loads, which
    /// is why the ring itself is still a `mergeKey` rather than one of these numbers.
    struct Filtered {
        let generation: Int
        let showBoosts: Bool
        let mediaOnly: Bool
        let posts: [Post]
        let index: [String: Int]
        /// What these two switches turned away, kept beside what they let through for the same
        /// reason the list is kept at all: working it out again on every pass of a screen's
        /// body is a cost paid for nothing.
        let hidden: [Hidden]
    }

    private let preferences: Preferences

    init(timeline: Timeline, preferences: Preferences) {
        self.timeline = timeline
        self.preferences = preferences
    }

    /// Whether nothing has arrived yet — asked before the store is read, and before a load is
    /// counted as the first one.
    var isEmpty: Bool { result.isEmpty }

    /// The rules, applied. They add and remove; they never move.
    ///
    /// Worked out once per list and once per change of rule rather than once per pass of a
    /// screen's body: a key that moves the ring redraws the timeline, and filtering every
    /// post again on every press of `j` is a cost paid for nothing.
    var visible: [Post] { rules().posts }

    /// Everything that arrived and is not on the screen, and what kept each of them off.
    ///
    /// Both halves of it: the rules written on this timeline, which the loader applied on the
    /// way in, and the two switches, which are applied here. They are the same kind of thing —
    /// the reader's own, removing and never moving — so a reader asking why a post is missing
    /// gets one list rather than two.
    var hidden: [Hidden] { result.hidden + rules().hidden }

    func rules() -> Filtered {
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
        let sifted = TimelineLoader.sift(showBoosts: showBoosts, mediaOnly: mediaOnly, posts)
        let shown = sifted.admitted
        var index: [String: Int] = [:]
        index.reserveCapacity(shown.count)
        // The first of a repeated key wins, which is what walking the list to find one did.
        for (position, post) in shown.enumerated() where index[post.mergeKey] == nil {
            index[post.mergeKey] = position
        }
        let answer = Filtered(generation: generation, showBoosts: showBoosts, mediaOnly: mediaOnly,
                              posts: shown, index: index, hidden: sifted.hidden)
        filtered = answer
        return answer
    }

    /// The posts this feed is holding, put here rather than loaded.
    ///
    /// `FeedPaging.load` is how they arrive in the running app, and it needs servers to ask and
    /// a network to ask them over. This is the other door, and it is here so that the keys
    /// which move through a feed can be pressed on a feed with real posts in it — the wired
    /// path, from the press to the address that is opened, and no server anywhere in it.
    func show(_ posts: [Post]) {
        result = TimelineResult(posts: posts, failures: [:])
    }

    /// These posts, and everything else about the last load left as it was. What a reach and a
    /// reconcile both do: they change the list and say nothing new about any server, so the
    /// standing `failures` and `unasked` are not theirs to rewrite — and writing them out by
    /// hand at each place is how `unasked` came to be dropped once already.
    func showing(_ posts: [Post]) {
        result = TimelineResult(posts: posts, failures: result.failures, unasked: result.unasked)
    }

    /// What a load brought back, joined to what was already here.
    ///
    /// The whole result, `unasked` and all: a server inside its wait is neither in the posts
    /// nor in the failures, and a rebuild that leaves it out of the third place too loses the
    /// difference between a server that had nothing to say and one nobody asked.
    func replace(with loaded: TimelineResult, asked servers: [Server]) {
        result = TimelineResult(posts: loaded.posts(carrying: result.posts, asked: servers),
                                failures: loaded.failures, unasked: loaded.unasked)
    }

    /// What the store had, before any server has been asked.
    func stocked(with posts: [Post]) {
        result = TimelineResult(posts: posts, failures: [:])
    }

    /// A different question is a different page. What was on the screen was the answer to the
    /// old one, and keeping it would leave posts under rules that no longer admit them until
    /// something else happened to replace them.
    func forgetTheList() {
        result = TimelineResult(posts: [], failures: result.failures, unasked: result.unasked)
    }

    /// Older posts joining the end of the list, and which of them did.
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
    ///
    /// What joined is handed back rather than acted on: where the ring goes is `FeedPlace`'s,
    /// and the count is the reach's own to steer by.
    func append(_ older: [Post]) -> [Post] {
        guard let foot = result.posts.last else { return [] }
        // Only against itself. The shown list runs from the top of the timeline down to
        // `foot` without a break, so nothing older than `foot` can already be in it — and
        // rebuilding a key set over the whole list every round would be the one cost a cold
        // start pays eight times over for nothing.
        var known: Set<String> = []
        // Both lists arrive in the timeline's own order, so what survives the filter is still
        // in it and goes on the end as it stands. Sorting again would be the one thing this
        // must not do.
        let joining = older.filter {
            TimelineOrder.isOlder($0, than: foot) && known.insert($0.mergeKey).inserted
        }
        guard !joining.isEmpty else { return [] }
        showing(result.posts + joining)
        return joining
    }

    /// The posts an authority has confirmed it will not hand over any more, taken off the
    /// screen. It removes and it never moves: everything else stays exactly where it was.
    ///
    /// A pass asks about at most a handful and most passes settle none of them on this screen,
    /// so whether anything here is going is asked before a new list is built rather than after
    /// one has been built and thrown away.
    func drop(_ gone: Set<String>) {
        guard !gone.isEmpty, result.posts.contains(where: { gone.contains($0.mergeKey) })
        else { return }
        showing(result.posts.filter { !gone.contains($0.mergeKey) })
    }
}
