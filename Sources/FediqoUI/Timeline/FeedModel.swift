import Foundation
import Observation
import FediqoCore

/// One feed, and the three jobs it is made of.
///
/// It used to be one object with fifteen stored properties doing three unrelated things — the
/// list and its filter cache, the reader's place in it, and the paging lifecycle — and a write
/// to any of them invalidated every view that read any of the others. A spinner appearing at
/// the foot of a cold start redrew the header, the tabs and the whole list, several times a
/// second (#70).
///
/// They are `FeedPosts`, `FeedPlace` and `FeedPaging` now, each holding the state that is
/// actually its own. This stays because nothing outside should have to know which of the three
/// to ask: a screen has one feed, and asks it. What it reads through here is the sub-object's
/// own property, so observation still stops at the leaf — a view that reads `visible` depends
/// on the list and not on whether a page is out.
@MainActor
@Observable
final class FeedModel {
    /// What is on the screen.
    let posts: FeedPosts
    /// Where the reader is standing in it.
    let place: FeedPlace
    /// Whether anything is on its way, and what the last asking said.
    let paging: FeedPaging

    init(timeline: Timeline, preferences: Preferences, loader: TimelineLoader = TimelineLoader()) {
        let posts = FeedPosts(timeline: timeline, preferences: preferences)
        let place = FeedPlace(rows: posts)
        self.posts = posts
        self.place = place
        self.paging = FeedPaging(posts: posts, place: place, loader: loader)
    }

    // MARK: - The list

    /// Which timeline this is reading — its base source, its rules, and the name the reader
    /// gave it.
    ///
    /// Changing the question is the one rule that is about two of the three, which is why it
    /// is stated here rather than inside either: what was on the screen was the answer to the
    /// old question, and the next `loadIfNeeded` must ask again rather than recognise the
    /// servers it asked last time and do nothing.
    var timeline: Timeline {
        get { posts.timeline }
        set {
            let asked = newValue.query != posts.timeline.query
            posts.timeline = newValue
            guard asked else { return }
            posts.forgetTheList()
            paging.forgetTheLoad()
        }
    }

    var result: TimelineResult { posts.result }
    var visible: [Post] { posts.visible }
    var hidden: [Hidden] { posts.hidden }
    func show(_ list: [Post]) { posts.show(list) }

    // MARK: - Where the reader is

    var selection: String? { place.selection }
    var selectedPost: Post? { place.selectedPost }
    var selectedURL: URL? { place.selectedURL }
    var topRequests: Int { place.topRequests }
    var awaitingOlder: Bool { place.awaitingOlder }

    @discardableResult
    func moveSelection(by steps: Int) -> Bool { place.moveSelection(by: steps) }
    func select(_ post: Post) { place.select(post) }
    func goToTop() { place.goToTop() }

    // MARK: - What is on its way

    typealias Bottom = FeedPaging.Bottom

    var loading: Bool { paging.loading }
    var bottom: Bottom { paging.bottom }
    var failures: [String: SourceFailure] { paging.failures }
    var storeFailure: SourceFailure? { paging.storeFailure }
    var loader: TimelineLoader { paging.loader }
    var settling: Task<Void, Never>? { paging.settling }
    var announcementLasts: Duration {
        get { paging.announcementLasts }
        set { paging.announcementLasts = newValue }
    }
    var onTokenRejected: (@MainActor (String) -> Void)? {
        get { paging.onTokenRejected }
        set { paging.onTokenRejected = newValue }
    }

    func loadIfNeeded(servers: [Server]) async { await paging.loadIfNeeded(servers: servers) }
    /// The next `loadIfNeeded` asks again even though the servers have not changed.
    ///
    /// For the one case where they are the same servers and the answer is not: somebody has been
    /// followed, so what home holds is different without anything about the reading being (#88).
    func forgetTheLoad() { paging.forgetTheLoad() }
    func load(servers: [Server], refresh: Refresh = .manual) async {
        await paging.load(servers: servers, refresh: refresh)
    }
    func loadOlder(servers: [Server]) async { await paging.loadOlder(servers: servers) }
    /// Asks these servers again about the stretch this feed is already holding of them — for
    /// when what they would say about it has changed and nothing about the reading has (#92).
    func refill(_ servers: [Server]) async { await paging.refill(servers) }
}
