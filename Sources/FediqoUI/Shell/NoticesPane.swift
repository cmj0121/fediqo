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
/// them; and then the head and the lines. **What each source has to say — not read, held to the
/// most kept, never asked, asked and refused — is one status mark in the head** (#396,
/// `StatusMark`), which opens each source's sentence and its Ask or Again; nothing stands above
/// the lines for it. **A read on the wire, a source that failed and a read stopped are its
/// bottom toast's**, as the timeline's are (DESIGN-reload).
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
    /// Who boosted or favourited a post a line is about, opened from its faces (#375).
    var onOpenPeople: (PeopleList, Notice) -> Void = { _, _ in }
    /// Somebody's page and their acts, which a line of a person draws and acts through (#375).
    var people: ShellPersonPages?
    /// What a post's row on a line opens its pictures and plays its films through (#375).
    var media: NoticeMedia?
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
            hosts: hosts,
            locked: list.locked,
            unread: unread,
            full: list.fullHosts,
            places: places(among: hosts, in: session)
        )
    }

    /// What the status mark in the head lists now (#396): each source's line (`lines`), what
    /// an ask or a reading of requests came to (`said`), a request let through and on its way,
    /// and why the list ends where the foot is a plain mark. A held-back list being read, or
    /// listed short, is said on its own page (`NoticesHeldPage`). `reload` is what Again reads with where a source was not read.
    static func status(
        in session: ShellSession, began: Bool = true, language: DummyLanguage? = nil
    ) -> [StatusLine] {
        let hosts = hosts(in: session)
        return status(
            hosts: hosts, unread: unread(among: hosts, in: session, began: began), in: session, language: language
        )
    }

    static func status(
        hosts: [(host: String, notices: NoticeStanding)], unread: [String], in session: ShellSession,
        touch: Bool = false, reload: @escaping () -> Void = {}, language: DummyLanguage? = nil
    ) -> [StatusLine] {
        let acts = session.noticeList.acts
        var status = lines(hosts: hosts, unread: unread, in: session).map { line in
            let press = press(line, in: session, reload: reload, language: language)
            return StatusLine(
                id: line.id, host: line.host, words: line.words(language: language, touch: touch),
                needsReader: press != nil || standsOut(line), standsOut: standsOut(line), press: press
            )
        }
        // An ask that came to nothing leaves its source unasked, and that line carries the press
        // and the count: this one only says what happened.
        status += said(in: session, language: language).map {
            StatusLine(id: "said:" + $0.host, host: $0.host, words: $0.words, needsReader: false)
        }
        status += acts.onItsWay.map {
            StatusLine(
                id: "onWay:" + $0.id, host: $0.source.host.lowercased(),
                words: NoticeActs.onItsWay($0, language: language), needsReader: false
            )
        }
        // Why the list ends where it does, where its foot is a plain mark. A source held to the
        // most kept is named by its own line above.
        switch foot(in: session) {
        case .held?:
            status.append(StatusLine(
                id: "foot:held", host: nil, words: L10n.t("notices.foot.held", language: language),
                press: StatusPress(
                    kind: .again, spoken: L10n.t("status.press.again.notices.spoken", language: language), act: reload
                )
            ))
        case .limit?:
            status.append(StatusLine(
                id: "foot:limit", host: nil, words: L10n.t("notices.foot.limit", language: language), needsReader: false
            ))
        case .more?, .full?, .end?, nil:
            break
        }
        return status
    }

    /// What a source's line offers in the status list: Ask where it was never asked, Again
    /// where it was refused — on its own page, or by the source — or where it was not read.
    /// A line with no press only informs, and is not counted (`StatusLine.needsReader`).
    static func press(
        _ line: NoticesLine, in session: ShellSession, reload: @escaping () -> Void, language: DummyLanguage? = nil
    ) -> StatusPress? {
        switch line {
        case .unasked(let host):
            StatusPress(kind: .ask, spoken: NoticeAskSlot.spoken(host, language: language)) {
                session.askForNotices(host: host)
            }
        case .refused(let host):
            // Asked again where the sign-in may be asked for notices; where it already holds
            // them and the source still gave none, the source is read again — but never while
            // an ask is out there, which the toast then says.
            StatusPress(
                kind: .again, spoken: String(format: L10n.t("status.press.again.ask.spoken", language: language), host)
            ) {
                if !session.askFor([.notices], host: host), !session.isAsking(host: host) { reload() }
            }
        case .declined(let host):
            StatusPress(
                kind: .again, spoken: String(format: L10n.t("status.press.again.ask.spoken", language: language), host)
            ) {
                session.askForNotices(host: host)
            }
        case .locked(let host), .unread(let host):
            StatusPress(
                kind: .again,
                spoken: String(format: L10n.t("status.press.again.read.spoken", language: language), host),
                act: reload
            )
        case .asking, .full:
            nil
        }
    }

    /// What each source's sign-in draws where its notices would be, by how it stands to them
    /// (`MastodonSessions.standing`) and whether it is being asked for something now.
    static func places(
        among hosts: [(host: String, notices: NoticeStanding)], in session: ShellSession
    ) -> [String: PartWords.Place.Kind] {
        let mastodon = session.mastodon
        return hosts.reduce(into: [:]) { kinds, entry in
            guard let standing = mastodon.standing(.notices, host: entry.host) else { return }
            kinds[entry.host] = PartWords.place(standing, of: .notices, asking: mastodon.asking.contains(entry.host))?.kind
        }
    }

    /// What is said of each source where no sign-in may read notices and there is no list.
    static func notAllowedLines(
        _ hosts: [(host: String, notices: NoticeStanding)], in session: ShellSession
    ) -> [NoticesLine] {
        NoticesLine.lines(hosts: hosts, places: places(among: hosts, in: session))
    }

    /// What stands under the last line now, or nothing while a read is on the wire: the
    /// toast says so (DESIGN-reload), and no row of the list.
    static func foot(in session: ShellSession) -> NoticesFoot? {
        let list = session.noticeList
        guard !list.isReading else { return nil }
        let foot = NoticesFoot.foot(hasMore: list.hasMore(in: session), floor: list.floor, full: list.isFull)
        // And where what stops the list is the months limit, that is what is said.
        if foot == .held || foot == .end, list.failures.isEmpty, list.locked.isEmpty, list.isAtLimit {
            return .limit
        }
        return foot
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
            case .list where acts.heldShown:
                NoticesHeldPage(session: session, asks: asked)
            case .list:
                head(hosts, status: Self.status(
                    hosts: hosts, unread: Self.unread(among: hosts, in: session, began: began), in: session,
                    touch: touch, reload: onReload
                ))
                    .modifier(NoticesProbed(.head, probe: probe))
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
        // A post's row on a line (#375) puts its question through the page's one asker too.
        .environment(\.shellRowAsk, RowAsk(put: { session.noticeList.acts.asked = $0 }))
        // The read's wait, miss and stop at the foot of the page, as the timeline's (DESIGN-reload).
        .modifier(ReloadToast(toast: TimelineToast.asked(list.ask(), note: nil)))
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
            ForEach(Self.notAllowedLines(hosts, in: session)) { line in
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

    /// The place's name and the marks: every source's state, the gear that chooses the kinds
    /// shown — lit while any is left out, with no words about it in the head (#397) — the read,
    /// and `…` where a source may be read. On the trailing edge, where a timeline keeps its
    /// search and reload.
    ///
    /// **Nothing here is cut short.** Where the line has no room for the name beside the marks,
    /// the marks stand under it.
    private func head(_ hosts: [(host: String, notices: NoticeStanding)], status: [StatusLine]) -> some View {
        // Made once a draw, and stood in whichever of the two fits.
        let marks = marks(hosts, status: status)
        return ViewThatFits(in: .horizontal) {
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

    private func marks(_ hosts: [(host: String, notices: NoticeStanding)], status: [StatusLine]) -> some View {
        let more = NoticeActs.more(in: session, among: hosts)
        return HStack(spacing: ShellSpace.step) {
            if !status.isEmpty {
                StatusMark(lines: status)
                    .modifier(NoticesProbed(.statusMark, says: StatusWords.spoken(status), probe: probe))
            }
            NoticeKindsMenu(kinds: NoticeWords.narrowable(held: list.lines, hidden: prefs.noticesHidden), prefs: prefs)
                .modifier(NoticesProbed(.kindsMark, says: NoticeKindsMenu.spoken(prefs.noticesHidden), probe: probe))
            reloadMark
                .modifier(NoticesProbed(.reloadMark, probe: probe))
            if let more {
                ShellMoreButton(label: ShellMore.label(), asks: asked, more: { more })
                    .modifier(NoticesProbed(.moreMark, probe: probe))
            }
        }
        .fixedSize()
    }

    /// `r`'s mark, and Stop in its place while the newest are read — a timeline's own mark and
    /// rule (`ReloadMark`), under this page's names for the two. A reading-on is not stopped.
    @ViewBuilder
    private var reloadMark: some View {
        if let shown = ReloadMark.shown(canReload: canReload, stoppable: list.ask().stoppable) {
            ShellIconButton(shown.symbol, name: Self.reloadName(shown)) {
                switch ReloadMark.press(shown, at: Date(), pressedAt: reloadPressed) {
                case .begins:
                    reloadPressed = Date()
                    onReload()
                case .stops: list.stop()
                case .unheard: break
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
        // What the sources hold back: one row, which opens it as a page of its own (#399).
        let held = acts.heldCount
        if held > 0 {
            NoticesHeldRow(count: held) { Task { await acts.showHeld(in: session) } }
            ShellRule()
        }
        if !shown.isEmpty {
            rows(shown)
        } else {
            none(unread)
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

    /// One source's word above the lines: where the answer would have been.
    ///
    /// On one line with its press where both fit whole; the press under the words where they
    /// do not, and the words wrapped. Neither is cut.
    ///
    /// **A source refused on its own page is one press**: the line says what happened and
    /// asks again, and the whole of it is what is pressed.
    @ViewBuilder
    private func sourceLine(_ line: NoticesLine) -> some View {
        let words = line.words(touch: touch)
        if case .declined(let host) = line {
            ShellLinkButton(words, symbol: NoticeAskSlot.symbol) { session.askForNotices(host: host) }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NoticesProbed(.linePress(line.id), says: words, probe: probe))
                .padding(.horizontal, ShellSpace.pad)
                .padding(.vertical, ShellSpace.snug)
                .modifier(NoticesProbed(.line(line.id), says: words, probe: probe))
        } else {
            WordsThenPress(words: lineWords(words, of: line), press: linePress(line))
                .modifier(NoticesProbed(.line(line.id), says: words, probe: probe))
        }
    }

    private func lineWords(_ words: String, of line: NoticesLine) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(Self.standsOut(line) ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme))
            .modifier(NoticesProbed(.lineWords(line.id), probe: probe))
    }

    /// What is pressed beside a source's word: the press that asks a source never asked.
    @ViewBuilder
    private func linePress(_ line: NoticesLine) -> some View {
        switch line {
        case .unasked(let host):
            NoticeAskSlot(host: host, session: session)
        case .refused, .locked, .unread, .full, .declined, .asking:
            EmptyView()
        }
    }

    /// Whether a line is drawn in the page's full ink: a source whose older notices are not
    /// shown, which says something is missing from the list under it.
    static func standsOut(_ line: NoticesLine) -> Bool {
        switch line {
        case .full: true
        case .unasked, .refused, .locked, .unread, .declined, .asking: false
        }
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

    @ViewBuilder
    private var foot: some View {
        if let foot = Self.foot(in: session) {
            NoticesFootRow(foot: foot, hand: hand, onPress: readOn)
                .modifier(NoticesProbed(.foot, says: NoticesFootRow.spoken(foot), probe: probe))
        }
    }

    private func rows(_ shown: [Notice]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
            // How the reader stands to the people the lines name as followers and as asking (#375):
            // asked once a person, for the lines drawn, in one ask a stretch.
            .task(id: shown.map(\.id)) { await list.stand(for: shown, in: session) }
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

    /// Under a finger the row is lit by its own share of the reading mark (#303). Drawn as what it
    /// is about (#375, `NoticeCard`).
    private func row(_ notice: Notice) -> some View {
        ReadRow(lamp: mark.lamp(for: notice.id), touch: touch, selected: notice.id == selectedID) { lit in
            NoticeCard(
                notice: notice,
                session: session,
                people: people,
                selected: lit,
                tooOld: notice.id == tooOld,
                onPress: { press(notice) },
                onOpen: NoticeWords.opens(notice) == .nothing ? nil : { onOpen(notice) },
                onOpenPerson: { onOpenPerson($0, notice) },
                onOpenPeople: { onOpenPeople($0, notice) },
                heard: heard(notice.id),
                menu: NoticeRow.Menu(more: { NoticeActs.more(notice, in: session) }, asks: asked),
                asked: asked,
                media: media
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

/// The kinds of notice shown, chosen behind a gear in the page's head (#397): a menu of each
/// kind on or off, and Show every kind. **The gear is lit while any kind is left out**, so a
/// short list is not read as the servers sending nothing; a listener hears it selected, and how
/// many kinds are left out.
///
/// The choice is `DummyPrefs.noticesHidden` and nothing else — only what is drawn is narrowed,
/// and no source is asked anything for it.
struct NoticeKindsMenu: View {
    let kinds: [String]
    @Bindable var prefs: DummyPrefs
    @Environment(\.colorScheme) private var colorScheme

    static let symbol = "gearshape"

    /// Whether the gear is lit: any kind left out.
    static func lit(_ hidden: Set<String>) -> Bool {
        !hidden.isEmpty
    }

    /// What a listener hears of the gear beside its name: every kind shown, or how many are not.
    static func spoken(_ hidden: Set<String>, language: DummyLanguage? = nil) -> String {
        NoticeWords.narrowed(hidden, language: language)
    }

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
                .foregroundStyle(lit ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
                .modifier(ShellGlyphBox())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .shellNamed("notices.kinds")
        .accessibilityValue(Self.spoken(prefs.noticesHidden))
        .accessibilityAddTraits(lit ? .isSelected : [])
    }

    private var lit: Bool {
        Self.lit(prefs.noticesHidden)
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

/// What stands under the last line: a press while older notices can be read, and otherwise a
/// plain end mark (#396) — why the list ends there is the status mark's to say.
struct NoticesFootRow: View {
    let foot: NoticesFoot
    /// Told whether the foot is in view: what a hand's scroll is weighed by when it ends.
    let hand: NoticeHand
    let onPress: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// What the foot is said as: the press's own words, or the end mark's name.
    static func spoken(_ foot: NoticesFoot, language: DummyLanguage? = nil) -> String {
        guard foot == .more, let words = foot.words(language: language) else {
            return L10n.t("notices.foot.endMark", language: language)
        }
        return words
    }

    static let endSymbol = "smallcircle.filled.circle"

    var body: some View {
        let words = Self.spoken(foot)
        Group {
            if foot == .more {
                Button(action: onPress) { label(words) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(words)
                    .accessibilityAddTraits(.isButton)
            } else {
                Image(systemName: Self.endSymbol)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ShellSpace.step)
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
        .foregroundStyle(ShellChrome.inkDim(colorScheme))
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
        /// The head's parts: the place's name and its marks — the kinds gear, the read and `…`.
        case title, kindsMark, reloadMark, moreMark
        /// The head's status mark (#396): every source's state, behind one count.
        case statusMark
        /// What the page says of itself at one source — its ask, its reading of requests —
        /// where no sign-in may read notices and there is no head to hold it.
        case said(String)
        /// The row of what the sources hold back (#399), and on the page it opens: each source's
        /// word of it, by host; while its requests are read; where it holds more than it listed;
        /// and where nothing is held back any more.
        case heldRow, held(String), heldReading(String), heldPartial(String), heldEmpty
        /// What reading a source's requests came to, where it came to nothing, and its Again.
        case heldSaid(String), heldAgain(String)
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
