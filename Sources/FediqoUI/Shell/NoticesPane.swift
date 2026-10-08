import FediqoCore
import SwiftUI

/// The notices place (#323): what every signed-in source says happened to the person, one line a
/// notice, newest first, each saying its source.
///
/// **It reads only when asked.** The page reads when it opens and when it is asked to — its
/// reload mark, `r`, a pull — and reads on at its foot. What a line opens is the root's, because
/// the walk is: a post opens in its conversation on the timeline place, and leaving that comes
/// back here.
///
/// **What can be done is behind three dots, and asked first** (`NoticeActs`): a line's own —
/// dismissing it — the head's, which dismisses all a source has, and a held-back request's.
/// One asker on the page puts every such question (`ShellNoticeActs.asked`). **At its yes
/// the line, or the request, leaves the page**; where its source then says no it is drawn
/// again where it was, and the strip at the foot of every page says so (`SaidStrip`) — this
/// page's own sentences above the list are for its ask and its reading of requests.
///
/// **What it says before any line**, in this order: that nobody is signed in to a source that
/// has notices, and what would make the page fill; that somebody is, and no sign-in may read
/// them; and then the lines, with what each source has to say above them — on the wire, failed,
/// never asked, asked and refused.
struct NoticesPane: View {
    let session: ShellSession
    /// The line the lamp is on, with a keyboard or a pointer. Held by the app, where `j`, `k`
    /// and `Return` are read.
    @Binding var selectedID: String?
    /// The line being read, under a finger. This page's own, and not the timeline's.
    let mark: ShellReadingMark
    /// Whether there is anybody to read again, and the read: what `r` asks and does.
    var canReload: Bool
    var onReload: () -> Void
    /// A press that opens a line, answered by the root.
    var onOpen: (Notice) -> Void
    var onOpenPerson: (DummyPerson, Notice) -> Void
    /// The line whose post could not be opened, being older than this device keeps.
    var tooOld: String?
    var jumpToTop: Int = 0

    @Environment(DummyPrefs.self) private var prefs
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellTouch) private var touch
    @Environment(\.shellPlaceIsActive) private var active
    @Environment(\.shellNoticesProbe) private var probe
    /// When the reload mark was last pressed to begin a read. See `ReloadMark.stops`.
    @State private var reloadPressed: Date?
    /// Whether the page has read since it opened: a source that may be asked and has neither
    /// answered nor failed after that was left unread by a read that was stopped, and is named.
    @State private var began = false
    @State private var hand = NoticeHand()

    private var list: ShellNoticeList { session.noticeList }
    private var acts: ShellNoticeActs { session.noticeList.acts }

    /// The question a menu on this page put, or `d` did: held by the session's acts.
    private var asked: Binding<ShellMoreAsk?> {
        Binding(get: { session.noticeList.acts.asked }, set: { session.noticeList.acts.asked = $0 })
    }

    /// The signed-in sources of a kind that has notices, and where each sign-in stands. A source
    /// of any other kind is never asked and never named here.
    static func hosts(in session: ShellSession) -> [(host: String, notices: NoticeStanding)] {
        let signedIn = session.mastodon.signedInHosts
        return session.sources
            .filter { $0.kind.offers.notices && signedIn.contains($0.host.lowercased()) }
            .map { ($0.host.lowercased(), session.mastodon.notices(host: $0.host)) }
            .sorted { $0.0 < $1.0 }
    }

    /// The sources that may be asked and have neither answered nor failed, with nobody on the
    /// wire for them: a read stopped before they did. Nothing before the page has read at all.
    static func unread(in session: ShellSession, began: Bool) -> [String] {
        unread(among: hosts(in: session), in: session, began: began)
    }

    /// `unread(in:began:)` of `hosts` already worked out (`hosts(in:)`): a draw works them out
    /// once, and asks each of these with them.
    static func unread(
        among hosts: [(host: String, notices: NoticeStanding)], in session: ShellSession, began: Bool
    ) -> [String] {
        guard began else { return [] }
        let list = session.noticeList
        return hosts.filter { $0.notices == .allowed }.map(\.host).filter { host in
            list.standing(host: host) == .unread && !list.locked.contains(host)
        }
    }

    /// What is said above the lines now. `began` is whether the page has read since it opened.
    static func lines(in session: ShellSession, began: Bool = true) -> [NoticesLine] {
        let hosts = hosts(in: session)
        return lines(hosts: hosts, unread: unread(among: hosts, in: session, began: began), in: session)
    }

    static func lines(
        hosts: [(host: String, notices: NoticeStanding)], unread: [String], in session: ShellSession
    ) -> [NoticesLine] {
        let list = session.noticeList
        return NoticesLine.lines(
            reading: list.readingHosts.filter { list.reaches[$0]?.readingOn != true },
            failures: list.failures,
            askable: Set(list.reaches.filter(\.value.askable).keys),
            hosts: hosts,
            locked: list.locked,
            unread: unread,
            full: list.fullHosts
        )
    }

    /// What stands under the last line now.
    static func foot(in session: ShellSession) -> NoticesFoot {
        let list = session.noticeList
        return NoticesFoot.foot(
            hasMore: list.hasMore(in: session),
            isReading: list.readingHosts.contains { list.reaches[$0]?.readingOn == true },
            floor: list.floor, full: list.isFull
        )
    }

    /// What is said where no line is drawn now.
    static func none(in session: ShellSession, began: Bool = true) -> NoticesNone {
        none(unread: unread(in: session, began: began), in: session)
    }

    static func none(unread: [String], in session: ShellSession) -> NoticesNone {
        let list = session.noticeList
        return NoticesNone.none(
            isReading: list.isReading, held: list.lines.count,
            said: !list.failures.isEmpty || !list.locked.isEmpty,
            answered: list.reaches.values.contains(where: \.answered),
            unread: !unread.isEmpty
        )
    }

    /// When the page reads without being asked: as it opens, and again where a source may be
    /// asked that could not be when it opened.
    private struct Opening: Hashable {
        let active: Bool
        let asked: [String]
    }

    var body: some View {
        let hosts = Self.hosts(in: session)
        VStack(alignment: .leading, spacing: 0) {
            switch NoticesStanding.standing(hosts, held: !list.reaches.isEmpty) {
            case .nobody:
                ShellNotice(
                    symbol: "bell",
                    title: L10n.t("notices.empty.title"),
                    detail: L10n.t("notices.empty.line"),
                    help: L10n.t("notices.empty.detail")
                )
                .modifier(NoticesProbed(.nobody, says: L10n.t("notices.empty.line"), probe: probe))
            case .notAllowed(let unasked, _):
                notAllowed(unasked: unasked, hosts: hosts)
            case .list:
                head(hosts)
                    .modifier(NoticesProbed(.head, says: NoticeWords.narrowed(prefs.noticesHidden), probe: probe))
                ShellRule()
                listed(hosts)
            }
        }
        .task(id: Opening(active: active, asked: hosts.filter { $0.notices == .allowed }.map(\.host))) {
            guard active else { return }
            began = true
            await acts.readPage(in: session)
        }
        .modifier(ShellMoreAsks(asked: asked))
    }

    // MARK: - Nobody may read notices

    /// What the page says where somebody is signed in and no sign-in may read notices. Which
    /// source is which is said under it, a line each.
    static func notAllowedWords(
        unasked: [String], language: DummyLanguage? = nil
    ) -> (title: String, line: String, help: String) {
        guard !unasked.isEmpty else {
            return (
                L10n.t("notices.refused.title", language: language),
                L10n.t("notices.refused.line", language: language),
                L10n.t("notices.refused.detail", language: language)
            )
        }
        return (
            L10n.t("notices.unasked.title", language: language),
            L10n.t("notices.unasked.line", language: language),
            L10n.t("notices.unasked.detail", language: language)
        )
    }

    /// **Every signed-in source is named with what is true of it** — not asked yet, or asked
    /// and gave none — whichever of the two the page's own sentence is about.
    private func notAllowed(unasked: [String], hosts: [(host: String, notices: NoticeStanding)]) -> some View {
        let words = Self.notAllowedWords(unasked: unasked)
        return VStack(alignment: .leading, spacing: 0) {
            ShellNotice(symbol: "bell", title: words.title, detail: words.line, fills: false, help: words.help)
                .modifier(NoticesProbed(.notAllowed, says: words.line, probe: probe))
            ForEach(NoticesLine.lines(reading: [], failures: [], askable: [], hosts: hosts)) { line in
                ShellRule()
                sourceLine(line)
            }
            // What the ask itself came to: the first one failing leaves the page here, with
            // no list to say it above.
            ForEach(Self.said(in: session), id: \.host) { said in
                ShellRule()
                wordLine(said.words, part: .said(said.host), ink: ShellChrome.ink(colorScheme))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - The head

    /// The place's name, what the choice of kinds leaves out, and the marks: the kinds shown,
    /// the read, and `…` where a source may be read. On the trailing edge, where a timeline keeps its search and reload.
    ///
    /// **Nothing here is cut short.** Where the line has no room for the words about the kinds
    /// they go — the mark beside them is lit while any kind is left out, and says how many —
    /// and where it has no room for the name beside the marks, the marks stand under it.
    private func head(_ hosts: [(host: String, notices: NoticeStanding)]) -> some View {
        // Made once a draw, and stood in whichever of the three fits.
        let marks = marks(hosts)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: ShellSpace.step) {
                title
                kindsWords
                Spacer(minLength: 0)
                marks
            }
            HStack(alignment: .center, spacing: ShellSpace.step) {
                title
                Spacer(minLength: 0)
                marks
            }
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                title
                HStack(spacing: ShellSpace.step) {
                    Spacer(minLength: 0)
                    marks
                }
            }
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.top, ShellSpace.step)
        .padding(.bottom, ShellSpace.snug)
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        Text(ShellPlace.notices.title)
            .shellFont(.name)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
            .modifier(NoticesProbed(.title, probe: probe))
    }

    private var kindsWords: some View {
        Text(NoticeWords.narrowed(prefs.noticesHidden))
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .fixedSize()
            .modifier(NoticesProbed(.kindsWords, probe: probe))
    }

    private func marks(_ hosts: [(host: String, notices: NoticeStanding)]) -> some View {
        let more = NoticeActs.more(in: session, among: hosts)
        return HStack(spacing: ShellSpace.step) {
            NoticeKindsMenu(kinds: NoticeWords.narrowable(held: list.lines, hidden: prefs.noticesHidden), prefs: prefs)
                .modifier(NoticesProbed(.kindsMark, probe: probe))
            reloadMark
                .modifier(NoticesProbed(.reloadMark, probe: probe))
            if let more {
                ShellMoreButton(label: ShellMore.label(), asks: asked, more: { more })
                    .modifier(NoticesProbed(.moreMark, probe: probe))
            }
        }
        .fixedSize()
    }

    /// `r`'s mark, and Stop in its place while a read is on the wire — a timeline's own mark
    /// and rule (`ReloadMark`), under this page's names for the two.
    @ViewBuilder
    private var reloadMark: some View {
        if let shown = ReloadMark.shown(canReload: canReload, stoppable: list.isReading) {
            ShellIconButton(shown.symbol, name: Self.reloadName(shown)) {
                switch shown {
                case .reload:
                    reloadPressed = Date()
                    onReload()
                case .stop:
                    guard ReloadMark.stops(at: Date(), pressedAt: reloadPressed) else { return }
                    list.stop()
                }
            }
        }
    }

    static func reloadName(_ mark: ReloadMark) -> String {
        switch mark {
        case .reload: "notices.reload"
        case .stop: "notices.reload.stop"
        }
    }

    // MARK: - The lines

    @ViewBuilder
    private func listed(_ hosts: [(host: String, notices: NoticeStanding)]) -> some View {
        let shown = list.shown(hiding: prefs.noticesHidden)
        let unread = Self.unread(among: hosts, in: session, began: began)
        ForEach(Self.lines(hosts: hosts, unread: unread, in: session)) { line in
            sourceLine(line)
            ShellRule()
        }
        ForEach(Self.said(in: session), id: \.host) { said in
            wordLine(said.words, part: .said(said.host), ink: ShellChrome.ink(colorScheme))
            ShellRule()
        }
        ForEach(acts.onItsWay) { request in
            wordLine(NoticeActs.onItsWay(request), part: .onWay(request.id), ink: ShellChrome.inkDim(colorScheme))
            ShellRule()
        }
        let holders = acts.shownHolders
        ForEach(holders, id: \.self) { host in
            if let held = acts.shownHeld(host: host) {
                NoticeHeldLine(host: host, held: held, open: acts.opened.contains(host)) { toggleHeld(host) }
                ShellRule()
            }
        }
        let open = holders.filter { acts.opened.contains($0) }
        if !shown.isEmpty {
            rows(shown, holding: open)
        } else if open.isEmpty {
            none(unread)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heldBack(open)
                    noneWords(unread)
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// What the page has to say of itself, by source, in host order: an ask for notices, or
    /// a reading of what is held back, that came to nothing (`ShellNoticeActs.said`).
    static func said(in session: ShellSession, language: DummyLanguage? = nil) -> [(host: String, words: String)] {
        session.noticeList.acts.said.sorted { $0.key < $1.key }.map {
            ($0.key, NoticeActs.words($0.value, host: $0.key, language: language))
        }
    }

    /// One sentence above the lines, whole: wrapped where the page is narrow, never cut.
    private func wordLine(_ words: String, part: NoticesProbe.Part, ink: Color) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(NoticesProbed(part, says: words, probe: probe))
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
    }

    /// The press on a source's held-back line: opens it, reading what it holds, or closes it.
    func toggleHeld(_ host: String) {
        if acts.opened.contains(host) {
            acts.close(host: host)
        } else {
            Task { await acts.open(host: host, in: session) }
        }
    }

    /// What the opened sources hold back, a row a person: at the head of what scrolls, so a
    /// long list of them never pushes the notices off the page.
    @ViewBuilder
    private func heldBack(_ hosts: [String]) -> some View {
        ForEach(hosts, id: \.self) { host in
            let listed = acts.listed(host: host)
            if listed.isEmpty, acts.readingRequests.contains(host) {
                wordLine(
                    String(format: L10n.t("notices.held.reading"), host), part: .heldReading(host),
                    ink: ShellChrome.inkFaint(colorScheme)
                )
                ShellRule()
            }
            ForEach(listed) { request in
                NoticeRequestRow(request: request, more: { NoticeActs.more(request, in: session) }, asks: asked)
                ShellRule()
            }
            // The source counts more people than it listed — or listed nobody at all: said,
            // so an opened line never stands over nothing.
            if let held = acts.shownHeld(host: host), acts.requests[host] != nil, held.requests > listed.count,
               !acts.readingRequests.contains(host) {
                wordLine(
                    String(format: L10n.t(listed.isEmpty ? "notices.held.none" : "notices.held.partial"), host),
                    part: .heldPartial(host), ink: ShellChrome.inkFaint(colorScheme)
                )
                ShellRule()
            }
        }
    }

    /// One source's word above the lines: where the answer would have been, as a tag's page
    /// says an ask that is on its way or failed.
    ///
    /// On one line with its press where both fit whole; the press under the words where they
    /// do not, and the words wrapped. Neither is cut.
    private func sourceLine(_ line: NoticesLine) -> some View {
        let words = line.words(touch: touch)
        return WordsThenPress(words: lineWords(words, of: line), press: linePress(line))
            .modifier(NoticesProbed(.line(line.id), says: words, probe: probe))
    }

    private func lineWords(_ words: String, of line: NoticesLine) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(Self.standsOut(line) ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme))
            .modifier(NoticesProbed(.lineWords(line.id), probe: probe))
    }

    /// What is pressed beside a source's word. **Asking a failed source again waits for the
    /// read on the wire**, and says so: the list takes one read at a time, and a press that
    /// did nothing would say nothing.
    @ViewBuilder
    private func linePress(_ line: NoticesLine) -> some View {
        switch line {
        case .failed(let host, _, true):
            let waits = list.isReading
            ShellLinkButton(L10n.t("notices.retry")) { retry(host) }
                .disabled(waits)
                .opacity(waits ? Self.waiting : 1)
                .help(Self.retryHint(waits: waits))
                .accessibilityHint(Self.retryHint(waits: waits))
                .fixedSize()
                .modifier(NoticesProbed(.linePress(line.id), says: Self.retryHint(waits: waits), probe: probe))
        case .unasked(let host):
            NoticeAskSlot(host: host, session: session)
        case .reading, .failed, .refused, .locked, .unread, .full:
            EmptyView()
        }
    }

    /// How a press that waits is drawn: there, and not to be pressed yet.
    static let waiting: Double = 0.4

    /// Why asking again waits, or nothing where it does not.
    static func retryHint(waits: Bool, language: DummyLanguage? = nil) -> String {
        waits ? L10n.t("notices.retry.waits", language: language) : ""
    }

    static func isFailure(_ line: NoticesLine) -> Bool {
        if case .failed = line { true } else { false }
    }

    /// Whether a line is drawn in the page's full ink: a failure, and a source whose older
    /// notices are not shown — each says something is missing from the list under it.
    static func standsOut(_ line: NoticesLine) -> Bool {
        switch line {
        case .failed, .full: true
        case .reading, .unasked, .refused, .locked, .unread: false
        }
    }

    /// The press beside a source named as failed.
    func retry(_ host: String) {
        Task { await list.retry(host: host, in: session) }
    }

    /// The foot pressed: the next, older stretch.
    func readOn() {
        Task { await list.readOn(in: session) }
    }

    /// A scroll of the person's own hand ended with the foot brought into view.
    private func arrivedAtFoot() {
        guard Self.foot(in: session) == .more else { return }
        readOn()
    }

    @ViewBuilder
    private func none(_ unread: [String]) -> some View {
        noneWords(unread)
        Spacer(minLength: 0)
    }

    @ViewBuilder
    private func noneWords(_ unread: [String]) -> some View {
        let said = Self.none(unread: unread, in: session)
        if let words = said.words(older: Self.foot(in: session) == .more) {
            Text(words)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(ShellSpace.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NoticesProbed(.none, says: words, probe: probe))
        }
        // Lines held and all of a kind left out: older ones may be of a kind shown, and
        // reading on to them is a press — nothing here reads by itself.
        if case .narrowed = said { foot }
    }

    private var foot: some View {
        let foot = Self.foot(in: session)
        return NoticesFootRow(foot: foot, hand: hand, onPress: readOn)
            .modifier(NoticesProbed(.foot, says: foot.words(), probe: probe))
    }

    private func rows(_ shown: [Notice], holding open: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    heldBack(open)
                    ForEach(shown) { notice in
                        VStack(alignment: .leading, spacing: 0) {
                            row(notice)
                            ShellRule()
                        }
                        .id(notice.id)
                    }
                    foot
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            // Pulled down from its top, the page reads again as its reload mark reads it.
            .modifier(PullsToReload(offered: { canReload }, reload: {}, settled: { await acts.readPage(in: session) }))
            .clearsFloatingCorner()
            .modifier(KeepsNoticeMark(mark: mark, hand: hand, shown: shown.count, onArrive: arrivedAtFoot))
            .modifier(NoticeListPlace(
                proxy: proxy, ids: shown.map(\.id), leaving: list.leftAtYes, selectedID: $selectedID, mark: mark,
                touch: touch, jumpToTop: jumpToTop
            ))
        }
    }

    /// Under a finger the row is lit by its own share of the reading mark (#303).
    private func row(_ notice: Notice) -> some View {
        ReadRow(lamp: mark.lamp(for: notice.id), touch: touch, selected: notice.id == selectedID) { lit in
            NoticeRow(
                notice: notice,
                selected: lit,
                tooOld: notice.id == tooOld,
                onPress: { press(notice) },
                onOpen: NoticeWords.opens(notice) == .nothing ? nil : { onOpen(notice) },
                onOpenPerson: { onOpenPerson($0, notice) },
                heard: heard(notice.id),
                menu: NoticeRow.Menu(more: { NoticeActs.more(notice, in: session) }, asks: asked)
            )
        }
        .modifier(NoticesProbed(.row(notice.id), probe: probe))
    }

    /// Where a row tells a probe what it told a listener: the label it set, and not a second
    /// working out of it.
    private func heard(_ id: String) -> ((String) -> Void)? {
        guard let probe else { return nil }
        return { probe.says[.row(id)] = $0 }
    }

    /// A press on a line: the lamp, and on the line the lamp is already on, the opening — one
    /// press under a finger (`DummyCommand.tapped`). A line that opens nothing is only lit.
    func press(_ notice: Notice) {
        switch Self.pressed(notice, selected: selectedID, touch: touch) {
        case .select: selectedID = notice.id
        case .open: onOpen(notice)
        case nil: break
        }
    }

    static func pressed(_ notice: Notice, selected: String?, touch: Bool) -> DummyRowTap? {
        let tap = DummyCommand.tapped(notice.id, selected: selected, touch: touch)
        guard tap == .open, NoticeWords.opens(notice) == .nothing else { return tap }
        return nil
    }

    /// Where the lamp stands once the lines drawn have changed from `was` to `now`.
    ///
    /// **A lit line the person dismissed hands the lamp to the line that takes its place** —
    /// the next one down still drawn, or the one above where it was the last — so `d` and its
    /// yes, again and again, walk down the list and never drop the keys back to the top. A lit
    /// line that left any other way — the choice of kinds took it, or its source did — is not
    /// the lamp's, and nothing is lit. **A line drawn again does not take the lamp back**: its
    /// source said no after the person had moved on, and the strip says so.
    static func lamp(_ selected: String?, was: [String], now: [String], leaving: (String) -> Bool) -> String? {
        guard let selected, !now.contains(selected) else { return selected }
        guard leaving(selected), let at = was.firstIndex(of: selected) else { return nil }
        let drawn = Set(now)
        return was[(at + 1)...].first(where: drawn.contains) ?? was[..<at].last(where: drawn.contains)
    }
}

/// Words and the press beside them, above the list: on one line where both fit whole, the press
/// under the words where they do not, and the words wrapped. Neither is cut.
struct WordsThenPress<Words: View, Press: View>: View {
    let words: Words
    let press: Press

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                words.fixedSize()
                Spacer(minLength: 0)
                press
            }
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                words
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                press
            }
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
    }
}

/// The press that asks one source for notices, beside the line that names it as not asked.
///
/// **It only raises the question** (`ShellSession.askForNotices`): what more will be asked is
/// said there, before the source's own page opens, and nothing is sent until its yes.
struct NoticeAskSlot: View {
    let host: String
    let session: ShellSession
    @Environment(\.shellNoticesProbe) private var probe

    /// The glyph before the press's word: the one a source's row draws where its sign-in must
    /// be asked again (`SourceRow.permissionSymbol`). **The same glyph because it is the same
    /// errand** — asking a sign-in already held for more, with nobody signed out — so the
    /// reader who met it on a source knows it here, and the reverse.
    static let symbol = SourceRow.permissionSymbol

    /// What the press is called to a listener, who hears it apart from the line beside it.
    static func spoken(_ host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("notices.ask.press.spoken", language: language), host)
    }

    var body: some View {
        let spoken = Self.spoken(host)
        ShellLinkButton(L10n.t("notices.ask.press"), symbol: Self.symbol) { session.askForNotices(host: host) }
            .accessibilityLabel(spoken)
            .help(spoken)
            .fixedSize()
            .modifier(NoticesProbed(.linePress("unasked:" + host), says: spoken, probe: probe))
    }
}

/// The kinds of notice shown, chosen behind one mark in the page's head: a menu, as a row keeps
/// its further acts behind three dots.
///
/// The choice is `DummyPrefs.noticesHidden` and nothing else — only what is drawn is narrowed,
/// and no source is asked anything for it.
struct NoticeKindsMenu: View {
    let kinds: [String]
    @Bindable var prefs: DummyPrefs
    @Environment(\.colorScheme) private var colorScheme

    static let symbol = "line.3.horizontal.decrease"

    var body: some View {
        Menu {
            ForEach(kinds, id: \.self) { kind in
                Toggle(NoticeWords.kindName(kind), isOn: shown(kind))
            }
            if !prefs.noticesHidden.isEmpty {
                Divider()
                Button(L10n.t("notices.kinds.showAll"), action: showAll)
            }
        } label: {
            Image(systemName: Self.symbol)
                .foregroundStyle(
                    prefs.noticesHidden.isEmpty ? ShellChrome.inkDim(colorScheme) : ShellChrome.selectInk(colorScheme)
                )
                .modifier(ShellGlyphBox())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .shellNamed("notices.kinds")
        .accessibilityValue(NoticeWords.narrowed(prefs.noticesHidden))
    }

    private func shown(_ kind: String) -> Binding<Bool> {
        Binding(
            get: { !prefs.noticesHidden.contains(kind) },
            set: { prefs.noticesHidden = Self.choosing(kind, shown: $0, among: prefs.noticesHidden) }
        )
    }

    private func showAll() {
        prefs.noticesHidden = []
    }

    /// What is left out once `kind` is shown or is not.
    static func choosing(_ kind: String, shown: Bool, among hidden: Set<String>) -> Set<String> {
        shown ? hidden.subtracting([kind]) : hidden.union([kind])
    }
}

/// What stands under the last line: older notices to reach, a stretch on its way, where the list
/// is held, or its end — said where the list ends, as a timeline says what remains at its place.
struct NoticesFootRow: View {
    let foot: NoticesFoot
    /// Told whether the foot is in view: what a hand's scroll is weighed by when it ends.
    let hand: NoticeHand
    let onPress: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let words = foot.words()
        Group {
            if foot == .more {
                Button(action: onPress) { label(words) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(words)
                    .accessibilityAddTraits(.isButton)
            } else {
                label(words)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(words)
            }
        }
        .onAppear { hand.footInView = true }
        .onDisappear { hand.footInView = false }
    }

    private func label(_ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Image(systemName: foot.symbol)
                .accessibilityHidden(true)
            Text(words)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .shellFont(.meta)
        .foregroundStyle(foot == .more ? ShellChrome.inkDim(colorScheme) : ShellChrome.inkFaint(colorScheme))
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .contentShape(Rectangle())
    }
}

/// The line being read, worked out from what the list says is on screen (#303): `KeepsTopRow`'s
/// reports, to this page's own mark.
private struct KeepsNoticeMark: ViewModifier {
    let mark: ShellReadingMark
    let hand: NoticeHand
    /// How many lines are drawn.
    let shown: Int
    /// A scroll of the person's own hand ended having brought the foot into view.
    let onArrive: () -> Void

    func body(content: Content) -> some View {
        content
            .onScrollTargetVisibilityChange(idType: String.self) { mark.visible($0) }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: ShellReadingMark.wholeShare) { mark.whole($0) }
            .onScrollPhaseChange { old, phase in
                let byHand = ShellReadingMark.byHand(phase)
                if byHand { mark.scrolledByHand() }
                if hand.scrolled(wasByHand: ShellReadingMark.byHand(old), isByHand: byHand, shown: shown) { onArrive() }
            }
    }
}

/// Where the list stands as it is drawn and as the lamp moves: a timeline's own rules
/// (`TimelinePane.landing`, `ShellReadingMark.centres`), for this page's lamp and mark.
private struct NoticeListPlace: ViewModifier {
    let proxy: ScrollViewProxy
    let ids: [String]
    /// Whether a line left at the person's own yes (`ShellNoticeList.leftAtYes`): lit, it
    /// hands the lamp on.
    let leaving: (String) -> Bool
    @Binding var selectedID: String?
    let mark: ShellReadingMark
    let touch: Bool
    let jumpToTop: Int

    func body(content: Content) -> some View {
        content
            .onChange(of: ids, initial: true) { was, ids in
                mark.list(Set(ids))
                let lamp = NoticesPane.lamp(selectedID, was: was, now: ids, leaving: leaving)
                if lamp != selectedID { selectedID = lamp }
            }
            .onAppear {
                let returning = mark.returning
                mark.returning = nil
                // A tick later: a lazy stack just built has not laid out the row to scroll to.
                switch TimelinePane.landing(selected: selectedID, top: nil, touch: touch, marked: returning) {
                case .centred(let id): Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
                case .top(let id): Task { @MainActor in proxy.scrollTo(id, anchor: .top) }
                case nil: break
                }
                if touch, selectedID != nil { selectedID = nil }
            }
            .onChange(of: selectedID) { _, id in
                guard let id, ShellReadingMark.centres(onSelecting: id, touch: touch, handed: nil) else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: touch) { _, now in
                if now, selectedID != nil { selectedID = nil }
            }
            .onChange(of: jumpToTop) { _, _ in
                guard let first = ids.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(first, anchor: .top) }
            }
    }
}

/// Where the foot stood as a scroll of the person's own hand began, and where it stands now:
/// what decides whether that scroll, ending, reads on. Held past observation — a scroll
/// redraws nothing — and nothing here outlives the scroll it is about.
@MainActor
final class NoticeHand {
    /// Whether the foot is on screen, as the foot itself says.
    var footInView = false
    private var footInViewAtStart = false

    /// The list's scroll changed phase. Whether a hand's scroll has just ended having brought
    /// the foot into view (`NoticesFoot.readsByItself`).
    func scrolled(wasByHand: Bool, isByHand: Bool, shown: Int) -> Bool {
        if !wasByHand, isByHand { footInViewAtStart = footInView }
        guard wasByHand, !isByHand else { return false }
        return NoticesFoot.readsByItself(
            footInViewAtStart: footInViewAtStart, footInViewAtEnd: footInView, shown: shown
        )
    }
}

/// The parts of the notices page a hosted test reads: where each was laid out, and what it says.
@MainActor
final class NoticesProbe {
    enum Part: Hashable {
        case nobody, notAllowed, head, none, foot
        /// The head's parts: the place's name, the words about the kinds, and the three marks.
        case title, kindsWords, kindsMark, reloadMark, moreMark
        /// What the page says of itself at one source — its ask, its reading of requests —
        /// and a request said to be on its way, by its id.
        case said(String), onWay(String)
        /// One source's held-back line, its words and its press, by host; and under it, while
        /// its requests are read and where it holds more than it listed.
        case held(String), heldWords(String), heldPress(String), heldReading(String), heldPartial(String)
        /// One held-back request, its words and its `…`, by the request's id.
        case request(String), requestWords(String), requestMore(String)
        /// The words of one source's line, and the press beside them, by `NoticesLine.id`.
        case lineWords(String), linePress(String)
        /// One source's word above the lines, by `NoticesLine.id`.
        case line(String)
        /// One notice's row, by the line's id.
        case row(String)
    }

    var frames: [Part: CGRect] = [:]
    var says: [Part: String] = [:]
}

extension EnvironmentValues {
    /// See `NoticesProbe`. Nothing outside a test.
    @Entry var shellNoticesProbe: NoticesProbe?
}

/// Reports one part of the page to a probe, where one is handed down; draws nothing and
/// changes nothing.
struct NoticesProbed: ViewModifier {
    let part: NoticesProbe.Part
    /// What the part says, where this is the one that says it.
    let says: String?
    let probe: NoticesProbe?

    init(_ part: NoticesProbe.Part, says: String? = nil, probe: NoticesProbe?) {
        self.part = part
        self.says = says
        self.probe = probe
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let probe {
            content.background(GeometryReader { room in
                let _ = (probe.frames[part] = room.frame(in: .global), says.map { probe.says[part] = $0 })
                Color.clear
            })
        } else {
            content
        }
    }
}
