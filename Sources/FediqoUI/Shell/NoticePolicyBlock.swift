import FediqoCore
import SwiftUI

// Whose notices a source holds back is the person's to choose (#376), on that source's own page
// of settings (#398) and never on Notifications: the choices the source has — let in, hold back,
// or let go — each a press that shows at once and is the source's own choice once it answers.

/// What the block of one source's choices says, as values a test reads without drawing it.
enum NoticePolicyWords {
    /// "What a.example holds back": the block's heading.
    static func title(_ host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("notices.policy.title", language: language), host)
    }

    /// Who a choice is about, in the person's own words.
    static func whose(_ whose: NoticePolicy.Whose, language: DummyLanguage? = nil) -> String {
        L10n.t("notices.policy." + key(whose), language: language)
    }

    /// What becomes of their notices.
    static func way(_ way: NoticePolicy.Way, language: DummyLanguage? = nil) -> String {
        switch way {
        case .accept: L10n.t("notices.policy.accept", language: language)
        case .filter: L10n.t("notices.policy.filter", language: language)
        case .drop: L10n.t("notices.policy.drop", language: language)
        }
    }

    /// What a listener is read of one choice: who, and what becomes of them now.
    static func spoken(_ whose: NoticePolicy.Whose, _ way: NoticePolicy.Way, language: DummyLanguage? = nil) -> String {
        ShellMark.said(Self.whose(whose, language: language), Self.way(way, language: language), language: language)
    }

    private static func key(_ whose: NoticePolicy.Whose) -> String {
        switch whose {
        case .notFollowing: "notFollowing"
        case .notFollowers: "notFollowers"
        case .newAccounts: "newAccounts"
        case .privateMentions: "privateMentions"
        case .limitedAccounts: "limitedAccounts"
        }
    }

    /// What the block draws: the choices, or where the sign-in may not choose, what more is
    /// asked — and nothing at all for a source that has no such thing, or was not asked yet.
    enum Stands: Equatable {
        /// The choices, as the source last said them with what is on its way drawn over them.
        case offered(NoticePolicy)
        /// The source has no such thing, or names no choice this build knows.
        case absent
        /// The sign-in may read notices and not change them: choosing asks for more.
        case locked
        /// Not asked yet: nothing is drawn.
        case unknown
    }

    @MainActor
    static func stands(_ host: String, in session: ShellSession) -> Stands {
        let acts = session.noticeList.acts
        guard let holding = acts.holdings[host.lowercased()] else { return .unknown }
        guard holding != .absent, let policy = acts.shownPolicy(host: host) else {
            return holding == .unasked ? .unknown : .absent
        }
        return acts.mayChoose(host: host, in: session) ? .offered(policy) : .locked
    }

    /// The question letting go of a kind's notices asks first: the source throws them away, and
    /// they are neither shown nor kept.
    @MainActor
    static func letGoQuestion(_ whose: NoticePolicy.Whose, at host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellQuestion.letGo(
            Self.whose(whose, language: language), at: host, yes: way(.drop, language: language), language: language
        )
    }

    static func locked(_ host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("notices.policy.locked", language: language), host)
    }
}

/// **On a joined source's page: whose notices it holds back** (#398) — people not followed, new
/// accounts and the rest, each let in, held back or let go. Beside what the source tells while
/// Fediqo runs (`NoticesToldControl`) and its filters (`ServerFiltersBlock`), and in their shape:
/// a heading, then the choices. **Nothing for a source that has none** — absent, not dim. A
/// sign-in that may not change them offers, in their place, the ask for what is missing.
/// Letting go asks first, here: the source then throws those notices away. A sign-in that cannot
/// read notices at all is not asked here: the block beside it (`NoticesToldControl`) already
/// offers the ask for notices, and once they are read this block has its choices or its ask.
struct NoticePolicyBlock: View {
    let host: String
    let session: ShellSession

    @Environment(\.colorScheme) private var colorScheme
    @State private var asked: ShellMoreAsk?

    private var acts: ShellNoticeActs { session.noticeList.acts }

    /// Whether the block is drawn: only where there are choices, or an ask for them.
    static func shows(_ stands: NoticePolicyWords.Stands) -> Bool {
        switch stands {
        case .offered, .locked: true
        case .absent, .unknown: false
        }
    }

    var body: some View {
        let stands = NoticePolicyWords.stands(host, in: session)
        VStack(alignment: .leading, spacing: 0) {
            if Self.shows(stands) {
                ShellRule()
                VStack(alignment: .leading, spacing: ShellSpace.step) {
                    ShellSectionHead(NoticePolicyWords.title(host))
                    choices(stands)
                    if let said = acts.said[host.lowercased()], said.act == .policy {
                        sentence(NoticeActs.words(said, host: host))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ShellSpace.pad)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ShellMoreAsks(asked: $asked))
    }

    @ViewBuilder
    private func choices(_ stands: NoticePolicyWords.Stands) -> some View {
        switch stands {
        case .offered(let policy):
            ForEach(policy.offered, id: \.self) { whose in
                if let way = policy.ways[whose] { choice(whose, way) }
            }
        case .locked:
            sentence(NoticePolicyWords.locked(host))
            ShellLinkButton(L10n.t("account.source.permission.word"), symbol: SourceRow.permissionSymbol) {
                _ = session.askFor([.acting, .notices], host: host)
            }
            .fixedSize()
        case .absent, .unknown:
            EmptyView()
        }
    }

    /// One choice: who, and a press that offers the three ways, the one it stands at ticked.
    private func choice(_ whose: NoticePolicy.Whose, _ way: NoticePolicy.Way) -> some View {
        let label = NoticePolicyWords.whose(whose)
        return HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Text(label)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Picker(label, selection: Binding(
                get: { way },
                set: { chosen in Self.choose(chosen, for: whose, at: host, in: session) { asked = $0 } }
            )) {
                ForEach(NoticePolicy.Way.allCases, id: \.self) { way in
                    Text(NoticePolicyWords.way(way)).tag(way)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(label)
            .accessibilityValue(NoticePolicyWords.way(way))
        }
    }

    /// A choice made: let in and hold back at once; let go asks first, in one line, since the
    /// source then throws those notices away — `ask` puts the question, and only its yes sends.
    static func choose(
        _ way: NoticePolicy.Way, for whose: NoticePolicy.Whose, at host: String, in session: ShellSession,
        ask: (ShellMoreAsk) -> Void
    ) {
        let acts = session.noticeList.acts
        guard way == .drop else {
            Task { await acts.choose(way, for: whose, at: host, in: session) }
            return
        }
        ask(ShellMoreAsk(question: NoticePolicyWords.letGoQuestion(whose, at: host)) {
            Task { await acts.choose(.drop, for: whose, at: host, in: session) }
        })
    }

    private func sentence(_ words: String) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
