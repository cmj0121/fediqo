import FediqoCore
import SwiftUI

/// What the person keeps (#284), where this device says what it holds (#294): how many posts and
/// what their words weigh, every source together and each by its name — a source that has been
/// removed among them, since a kept post outlives its source — and a press beside each figure
/// that stops keeping all of it.
///
/// **On the Keep tab, beside the limits, because it is what the limits cannot reach.** The Room
/// line above already says when kept posts alone hold the store over its room; this is where the
/// reader sees how many those are, whose they are, and can let them be ordinary posts again.
///
/// **Stop keeping asks first, and lets nothing go.** The question names the count; a yes takes
/// the mark off and nothing else. The posts are then what any post is, and the next limit, or the
/// next letting go, may take them — which the question says, since that is what the yes costs.
///
/// A view of its own, as `GoneSection` is, so the page keeps one section per fact.
struct KeptSection: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: ShellSession

    /// The press has its count and is asking first.
    @State private var asking: KeptAsk?
    /// What the last press did, and nothing before one.
    @State private var went: StoppedKeeping?

    var body: some View {
        let lines = Self.lines(session.holdings, sources: session.sources.map(\.host))
        Section {
            if lines.isEmpty {
                reading(L10n.t("usage.kept.none"))
            } else {
                row(
                    L10n.t("usage.span.every"), figure: Self.figure(session.holdings.kept),
                    ask: KeptAsk(host: nil, posts: session.holdings.kept.posts)
                )
                ForEach(lines) { line in
                    row(Self.name(line), figure: Self.figure(line.kept), ask: Self.ask(line))
                }
            }
            if let went { reading(Self.wentLine(went)) }
        } header: {
            ShellSectionHead(title: "usage.kept", line: "usage.kept.line", help: "usage.kept.help")
        }
        .shellConfirm($asking, question: { ShellQuestion.stopKeeping($0) }) { ask, _ in
            Task { went = await session.stopKeeping(host: ask.host) }
        }
    }

    /// One figure and the press that stops keeping what it counts.
    private func row(_ name: String, figure: String, ask: KeptAsk) -> some View {
        HStack(spacing: ShellSpace.snug) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name).shellFont(.reading)
                reading(figure)
            }
            Spacer(minLength: ShellSpace.snug)
            ShellIconButton("bookmark.slash", name: "usage.kept.stop", help: "usage.kept.stop.help", tone: .alarm) {
                // A source whose every kept post is kept through another source too has nothing
                // this press would make ordinary: said at once, and nothing is asked or done.
                if ask.posts == 0 {
                    went = StoppedKeeping(ordinary: 0, elsewhere: ask.elsewhere)
                } else {
                    asking = ask
                }
            }
        }
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

    private func reading(_ line: String) -> some View {
        Text(line)
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
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
