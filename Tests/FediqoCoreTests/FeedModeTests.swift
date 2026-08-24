import Testing
@testable import FediqoCore

/// The two feeds are the two tabs of the one page that reads a feed, so the order they are
/// listed in is the order the reader sees them in — and the order the keys rotate through.
@Suite("Two feeds, and the order they sit in")
struct FeedModeTests {
    @Test("The public timeline comes first and trending sits beside it")
    func order() {
        #expect(FeedMode.allCases == [.timeline, .trending])
    }
}
