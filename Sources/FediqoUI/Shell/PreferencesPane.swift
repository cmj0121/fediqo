import SwiftUI

/// Language, theme, and type — what a person chooses. What this device holds is on `UsagePane`
/// (#21).
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
        }
        .formStyle(.grouped)
        .padding(ShellSpace.snug)
    }
}
