import FediqoCore
import SwiftUI

/// The one line of somebody's page that stands between its head and its tabs, seen from every
/// tab: where asking who they are stands, or what the source says has become of the account.
///
/// **One at a time, the first that applies**: asking · could not ask, with the press that
/// asks again · not heard of · asked again and it failed · suspended · moved, with the press
/// that opens where they went.
struct PersonLineSaid: Equatable {
    let words: String
    /// A glyph before the words, where the line is about the account.
    var symbol: String?
    /// Whether it is said quietly: an ask on its way, and nothing that went wrong.
    var faint = false
    /// Whether "Try again" stands beside it, and whether that press is taken now.
    var again = false
    var busy = false
    /// Where they went, on the line that says they moved: what its press opens.
    var moved: Person.Moved?

    /// The line of the page of somebody a row called `named`, or nothing where the source has
    /// said who they are and nothing has become of the account.
    static func made(of said: PersonSaid, named: String, language: DummyLanguage? = nil) -> PersonLineSaid? {
        if let words = said.stateLine(of: named, language: language) {
            return PersonLineSaid(words: words, faint: said.reading == .asking, again: said.offersAgain, busy: said.asking)
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
    /// "Try again", where the source could not be asked who they are.
    var onAskAgain: () -> Void = {}
    var onLookUp: (SearchLookUpLine.Press) -> Void = { _ in }
    var onHome: (PersonHomeLine.Press) -> Void = { _ in }
    /// The press beside "They moved to …".
    var onOpenMoved: (Person.Moved) -> Void = { _ in }
    var onFollowed: (FollowedTagsEntry) -> Void = { _ in }
    /// The way to the people who ask to follow the reader, pressed on their own page.
    var onRequests: (RequestsEntry) -> Void = { _ in }
    /// A press on a row of the list in front that removes a follower (#313).
    var onListAct: (PersonAct, Person) -> Void = { _, _ in }
    /// The head's Follow, or an item of the `…`.
    var onAct: (PersonAct) -> Void = { _ in }
    /// The press on the lock of a sign-in that was not asked for following.
    var onAskFollows: () -> Void = {}
    /// "Try again", where the source could not be asked how the reader stands to them.
    var onStandingAgain: () -> Void = {}
    /// The foot under their posts, and under what they pinned; and "Try again" over those.
    var onReadOn: () -> Void = {}
    var onPinnedAgain: () -> Void = {}
    var onPinnedReadOn: () -> Void = {}
    /// A row of the list in front opened, that list asked again, and its foot.
    var onOpenListed: (Person) -> Void = { _ in }
    var onListAgain: () -> Void = {}
    var onListReadOn: () -> Void = {}
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

/// Somebody, opened: a page of its own (F9). A way back, who they are, the page's line, its
/// tabs, and the tab in front — the whole height of the pane, with no timeline's names over it.
///
///     ‹ Back                                                   [↻]   Esc or q
///     ─────────────────────────────────────────────────────────────────────────
///     head — `PersonHead`
///     ─────────────────────────────────────────────────────────────────────────
///     They moved to @alice@new.example.                  Open their new page
///     ─────────────────────────────────────────────────────────────────────────
///     (About)  (Following)  (Followers)  (Pinned)  (Posts)
///     ─────────────────────────────────────────────────────────────────────────
///     the tab in front
///
/// **It is handed everything it draws** — which tabs there are, which is in front, and each
/// part's own value — and asks nothing: which tabs a page has is decided where the source is
/// asked (`ShellPersonTabs`), and which kind of source this is is never looked at here. **A
/// page handed one tab draws no strip**: a forum author's page is the bar, the heading it
/// always had, and what this device holds of theirs.
///
/// **At an accessibility text size the head and the line are the first rows of every tab's
/// list**, and scroll away with it: fixed, they would fill a small screen. The bar and the
/// tabs stay.
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
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Whether the head scrolls away with the tab in front, at `size`.
    static func headScrolls(at size: DynamicTypeSize) -> Bool { size.isAccessibilitySize }

    /// Whether the strip of tabs is drawn: only where there is more than one.
    static func stripDrawn(_ tabs: [PersonTab]) -> Bool { tabs.count > 1 }

    /// What the bar's mark is called: whom it asks again.
    static func reloadName(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("person.reload", language: language), source)
    }

    private var line: PersonLineSaid? {
        said.flatMap { PersonLineSaid.made(of: $0, named: person.handle ?? person.name) }
    }

    /// The line about their own server, where it stands over the tabs: where the source has
    /// not heard of them. Everywhere else it is About's.
    private var homeOverTabs: PersonHomeLine? { said?.reading == .unheardOf ? home : nil }

    var body: some View {
        let scrolls = Self.headScrolls(at: typeSize)
        VStack(alignment: .leading, spacing: 0) {
            bar
            ShellRule()
            if !scrolls { heading }
            if Self.stripDrawn(tabs) {
                strip
                ShellRule()
            }
            inFront { if scrolls { heading } }
                // One list per tab, so a tab brought in front is drawn afresh at its own lamp.
                .id(front)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(Slid(slide: slide))
                .modifier(PullsToReload(offered: { canReload }, reload: {}, settled: acts.onPull))
        }
        // A sideways swipe goes to the tab beside; on the first it leaves the page.
        .modifier(SwipesTabs(slide: slide, tabs: tabs, selected: front, leave: acts.onBack, select: acts.onTab))
    }

    /// The way back and the way out of the page, on the line the thread pane puts them on —
    /// one bar, so a reader who has learnt to leave a conversation has learnt to leave this —
    /// and, where there is anybody to ask, the mark that asks them again.
    private var bar: some View {
        HStack(spacing: ShellSpace.snug) {
            ShellBackButton("person.back", action: acts.onBack)
            Spacer()
            if canReload {
                let name = Self.reloadName(head.whose ?? person.host)
                Button(action: acts.onReload) {
                    Image(systemName: ReloadMark.reload.symbol)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .modifier(ShellGlyphBox())
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
            }
            ShellKeyHint("person.leaveHint")
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
    }

    /// Who they are, and under it the page's line where there is one.
    @ViewBuilder
    private var heading: some View {
        PersonHead(
            head: head, front: Self.stripDrawn(tabs) ? front : nil, onTab: acts.onTab, onAct: acts.onAct,
            onAskFollows: acts.onAskFollows, onStandingAgain: acts.onStandingAgain
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
                .foregroundStyle(line.faint ? ShellChrome.inkFaint(colorScheme) : ShellChrome.ink(colorScheme))
                .accessibilityElement(children: .combine),
                press: Group {
                    if line.again {
                        ShellLinkButton(L10n.t("person.retry"), action: acts.onAskAgain)
                            .disabled(line.busy)
                            .fixedSize()
                    } else if let moved = line.moved {
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

    /// The page's tabs, as every page with tabs draws them (`ShellTabs`): a pill each on a
    /// wide page, and on a narrow one the tab in front by name with a dot for each.
    private var strip: some View {
        ShellTabs(tabs, selected: front, slide: slide, onSelect: acts.onTab)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
    }

    /// The tab in front, with `lead` as the first rows of its list.
    @ViewBuilder
    private func inFront<Lead: View>(@ViewBuilder lead: () -> Lead) -> some View {
        switch front {
        case .about:
            if let about {
                PersonAbout(
                    said: about, lit: selectedID, jumpToTop: jumpToTop, onHome: acts.onHome, onFollowed: acts.onFollowed,
                    onAskFollows: acts.onAskFollows, onStandingAgain: acts.onStandingAgain, onAct: acts.onAct, onRequests: acts.onRequests,
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
            if let pinned { postRows(pinned, again: acts.onPinnedAgain, readOn: acts.onPinnedReadOn, lead: lead) }
        case .posts:
            postRows(posts, again: {}, readOn: acts.onReadOn, lead: lead)
        }
    }

    private func postRows<Lead: View>(
        _ said: PostRowsSaid, again: @escaping () -> Void, readOn: @escaping () -> Void, @ViewBuilder lead: () -> Lead
    ) -> some View {
        PersonPane(
            said: said, catalogues: rows.catalogues, catalogueSettled: rows.catalogueSettled, posts: rows.posts,
            selectedID: $selectedID, acting: rows.acting, decks: $decks, playback: rows.playback,
            onPlayRow: rows.onPlayRow, onViewRow: rows.onViewRow, onTurnRow: rows.onTurnRow,
            onOpenThread: rows.onOpenThread, jumpToTop: jumpToTop, onAskAgain: again, onReadOn: readOn, lead: lead
        )
    }
}
