import FediqoCore
import SwiftUI

/// Part of what this device holds, let go on purpose (#248): the posts of a span of days, from
/// one source or from every one, and — behind the row's `…` — the press that lets exactly those go.
///
/// **On the Keep tab, beside the window and the wait, because it is the same question asked the
/// other way round.** The window and the wait say how long a post stays; this says which posts
/// go now, and the person is the one saying it. The figure on the row is live — it is the
/// store's count for the days and the source picked, read again as either moves or as what is
/// held does. A read overtaken by a newer pick is dropped, so an old span's figure never lands
/// on a new one.
///
/// **Let go is a destructive item of the row's `…`, and has no button of its own.** It counts
/// again at the press, as the button it replaces did, so the number the question names is the
/// number at the press and never a figure the screen drew before the store moved under it.
/// Where the days and source hold nothing it is dim, and the menu's head says so.
///
/// **Every host with a post held is offered**, not only the sources joined: a source removed
/// while its posts were kept (#250) is a host `Holdings` still counts, and its posts are as much
/// this device's to let go as any other's.
///
/// A view of its own for `GoneSection`'s reason: one group per fact, read and tested alone.
struct SpanSection: View {
    let session: ShellSession

    /// The first and the last day of the span, both inside it. Today until the reader says.
    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var to = Calendar.current.startOfDay(for: Date())
    /// The one host whose posts go, or every host where nil.
    @State private var host: String?
    /// The store's count for the span and host, nil until the first read lands — a "0" drawn
    /// before anything was counted would be a figure about nothing.
    @State private var count: Int?
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
                if let count { ShellReadingLine(Self.countLine(count)) }
                Spacer(minLength: ShellSpace.snug)
                ShellMoreButton(Self.more(
                    SpanAsk(from: from, to: to, host: host), figure: count,
                    count: { ask in
                        (await session.spanHeld(ask.span, host: ask.host), await session.spanKept(ask.span, host: ask.host))
                    },
                    none: { count = 0 },
                    go: { [from, to, host] in
                        Task { went = await session.letGo(span: Self.span(from: from, to: to), host: host) }
                    }
                ))
            }
            if let went { ShellReadingLine(Self.wentLine(went, offDevice: !Self.unwritten(in: session))) }
        } header: {
            ShellSectionHead(title: "prefs.span", line: "usage.span.line", help: "prefs.span.footer")
        }
        .task(id: Probe(span: span, host: host, holdings: session.holdings)) {
            // Nothing until this read lands, so the press is never made on a stale figure.
            count = nil
            // Dropped where a newer pick has cancelled this read: its figure is another span's.
            if let read = await Self.landed({ await session.spanHeld(span, host: host) }) { count = read }
        }
        .onChange(of: hosts) { _, hosts in
            if let host, !hosts.contains(host) { self.host = nil }
        }
    }

    /// What a read came to, or nothing where the task it ran in was cancelled while it was out
    /// — the pickers moved, and the answer is about days or a source no longer picked.
    static func landed<Value: Sendable>(_ read: @MainActor () async -> Value) async -> Value? {
        let value = await read()
        return Task.isCancelled ? nil : value
    }

    /// The row's `…`: the one item that lets the posts of `ask`'s days and source go.
    ///
    /// **Destructive, and its question is counted at the press** (`ShellMoreItem.danger(counts:)`):
    /// `count` is asked for the posts and the kept ones among them when the item is chosen, and
    /// `ShellQuestion.letGo` names that count — not `figure`, which is only what the row drew.
    /// Where the count is none, `none` is told so the row says so, and nothing is asked.
    ///
    /// Dim while `figure` is none or not yet read, and then the head says why in its own words:
    /// there is nothing on these days, which "not right now" would not say.
    static func more(
        _ ask: SpanAsk, figure: Int?,
        count: @escaping @MainActor (SpanAsk) async -> (posts: Int, kept: Int),
        none: @escaping @MainActor () -> Void, go: @escaping () -> Void,
        language: DummyLanguage? = nil
    ) -> ShellMore {
        let live = (figure ?? 0) > 0
        let item = ShellMoreItem.danger(
            "trash", L10n.t("usage.span.now", language: language),
            look: live ? .live : .dim(.notNow),
            counts: {
                let counted = await count(ask)
                guard counted.posts > 0 else {
                    none()
                    return nil
                }
                return ShellQuestion.letGo(ask.counting(counted.posts, kept: counted.kept), language: language)
            },
            act: go
        )
        return .ending(in: item, dimFor: live ? nil : L10n.t("usage.span.none", language: language))
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

    /// Whether the posts a press let go are still in this device's file: the write behind it
    /// did not land, and the strip says so (`ShellSession.saveNow`) until one does.
    static func unwritten(in session: ShellSession) -> Bool {
        session.said.lines.contains { $0.what == .unwritten(.posts) }
    }

    /// What the press says back: how many went — or, where the write that takes them off
    /// the disk did not land, the strip's own sentence that they are not off this device yet,
    /// and no count: nothing is said to be done that is not.
    static func wentLine(_ count: Int, offDevice: Bool = true, language: DummyLanguage? = nil) -> String {
        guard offDevice else { return Said(.unwritten(.posts), .unreachable, host: "").words(language: language) }
        return L10n.count("prefs.span.went", count, language: language)
    }
}

/// What a press is about to let go (#248): the days and the host the reader picked, and how
/// many posts the store counted for them at the press — what the question names.
struct SpanAsk: Equatable {
    var posts = 0
    /// How many posts of those days and that source the person keeps, which stay (#294).
    var kept = 0
    let from: Date
    let to: Date
    let host: String?

    var span: Range<Date> { SpanSection.span(from: from, to: to) }

    /// The same ask, with the count the store gave.
    func counting(_ posts: Int, kept: Int = 0) -> SpanAsk {
        var counted = self
        counted.posts = posts
        counted.kept = kept
        return counted
    }
}

extension ShellSession {
    /// How many posts `span` holds from `host`, or from every host where nil — what the press
    /// would let go (#248), read off the store so a forum topic's kept replies are counted too.
    func spanHeld(_ span: Range<Date>, host: String?) async -> Int {
        await store.count(span: span, host: host)
    }

    /// How many kept posts `span` holds from `host`: what the press would leave (#294).
    func spanKept(_ span: Range<Date>, host: String?) async -> Int {
        await store.keptCount(span: span, host: host)
    }

    /// Lets go of the posts of `span` from `host`, or from every host where nil — the reader's
    /// press (#248). Where something went, the rows are read again, the store is written so the
    /// drop holds after a relaunch, and the index is measured again; where nothing did, nothing
    /// moves. Returns how many went.
    ///
    /// **A notice's copy of a post of those days goes too**, an item or not, and is counted
    /// nowhere — a notice is not a post — but is off the disk before this returns all the same.
    @discardableResult
    func letGo(span: Range<Date>, host: String?) async -> Int {
        await holdingStill {
            let told = await store.noticesRevision
            let went = await store.letGo(span: span, host: host)
            guard went > 0 else {
                // Only the copy a notice carried went: waited for like the rest (#292), as
                // `keep(months:)` waits for the notices its limit alone let go.
                if await store.noticesRevision != told { await saveNow(.posts) }
                return 0
            }
            await reloadFromStore()
            // Waited for: the count is not said while the file still holds what went (#292).
            await saveNow(.posts) { [weak self] in await self?.readStoreBytes() }
            return went
        }
    }
}
