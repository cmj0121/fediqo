import FediqoCore
import SwiftUI

// Whose notices a source holds back is the person's to choose (#376): one line a source on the
// notices page, opened to the choices the source has — let in, hold back, or let go — each a
// press that shows at once and is the source's own choice once it answers.

/// What the line of one source's choices says, as values a test reads without drawing it.
enum NoticePolicyWords {
    /// "What a.example holds back": the line's own words, and its press's.
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

    /// What the opened line says in place of the choices, where there are none to offer: the
    /// source holds nothing back, or the sign-in may not choose — and then what more is asked.
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

    static func absent(_ host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("notices.policy.absent", language: language), host)
    }

    static func locked(_ host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("notices.policy.locked", language: language), host)
    }
}

/// One source's line of whose notices it holds back: a press that opens it, and under it the
/// choices — or, where there are none to make here, why.
struct NoticePolicyLine: View {
    let host: String
    let session: ShellSession

    @Environment(\.colorScheme) private var colorScheme

    private var acts: ShellNoticeActs { session.noticeList.acts }

    var body: some View {
        let stands = NoticePolicyWords.stands(host, in: session)
        if stands != .unknown {
            let open = acts.policyOpen.contains(host)
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                Button { acts.togglePolicy(host: host) } label: {
                    HStack(spacing: ShellSpace.snug) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .accessibilityHidden(true)
                        Text(NoticePolicyWords.title(host))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .accessibilityHidden(true)
                    }
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(L10n.t(open ? "notices.policy.opened" : "notices.policy.closed")))
                if open { choices(stands) }
            }
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
        }
    }

    @ViewBuilder
    private func choices(_ stands: NoticePolicyWords.Stands) -> some View {
        switch stands {
        case .offered(let policy):
            ForEach(policy.offered, id: \.self) { whose in
                if let way = policy.ways[whose] { choice(whose, way) }
            }
        case .absent:
            sentence(NoticePolicyWords.absent(host))
        case .locked:
            sentence(NoticePolicyWords.locked(host))
            ShellLinkButton(L10n.t("account.source.permission.word"), symbol: SourceRow.permissionSymbol) {
                _ = session.askFor([.acting, .notices], host: host)
            }
            .fixedSize()
        case .unknown:
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
                set: { chosen in choose(chosen, for: whose) }
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

    /// A choice made: let in and hold back at once; let go asks first, in one line, since the source
    /// then throws those notices away — the page's one asker puts it, and only its yes sends.
    private func choose(_ way: NoticePolicy.Way, for whose: NoticePolicy.Whose) {
        let acts = acts, session = session, host = host
        guard way == .drop else {
            Task { await acts.choose(way, for: whose, at: host, in: session) }
            return
        }
        acts.asked = ShellMoreAsk(question: NoticePolicyWords.letGoQuestion(whose, at: host)) {
            Task { await acts.choose(.drop, for: whose, at: host, in: session) }
        }
    }

    private func sentence(_ words: String) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
