import FediqoCore
import SwiftUI

/// What this device is holding from each server the reader added (#21). Preferences keeps what a
/// person chooses; this page keeps what this device holds.
///
/// Tabbed by purpose (#7): by source, by time, by cache. The cache section is decision 14's
/// screen. Three caches hold a server's copy between them and
/// none of them is visible from anywhere else in the app, so this is the only place a reader can
/// see what has accumulated in their name, and the only place they can drop it. Each row is an
/// instrument readout rather than a storage-management control: the host, two figures in the type
/// scale's monospaced `reading` role so a column of servers lines up and a fall to zero reads as
/// the column moving, and one button.
///
/// **The section says what it is, in its header, because the figures under it would otherwise
/// lie.** What is held here outlives a relaunch: the posts are in the store on disk, pictures are
/// kept both in memory and as copies on disk, and emoji names are read again after a day. The
/// header says it is this device's, the footer says what is re-read and what stays, and the
/// readout counts posts in total, by source and by week or month, beside pictures in memory and
/// on disk (#7). The other two drops sit on their own tabs: by time, as a window kept from here
/// on, and by cache.
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
    private struct Reading: Equatable {
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

    /// What this page is for, one tab each (#7): by source, by time, by cache.
    enum Purpose: String, CaseIterable, Identifiable {
        case source
        case time
        case copies

        var id: Self { self }

        var titleKey: String {
            switch self {
            case .source: "usage.tab.source"
            case .time: "usage.tab.time"
            case .copies: "usage.tab.copies"
            }
        }
    }

    var body: some View {
        if let session, session.sources.isEmpty {
            ShellNotice(
                symbol: "chart.bar.xaxis",
                title: L10n.t("usage.empty.title"),
                detail: L10n.t("usage.empty.detail")
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

    /// The same pills the timeline uses for All and Trends: one selected, the rest a well.
    /// Tab rotates them (`ShellSession.rotateUsageTab`); they sit in the Form so the grouped
    /// chrome is the page's own, not a second colour.
    private var tabs: some View {
        HStack(spacing: ShellSpace.tight) {
            ForEach(Purpose.allCases) { tab in
                let selected = tab == (session?.usagePurpose ?? .source)
                Button {
                    session?.usagePurpose = tab
                } label: {
                    Text(L10n.t(tab.titleKey))
                        .lineLimit(1)
                        .fixedSize()
                        .shellFont(.meta, weight: selected ? .semibold : .regular)
                        .foregroundStyle(
                            selected
                                ? ShellChrome.selectInk(colorScheme)
                                : ShellChrome.inkDim(colorScheme)
                        )
                        .padding(.horizontal, ShellSpace.snug)
                        .padding(.vertical, ShellSpace.tight)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    selected
                                        ? ShellChrome.selectFill(colorScheme)
                                        : ShellChrome.well(colorScheme)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
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
                section(session, holdings: session.holdings)
            case .time:
                breakdown(session)
                keep
                GoneSection(session: session)
            case .copies:
                copies(session)
            }
        }
    }

    /// Takes the session rather than reading the optional again, so that everything below it is
    /// written against a session that exists. The nil case is decided once, above.
    @ViewBuilder
    private func section(_ session: ShellSession, holdings: Holdings) -> some View {
        Section {
            totals(session, holdings: holdings)
            ForEach(session.sources) { source in row(source, in: session, holdings: holdings) }
        } header: {
            Text(L10n.t("prefs.cache"))
        } footer: {
            Text(L10n.t("prefs.cache.footer"))
                .shellFont(.mark)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
    }

    /// Everything held, all sources together: posts, and pictures in memory and on disk.
    private func totals(_ session: ShellSession, holdings: Holdings) -> some View {
        let memory = Self.memory(session.sources.map(\.host), in: session)
        let disk = onDisk.map { $0.values.reduce(0, +) }
        return VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(L10n.t("prefs.held.total"))
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            reading(Text(Self.postsLine(holdings.posts)))
            reading(Self.picturesText(count: memory.count, bytes: memory.bytes, disk: disk))
        }
        .padding(.vertical, ShellSpace.tight)
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
            if holdings.byPeriod.isEmpty {
                reading(Text(L10n.t("prefs.held.posts.none")))
            } else {
                ForEach(holdings.byPeriod.prefix(Self.stretchesShown), id: \.start) { bucket in
                    HStack {
                        reading(Text(Self.stretchLabel(bucket.start, period: session.heldPeriod)))
                        Spacer()
                        reading(Text(Self.postsLine(bucket.posts)))
                    }
                }
            }
        } header: {
            Text(L10n.t("prefs.held.breakdown"))
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
            reading(Self.picturesText(count: memory.count, bytes: memory.bytes, disk: disk))
                .padding(.vertical, ShellSpace.tight)
            Button(L10n.t("prefs.drop.copies")) { droppingCopies = true }
        } footer: {
            Text(L10n.t("prefs.drop.footer"))
                .shellFont(.mark)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
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
    static func picturesText(count: Int, bytes: Int, disk: Int?) -> Text {
        var text = count == 0
            ? Text(L10n.t("prefs.cache.pictures.none"))
            : Text(L10n.count("prefs.cache.pictures", count))
                + Text(verbatim: " · ")
                + Text(String(format: L10n.t("prefs.held.memory"), Self.size(bytes)))
        if let disk {
            text = text + Text(verbatim: " · ") + Text(String(format: L10n.t("prefs.held.disk"), Self.size(disk)))
        }
        return text
    }

    static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(L10n.locale()))
    }

    private func row(_ source: Source, in session: ShellSession, holdings: Holdings) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(source.host)
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                catalogueLine(for: source)
                reading(Text(Self.postsLine(holdings.posts(host: source.host))))
                pictureLine(source, in: session)
                postLine(source, in: session)
                passwordLine(source, in: session)
            }
            Spacer(minLength: ShellSpace.snug)
            // No `.accessibilityElement(children: .ignore)` on the row around it. A container
            // collapsed to one element swallows the button's activation, and this branch has
            // shipped that defect twice — announcing a control that does nothing, and leaving a
            // reader with no keyboard no way to act at all.
            //
            // **Asks, rather than fires** (decision 29). `prefs.cache.clear` is one word for one
            // call reached from two questions, so a Clear that confirms on Account and empties
            // straight away here would be the same word doing two different things two panes
            // apart. One presenter, on `FediqoRootView`, driven by `session.clearing`.
            //
            // This pane already draws `passwordLine`, so a reader here has been told a password is
            // held before they press. The dialog is not redundant even so: it names the sign-out
            // as well, and the two entrances must not diverge.
            Button(L10n.t("prefs.cache.clear")) {
                session.clearing = source.host
            }
            .accessibilityLabel(
                Text(String(format: L10n.t("prefs.cache.clear.label"), source.host))
            )
        }
        .padding(.vertical, ShellSpace.tight)
    }

    /// How many names this server registered and when they were read. The relative date is a
    /// `Text` format rather than a formatted `String` so it follows the locale the shell is set
    /// to, which is the reader's preference and not the device's.
    @ViewBuilder
    private func catalogueLine(for source: Source) -> some View {
        if let catalogues {
            if let held = catalogues[source.host] {
                reading(
                    Text(String(format: L10n.t("prefs.cache.catalogue"), held.count))
                        + Text(verbatim: " ")
                        + Text(held.fetchedAt, format: .relative(presentation: .named))
                )
            } else {
                reading(Text(L10n.t("prefs.cache.catalogue.none")))
            }
        }
    }

    /// Both picture caches in one figure, because the reader was promised one thing: the pictures
    /// this server's posts are drawn with. Which cache an avatar and a `:blobcat:` happen to live
    /// in is this app's business and not theirs.
    ///
    /// Read off **this session's** caches rather than off `.shared`, so the figures and the
    /// button beside them are answers about the same two objects — see `ShellSession.pictures`.
    private func pictureLine(_ source: Source, in session: ShellSession) -> some View {
        let memory = Self.memory([source.host], in: session)
        return reading(Self.picturesText(
            count: memory.count, bytes: memory.bytes, disk: onDisk.map { $0[source.host.lowercased()] ?? 0 }
        ))
    }

    /// The forum posts this device is holding from this server — D30's cache, in the inventory.
    ///
    /// **This run's cache, which Clear empties.** An opening post kept with its row (#154) is part
    /// of the row, and a Clear keeps the rows, so it is not counted here: the figure is what the
    /// button beside it lets go of.
    ///
    /// **Drawn only for a forum**, which is the one place this cache can ever hold anything: a
    /// `tid` is Discuz!'s number and `ForumThreadRef` refuses everything else, so a line under
    /// `first.example` reading "no first posts held" would be a true sentence about a thing
    /// that was never possible. Every other line in this row is about something every source can
    /// have.
    ///
    /// Read off **this session's** cache, for the reason `pictureLine` is: the figure and the
    /// button beside it have to be answers about the same object.
    @ViewBuilder
    private func postLine(_ source: Source, in session: ShellSession) -> some View {
        if source.kind == .discuz {
            let held = session.posts.holding(host: source.host)
            if held.count == 0 {
                reading(Text(L10n.t("prefs.cache.posts.none")))
            } else {
                reading(
                    Text(L10n.count("prefs.cache.posts", held.count))
                        + Text(verbatim: " · ")
                        + Text(Self.size(held.bytes))
                )
            }
        }
    }

    /// Whether a password is being held for this server, and a way to stop holding it.
    ///
    /// **Drawn before the Clear beside it is pressed, and that is the point.** Clear now takes
    /// the saved password with everything else (D25), which is a heavier thing than "empties the
    /// cache" — so the row says a password is here *before* the press, and offers a Forget of its
    /// own for the reader who wants only that and would like to keep their pictures.
    ///
    /// Read off `savedHosts`, which the session holds, rather than off the Keychain: a body runs
    /// whenever anything it touches moves, and a Keychain lookup per row per frame is a trip into
    /// another process to draw one line.
    @ViewBuilder
    private func passwordLine(_ source: Source, in session: ShellSession) -> some View {
        if session.forums.hasPassword(host: source.host) {
            HStack(spacing: ShellSpace.snug) {
                reading(Text(L10n.t("prefs.password.held")))
                Button(L10n.t("prefs.password.forget")) {
                    session.forums.forgetPassword(host: source.host)
                }
                .shellFont(.mark)
                .buttonStyle(.plain)
                .foregroundStyle(ShellChrome.phosphor(colorScheme))
                .accessibilityLabel(
                    Text(String(format: L10n.t("prefs.password.forget.label"), source.host))
                )
            }
        }
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
