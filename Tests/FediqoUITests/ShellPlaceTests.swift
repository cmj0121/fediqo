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

@Suite("The dummy keys")
struct DummyCommandTests {
    @Test("Question mark opens the guide")
    func questionMarkShowsTheGuide() {
        #expect(DummyCommand.from("?", shift: true) == .showShortcuts)
        #expect(DummyCommand.from("/") == nil)
        #expect(DummyCommand.from("?", typing: true) == nil)
    }

    @Test("The guide names every dummy command")
    func guideNamesEveryCommand() {
        let named = Set(DummyShortcut.all.flatMap(\.commands))
        #expect(named == Set(DummyCommand.allCases))
        #expect(DummyShortcut.all.contains { $0.keys.contains("?") })
        #expect(L10n.t("shortcut.title") != "shortcut.title")
        #expect(L10n.t("shortcut.tabs") != "shortcut.tabs")
        #expect(L10n.t("shortcut.pages") != "shortcut.pages")
        #expect(Set(DummyShortcut.all.map(\.group)) == Set(DummyShortcutGroup.allCases))
        #expect(L10n.t("shortcut.group.moving") != "shortcut.group.moving")
    }

    @Test("Letters belong to the draft while composing")
    func lettersYieldWhileTyping() {
        #expect(DummyCommand.from("c") == .compose)
        #expect(DummyCommand.from("c", typing: true) == nil)
        #expect(DummyCommand.from("\u{1B}", typing: true) == .dismiss)
        #expect(DummyCommand.from("\t", typing: true) == nil)
    }

    @Test("Tab rotates this page's tabs; control-tab rotates places")
    func tabRotatesTabsAndControlTabRotatesPlaces() {
        #expect(DummyCommand.from("\t") == .nextTab)
        #expect(DummyCommand.from("\t", shift: true) == .previousTab)
        #expect(DummyCommand.from("\t", control: true) == .nextPage)
        #expect(DummyCommand.from("\t", shift: true, control: true) == .previousPage)
        #expect(DummyCommand.advanced(["all", "work"], from: "all", by: 1) == "work")
        #expect(DummyCommand.advanced(["all", "work"], from: "work", by: 1) == "all")
        #expect(
            DummyCommand.advanced(ShellPlace.allCases, from: .timeline, by: -1) == .preferences
        )
    }

    @Test("j and k step this list without wrapping")
    func listKeysStepWithoutWrapping() {
        #expect(DummyCommand.from("j") == .nextPost)
        #expect(DummyCommand.from("k") == .previousPost)
        #expect(DummyCommand.from(" ") == .expandPost)
        #expect(DummyCommand.from("q") == .back)
        #expect(DummyCommand.from("g") == .goTop)
        #expect(DummyCommand.from("g", typing: true) == nil)
        #expect(DummyCommand.stepped(["a", "b", "c"], from: nil, by: 1) == "a")
        #expect(DummyCommand.stepped(["a", "b", "c"], from: nil, by: -1) == "c")
        #expect(DummyCommand.stepped(["a", "b", "c"], from: "a", by: 1) == "b")
        #expect(DummyCommand.stepped(["a", "b", "c"], from: "c", by: 1) == "c")
        #expect(DummyItem.stored[0].dummyReplies().count == 2)
        #expect(DummyCommand.consumes("j", did: false))
        #expect(!DummyCommand.consumes(" ", did: false))
    }
}

@Suite("Dummy preferences")
struct DummyPrefsTests {
    @Test("Language and theme default to the system")
    func languageAndThemeFollowTheSystem() {
        #expect(DummyLanguage.system.lprojName == nil)
        #expect(DummyTheme.system.colorScheme == nil)
        #expect(DummyTheme.light.colorScheme == .light)
        #expect(DummyTheme.dark.colorScheme == .dark)
    }

    @Test("Default type is a step above system large")
    func defaultTypeIsLarger() {
        #expect(DummyFontSize.standard.dynamicType == .xLarge)
        #expect(DummyFontSize.smallest.dynamicType < DummyFontSize.standard.dynamicType)
        #expect(DummyFontSize.standard.dynamicType < DummyFontSize.largest.dynamicType)
    }

    @Test("A chosen language loads that lproj")
    func chosenLanguageLoadsThatCatalog() {
        #expect(L10n.t("shell.timeline.title", language: .english) == "Timeline")
        #expect(L10n.t("shell.timeline.title", language: .taiwanese) == "時間軸")
        #expect(L10n.t("prefs.fontSize.default", language: .english) == "Default")
    }
}
