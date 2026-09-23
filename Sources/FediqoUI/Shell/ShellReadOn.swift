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
// post the source did give, that posts may be missing there, which reaching reads down (#204).
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
// **Reading down is the same ask, the other way** (#204): from the post the mark sits against,
// toward what is held below it (`MastodonReadOn.readDown`). The hole filled, the mark goes; the
// bound reached first, it moves down to the oldest post read, and is reached again as that row
// is; the source answering with nothing, it settles, and says for good that what lay there is no
// longer there — in the words and the mark of a post deleted at its source (#179), and let go
// with those (`ShellGone.swift`). A read that fails leaves it as it was, and reaching it again
// tries again. Reached once, it asks once: a row asks as it comes into view, not while it stays.
//
// **Only where the timeline in front reads that timeline.** A post Home and a list both carry can
// be whole in the one and not the other, and Trends reads neither.

/// What the list says next to one row (#201).
struct TimelineGapMarks: Equatable {
    /// Timelines with newer posts remaining above the row, each read on when reached.
    var above: [Stretch] = []
    /// Timelines that may be missing posts below the row, each read down when reached (#204).
    var below: [Stretch] = []
    /// Timelines whose source no longer has what lay below the row (#204): said, and asked nothing.
    var settled: [Stretch] = []
    /// The copy of the row each source's places below sit against — a merged row carries one per
    /// source — which is what reading down reads from.
    var posts: [String: NoteKey] = [:]
}

/// One place a timeline is not whole, reached (#201, #204): where more belong, or where posts may
/// be missing below `post`.
enum GapReach: Hashable {
    case more(Stretch)
    case missing(Stretch, below: NoteKey)
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
        guard let category = stretch.category, mayReach(.more(stretch), in: session) else { return }
        await run(.more) {
            await self.read([FetchAsk(host: stretch.host, categories: [category])], as: .more, in: session)
        }
    }

    /// A place where posts may be missing below `post`, reached (#204): that one timeline read
    /// down from it, as an ask for more and in that ask's company, as `readOn` is. What it could
    /// not read is the ask for more's to say.
    func readDown(_ stretch: Stretch, below post: NoteKey, in session: ShellSession) async {
        guard let category = stretch.category, mayReach(.missing(stretch, below: post), in: session) else {
            return
        }
        await run(.more) {
            let read = await self.readDown(category, of: stretch.host, below: post, in: session)
            guard !Task.isCancelled else { return }
            await session.reloadFromStore()
            self.record(read ? [] : [stretch.host], for: .more)
        }
    }

    /// Whether a place reached asks now: not while the editor is up, nor while `r` or the wait is
    /// reading its host. Kept for later, and not asked now, while another ask for more is out.
    private func mayReach(_ reach: GapReach, in session: ShellSession) -> Bool {
        let host = switch reach {
        case .more(let stretch), .missing(let stretch, _): stretch.host
        }
        guard session.editing == nil else { return false }
        let busy = [Ask.timeline, .held].filter(asking.contains)
        guard !busy.contains(where: { readingHosts[$0]?.contains(host) ?? true }) else { return false }
        guard !asking.contains(.more) else {
            pendingReadOn.add(reach, of: session)
            return false
        }
        return true
    }

    /// One timeline read down and landed: the public one here, Home or a list as the reader.
    /// Whether it came back; a reader walking away is not a failure.
    private func readDown(
        _ category: FediqoCore.Category, of host: String, below post: NoteKey, in session: ShellSession
    ) async -> Bool {
        let stamp = Source(host: host, kind: .mastodon)
        do {
            switch category {
            case .public:
                let me = session.mastodon.handles[host]
                let signedIn = session.mastodon.isSignedIn(host: host)
                guard let place = await session.store.missing(
                    below: post, in: .public, writtenBy: me, signedIn: signedIn
                ) else {
                    return true
                }
                let client = MastodonClient(
                    http: timed(session.http, for: .timeline, name: .public, in: session), host: host
                )
                let down = try await client.publicTimeline(source: stamp, readingDownFrom: place)
                try Task.checkCancellation()
                await session.store.land(down, below: post, of: .public, ifSourceHere: host)
                return down.stopped == nil
            default:
                // Signed out since the place was drawn: nothing is asked, and nothing failed.
                guard let token = session.mastodon.token(host: host) else { return true }
                let lists = session.sources.first { $0.host == host }?.lists ?? []
                let name: SourceWork.Name? = switch category {
                case .home: .home
                case .list(let id): lists.first { $0.id == id }.map { .called($0.name) }
                default: nil
                }
                let door = session.mastodon.authorized(token: token, within: deadline, for: .timeline, name: name)
                let account = MastodonAccount(door: door, store: session.store)
                let me = session.mastodon.handles[host]
                try await asReader(host) { try await account.readDown(category, below: post, writtenBy: me) }
                return true
            }
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
            return false
        } catch {
            return Cancellation.happened(error)
        }
    }

    /// The places reached while an ask for more was out, read now it has ended — one after
    /// another, since each is an ask for more of its own. Only those the timeline in front still
    /// says the same of, asked as each comes up: the reader may have moved on since, or a read
    /// meanwhile reached them.
    func readOnPending() {
        guard let (reaches, session) = pendingReadOn.take() else { return }
        Task { @MainActor in
            for reach in reaches where Self.says(reach, in: session) {
                switch reach {
                case .more(let stretch): await self.readOn(stretch, in: session)
                case .missing(let stretch, let post): await self.readDown(stretch, below: post, in: session)
                }
            }
        }
    }

    /// Whether the timeline in front still says what `reach` was reached for.
    static func says(_ reach: GapReach, in session: ShellSession) -> Bool {
        let marks = session.gapMarks(in: session.timelineItems(latest: nil)).values
        switch reach {
        case .more(let stretch):
            return marks.contains { $0.above.contains(stretch) }
        case .missing(let stretch, let post):
            return marks.contains { $0.below.contains(stretch) && $0.posts[stretch.host] == post }
        }
    }
}

/// Places reached while another ask for more was out (#201), in the order they were reached.
struct PendingReadOn {
    private var reaches: [GapReach] = []
    private weak var session: ShellSession?

    mutating func add(_ reach: GapReach, of session: ShellSession) {
        self.session = session
        if !reaches.contains(reach) { reaches.append(reach) }
    }

    /// Everything waiting, and the session it waits in, handed over once.
    mutating func take() -> ([GapReach], ShellSession)? {
        defer { reaches = [] }
        guard !reaches.isEmpty, let session else { return nil }
        return (reaches, session)
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
                case .settled: marks[row, default: TimelineGapMarks()].settled.append(stretch)
                }
                if gap.kind != .newerRemain, let post = NoteKey(rowID: copy.id) {
                    marks[row]?.posts[host] = post
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
            TimelineGapRows(
                kind: .mayBeMissing, stretches: marks?.below ?? [], session: session, posts: marks?.posts ?? [:]
            )
            TimelineGapRows(kind: .settled, stretches: marks?.settled ?? [], session: session)
        }
    }
}

/// The places next to one row where its timeline is not whole, each a row of words (#201).
struct TimelineGapRows: View {
    let kind: TimelineGap.Kind
    let stretches: [Stretch]
    let session: ShellSession
    /// The copy each source's place below sits against, where posts may be missing (#204).
    var posts: [String: NoteKey] = [:]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Ruled off from the row it is next to, on that side: the row's own rule is below it.
        ForEach(stretches, id: \.self) { stretch in
            if kind != .newerRemain { hairline }
            TimelineGapRow(kind: kind, stretch: stretch, session: session, post: posts[stretch.host])
            if kind == .newerRemain { hairline }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(ShellChrome.hairline(colorScheme))
            .frame(height: ShellSpace.hair)
    }
}

/// One place a timeline is not whole, said in words where it is (#201). Where more belong, or
/// posts may be missing (#204), a press reads them, and so does the row coming into view —
/// scrolled or walked to, as the end of the list asks for more; where the source no longer has
/// what lay there, it is said as a post deleted at its source is (#179), and nothing is offered.
struct TimelineGapRow: View {
    let kind: TimelineGap.Kind
    let stretch: Stretch
    let session: ShellSession
    /// The post a place where posts may be missing sits against: what reading down reads from.
    var post: NoteKey?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let words = Self.words(kind, host: stretch.host)
        if Self.reads(kind) {
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
        switch kind {
        case .newerRemain:
            Task { await session.reload.readOn(stretch, in: session) }
        case .mayBeMissing:
            guard let post else { return }
            Task { await session.reload.readDown(stretch, below: post, in: session) }
        case .settled:
            return
        }
    }

    /// Whether reaching a place of `kind` reads anything. A settled one asks nothing again.
    static func reads(_ kind: TimelineGap.Kind) -> Bool {
        kind != .settled
    }

    /// The glyph beside the words: a settled place wears a deleted post's (`DummyItemRow.goneMark`).
    static func symbol(_ kind: TimelineGap.Kind) -> String {
        switch kind {
        case .newerRemain: "arrow.up.circle"
        case .mayBeMissing: "exclamationmark.triangle"
        case .settled: "xmark.bin"
        }
    }

    /// What the row says, naming the source — and what VoiceOver says, the row being one element.
    /// A settled place opens with a deleted post's word, so it is heard as one is. `language` for
    /// a test, which asks for one rather than setting the one every suite shares.
    static func words(_ kind: TimelineGap.Kind, host: String, language: DummyLanguage? = nil) -> String {
        switch kind {
        case .newerRemain: String(format: L10n.t("timeline.gap.more", language: language), host)
        case .mayBeMissing: String(format: L10n.t("timeline.gap.missing", language: language), host)
        case .settled:
            String(
                format: L10n.t("timeline.gap.settled", language: language),
                DummyItemRow.goneWord(language: language), host
            )
        }
    }
}
