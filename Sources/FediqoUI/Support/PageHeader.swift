import SwiftUI

/// The top of a page: what it is called, its tabs, and the line saying what the tab you are
/// on is.
///
/// One header for every page that has tabs, so that a reader crossing from the Timeline to
/// Settings arrives somewhere that is laid out the way the place they left was. It sits above
/// the scrolling rather than inside it — the name of the page is not something to scroll away
/// from — which is also what makes it the one place a page's controls can live.
///
/// What a header cannot say is which page it belongs to: the title comes from the rail item
/// and the tabs from the page, and both are handed in. A tab does not know its own page.
struct PageHeader<Tabs: View, Controls: View>: View {
    let titleKey: String
    /// The line describing the tab being shown. A page with tabs always has one, because the
    /// tabs are named in two words and two words are not an explanation.
    let subtitleKey: String
    /// Whether the page is waiting for something. A spinner beside the title, where the
    /// reader is already looking, rather than over the content they are still reading.
    var loading = false
    @ViewBuilder var tabs: Tabs
    @ViewBuilder var controls: Controls

    /// Whether there is one column's worth of room here rather than two. The shell decides
    /// it — it is the one place that knows what the platform will say — and this reads the
    /// answer rather than asking the platform a second time.
    @Environment(\.fediqoCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(t(titleKey)).fediqoFont(20, weight: .semibold).lineLimit(1)
                if loading { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
                controls
            }
            tabsAndSubtitle
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(PageHeaderBackground())
    }

    /// Which tab is showing, and the line saying what that tab is.
    ///
    /// Given a window's width they sit on one line, the control no wider than its words need.
    /// A phone has no such width: the control there would take what it was given and leave the
    /// description a couple of characters, so the two go one above the other and the control
    /// spreads across the row, which is how a segmented control looks on iOS anyway.
    @ViewBuilder
    private var tabsAndSubtitle: some View {
        if compact {
            tabs
            subtitle
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                tabs.fixedSize()
                subtitle
            }
        }
    }

    /// Beside the control it is given whatever is left of the row, so it is held to two lines
    /// rather than pushing the header down. On its own row it has the width to say the whole
    /// sentence, and a sentence cut off mid-word reads as a fault rather than a note.
    private var subtitle: some View {
        Text(t(subtitleKey))
            .fediqoFont(11)
            .foregroundStyle(.secondary)
            .lineLimit(compact ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension PageHeader where Controls == EmptyView {
    /// A page whose header carries nothing but its name and its tabs, which is most of them:
    /// only the Timeline has anything to put up there.
    init(titleKey: String, subtitleKey: String, loading: Bool = false,
         @ViewBuilder tabs: () -> Tabs) {
        self.init(titleKey: titleKey, subtitleKey: subtitleKey, loading: loading,
                  tabs: tabs, controls: { EmptyView() })
    }
}

/// The tint that lifts a header off the page under it. Its own type so that it can read the
/// colour scheme without the header being rebuilt for it.
struct PageHeaderBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Palette.raised(colorScheme).opacity(0.6)
    }
}
