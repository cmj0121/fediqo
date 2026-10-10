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
    /// Whether the list is being asked from the top.
    var asking = false
    var foot: Foot?

    /// The host of the source that says.
    var source: String { list.host }

    // MARK: - Words

    /// Whose list it is, in the page's head. **Their handle is a stranger's word set in a
    /// sentence of ours**, and is the one made fit for a line.
    static func title(_ list: PeopleList, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("people.title.\(list.which.rawValue)", language: language), list.lineHandle)
    }

    /// What the source counts in the list, where it said: its figure, said as its figure.
    static func counts(_ list: PeopleList, language: DummyLanguage? = nil) -> String? {
        list.counted.map {
            String(format: L10n.t("people.counts", language: language), list.host, L10n.grouped($0, language: language))
        }
    }

    /// What is said above the rows: that the list is being asked for, that it could not be —
    /// or, once the source has given it, what asking again came to.
    func stateLine(language: DummyLanguage? = nil) -> String? {
        switch reading {
        case .asking: String(format: L10n.t("people.asking", language: language), source)
        case .failed: String(format: L10n.t("people.failed", language: language), source)
        case .said: againFailed ? String(format: L10n.t("people.again.failed", language: language), source) : nil
        }
    }

    /// Whether the line above the rows offers the press that asks again.
    var offersAgain: Bool { reading == .failed || againFailed }

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
        if list.hidden, !own {
            return String(format: L10n.t("people.hidden", language: language), list.lineHandle)
        }
        if let counted = list.counted, counted > 0 {
            return String(format: L10n.t(signedIn ? "people.noneOf" : "people.noneOf.unsigned", language: language), source)
        }
        return String(format: L10n.t("people.none", language: language), source)
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
    var jumpToTop: Int = 0
    var onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// Under a finger one press on a row opens it (#303); the lamp here is where the walk left it.
    @Environment(\.shellTouch) private var touch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            ShellRule()
            PeopleHead(list: said.list)
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

    /// Top to bottom, as one list that scrolls together: where the asking stands, the people
    /// the source gave, what stands where they would where it gave nobody, and the foot.
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let line = said.stateLine() {
                        stateLine(line)
                        ShellRule()
                    }
                    ForEach(Array(said.people.enumerated()), id: \.element.id) { index, person in
                        row(person)
                            .id(person.id)
                        if index < said.people.count - 1 { ShellRule() }
                    }
                    if let sentence = said.nothing() {
                        Text(sentence)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(ShellSpace.pad)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let foot = said.foot {
                        ShellRule()
                        PersonFootRow(
                            symbol: said.footSymbol(foot), words: said.footWords(foot), presses: foot.presses,
                            onPress: onReadOn
                        )
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            // Come back to from somebody's page, the row they were opened from is in view.
            .onAppear {
                if let id = DummyCommand.centredOnAppear(selected: selectedID) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jumpToTop) { _, _ in
                guard let first = said.people.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    /// Where the asking stands, and beside a failure the press that asks again.
    private func stateLine(_ line: String) -> some View {
        WordsThenPress(
            words: Text(line)
                .shellFont(.meta)
                .foregroundStyle(said.reading == .asking ? ShellChrome.inkFaint(colorScheme) : ShellChrome.ink(colorScheme)),
            press: Group {
                if said.offersAgain {
                    ShellLinkButton(L10n.t("person.retry"), action: onAskAgain)
                        .disabled(said.asking)
                        .fixedSize()
                }
            }
        )
    }

    /// One of them. A press lights the row, and a second on the row it is already on opens
    /// them — `DummyCommand.tapped`, as on every list; under a finger one press opens.
    private func row(_ person: Person) -> some View {
        PersonRow(
            person: person,
            selected: person.id == selectedID,
            onPress: {
                switch DummyCommand.tapped(person.id, selected: selectedID, touch: touch) {
                case .select: selectedID = person.id
                case .open: onOpen(person)
                }
            },
            onOpen: { onOpen(person) }
        )
    }
}

/// The head of a list of people: whose list this is and which source keeps it, and under them
/// what that source counts — said as its figure, in its name, since the rows below may be fewer.
struct PeopleHead: View {
    let list: PeopleList
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(PeopleSaid.title(list))
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let figure = PeopleSaid.counts(list) {
                    Text(figure)
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ShellWellPill(list.host).fixedSize()
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
