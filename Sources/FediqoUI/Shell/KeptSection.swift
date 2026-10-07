import FediqoCore
import SwiftUI

/// What the person keeps (#284), where this device says what it holds (#294): how many posts and
/// what their words weigh, every source together and each by its name — a source that has been
/// removed among them, since a kept post outlives its source.
///
/// **On the Keep tab, beside the limits, because it is what the limits cannot reach.** The Room
/// line above already says when kept posts alone hold the store over its room; this is where the
/// reader sees how many those are, whose they are, and can let them be ordinary posts again.
///
/// **A row is a source's mark, its name, its figure and `…`; stopping is behind the dots.** Stop
/// keeping takes a mark away that does not come back by itself, so it is a destructive item of
/// the row's menu and has no button of its own. It asks first and lets nothing go: the question
/// names the count, a yes takes the mark off and nothing else. The posts are then what any post
/// is, and the next limit, or the next letting go, may take them — which the question says,
/// since that is what the yes costs.
///
/// A view of its own, as `GoneSection` is, so the page keeps one section per fact.
struct KeptSection: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: ShellSession

    /// What the last press did, and nothing before one.
    @State private var went: StoppedKeeping?

    var body: some View {
        let lines = Self.lines(session.holdings, sources: session.sources.map(\.host))
        Section {
            if lines.isEmpty {
                ShellReadingLine(L10n.t("usage.kept.none"))
            } else {
                row(
                    L10n.t("usage.span.every"), figure: Self.figure(session.holdings.kept),
                    ask: KeptAsk(host: nil, posts: session.holdings.kept.posts)
                ) {
                    Image(systemName: UsagePane.Purpose.source.symbol)
                        .shellFont(.name)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .accessibilityHidden(true)
                }
                // Every source a line may name, looked up once for the list and not once a line.
                let known = Self.sources(in: session)
                ForEach(lines) { line in
                    row(Self.name(line), figure: Self.figure(line.kept), ask: Self.ask(line)) {
                        UsageSourceMark(source: known[line.host] ?? Source(host: line.host, kind: .unknown))
                    }
                }
            }
            if let went { ShellReadingLine(Self.wentLine(went)) }
        } header: {
            ShellSectionHead(title: "usage.kept", line: "usage.kept.line", help: "usage.kept.help")
        }
    }

    /// One row: the mark, the name over its figure, and the `…` that holds stopping.
    private func row(_ name: String, figure: String, ask: KeptAsk, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: ShellSpace.snug) {
            mark()
            VStack(alignment: .leading, spacing: 0) {
                // A host is a name like any other row's: one line, and its middle goes first.
                Text(name)
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ShellReadingLine(figure)
            }
            Spacer(minLength: ShellSpace.snug)
            ShellMoreButton(Self.more(
                ask,
                said: { went = $0 },
                stop: { Task { went = await session.stopKeeping(host: ask.host) } }
            ))
        }
    }

    /// A row's `…`: the one item that stops keeping what the row counts.
    ///
    /// **Destructive, and asking `ShellQuestion.stopKeeping` first, wherever a press would make a
    /// post ordinary.** A source whose every kept post is kept through another source too has
    /// nothing this press would make ordinary: the item is then an ordinary one, since it takes
    /// nothing away, and choosing it says so at once (`said`) — nothing is asked or done.
    static func more(
        _ ask: KeptAsk, said: @escaping (StoppedKeeping) -> Void, stop: @escaping () -> Void,
        language: DummyLanguage? = nil
    ) -> ShellMore {
        let name = String(
            format: L10n.t("usage.kept.stop.from", language: language),
            SpanSection.whereLabel(ask.host, language: language)
        )
        guard ask.posts > 0 else {
            return ShellMore(items: [
                .plain(stopSymbol, name) { said(StoppedKeeping(ordinary: 0, elsewhere: ask.elsewhere)) },
            ])
        }
        return ShellMore(items: [
            .danger(stopSymbol, name, asks: ShellQuestion.stopKeeping(ask, language: language), act: stop),
        ])
    }

    static let stopSymbol = "bookmark.slash"

    /// The source each line is about, for its mark, by host: one here, or one removed whose
    /// posts stayed (`UsageSourceList.source`'s order). A host in neither is drawn as the host
    /// alone, since nothing remembers its kind.
    static func sources(in session: ShellSession) -> [String: Source] {
        Dictionary(
            (session.sources + UsageSourceList.removed(session)).map { ($0.host, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// What is kept from one source.
    struct Line: Equatable, Identifiable {
        let host: String
        let kept: Holdings.Kept
        /// Whether the source is no longer here: its kept posts stayed when it was removed.
        let removed: Bool
        /// How many of them stay kept through another source's copy, whatever is done here.
        var elsewhere = 0

        var id: String { host }
    }

    /// One line a source that anything is kept from: the sources here in their own order, then
    /// the ones removed, by host — `UsageSourceList`'s order, so the two tabs read alike.
    static func lines(_ holdings: Holdings, sources: [String]) -> [Line] {
        let here = sources.filter { holdings.keptBySource[$0] != nil }
        let removed = holdings.keptBySource.keys.filter { !sources.contains($0) }.sorted()
        func line(_ host: String, removed: Bool) -> Line {
            Line(host: host, kept: holdings.kept(host: host), removed: removed, elsewhere: holdings.keptElsewhere(host: host))
        }
        return here.map { line($0, removed: false) } + removed.map { line($0, removed: true) }
    }

    /// What one source's press asks about: the posts that would be ordinary afterwards, and
    /// beside them the ones that stay kept through another source.
    static func ask(_ line: Line) -> KeptAsk {
        KeptAsk(host: line.host, posts: line.kept.posts - line.elsewhere, elsewhere: line.elsewhere)
    }

    /// A source by its host, and one no longer here said to be so.
    static func name(_ line: Line, language: DummyLanguage? = nil) -> String {
        line.removed
            ? String(format: L10n.t("usage.kept.removed", language: language), line.host)
            : line.host
    }

    /// "3 kept · 4 KB of words".
    static func figure(_ kept: Holdings.Kept, language: DummyLanguage? = nil) -> String {
        String(
            format: L10n.t("usage.kept.figure", language: language),
            L10n.count("usage.kept.posts", kept.posts, language: language),
            UsagePane.size(kept.bytes, language: language)
        )
    }

    /// What a press says back: how many posts are ordinary now, and how many stay kept through
    /// another source — each said only where there is any, and "none" where there is neither.
    static func wentLine(_ went: StoppedKeeping, language: DummyLanguage? = nil) -> String {
        let ordinary = went.ordinary == 0 ? nil : L10n.count("usage.kept.went", went.ordinary, language: language)
        let elsewhere = went.elsewhere == 0 ? nil : L10n.count("usage.kept.elsewhere", went.elsewhere, language: language)
        switch (ordinary, elsewhere) {
        case (nil, nil): return L10n.t("usage.kept.went.none", language: language)
        case (let line?, nil), (nil, let line?): return line
        case (let ordinary?, let elsewhere?):
            return String(format: L10n.t("question.join", language: language), ordinary, elsewhere)
        }
    }
}

/// What a press is about to stop keeping (#294): every source's, or one host's — one here or one
/// removed — and how many posts that was at the press, which is what the question names.
///
/// `posts` are the ones that will be ordinary afterwards. `elsewhere` are this source's copies of
/// posts another source's copy keeps too: un-kept here, they stay kept there, and the question
/// says so rather than counting them as let go of.
struct KeptAsk: Equatable {
    let host: String?
    let posts: Int
    var elsewhere = 0
}
