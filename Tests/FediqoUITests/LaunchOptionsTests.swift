import Testing
import FediqoCore
@testable import FediqoUI

/// Opening the app at a screen, so each one can be looked at without clicking through the
/// ones before it. `FEDIQO_RAIL` used to name a page and one of its names is now a tab.
@Suite("Opening the app somewhere other than the beginning")
struct LaunchOptionsTests {
    @Test("`trending` still names one screen: the Timeline page, on its Trending tab")
    func trendingIsATabNow() {
        let options = LaunchOptions.fromEnvironment(["FEDIQO_RAIL": "trending"])
        #expect(options.railItem == .timeline)
        #expect(options.feedTab == .trending)
    }

    @Test("A page names itself and leaves the tab alone", arguments: [
        ("timeline", RailItem.timeline), ("kept", .kept), ("statistics", .statistics), ("settings", .settings),
    ])
    func pagesOpenThemselves(name: String, page: RailItem) {
        let options = LaunchOptions.fromEnvironment(["FEDIQO_RAIL": name])
        #expect(options.railItem == page)
        #expect(options.feedTab == nil)
    }

    @Test("A name that is neither a page nor a tab opens nothing in particular")
    func unknownNamesAreIgnored() {
        let options = LaunchOptions.fromEnvironment(["FEDIQO_RAIL": "elsewhere"])
        #expect(options.railItem == nil)
        #expect(options.feedTab == nil)
    }

    @Test("Asked for nothing, it asks for nothing")
    func emptyEnvironment() {
        let options = LaunchOptions.fromEnvironment([:])
        #expect(options.route == nil)
        #expect(options.railItem == nil)
        #expect(options.feedTab == nil)
        #expect(options.composing == false)
    }
}
