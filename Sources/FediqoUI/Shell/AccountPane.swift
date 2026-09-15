import FediqoCore
import SwiftUI

/// The sources this device reads. Empty, it is the first thing anyone sees, so it says
/// what the app is for before it asks for anything. Joined, it gets out of the way.
struct AccountPane: View {
    @Bindable var session: ShellSession
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    private enum Metrics {
        /// The mark, at the size the mark is drawn rather than the size of an icon.
        static let mark: CGFloat = 72
        /// A field the width of a hostname. A pane is wider than anything typed into it.
        static let field: CGFloat = 520
        /// The promise is a sentence, not a row: it wraps where a sentence should.
        static let saying: CGFloat = 560
        static let fieldRadius: CGFloat = 6
        static let icon: CGFloat = 18
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.room) {
            masthead
            adding
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)
            catalogRegion
        }
        .padding(ShellSpace.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: searchFocused) { _, on in
            session.searchFocused = on
        }
        .onDisappear { session.searchFocused = false }
        .task { await session.loadCatalog() }
    }

    @ViewBuilder
    private var masthead: some View {
        if session.sources.isEmpty { hero } else { standing }
    }

    /// Nothing has been joined yet. The octopus, the promise, and what it costs — and
    /// then the one control that does anything about it.
    private var hero: some View {
        HStack(alignment: .top, spacing: ShellSpace.pad) {
            Image("Mascot", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: Metrics.mark, height: Metrics.mark)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                Text(L10n.t("account.hero.promise"))
                    .font(ShellType.display)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t("account.hero.detail"))
                    .font(ShellType.body)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Metrics.saying, alignment: .leading)
        }
    }

    /// Something is joined. The page says which, and stops selling itself.
    private var standing: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Text(L10n.t("shell.account.title"))
                .font(ShellType.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            SourceMarkRow(sources: session.sources.map(Self.mark))
        }
    }

    private var adding: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            if !session.sources.isEmpty {
                Text(L10n.t("account.add.detail"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            searchField
            if statusVisible { status }
        }
    }

    private var searchField: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            TextField(L10n.t("account.search.placeholder"), text: $session.hostname)
                .font(ShellType.body)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .disabled(session.checking)
                .onSubmit { session.search() }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .accessibilityLabel(L10n.t("account.search.placeholder"))
            Button {
                session.search()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(ShellType.body.weight(.semibold))
                    .frame(width: Metrics.icon, height: Metrics.icon)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
            }
            .buttonStyle(.plain)
            .disabled(session.checking)
            .accessibilityLabel(L10n.t("account.search"))
            .help(L10n.t("account.search"))
        }
        .padding(.horizontal, ShellSpace.step)
        .padding(.vertical, ShellSpace.snug)
        .frame(maxWidth: Metrics.field, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: ShellSpace.hair)
        }
    }

    private var statusVisible: Bool {
        session.checking || session.refuse != nil
    }

    @ViewBuilder
    private var status: some View {
        if session.checking {
            HStack(spacing: ShellSpace.snug) {
                ProgressView()
                Text(String(format: L10n.t("account.detect.progress"), session.progressHost))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        } else if let refuse = session.refuse {
            Text(refuse)
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.alarm(colorScheme))
        }
    }

    @ViewBuilder
    private var catalogRegion: some View {
        switch session.catalog {
        case .loading:
            note {
                HStack(spacing: ShellSpace.snug) {
                    ProgressView()
                    Text(L10n.t("account.catalog.loading"))
                        .font(ShellType.body)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
            }
        case .failed:
            note {
                Text(L10n.t("account.catalog.failed"))
                    .font(ShellType.body)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        case .empty:
            note {
                Text(L10n.t("account.catalog.empty"))
                    .font(ShellType.body)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        case .ready:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let host = session.extraJoinHost {
                        extraJoinRow(host)
                        Rectangle()
                            .fill(ShellChrome.hairline(colorScheme))
                            .frame(height: ShellSpace.hair)
                    }
                    ForEach(session.visibleServers) { server in
                        catalogRow(server)
                        Rectangle()
                            .fill(ShellChrome.hairline(colorScheme))
                            .frame(height: ShellSpace.hair)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func extraJoinRow(_ host: String) -> some View {
        let added = session.isAdded(host)
        return Button {
            session.hostname = host
            Task { await session.add() }
        } label: {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(String(format: L10n.t("account.catalog.addHost"), host))
                    .font(ShellType.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Text(added ? L10n.t("account.catalog.added") : L10n.t("account.catalog.addHost.detail"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, ShellSpace.step)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.checking || added)
        .accessibilityLabel(String(format: L10n.t("account.catalog.addHost"), host))
    }

    private func catalogRow(_ server: CatalogServer) -> some View {
        let added = session.isAdded(server.domain)
        let disabled = session.checking || added
        return Button {
            Task { await session.pick(server) }
        } label: {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(server.domain)
                    .font(ShellType.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Text(added ? L10n.t("account.catalog.added") : server.summary)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
                if !added {
                    Text(metaLine(server))
                        .font(ShellType.mark)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, ShellSpace.step)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(server.domain)
        .accessibilityValue(added ? L10n.t("account.catalog.added") : "\(server.summary), \(metaLine(server))")
    }

    private func metaLine(_ server: CatalogServer) -> String {
        String(
            format: L10n.t("account.catalog.meta"),
            languageName(server.language),
            Self.compact(server.weekUsers),
            Self.compact(server.users)
        )
    }

    private func languageName(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.t("account.catalog.langUnknown") }
        return locale.localizedString(forLanguageCode: trimmed) ?? trimmed
    }

    private static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private static func mark(_ source: Source) -> DummySource {
        .unsigned(source.host)
    }
}
