import Foundation
import Testing
@testable import FediqoUI

/// #143: Preferences says which Fediqo this is — exactly what the build was stamped with.
@Suite("Which Fediqo this is")
@MainActor
struct BuildStampTests {
    private let hash = "532ab49533714f81df09bc740eb2fd8205c41e30"

    private func stamped(dirty: String = "NO") -> [String: Any] {
        [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "510",
            BuildStamp.revisionKey: hash,
            BuildStamp.dirtyKey: dirty,
        ]
    }

    @Test("The version, build and revision are the stamped ones, character for character")
    func readsWhatWasStamped() {
        let stamp = BuildStamp(info: stamped())
        #expect(stamp == BuildStamp(version: "0.1.0", build: "510", revision: hash, changes: .none))
        let rows = stamp.rows(language: .english)
        #expect(rows.map(\.label) == ["Version", "Build", "Source", "Changes"])
        #expect(rows.map(\.value) == ["0.1.0", "510", hash, "None: built exactly as committed"])
        #expect(rows.map(\.isReading) == [false, false, true, false])
    }

    /// The page reports; it never corrects. A version from a series that is not the milestone in
    /// hand is still the version, and nothing is rounded, padded or prefixed.
    @Test("Whatever the stamp says is shown as it is, not as a milestone")
    func neverCorrects() {
        var info = stamped()
        info["CFBundleShortVersionString"] = "0.1"
        info["CFBundleVersion"] = "0"
        let rows = BuildStamp(info: info).rows(language: .english)
        #expect(rows[0].value == "0.1")
        #expect(rows[1].value == "0")
    }

    @Test("A build from uncommitted changes says so")
    func dirtySaysSo() {
        let stamp = BuildStamp(info: stamped(dirty: "YES"))
        #expect(stamp.changes == .uncommitted)
        #expect(stamp.rows(language: .english).last?.value == "Built with changes not yet committed")
        #expect(stamp.rows(language: .taiwanese).last?.value == "組建時含有尚未提交的變更")
    }

    @Test("A revision with no word on changes claims neither clean nor dirty")
    func changesUnrecorded() {
        var info = stamped()
        info[BuildStamp.dirtyKey] = nil
        let stamp = BuildStamp(info: info)
        #expect(stamp.changes == .unrecorded)
        #expect(stamp.rows(language: .english).last?.value == "Not recorded")
    }

    /// Empty is what project.yml leaves when nothing was stamped, `$(…)` is a setting a tool did
    /// not expand, and no key at all is an older build. None of them is a revision.
    @Test("An absent stamp is said, never made up", arguments: [nil, "", "$(FEDIQO_SOURCE_REVISION)"])
    func absentIsSaid(revision: String?) {
        var info: [String: Any] = [
            "CFBundleShortVersionString": "0.0.0",
            "CFBundleVersion": "0",
            BuildStamp.dirtyKey: "",
        ]
        if let revision { info[BuildStamp.revisionKey] = revision }
        let stamp = BuildStamp(info: info)
        #expect(stamp.revision == nil)
        let rows = stamp.rows(language: .english)
        #expect(rows.map(\.label) == ["Version", "Build", "Source"], "no Changes row with no revision")
        #expect(rows[2].value == "Not recorded: this build was made without its source written into it")
        #expect(rows.allSatisfy { !$0.value.contains("$(") })
    }

    @Test("No Info.plist at all: every row says it is not recorded")
    func nothingAtAll() {
        let rows = BuildStamp(info: nil).rows(language: .english)
        #expect(rows.map(\.value) == [
            "Not recorded", "Not recorded",
            "Not recorded: this build was made without its source written into it",
        ])
    }

    /// `swift test` runs inside a test host that Apps/Makefile never stamped, so the app's own
    /// reading of its bundle must come back without a revision rather than inventing one.
    @Test("A package test run is not stamped, and says so")
    func packageRunIsUnstamped() {
        #expect(BuildStamp.main.revision == nil)
        #expect(BuildStamp.main.changes == .unrecorded)
    }

    @Test("One copy is everything on the page, whole, in the page's words and order")
    func copyAll() {
        let stamp = BuildStamp(info: stamped(dirty: "YES"))
        #expect(stamp.copyText(language: .english) == """
            This Fediqo
            Version: 0.1.0
            Build: 510
            Source: \(hash)
            Changes: Built with changes not yet committed
            """)
        #expect(stamp.copyText(language: .taiwanese) == """
            這個 Fediqo
            版本：0.1.0
            組建：510
            原始碼：\(hash)
            變更：組建時含有尚未提交的變更
            """)
        let unstamped = BuildStamp(info: nil).copyText(language: .english)
        #expect(unstamped.hasSuffix("Source: Not recorded: this build was made without its source written into it"))
    }

    @Test("Every word on the page is in both languages")
    func bothLanguages() {
        let keys = [
            "about.title", "about.version", "about.build", "about.source", "about.source.none",
            "about.changes", "about.changes.none", "about.changes.uncommitted", "about.missing",
            "about.line", "about.copy", "about.copied", "about.copy.hint", "about.footer",
        ]
        for key in keys {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    @Test("Preferences has three tabs, what a person chooses, this build and what is in flight, in both languages")
    func preferencesTabs() {
        #expect(PreferencesPane.Purpose.allCases == [.choices, .build, .work])
        #expect(L10n.t("prefs.tab.work", language: .english) == "In flight")
        #expect(L10n.t("prefs.tab.work", language: .taiwanese) == "連線中")
        #expect(L10n.t("prefs.tab.choices", language: .english) == "Settings")
        #expect(L10n.t("prefs.tab.build", language: .english) == "This Fediqo")
        #expect(L10n.t("prefs.tab.choices", language: .taiwanese) == "設定")
        #expect(L10n.t("prefs.tab.build", language: .taiwanese) == "這個 Fediqo")
    }

    @Test("Tab on Preferences goes Settings, This Fediqo, In flight, and round again, as it does on Usage")
    func preferencesTabOrder() {
        let session = ShellSession(http: FixtureHTTP())
        #expect(session.preferencesPurpose == .choices)
        var visited: [PreferencesPane.Purpose] = []
        for _ in 0..<4 {
            #expect(session.rotatePreferencesTab(by: 1))
            visited.append(session.preferencesPurpose)
        }
        #expect(visited == [.build, .work, .choices, .build])
        session.rotatePreferencesTab(by: -1)
        #expect(session.preferencesPurpose == .choices)
        #expect(session.usagePurpose == .source, "Preferences' tabs are its own, not Usage's")
    }

    /// No view inspector here, so the page is pinned by what its files say, as Usage's is: the
    /// build tab is `BuildStampSection` and only that, the choices stay on the first tab, and the
    /// shell's Tab reaches Preferences.
    @Test("The build tab is its own page, and the shell's Tab reaches it")
    func tabsAreWired() throws {
        let shell = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI")
        let pane = try String(contentsOf: shell.appendingPathComponent("Shell/PreferencesPane.swift"), encoding: .utf8)
        let root = try String(contentsOf: shell.appendingPathComponent("FediqoRootView.swift"), encoding: .utf8)
        #expect(pane.contains("case .build: BuildStampSection(stamp: stamp)"))
        #expect(pane.contains("case .choices: choices"))
        #expect(pane.contains("case .work: SourceWorkSection(work: session?.work ?? .shared)"))
        #expect(root.contains("case .preferences: session.rotatePreferencesTab(by: step)"))
    }

    /// The route the stamp takes: project.yml writes the two settings into each app's Info.plist
    /// under the keys `BuildStamp` reads. A key renamed on one side and not the other would
    /// leave every build reading "not recorded", and nothing else would notice.
    @Test("Both apps' Info.plists carry the source under the keys the page reads", arguments: ["macOS", "iOS"])
    func plistsCarryTheKeys(platform: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Apps/\(platform)/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(plist[BuildStamp.revisionKey] as? String == "$(FEDIQO_SOURCE_REVISION)")
        #expect(plist[BuildStamp.dirtyKey] as? String == "$(FEDIQO_SOURCE_DIRTY)")
        #expect(plist["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
        #expect(plist["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
    }
}
