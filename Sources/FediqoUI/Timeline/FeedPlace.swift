import Foundation
import Observation
import FediqoCore

/// Where the reader is standing in a feed, and nothing else.
///
/// The second of the three jobs `FeedModel` used to do in one object (#70). The ring, whether
/// it is waiting for a post that has not arrived, and the asking to be taken back to the top.
///
/// It reads the list to answer any of it — a ring is a place in a list — and it never writes
/// one. That is the whole of the relation: moving the ring cannot change what is on the screen,
/// which is why a press of `j` has no business redrawing the header.
@MainActor
@Observable
final class FeedPlace {
    /// The post the ring is on, by `Post.mergeKey`, or nothing when the reader is at the top
    /// of the list rather than on a row.
    ///
    /// A key rather than a position, because the list is replaced whole by every load: an
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

    /// Whether the ring is waiting for a post that does not exist yet — `j` pressed on the
    /// last post there is. The first post to arrive takes it.
    ///
    /// Every press answers this afresh, so a reader who asked for more and then went back up
    /// is no longer waiting and the page that arrives leaves their ring alone.
    @ObservationIgnored private(set) var awaitingOlder = false

    private let posts: FeedPosts
    private let preferences: Preferences

    init(posts: FeedPosts, preferences: Preferences) {
        self.posts = posts
        self.preferences = preferences
    }

    /// The post the ring is on, if the list still has it.
    ///
    /// Nothing is pruned when a load drops the selected post — the key is simply a key the
    /// list no longer answers to, so no ring is drawn and there is nothing to open. Should
    /// the post come back — a filter turned off again, a later load carrying it — the ring
    /// comes back with it, which is what a reader who turned a filter on and off again
    /// would expect. What does not happen either way is the list moving under them.
    var selectedPost: Post? {
        let shown = posts.rules()
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
        let shown = posts.rules()
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

    /// The ring, put where the reader clicked. Nothing else moves: the list does not scroll to
    /// it, because it is already under their pointer.
    func select(_ post: Post) {
        guard selection != post.mergeKey else { return }
        selection = post.mergeKey
        awaitingOlder = false
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

    /// The ring, where `j` asked for a post that had not arrived yet: it lands on the first of
    /// the new posts the reader can actually see, and a page the filters hide entirely leaves
    /// it waiting for the next one.
    ///
    /// The rules are applied to the arriving page rather than read off the shown list, because
    /// the shown list has just changed under it: asking `rules()` here is a guaranteed miss and
    /// a rebuild of the whole index, to answer a question about forty posts.
    func land(theRingOn joining: [Post]) {
        guard awaitingOlder else { return }
        let visible = TimelineLoader.apply(showBoosts: preferences.showBoosts,
                                           mediaOnly: preferences.showMediaOnly, to: joining)
        guard let landing = visible.first else { return }
        selection = landing.mergeKey
        awaitingOlder = false
    }
}
