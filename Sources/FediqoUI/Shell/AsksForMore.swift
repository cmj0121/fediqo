import FediqoCore
import SwiftUI

/// A row that, coming into view, asks the timeline in front for its next stretch (#87) — where
/// `asks` says it is near enough the end to. A modifier of its own so the list's row stays one
/// chain the type-checker reads quickly.
///
/// **This device first** (#357): a timeline read from the file a page at a time reads the page
/// below from there while the file has one — as the reader's place moves (`ShellSession.placed`,
/// #359), and from its foot only where the place has read nothing on (`footReached`) — and only
/// once it has none asks its sources.
struct AsksForMore: ViewModifier {
    let asks: Bool
    let timeline: TimelineQuery
    let session: ShellSession
    var latest: LatestDate?

    func body(content: Content) -> some View {
        content.onAppear {
            guard asks else { return }
            guard !session.readsOnFromFile(timeline) else {
                session.footReached(timeline, latest: latest)
                return
            }
            Task { await session.reload.more(timeline, in: session) }
        }
    }
}
