import AuthenticationServices
import SwiftUI
import FediqoCore

/// The general preferences: how it looks, what language it speaks, and what it reads.
///
/// Three tabs. What Fediqo does not do with what it reads is under Sources rather than on a
/// tab of its own — it is about the servers, and the moment a reader thinks of it is the
/// moment they are looking at the list of them.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var confirmingForget = false
    @State private var confirmingReset = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sections(of: app.settingsTab)
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(22)
            }
            .frame(maxWidth: .infinity)
        }
        .task { await app.signIn?.refresh() }
    }

    private var header: some View {
        @Bindable var app = app
        return PageHeader(titleKey: app.railItem.titleKey,
                          subtitleKey: "\(app.settingsTab.rawValue).subtitle") {
            SegmentedChoice(SettingsTab.allCases, keyPrefix: "tab", selection: $app.settingsTab)
        }
    }

    @ViewBuilder
    private func sections(of tab: SettingsTab) -> some View {
        switch tab {
        case .appearance:
            section(t("settings.appearance")) { appearance }
        case .sources:
            section(t("settings.sources")) { sources }
            section(t("settings.privacy")) {
                Text(t("settings.privacy.body"))
                    .fediqoFont(11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .keyboard:
            // The same list `?` puts up, in the one place a reader who has never pressed `?`
            // would go looking. One view, so the two cannot drift apart.
            section(t("shortcut.title")) { ShortcutList() }
        }
    }

    @ViewBuilder
    private var appearance: some View {
        @Bindable var preferences = app.preferences
        choiceRow("settings.theme", keyPrefix: "settings.theme", selection: $preferences.theme)
        Divider().opacity(0.4)
        choiceRow("settings.textSize", keyPrefix: "settings.textSize", selection: $preferences.textScale)
        Divider().opacity(0.4)
        languageRow
        Divider().opacity(0.4)
        choiceRow("settings.refresh", keyPrefix: "settings.refresh", selection: $preferences.refreshInterval)
        Divider().opacity(0.4)
        Text(t("settings.sample"))
            .fediqoFont(13)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Rows

    /// Every appearance choice is the same row: a label, and the control every choice in the
    /// app is made with — here over the whole enum, since a preference has no case the
    /// reader is not offered.
    private func choiceRow<T>(_ titleKey: String, keyPrefix: String, selection: Binding<T>) -> some View
    where T: CaseIterable & Identifiable & Hashable & RawRepresentable, T.RawValue == String {
        LabeledContent {
            SegmentedChoice(Array(T.allCases), keyPrefix: keyPrefix, selection: selection)
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
        sourceList
        // Below the sources and always there, servers or none: it is not about the servers.
        // A reader with nothing added still has preferences, a store, and a Keychain item or
        // two, and "make this like a fresh install" has to mean all of it.
        startAgain
    }

    /// Everything on this device, gone. Two steps to reach it — the button and then a dialog
    /// naming what goes — because it is the one action here that nothing can undo.
    private var startAgain: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hairline().padding(.vertical, 6)
            Button(t("settings.reset"), role: .destructive) { confirmingReset = true }
                .buttonStyle(.plain)
                .fediqoFont(11)
                .foregroundStyle(.red)
                .confirmationDialog(t("settings.reset.ask"), isPresented: $confirmingReset, titleVisibility: .visible) {
                    Button(t("settings.reset.confirm"), role: .destructive) {
                        Task { await app.startAgain() }
                    }
                    Button(t("common.cancel"), role: .cancel) {}
                } message: {
                    Text(t("settings.reset.warning"))
                }
            Text(t("settings.reset.note"))
                .fediqoFont(10)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var sourceList: some View {
        if app.servers.isEmpty {
            Text(t("settings.sources.empty")).fediqoFont(12).foregroundStyle(.secondary)
        } else {
            ForEach(app.servers) { server in
                sourceRow(server)
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

    /// One server: what it is on the left, and on the right everything that can be done to
    /// it, as icons in one group. Sign in and sign out are only there for a protocol this
    /// build can sign in to — and only with a store behind them, since without one there is
    /// no `signIn` at all. Stopping reading is always offered.
    private func sourceRow(_ server: Server) -> some View {
        HStack(spacing: 8) {
            Image(systemName: server.socialProtocol.symbolName).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.title).fediqoFont(13, weight: .medium).lineLimit(1)
                Text(server.host).fediqoFont(10).foregroundStyle(.secondary)
            }
            Spacer()
            // The handle and the controls are one group so the model behind them is unwrapped
            // once; the handle keeps its own gap, since only the buttons sit shoulder to
            // shoulder.
            HStack(spacing: 0) {
                if let signIn = app.signIn, signIn.canSignIn(to: server) {
                    if let account = signIn.account(on: server) {
                        // A handle the server no longer answers to reads as the warning it
                        // is, rather than as a quiet claim to be signed in.
                        Text(account.handle)
                            .fediqoFont(11)
                            .foregroundStyle(signIn.isRejected(server) ? Color.orange : Color.secondary)
                            .lineLimit(1)
                            .padding(.trailing, 8)
                    }
                    accountControl(signIn, for: server)
                }
                IconButton(symbol: "xmark.circle", labelKey: "timeline.remove", tint: .red) { app.remove(server) }
            }
        }
        .padding(.vertical, 3)
    }

    /// The signed-in state of one row, as the icons it is worth: sign out when there is an
    /// account, sign in when there is not — and both when the server has stopped accepting
    /// the account, since those are the only two ways out (nothing retries for you). No
    /// fourth control: it is the same Sign in, wearing what happened.
    @ViewBuilder
    private func accountControl(_ signIn: SignInModel, for server: Server) -> some View {
        if signIn.account(on: server) != nil {
            if signIn.isRejected(server) {
                signInButton(signIn, for: server, symbol: "person.crop.circle.badge.exclamationmark",
                             labelKey: "settings.signInAgain", tint: .orange)
            }
            IconButton(symbol: "rectangle.portrait.and.arrow.right", labelKey: "settings.signOut") {
                Task { await signIn.signOut(of: server) }
            }
        } else {
            // The system accent rather than `Palette.accent`: this glyph is drawn on the card
            // itself, and the house blue is too pale against a light one to read.
            signInButton(signIn, for: server, symbol: "person.crop.circle.badge.plus",
                         labelKey: "settings.signIn", tint: .accentColor)
        }
    }

    /// The one sign-in button, whatever it is called this time. The browser session is handed
    /// to the model here because only a view can read it.
    private func signInButton(_ signIn: SignInModel, for server: Server,
                              symbol: String, labelKey: String, tint: Color) -> some View {
        IconButton(symbol: symbol, labelKey: labelKey, tint: tint) {
            let session = webSession
            Task {
                await signIn.signIn(to: server) { consent, scheme in
                    do {
                        return try await session.authenticate(using: consent, callbackURLScheme: scheme,
                                                              preferredBrowserSession: .shared)
                    } catch let closed as ASWebAuthenticationSessionError where closed.code == .canceledLogin {
                        // Closing the browser is a decision, not a failure — said here so
                        // the model never has to speak AuthenticationServices.
                        throw CancellationError()
                    }
                }
                // A first account is what makes a home timeline readable, so this is where it
                // is offered. Asked after the model has re-read the rows, so a handshake that
                // failed offers nothing.
                await app.offerHomeTimeline()
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
