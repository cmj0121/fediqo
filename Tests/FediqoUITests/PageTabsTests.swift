import Testing
@testable import FediqoUI

/// Two levels of place. A page is a main category and the rail lists them; a tab is a
/// sub-category inside one, and only the Timeline page has any — and there its tabs are the
/// reader's own timelines rather than a list this app decides.
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
        #expect(app.readingTimeline?.id == "public")
        app.currentTimeline = "trend"
        #expect(app.readingTimeline?.id == "trend")
    }

    @Test("A page with no tabs reads no feed, whichever tab was last chosen",
          arguments: pagesWithoutTabs)
    func noFeedWithoutTabs(page: RailItem) {
        let app = freshApp("no-feed-without-tabs")
        app.currentTimeline = "trend"
        app.railItem = page
        #expect(app.readingTimeline == nil)
    }

    @Test("The clock is keyed to the tab, so changing tab starts a new one")
    func refreshKeyCarriesTheTab() {
        let app = freshApp("refresh-key-tab")
        app.railItem = .timeline
        app.currentTimeline = "public"
        let reading = app.refreshKey
        app.currentTimeline = "trend"
        #expect(app.refreshKey != reading)
        #expect(app.refreshKey.timeline == "trend")
    }

    @Test("Choosing a tab you cannot see does not disturb a clock that is not running")
    func refreshKeyIgnoresAnInvisibleTab() {
        let app = freshApp("refresh-key-invisible-tab")
        app.railItem = .settings
        let sitting = app.refreshKey
        #expect(sitting.timeline == nil)
        app.currentTimeline = "trend"
        #expect(app.refreshKey == sitting)
    }
}
