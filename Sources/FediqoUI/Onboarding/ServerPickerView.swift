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
    @State private var model: ServerPickerModel

    init(socialProtocol: SocialProtocol, onDismiss: (() -> Void)? = nil) {
        self.socialProtocol = socialProtocol
        self.onDismiss = onDismiss
        _model = State(initialValue: ServerPickerModel(socialProtocol: socialProtocol))
    }

    private var isSheet: Bool { onDismiss != nil }

    var body: some View {
        @Bindable var model = model
        return ZStack {
            if !isSheet {
                Palette.surface(colorScheme).ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 0) {
                header
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        entryField(typed: $model.typed)
                        suggestionList
                        sourceNote
                    }
                    .padding(20)
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
                    .onSubmit { submit(typed.wrappedValue) }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif

                Button(t("onboarding.server.add")) { submit(typed.wrappedValue) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .fediqoFont(12, weight: .medium)
                    .disabled(!model.canSubmit)
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
            case .idle:
                EmptyView()
            }
        }
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
            submit(suggestion.host)
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

    private func submit(_ host: String) {
        Task {
            guard let server = await model.adopt(host: host) else { return }
            app.add(server)
            model.typed = ""
            dismiss()
        }
    }

    private func dismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            app.route = app.servers.isEmpty ? .protocolPicker : .shell
        }
    }
}
