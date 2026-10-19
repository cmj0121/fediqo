import FediqoCore
import SwiftUI

/// The hashtags the reader follows at a source, opened: a page of its own (F10), drawn in the
/// frame every opened page stands in (`OpenedPage`), with no tabs. Its bar holds the way back
/// and the mark that asks the source again; its head says what the list is and which source
/// keeps it, and draws no figure; under them are the hashtags, as a page of rising ones draws
/// them, each with its `…`.
///
/// **A step of the walk like somebody's page.** It draws what it is handed and asks nothing:
/// the asking is `ShellFollowedTags`'s, a row's press is the hashtag page's own, and which kind
/// of source this is is never looked at here. **At an accessibility text size the head is the
/// list's first rows**, and scrolls away with it.
struct FollowedTagsPane: View {
    let said: FollowedTagsSaid
    @Binding var selectedID: String?
    /// How far a sideways swipe has slid the list.
    var slide = PageSlide()
    /// What the bar's mark is called, or nothing where there is nobody to ask again.
    var reload: String?
    /// A row opened: that hashtag's page, answered by the root under the walk's own rule.
    var onOpen: (RisingRow) -> Void
    /// The bar's mark: what `r` does.
    var onReload: () -> Void = {}
    /// The same, pulled for: it returns when the answer has landed.
    var onPull: () async -> Void = {}
    /// What stops the list's ask while it runs: the bar's mark is then Stop.
    var onStop: (() -> Void)?
    /// The foot's press: the next stretch.
    var onReadOn: () -> Void = {}
    /// The item of a row's `…` that follows (true) or unfollows (false): what it offered when
    /// the menu was built, and only that.
    var onAct: (FollowedTagRow, Bool) -> Void = { _, _ in }
    /// The item that asks the sign-in for the rest of who the reader follows.
    var onAsk: () -> Void = {}
    var jumpToTop: Int = 0
    var onBack: () -> Void

    /// The page's one asker, as a row's menu is handed one: no item here asks first.
    @State private var asked: ShellMoreAsk?

    /// What the bar's mark is called — the source it asks — where `r` would ask it again; with
    /// nobody to ask there is no mark, not a dim one, and a pull asks nothing.
    static func reloadName(of said: FollowedTagsSaid, canReload: Bool, language: DummyLanguage? = nil) -> String? {
        canReload ? PersonPage.reloadName(said.page.host, language: language) : nil
    }

    /// What the frame presses on this page. **Stop is the list's own** (decision 10): handed
    /// while the list is asked of its source, it stops that ask and nothing else — never a
    /// reload of the stream running out of sight under the page.
    static func acts(
        onBack: @escaping () -> Void, onReload: @escaping () -> Void, onPull: @escaping () async -> Void,
        onStop: (() -> Void)? = nil
    ) -> OpenedPageActs<SoleTab> {
        OpenedPageActs(onBack: onBack, onReload: onReload, onPull: onPull, onStop: onStop)
    }

    var body: some View {
        OpenedPage(
            tabs: SoleTab.tabs, front: .sole, slide: slide, reload: reload,
            acts: Self.acts(onBack: onBack, onReload: onReload, onPull: onPull, onStop: onStop),
            head: {
                FollowedTagsHead(said: said)
                ShellRule()
            },
            inFront: { lead in FollowedTagsList(said: said, selectedID: $selectedID, acts: listActs, asked: $asked, jumpToTop: jumpToTop) { lead } }
        )
        .modifier(ShellMoreAsks(asked: $asked))
    }

    private var listActs: FollowedTagsActs {
        FollowedTagsActs(onOpen: onOpen, onReadOn: onReadOn, onAct: onAct, onAsk: onAsk)
    }
}

/// The head of the hashtags followed: what the list is and which source keeps it — **and no
/// figure**: how many are shown is the rows themselves. One heading to a listener, the source's
/// pill within it.
struct FollowedTagsHead: View {
    let said: FollowedTagsSaid
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            Text(FollowedTagsSaid.title())
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ShellWellPill(said.page.host).fixedSize()
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// What the list of the hashtags followed presses, each answered by the page's owner.
struct FollowedTagsActs {
    var onOpen: (RisingRow) -> Void
    var onReadOn: () -> Void
    var onAct: (FollowedTagRow, Bool) -> Void
    var onAsk: () -> Void
}

/// The hashtags followed, as the list under the head: the rows, the sentence where there are
/// none, and the foot that reads on — the asking is the page's toast — led by the head where it
/// scrolls away.
struct FollowedTagsList<Lead: View>: View {
    let said: FollowedTagsSaid
    @Binding var selectedID: String?
    let acts: FollowedTagsActs
    @Binding var asked: ShellMoreAsk?
    var jumpToTop: Int = 0
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellTouch) private var touch

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    lead
                    ForEach(Array(said.rows.enumerated()), id: \.element.id) { index, row in
                        self.row(row)
                            .id(row.id)
                        if index < said.rows.count - 1 { ShellRule() }
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
                            onPress: acts.onReadOn
                        )
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            // Come back to from a hashtag's page, the row it was opened from is in view.
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

    /// One hashtag. A press lights the row, and a second on the row it is already on opens
    /// it — `DummyCommand.tapped`, as on every list; under a finger one press opens.
    private func row(_ row: FollowedTagRow) -> some View {
        // The menu is built when it is opened; what `…` is called is known without it.
        let offer = said.offer(for: row)
        let menu = offer.map { _ in
            NoticeRow.Menu(more: { said.more(for: row, act: { acts.onAct(row, $0) }, ask: acts.onAsk) ?? ShellMore(items: []) }, asks: $asked)
        }
        return RisingRowView(
            row: row.listed,
            selected: row.id == selectedID,
            onPress: {
                switch DummyCommand.tapped(row.id, selected: selectedID, touch: touch) {
                case .select: selectedID = row.id
                case .open: acts.onOpen(row.listed)
                }
            },
            onOpen: { acts.onOpen(row.listed) },
            said: row.words(),
            missed: row.missedWords(),
            menu: menu,
            menuLabel: offer.map { ShellMore.label(only: FollowedTagsSaid.name(of: $0, on: row)) }
        )
    }
}
