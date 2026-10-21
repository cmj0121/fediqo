import FediqoCore
import SwiftUI

/// The quoted post above the composer's editor (X0 §3): where the quote goes through, the post
/// drawn as a quote is, and the press that gives the post back plain.
struct QuoteHead: View {
    @Bindable var session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            if let quoting = session.composeDraft.quoting {
                Text(String(format: L10n.t("compose.quote.through"), quoting.item.host))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = session.note(ofRow: quoting.item.rowID) {
                    QuoteCard(post: QuotedPost(note), host: quoting.item.host, lifted: false, onOpen: nil, onToggleCover: {})
                }
                ShellLinkButton(L10n.t("compose.quote.remove")) { session.composeDraft.quoting = nil }
                    .fixedSize()
            }
        }
    }
}

/// Who may quote the post, picked when writing (X0 §3): the account's own setting where nothing
/// was chosen — and nothing sent — or one of three. Fixed at nobody, and said why, on a post only
/// followers or those it names may read.
struct QuotePolicyMenu: View {
    @Binding var draft: PostDraft
    let host: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fixed = draft.quotePolicySent == .nobody && draft.audience != .everyone && draft.audience != .unlisted
        VStack(alignment: .leading, spacing: ShellSpace.hair) {
            Picker(selection: Binding(get: { fixed ? .nobody : draft.quotePolicy }, set: { draft.quotePolicy = $0 })) {
                Text(QuoteWords.unsaid(host: host)).tag(QuotePolicy?.none)
                ForEach(QuotePolicy.allCases, id: \.self) { policy in
                    Text(QuoteWords.policy(policy)).tag(QuotePolicy?.some(policy))
                }
            } label: {
                Label(L10n.t("compose.quotePolicy"), systemImage: "hand.raised")
            }
            .shellFont(.meta)
            .disabled(fixed)
            .accessibilityLabel(L10n.t("compose.quotePolicy"))
            if fixed {
                Text(L10n.t("compose.quotePolicy.private"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The quotes of one's own post (X0 §3): who quoted it, when, their first line, and each taken
/// back behind a question — a row then reads Taken back.
struct QuotesSheet: View {
    let host: String
    let rows: [Note]
    let reading: ShellQuoting.Reading
    let more: Bool
    let revoking: Set<String>
    let missed: String?
    var onRevoke: (Note) -> Void
    var onReadOn: () -> Void
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.t("quotes.title"))
                        .shellFont(.pane)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: ShellSpace.step)
                    Button(L10n.t("servers.close"), action: onClose).keyboardShortcut(.cancelAction)
                }
                Text(String(format: L10n.t("quotes.whose"), host))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            .padding(ShellSpace.room)
            ShellRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let missed {
                        Label(missed, systemImage: SaidStrip.symbol)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.ink(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(ShellSpace.pad)
                    }
                    if let line = line {
                        Text(line)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .padding(ShellSpace.pad)
                    }
                    ForEach(rows, id: \.key) { quoting in
                        row(quoting)
                        ShellRule()
                    }
                    if reading == .read, more {
                        Button(action: onReadOn) {
                            Text(L10n.t("waiting.more"))
                                .shellFont(.meta)
                                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(ShellSpace.pad)
                    }
                }
            }
        }
        .background(ShellChrome.page(colorScheme))
        .frame(minWidth: 320, idealWidth: 420, minHeight: 320, idealHeight: 480)
    }

    private var line: String? {
        switch reading {
        case .reading where rows.isEmpty: String(format: L10n.t("waiting.asking"), host)
        case .failed: String(format: L10n.t("quotes.failed"), host)
        case .read where rows.isEmpty: String(format: L10n.t("quotes.none"), host)
        default: nil
        }
    }

    private func row(_ quoting: Note) -> some View {
        let revoked = QuoteWords.revoked(quoting)
        return VStack(alignment: .leading, spacing: ShellSpace.hair) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Text(quoting.author).shellFont(.name, weight: .semibold).foregroundStyle(ShellChrome.ink(colorScheme))
                Text(quoting.handle).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme)).lineLimit(1)
                if revoked {
                    Text(L10n.t("quotes.revoked"))
                        .shellFont(.mark)
                        .padding(.horizontal, ShellSpace.tight)
                        .background(ShellChrome.well(colorScheme), in: Capsule())
                }
                Spacer(minLength: ShellSpace.step)
                if !revoked, !revoking.contains(quoting.key.rowID) {
                    ShellMoreButton(ShellMore(head: [QuoteWords.spoken(quoting)], items: [
                        .danger(
                            "hand.raised.slash", L10n.t("quotes.revoke"), asks: QuoteWords.revokeQuestion(quoting)
                        ) { onRevoke(quoting) },
                    ]))
                    .fixedSize()
                }
            }
            Text(quoting.body)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
        }
        .padding(ShellSpace.pad)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(QuoteWords.spoken(quoting))
    }
}

/// Quoting's sheets and questions, put up and taken down — **in a modifier of its own**, never in
/// the root's chain of presenters: the quotes of one's own post, and the question before a quote
/// drops what the draft carries; and the composer opened on a quote. Hands the session what its
/// people pages know of each host, which says whether it has quotes.
struct QuotePresenter: ViewModifier {
    let session: ShellSession
    let hosts: ShellHostsKnown
    @Binding var composing: Bool

    func body(content: Content) -> some View {
        @Bindable var quoting = session.quoting
        content
            .onAppear { quoting.hosts = hosts }
            .onChange(of: quoting.composeRequest) { _, _ in composing = true }
            .sheet(item: Binding(get: { quoting.open }, set: { if $0 == nil { quoting.close() } })) { open in
                QuotesSheet(
                    host: open.host, rows: quoting.rows, reading: quoting.reading, more: quoting.next != nil,
                    revoking: quoting.revoking, missed: quoting.missed,
                    onRevoke: { quoting.withdrawQuote($0, of: open.post, in: session) },
                    onReadOn: { quoting.readOn(in: session) },
                    onClose: { quoting.close() }
                )
                #if os(iOS)
                .presentationDetents([.large])
                #endif
            }
            .shellConfirm($quoting.asking, question: { QuoteWords.dropQuestion($0) }) { ask, _ in
                quoting.dropAndQuote(ask.item, in: session)
            }
    }
}
