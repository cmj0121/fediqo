import Testing
@testable import FediqoUI

/// About is a Settings tab whose numbers a test must be able to name. SwiftPM's host
/// bundle is not this app, so the values are injected rather than read from `Bundle.main`.
@Suite("The About tab")
struct AboutCatalogueTests {
    @Test("Every Settings tab has a name and a subtitle in both languages",
          arguments: ["en", "zh-TW"])
    func everySettingsTabIsTranslated(language: String) throws {
        let catalogue = try stringCatalogue()
        for tab in SettingsTab.allCases {
            for key in ["tab.\(tab.rawValue)", "\(tab.rawValue).subtitle"] {
                let value = catalogue[key]?[language]
                #expect(value?.isEmpty == false, "\(key) says nothing in \(language)")
            }
        }
    }

    @Test("Every label About draws is written in both languages",
          arguments: ["en", "zh-TW"])
    func everyAboutLabelIsTranslated(language: String) throws {
        let catalogue = try stringCatalogue()
        let keys = [
            "settings.version", "settings.version.marketing", "settings.version.build",
            "settings.shortcuts", "settings.shortcuts.hint",
        ]
        for key in keys {
            let value = catalogue[key]?[language]
            #expect(value?.isEmpty == false, "\(key) says nothing in \(language)")
        }
    }

    /// The last tab is About now. Leaving the old keys in the catalogue would keep a name
    /// the screen no longer uses, and a reader of the file would think Keyboard was still
    /// a tab.
    @Test("The Keyboard tab's strings are gone")
    func keyboardTabStringsAreGone() throws {
        let catalogue = try stringCatalogue()
        #expect(catalogue["tab.keyboard"] == nil)
        #expect(catalogue["keyboard.subtitle"] == nil)
    }
}

@Suite("What this build is")
@MainActor
struct AboutVersionTests {
    /// The About rows read these two properties and nothing else. A test that named them
    /// here and then asked a view would be asking SwiftUI whether it bound a value it was
    /// handed — the seam is the thing that can lie.
    @Test("About shows the marketing and build handed in at launch")
    func aboutShowsTheInjectedVersion() {
        let app = freshApp("about-version", marketingVersion: "1.2.3", buildVersion: "99")
        #expect(app.marketingVersion == "1.2.3")
        #expect(app.buildVersion == "99")
    }
}
