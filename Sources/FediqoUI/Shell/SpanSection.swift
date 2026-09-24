import FediqoCore
import SwiftUI

/// Part of what this device holds, let go on purpose (#248): the posts of a span of days, from
/// one source or from every one, and a press that lets exactly those go.
///
/// **On the Keep tab, beside the window and the wait, because it is the same question asked the
/// other way round.** The window and the wait say how long a post stays; this says which posts
/// go now, and the person is the one saying it. The figure on the press's row is live — it is
/// the store's count for the days and the source picked, read again as either moves — so what the
/// question then names is what the reader already saw.
///
/// **Every host with a post held is offered**, not only the sources joined: a source removed
/// while its posts were kept (#250) is a host `Holdings` still counts, and its posts are as much
/// this device's to let go as any other's.
///
/// A view of its own for `GoneSection`'s reason: one group per fact, read and tested alone.
struct SpanSection: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: ShellSession

    /// The first and the last day of the span, both inside it. Today until the reader says.
    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var to = Calendar.current.startOfDay(for: Date())
    /// The one host whose posts go, or every host where nil.
    @State private var host: String?
    /// The store's count for the span and host, nil until the first read lands — a "0" drawn
    /// before anything was counted would be a figure about nothing.
    @State private var count: Int?
    /// The press has counted again and is asking first; what it counted is what the question
    /// names, never a figure the screen drew before the store moved under it.
    @State private var asking: SpanAsk?
    /// What the last press let go, and nothing before a press.
    @State private var went: Int?

    /// What the count is read again for: the span, the host, and the holding moving under them.
    private struct Probe: Equatable {
        let span: Range<Date>
        let host: String?
        let holdings: Holdings
    }

    var body: some View {
        Section {
            DatePicker(L10n.t("usage.span.from"), selection: $from, in: ...to, displayedComponents: .date)
            DatePicker(L10n.t("usage.span.to"), selection: $to, in: from..., displayedComponents: .date)
            sourcePicker
            HStack(spacing: ShellSpace.snug) {
                if let count { reading(Self.countLine(count)) }
                Spacer(minLength: ShellSpace.snug)
                ShellIconButton("trash", name: "usage.span.now", help: "usage.span.now.help", tone: .alarm) {
                    let ask = SpanAsk(from: from, to: to, host: host)
                    Task {
                        // Counted at the press, as `GoneSection` counts: nothing to let go is
                        // said on the row, anything is asked about by its count now.
                        let counted = await session.spanHeld(ask.span, host: ask.host)
                        if counted == 0 { count = 0 } else { asking = ask.counting(counted) }
                    }
                }
                .disabled((count ?? 0) == 0)
            }
            if let went { reading(Self.wentLine(went)) }
        } header: {
            ShellSectionHead(title: "prefs.span", line: "usage.span.line", help: "prefs.span.footer")
        }
        .task(id: Probe(span: span, host: host, holdings: session.holdings)) {
            // Nothing until this read lands, so the press is never made on a stale figure.
            count = nil
            count = await session.spanHeld(span, host: host)
        }
        .onChange(of: hosts) { _, hosts in
            if let host, !hosts.contains(host) { self.host = nil }
        }
        .shellConfirm($asking, question: { ShellQuestion.letGo($0) }) { ask, _ in
            Task { went = await session.letGo(span: ask.span, host: ask.host) }
        }
    }

    /// Every source, then each host holding a post, in one order whoever joined them.
    private var sourcePicker: some View {
        Picker(L10n.t("usage.span.source"), selection: $host) {
            Text(L10n.t("usage.span.every")).tag(String?.none)
            ForEach(hosts, id: \.self) { host in
                Text(host).tag(String?.some(host))
            }
        }
    }

    private var hosts: [String] { Self.hosts(session.holdings) }

    private var span: Range<Date> { Self.span(from: from, to: to) }

    /// The hosts a post is held from, sorted — a removed source's among them.
    static func hosts(_ holdings: Holdings) -> [String] {
        holdings.bySource.keys.sorted()
    }

    /// The whole days from `from` to `to`, both inside, in this device's calendar: the moments
    /// a post is let go by, since the store reads when a post was posted and the reader picks
    /// days. `to` before `from` is the one day `from`, as the pickers never allow it.
    static func span(from: Date, to: Date, calendar: Calendar = .current) -> Range<Date> {
        let start = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: max(from, to))
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400)
        return start..<end
    }

    /// The days named as the reader picked them: one day, or the first and the last.
    static func spanLabel(from: Date, to: Date, calendar: Calendar = .current, language: DummyLanguage? = nil)
        -> String
    {
        let style = Date.FormatStyle.dateTime.year().month(.abbreviated).day().locale(L10n.locale(language))
        guard !calendar.isDate(from, inSameDayAs: to) else { return from.formatted(style) }
        return String(format: L10n.t("usage.span.between", language: language), from.formatted(style), to.formatted(style))
    }

    /// Where the posts come from, as the question says it mid-sentence: the host, or every source.
    static func whereLabel(_ host: String?, language: DummyLanguage? = nil) -> String {
        host ?? L10n.t("usage.span.every.line", language: language)
    }

    /// The live figure: how many posts the span and source hold, or that they hold none.
    static func countLine(_ count: Int, language: DummyLanguage? = nil) -> String {
        count == 0 ? L10n.t("usage.span.none", language: language) : L10n.count("prefs.held.posts", count, language: language)
    }

    /// What the press says back: how many went.
    static func wentLine(_ count: Int, language: DummyLanguage? = nil) -> String {
        L10n.count("prefs.span.went", count, language: language)
    }

    private func reading(_ line: String) -> some View {
        Text(line)
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
    }
}

/// What a press is about to let go (#248): the days and the host the reader picked, and how
/// many posts the store counted for them at the press — what the question names.
struct SpanAsk: Equatable {
    var posts = 0
    let from: Date
    let to: Date
    let host: String?

    var span: Range<Date> { SpanSection.span(from: from, to: to) }

    /// The same ask, with the count the store gave.
    func counting(_ posts: Int) -> SpanAsk {
        var counted = self
        counted.posts = posts
        return counted
    }
}

extension ShellSession {
    /// How many posts `span` holds from `host`, or from every host where nil — what the press
    /// would let go (#248), read off the store so the rows held aside are counted too.
    func spanHeld(_ span: Range<Date>, host: String?) async -> Int {
        await store.count(span: span, host: host)
    }

    /// Lets go of the posts of `span` from `host`, or from every host where nil — the reader's
    /// press (#248). Where something went, the rows are read again, the store is written so the
    /// drop holds after a relaunch, and the index is measured again; where nothing did, nothing
    /// moves. Returns how many went.
    @discardableResult
    func letGo(span: Range<Date>, host: String?) async -> Int {
        let went = await store.letGo(span: span, host: host)
        guard went > 0 else { return 0 }
        await reloadFromStore()
        await persist?()
        await readStoreBytes()
        return went
    }
}
