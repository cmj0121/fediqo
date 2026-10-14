import FediqoCore
import SwiftUI

/// What a search found at one source, opened (F10): one page in the frame every opened page
/// stands in — the bar, the head that says once whose answer this is and to what, People ·
/// Hashtags where the source gave both, and the tab in front.
///
/// **It draws what it is handed and asks nothing**: which tabs there are, which is in front
/// and what each lists are worked out where the answer is held (`ShellSearchFound`) and where
/// the people are asked (`ShellPeoplePages`), and which kind of source it is is never looked
/// at here. With one tab there is no strip, and the page is that one list.
struct FoundPage: View {
    let said: FoundSaid
    @Binding var selectedID: String?
    var slide = PageSlide()
    /// What the bar's mark is called, or nothing where there is nobody to ask again.
    var reload: String?
    var acts = OpenedPageActs<FoundWhich>()
    /// A row of the people opened: that person's page, answered by the root.
    var onOpenPerson: (Person) -> Void = { _ in }
    /// A row of the hashtags opened: that hashtag's page, answered by the root.
    var onOpenRow: (SearchFoundRow) -> Void = { _ in }
    /// The people's "Try again": their list asked from the top.
    var onAskAgain: () -> Void = {}
    /// The people's foot: the next stretch.
    var onReadOn: () -> Void = {}
    var onAct: (PersonAct, Person) -> Void = { _, _ in }
    var onAsk: () -> Void = {}
    var jumpToTop: Int = 0

    /// What the bar's mark is called — the source it asks — where `r` would ask it again:
    /// **on People only**, whose list is asked of the source; the hashtags are what the answer
    /// already held, and have nobody to ask. Then there is no mark, not a dim one, and a pull
    /// asks nothing.
    static func reloadName(of said: FoundSaid, canReload: Bool, language: DummyLanguage? = nil) -> String? {
        said.which == .people && canReload ? PersonPage.reloadName(said.at.source, language: language) : nil
    }

    /// What the frame presses on this page. **No Stop**: the page's asks are its source's and
    /// never the timeline's reload, so a Stop in its bar could only stop a reload running out of
    /// sight under it.
    static func acts(
        onBack: @escaping () -> Void, onTab: @escaping (FoundWhich) -> Void, onReload: @escaping () -> Void,
        onPull: @escaping () async -> Void
    ) -> OpenedPageActs<FoundWhich> {
        OpenedPageActs(onBack: onBack, onTab: onTab, onReload: onReload, onPull: onPull, onStop: nil)
    }

    var body: some View {
        OpenedPage(
            tabs: said.tabs, front: said.which, slide: slide, reload: reload, acts: acts,
            head: {
                FoundHead(at: said.at)
                ShellRule()
            },
            inFront: { lead in front { lead } }
        )
    }

    /// The tab in front: the people, as every list of people draws them, or the hashtags.
    @ViewBuilder
    private func front<Lead: View>(@ViewBuilder lead: () -> Lead) -> some View {
        if let people = said.people {
            PeopleRows(
                said: people, selectedID: $selectedID, onOpen: onOpenPerson, onAskAgain: onAskAgain, onReadOn: onReadOn,
                onAct: onAct, onAsk: onAsk, jumpToTop: jumpToTop, lead: lead
            )
        } else if let tags = said.tags {
            FoundTagsList(said: tags, selectedID: $selectedID, onOpen: onOpenRow, jumpToTop: jumpToTop, lead: lead)
        }
    }
}

/// The head of the page of what a search found: whose answer this is, and to what — said once,
/// whichever tab is in front.
struct FoundHead: View {
    let at: FoundAt
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(FoundAt.title(at.source))
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(at.headLine())
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The tab of the hashtags a source found: every one its answer held, as the page of rising
/// hashtags draws them, and under them whether that was all — led by the page's head where the
/// head scrolls away. Drawn from what the search already holds: nothing is asked by it.
struct FoundTagsList<Lead: View>: View {
    let said: FoundTagsSaid
    @Binding var selectedID: String?
    var onOpen: (SearchFoundRow) -> Void
    var jumpToTop: Int = 0
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    /// Under a finger one press on a row opens it (#303); the lamp here is where the walk left it.
    @Environment(\.shellTouch) private var touch

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    lead
                    ForEach(said.rows) { row in
                        SearchFoundRowView(row: row, selected: row.id == selectedID, onPress: { press(row) }, onOpen: { onOpen(row) })
                            .id(row.id)
                        ShellRule()
                    }
                    Text(said.foot())
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(ShellSpace.pad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            .onAppear {
                if let id = DummyCommand.centredOnAppear(selected: selectedID) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jumpToTop) { _, _ in
                guard let first = said.rows.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    /// A press lights the row, and a second on the row it is already on opens it —
    /// `DummyCommand.tapped`, as on every list; under a finger one press opens.
    private func press(_ row: SearchFoundRow) {
        switch DummyCommand.tapped(row.id, selected: selectedID, touch: touch) {
        case .select: selectedID = row.id
        case .open: onOpen(row)
        }
    }
}
