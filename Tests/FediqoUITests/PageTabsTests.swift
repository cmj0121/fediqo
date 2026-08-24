import Testing
@testable import FediqoUI

/// Two levels of place. A page is a main category and the rail lists them; a tab is a
/// sub-category inside one, and only the Timeline page has any.
@Suite("Pages, and the tabs inside them")
@MainActor
struct PageTabsTests {
    @Test("The rail is the four main categories, and Trending is not one of them")
    func rail() {
        #expect(RailItem.allCases == [.timeline, .kept, .statistics, .settings])
    }

    @Test("The feed being read is the visible tab of the visible page")
    func feedFollowsTheTab() {
        let app = freshApp("feed-follows-tab")
        app.railItem = .timeline
        #expect(app.feedMode == .timeline)
        app.feedTab = .trending
        #expect(app.feedMode == .trending)
    }

    @Test("A page with no tabs reads no feed, whichever tab was last chosen",
          arguments: pagesWithoutTabs)
    func noFeedWithoutTabs(page: RailItem) {
        let app = freshApp("no-feed-without-tabs")
        app.feedTab = .trending
        app.railItem = page
        #expect(app.feedMode == nil)
    }

    @Test("The clock is keyed to the tab, so changing tab starts a new one")
    func refreshKeyCarriesTheTab() {
        let app = freshApp("refresh-key-tab")
        app.railItem = .timeline
        app.feedTab = .timeline
        let reading = app.refreshKey
        app.feedTab = .trending
        #expect(app.refreshKey != reading)
        #expect(app.refreshKey.tab == .trending)
    }

    @Test("Choosing a tab you cannot see does not disturb a clock that is not running")
    func refreshKeyIgnoresAnInvisibleTab() {
        let app = freshApp("refresh-key-invisible-tab")
        app.railItem = .settings
        let sitting = app.refreshKey
        #expect(sitting.tab == nil)
        app.feedTab = .trending
        #expect(app.refreshKey == sitting)
    }
}
