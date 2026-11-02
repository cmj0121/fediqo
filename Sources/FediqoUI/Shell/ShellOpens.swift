import FediqoCore
import SwiftUI

/// What a row away from the timeline's lists opens by (#443): a report's posts, a quote of one's
/// own post, a member of a collection, a held-back request. Each is a step of the timeline's walk,
/// and leaving it comes back to where it was pressed (`PlaceErrand`).
///
/// Always equal, for `PressedAgain`'s reason.
struct ShellOpens: Equatable {
    let person: (DummyPerson) -> Void
    /// The post is held first, as a notice's post is, since nothing here holds it.
    let post: (Note) -> Void

    static func == (_: ShellOpens, _: ShellOpens) -> Bool { true }
}

extension EnvironmentValues {
    /// See `ShellOpens`. Nothing where there is no root to walk, and a row then opens nothing.
    @Entry var shellOpens: ShellOpens?
}

extension DummyPerson {
    /// Whether a row on this person's page has an author to open: only a boost of somebody else's
    /// post. Every other row there is their own, whatever spelling of their handle it came with.
    func opensAuthor(of item: DummyItem) -> Bool {
        item.reblogger != nil && DummyPerson(item)?.id != id
    }
}

/// A post drawn inside a report or a server's review: a post's row, and a press does what it does
/// everywhere (`DummyCommand.tapped`). The lamp is its own: the one around it is the report's.
struct TendedPostRow: View {
    let note: Note
    let item: DummyItem
    let catalogues: EmojiCatalogueStore
    let posts: ForumPosts
    var onOpenPerson: (DummyPerson) -> Void

    @State private var lit: String?
    @Environment(\.shellOpens) private var opens
    @Environment(\.shellTouch) private var touch

    var body: some View {
        DummyItemRow(
            item: item, catalogues: catalogues, posts: posts, selected: lit == item.id,
            onSelect: {
                switch DummyCommand.tapped(item.id, selected: lit, touch: touch) {
                case .select: lit = item.id
                case .open: opens?.post(note)
                }
            },
            onOpen: opens.map { opens in { opens.post(note) } },
            onOpenPerson: onOpenPerson
        )
    }
}

/// A quoted post's card whose cover is lifted here and nowhere else: where the card is not any
/// row's (`QuoteHead`, a notice about one's own post), and the cover would otherwise do nothing.
struct OwnCoverQuoteCard: View {
    let post: QuotedPost
    let host: String
    var onOpen: (() -> Void)?

    @State private var lifted = false

    var body: some View {
        QuoteCard(post: post, host: host, lifted: lifted, onOpen: onOpen, onToggleCover: { lifted.toggle() })
    }
}
