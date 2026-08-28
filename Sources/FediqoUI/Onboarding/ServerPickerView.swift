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
                        VStack(alignment: .leading, spacing: Space.room) {
                            entryField(typed: $model.typed).id(Self.entryAnchor)
                            if case .found(let info) = model.probe {
                                foundCard(info)
                            }
                            suggestionList
                            sourceNote
                        }
                        .padding(Space.room)
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
        VStack(alignment: .leading, spacing: Space.step) {
            HStack {
                Text(t("onboarding.server.title")).fediqoFont(TypeScale.title, weight: .semibold)
                Spacer()
                Button(t(isSheet ? "common.close" : "onboarding.server.back")) { dismiss() }
                    .buttonStyle(.plain)
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.secondary)
            }
            Text(t("onboarding.server.subtitle"))
                .fediqoFont(TypeScale.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.room)
        .padding(.top, isSheet ? 20 : 40)
        .padding(.bottom, Space.withinGroup)
    }

    private func entryField(typed: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Space.step) {
            Text(t("onboarding.server.field")).fediqoFont(TypeScale.small, weight: .medium).foregroundStyle(.secondary)

            HStack(spacing: Space.step) {
                TextField("mastodon.social", text: typed)
                    .textFieldStyle(.roundedBorder)
                    .fediqoFont(TypeScale.lead)
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
                .fediqoFont(TypeScale.small, weight: .medium)
                .disabled(!model.canSubmit)
                .help(t("onboarding.server.look"))
                .accessibilityLabel(Text(t("onboarding.server.look")))
            }

            switch model.probe {
            case .checking(let host):
                HStack(spacing: Space.snug) {
                    ProgressView().controlSize(.small)
                    Text("\(t("onboarding.server.checking")) \(host)").fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
                }
            case .failed(let failure):
                Label(message(for: failure), systemImage: "exclamationmark.triangle")
                    .fediqoFont(TypeScale.minor)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .found, .idle:
                // The answer is a card of its own, below. What belongs under the field is only
                // what is too small to be one: a spinner, or the reason there is no answer.
                EmptyView()
            }
        }
    }

    /// What the server says it is, before anything has been written down. Everything on this
    /// card came off that server and nowhere else, which is what makes it safe to put in front
    /// of somebody who has decided nothing. Looking is not joining: the field above is still a
    /// field, cancelling leaves the app exactly as it was, and either way the next server can
    /// be looked at without anything having happened to this one.
    private func foundCard(_ info: InstanceInfo) -> some View {
        let already = model.alreadyReading(info, among: app.servers)
        return VStack(alignment: .leading, spacing: Space.gap) {
            HStack(alignment: .top, spacing: Space.gap) {
                if info.thumbnailURL != nil {
                    RemoteImage(url: info.thumbnailURL, width: Size.thumbnail, height: Size.thumbnail)
                }
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(info.title).fediqoFont(TypeScale.section, weight: .semibold)
                    Text(info.host).fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !info.summary.isEmpty {
                Text(info.summary)
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let counted = figures(for: info)
            if !counted.isEmpty {
                Text(counted.joined(separator: " · "))
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.tertiary)
            }

            let marks = badges(for: info)
            if !marks.isEmpty {
                FlowRow(spacing: Space.tight) {
                    ForEach(marks, id: \.self) { mark in
                        Text(mark).fediqoFont(TypeScale.caption).fediqoPill()
                    }
                }
            }

            if !info.rules.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: Space.snug) {
                    Text(t("onboarding.server.rules"))
                        .fediqoFont(TypeScale.minor, weight: .medium)
                        .foregroundStyle(.secondary)
                    ForEach(Array(info.rules.enumerated()), id: \.offset) { index, rule in
                        rulesRow(number: index + 1, rule: rule)
                    }
                }
            }

            HStack(spacing: Space.gap) {
                if already {
                    Text(t("onboarding.server.already")).fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
                } else {
                    Button(t("onboarding.server.add")) { adopt(info) }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .fediqoFont(TypeScale.small, weight: .medium)
                }
                Button(t("common.cancel")) { model.clear() }
                    .buttonStyle(.plain)
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Space.hair)
        }
        .padding(Space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fediqoCard()
    }

    private func rulesRow(number: Int, rule: InstanceRule) -> some View {
        HStack(alignment: .top, spacing: Space.step) {
            Text("\(number)")
                .fediqoFont(TypeScale.caption, weight: .medium)
                .foregroundStyle(.tertiary)
                .frame(minWidth: Glyph.column, alignment: .trailing)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(rule.text).fediqoFont(TypeScale.minor).fixedSize(horizontal: false, vertical: true)
                if let detail = rule.detail {
                    Text(detail)
                        .fediqoFont(TypeScale.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The short facts, each said only where the server said it. What it runs, whether it is
    /// taking anybody new, and the languages it claims -- a reader deciding on a server wants
    /// all three at a glance and none of them invented.
    private func badges(for info: InstanceInfo) -> [String] {
        var marks = info.languages.prefix(6).map(languageName)
        if let version = info.version, !version.isEmpty {
            marks.append(t("onboarding.server.version", version))
        }
        if let open = info.registrationsOpen {
            marks.append(t(open ? "onboarding.server.registrations.open" : "onboarding.server.registrations.closed"))
        }
        return marks
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
        VStack(alignment: .leading, spacing: Space.mid) {
            HStack {
                Text(t("onboarding.server.suggested")).fediqoFont(TypeScale.small, weight: .medium).foregroundStyle(.secondary)
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
            HStack(alignment: .top, spacing: Space.gap) {
                VStack(alignment: .leading, spacing: Space.tight) {
                    HStack(spacing: Space.snug) {
                        Text(suggestion.host).fediqoFont(TypeScale.lead, weight: .medium)
                        if already {
                            Text(t("onboarding.server.already")).fediqoFont(TypeScale.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !suggestion.summary.isEmpty {
                        Text(suggestion.summary)
                            .fediqoFont(TypeScale.minor)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let users = suggestion.totalUsers {
                        Text(t("onboarding.server.users", users.formatted()))
                            .fediqoFont(TypeScale.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: Space.step)
                Image(systemName: already ? "checkmark" : "plus")
                    .foregroundStyle(already ? Color.secondary : Palette.accent)
            }
            .padding(Space.gap)
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
            .fediqoFont(TypeScale.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.tight)
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
