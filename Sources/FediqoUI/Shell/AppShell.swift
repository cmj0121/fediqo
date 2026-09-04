import SwiftUI
import FediqoCore

/// Two columns: the action bar on the left, the display field on the right.
///
/// On a narrow screen — an iPhone — the destinations become a tab bar and New Post becomes
/// the button floating over it, which is the same arrangement as the rail: four places to
/// go, and one thing to do from wherever you are. The rail is a plain view rather than a
/// `NavigationSplitView` sidebar because a split view cannot be a fixed-width icon rail, and
/// how it collapses is the platform's decision rather than ours.
struct AppShell: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    /// The one way this app opens a link, lent to the app so that the key which opens a post
    /// and the menu item on the row itself are the same act.
    @Environment(\.openURL) private var openURL

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// The floor, and only the floor. A window narrower than a panel of prose has nothing to
    /// put beside the rail, and one shorter than this shows a single row and a scrollbar.
    private static let shortestUsefulColumn: CGFloat = 300
    /// The one thing on a phone that is not a place to go: the press that writes. Bigger than
    /// anything it floats over, and held clear of the tab bar underneath it.
    private static let composeButton: CGFloat = 54
    private static let aboveTabBar: CGFloat = 72

    private var railWidth: CGFloat {
        app.preferences.railExpanded ? RailView.expandedWidth : RailView.collapsedWidth
    }

    /// Whether the destinations are a tab bar or a rail. **The only thing this answer decides**,
    /// and the reason it is still a boolean while S9 has done away with the rest of them: a tab
    /// bar and a sidebar are two navigation idioms rather than two arrangements of one, they
    /// hold different state, and which of them a device expects is Apple's answer to give and
    /// not a width to measure. No screen below reads it; every one of them fits the room it is
    /// given instead.
    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        // One clock for the whole shell, keyed to the feed being read — the page, and the
        // tab within it — and how often it is to be read. `.task(id:)` cancels the old one
        // and starts the new one on every change, and cancels it altogether when the shell
        // goes away — so there is never a second one, and never one left running for a feed
        // nobody is looking at.
        layout
            // Over everything the shell draws, including the composer: what the reader asked
            // to look at is the thing in front of them until they leave it.
            .overlay { MediaViewer() }
            // What came of the last thing the reader asked for, at the foot of whatever they
            // are looking at. Above the viewer rather than under it: a message nothing can be
            // drawn over is the only kind worth showing at all.
            .overlay(alignment: .bottom) { ActionNotice() }
            // The keys, written down, over everything the shell draws — including the
            // composer, so `?` with a draft open puts the list in front of it rather than
            // behind it.
            .shortcutsOverlay()
            .onAppear { app.openLink = { openURL($0) } }
            // A hashtag in somebody's words is spelled as an address, because a pressable run
            // inside a line of prose is the one thing SwiftUI will put there and still let the
            // line wrap and be selected. This is where the app takes its own back: `fediqo-tag:`
            // opens a timeline of that tag and **never reaches a browser**, and every other
            // address goes out exactly as it did (#107).
            .environment(\.openURL, OpenURLAction { url in
                guard let tag = TagLink.tag(in: url) else { return .systemAction }
                app.openTag(tag)
                return .handled
            })
            .shellKeyPresses()
            .shellKeyCommands()
            .task(id: app.refreshKey) { await app.refreshWhileVisible() }
            // Once, when the shell arrives. See `tidy`: the reader's own policy, applied when
            // they open the app rather than on a clock nobody sees.
            .task { await app.tidy() }
            // A run told to open the reader's own page does it once the accounts are known.
            // The same shape every other launch variable has, and the same reason (#30).
            .task(id: app.yourAccounts) {
                guard app.launchedOnYourPage, app.person == nil,
                      let mine = app.yourAccounts.first
                else { return }
                app.openYourPage(mine)
            }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if compact {
            tabbed
        } else {
            columns
        }
        #else
        columns
        #endif
    }

    private var columns: some View {
        HStack(spacing: 0) {
            RailView()
            Hairline(axis: .vertical)
            view(for: app.railItem)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface(colorScheme))
                .pagesOverThePage()
        }
        // The floor, and only the floor. Anything larger is the reader's business, and
        // anything that made this bigger than it needs to be was a bug.
        .frame(minWidth: Size.prose, minHeight: Self.shortestUsefulColumn)
        // Beside the bar, at the foot, next to the button that opened it.
        .composerPanel(
            alignment: .bottomLeading,
            inset: EdgeInsets(top: 0, leading: railWidth + Space.mid, bottom: Space.mid, trailing: 0)
        )
    }

    #if os(iOS)
    private var tabbed: some View {
        @Bindable var app = app
        return TabView(selection: $app.railItem) {
            ForEach(RailItem.allCases) { item in
                view(for: item)
                    .background(Palette.surface(colorScheme))
                    // Inside the tab rather than over the bar, for the reason it is inside the
                    // rail on the Mac: an opened post does not take the app's furniture away.
                    .pagesOverThePage()
                    .tabItem { Label(t(item.titleKey), systemImage: item.symbolName) }
                    .tag(item)
            }
        }
        .overlay(alignment: .bottomTrailing) { composeButton }
        .composerPanel(
            alignment: .bottomTrailing,
            inset: EdgeInsets(top: 0, leading: 0, bottom: Self.aboveTabBar + Self.composeButton + Space.pad,
                              trailing: Space.withinGroup)
        )
    }

    private var composeButton: some View {
        Button { app.toggleComposer() } label: {
            Image(systemName: "square.and.pencil")
                .fediqoSymbol(Glyph.action, weight: .semibold)
                .frame(width: Self.composeButton, height: Self.composeButton)
                .background(Circle().fill(Palette.accent))
                .foregroundStyle(Color.black.opacity(0.85))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, Space.room)
        .padding(.bottom, Self.aboveTabBar)
        .accessibilityLabel(Text(t("rail.compose")))
    }
    #endif

    @ViewBuilder
    private func view(for item: RailItem) -> some View {
        switch item {
        // A tab is its own screen, not the same screen handed different posts: the identity
        // is the tab's, so neither feed inherits the other's scroll position or its open
        // menus. What outlives the swap is what should — the two `FeedModel`s, which the app
        // holds rather than the screen, so nothing is re-asked and nothing is thrown away.
        //
        // The price is paid in both directions, and it is the price we chose. Going back to
        // a tab builds it afresh: its `.task` runs again — which asks the model nothing it
        // has already been asked — and the scroll position and any open sheet are gone.
        //
        // Where the reader was is now wanted, and it is kept the way this comment always said
        // it would have to be: beside the feeds rather than by dropping this `.id`. The ring
        // lives on the `FeedModel`, and `FeedScreen` scrolls to it once on the way in — so
        // the swap is still clean, and coming back is still a screen built from nothing.
        case .inbox: InboxScreen()
        case .timeline:
            if let timeline = app.readingTimeline {
                FeedScreen(timeline: timeline).id(timeline.id)
            } else {
                // Every timeline deleted. The page offers to make one rather than sitting
                // empty: an empty list of timelines is a state a reader can reach on purpose,
                // and the way back has to be on the page they reached it from.
                NoTimelinesView()
            }
        case .kept: KeptView()
        case .statistics: StatisticsView()
        case .settings: SettingsView()
        }
    }
}


/// An opened post, a person, and one of their lists — over whichever page the reader was on.
///
/// **The shell's and not one screen's.** These were three overlays on `FeedScreen`, which was
/// invisible the moment the inbox stopped being a sheet over the timeline and became a page
/// beside it — so a reader told that somebody had replied to them could press the line and
/// nothing at all happened (#123). An opened post over the inbox is the same opened post, and a
/// second stack of these on the second page would be two stacks to keep in step.
///
/// **Over the page and not over the shell**, which is the whole of where this goes. Put outside
/// the rail it covered the rail, and a reader with a post open could not reach another page
/// without closing it first — the furniture of the app is not a thing an opened post is allowed
/// to take away.
///
/// Over the list rather than instead of it: underneath, whichever page it was, the scroll
/// position and the ring stay exactly where the reader left them, so closing it gives back the
/// page they came from and never moves them to another one.
private struct PagesOverThePage: ViewModifier {
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content
            .overlay {
                if let opened = app.expanded {
                    PostPage(post: opened) { app.perform(.dismiss) }
                        .transition(.opacity)
                }
            }
            // A person over the post as well: the author is pressable on an opened post too, and
            // what was underneath keeps its place either way.
            .overlay {
                if let person = app.person {
                    PersonPage(model: person) { app.closePerson() }
                        .transition(.opacity)
                }
            }
            // And one of their two lists over that, because a list of somebody's followers is
            // somewhere you go from their page and come back to it from (#90).
            .overlay {
                if let people = app.people {
                    PeopleList(model: people) { app.closePeople() }
                        .transition(.opacity)
                }
            }
    }
}

extension View {
    func pagesOverThePage() -> some View { modifier(PagesOverThePage()) }
}
