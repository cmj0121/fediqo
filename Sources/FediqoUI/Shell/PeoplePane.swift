import FediqoCore
import SwiftUI

/// A list of people as its page is handed it (#311): which list, where the asking has got to,
/// and who the source has given so far.
///
/// **One source's word, and its count is its own.** The figure in the head is what the source
/// counts; the rows are who it gave whoever asked. The two differ for reasons the list never
/// says — so the count is never a promise of rows, what was given is said where the list ends
/// and never before, and nothing here is called empty or hidden on the strength of no rows.
struct PeopleSaid: Equatable {
    /// Where asking for the list has got to.
    enum Reading: Equatable {
        /// The first stretch is out, or about to be.
        case asking
        /// The source answered: `people` is who it gave, which may be nobody.
        case said
        /// The source refused, failed, or sent what could not be read.
        case failed
        /// The source says it has no such list at all: the list's own address is not there.
        case absent
    }

    /// What stands under the rows.
    enum Foot: Equatable {
        /// The source named a next stretch: a press reads it — and reads it again where the
        /// last did not come, which the toast says (DESIGN-reload).
        case more
        /// The source named no next: the end of what it gives whoever asked.
        case end
        /// The source stopped handing the list on in order. It ends here, and no press asks again.
        case stopped
        /// A directory read as far as one is read here: the source may have more, and none is asked for.
        case farthest

        var presses: Bool { self == .more }
    }

    let list: PeopleList
    /// Whether whoever would ask now is signed in to the source: what its sentences may say
    /// of a sign-in.
    var signedIn = false
    /// Whether the list is the signed-in reader's own.
    var own = false
    var reading: Reading = .asking
    var people: [Person] = []
    /// How the reader stands to the people listed, as the source last said, by the id it knows
    /// each by. **Only whom it has said of**: nobody where nobody was asked — no sign-in, one
    /// that does not see it, a source where nobody is followed — where the ask is out, and
    /// where it failed. A row of somebody not here draws no word of it.
    var stands: [String: PersonStanding] = [:]
    /// What a row of the list offers (#313), in the order it is drawn: accepting a request
    /// is a press on the row, and refusing one or removing a follower an item of its `…`.
    /// Nothing on a list with nothing to do to a row.
    var acts: [PersonAct] = []
    /// The sentence of a row whose press did not arrive, by the id the source knows them by.
    var missed: [String: String] = [:]
    /// How the sign-in stands where the rows of this list would offer something and it may
    /// not change who follows whom (#313): said in one line over the rows, dim with the lock,
    /// a press where it may be asked. Nothing where it may, and on a list with nothing to offer.
    var lock: PartWords.Place?
    /// Whether the list is being asked from the top.
    var asking = false
    var foot: Foot?
    /// How a directory is asked for — its order, and whether only the people who live there —
    /// or nothing where the list is somebody's, which has no such choice.
    var sorting: DirectoryChoice?
    /// How "Don't suggest" stands on each row (#315): only on the people a source suggests.
    var dismissing: Dismissing?
    /// How the sign-in stands where a row of the reader's own people featured would offer
    /// Take off your profile and it lacks the account part (#315): the item is dim with this
    /// lock, and its press asks where it may. Nothing where it holds it, and on any other list.
    var accountLock: PartWords.Place?

    /// How telling the source not to suggest somebody stands for the sign-in.
    enum Dismissing: Equatable {
        /// It holds the account part: the row's `…` holds the press, asked about first.
        case offered
        /// It does not: the press is dim with the part's lock, and asks where it may.
        case locked(PartWords.Place)
    }

    /// The host of the source that says.
    var source: String { list.host }

    // MARK: - Words

    /// Whose list it is, in the page's head. **Their handle is a stranger's word set in a
    /// sentence of ours**, and is the one made fit for a line.
    static func title(_ list: PeopleList, own: Bool = false, language: DummyLanguage? = nil) -> String {
        if own, list.which == .featured {
            return String(format: L10n.t("people.title.featured.own", language: language), list.host)
        }
        if list.which == .collection {
            return String(format: L10n.t("people.title.collection", language: language), list.lineWords, list.lineHandle)
        }
        return String(
            format: L10n.t("people.title.\(list.which.rawValue)", language: language),
            titleNamesHost(list) ? list.host : list.lineHandle
        )
    }

    /// The head's title of this list: the reader's own people featured say "you" (#315).
    func title(language: DummyLanguage? = nil) -> String {
        Self.title(list, own: own, language: language)
    }

    /// Whether the title names the source that keeps the list — nobody's list, or the
    /// reader's own requests — and not whose list it is.
    static func titleNamesHost(_ list: PeopleList, own: Bool = false) -> Bool {
        list.readByCount || list.isReadersOwn || (own && list.which == .featured)
    }

    /// What an order of a directory is called, in the control that chooses it.
    static func orderName(_ order: DirectoryOrder, language: DummyLanguage? = nil) -> String {
        L10n.t("people.directory.order.\(order.rawValue)", language: language)
    }

    /// What the choice of only the people who live at the source is called.
    static func localName(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("people.directory.local", language: language), source)
    }

    /// How a directory is being read, as one sentence: what a listener hears of the order's
    /// word and of the gear (#401), where a list of somebody's says what its source counts.
    static func sortingLine(_ choice: DirectoryChoice, source: String, language: DummyLanguage? = nil) -> String {
        let key = "people.directory.line.\(choice.order.rawValue)" + (choice.localOnly ? ".local" : "")
        return String(format: L10n.t(key, language: language), source)
    }

    /// The order the other of the two would be, and the choice with the people who live
    /// elsewhere let in or kept out: what the control's presses choose.
    static func choosing(_ order: DirectoryOrder, from choice: DirectoryChoice) -> DirectoryChoice {
        DirectoryChoice(order: order, localOnly: choice.localOnly)
    }

    static func choosing(localOnly: Bool, from choice: DirectoryChoice) -> DirectoryChoice {
        DirectoryChoice(order: choice.order, localOnly: localOnly)
    }

    /// Whether the control that chooses how a directory is read takes a press: there is a
    /// directory, and it is not being asked from the top.
    var choosesSorting: Bool { sorting != nil && reading != .absent && !asking }

    /// How many the source counts in the list as it said since the list was opened, where that
    /// is newer than the list's own figure: who ask to follow the reader, as the sign-in's
    /// account check last said — **and only while it holds**: nothing once a request has been
    /// answered here. Nothing on any other list.
    var tally: Int?

    /// What the source counts in the list, where it said one: **never nought**, which would
    /// be a figure where the rows already say there is nobody.
    var counted: Int? { (tally ?? list.counted).flatMap { $0 > 0 ? $0 : nil } }

    static let figureSymbol = "person.2"

    /// The head's figure: the source's count, a glyph and the number on no well, opening
    /// nothing (F10 §10, 6) — its sentence told to a pointer and a listener. Nothing where the
    /// source said none. **Its sentence names the source only where the title does not**: who
    /// asks to follow the reader is said as the way to the list says it.
    func figure(language: DummyLanguage? = nil) -> PageFigure? {
        counted.map {
            PageFigure(
                symbol: Self.figureSymbol, figure: L10n.grouped($0, language: language),
                spoken: list.which == .requests
                    ? PersonSaid.figure("people.requests.entry.count", $0, language: language)
                    : String(format: L10n.t("people.counts", language: language), source, L10n.grouped($0, language: language)),
                opens: false
            )
        }
    }

    /// What the source counts in the list, where it said: its figure, said as its figure.
    static func counts(_ list: PeopleList, language: DummyLanguage? = nil) -> String? {
        list.counted.map {
            String(format: L10n.t("people.counts", language: language), list.host, L10n.grouped($0, language: language))
        }
    }

    /// The first part of the keys a list's own sentences are under, by which list it is.
    static func words(_ which: PeopleList.Which) -> String {
        switch which {
        case .directory: "people.directory"
        case .found: "people.found"
        case .suggested: "people.suggested"
        case .requests: "people.requests"
        case .featured: "people.featured"
        case .muted: "people.muted"
        case .blocked: "people.blocked"
        case .boostedBy: "people.boostedBy"
        case .favouritedBy: "people.favouritedBy"
        case .collection: "people.collection"
        case .following, .followers: "people"
        }
    }

    /// What is said above the rows: that the source says it has no such list at all — a state
    /// of the list, and no failure. Being asked, and an ask that came to nothing, are the
    /// page's toast to say (DESIGN-reload), and nothing here.
    func stateLine(language: DummyLanguage? = nil) -> String? {
        // Only a list a host may not have is ever absent, and each says so in its own words.
        guard reading == .absent else { return nil }
        return String(format: L10n.t("\(Self.words(list.which)).absent", language: language), source)
    }

    /// Whether the line above the rows offers the press that asks again: beside a list the
    /// source says it has not, since nothing stays absent until the app is quit.
    var offersAgain: Bool { reading == .absent }

    /// How many the source counts beyond who it gave, where the list has ended short of its
    /// own figure — or nothing where it has not ended, said no figure, or gave as many.
    var short: Int? {
        guard foot == .end, let counted = list.counted, counted > people.count else { return nil }
        return counted - people.count
    }

    func footSymbol(_ foot: Foot) -> String {
        switch foot {
        case .more: "arrow.down.circle"
        case .end: short == nil ? "checkmark.circle" : "circle.dotted"
        case .stopped: "exclamationmark.circle"
        case .farthest: "circle.dotted"
        }
    }

    /// What the foot says. **The end is the end of what the source gives whoever asked**: where
    /// it gave fewer than it counts, it says both figures and that the rest is not held or is
    /// left out — and names a sign-in only where there is one.
    func footWords(_ foot: Foot, language: DummyLanguage? = nil) -> String {
        switch foot {
        case .more: return L10n.t("people.foot.more", language: language)
        case .stopped: return String(format: L10n.t("people.foot.stopped", language: language), source)
        case .farthest:
            let key = switch list.which {
            case .found: "people.found.foot.farthest"
            case .suggested: "people.suggested.foot.farthest"
            case .directory, .following, .followers, .requests, .featured, .muted, .blocked, .boostedBy, .favouritedBy, .collection:
                "people.directory.foot.farthest"
            }
            return String(format: L10n.t(key, language: language), L10n.grouped(people.count, language: language), source)
        case .end:
            guard short != nil, let counted = list.counted else {
                return String(format: L10n.t("people.foot.end", language: language), source)
            }
            return String(
                format: L10n.t(signedIn ? "people.foot.partial" : "people.foot.partial.unsigned", language: language),
                source, L10n.grouped(people.count, language: language), L10n.grouped(counted, language: language)
            )
        }
    }

    /// What stands where rows would, once the source has answered with nobody and named no
    /// next — or nothing where there are rows, or more to read, or no answer yet.
    ///
    /// **Hidden only where the account says so**: a hidden list, an empty one and the list of
    /// somebody who blocks the reader arrive alike. And never of the reader's own list — its
    /// owner is given a hidden list, so nobody in it is not its being hidden. **`own` is known
    /// by the reader's handle alone**: a reader the source has not named, looking at their own
    /// hidden list given empty, is told it is hidden — true of the account, and not why it is
    /// empty. That is covered only once every sign-in learns who it is. Beside a count
    /// that is not nothing, the source gave none of them, and no reason is known; otherwise it
    /// gave nobody. Always about the source, never that they follow nobody.
    func nothing(language: DummyLanguage? = nil) -> String? {
        guard reading == .said, people.isEmpty, foot == nil else { return nil }
        // A directory that answered with nobody is one nobody is in — never one switched off,
        // which answers that its address is not there.
        if let sorting {
            return String(format: L10n.t(sorting.localOnly ? "people.directory.none.local" : "people.directory.none", language: language), source)
        }
        if list.which == .found {
            return String(format: L10n.t("people.found.none", language: language), source)
        }
        if list.which == .suggested {
            return String(format: L10n.t("people.suggested.none", language: language), source)
        }
        if list.which == .requests {
            return String(format: L10n.t("people.requests.none", language: language), source)
        }
        if list.which == .featured {
            return String(format: L10n.t("people.featured.none", language: language), source)
        }
        if [.muted, .blocked, .boostedBy, .favouritedBy, .collection].contains(list.which) {
            return String(format: L10n.t("\(Self.words(list.which)).none", language: language), source)
        }
        if list.hidden, !own {
            return String(format: L10n.t("people.hidden", language: language), list.lineHandle)
        }
        if let counted = list.counted, counted > 0 {
            return String(format: L10n.t(signedIn ? "people.noneOf" : "people.noneOf.unsigned", language: language), source)
        }
        return String(format: L10n.t("people.none", language: language), source)
    }

    /// The lock's sentence over the rows.
    func lockWords(language: DummyLanguage? = nil) -> String? {
        lock.map { String(format: L10n.t($0.key, language: language), source) }
    }

    // MARK: - What a row offers (#313)

    /// The acts of a row that take something away, and so stand only in its `…` and ask first.
    var dangerous: [PersonAct] { acts.filter { $0 == .refuseRequest || $0 == .removeFollower } }

    /// Whether a row's `…` holds Take off your profile (#315): on the reader's own people
    /// featured, plain and at once — or dim with the account part's lock.
    var takesOff: Bool { acts.contains(.unfeature) || accountLock != nil }

    /// Whether accepting is a press on the row.
    var accepts: Bool { acts.contains(.acceptRequest) }

    // MARK: - A row's menu

    /// What telling the source not to suggest somebody is called.
    static func dismissName(language: DummyLanguage? = nil) -> String {
        L10n.t("people.suggested.dismiss", language: language)
    }

    static let dismissSymbol = "person.crop.circle.badge.minus"

    /// What the `…` of the row of `person` holds on the people a source suggests (#315), or
    /// nothing on any other list. **Where the sign-in holds the account part**: Don't suggest,
    /// asked about first — its yes is `act`. **Where it does not**: Don't suggest dim with the
    /// lock, saying the part's own sentence, whose press is `act` too where the part may be asked
    /// for — which then only asks.
    @MainActor
    func more(of person: Person, act: @escaping () -> Void, language: DummyLanguage? = nil) -> ShellMore? {
        switch dismissing {
        case .offered?:
            return ShellMore(items: [
                .danger(
                    Self.dismissSymbol, Self.dismissName(language: language),
                    asks: ShellQuestion.dontSuggest(person.lineHandle, at: source, language: language), act: act
                ),
            ])
        case .locked(let place)?:
            let dim = ShellMark(SourceRow.permissionSymbol, Self.dismissName(language: language), look: .dim(.askAgain))
            return ShellMore.ending(
                in: .plain(dim, ask: place.asks ? act : nil, act: {}),
                dimFor: String(format: L10n.t(place.key, language: language), source)
            )
        case nil:
            return nil
        }
    }
}

/// A list of people, opened: a page of its own (F10) — the directory, the people suggested,
/// who asks to follow the reader — drawn in the frame every opened page stands in
/// (`OpenedPage`), with no tabs. The people a search found are a tab of the page of what it
/// found (`FoundPage`), drawn by the same rows. Its bar holds the way back and the mark that
/// asks the source again; its head says whose list it is, which source keeps it and what that
/// source counts; under them are the people the source gave.
///
/// **A step of the walk like somebody's page**, so the way back, the lamp and the row given
/// back on leaving somebody's page are the walk's own. It draws what it is handed and asks
/// nothing: the asking is `ShellPeoplePages`'s, and which kind of source this is is never
/// looked at here. **At an accessibility text size the head is the list's first rows**, and
/// scrolls away with it.
struct PeoplePane: View {
    let said: PeopleSaid
    @Binding var selectedID: String?
    /// How far a sideways swipe has slid the list.
    var slide = PageSlide()
    /// Whether the source can be asked again: what `r` goes by, and the bar's mark with it.
    var canReload = false
    /// A row opened: that person's page, answered by the root under the walk's own rule.
    var onOpen: (Person) -> Void
    /// "Ask again", beside a list the source says it has not: the list asked from the top.
    var onAskAgain: () -> Void = {}
    /// The bar's mark: what `r` does.
    var onReload: () -> Void = {}
    /// The same, pulled for: it returns when the answer has landed.
    var onPull: () async -> Void = {}
    /// What stops the list's ask while it runs: the bar's mark is then Stop.
    var onStop: (() -> Void)?
    /// The foot's press: the next stretch.
    var onReadOn: () -> Void = {}
    /// A directory's order chosen, or only the people who live there: asked from the top.
    var onChoose: (DirectoryChoice) -> Void = { _ in }
    /// A press on a row that answers a request or removes a follower (#313).
    var onAct: (PersonAct, Person) -> Void = { _, _ in }
    /// The press on the lock of a sign-in that may not change who follows whom.
    var onAsk: () -> Void = {}
    var jumpToTop: Int = 0
    var onBack: () -> Void

    /// What the bar's mark is called — the source it asks — or nothing where it cannot be
    /// asked: then there is no mark, and a pull asks nothing.
    static func reloadName(of said: PeopleSaid, canReload: Bool, language: DummyLanguage? = nil) -> String? {
        canReload ? PersonPage.reloadName(said.source, language: language) : nil
    }

    var body: some View {
        OpenedPage(
            slide: slide, reload: Self.reloadName(of: said, canReload: canReload), onBack: onBack, onReload: onReload,
            onPull: onPull, onStop: onStop,
            head: {
                PeopleHead(said: said, onChoose: onChoose)
                ShellRule()
            },
            inFront: { lead in list { lead } }
        )
    }

    /// The people the source gave, as the one list a tab of somebody's page draws too: led by
    /// the head where it scrolls away.
    private func list<Lead: View>(@ViewBuilder lead: () -> Lead) -> some View {
        PeopleRows(
            said: said, selectedID: $selectedID, onOpen: onOpen, onAskAgain: onAskAgain, onReadOn: onReadOn,
            onAct: onAct, onAsk: onAsk, jumpToTop: jumpToTop, lead: lead
        )
    }

    /// The `…` of the row of `person` in `said`: what the list offers a row that takes
    /// something away (#313) — refusing a request, removing a follower — and Don't suggest
    /// (#315), each asked about first, through the page's one asker; or nothing.
    @MainActor
    static func menu(
        for said: PeopleSaid, of person: Person, asks: Binding<ShellMoreAsk?>, act: @escaping (PersonAct) -> Void
    ) -> NoticeRow.Menu? {
        if let more = said.more(of: person, act: { act(.dismissSuggestion) }) {
            return NoticeRow.Menu(more: { more }, asks: asks)
        }
        if said.takesOff {
            let name = PersonActing.name(.unfeature)
            guard let lock = said.accountLock else {
                let more = ShellMore(items: [
                    .plain(PersonActing.symbol(.unfeature), name) { act(.unfeature) },
                ])
                return NoticeRow.Menu(more: { more }, asks: asks)
            }
            let dim = ShellMark(SourceRow.permissionSymbol, name, look: .dim(.askAgain))
            let more = ShellMore.ending(
                in: .plain(dim, ask: lock.asks ? { act(.unfeature) } : nil, act: {}),
                dimFor: String(format: L10n.t(lock.key), said.source)
            )
            return NoticeRow.Menu(more: { more }, asks: asks)
        }
        let dangerous = said.dangerous
        guard !dangerous.isEmpty else { return nil }

        let more = ShellMore(items: dangerous.map { offered in
            .danger(
                PersonActing.symbol(offered), PersonActing.name(offered),
                asks: ShellQuestion.about(offered, person.lineHandle, at: said.source)
            ) { act(offered) }
        })
        return NoticeRow.Menu(more: { more }, asks: asks)
    }
}

/// The head of a list of people: whose list this is and which source keeps it, and under them
/// what that source counts — its figure (`PageFigure`), a glyph and the number opening
/// nothing, only where it said one, since the rows below may be fewer.
///
/// **A directory's head names the order in a word, and the choice sits behind a gear**
/// (#401). The title and that word are the heading a listener hears; the long sentence of how
/// the directory is read is the word's value, not a paragraph. The gear is an element of its
/// own after them, lit while only the people who live there are listed. A source that says it
/// has no directory draws no gear: a choice it does not have is absent, not greyed. A list of
/// somebody's keeps the source's count, and its pill.
struct PeopleHead: View {
    let said: PeopleSaid
    var onChoose: (DirectoryChoice) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    private var list: PeopleList { said.list }
    private var sorting: DirectoryChoice? { said.sorting }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(said.title())
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let sorting {
                    Text(DirectoryGear.word(sorting))
                        .shellFont(.meta, weight: .medium)
                        .foregroundStyle(said.choosesSorting ? ShellChrome.ink(colorScheme) : ShellChrome.inkFaint(colorScheme))
                        .accessibilityValue(PeopleSaid.sortingLine(sorting, source: list.host))
                }
                if let figure = said.figure() { PageFigureView(figure: figure) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(HeadElement(alone: sorting != nil))
            if let sorting {
                if DirectoryGear.shown(for: said) {
                    DirectoryGearMenu(choice: sorting, source: list.host, onChoose: onChoose)
                        .disabled(!said.choosesSorting)
                        .fixedSize()
                }
            } else {
                ShellWellPill(list.host)
                    .fixedSize()
                    // Heard once: where the title already names the source, the pill is not said again.
                    .accessibilityHidden(PeopleSaid.titleNamesHost(list, own: said.own))

            }
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        // A list of somebody's is one heading to a listener, its source's pill within it, as
        // before; a directory's words are the heading and its control an element after it.
        .modifier(HeadElement(alone: sorting == nil))
    }

    /// Makes what it is put on one heading for a listener, where it is told to.
    private struct HeadElement: ViewModifier {
        let alone: Bool

        func body(content: Content) -> some View {
            if alone {
                content
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
            } else {
                content
            }
        }
    }
}

/// What a directory's head shows of how it is read (#401): the order's name, in a word, and
/// whether the gear is lit. The gear is lit while only the people who live there are listed.
/// Changing either still asks the directory again from the top (`PeopleSaid.choosing`).
enum DirectoryGear {
    static let symbol = "gearshape"

    static func word(_ choice: DirectoryChoice, language: DummyLanguage? = nil) -> String {
        PeopleSaid.orderName(choice.order, language: language)
    }

    static func lit(_ choice: DirectoryChoice) -> Bool {
        choice.localOnly
    }

    /// The gear is drawn where the source has a directory to order. One that says it has none
    /// offers no choice, so the gear is absent, not greyed. While the directory is asked from
    /// the top the gear stays, dimmed: the choice is still there.
    static func shown(for said: PeopleSaid) -> Bool {
        said.sorting != nil && said.reading != .absent
    }
}

/// The gear a directory's order and local-only choice sit behind (#401). The two orders are
/// the two a source takes; under them, only the people who live there. It chooses and asks
/// nothing itself: the asking is `ShellPeoplePages`'s, and the head follows whatever it chose.
struct DirectoryGearMenu: View {
    let choice: DirectoryChoice
    let source: String
    var onChoose: (DirectoryChoice) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            ForEach(DirectoryOrder.allCases, id: \.self) { order in
                Toggle(PeopleSaid.orderName(order), isOn: Binding(
                    get: { choice.order == order },
                    set: { _ in onChoose(PeopleSaid.choosing(order, from: choice)) }
                ))
            }
            Divider()
            Toggle(PeopleSaid.localName(source), isOn: Binding(
                get: { choice.localOnly },
                set: { onChoose(PeopleSaid.choosing(localOnly: $0, from: choice)) }
            ))
        } label: {
            Image(systemName: DirectoryGear.symbol)
                .foregroundStyle(gearInk)
                .modifier(ShellGlyphBox())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .shellNamed("people.directory.choose")
        .accessibilityValue(PeopleSaid.sortingLine(choice, source: source))
    }

    /// Lit while the directory is narrowed to the people who live there; dim while the
    /// directory is being asked from the top. A source that has no directory draws no gear.
    private var gearInk: Color {
        guard isEnabled else { return ShellChrome.inkFaint(colorScheme) }
        return DirectoryGear.lit(choice) ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme)
    }
}

/// A way from the reader's own page to one of their lists of whom they keep away at a source
/// (#314): whom they mute, whom they block, and the servers they block — one line of "You
/// there" on About each, and what its press does.
///
/// **Where the sign-in does not see whom they mute and block, there is one line and not three**:
/// the lock of how the sign-in stands, said once, whose press asks where it may.
struct KeepingEntry: Equatable, Identifiable {
    enum Which: String, CaseIterable {
        case muted, blocked, servers
    }

    let which: Which
    let host: String
    /// How the sign-in stands where it does not see whom the reader mutes and blocks.
    var locked: PartWords.Place?

    /// What the lamp stands on where it stands on this line.
    var id: String { Self.id(which) }

    static func id(_ which: Which) -> String { "about." + which.rawValue }

    /// The list a press opens: one of people, or nothing for the servers, which are a sheet.
    var list: PeopleList? {
        switch which {
        case .muted: PeopleList(.muted, at: host)
        case .blocked: PeopleList(.blocked, at: host)
        case .servers: nil
        }
    }

    var asks: Bool { locked?.asks ?? false }
    var presses: Bool { locked == nil || asks }

    func words(language: DummyLanguage? = nil) -> String {
        if let locked { return String(format: L10n.t(locked.key, language: language), host) }
        return L10n.t("keeping.\(which.rawValue).entry", language: language)
    }

    var symbol: String {
        switch which {
        case .muted: "speaker.slash"
        case .blocked: "hand.raised"
        case .servers: PersonActing.serverBlockedSymbol
        }
    }
}

/// The way to the people who ask to follow the reader, on their own page (#313): one line of
/// "You there" on About, and what its press does.
///
/// **Its figure is the source's, as the sign-in's own account check last said it** — the one
/// place a source says how many ask — and never arithmetic: it does not count down when a
/// request is answered here, and changes when that check next runs. Where the check said
/// no figure, the line is words alone: the source did not say there are none. **Where it
/// said nought there is no line at all** (`ShellPersonPages.requestsEntry`).
struct RequestsEntry: Equatable {
    let list: PeopleList
    /// How many ask, as the account check last said. Nothing where it has not said.
    var counted: Int?
    /// How the sign-in stands where it does not see who follows the reader. Nothing where it does.
    var locked: PartWords.Place?

    /// What the lamp stands on where it stands on this line.
    static let id = "about.requests"

    /// Whether pressing a locked line asks the sign-in for who the reader follows.
    var asks: Bool { locked?.asks ?? false }

    /// Whether the line is a press: open, or a lock that asks.
    var presses: Bool { locked == nil || asks }

    func words(language: DummyLanguage? = nil) -> String {
        if let locked { return String(format: L10n.t(locked.key, language: language), list.host) }
        guard let counted else { return L10n.t("people.requests.entry", language: language) }
        return PersonSaid.figure("people.requests.entry.count", counted, language: language)
    }
}
