import FediqoCore
import SwiftUI

/// What this device is holding from each server the reader added (#21). Preferences keeps what a
/// person chooses; this page keeps what this device holds.
///
/// Tabbed by purpose (#7), one style a tab (#234): the sources as a list, the posts by time as an
/// account, how long they are kept as a form, and the picture copies. The cache section is
/// decision 14's screen. Three caches hold a server's copy between them and none of them is
/// visible from anywhere else in the app, so this is the only place a reader can see what has
/// accumulated in their name, and the only place they can drop it. A source is one row — its
/// posts as the figure, in the type scale's monospaced `reading` role so a column of servers lines
/// up — and entering it opens everything held for it, where it is cleared (`UsageSourceDetail`).
///
/// **The section says what it is, in its header, because the figures under it would otherwise
/// lie.** What is held here outlives a relaunch: the posts are in the store on disk, pictures are
/// kept both in memory and as copies on disk, and emoji names are read again after a day. The
/// header says it is this device's, the footer says what is re-read and what stays, and the
/// readout counts posts in total, by source and by week or month, beside pictures in memory and
/// on disk (#7). The other two drops sit on their own tabs: a window kept from here on, and the
/// copies.
///
/// **Clear empties; it does not remove.** The server stays added and its timeline stays the
/// reader's; what goes is this device's copy, and the pictures are read again as they are wanted.
/// See `ShellPictures`, "What Clear means", for why a row still drawn may put a source straight
/// back and why that is the same answer rather than a hole in it.
///
/// The one thing drawn here that a stranger writes is a **host**, and a host goes through
/// `Host.parse` and is not a post's words. That keeps this pane on the safe side of the branch's
/// emoji-height rule: nothing here hugs text that can carry a custom emoji, and no height here is
/// set by text at all. The day anything routes a display name or a server summary through this
/// pane, it joins the at-risk list and any height assertion on it needs a fixture with an emoji.
struct UsagePane: View {
    @Environment(DummyPrefs.self) private var prefs
    @Environment(\.colorScheme) private var colorScheme

    /// Optional because this pane is reachable without it — a preview, or a test. Where there is
    /// no session there are no sources, and a section listing nothing is not drawn.
    @Environment(ShellSession.self) private var session: ShellSession?

    /// The catalogue store is an actor, and a view body cannot await one. Same shape the row
    /// takes: the view owns a little state and its own `.task` fills it, so nothing here reaches
    /// across an isolation boundary while SwiftUI is asking for a body.
    ///
    /// **Optional, and that is not tidiness.** An empty dictionary would say "no server has a
    /// catalogue", which is a different fact from "nobody has looked yet" — and on the first pass
    /// the second is the true one, because the body always draws before the task can run. Drawing
    /// "No emoji names read yet" beside a server whose 154 names are held is a false statement
    /// that corrects itself a frame later, which is the kind of true-looking lie this whole
    /// section was designed against. Until the first read lands, the line is simply not drawn.
    @State private var catalogues: [String: Reading]?

    /// What a screen needs from a catalogue, and nothing that resolves a shortcode —
    /// `EmojiCatalogue.lookup` is deliberately not public, and copying its three public facts out
    /// is what keeps this pane on the right side of that door.
    struct Reading: Equatable {
        let fetchedAt: Date
        let count: Int
    }

    /// What the catalogue readings are asked again for: a source list that changed, or a Clear.
    ///
    /// **This used to claim nothing else could move them, "because nothing else in this app
    /// fetches a catalogue while this is the page". That was false**, and falsified by
    /// this unit's own header: on iOS compact the pages are tabs and the timeline's tree is alive
    /// behind this one, and on either platform a catalogue commissioned by a join can still be on
    /// the wire when the reader walks here. Neither moves `hosts` or `cleared`, so the reading
    /// would have said "No emoji names held" beside a server whose names landed a second later,
    /// for as long as the pane stayed open.
    ///
    /// What closes it is not a finer `Probe` but `readCatalogues` waiting on the work: see there.
    private struct Probe: Equatable {
        let hosts: [String]
        let cleared: Int
    }

    private var sources: [Source] { session?.sources ?? [] }

    /// What each source's picture copies weigh on disk, by folded host. Optional for the reason
    /// `catalogues` is: until the first read lands, "nothing on disk" would be a guess.
    @State private var onDisk: [String: Int]?

    /// The drop by cache has been pressed and not yet answered for.
    @State private var droppingCopies = false

    /// A narrower window the reader picked and not yet confirmed: it would drop posts, so it asks
    /// first. A wider one, or forever, drops nothing and applies at once.
    @State private var shortening: Int?

    /// The windows offered for keeping, in months. Forever, the default, is offered beside them.
    static let monthChoices = [1, 3, 6, 12]

    /// What this page is for, one tab each (#7): by source, by time, how long, by cache. How long
    /// posts are kept is a tab of its own (#234), so the list by time never shares a page with a
    /// setting.
    enum Purpose: String, CaseIterable, Identifiable, ShellTab {
        case source
        case time
        case keep
        case copies

        var id: Self { self }

        var titleKey: String {
            switch self {
            case .source: "usage.tab.source"
            case .time: "usage.tab.time"
            case .keep: "usage.tab.keep"
            case .copies: "usage.tab.copies"
            }
        }

        var symbol: String {
            switch self {
            case .source: "square.stack.3d.up"
            case .time: "clock"
            case .keep: "hourglass"
            case .copies: "internaldrive"
            }
        }
    }

    var body: some View {
        if let session, session.sources.isEmpty {
            ShellNotice(
                symbol: "chart.bar.xaxis",
                title: L10n.t("usage.empty.title"),
                detail: L10n.t("usage.empty.detail"),
                help: L10n.t("usage.empty.help")
            )
        } else {
            readout
        }
    }

    private var readout: some View {
        Form {
            Section { tabs }
            page
        }
        .formStyle(.grouped)
        // The page's own colour, as on the timeline and Account, and no scroll bar.
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .clearsFloatingCorner()
        .padding(ShellSpace.snug)
        .task(id: Probe(hosts: sources.map(\.host), cleared: session?.cleared ?? 0)) {
            await readCatalogues()
            await readDisk()
        }
        .confirmationDialog(
            Text(L10n.t("prefs.drop.copies.title")),
            isPresented: $droppingCopies,
            titleVisibility: .visible
        ) {
            Button(L10n.t("prefs.drop.confirm"), role: .destructive) {
                session?.dropCopies()
                Task { await readDisk() }
            }
            Button(L10n.t("board.choose.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("prefs.drop.copies.detail"))
        }
        .confirmationDialog(
            Text(shortening.map { L10n.count("prefs.keep.shorten.title", $0) } ?? ""),
            isPresented: Binding(get: { shortening != nil }, set: { if !$0 { shortening = nil } }),
            titleVisibility: .visible,
            presenting: shortening
        ) { months in
            Button(L10n.t("prefs.drop.confirm"), role: .destructive) {
                prefs.keepMonths = months
                shortening = nil
            }
            Button(L10n.t("board.choose.cancel"), role: .cancel) { shortening = nil }
        } message: { _ in
            Text(L10n.t("prefs.keep.shorten.detail"))
        }
    }

    /// The page's tabs (`ShellTabs`). Tab rotates them (`ShellSession.rotateUsageTab`); they sit
    /// in the Form so the grouped chrome is the page's own, not a second colour.
    private var tabs: some View {
        ShellTabs(Purpose.allCases, selected: session?.usagePurpose ?? .source) { session?.usagePurpose = $0 }
    }

    @ViewBuilder
    private var page: some View {
        // **Nothing at all, rather than an empty state, when there is no session.** Falling
        // through to the empty notice would tell a reader who has joined a server to go and add
        // one, with the rail summary pointing them at it. The empty state is for a reader who
        // genuinely has no sources; "the shell has not handed this pane its session" is not that,
        // and this pane must not guess which it is looking at.
        if let session {
            switch session.usagePurpose {
            case .source:
                sources(session)
            case .time:
                breakdown(session)
            case .keep:
                keep
                GoneSection(session: session)
            case .copies:
                copies(session)
            }
        }
    }

    /// The list of sources, or the one the reader entered. A source removed while its detail is
    /// open leaves the list in its place.
    @ViewBuilder
    private func sources(_ session: ShellSession) -> some View {
        if let host = session.usageOpened, let source = session.sources.first(where: { $0.host == host }) {
            UsageSourceDetail(
                session: session, source: source, catalogue: catalogues?[host],
                cataloguesRead: catalogues != nil, onDisk: onDisk
            )
        } else {
            UsageSourceList(session: session, onDisk: onDisk)
        }
    }

    /// The breakdown by week or month (#7): newest first, one line a stretch that holds a post.
    @ViewBuilder
    private func breakdown(_ session: ShellSession) -> some View {
        @Bindable var session = session
        let holdings = session.holdings
        Section {
            Picker(L10n.t("prefs.held.per"), selection: $session.heldPeriod) {
                Text(L10n.t("prefs.held.per.week")).tag(HeldPeriod.week)
                Text(L10n.t("prefs.held.per.month")).tag(HeldPeriod.month)
            }
            .pickerStyle(.segmented)
            // All sources first, in the rows' own shape; where it says none, no stretch follows.
            stretch(
                Text(L10n.t("prefs.held.total")).shellFont(.name).foregroundStyle(ShellChrome.ink(colorScheme)),
                posts: holdings.posts
            )
            ForEach(holdings.byPeriod.prefix(Self.stretchesShown), id: \.start) { bucket in
                stretch(reading(Text(Self.stretchLabel(bucket.start, period: session.heldPeriod))),
                        posts: bucket.posts)
            }
        } header: {
            Text(L10n.t("prefs.held.breakdown"))
        }
    }

    /// One line of the breakdown: what it counts, and its posts at the trailing edge.
    private func stretch(_ label: some View, posts: Int) -> some View {
        HStack {
            label
            Spacer()
            reading(Text(Self.postsLine(posts)))
        }
    }

    /// How many weeks or months the breakdown lists before it stops.
    static let stretchesShown = 12

    /// How long posts are kept (#7, by time). Shortening asks first; Forever and a longer window
    /// drop nothing and apply at once.
    private var keep: some View {
        Section {
            Picker(L10n.t("prefs.keep"), selection: keepSelection) {
                Text(L10n.t("prefs.keep.forever")).tag(Int?.none)
                ForEach(Self.monthChoices, id: \.self) { months in
                    Text(L10n.count("prefs.keep.months", months)).tag(Int?.some(months))
                }
            }
        } header: {
            Text(L10n.t("prefs.keep"))
        }
    }

    /// Picture copies, all sources together, and the drop that takes them (#7, by cache).
    private func copies(_ session: ShellSession) -> some View {
        let memory = Self.memory(session.sources.map(\.host), in: session)
        let disk = onDisk.map { $0.values.reduce(0, +) }
        return Section {
            HStack(spacing: ShellSpace.snug) {
                reading(Text(Self.picturesLine(count: memory.count, bytes: memory.bytes, disk: disk)))
                Spacer(minLength: ShellSpace.snug)
                ShellIconButton("trash", name: "prefs.drop.copies", help: "usage.drop.copies.help", tone: .alarm) {
                    droppingCopies = true
                }
            }
            .padding(.vertical, ShellSpace.tight)
        } header: {
            Text(L10n.t("prefs.held.total"))
        } footer: {
            UsageFooter(line: "usage.drop.line", help: "prefs.drop.footer", about: L10n.t("usage.tab.copies"))
        }
    }

    /// The Keep picker's binding: a window that would drop posts waits on `shortening`'s question;
    /// one that drops nothing is written straight through.
    private var keepSelection: Binding<Int?> {
        Binding(
            get: { prefs.keepMonths },
            set: { months in
                if KeepPolicy.shortens(from: prefs.keepMonths, to: months) {
                    shortening = months
                } else {
                    prefs.keepMonths = months
                }
            }
        )
    }

    static func postsLine(_ count: Int) -> String {
        count == 0 ? L10n.t("prefs.held.posts.none") : L10n.count("prefs.held.posts", count)
    }

    /// A week by the day it starts, a month by its name, both in the shell's language.
    static func stretchLabel(_ start: Date, period: HeldPeriod) -> String {
        switch period {
        case .week:
            String(format: L10n.t("prefs.held.week"),
                   start.formatted(.dateTime.year().month(.abbreviated).day().locale(L10n.locale())))
        case .month:
            start.formatted(.dateTime.year().month(.wide).locale(L10n.locale()))
        }
    }

    /// Pictures in memory, both caches, over `hosts`.
    static func memory(_ hosts: [String], in session: ShellSession) -> (count: Int, bytes: Int) {
        hosts.reduce((0, 0)) { sum, host in
            let shell = session.pictures.holding(host: host)
            let emoji = session.emojis.holding(host: host)
            return (sum.0 + shell.count + emoji.count, sum.1 + shell.bytes + emoji.bytes)
        }
    }

    /// "3 pictures · 1.2 MB in memory · 40 MB on disk", with the disk half left off until it has
    /// been read, and a line of its own where nothing is held in memory.
    static func picturesLine(count: Int, bytes: Int, disk: Int?) -> String {
        var parts = count == 0
            ? [L10n.t("prefs.cache.pictures.none")]
            : [L10n.count("prefs.cache.pictures", count), String(format: L10n.t("prefs.held.memory"), size(bytes))]
        if let disk { parts.append(String(format: L10n.t("prefs.held.disk"), size(disk))) }
        return parts.joined(separator: " · ")
    }

    /// One source's pictures, both caches in one figure — the reader was promised the pictures
    /// this server's posts are drawn with, not which cache an avatar and a `:blobcat:` live in.
    /// Read off **this session's** caches, so the figure and Clear are about the same objects.
    static func picturesLine(_ source: Source, in session: ShellSession, onDisk: [String: Int]?) -> String {
        let memory = memory([source.host], in: session)
        return picturesLine(
            count: memory.count, bytes: memory.bytes, disk: onDisk.map { $0[source.host.lowercased()] ?? 0 }
        )
    }

    static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(L10n.locale()))
    }

    private func reading(_ text: Text) -> some View {
        text
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
    }

    /// Reads each source's catalogue, **waiting first on a fetch already on its way for it**.
    ///
    /// The wait is what makes this reading true rather than true-at-the-instant-it-ran. A
    /// catalogue is commissioned by the join and lands whenever the server answers — a big
    /// instance's is the largest of the four answers it sends — so it can easily still be on the
    /// wire when the reader walks to this pane, and nothing here would ever look again. `settle`
    /// on a host with nothing in flight is not a wait, so this costs nothing in the ordinary
    /// case; and it cannot hang the pane, because the fetch it waits on is the one the join
    /// already started and its failure is dropped rather than thrown.
    private func readCatalogues() async {
        guard let session else { return }
        var next: [String: Reading] = [:]
        for source in session.sources {
            await session.emoji.settle(host: source.host)
            guard let held = await session.emoji.catalogue(host: source.host) else { continue }
            next[source.host] = Reading(fetchedAt: held.fetchedAt, count: held.count)
        }
        catalogues = next
    }

    /// Reads what each source's copies weigh on disk, off the main actor (#7).
    private func readDisk() async {
        guard let session else { return }
        onDisk = await session.pictures.diskBytes(hosts: session.sources.map(\.host))
    }
}
