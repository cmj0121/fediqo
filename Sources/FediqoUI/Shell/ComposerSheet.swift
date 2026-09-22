import FediqoCore
import SwiftUI

/// Compose over the current page. The same shape a reply will use: a sheet, not a destination.
struct ComposerSheet: View {
    @Environment(ShellSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    /// What the sheet draws: empty is only when there is nothing to write to **and** nothing
    /// unsent and no failure in hand. A 403 or 401 that spends the last writable source must
    /// not swallow the draft into that notice.
    enum Surface: Equatable {
        case empty
        case composing
    }

    static func surface(offered: [Source], draft: String, failed: String?) -> Surface {
        if !offered.isEmpty { return .composing }
        if failed != nil { return .composing }
        if !trimmed(draft).isEmpty { return .composing }
        return .empty
    }

    /// Cancel is refused while a send is on the wire, so a late success cannot land on a
    /// sheet the reader already left.
    static func canDismiss(sending: Bool) -> Bool { !sending }

    /// A landing clears the draft only where it is still the snapshot that was sent.
    static func draftAfterLanding(current: String, sent: String) -> String {
        trimmed(current) == sent ? "" : current
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
        let offered = session.writableSources
        let host = session.composeHost
        let limit = host.map(session.postLimit(of:)) ?? MastodonWrite.defaultLimit
        WritingSheet(
            titleKey: "compose.title",
            sendKey: "compose.post",
            bodyKey: "compose.body",
            draft: $session.composeDraft,
            limit: limit,
            canSend: session.canPost,
            height: 400,
            hidesScrollIndicators: true,
            speaksLimitLine: true,
            writes: { failed in
                Self.surface(offered: offered, draft: session.composeDraft, failed: failed) == .composing
            },
            send: {
                try await session.post()
                return session.composeDraft.isEmpty
            },
            failedAt: { session.composeHost }
        ) { sending, failed in
            if Self.surface(offered: offered, draft: session.composeDraft, failed: failed) == .empty {
                ShellNotice(
                    symbol: "square.and.pencil",
                    title: L10n.t("compose.none.title"),
                    detail: L10n.t("compose.none.detail")
                )
            } else if offered.isEmpty, failed == nil {
                Text(L10n.t("compose.none.detail"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !offered.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
                    Picker(L10n.t("compose.source"), selection: $session.composeHost) {
                        ForEach(offered, id: \.host) { source in
                            Text(source.host).tag(Optional(source.host))
                        }
                    }
                    .shellFont(.meta)
                    .accessibilityLabel(L10n.t("compose.source"))
                    Picker(L10n.t("compose.visibility"), selection: $session.composeAudience) {
                        ForEach(Audience.allCases, id: \.self) { audience in
                            Text(L10n.t(Self.visibilityKey(audience))).tag(audience)
                        }
                    }
                    .shellFont(.meta)
                    .accessibilityLabel(L10n.t("compose.visibility"))
                }
                .pickerStyle(.menu)
                .disabled(sending)
            }
        }
        .onAppear { session.prepareCompose() }
        .task(id: session.composeHost) { await session.refreshPostLimit() }
    }
}

/// What the composer and an answer share (#108): the limit line, the editor, the wait while a
/// send is on the wire, the failure that keeps every character and tries again, and the toolbar
/// whose Cancel is refused while a send is out — **one state machine for the two**, where the
/// answer used to re-implement the composer's and had begun to drift from it.
///
/// **The two drifts are parameters rather than fixed**, so each sheet keeps exactly what it drew:
/// the composer's editor draws no scroll indicators and its limit line is spoken as its own
/// label; the answer's does neither. What sits above the limit line is each sheet's own, and so
/// is whether the editor is drawn at all — the composer with nothing to write to and nothing in
/// hand draws only its notice.
struct WritingSheet<Above: View>: View {
    let titleKey: String
    let sendKey: String
    /// The editor's name to VoiceOver.
    let bodyKey: String
    let draft: Binding<String>
    let limit: Int
    let canSend: Bool
    let height: CGFloat
    let hidesScrollIndicators: Bool
    let speaksLimitLine: Bool
    /// Whether the editor is drawn, given the source a failed send is holding, if any.
    let writes: (String?) -> Bool
    /// The send: throws where it failed, and says whether the sheet may close — only where the
    /// draft it sent is gone (`ComposerSheet.draftAfterLanding`).
    let send: @MainActor () async throws -> Bool
    /// The source a failed send is said against, asked when it fails.
    let failedAt: @MainActor () -> String?
    let above: (_ sending: Bool, _ failed: String?) -> Above

    init(
        titleKey: String, sendKey: String, bodyKey: String, draft: Binding<String>, limit: Int,
        canSend: Bool, height: CGFloat, hidesScrollIndicators: Bool, speaksLimitLine: Bool,
        writes: @escaping (String?) -> Bool = { _ in true },
        send: @escaping @MainActor () async throws -> Bool,
        failedAt: @escaping @MainActor () -> String?,
        @ViewBuilder above: @escaping (_ sending: Bool, _ failed: String?) -> Above
    ) {
        self.titleKey = titleKey
        self.sendKey = sendKey
        self.bodyKey = bodyKey
        self.draft = draft
        self.limit = limit
        self.canSend = canSend
        self.height = height
        self.hidesScrollIndicators = hidesScrollIndicators
        self.speaksLimitLine = speaksLimitLine
        self.writes = writes
        self.send = send
        self.failedAt = failedAt
        self.above = above
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var sending = false
    @State private var failed: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ShellSpace.step) {
                above(sending, failed)
                if writes(failed) {
                    let remaining = ComposerSheet.remaining(draft.wrappedValue, limit: limit)
                    let line = ComposerSheet.limitLine(remaining: remaining, limit: limit)
                    Text(line)
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .modifier(SpokenAs(line: speaksLimitLine ? line : nil))
                    TextEditor(text: draft)
                        .shellFont(.body)
                        .scrollContentBackground(.hidden)
                        .modifier(HiddenIndicators(hidden: hidesScrollIndicators))
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .disabled(sending)
                        .accessibilityLabel(L10n.t(bodyKey))
                    if sending {
                        ShellWaiting()
                            .frame(height: ShellSpace.pad)
                            .frame(maxWidth: .infinity)
                    }
                    if let failed {
                        ShellFailure(source: failed) {
                            Task { await run() }
                        }
                        .frame(minHeight: 72)
                    }
                }
            }
            .padding(ShellSpace.step)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ShellChrome.page(colorScheme))
            .navigationTitle(L10n.t(titleKey))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("compose.cancel")) {
                        guard ComposerSheet.canDismiss(sending: sending) else { return }
                        dismiss()
                    }
                    .disabled(!ComposerSheet.canDismiss(sending: sending))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t(sendKey)) {
                        Task { await run() }
                    }
                    .disabled(!canSend || sending)
                    .accessibilityLabel(L10n.t(sendKey))
                }
            }
        }
        #if os(macOS)
        .frame(width: 600, height: height)
        #else
        .frame(minWidth: 600, minHeight: height)
        #endif
        .interactiveDismissDisabled(!ComposerSheet.canDismiss(sending: sending))
    }

    private func run() async {
        guard !sending else { return }
        sending = true
        failed = nil
        defer { sending = false }
        do {
            guard try await send() else { return }
            dismiss()
        } catch {
            failed = failedAt()
        }
    }
}

/// The limit line spoken as its own words, where a sheet asks for that.
private struct SpokenAs: ViewModifier {
    let line: String?

    func body(content: Content) -> some View {
        if let line {
            content.accessibilityLabel(Text(line))
        } else {
            content
        }
    }
}

/// The editor's scroll indicators hidden, where a sheet asks for that.
private struct HiddenIndicators: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden {
            content.scrollIndicators(.never)
        } else {
            content
        }
    }
}
