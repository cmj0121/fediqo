import FediqoCore
import SwiftUI

/// Catalog plus a hostname field. Join stays on this page.
struct AccountPane: View {
    @Bindable var session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    private enum Metrics {
        static let pad: CGFloat = 16
        static let stack: CGFloat = 16
        static let gap: CGFloat = 8
        static let row: CGFloat = 10
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
            fieldAndAdd
            status
            catalogRegion
        }
        .padding(Metrics.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await session.loadCatalog() }
    }

    private var fieldAndAdd: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Metrics.gap) {
                hostnameField
                addButton
            }
            VStack(alignment: .leading, spacing: Metrics.gap) {
                hostnameField
                addButton
            }
        }
    }

    private var hostnameField: some View {
        TextField(L10n.t("account.add.host"), text: $session.hostname)
            .font(.body)
            .textFieldStyle(.plain)
            .disabled(session.checking)
            .onSubmit { Task { await session.add() } }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(ShellChrome.hairline(colorScheme))
                    .frame(height: 1)
            }
    }

    private var addButton: some View {
        Button {
            Task { await session.add() }
        } label: {
            Text(L10n.t("account.add"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(ShellChrome.selectFill(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .disabled(session.checking || session.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(L10n.t("account.add"))
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed:
            Text(L10n.t("account.catalog.failed"))
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .empty:
            Text(L10n.t("account.catalog.empty"))
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .ready(let servers):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(servers) { server in
                        catalogRow(server)
                        Rectangle()
                            .fill(ShellChrome.hairline(colorScheme))
                            .frame(height: 1)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Metrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(server.domain)
        .accessibilityValue(added ? L10n.t("account.catalog.added") : server.summary)
    }

    private static func mark(_ source: Source) -> DummySource {
        .unsigned(source.host)
    }
}
