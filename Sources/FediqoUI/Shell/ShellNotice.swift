import FediqoCore
import SwiftUI

/// What a page says when it has nothing to show. Left aligned like every other page
/// here, and it names the next thing to do rather than describing the emptiness.
///
/// **Empty is this view, not a wait and not a failure.** `ShellWaiting` is still on the
/// wire in a place; `ShellFailure` is a miss in a place (a picture, the composer). A
/// wait or miss of the stream is the toast. A place with nothing to show draws this.
struct ShellNotice: View {
    let symbol: String
    let title: String
    let detail: String
    /// A whole empty page fills the pane; a thread with nothing under it does not.
    var fills = true
    /// The longer explanation behind a (?) after the detail, where the detail is kept short.
    var help: String?

    @Environment(\.colorScheme) private var colorScheme

    @ShellMetric(relativeTo: .title3) private var glyph: CGFloat = 28

    private enum Metrics {
        /// An empty page is prose. It wraps where a sentence should.
        static let saying: CGFloat = 560
    }

    init(symbol: String, title: String, detail: String, fills: Bool = true, help: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.fills = fills
        self.help = help
    }

    init(_ notice: EmptyNotice) {
        self.init(
            symbol: notice.symbol, title: notice.title, detail: notice.detail, fills: notice.fills,
            help: notice.help
        )
    }

    var body: some View {
        // The (?) after the line it explains, on the notice's own heading rather than under it
        // (#244): an empty place is its own group, and its title and line are that group's head.
        HStack(alignment: .lastTextBaseline, spacing: ShellSpace.tight) {
            words
            if let help { ShellHelp(verbatim: help, about: title) }
        }
        .frame(maxWidth: Metrics.saying, alignment: .leading)
        .padding(ShellSpace.pad)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
    }

    /// One element to VoiceOver; the (?) after it is spoken as itself.
    private var words: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .regular))
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .accessibilityHidden(true)
            Text(title)
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            Text(detail)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(EmptyNotice.spoken(title: title, detail: detail)))
    }
}

/// What an empty place says, from facts a test can name without drawing the pane.
///
/// The stream draws this wherever it has no rows (`TimelinePane.underneath`). This is the copy
/// and the distinctions inside that empty: a search, a timeline the rules emptied, a source
/// never asked, a source that answered with nothing, a thread with nothing under it.
struct EmptyNotice: Equatable, Sendable {
    /// Why this place is empty. The view does not switch on it; tests do.
    enum Kind: Equatable, Sendable {
        /// The search is still folding what this device holds.
        case indexing
        /// A pattern was matched against the store, and nothing held matched.
        case search
        /// Nobody is joined, so nothing can land.
        case noSources
        /// Sources are here; this device has not kept a note from them.
        case held
        /// A reload of this session finished, nobody failed, and still nothing is kept.
        case answered
        /// The store has notes; this query's own rules let none through, and this is the
        /// rule that hid them.
        case rules(Rule.ID)
        /// The rules would let notes through; the latest date holds them back.
        case latest
        /// A thread with nothing under it — not the timeline's empty, and not a wait.
        case thread
    }

    var kind: Kind
    var symbol: String
    var title: String
    var detail: String
    var fills: Bool = true
    /// What the one line leaves out, behind its (?), where there is more.
    var help: String?

    /// The rule that emptied this timeline, where that is why.
    var ruleID: Rule.ID? {
        if case .rules(let id) = kind { return id }
        return nil
    }

    /// What VoiceOver is owed: the title and the next thing to do, as one sentence.
    var spoken: String { Self.spoken(title: title, detail: detail) }

    static func spoken(title: String, detail: String) -> String {
        title + " " + detail
    }

    /// An empty timeline or an empty search. Search stays its own notices; a timeline
    /// emptied by rules names that rule in the hide's own words.
    ///
    /// **`asked` is a reload of this session that finished with nobody failing.** Join
    /// also asks, and Clear can empty a store a reload had filled; those are not facts
    /// this function can pin without a store schema, so they are not told apart here.
    /// `landed > 0`, `failed` empty, not `stopped` is the asked the session already has.
    static func timeline(
        searching: Bool,
        indexed: Bool,
        query: TimelineQuery,
        notes: [Note],
        written: [TimelineDefinition],
        sources: [Source],
        index: TextIndex,
        latest: LatestDate?,
        asked: Bool,
        language: DummyLanguage? = nil
    ) -> EmptyNotice {
        if searching {
            if !indexed {
                return EmptyNotice(
                    kind: .indexing,
                    symbol: "magnifyingglass",
                    title: L10n.t("search.indexing.title", language: language),
                    detail: L10n.t("search.indexing.detail", language: language)
                )
            }
            // Which timeline it looked in (#145): a search finds only what that one lets through,
            // so "nothing matches" without the name would read as nothing on this device at all.
            let name = query.name(among: written, language: language)
            return EmptyNotice(
                kind: .search,
                symbol: "magnifyingglass",
                title: String(format: L10n.t("search.empty.title", language: language), name),
                detail: L10n.t("search.empty.line", language: language),
                help: L10n.t("search.empty.detail", language: language)
            )
        }

        let definition = query.definition(among: written)
        if let rule = Self.ruleThatHid(notes, definition: definition, sources: sources, index: index)
        {
            let status = CompiledTimeline(definition, sources: sources).status(of: rule)
            let named = RuleText.spoken(rule, status: status, sources: sources, language: language)
            let words = named.isEmpty ? RuleText.phrase(rule, sources: sources, language: language) : named
            let title: String
            switch query {
            case .trends:
                title = L10n.t("timeline.empty.trends.title", language: language)
            case .all, .written:
                title = L10n.t("timeline.empty.rules.title", language: language)
            }
            return EmptyNotice(
                kind: .rules(rule.id),
                symbol: "list.bullet.rectangle",
                title: title,
                detail: String(format: L10n.t("timeline.empty.rules.detail", language: language), words)
            )
        }

        if !notes.isEmpty, let latest {
            let allowed = CompiledTimeline(definition, sources: sources).shown(notes, index)
            if !allowed.isEmpty, latest.shown(allowed).isEmpty {
                return EmptyNotice(
                    kind: .latest,
                    symbol: "list.bullet.rectangle",
                    title: L10n.t("timeline.empty.latest.title", language: language),
                    detail: L10n.t("timeline.empty.latest.detail", language: language)
                )
            }
        }

        if sources.isEmpty {
            return Self.queryEmpty(.noSources, query: query, language: language)
        }
        if asked {
            return Self.queryEmpty(.answered, query: query, language: language)
        }
        return Self.queryEmpty(.held, query: query, language: language)
    }

    /// A thread with nothing under it, or nothing where this is still a wait or a
    /// way in. A miss is the toast, so it does not suppress this notice. Conversation
    /// fetch is out of this pane; a microblog with a reply count above zero is not
    /// told as empty just because the descendants list is.
    static func thread(
        descendantCount: Int,
        replyCount: Int?,
        standing: ForumRepliesStanding?,
        language: DummyLanguage? = nil
    ) -> EmptyNotice? {
        let forumNone: Bool
        if let standing {
            switch standing {
            case .none:
                forumNone = true
            case .unasked, .coming, .loaded, .absent:
                return nil
            }
        } else {
            guard descendantCount == 0, replyCount == 0 else { return nil }
            forumNone = false
        }
        let title = forumNone
            ? L10n.t("thread.replies.none", language: language)
            : L10n.t("thread.empty.title", language: language)
        return EmptyNotice(
            kind: .thread,
            symbol: "text.bubble",
            title: title,
            detail: L10n.t("thread.empty.detail", language: language),
            fills: false
        )
    }

    private static func queryEmpty(
        _ kind: Kind, query: TimelineQuery, language: DummyLanguage?
    ) -> EmptyNotice {
        let title: String
        let detail: String
        switch (kind, query) {
        case (.answered, .trends):
            title = L10n.t("timeline.empty.trends.title", language: language)
            detail = L10n.t("timeline.empty.trends.answered.detail", language: language)
        case (.answered, _):
            title = L10n.t("timeline.empty.answered.title", language: language)
            detail = L10n.t("timeline.empty.answered.detail", language: language)
        case (.held, .trends), (.noSources, .trends):
            title = L10n.t("timeline.empty.trends.title", language: language)
            detail = L10n.t("timeline.empty.trends.detail", language: language)
        case (.held, _):
            title = L10n.t("timeline.empty.held.title", language: language)
            detail = L10n.t("timeline.empty.held.detail", language: language)
        default:
            title = L10n.t("\(query.emptyKey).title", language: language)
            detail = L10n.t("\(query.emptyKey).detail", language: language)
        }
        return EmptyNotice(
            kind: kind,
            symbol: "list.bullet.rectangle",
            title: title,
            detail: detail
        )
    }

    /// The first of the timeline's own rules that hid any of these notes, where none of
    /// them is shown. Nothing where the store is empty, or where a note is let through.
    private static func ruleThatHid(
        _ notes: [Note],
        definition: TimelineDefinition,
        sources: [Source],
        index: TextIndex
    ) -> Rule? {
        guard !notes.isEmpty else { return nil }
        let compiled = CompiledTimeline(definition, sources: sources)
        var ids: Set<Rule.ID> = []
        for note in notes {
            switch compiled.verdict(note, index) {
            case .shown: return nil
            case .hidden(let id): ids.insert(id)
            }
        }
        return definition.rules.first { ids.contains($0.id) }
    }
}
