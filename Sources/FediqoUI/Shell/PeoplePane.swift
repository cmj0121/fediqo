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
        /// The source named a next stretch: a press reads it.
        case more
        /// A stretch is on the wire.
        case reading
        /// The source named no next: the end of what it gives whoever asked.
        case end
        /// The last stretch asked for did not come. A press asks again.
        case failed
        /// The source stopped handing the list on in order. It ends here, and no press asks again.
        case stopped
        /// A directory read as far as one is read here: the source may have more, and none is asked for.
        case farthest

        var presses: Bool { self == .more || self == .failed }
    }

    let list: PeopleList
    /// Whether whoever would ask now is signed in to the source: what its sentences may say
    /// of a sign-in.
    var signedIn = false
    /// Whether the list is the signed-in reader's own.
    var own = false
    var reading: Reading = .asking
    /// Asking from the top again came to a failure, on a list the source had already given:
    /// said in a line of its own, above who it gave then — who stand.
    var againFailed = false
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

    /// The host of the source that says.
    var source: String { list.host }

    // MARK: - Words

    /// Whose list it is, in the page's head. **Their handle is a stranger's word set in a
    /// sentence of ours**, and is the one made fit for a line.
    static func title(_ list: PeopleList, language: DummyLanguage? = nil) -> String {
        String(
            format: L10n.t("people.title.\(list.which.rawValue)", language: language),
            list.readByCount || list.which == .requests ? list.host : list.lineHandle
        )
    }

    /// What an order of a directory is called, in the control that chooses it.
    static func orderName(_ order: DirectoryOrder, language: DummyLanguage? = nil) -> String {
        L10n.t("people.directory.order.\(order.rawValue)", language: language)
    }

    /// What the choice of only the people who live at the source is called.
    static func localName(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("people.directory.local", language: language), source)
    }

    /// How a directory is being read, as one sentence under its title — where a list of
    /// somebody's says what its source counts.
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

    /// What the source counts in the list, where it said: its figure, said as its figure.
    static func counts(_ list: PeopleList, language: DummyLanguage? = nil) -> String? {
        // The people a search found are counted by nobody: the line says what was asked.
        if list.which == .found { return String(format: L10n.t("search.found.line", language: language), list.lineWords) }
        return list.counted.map {
            String(format: L10n.t("people.counts", language: language), list.host, L10n.grouped($0, language: language))
        }
    }

    /// What is said above the rows: that the list is being asked for, that it could not be —
    /// or, once the source has given it, what asking again came to.
    func stateLine(language: DummyLanguage? = nil) -> String? {
        let asked = switch list.which {
        case .directory: "people.directory"
        case .found: "people.found"
        case .suggested: "people.suggested"
        case .requests: "people.requests"
        case .following, .followers: "people"
        }
        return switch reading {
        case .asking: String(format: L10n.t("\(asked).asking", language: language), source)
        case .failed: String(format: L10n.t("\(asked).failed", language: language), source)
        // Only a list a host may not have is ever absent, and each says so in its own words.
        case .absent: String(format: L10n.t("\(asked).absent", language: language), source)
        case .said: againFailed ? String(format: L10n.t("people.again.failed", language: language), source) : nil
        }
    }

    /// Whether the line above the rows offers the press that asks again. Beside a directory
    /// the source says it has not, too: nothing stays absent until the app is quit.
    var offersAgain: Bool { reading == .failed || reading == .absent || againFailed }

    /// How many the source counts beyond who it gave, where the list has ended short of its
    /// own figure — or nothing where it has not ended, said no figure, or gave as many.
    var short: Int? {
        guard foot == .end, let counted = list.counted, counted > people.count else { return nil }
        return counted - people.count
    }

    func footSymbol(_ foot: Foot) -> String {
        switch foot {
        case .more: "arrow.down.circle"
        case .reading: "ellipsis"
        case .end: short == nil ? "checkmark.circle" : "circle.dotted"
        case .failed: "exclamationmark.arrow.circlepath"
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
        case .reading: return L10n.t("people.foot.reading", language: language)
        case .failed: return String(format: L10n.t("people.foot.failed", language: language), source)
        case .stopped: return String(format: L10n.t("people.foot.stopped", language: language), source)
        case .farthest:
            let key = switch list.which {
            case .found: "people.found.foot.farthest"
            case .suggested: "people.suggested.foot.farthest"
            case .directory, .following, .followers, .requests: "people.directory.foot.farthest"
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

    /// Whether accepting is a press on the row.
    var accepts: Bool { acts.contains(.acceptRequest) }

    // MARK: - A row's menu

    /// What telling the source not to suggest somebody is called.
    static func dismissName(language: DummyLanguage? = nil) -> String {
        L10n.t("people.suggested.dismiss", language: language)
    }

    /// Why that is dim: the word a source wants for it belongs to changing the reader's own
    /// account there, which no sign-in is asked for yet.
    static func dismissDim(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("people.suggested.dismiss.dim", language: language), source)
    }

    static let dismissSymbol = "person.crop.circle.badge.minus"

    /// What the `…` of a row of this list holds, or nothing on a list with nothing to do to a
    /// row. **On the people a source suggests, one line and it is dim**: a source takes "don't
    /// suggest" only from a sign-in that may change the reader's account there, and no sign-in
    /// here is asked for that — so the line says why at the menu's head, takes no press, and
    /// nothing is sent.
    func more(language: DummyLanguage? = nil) -> ShellMore? {
        guard list.which == .suggested else { return nil }
        let dismiss = ShellMark(Self.dismissSymbol, Self.dismissName(language: language), look: .dim(.askAgain))
        return ShellMore.ending(in: .plain(dismiss, act: {}), dimFor: Self.dismissDim(source, language: language))
    }
}

/// A list of people, opened: a way back, whose list it is and what its source counts, and the
/// people the source gave — the person page's shape, for a page of people.
///
/// **A step of the walk like that page**, so the way back, the lamp and the row given back on
/// leaving somebody's page are the walk's own. It draws what it is handed and asks nothing: the
/// asking is `ShellPeoplePages`'s, and which kind of source this is is never looked at here.
struct PeoplePane: View {
    let said: PeopleSaid
    @Binding var selectedID: String?
    /// A row opened: that person's page, answered by the root under the walk's own rule.
    var onOpen: (Person) -> Void
    /// "Try again": the list asked from the top.
    var onAskAgain: () -> Void = {}
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            ShellRule()
            PeopleHead(list: said.list, sorting: said.sorting, chooses: said.choosesSorting, onChoose: onChoose)
            ShellRule()
            list
        }
    }

    /// The person page's own bar: one way back for every step of the walk.
    private var bar: some View {
        HStack(spacing: ShellSpace.snug) {
            ShellBackButton("person.back", action: onBack)
            Spacer()
            ShellKeyHint("person.leaveHint")
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
    }

    /// The people the source gave, as the one list a tab of somebody's page draws too.
    private var list: some View {
        PeopleRows(
            said: said, selectedID: $selectedID, onOpen: onOpen, onAskAgain: onAskAgain, onReadOn: onReadOn,
            onAct: onAct, onAsk: onAsk, jumpToTop: jumpToTop
        )
    }

    /// The `…` of a row of `said`, or nothing where its list has nothing to do to a row.
    /// **No item here asks first**, so no question is ever put and none is hung.
    static func menu(for said: PeopleSaid) -> NoticeRow.Menu? {
        said.more().map { more in NoticeRow.Menu(more: { more }, asks: .constant(nil)) }
    }

    /// The `…` of the row of `person` in `said`: what the list offers a row that takes
    /// something away (#313) — refusing a request, removing a follower — each asked about
    /// first, through the page's one asker; or what the list's own `…` holds, or nothing.
    @MainActor
    static func menu(
        for said: PeopleSaid, of person: Person, asks: Binding<ShellMoreAsk?>, act: @escaping (PersonAct) -> Void
    ) -> NoticeRow.Menu? {
        let dangerous = said.dangerous
        guard !dangerous.isEmpty else { return menu(for: said) }
        let more = ShellMore(head: [person.lineName, person.lineHandle], items: dangerous.map { offered in
            .danger(
                PersonActing.symbol(offered), PersonActing.name(offered),
                asks: ShellQuestion.about(offered, person.lineHandle, at: said.source)
            ) { act(offered) }
        })
        return NoticeRow.Menu(more: { more }, asks: asks)
    }
}

/// The head of a list of people: whose list this is and which source keeps it, and under them
/// what that source counts — said as its figure, in its name, since the rows below may be fewer.
///
/// **A directory's head says how it is being read, and holds the one control that chooses**
/// (#315): where a list of somebody's has the source's count, a directory has a sentence — in
/// which order, and whether only of the people who live there — and beside it a menu named by
/// the order in force. The sentence and the title are the heading a listener hears; the menu
/// is an element of its own after it.
struct PeopleHead: View {
    let list: PeopleList
    var sorting: DirectoryChoice?
    /// Whether the control takes a press: not while the directory is being asked from the top.
    var chooses = true
    var onChoose: (DirectoryChoice) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(PeopleSaid.title(list))
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let figure = sorting.map({ PeopleSaid.sortingLine($0, source: list.host) }) ?? PeopleSaid.counts(list) {
                    Text(figure)
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(HeadElement(alone: sorting != nil))
            if let sorting {
                DirectoryChoiceMenu(choice: sorting, source: list.host, onChoose: onChoose)
                    .disabled(!chooses)
                    .fixedSize()
            } else {
                ShellWellPill(list.host).fixedSize()
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

/// How a source's directory is read, chosen behind one press in the page's head: a menu named
/// by the order in force, as the notices' page keeps its kinds behind one mark. The two orders
/// are the two a source takes; under them, only the people who live there.
///
/// It chooses and asks nothing itself: the asking is `ShellPeoplePages`'s.
struct DirectoryChoiceMenu: View {
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
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                Text(PeopleSaid.orderName(choice.order))
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .shellFont(.meta, weight: .medium)
            .foregroundStyle(isEnabled ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkFaint(colorScheme))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .shellNamed("people.directory.choose")
        .accessibilityValue(PeopleSaid.sortingLine(choice, source: source))
    }
}

/// The way to the people who ask to follow the reader, on their own page (#313): one line of
/// "You there" on About, and what its press does.
///
/// **Its figure is the source's, as the sign-in's own account check last said it** — the one
/// place a source says how many ask — and never arithmetic: it does not count down when a
/// request is answered here, and changes when that check next runs. Where the check said
/// none, the line is words alone.
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
        if counted == 0 { return L10n.t("people.requests.entry.none", language: language) }
        return PersonSaid.figure("people.requests.entry.count", counted, language: language)
    }
}
