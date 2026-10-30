import FediqoCore
import SwiftUI

/// The one line of somebody's page that stands between its head and its tabs, seen from every
/// tab: that the source has not heard of them, or what it says has become of the account.
///
/// **One at a time, the first that applies**: not heard of · not heard of on asking again ·
/// suspended · moved, with the press that opens where they went. Being asked, and an ask that
/// came to nothing, are the page's toast to say (DESIGN-reload).
struct PersonLineSaid: Equatable {
    let words: String
    /// A glyph before the words, where the line is about the account.
    var symbol: String?
    /// Where they went, on the line that says they moved: what its press opens.
    var moved: Person.Moved?

    /// The line of the page, or nothing where the source has said who they are and nothing
    /// has become of the account.
    static func made(of said: PersonSaid, language: DummyLanguage? = nil) -> PersonLineSaid? {
        if let words = said.stateLine(language: language) {
            return PersonLineSaid(words: words)
        }
        guard let person = said.person,
              let line = PersonSaid.standing(of: person, source: said.source, language: language)
        else { return nil }
        return PersonLineSaid(words: line.words, symbol: line.symbol, moved: line.moved)
    }
}

/// What the parts of somebody's page press: each answered by whoever holds the walk and the
/// pages, so the page draws and asks nothing.
struct PersonPageActs {
    var onBack: () -> Void = {}
    /// A tab's pill pressed, or the figure that counts it: that tab, brought in front.
    var onTab: (PersonTab) -> Void = { _ in }
    /// The bar's mark: who they are and the tab in front, asked again.
    var onReload: () -> Void = {}
    /// The same, pulled for: it returns when the answers have landed.
    var onPull: () async -> Void = {}
    /// What stops the page's asks while one the reader pressed for runs: the bar's mark is
    /// then Stop.
    var onStop: (() -> Void)?
    var onLookUp: (SearchLookUpLine.Press) -> Void = { _ in }
    var onHome: (PersonHomeLine.Press) -> Void = { _ in }
    /// The press beside "They moved to …".
    var onOpenMoved: (Person.Moved) -> Void = { _ in }
    var onFollowed: (FollowedTagsEntry) -> Void = { _ in }
    /// The way to the people who ask to follow the reader, pressed on their own page.
    var onRequests: (RequestsEntry) -> Void = { _ in }
    var onKeeping: (KeepingEntry) -> Void = { _ in }
    /// What they feature, pressed on About (#315, #318): a hashtag, the people, or asking again.
    var onFeatured: (FeaturedPress) -> Void = { _ in }
    /// A press on a row of the list in front that removes a follower (#313).
    var onListAct: (PersonAct, Person) -> Void = { _, _ in }
    /// The head's Follow, or an item of the `…`.
    var onAct: (PersonAct) -> Void = { _ in }
    /// The reader's note on them written (#377), or — with nothing — the account part asked for.
    var onNote: (String?) -> Void = { _ in }
    /// The languages of their posts that reach Home, chosen on About (#378).
    var onLanguages: ([String]) -> Void = { _ in }
    /// The press on the lock of a sign-in that was not asked for following.
    var onAskFollows: () -> Void = {}
    /// Change, on the reader's own page.
    var onChange: () -> Void = {}
    /// The foot under their posts, and under what they pinned.
    var onReadOn: () -> Void = {}
    var onPinnedReadOn: () -> Void = {}
    /// A row of the list in front opened, that list asked again where its source says it has
    /// none such, and its foot.
    var onOpenListed: (Person) -> Void = { _ in }
    var onListAgain: () -> Void = {}
    var onListReadOn: () -> Void = {}
    /// The sheet of an act on them, from About's staff block (#382).
    var onStaffAct: (TendingStaffSaid) -> Void = { _ in }
    /// Which of the reader's lists they are on (#337), from the page's `…`.
    var onLists: () -> Void = {}
    /// Which of the reader's collections they are in (#433), from the page's `…`.
    var onCollections: () -> Void = {}
}

/// What the post rows of somebody's page are drawn with: the thread pane's own fittings,
/// handed through as one thing.
struct PersonPageRows {
    let catalogues: EmojiCatalogueStore
    var catalogueSettled = false
    let posts: ForumPosts
    var acting: (DummyItem) -> ItemActing = { _ in ItemActing() }
    let playback: ShellPlayback
    var onPlayRow: (DummyItem) -> Void
    var onViewRow: (DummyItem) -> Void
    var onTurnRow: (DummyItem) -> Void
    var onOpenThread: (String) -> Void
}

/// Somebody, opened: a page of its own (F9), drawn in the frame every opened page stands in
/// (`OpenedPage`). Who they are and the page's line are its head; its tabs and the tab in
/// front are what the frame is handed.
///
/// **It is handed everything it draws** — which tabs there are, which is in front, and each
/// part's own value — and asks nothing: which tabs a page has is decided where the source is
/// asked (`ShellPersonTabs`), and which kind of source this is is never looked at here. **A
/// page handed one tab draws no strip**: a forum author's page is the bar, the heading it
/// always had, and what this device holds of theirs.
struct PersonPage: View {
    let person: DummyPerson
    let tabs: [PersonTab]
    let front: PersonTab
    let head: PersonHeadSaid
    /// What their source says of them, where it says who people are: what the page's line is
    /// made from. Nothing on a page handed no word of a source.
    var said: PersonSaid?
    var about: PersonAboutSaid?
    /// The rows of the Posts tab, and of the Pinned one where the page has it.
    var posts: PostRowsSaid
    var pinned: PostRowsSaid?
    /// The list of people in front, where the tab in front is one.
    var people: PeopleSaid?
    /// Where the source has not heard of them: the press that asks it to look them up, and
    /// the line about the server they live on.
    var lookUp: SearchLookUpLine?
    var home: PersonHomeLine?
    let rows: PersonPageRows
    @Binding var selectedID: String?
    @Binding var decks: ShellDecks
    var jumpToTop: Int
    /// How far a sideways swipe has slid what is under the tabs.
    let slide: PageSlide
    /// Whether there is anybody to ask again: the bar's mark is absent where there is not.
    var canReload = false
    var acts = PersonPageActs()

    @Environment(\.colorScheme) private var colorScheme

    /// What the bar's mark is called: whom it asks again.
    static func reloadName(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("person.reload", language: language), source)
    }

    private var line: PersonLineSaid? {
        said.flatMap { PersonLineSaid.made(of: $0) }
    }

    /// The line about their own server, where it stands over the tabs: where the source has
    /// not heard of them. Everywhere else it is About's.
    private var homeOverTabs: PersonHomeLine? { said?.reading == .unheardOf ? home : nil }

    var body: some View {
        OpenedPage(
            tabs: tabs, front: front, slide: slide,
            // Whom the bar's mark asks again, where there is anybody to ask.
            reload: canReload ? Self.reloadName(head.whose ?? person.host) : nil,
            acts: OpenedPageActs(
                onBack: acts.onBack, onTab: acts.onTab, onReload: acts.onReload, onPull: acts.onPull, onStop: acts.onStop
            ),
            head: { heading },
            inFront: { lead in inFront { lead } }
        )
    }

    /// Who they are, and under it the page's line where there is one.
    @ViewBuilder
    private var heading: some View {
        PersonHead(
            head: head, front: PageFrame.stripDrawn(tabs) ? front : nil, onTab: acts.onTab, onAct: acts.onAct,
            onAskFollows: acts.onAskFollows, onChange: acts.onChange, onLists: acts.onLists, onCollections: acts.onCollections
        )
        ShellRule()
        if line != nil || lookUp != nil || homeOverTabs != nil {
            pageLine
            ShellRule()
        }
    }

    @ViewBuilder
    private var pageLine: some View {
        if let line {
            WordsThenPress(
                words: HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                    if let symbol = line.symbol { Image(systemName: symbol).accessibilityHidden(true) }
                    Text(line.words)
                }
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .accessibilityElement(children: .combine),
                press: Group {
                    if let moved = line.moved {
                        ShellLinkButton(PersonSaid.openMoved()) { acts.onOpenMoved(moved) }.fixedSize()
                    }
                }
            )
        }
        if let lookUp {
            SearchLookUpView(line: lookUp, onPress: acts.onLookUp)
                .padding(.horizontal, ShellSpace.pad)
                .padding(.vertical, ShellSpace.snug)
        }
        if let homeOverTabs { PersonHomeLineView(line: homeOverTabs, onPress: acts.onHome) }
    }

    /// The tab in front, with `lead` as the first rows of its list.
    @ViewBuilder
    private func inFront<Lead: View>(@ViewBuilder lead: () -> Lead) -> some View {
        switch front {
        case .about:
            if let about {
                PersonAbout(
                    said: about, lit: selectedID, jumpToTop: jumpToTop, onHome: acts.onHome, onFollowed: acts.onFollowed,
                    onAskFollows: acts.onAskFollows, onAct: acts.onAct, onRequests: acts.onRequests, onKeeping: acts.onKeeping,
                    onFeatured: acts.onFeatured, onStaffAct: acts.onStaffAct, onNote: acts.onNote,
                    onOpenPerson: acts.onOpenListed, onLanguages: acts.onLanguages,
                    lead: lead
                )
            }
        case .following, .followers:
            if let people {
                PeopleRows(
                    said: people, selectedID: $selectedID, onOpen: acts.onOpenListed, onAskAgain: acts.onListAgain,
                    onReadOn: acts.onListReadOn, onAct: acts.onListAct, onAsk: acts.onAskFollows, jumpToTop: jumpToTop,
                    lead: lead
                )
            }
        case .pinned:
            if let pinned { postRows(pinned, readOn: acts.onPinnedReadOn, lead: lead) }
        case .posts:
            postRows(posts, readOn: acts.onReadOn, lead: lead)
        }
    }

    private func postRows<Lead: View>(
        _ said: PostRowsSaid, readOn: @escaping () -> Void, @ViewBuilder lead: () -> Lead
    ) -> some View {
        PersonPane(
            said: said, catalogues: rows.catalogues, catalogueSettled: rows.catalogueSettled, posts: rows.posts,
            selectedID: $selectedID, acting: rows.acting, decks: $decks, playback: rows.playback,
            onPlayRow: rows.onPlayRow, onViewRow: rows.onViewRow, onTurnRow: rows.onTurnRow,
            onOpenThread: rows.onOpenThread, jumpToTop: jumpToTop, onReadOn: readOn, lead: lead
        )
    }
}
