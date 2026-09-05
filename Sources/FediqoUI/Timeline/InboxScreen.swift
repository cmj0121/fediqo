import SwiftUI
import FediqoCore

/// Who has been in touch: what reached you, and who you are talking to.
///
/// **One page with two tabs, drawn the way every other page with tabs is drawn.** The title, the
/// line under it describing the tab being shown, the tabs themselves and the page's own controls
/// are the arrangement the Timeline and Statistics pages already have — a reader who has learned
/// one has learned this.
///
/// **Neither half is a timeline.** `BaseSource.notice` offers no template because an inbox is not
/// a stretch of time somebody can page through, and a conversation is ordered by the conversation
/// rather than by time (#109). That is why they are not tabs of the Timeline page — and why they
/// are tabs of each other: both are somebody addressing you.
struct InboxScreen: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            PageHeader(titleKey: RailItem.inbox.titleKey,
                       // The line belongs to the tab, not to the page: the two halves are
                       // different readings and a line describing both would describe neither.
                       subtitleKey: "\(app.inboxTab.rawValue).subtitle",
                       loading: loading) {
                SegmentedChoice(InboxTab.allCases, keyPrefix: "tab", selection: $app.inboxTab)
            } controls: {
                controls
            }
            Hairline()
            switch app.inboxTab {
            case .notices: NoticesList()
            case .talks: TalksList()
            case .requests: RequestsList()
            }
        }
        .background(Palette.surface(colorScheme))
    }

    /// Whichever half is waiting. A spinner beside the title, where the reader is already
    /// looking, rather than over what they are still reading.
    private var loading: Bool {
        switch app.inboxTab {
        case .notices: app.notices?.asking ?? false
        case .talks: app.talks.loading
        case .requests: app.requests.loading
        }
    }

    /// What can be done on this page, which is one thing per tab and the same thing in both:
    /// ask again, now, because somebody said so.
    @ViewBuilder
    private var controls: some View {
        IconButton(symbol: "arrow.clockwise", labelKey: "timeline.refresh") {
            switch app.inboxTab {
            case .notices: Task { await app.askForNotices() }
            case .talks: Task { await app.talks.read() }
            case .requests: Task { await app.requests.read() }
            }
        }
    }
}
