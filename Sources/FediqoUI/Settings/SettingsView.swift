import SwiftUI
import FediqoCore

/// The general preferences: how it looks, what language it speaks, and what it reads.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var confirmingForget = false

    var body: some View {
        @Bindable var preferences = app.preferences
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(t("settings.title")).fediqoFont(20, weight: .semibold)

                section(t("settings.appearance")) {
                    choiceRow("settings.theme", keyPrefix: "settings.theme", selection: $preferences.theme)
                    Divider().opacity(0.4)
                    choiceRow("settings.textSize", keyPrefix: "settings.textSize", selection: $preferences.textScale)
                    Divider().opacity(0.4)
                    languageRow
                    Divider().opacity(0.4)
                    Text(t("settings.sample"))
                        .fediqoFont(13)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(t("settings.sources")) { sources }

                section(t("settings.privacy")) {
                    Text(t("settings.privacy.body"))
                        .fediqoFont(11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(22)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rows

    /// Every appearance choice is the same row: a label, and one segment per case, named by
    /// a string key derived from the case itself.
    private func choiceRow<T>(_ titleKey: String, keyPrefix: String, selection: Binding<T>) -> some View
    where T: CaseIterable & Identifiable & Hashable & RawRepresentable, T.RawValue == String, T.AllCases: RandomAccessCollection {
        LabeledContent {
            Picker("", selection: selection) {
                ForEach(T.allCases) { option in
                    Text(t("\(keyPrefix).\(option.rawValue)")).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } label: {
            Text(t(titleKey)).fediqoFont(13)
        }
    }

    /// The language row is not one of those: the choices are written in themselves rather
    /// than translated, and there are too few to spend a segmented control on.
    private var languageRow: some View {
        LabeledContent {
            Picker("", selection: Binding(
                get: { app.preferences.language },
                set: { app.apply(language: $0) }
            )) {
                Text(t("settings.language.system")).tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "繁體中文").tag(AppLanguage.traditionalChinese)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        } label: {
            Text(t("settings.language")).fediqoFont(13)
        }
    }

    @ViewBuilder
    private var sources: some View {
        if app.servers.isEmpty {
            Text(t("settings.sources.empty")).fediqoFont(12).foregroundStyle(.secondary)
        } else {
            ForEach(app.servers) { server in
                HStack(spacing: 8) {
                    Image(systemName: server.socialProtocol.symbolName).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.title).fediqoFont(13, weight: .medium).lineLimit(1)
                        Text(server.host).fediqoFont(10).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(t("timeline.remove"), role: .destructive) { app.remove(server) }
                        .buttonStyle(.plain)
                        .fediqoFont(11)
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 3)
            }

            Button(t("settings.sources.forget"), role: .destructive) { confirmingForget = true }
                .buttonStyle(.plain)
                .fediqoFont(11)
                .foregroundStyle(.red)
                .padding(.top, 4)
                .confirmationDialog(t("settings.sources.forget"), isPresented: $confirmingForget) {
                    Button(t("settings.sources.forget"), role: .destructive) { app.forgetAllServers() }
                    Button(t("common.cancel"), role: .cancel) {}
                }
        }
    }

    // MARK: - Chrome

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).fediqoFont(11, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fediqoCard()
        }
    }
}
