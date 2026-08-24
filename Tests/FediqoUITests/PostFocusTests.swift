import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// A post whose `mergeKey` is the name given here, so a test can say which row it means.
private func post(_ name: String, web: URL? = URL(string: "https://example.social/@a/1")) -> Post {
    Post(uri: name, socialProtocol: .mastodon, sourceURL: "https://example.social",
         createdAt: Date(timeIntervalSince1970: 0), authorId: "a", authorName: "A",
         authorHandle: "@a", text: name, webURL: web)
}

private let abc = [post("a"), post("b"), post("c")]

/// The ring: where the reader is in a list, and what moves it.
@Suite("The post you are on")
@MainActor
struct PostFocusTests {
    private func feedOnB() -> FeedModel {
        let feed = FeedModel(mode: .timeline)
        feed.moveSelection(by: 1, in: abc)
        feed.moveSelection(by: 1, in: abc)
        #expect(feed.selection == "b")
        return feed
    }

    @Test("Nothing is selected until something is")
    func nothingAtFirst() {
        let feed = FeedModel(mode: .timeline)
        #expect(feed.selection == nil)
        #expect(feed.selectedPost(in: abc) == nil)
    }

    /// There is no "where you were" to step from, so both keys mean the same thing once:
    /// start at the top of the list.
    @Test("With nothing selected, the first press starts at the first post",
          arguments: [1, -1])
    func firstPressStartsAtTheTop(steps: Int) {
        let feed = FeedModel(mode: .timeline)
        #expect(feed.moveSelection(by: steps, in: abc))
        #expect(feed.selection == "a")
    }

    @Test("j walks down the list and stops at the bottom rather than coming round again")
    func stopsAtTheBottom() {
        let feed = FeedModel(mode: .timeline)
        for name in ["a", "b", "c"] {
            #expect(feed.moveSelection(by: 1, in: abc))
            #expect(feed.selection == name)
        }
        #expect(feed.moveSelection(by: 1, in: abc) == false)
        #expect(feed.selection == "c")
    }

    @Test("k walks back up and stops at the top rather than coming round again")
    func stopsAtTheTop() {
        let feed = feedOnB()
        #expect(feed.moveSelection(by: -1, in: abc))
        #expect(feed.selection == "a")
        #expect(feed.moveSelection(by: -1, in: abc) == false)
        #expect(feed.selection == "a")
    }

    @Test("A list with no posts in it has nowhere to go")
    func emptyList() {
        let feed = FeedModel(mode: .timeline)
        #expect(feed.moveSelection(by: 1, in: []) == false)
        #expect(feed.selection == nil)
    }

    // MARK: - A list that changed underneath

    /// The whole reason the ring is written in a `mergeKey` rather than a position: every
    /// load replaces the list, and a refresh that brings ten new posts must not carry the
    /// ring ten posts down with it.
    @Test("New posts above do not move the ring off the post it is on")
    func survivesARefresh() {
        let feed = feedOnB()
        let refreshed = [post("x"), post("y")] + abc
        #expect(feed.selectedPost(in: refreshed)?.mergeKey == "b")
        #expect(feed.moveSelection(by: 1, in: refreshed))
        #expect(feed.selection == "c")
    }

    @Test("The ring is on the post, so it goes where the post goes")
    func survivesAReorder() {
        let feed = feedOnB()
        let reordered = [post("c"), post("b"), post("a")]
        #expect(feed.selectedPost(in: reordered)?.mergeKey == "b")
        #expect(feed.moveSelection(by: 1, in: reordered))
        #expect(feed.selection == "a")
    }

    /// Nothing is pruned: the key stays, and it is simply a key this list does not answer
    /// to. So no ring is drawn, `Return` has nothing to open, and the next step starts over
    /// at the top rather than guessing at where the post used to be.
    @Test("A selected post that is gone leaves no ring and nothing to open")
    func selectedPostDisappears() {
        let feed = feedOnB()
        let without = [post("a"), post("c")]
        #expect(feed.selectedPost(in: without) == nil)
        #expect(feed.selectedURL(in: without) == nil)
        #expect(feed.moveSelection(by: 1, in: without))
        #expect(feed.selection == "a")
    }

    /// A filter turned on and off again is the common way a post leaves a list and comes
    /// back to it, and the reader who turned it off wants to be where they were.
    @Test("A post that comes back brings the ring back with it")
    func selectedPostReturns() {
        let feed = feedOnB()
        #expect(feed.selectedPost(in: [post("a")]) == nil)
        #expect(feed.selectedPost(in: abc)?.mergeKey == "b")
    }

    // MARK: - Opening, and going back to the top

    @Test("Return opens the address of the post the ring is on")
    func opensTheSelectedPost() {
        let feed = feedOnB()
        #expect(feed.selectedURL(in: abc)?.absoluteString == "https://example.social/@a/1")
    }

    /// Silent, and on purpose: there is no fault to report — the post is not a page
    /// anywhere — and a warning would be the app complaining about somebody else's server
    /// every time the reader pressed `Return` on the wrong row.
    @Test("A post the server gave no address for has nothing to open, and says nothing")
    func openingAPostWithNoAddress() {
        let feed = FeedModel(mode: .timeline)
        let posts = [post("a", web: nil)]
        #expect(feed.moveSelection(by: 1, in: posts))
        #expect(feed.selectedURL(in: posts) == nil)
    }

    /// Being taken to the top with the ring still on a post a thousand rows down would be
    /// telling the reader they are in two places.
    @Test("Going to the top lets the ring go, and means it again every time it is asked")
    func goingToTheTop() {
        let feed = feedOnB()
        feed.goToTop()
        #expect(feed.selection == nil)
        #expect(feed.topRequests == 1)
        feed.goToTop()
        #expect(feed.topRequests == 2)
    }
}

/// The same keys, asked of the app rather than of one feed.
@Suite("Steering the posts from the keyboard")
@MainActor
struct PostCommandTests {
    @Test("On a page with no posts, none of the post keys has anything to do",
          arguments: [RailItem.kept, .statistics, .settings])
    func nothingToDoWithoutAFeed(page: RailItem) {
        let app = freshApp("post-keys-without-a-feed")
        app.railItem = page
        for command in [KeyCommand.nextPost, .previousPost, .openPost, .backToTop] {
            #expect(app.perform(command) == false)
        }
    }

    /// `↑`, `↓` and `Return` are how somebody without a pointer steers every other screen in
    /// the app. A page with no timeline must hand them back, or the pickers in Settings
    /// cannot be moved and its buttons cannot be pressed.
    @Test("A key a control might want is given back where there was nothing to do with it",
          arguments: [(down, KeyCommand.nextPost), (up, .previousPost), (enter, .openPost)]
            as [(Character, KeyCommand)],
          [RailItem.kept, .statistics, .settings])
    func sharedKeysAreHandedBack(press: (key: Character, command: KeyCommand), page: RailItem) {
        let app = freshApp("post-keys-shared-handed-back")
        app.railItem = page
        #expect(app.consumes(press.command, spelledWith: press.key) == false)
    }

    /// A letter is ours alone: nothing on any screen wants a bare `g`, so handing one back
    /// only has AppKit find nobody who wanted it and beep at a reader pressing a key the app
    /// documents.
    @Test("A letter is kept even where there is nothing for it to do",
          arguments: [(Character("j"), KeyCommand.nextPost), ("k", .previousPost), ("g", .backToTop)]
            as [(Character, KeyCommand)],
          [RailItem.kept, .statistics, .settings])
    func lettersAreAlwaysKept(press: (key: Character, command: KeyCommand), page: RailItem) {
        let app = freshApp("post-keys-letters-kept")
        app.railItem = page
        #expect(app.consumes(press.command, spelledWith: press.key))
    }

    @Test("A timeline with nothing in it yet has nothing to move through")
    func emptyTimeline() {
        let app = freshApp("post-keys-empty-timeline")
        app.railItem = .timeline
        #expect(app.feedMode == .timeline)
        #expect(app.perform(.nextPost) == false)
        #expect(app.perform(.previousPost) == false)
    }

    /// The list may be empty but the top of it is still a place, and the button in the
    /// header asks for it by the same road.
    @Test("Going to the top is always something a timeline can do")
    func topOfATimeline() {
        let app = freshApp("post-keys-top")
        app.railItem = .timeline
        #expect(app.perform(.backToTop))
        #expect(app.feed(for: .timeline).topRequests == 1)
    }

    @Test("With no post under the ring, nothing is opened at all")
    func nothingToOpen() {
        let app = freshApp("post-keys-nothing-to-open")
        app.railItem = .timeline
        var opened: [URL] = []
        app.openLink = { opened.append($0) }
        #expect(app.perform(.openPost) == false)
        #expect(opened.isEmpty)
    }

    /// Two tabs are two lists, and each keeps its own place in itself.
    @Test("The ring belongs to the feed, so the two tabs do not share one")
    func aRingPerTab() {
        let app = freshApp("post-keys-ring-per-tab")
        app.railItem = .timeline
        app.feedTab = .timeline
        #expect(app.perform(.backToTop))
        #expect(app.feed(for: .timeline).topRequests == 1)
        #expect(app.feed(for: .trending).topRequests == 0)
    }
}

/// The wired path: a feed with real posts in it, the keys pressed on the app rather than on
/// the feed, and the address the shell is handed at the end of it.
@Suite("Reading a feed that has posts in it")
@MainActor
struct WiredPostKeyTests {
    /// The same three posts, each at an address of its own, so that opening one proves which
    /// one was opened.
    private static let posts = ["a", "b", "c"].map {
        post($0, web: URL(string: "https://example.social/@a/\($0)"))
    }

    private func timeline(_ name: String) -> AppState {
        let app = freshApp(name)
        app.railItem = .timeline
        app.feedTab = .timeline
        app.feed(for: .timeline).show(Self.posts)
        return app
    }

    @Test("j and k walk the ring through the posts the app is showing, and stop at the ends")
    func movesThroughTheList() {
        let app = timeline("wired-move")
        let feed = app.feed(for: .timeline)
        for name in ["a", "b", "c"] {
            #expect(app.perform(.nextPost))
            #expect(feed.selection == name)
        }
        #expect(app.perform(.nextPost) == false)
        #expect(app.perform(.previousPost))
        #expect(feed.selection == "b")
    }

    /// The line issue #19 is written on: a post is *opened*. The shell lends the app its own
    /// way of opening a link, and this is that loan being spent, on the post the ring is on.
    @Test("Return opens the address of the post the ring is on, and no other")
    func opensTheSelectedPost() {
        let app = timeline("wired-open")
        var opened: [URL] = []
        app.openLink = { opened.append($0) }
        app.perform(.nextPost)
        app.perform(.nextPost)
        #expect(app.perform(.openPost))
        #expect(opened.map(\.absoluteString) == ["https://example.social/@a/b"])
    }

    /// Whether the shell has lent a way of opening a link is a different question from
    /// whether there was a post to open, and `Return` answers only the second.
    @Test("A post with an address is something to open, however it would be opened")
    func aPostToOpenBeforeTheLoan() {
        let app = timeline("wired-open-unlent")
        #expect(app.openLink == nil)
        #expect(app.perform(.nextPost))
        #expect(app.perform(.openPost))
    }

    @Test("A post the server gave no address for is nothing to open, and nothing is opened")
    func aPostWithNoAddress() {
        let app = timeline("wired-open-no-address")
        app.feed(for: .timeline).show([post("a", web: nil)])
        var opened: [URL] = []
        app.openLink = { opened.append($0) }
        #expect(app.perform(.nextPost))
        #expect(app.perform(.openPost) == false)
        #expect(opened.isEmpty)
    }

    /// The other half of the rule, at the one place a reader meets it: holding `j` at the
    /// bottom of a list is silent, and `↓` there is still the scroll view's to answer.
    @Test("At the bottom of the list, j is still kept and ↓ is still given back")
    func atTheBottomOfTheList() {
        let app = timeline("wired-bottom")
        while app.perform(.nextPost) {}
        #expect(app.consumes(.nextPost, spelledWith: "j"))
        #expect(app.consumes(.nextPost, spelledWith: down) == false)
    }

    /// The ring follows the rules the reader set: a post the filters take out of the list is
    /// not a post the keys can land on.
    @Test("The keys move through the posts that are shown, not the ones that were loaded")
    func movesThroughWhatIsVisible() {
        let app = timeline("wired-filtered")
        app.preferences.showMediaOnly = true
        #expect(app.perform(.nextPost) == false)
        #expect(app.feed(for: .timeline).selection == nil)
    }
}
