import Testing
@testable import FediqoCore

/// The two feeds are the two tabs of the one page that reads a feed, so the order they are
/// listed in is the order the reader sees them in, and each has to be tellable from the other
/// by something a list can hold on to.
@Suite("Two feeds, and the order they sit in")
struct FeedModeTests {
    @Test("The public timeline comes first and trending sits beside it")
    func order() {
        #expect(FeedMode.allCases == [.timeline, .trending])
    }

    @Test("Each feed is its own row, named by itself")
    func identity() {
        #expect(FeedMode.allCases.map(\.id) == ["timeline", "trending"])
    }
}
