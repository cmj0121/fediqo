import FediqoCore
import SwiftUI

/// Language, theme, type, and the latest date every timeline stops at (#22) — what a person
/// chooses. What this device holds is on `UsagePane` (#21).
struct PreferencesPane: View {
    @Environment(DummyPrefs.self) private var prefs

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
            }
        }
        .formStyle(.grouped)
        // The page's own colour, as on the timeline and Account, and no scroll bar.
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
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
