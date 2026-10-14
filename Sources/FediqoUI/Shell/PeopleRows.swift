import FediqoCore
import SwiftUI

/// The people a source gave for a list, as one list that scrolls together: where the asking
/// stands, each of them on a row, what stands where they would where it gave nobody, and the
/// foot.
///
/// **One list for a page of people and for a tab of somebody's page** (`PeoplePane`, and the
/// Following and Followers tabs): the same rows, the same sentences, the same foot. It draws
/// what it is handed and asks nothing — the asking is `ShellPeoplePages`'s.
struct PeopleRows<Lead: View>: View {
    let said: PeopleSaid
    @Binding var selectedID: String?
    /// A row opened: that person's page, answered by the root under the walk's own rule.
    var onOpen: (Person) -> Void
    /// "Try again": the list asked from the top.
    var onAskAgain: () -> Void = {}
    /// The foot's press: the next stretch.
    var onReadOn: () -> Void = {}
    /// A press on a row that answers a request or removes a follower (#313).
    var onAct: (PersonAct, Person) -> Void = { _, _ in }
    /// The press on the lock of a sign-in that may not change who follows whom.
    var onAsk: () -> Void = {}
    var jumpToTop: Int = 0
    /// What stands over the rows and scrolls away with them. Nothing on a page of people.
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    /// Under a finger one press on a row opens it (#303); the lamp here is where the walk left it.
    @Environment(\.shellTouch) private var touch
    /// The question of a row's `…` item that asks first: put once, by this list.
    @State private var asked: ShellMoreAsk?

    private static var top: String { "people.top" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    lead
                    if let line = said.stateLine() {
                        stateLine(line)
                        ShellRule()
                    }
                    if let words = said.lockWords() {
                        locked(words, asks: said.lock?.asks == true)
                        ShellRule()
                    }
                    ForEach(Array(said.people.enumerated()), id: \.element.id) { index, person in
                        row(person)
                            .id(person.id)
                        if let missed = said.missed[person.accountID] { quiet(missed, ink: ShellChrome.ink(colorScheme)) }
                        if index < said.people.count - 1 { ShellRule() }
                    }
                    if let sentence = said.nothing() { quiet(sentence, ink: ShellChrome.inkFaint(colorScheme)) }
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
            .modifier(ShellMoreAsks(asked: $asked))
            // Come back to from somebody's page, the row they were opened from is in view.
            .onAppear {
                if let id = DummyCommand.centredOnAppear(selected: selectedID) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jumpToTop) { _, _ in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(Self.top, anchor: .top) }
            }
        }
    }

    /// Where the asking stands, and beside a failure the press that asks again.
    private func stateLine(_ line: String) -> some View {
        WordsThenPress(
            words: Text(line)
                .shellFont(.meta)
                .foregroundStyle(
                    said.reading == .asking || said.reading == .absent
                        ? ShellChrome.inkFaint(colorScheme) : ShellChrome.ink(colorScheme)
                ),
            press: Group {
                if said.offersAgain {
                    let again = Self.again(said)
                    ShellLinkButton(again.words, action: onAskAgain)
                        .disabled(said.asking)
                        .fixedSize()
                        // Called by its words, as Voice Control hears them; whom it asks, told after.
                        .accessibilityHint(again.hint)
                }
            }
        )
    }

    /// The press that asks the list again beside a failure: its words as drawn, which are its
    /// name to a listener and to Voice Control, and whom it asks, told after them.
    static func again(_ said: PeopleSaid, language: DummyLanguage? = nil) -> (words: String, hint: String) {
        (L10n.t(said.reading == .absent ? "source.more.again" : "person.retry", language: language),
         PersonPage.reloadName(said.source, language: language))
    }

    /// One of them. A press lights the row, and a second on the row it is already on opens
    /// them — `DummyCommand.tapped`, as on every list; under a finger one press opens.
    private func row(_ person: Person) -> some View {
        PersonRow(
            person: person,
            stands: said.stands[person.accountID],
            selected: person.id == selectedID,
            onPress: {
                switch DummyCommand.tapped(person.id, selected: selectedID, touch: touch) {
                case .select: selectedID = person.id
                case .open: onOpen(person)
                }
            },
            onOpen: { onOpen(person) },
            menu: PeoplePane.menu(for: said, of: person, asks: $asked) { onAct($0, person) },
            accept: said.accepts ? { onAct(.acceptRequest, person) } : nil
        )
    }

    /// How the sign-in stands, dim, after the glyph a source's row draws where its sign-in
    /// must be asked again: the whole line the press where it asks, and words where not.
    @ViewBuilder
    private func locked(_ words: String, asks: Bool) -> some View {
        let label = Label(words, systemImage: SourceRow.permissionSymbol)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.markDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
        if asks {
            Button(action: onAsk) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(L10n.t("mark.dim.askAgain"))
        } else {
            label
        }
    }

    /// A sentence in the list's own column: what stands where rows would, and under a row
    /// the press that did not arrive.
    private func quiet(_ sentence: String, ink: Color) -> some View {
        Text(sentence)
            .shellFont(.meta)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(ShellSpace.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PeopleRows where Lead == EmptyView {
    init(
        said: PeopleSaid, selectedID: Binding<String?>, onOpen: @escaping (Person) -> Void,
        onAskAgain: @escaping () -> Void = {}, onReadOn: @escaping () -> Void = {},
        onAct: @escaping (PersonAct, Person) -> Void = { _, _ in }, onAsk: @escaping () -> Void = {}, jumpToTop: Int = 0
    ) {
        self.init(
            said: said, selectedID: selectedID, onOpen: onOpen, onAskAgain: onAskAgain, onReadOn: onReadOn,
            onAct: onAct, onAsk: onAsk, jumpToTop: jumpToTop, lead: { EmptyView() }
        )
    }
}
