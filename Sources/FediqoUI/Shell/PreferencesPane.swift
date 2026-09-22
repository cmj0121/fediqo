import FediqoCore
import SwiftUI

/// Language, theme, type, and the latest date every timeline stops at (#22) — what a person
/// chooses. What this device holds is on `UsagePane` (#21). Last on the page, in a section of its
/// own, which Fediqo this is (#143) — see `BuildStampSection`.
struct PreferencesPane: View {
    @Environment(DummyPrefs.self) private var prefs

    /// What this build was stamped with. The app's own by default; a test or a preview hands in
    /// another.
    var stamp: BuildStamp = .main

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Picker(L10n.t("prefs.language"), selection: $prefs.language) {
                ForEach(DummyLanguage.allCases) { language in
                    Text(L10n.t("prefs.language.\(language.labelKey)")).tag(language)
                }
            }
            Picker(L10n.t("prefs.theme"), selection: $prefs.theme) {
                ForEach(DummyTheme.allCases) { theme in
                    Text(L10n.t("prefs.theme.\(theme.rawValue)")).tag(theme)
                }
            }
            Picker(L10n.t("prefs.fontSize"), selection: $prefs.fontSize) {
                ForEach(DummyFontSize.allCases) { size in
                    Text(L10n.t("prefs.fontSize.\(size.rawValue)")).tag(size)
                }
            }
            Section {
                Toggle(L10n.t("prefs.latest"), isOn: latestIsOn)
                if prefs.latestDate != nil {
                    DatePicker(L10n.t("prefs.latest.date"), selection: latestDay, displayedComponents: .date)
                }
            } footer: {
                Text(L10n.t("prefs.latest.footer"))
                    .shellFont(.meta)
            }
            BuildStampSection(stamp: stamp)
        }
        .formStyle(.grouped)
        // **The pane the type size is chosen on has to move with it** (#96). A `Form`'s rows
        // take the platform's own font unless they are told otherwise, and on a Mac that font
        // does not follow the preference — so the one screen where a reader can see what they
        // just chose was the one screen that would not have shown it. Set on the `Form` rather
        // than on each row: a label, a picker's rows and a toggle all inherit it, and a control
        // added later inherits it too rather than being forgotten.
        .shellFont(.body)
        // The page's own colour, as on the timeline and Account, and no scroll bar.
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .clearsFloatingCorner()
        .padding(ShellSpace.snug)
    }

    /// Off is no latest date. Turning it on starts at today, the date that hides nothing yet.
    private var latestIsOn: Binding<Bool> {
        Binding(
            get: { prefs.latestDate != nil },
            set: { on in prefs.latestDate = on ? LatestDate(Date()) : nil }
        )
    }

    /// The picker's date is the chosen day's start here; what it answers is read back as a day.
    private var latestDay: Binding<Date> {
        Binding(
            get: { prefs.latestDate?.start() ?? Date() },
            set: { prefs.latestDate = LatestDate($0) }
        )
    }
}
