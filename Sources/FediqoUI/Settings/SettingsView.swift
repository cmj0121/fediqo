import AuthenticationServices
import SwiftUI
import FediqoCore

/// The general preferences: how it looks, what language it speaks, and what it reads.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.webAuthenticationSession) private var webSession
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
        .task { await app.signIn?.refresh() }
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
                    if let signIn = app.signIn, signIn.canSignIn(to: server) {
                        accountControls(signIn, for: server)
                    }
                    Button(t("timeline.remove"), role: .destructive) { app.remove(server) }
                        .buttonStyle(.plain)
                        .fediqoFont(11)
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 3)
            }

            if let failure = app.signIn?.failure {
                Label(message(for: failure), systemImage: "exclamationmark.triangle")
                    .fediqoFont(11)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The signed-in state of one row: the handle and Sign out, or Sign in alone. The
    /// browser session is handed to the model here because only a view can read it.
    @ViewBuilder
    private func accountControls(_ signIn: SignInModel, for server: Server) -> some View {
        if let account = signIn.account(on: server) {
            Text(account.handle).fediqoFont(11).foregroundStyle(.secondary).lineLimit(1)
            Button(t("settings.signOut")) { Task { await signIn.signOut(of: server) } }
                .buttonStyle(.plain)
                .fediqoFont(11)
                .foregroundStyle(.secondary)
        } else {
            Button(t("settings.signIn")) {
                let session = webSession
                Task {
                    await signIn.signIn(to: server) { consent, scheme in
                        try await session.authenticate(using: consent, callbackURLScheme: scheme,
                                                       preferredBrowserSession: .shared)
                    }
                }
            }
            .buttonStyle(.plain)
            .fediqoFont(11)
            .foregroundStyle(.tint)
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
