import FediqoCore
import SwiftUI

/// The sheet that changes one's own post, presented from the root (#332).
struct ChangePresenter: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { session.changes.shown }, set: { if $0 == nil { session.changes.close() } })) { _ in
            ChangeSheet()
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
    }
}

/// The sheet itself: the composer's own controls over the change's draft (X0 §1).
struct ChangeSheet: View {
    @Environment(ShellSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var changes = session.changes
        let host = changes.host
        WritingSheet(
            titleKey: changes.waiting == nil ? "change.title" : "change.title.waiting",
            sendKey: "change.save",
            bodyKey: "compose.body",
            draft: $changes.draft.text,
            limit: session.postLimit(of: host),
            canSend: changes.canSave(in: session),
            height: 680,
            hidesScrollIndicators: true,
            speaksLimitLine: true,
            writes: { _ in changes.phase == .ready },
            send: { changes.save(in: session) },
            failedAt: { nil },
            cancel: { changes.cancel() }
        ) { _ in
            above(changes, host: host)
        }
        // A swipe down does not take a change typed and not saved: Cancel asks first (X0 §1).
        .interactiveDismissDisabled(Self.holdsOnSwipe(changes))
        .fileImporter(
            isPresented: $changes.importing,
            allowedContentTypes: [.image, .movie, .audio, .gif],
            allowsMultipleSelection: true,
            onCompletion: { changes.read($0, in: session) }
        )
        .shellConfirm($changes.askingVotes, question: { ChangeWords.question($0, host: host) }) { _, _ in
            changes.commit(in: session)
        }
        .shellConfirm($changes.askingDiscard, question: { ShellQuestion.discardChange(host: $0) }) { _, _ in
            changes.close()
        }
    }

    /// The head of a waiting post's change (#333): where it waits, who may read it — which may
    /// change, as a new post's may — and that what it answers stays.
    @ViewBuilder
    private func waitingHead(_ changes: ShellChange, host: String) -> some View {
        Text(String(format: L10n.t("change.waiting.where"), host))
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
        Picker(L10n.t("compose.visibility"), selection: Bindable(changes).draft.audience) {
            ForEach(Audience.allCases, id: \.self) { audience in
                AudienceOption(audience).tag(audience)
            }
        }
        .pickerStyle(.menu)
        .shellFont(.meta)
        .accessibilityLabel(L10n.t("compose.visibility"))
        // Who may quote it changes with the rest (Decision 8 §7.1): the composer's own control.
        if session.quotesOffered(host: host) == true {
            QuotePolicyMenu(draft: Bindable(changes).draft, host: host)
        }
        if changes.waiting?.post.answering != nil {
            Text(L10n.t("change.waiting.answers"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        // A waiting quote: what it quotes stays, as a published quote's does (X0 §3).
        if let line = ChangeWords.waitingQuoteLine(changes.waiting?.post) {
            Text(line)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whether the sheet stays when swiped down: while something typed has not been saved.
    static func holdsOnSwipe(_ changes: ShellChange) -> Bool { changes.touched }

    @ViewBuilder
    private func above(_ changes: ShellChange, host: String) -> some View {
        switch changes.phase {
        case .asking:
            HStack(spacing: ShellSpace.snug) {
                ProgressView().controlSize(.small)
                Text(String(format: L10n.t("change.asking"), host))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            .accessibilityElement(children: .combine)
        case .failed:
            Text(String(format: L10n.t("change.readFailed"), host))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ShellLinkButton(L10n.t("person.retry")) { changes.retry(in: session) }
        case .ready where changes.waiting != nil:
            waitingHead(changes, host: host)
            ComposeExtras(draft: Bindable(changes).draft, controls: changes.controls(in: session)) { EmptyView() }
        case .ready:
            let whereLine = ChangeWords.whereLine(host: host, audience: changes.open?.audience, answering: changes.open?.answering)
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                Text(whereLine)
                Text(ChangeWords.fixedLine())
            }
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            // The fixed line is one element (X0 §5).
            .accessibilityElement(children: .combine)
            // The post it quotes, fixed: a change cannot move what it quotes (X0 §1).
            if let quote = changes.open?.copy.quote {
                if quote.post != nil {
                    QuoteBand(quote: quote, host: host)
                } else {
                    Text(QuoteBand.sentence(quote))
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
            }
            ComposeExtras(draft: Bindable(changes).draft, controls: changes.controls(in: session)) {
                if changes.resets, let source = changes.source {
                    ResetLine(text: ChangeWords.resetLine(source))
                }
            }
        }
    }
}

/// The line under a poll the change would start again: full ink, the one loss on this sheet,
/// and read out once as it appears (X0 §5).
private struct ResetLine: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label(text, systemImage: "arrow.counterclockwise")
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}
