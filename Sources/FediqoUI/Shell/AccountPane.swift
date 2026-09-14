import FediqoCore
import SwiftUI

/// Catalog plus a search field. Join is tapping a row; the field only filters.
struct AccountPane: View {
    @Bindable var session: ShellSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    private enum Metrics {
        static let pad: CGFloat = 16
        static let stack: CGFloat = 16
        static let gap: CGFloat = 8
        static let row: CGFloat = 10
        static let widgetRadius: CGFloat = 8
        static let fieldRadius: CGFloat = 6
        static let fieldPad: CGFloat = 10
        static let icon: CGFloat = 18
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.stack) {
            if !session.sources.isEmpty {
                SourceMarkRow(sources: session.sources.map(Self.mark))
            }
            Text(L10n.t("account.add.title"))
                .font(.headline)
            Text(L10n.t("account.add.detail"))
                .font(.body)
                .foregroundStyle(.secondary)
            widget
        }
        .padding(Metrics.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await session.loadCatalog() }
    }

    private var widget: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(Metrics.fieldPad)
            if statusVisible {
                status
                    .padding(.horizontal, Metrics.fieldPad)
                    .padding(.bottom, Metrics.gap)
            }
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: 1)
            catalogRegion
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ShellChrome.well(colorScheme), in: RoundedRectangle(cornerRadius: Metrics.widgetRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.widgetRadius, style: .continuous)
                .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.widgetRadius, style: .continuous))
    }

    private var searchField: some View {
        HStack(alignment: .center, spacing: Metrics.gap) {
            TextField(L10n.t("account.search.placeholder"), text: $session.hostname)
                .font(.body)
                .textFieldStyle(.plain)
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
                    .font(.body.weight(.semibold))
                    .frame(width: Metrics.icon, height: Metrics.icon)
                    .foregroundStyle(ShellChrome.phosphor(colorScheme))
            }
            .buttonStyle(.plain)
            .disabled(session.checking)
            .accessibilityLabel(L10n.t("account.search"))
            .help(L10n.t("account.search"))
        }
        .padding(.horizontal, Metrics.fieldPad)
        .padding(.vertical, 8)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: 1)
        }
    }

    private var statusVisible: Bool {
        session.checking || session.refuse != nil
    }

    @ViewBuilder
    private var status: some View {
        if session.checking {
            HStack(spacing: Metrics.gap) {
                ProgressView()
                Text(String(format: L10n.t("account.detect.progress"), session.progressHost))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let refuse = session.refuse {
            Text(refuse)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var catalogRegion: some View {
        switch session.catalog {
        case .loading:
            HStack(spacing: Metrics.gap) {
                ProgressView()
                Text(L10n.t("account.catalog.loading"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(Metrics.fieldPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed:
            Text(L10n.t("account.catalog.failed"))
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(Metrics.fieldPad)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .empty:
            Text(L10n.t("account.catalog.empty"))
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(Metrics.fieldPad)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .ready:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let host = session.extraJoinHost {
                        extraJoinRow(host)
                        Rectangle()
                            .fill(ShellChrome.hairline(colorScheme))
                            .frame(height: 1)
                    }
                    ForEach(session.visibleServers) { server in
                        catalogRow(server)
                        Rectangle()
                            .fill(ShellChrome.hairline(colorScheme))
                            .frame(height: 1)
                    }
                }
                .padding(.horizontal, Metrics.fieldPad)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func extraJoinRow(_ host: String) -> some View {
        let added = session.isAdded(host)
        return Button {
            session.hostname = host
            Task { await session.add() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L10n.t("account.catalog.addHost"), host))
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(added ? L10n.t("account.catalog.added") : L10n.t("account.catalog.addHost.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Metrics.row)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(server.domain)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(added ? L10n.t("account.catalog.added") : server.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !added {
                    Text(metaLine(server))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Metrics.row)
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
