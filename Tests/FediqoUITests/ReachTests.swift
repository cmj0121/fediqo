import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #112 — nothing needed to read or to act is reachable at one width only.
///
/// What a test can reach: that the narrow arrangement's compose button tells every page the
/// corner it floats over, exactly when it floats, and that the keys walk exactly the places the
/// tabs draw. What it cannot: that a list's end really stops short of the button. A scroll view
/// hosted with no window reports neither the margin nor a longer content, with the margin written
/// in as a literal — so a test measuring it here could not fail, and there is none. Named in the
/// report as unobserved.
@Suite("Every act at every width")
@MainActor
struct ReachTests {
    // MARK: The corner the compose button floats over

    /// **Present exactly when the button is.** Where compose cannot be pressed there is no button,
    /// so there is nothing to keep clear, and a list that stopped short of nothing would be room
    /// wasted at the end of every page.
    @Test("The floating corner is there exactly when the compose button is")
    func theCornerFollowsTheButton() {
        #expect(FediqoRootView.composeCorner(canCompose: false) == .zero)
        #expect(FediqoRootView.composeCorner(canCompose: true) != .zero)
    }

    /// The room asked for covers the button and the space the button keeps from the edges, in
    /// both directions — the end of a list upward, the end of the search bar inward.
    @Test("The corner reaches past the button in both directions")
    func theCornerCoversTheButton() {
        let corner = FediqoRootView.composeCorner(canCompose: true)
        let compact = FediqoRootView.Compact.self
        #expect(corner.height > compact.button + compact.clearance)
        #expect(corner.width > compact.button + ShellSpace.room)
    }

    /// Nothing is kept clear where nothing floats — the wide arrangement's default, and every
    /// page that is not under the tabs.
    @Test("Nothing floats anywhere by default")
    func nothingFloatsByDefault() {
        #expect(EnvironmentValues().shellFloatingCorner == .zero)
    }

    // MARK: Keys reach what the tabs draw

    /// The tabs are the places that can be entered, and ⌃Tab walks exactly those, in both
    /// arrangements, because the keys are read above either of them.
    @Test("⌃Tab walks exactly the places the tabs draw, whatever is open")
    func theKeysWalkTheTabs() {
        let cases: [ShellAvailability] = [
            .empty,
            ShellAvailability(queryIDs: ["all"]),
            ShellAvailability(queryIDs: ["all", "trends"], signedIn: true),
        ]
        for availability in cases {
            let tabs = availability.enabledPlaces
            var walked: [ShellPlace] = []
            var place = tabs[0]
            for _ in tabs {
                walked.append(place)
                place = availability.rotate(from: place, by: 1)
            }
            #expect(walked == tabs, "\(availability)")
            #expect(place == tabs[0], "\(availability) comes back round")
        }
    }
}
