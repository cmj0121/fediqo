import FediqoCore
import SwiftUI

/// Compose over the current page. The same shape a reply will use: a sheet, not a destination.
struct ComposerSheet: View {
    @Environment(ShellSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var sending = false
    @State private var failedHost: String?

    /// Sources `SourceWriting.writes` names, in join order.
    static func offered(_ rows: [SourceRow]) -> [Source] {
        rows.filter { $0.writing == .writes }.map(\.source)
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func remaining(_ text: String, limit: Int) -> Int {
        limit - trimmed(text).count
    }

    static func canSend(text: String, limit: Int, hasSource: Bool) -> Bool {
        let body = trimmed(text)
        return hasSource && !body.isEmpty && body.count <= limit
    }

    static func limitLine(remaining: Int, limit: Int) -> String {
        String(format: L10n.t("compose.limit"), remaining, limit)
    }

    static func visibilityKey(_ audience: Audience) -> String {
        switch audience {
        case .everyone: "compose.visibility.public"
        case .unlisted: "compose.visibility.unlisted"
        case .followers: "compose.visibility.private"
        case .mentioned: "compose.visibility.direct"
        }
    }

    var body: some View {
        @Bindable var session = session
        let offered = Self.offered(session.rows)
        let host = session.composeHost
        let limit = host.map(session.postLimit(of:)) ?? MastodonWrite.defaultLimit
        let remaining = Self.remaining(session.composeDraft, limit: limit)
        NavigationStack {
            VStack(alignment: .leading, spacing: ShellSpace.step) {
                if offered.isEmpty {
                    ShellNotice(
                        symbol: "square.and.pencil",
                        title: L10n.t("compose.none.title"),
                        detail: L10n.t("compose.none.detail")
                    )
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
                        Picker(L10n.t("compose.source"), selection: $session.composeHost) {
                            ForEach(offered, id: \.host) { source in
                                Text(source.host).tag(Optional(source.host))
                            }
                        }
                        .accessibilityLabel(L10n.t("compose.source"))
                        Picker(L10n.t("compose.visibility"), selection: $session.composeAudience) {
                            ForEach(Audience.allCases, id: \.self) { audience in
                                Text(L10n.t(Self.visibilityKey(audience))).tag(audience)
                            }
                        }
                        .accessibilityLabel(L10n.t("compose.visibility"))
                    }
                    .pickerStyle(.menu)
                    .disabled(sending)
                    Text(Self.limitLine(remaining: remaining, limit: limit))
                        .font(ShellType.reading)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .accessibilityLabel(
                            Text(Self.limitLine(remaining: remaining, limit: limit))
                        )
                    TextEditor(text: $session.composeDraft)
                        .font(ShellType.body)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .disabled(sending)
                        .accessibilityLabel(L10n.t("compose.body"))
                    if sending {
                        ShellWaiting()
                            .frame(height: ShellSpace.pad)
                            .frame(maxWidth: .infinity)
                    }
                    if let failedHost {
                        ShellFailure(source: failedHost) {
                            Task { await send() }
                        }
                        .frame(minHeight: 72)
                    }
                }
            }
            .padding(ShellSpace.step)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ShellChrome.page(colorScheme))
            .navigationTitle(L10n.t("compose.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("compose.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("compose.post")) {
                        Task { await send() }
                    }
                    .disabled(!session.canPost || sending)
                    .accessibilityLabel(L10n.t("compose.post"))
                }
            }
        }
        #if os(macOS)
        .frame(width: 600, height: 400)
        #else
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .onAppear { session.prepareCompose() }
        .task(id: session.composeHost) { await session.refreshPostLimit() }
    }

    private func send() async {
        guard !sending else { return }
        sending = true
        failedHost = nil
        defer { sending = false }
        do {
            try await session.post()
            guard session.composeDraft.isEmpty else { return }
            dismiss()
        } catch {
            failedHost = session.composeHost
        }
    }
}
