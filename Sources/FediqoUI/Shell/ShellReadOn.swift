import FediqoCore
import Foundation
import SwiftUI

// A microblog timeline read again reads on from where this device left it (#201).
//
// `r` and the wait read each Mastodon timeline on from the newest id it listed — Home and the
// lists through `MastodonAccount`, the public timeline here — so what arrived while the app was
// closed is read stretch after stretch rather than skipped. Where a read stopped at its bound, or
// the source did not give back what lay between, the store keeps that with the post it sits
// against (`Note.gaps`), and the list says it at that place: above the newest post read, that
// more belong there, which reaching — by scroll, by key or by press — reads on; below the oldest
// post the source did give, that posts may be missing there, which is said and nothing more.
//
// **Reaching it is an ask for more**, as the end of the list is (#87), and not `r`: nothing is
// re-centred, so the row being read stays where it is, and the newer posts land above it. So it
// keeps that ask's company: `r` ends it, the wait and an open thread's renewal (#198) do not
// start while it is out, and it may run beside a renewal already on its way — it reads one
// Mastodon timeline, never a forum, so no stranger's forum is asked twice at once. Reached while
// another ask for more is out, it waits for that one to end rather than being dropped; reached
// while `r` or the wait is reading its source, it asks nothing, since they read it on from the
// same place.
//
// **Only where the timeline in front reads that timeline.** A post Home and a list both carry can
// be whole in the one and not the other, and Trends reads neither.

/// What the list says next to one row (#201).
struct TimelineGapMarks: Equatable {
    /// Timelines with newer posts remaining above the row, each read on when reached.
    var above: [Stretch] = []
    /// Timelines that may be missing posts below the row.
    var below: [Stretch] = []
}

extension ShellReload {
    /// The public timeline read on from the newest id it listed, and landed with what it says
    /// about where it is not whole. A reader walking away is not a failure; anything else is.
    func readOnPublic(_ client: MastodonClient, stamp: Source, in session: ShellSession) async -> Bool {
        do {
            let store = session.store
            let anchor = await store.newestListedID(host: stamp.host, category: .public)
            let held = anchor == nil ? await store.held(host: stamp.host, category: .public) : []
            let read = try await client.publicTimeline(source: stamp, readingOnFrom: anchor, holding: held)
            try Task.checkCancellation()
            await session.store.land(read, of: .public, ifSourceHere: stamp.host)
            // What came before a stretch that failed has landed; the read still did not come back.
            return read.stopped == nil
        } catch {
            return Cancellation.happened(error)
        }
    }

    /// A place where more belong, reached (#201): that one timeline read on from the newest id it
    /// listed, as an ask for more. Reached while another ask for more is out, it waits for that
    /// one to end rather than being dropped. Nothing while `r` or the wait is reading its host —
    /// they read this timeline on from the same place — nor while the editor is up.
    func readOn(_ stretch: Stretch, in session: ShellSession) async {
        guard session.editing == nil, let category = stretch.category else { return }
        let busy = [Ask.timeline, .held].filter(asking.contains)
        guard !busy.contains(where: { readingHosts[$0]?.contains(stretch.host) ?? true }) else { return }
        guard !asking.contains(.more) else {
            pendingReadOn.add(stretch, of: session)
            return
        }
        await run(.more) {
            await self.read([FetchAsk(host: stretch.host, categories: [category])], as: .more, in: session)
        }
    }

    /// The places reached while an ask for more was out, read on now it has ended — one after
    /// another, since each is an ask for more of its own. Only those the timeline in front still
    /// says more belong at, asked as each comes up: the reader may have moved on since, or a read
    /// meanwhile reached them.
    func readOnPending() {
        guard let (stretches, session) = pendingReadOn.take() else { return }
        Task { @MainActor in
            for stretch in stretches where Self.saysMore(stretch, in: session) {
                await self.readOn(stretch, in: session)
            }
        }
    }

    /// Whether the timeline in front says more belong somewhere of `stretch`'s.
    static func saysMore(_ stretch: Stretch, in session: ShellSession) -> Bool {
        session.gapMarks(in: session.timelineItems(latest: nil)).values.contains { $0.above.contains(stretch) }
    }
}

/// Places reached while another ask for more was out (#201), in the order they were reached.
struct PendingReadOn {
    private var stretches: [Stretch] = []
    private weak var session: ShellSession?

    mutating func add(_ stretch: Stretch, of session: ShellSession) {
        self.session = session
        if !stretches.contains(stretch) { stretches.append(stretch) }
    }

    /// Everything waiting, and the session it waits in, handed over once.
    mutating func take() -> ([Stretch], ShellSession)? {
        defer { stretches = [] }
        guard !stretches.isEmpty, let session else { return nil }
        return (stretches, session)
    }
}

extension ShellSession {
    /// Where the timeline in front is not whole, by the row each place is next to (#201). Every
    /// copy of a merged row answers for its own source's timelines.
    func gapMarks(in items: [DummyItem]) -> [String: TimelineGapMarks] {
        var marked: [(row: String, copy: DummyItem)] = []
        for item in items {
            if !item.gaps.isEmpty { marked.append((item.id, item)) }
            for copy in item.otherCopies where !copy.gaps.isEmpty { marked.append((item.id, copy)) }
        }
        guard !marked.isEmpty else { return [:] }
        let asks = CompiledTimeline(currentTimeline.definition(among: written), sources: sources).sourcesToAsk()
        let reads = Dictionary(asks.map { ($0.host, $0.categories) }, uniquingKeysWith: { a, _ in a })
        var marks: [String: TimelineGapMarks] = [:]
        for (row, copy) in marked {
            let host = copy.source.host
            guard let asked = reads[host] else { continue }
            let gaps = copy.gaps.sorted { String(describing: $0.category) < String(describing: $1.category) }
            for gap in gaps where asked?.contains(gap.category) ?? true {
                let stretch = Stretch(host: host, category: gap.category)
                switch gap.kind {
                case .newerRemain: marks[row, default: TimelineGapMarks()].above.append(stretch)
                case .mayBeMissing: marks[row, default: TimelineGapMarks()].below.append(stretch)
                }
            }
        }
        return marks
    }
}

/// A row, with the places next to it where its timeline is not whole said above and below it
/// (#201). A modifier of its own so the list's row stays one chain the type-checker reads quickly.
struct TimelineGapMarked: ViewModifier {
    let marks: TimelineGapMarks?
    let session: ShellSession

    /// One shape with a mark or without, so a mark coming or going never builds the row anew.
    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineGapRows(kind: .newerRemain, stretches: marks?.above ?? [], session: session)
            content
            TimelineGapRows(kind: .mayBeMissing, stretches: marks?.below ?? [], session: session)
        }
    }
}

/// The places next to one row where its timeline is not whole, each a row of words (#201).
struct TimelineGapRows: View {
    let kind: TimelineGap.Kind
    let stretches: [Stretch]
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Ruled off from the row it is next to, on that side: the row's own rule is below it.
        ForEach(stretches, id: \.self) { stretch in
            if kind == .mayBeMissing { hairline }
            TimelineGapRow(kind: kind, stretch: stretch, session: session)
            if kind == .newerRemain { hairline }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(ShellChrome.hairline(colorScheme))
            .frame(height: ShellSpace.hair)
    }
}

/// One place a timeline is not whole, said in words where it is (#201). Where more belong, a press
/// reads on, and so does the row coming into view — scrolled or walked to, as the end of the list
/// asks for more; where posts may be missing, it is said and nothing is offered.
struct TimelineGapRow: View {
    let kind: TimelineGap.Kind
    let stretch: Stretch
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let words = Self.words(kind, host: stretch.host)
        if kind == .newerRemain {
            Button(action: reach) { label(words) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
                .accessibilityAddTraits(.isButton)
                .onAppear(perform: reach)
        } else {
            label(words)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
        }
    }

    private func label(_ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Image(systemName: Self.symbol(kind))
                .accessibilityHidden(true)
            Text(words)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .shellFont(.meta)
        .foregroundStyle(ShellChrome.inkDim(colorScheme))
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .contentShape(Rectangle())
    }

    private func reach() {
        Task { await session.reload.readOn(stretch, in: session) }
    }

    static func symbol(_ kind: TimelineGap.Kind) -> String {
        switch kind {
        case .newerRemain: "arrow.up.circle"
        case .mayBeMissing: "exclamationmark.triangle"
        }
    }

    /// What the row says, naming the source. `language` for a test, which asks for one rather than
    /// setting the one every suite shares.
    static func words(_ kind: TimelineGap.Kind, host: String, language: DummyLanguage? = nil) -> String {
        switch kind {
        case .newerRemain: String(format: L10n.t("timeline.gap.more", language: language), host)
        case .mayBeMissing: String(format: L10n.t("timeline.gap.missing", language: language), host)
        }
    }
}
