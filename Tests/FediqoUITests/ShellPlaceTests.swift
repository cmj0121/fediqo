import Testing
@testable import FediqoUI

@Suite("The shell")
struct ShellPlaceTests {
    @Test("Compose is not a place")
    func composeIsNotAPlace() {
        #expect(ShellPlace.allCases.map(\.rawValue) == [
            "timeline", "notices", "account", "usage", "preferences",
        ])
    }

    @Test("Dummy tabs are named queries")
    func dummyTabs() {
        #expect(DummyTimeline.shipped.map(\.id) == ["all", "work"])
    }

    @Test("Every place can say what the action is for")
    func everyPlaceHasASummary() {
        for place in ShellPlace.allCases {
            #expect(!place.summary.isEmpty)
        }
    }

    @Test("The rail has two widths")
    func railWidths() {
        #expect(RailView.collapsedWidth < RailView.expandedWidth)
    }

    @Test("A rail row is the same height open or collapsed")
    func railRowHeightIsStable() {
        #expect(RailView.rowInnerHeight == RailView.well)
        #expect(RailView.iconSize < RailView.well)
    }

    @Test("Shell copy comes from the module, not the key")
    func shellCopyIsTranslated() {
        #expect(ShellPlace.timeline.title != "shell.timeline.title")
        #expect(ShellPlace.usage.title != "shell.usage.title")
        #expect(L10n.t("rail.collapse.title") != "rail.collapse.title")
    }

    @Test("Usage is a place, with the statistic bar")
    func usageIsAPlace() {
        #expect(ShellPlace.usage.symbolName == "chart.bar.xaxis")
        #expect(!ShellPlace.usage.summary.isEmpty)
    }

    @Test("A source without an account is unsigned")
    func unsignedSource() {
        #expect(!DummySource.unsignedPublic.isSignedIn)
        #expect(DummySource.unsignedPublic.account == nil)
    }

    @Test("A signed-in source carries account meta")
    func signedInSource() {
        #expect(DummySource.signedIn.isSignedIn)
        #expect(DummySource.signedIn.account?.handle == "@you@second.example")
        #expect(DummyTimeline(id: "all").sources.contains { $0.isSignedIn })
        #expect(DummyTimeline(id: "all").sources.contains { !$0.isSignedIn })
    }
}
