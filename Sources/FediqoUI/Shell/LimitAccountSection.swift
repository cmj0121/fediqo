import FediqoCore
import SwiftUI

/// What the limits let go (#251), on the Keep tab under the limits themselves: one row each
/// time a limit acted — which limit, how many posts and picture copies went and from which
/// sources, and when — newest first, each opening its detail in place of the list.
///
/// **The one account of posts no longer here.** A hide names its rule on the row it hides; a
/// post a limit let go has no row left to name anything on, so the naming lives here, beside the
/// pickers that set the limits and the figures they changed. The lines hold only what the row
/// shows: never a post, never where it was read.
///
/// Clear is a plain press, asked first (`ShellQuestion.clearAccount`): the lines go and nothing
/// else does — there is nothing left of what they describe for a clear to reach.
struct LimitAccountSection: View {
    let session: ShellSession

    @Environment(\.colorScheme) private var colorScheme
    @State private var lit: UUID?
    @State private var opened: LimitAct?
    @State private var clearing = false

    var body: some View {
        Section {
            if let opened {
                LimitActDetail(act: opened) { self.opened = nil }
            } else {
                lines
            }
        } header: {
            ShellSectionHead(title: "prefs.limits", line: "prefs.limits.line", help: "prefs.limits.help")
        }
        .shellConfirm($clearing, question: ShellQuestion.clearAccount()) { _ in
            Task { await session.clearLimitAccount() }
        }
    }

    @ViewBuilder
    private var lines: some View {
        let listed = session.limitAccount
        ForEach(listed) { act in
            ShellListRow(
                id: act.id, title: Self.title(act), brief: Self.brief(act), figure: Self.when(act),
                selection: $lit, onOpen: { opened = act },
                onStep: { lit = ShellListStep.stepped(listed.map(\.id), from: lit, by: $0) }
            ) {
                Image(systemName: Self.symbol(act.limit))
            }
        }
        HStack(spacing: ShellSpace.snug) {
            if listed.isEmpty {
                Text(L10n.t("prefs.limits.none"))
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
            Spacer(minLength: ShellSpace.snug)
            if !listed.isEmpty {
                ShellIconButton("eraser", name: "prefs.limits.clear", help: "prefs.limits.clear.help") {
                    clearing = true
                }
            }
        }
        .padding(.vertical, ShellSpace.tight)
    }

    /// The limit's glyph: the pickers' own, so a line is read back to the picker that set it.
    static func symbol(_ limit: StoreLimit) -> String {
        switch limit {
        case .months: "hourglass"
        case .room: "internaldrive"
        }
    }

    /// The limit, named as its picker names it.
    static func title(_ act: LimitAct, language: DummyLanguage? = nil) -> String {
        switch act.limit {
        case .months: L10n.t("prefs.keep", language: language)
        case .room: L10n.t("prefs.room", language: language)
        }
    }

    /// "12 posts and 30 picture copies · from a.example, b.example": what went, and from where.
    static func brief(_ act: LimitAct, language: DummyLanguage? = nil) -> String {
        let counts = Self.counts(act, language: language)
        guard !act.sources.isEmpty else { return counts }
        return String(
            format: L10n.t("prefs.limits.brief.from", language: language), counts, act.sources.joined(separator: ", ")
        )
    }

    /// The posts, the copies, or both — one unsaid where none of it went.
    static func counts(_ act: LimitAct, language: DummyLanguage? = nil) -> String {
        let posts = L10n.count("prefs.held.posts", act.posts, language: language)
        let copies = L10n.count("prefs.limits.copies", act.copies, language: language)
        switch (act.posts, act.copies) {
        case (_, 0): return posts
        case (0, _): return copies
        default: return String(format: L10n.t("prefs.limits.both", language: language), posts, copies)
        }
    }

    /// When the limit acted, short, in the shell's language.
    static func when(_ act: LimitAct, language: DummyLanguage? = nil) -> String {
        act.at.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(L10n.locale(language)))
    }
}

/// One line of the account, opened: the limit at the head, then when, what went and from where.
struct LimitActDetail: View {
    let act: LimitAct
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            ShellDetailHead(LimitAccountSection.title(act), onBack: onBack) {
                Image(systemName: LimitAccountSection.symbol(act.limit))
            }
            ForEach(Self.facts(act), id: \.label) { fact in
                ShellDetailFact(label: fact.label, value: fact.value)
            }
        }
        .padding(.vertical, ShellSpace.tight)
    }

    /// What the detail says, label and value, in order: when, the posts, the copies, the sources.
    static func facts(_ act: LimitAct, language: DummyLanguage? = nil) -> [(label: String, value: String)] {
        [
            (L10n.t("prefs.limits.detail.time", language: language), LimitAccountSection.when(act, language: language)),
            (L10n.t("prefs.limits.detail.posts", language: language), L10n.count("prefs.held.posts", act.posts, language: language)),
            (L10n.t("prefs.limits.detail.copies", language: language), L10n.count("prefs.limits.copies", act.copies, language: language)),
            (L10n.t("prefs.limits.detail.sources", language: language),
             act.sources.isEmpty ? L10n.t("prefs.limits.detail.sources.none", language: language) : act.sources.joined(separator: ", ")),
        ]
    }
}
