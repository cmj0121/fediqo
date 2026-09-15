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

    @Test("Empty launch lands on Account")
    func launchPlaceIsAccount() {
        #expect(ShellPlace.launch == .account)
    }

    @Test("Named queries start empty; Work is not shipped")
    func shippedQueriesAreEmpty() {
        #expect(DummyTimeline.shipped.isEmpty)
        #expect(!DummyTimeline.shipped.map(\.id).contains("work"))
    }

    @Test("Every place can say what the action is for")
    func everyPlaceHasASummary() {
        for place in ShellPlace.allCases {
            #expect(!place.summary.isEmpty)
        }
    }

    @Test("The rail has two widths")
    func railWidths() {
        #expect(RailView.Metrics.collapsedWidth < RailView.Metrics.expandedWidth)
    }

    @Test("A rail row is the same height open or collapsed")
    func railRowHeightIsStable() {
        #expect(RailView.Metrics.rowInnerHeight == RailView.Metrics.well)
        #expect(RailView.Metrics.iconSize < RailView.Metrics.well)
    }

    @Test("Shell copy comes from the module, not the key")
    func shellCopyIsTranslated() {
        #expect(ShellPlace.timeline.title != "shell.timeline.title")
        #expect(ShellPlace.usage.title != "shell.usage.title")
        #expect(L10n.t("rail.collapse.title") != "rail.collapse.title")
        #expect(L10n.t("account.rail.empty") != "account.rail.empty")
        #expect(L10n.t("account.add.title") != "account.add.title")
        #expect(L10n.t("shell.timeline.disabled") != "shell.timeline.disabled")
        #expect(L10n.t("compose.disabled.summary") != "compose.disabled.summary")
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
    }
}

@Suite("The empty session")
struct EmptySessionTests {
    @Test("Timeline and notices rails are not selectable")
    func timelineAndNoticesAreOff() {
        let empty = ShellAvailability.empty
        #expect(!empty.allows(.timeline))
        #expect(!empty.allows(.notices))
        #expect(empty.allows(.account))
        #expect(empty.allows(.usage))
        #expect(empty.allows(.preferences))
        #expect(empty.enabledPlaces == [.account, .usage, .preferences])
    }

    @Test("Compose command no-ops without a signed-in source")
    func composeNoOpsWhenUnsigned() {
        #expect(DummyCommand.from("c") == .compose)
        #expect(!ShellAvailability.empty.canCompose)
        #expect(ShellAvailability.empty.composeHintKey == "compose.disabled.summary")
    }

    @Test("Place rotate skips disabled")
    func placeRotateSkipsDisabled() {
        let empty = ShellAvailability.empty
        #expect(empty.rotate(from: .account, by: 1) == .usage)
        #expect(empty.rotate(from: .usage, by: 1) == .preferences)
        #expect(empty.rotate(from: .preferences, by: 1) == .account)
        #expect(empty.rotate(from: .account, by: -1) == .preferences)
        #expect(empty.rotate(from: .timeline, by: 1) == .account)
        #expect(empty.placing(.account, as: .timeline) == .account)
        #expect(empty.placing(.account, as: .notices) == .account)
        #expect(empty.placing(.account, as: .usage) == .usage)
    }

    @Test("Disabled rail copy is the reason, not a fake host")
    func disabledReasonsAndEmptyAccount() {
        let empty = ShellAvailability.empty
        #expect(empty.reasonKey(for: .timeline) == "shell.timeline.disabled")
        #expect(empty.reasonKey(for: .notices) == "shell.notices.disabled")
        #expect(empty.reasonKey(for: .account) == nil)
        #expect(L10n.t("account.rail.empty", language: .english) == "Add a source")
        #expect(L10n.t("account.add.title", language: .english) == "Add a source")
        #expect(
            L10n.t("account.add.detail", language: .english)
                == "Pick a Mastodon host from the list, or type its hostname. This session only."
        )
        #expect(L10n.t("shell.timeline.disabled", language: .english) == "Add a source on Account first")
        #expect(L10n.t("shell.notices.disabled", language: .english) == "Notices need a signed-in source")
        #expect(L10n.t("compose.disabled.summary", language: .english) == "Compose needs a signed-in source")
        #expect(
            L10n.t("notices.empty.detail", language: .english)
                == "Notices need a signed-in source. This session has none."
        )
    }

    @Test("Timeline enables when All and Trends exist")
    func timelineEnablesWhenAllAndTrendsExist() {
        #expect(!ShellAvailability(queryIDs: ["all"]).allows(.timeline))
        #expect(!ShellAvailability(queryIDs: ["trends"]).allows(.timeline))
        let ready = ShellAvailability(queryIDs: ["all", "trends"])
        #expect(ready.allows(.timeline))
        #expect(!ready.allows(.notices))
        #expect(!ready.canCompose)
        let signed = ShellAvailability(queryIDs: ["all", "trends"], signedIn: true)
        #expect(signed.allows(.notices))
        #expect(signed.canCompose)
        #expect(signed.rotate(from: .timeline, by: 1) == .notices)
    }

    @Test("Dummy stored items are not what All would show")
    func allIsEmptyWithoutJoin() {
        #expect(DummyItem.stored.isEmpty)
        #expect(DummyTimeline(id: "all").emptyKey == "timeline.empty")
        #expect(DummyTimeline(id: "trends").emptyKey == "timeline.empty.trends")
        #expect(
            L10n.t("timeline.empty", language: .english)
                == "No items yet. Public notes from these sources will land here."
        )
        #expect(
            L10n.t("timeline.empty.trends", language: .english)
                == "No trending notes yet. Notes that arrived as trending will land here."
        )
        #expect(L10n.t("timeline.empty") != L10n.t("timeline.empty.trends"))
        #expect(L10n.t("timeline.tab.trends", language: .english) == "Trends")
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
        #expect(DummyCommand.advanced(["all", "trends"], from: "all", by: 1) == "trends")
        #expect(DummyCommand.advanced(["all", "trends"], from: "trends", by: 1) == "all")
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
        #expect(DummyCommand.from("j", fieldFocused: true) == nil)
        #expect(DummyCommand.from("c", fieldFocused: true) == nil)
        #expect(DummyCommand.from("?", fieldFocused: true) == nil)
        #expect(DummyCommand.from("\t", fieldFocused: true) == nil)
        #expect(DummyCommand.from("\u{1B}", fieldFocused: true) == nil)
        #expect(DummyCommand.from("\r", fieldFocused: true) == nil)
        #expect(DummyCommand.stepped(["a", "b", "c"], from: nil, by: 1) == "a")
        #expect(DummyCommand.stepped(["a", "b", "c"], from: nil, by: -1) == "c")
        #expect(DummyCommand.stepped(["a", "b", "c"], from: "a", by: 1) == "b")
        #expect(DummyCommand.stepped(["a", "b", "c"], from: "c", by: 1) == "c")
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
        #expect(L10n.t("account.rail.empty", language: .taiwanese) == "新增來源")
        #expect(L10n.t("timeline.empty", language: .taiwanese) == "還沒有項目。這些來源的公開貼文會出現在這裡。")
        #expect(L10n.t("timeline.empty.trends", language: .taiwanese) == "還沒有趨勢項目。以趨勢進來的貼文會出現在這裡。")
    }
}
