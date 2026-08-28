import SwiftUI
import FediqoCore

/// Choosing a server to read. The same screen serves the fresh install and the "add a
/// source" sheet inside the timeline — a source is a source wherever it is added from.
///
/// Whether it is a sheet is not a separate fact: a sheet is the one that was given something
/// to do when it closes.
struct ServerPickerView: View {
    let socialProtocol: SocialProtocol
    var onDismiss: (() -> Void)?

    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var model: ServerPickerModel

    init(socialProtocol: SocialProtocol, onDismiss: (() -> Void)? = nil) {
        self.socialProtocol = socialProtocol
        self.onDismiss = onDismiss
        _model = State(initialValue: ServerPickerModel(socialProtocol: socialProtocol))
    }

    private var isSheet: Bool { onDismiss != nil }

    private static let entryAnchor = "entry"

    var body: some View {
        @Bindable var model = model
        return ZStack {
            if !isSheet {
                Palette.surface(colorScheme).ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 0) {
                header
                Hairline()
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            entryField(typed: $model.typed).id(Self.entryAnchor)
                            suggestionList
                            sourceNote
                        }
                        .padding(20)
                    }
                    .onChange(of: model.probe) { _, probe in
                        guard case .found = probe else { return }
                        withAnimation { scroll.scrollTo(Self.entryAnchor, anchor: .top) }
                    }
                }
            }
            .frame(maxWidth: isSheet ? .infinity : 640)
        }
        .frame(minWidth: isSheet ? 420 : nil, minHeight: isSheet ? 480 : nil)
        .task { await model.loadSuggestions() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("onboarding.server.title")).fediqoFont(22, weight: .semibold)
                Spacer()
                Button(t(isSheet ? "common.close" : "onboarding.server.back")) { dismiss() }
                    .buttonStyle(.plain)
                    .fediqoFont(12)
                    .foregroundStyle(.secondary)
            }
            Text(t("onboarding.server.subtitle"))
                .fediqoFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, isSheet ? 20 : 40)
        .padding(.bottom, 16)
    }

    private func entryField(typed: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("onboarding.server.field")).fediqoFont(12, weight: .medium).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("mastodon.social", text: typed)
                    .textFieldStyle(.roundedBorder)
                    .fediqoFont(14)
                    .onSubmit { look(typed.wrappedValue) }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif

                Button { look(typed.wrappedValue) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .fediqoFont(12, weight: .medium)
                .disabled(!model.canSubmit)
                .help(t("onboarding.server.look"))
                .accessibilityLabel(Text(t("onboarding.server.look")))
            }

            switch model.probe {
            case .checking(let host):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(t("onboarding.server.checking")) \(host)").fediqoFont(11).foregroundStyle(.secondary)
                }
            case .failed(let failure):
                Label(message(for: failure), systemImage: "exclamationmark.triangle")
                    .fediqoFont(11)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .found(let info):
                foundCard(info)
            case .idle:
                EmptyView()
            }
        }
    }

    /// What the server says it is, before anything has been written down. Everything on this
    /// card came off that server and nowhere else, which is what makes it safe to show to
    /// somebody who has decided nothing: looking is not joining, and cancelling leaves the app
    /// exactly as it was.
    private func foundCard(_ info: InstanceInfo) -> some View {
        let already = model.alreadyReading(info, among: app.servers)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if info.thumbnailURL != nil {
                    RemoteImage(url: info.thumbnailURL, width: 52, height: 52)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title).fediqoFont(15, weight: .semibold)
                    Text(info.host).fediqoFont(11).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !info.summary.isEmpty {
                Text(info.summary)
                    .fediqoFont(11)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let counted = figures(for: info)
            if !counted.isEmpty {
                Text(counted.joined(separator: " · "))
                    .fediqoFont(10)
                    .foregroundStyle(.tertiary)
            }

            if !info.languages.isEmpty {
                HStack(spacing: 4) {
                    ForEach(info.languages.prefix(6), id: \.self) { code in
                        Text(languageName(code)).fediqoFont(10).fediqoPill()
                    }
                }
            }

            HStack(spacing: 12) {
                if already {
                    Text(t("onboarding.server.already")).fediqoFont(11).foregroundStyle(.secondary)
                } else {
                    Button(t("onboarding.server.add")) { adopt(info) }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .fediqoFont(12, weight: .medium)
                }
                Button(t("common.cancel")) { model.clear() }
                    .buttonStyle(.plain)
                    .fediqoFont(12)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fediqoCard()
    }

    /// Only what the server actually counted. The two APIs count different things -- a month of
    /// people who posted, or everybody who ever registered -- and a server that publishes
    /// neither is not given one.
    private func figures(for info: InstanceInfo) -> [String] {
        var counted: [String] = []
        if let active = info.activeMonthlyUsers {
            counted.append(t("onboarding.server.active", active.formatted(.number.locale(locale))))
        }
        if let users = info.totalUsers {
            counted.append(t("onboarding.server.users", users.formatted(.number.locale(locale))))
        }
        if let posts = info.posts {
            counted.append(t("onboarding.server.posts", posts.formatted(.number.locale(locale))))
        }
        return counted
    }

    /// A language as the reader's own language spells it, and as the server spelled it where
    /// nothing can be made of the code.
    private func languageName(_ code: String) -> String {
        locale.localizedString(forIdentifier: code)
            ?? locale.localizedString(forLanguageCode: code)
            ?? code
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("onboarding.server.suggested")).fediqoFont(12, weight: .medium).foregroundStyle(.secondary)
                if model.loadingSuggestions {
                    ProgressView().controlSize(.small)
                }
            }

            ForEach(model.suggestions) { suggestion in
                suggestionRow(suggestion)
            }
        }
    }

    private func suggestionRow(_ suggestion: SuggestedServer) -> some View {
        let already = app.servers.contains { $0.host == suggestion.host }
        return Button {
            look(suggestion.host)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(suggestion.host).fediqoFont(14, weight: .medium)
                        if already {
                            Text(t("onboarding.server.already")).fediqoFont(10).foregroundStyle(.secondary)
                        }
                    }
                    if !suggestion.summary.isEmpty {
                        Text(suggestion.summary)
                            .fediqoFont(11)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let users = suggestion.totalUsers {
                        Text(t("onboarding.server.users", users.formatted()))
                            .fediqoFont(10)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: already ? "checkmark" : "plus")
                    .foregroundStyle(already ? Color.secondary : Palette.accent)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fediqoCard()
        }
        .buttonStyle(.plain)
        .disabled(already)
        .opacity(already ? 0.55 : 1)
    }

    /// The one request that does not go to a server you chose says so, on the screen that
    /// makes it — and says it in whatever terms the directory that answered calls for.
    private var sourceNote: some View {
        Label(t(model.origin.noteKey), systemImage: model.origin.symbolName)
            .fediqoFont(10)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    // MARK: - Actions

    /// Asks, and stops. The field is filled in on the way so that what is on screen and what
    /// was asked about are never two different servers.
    private func look(_ host: String) {
        model.typed = host
        Task { await model.look(host: host) }
    }

    private func adopt(_ info: InstanceInfo) {
        app.add(model.server(from: info))
        model.typed = ""
        model.clear()
        dismiss()
    }

    private func dismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            app.route = app.servers.isEmpty ? .protocolPicker : .shell
        }
    }
}
