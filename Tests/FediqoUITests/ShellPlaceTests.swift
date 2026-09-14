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

@Suite("The dummy stream")
struct DummyStreamTests {
    @Test("All mixes three source shapes")
    func allMixesShapes() {
        let kinds = Set(DummyTimeline(id: "all").sources.map(\.kind))
        #expect(kinds == [.microblog, .forum, .board])
    }

    @Test("All is notes and threads in time order")
    func allIsMixedAndTimed() {
        let items = DummyTimeline(id: "all").items
        #expect(items.contains { $0.kind == .note })
        #expect(items.contains { $0.source.kind == .forum })
        #expect(items.contains { $0.source.kind == .board })
        #expect(items.map(\.postedAt) == items.map(\.postedAt).sorted(by: >))
        #expect(items.count == DummyItem.stored.count)
    }

    @Test("Work is a source subset and a rule")
    func workFiltersBySourceAndRule() {
        let work = DummyTimeline(id: "work")
        #expect(work.sources.map(\.id) == ["second.example", "forum.example"])
        #expect(work.items.allSatisfy { $0.workRelated })
        #expect(work.items.allSatisfy { work.sources.contains($0.source) })
        #expect(work.items.contains { $0.kind == .note })
        #expect(work.items.contains { $0.kind == .thread })
        #expect(work.items.count < DummyTimeline(id: "all").items.count)
    }

    @Test("A named query can say its rule")
    func namedQueryHasARule() {
        #expect(DummyTimeline(id: "all").rule != "timeline.rule.all")
        #expect(DummyTimeline(id: "work").rule != "timeline.rule.work")
        #expect(DummyTimeline(id: "all").rule != DummyTimeline(id: "work").rule)
    }

    @Test("A thread has an optional title; a note does not")
    func titleIsOptionalOnTheSameForm() {
        #expect(DummyItem.stored.filter { $0.kind == .note }.allSatisfy { $0.titleKey == nil })
        #expect(DummyItem.stored.filter { $0.kind == .thread }.allSatisfy { $0.titleKey != nil })
    }

    @Test("Decorator, visibility and thumb are optional")
    func rowFactsAreOptional() {
        #expect(DummyItem.stored.contains { $0.answering != .nothing })
        #expect(DummyItem.stored.contains { $0.answering == .nothing })
        #expect(DummyItem.stored.contains { $0.boostedBy != nil })
        #expect(DummyItem.stored.contains { $0.audience == nil })
        #expect(DummyItem.stored.contains { $0.hasThumb })
        #expect(DummyItem.stored.contains { !$0.hasThumb })
        #expect(DummyItem.stored.contains { !$0.hasAvatar })
    }

    @Test("Action copy comes from the module")
    func actionCopyIsTranslated() {
        #expect(L10n.t("item.act.kept") != "item.act.kept")
        #expect(L10n.t("item.toast.kept.on") != "item.toast.kept.on")
        #expect(L10n.t("timeline.add") != "timeline.add")
    }

    @Test("A merged item names extra hosts as plus-n")
    func mergedItemHasExtraHosts() {
        let merged = DummyItem.stored.first { $0.shownHosts.count > 1 }
        #expect(merged != nil)
        #expect(merged?.shownHosts == merged?.shownHosts.sorted())
        #expect(DummyItem.stored.contains { $0.shownHosts.count == 1 })
    }
}
