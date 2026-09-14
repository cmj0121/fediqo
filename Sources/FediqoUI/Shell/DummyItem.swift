import Foundation

/// An item in the dummy store. A `note` or a `thread`, never a protocol row.
public enum DummyItemKind: String, Sendable, Hashable {
    case note
    case thread
}

/// Who the author wrote it for, where the dummy said so. Nothing means the shape has no such idea.
public enum DummyAudience: String, Sendable, Hashable {
    case everyone
    case unlisted
    case followers
    case mentioned

    var symbolName: String {
        switch self {
        case .everyone: "globe"
        case .unlisted: "moon"
        case .followers: "lock"
        case .mentioned: "at"
        }
    }
}

/// What a row says about this item being an answer.
public enum DummyAnswering: Sendable, Hashable {
    case nothing
    case somebody
    case handle(String)
}

public struct DummyCounts: Hashable, Sendable {
    public var replies: Int?
    public var reblogs: Int?
    public var favourites: Int?

    public init(replies: Int? = nil, reblogs: Int? = nil, favourites: Int? = nil) {
        self.replies = replies
        self.reblogs = reblogs
        self.favourites = favourites
    }
}

/// What this device has done to a dummy item. Remote marks are still local in this mock.
public struct DummyMarks: Hashable, Sendable {
    public var favourited: Bool
    public var bookmarked: Bool
    public var kept: Bool

    public init(favourited: Bool = false, bookmarked: Bool = false, kept: Bool = false) {
        self.favourited = favourited
        self.bookmarked = bookmarked
        self.kept = kept
    }
}

public struct DummyItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let source: DummySource
    public let author: String
    public let handle: String?
    public let titleKey: String?
    public let bodyKey: String
    public let boardKey: String?
    public let postedAt: Date
    public let workRelated: Bool
    public let answering: DummyAnswering
    public let boostedBy: String?
    public let audience: DummyAudience?
    public let hasAvatar: Bool
    public let hasThumb: Bool
    public let counts: DummyCounts
    public let marks: DummyMarks
    /// Other hosts that also carried this item. Empty for a single source.
    public let alsoFrom: [DummySource]

    /// Hosts to name on the row, stable and unique. First is drawn; the rest are +n.
    public var shownHosts: [String] {
        var seen = Set<String>()
        return ([source] + alsoFrom)
            .map(\.host)
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    public var kind: DummyItemKind {
        switch source.kind {
        case .microblog: .note
        case .forum, .board: .thread
        }
    }

    public var title: String? { titleKey.map { L10n.t($0) } }
    public var body: String { L10n.t(bodyKey) }
    public var board: String? { boardKey.map { L10n.t($0) } }

    /// The dummy store. Named queries select from this; they do not fetch.
    public static let stored: [DummyItem] = [
        DummyItem(
            id: "note-public",
            source: .unsignedPublic,
            author: "Ada",
            handle: "@ada@first.example",
            titleKey: nil,
            bodyKey: "item.note.public.body",
            boardKey: nil,
            postedAt: at(4),
            workRelated: false,
            answering: .handle("@you@second.example"),
            boostedBy: nil,
            audience: .everyone,
            hasAvatar: true,
            hasThumb: false,
            counts: DummyCounts(replies: 2, reblogs: 1, favourites: 4),
            marks: DummyMarks(),
            alsoFrom: []
        ),
        DummyItem(
            id: "note-you-work",
            source: .signedIn,
            author: "You",
            handle: "@you@second.example",
            titleKey: nil,
            bodyKey: "item.note.you.work.body",
            boardKey: nil,
            postedAt: at(6),
            workRelated: true,
            answering: .nothing,
            boostedBy: nil,
            audience: .followers,
            hasAvatar: true,
            hasThumb: false,
            counts: DummyCounts(replies: 1, favourites: 2),
            marks: DummyMarks(kept: true),
            alsoFrom: [.unsignedPublic]
        ),
        DummyItem(
            id: "note-you-weekend",
            source: .signedIn,
            author: "You",
            handle: "@you@second.example",
            titleKey: nil,
            bodyKey: "item.note.you.weekend.body",
            boardKey: nil,
            postedAt: at(2),
            workRelated: false,
            answering: .nothing,
            boostedBy: "Ada",
            audience: .everyone,
            hasAvatar: true,
            hasThumb: true,
            counts: DummyCounts(reblogs: 3, favourites: 9),
            marks: DummyMarks(favourited: true),
            alsoFrom: []
        ),
        DummyItem(
            id: "thread-forum-work",
            source: .forum,
            author: "Sam",
            handle: nil,
            titleKey: "item.thread.forum.work.title",
            bodyKey: "item.thread.forum.work.body",
            boardKey: nil,
            postedAt: at(5),
            workRelated: true,
            answering: .somebody,
            boostedBy: nil,
            audience: .unlisted,
            hasAvatar: false,
            hasThumb: false,
            counts: DummyCounts(replies: 12, reblogs: 2, favourites: 7),
            marks: DummyMarks(),
            alsoFrom: []
        ),
        DummyItem(
            id: "thread-forum-chat",
            source: .forum,
            author: "Sam",
            handle: nil,
            titleKey: "item.thread.forum.chat.title",
            bodyKey: "item.thread.forum.chat.body",
            boardKey: nil,
            postedAt: at(3),
            workRelated: false,
            answering: .nothing,
            boostedBy: nil,
            audience: .everyone,
            hasAvatar: false,
            hasThumb: true,
            counts: DummyCounts(replies: 4),
            marks: DummyMarks(bookmarked: true),
            alsoFrom: []
        ),
        DummyItem(
            id: "thread-board-weekend",
            source: .board,
            author: "Rin",
            handle: nil,
            titleKey: "item.thread.board.weekend.title",
            bodyKey: "item.thread.board.weekend.body",
            boardKey: "item.board.dev",
            postedAt: at(7),
            workRelated: false,
            answering: .nothing,
            boostedBy: nil,
            audience: nil,
            hasAvatar: false,
            hasThumb: false,
            counts: DummyCounts(replies: 8, favourites: 1),
            marks: DummyMarks(),
            alsoFrom: []
        ),
    ]

    /// Dummy clock relative to first load, so the row can say "xx ago".
    private static let origin = Date()

    private static func at(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval((offset - 8) * 3600)
    }

    /// One dummy conversation: the way up, this post, then answers indented under it.
    public func dummyConversation() -> DummyConversation {
        DummyConversation(ancestors: dummyAncestor.map { [$0] } ?? [], post: self, descendants: dummyLaidOut())
    }

    public static func named(_ id: String) -> DummyItem? {
        if let hit = stored.first(where: { $0.id == id }) { return hit }
        for item in stored {
            if let hit = item.dummyConversation().inOrder.first(where: { $0.id == id }) {
                return hit
            }
        }
        return nil
    }

    /// Dummy replies under this item. Same shape, later in time.
    public func dummyReplies() -> [DummyItem] {
        [
            reply(
                suffix: "r1",
                author: "Ada",
                handle: "@ada@first.example",
                bodyKey: "item.reply.one.body",
                later: 900,
                hasAvatar: true
            ),
            reply(
                suffix: "r2",
                author: "Sam",
                handle: nil,
                bodyKey: "item.reply.two.body",
                later: 2400,
                hasAvatar: false
            ),
        ]
    }

    private func reply(
        suffix: String,
        author: String,
        handle: String?,
        bodyKey: String,
        later: TimeInterval,
        hasAvatar: Bool
    ) -> DummyItem {
        DummyItem(
            id: "\(id)-\(suffix)",
            source: source,
            author: author,
            handle: handle,
            titleKey: nil,
            bodyKey: bodyKey,
            boardKey: nil,
            postedAt: postedAt.addingTimeInterval(later),
            workRelated: workRelated,
            answering: handle.map { .handle($0) } ?? .somebody,
            boostedBy: nil,
            audience: audience,
            hasAvatar: hasAvatar,
            hasThumb: false,
            counts: DummyCounts(),
            marks: DummyMarks(),
            alsoFrom: []
        )
    }

    private var dummyAncestor: DummyItem? {
        guard answering != .nothing else { return nil }
        return DummyItem(
            id: "\(id)-up",
            source: source,
            author: "Ada",
            handle: "@ada@first.example",
            titleKey: nil,
            bodyKey: "item.reply.up.body",
            boardKey: nil,
            postedAt: postedAt.addingTimeInterval(-3600),
            workRelated: workRelated,
            answering: .nothing,
            boostedBy: nil,
            audience: audience,
            hasAvatar: true,
            hasThumb: false,
            counts: DummyCounts(replies: 3),
            marks: DummyMarks(),
            alsoFrom: []
        )
    }

    private func dummyLaidOut() -> [DummyThreadEntry] {
        let replies = dummyReplies()
        guard let first = replies.first, let second = replies.dropFirst().first else {
            return replies.map { DummyThreadEntry(item: $0, depth: 1) }
        }
        let nested = first.reply(
            suffix: "n",
            author: "Rin",
            handle: nil,
            bodyKey: "item.reply.nested.body",
            later: 500,
            hasAvatar: false
        )
        return [
            DummyThreadEntry(item: first, depth: 1),
            DummyThreadEntry(item: nested, depth: 2),
            DummyThreadEntry(item: second, depth: 1),
        ]
    }
}

/// Ancestors, the post, then answers. Depth is generations below the post.
public struct DummyConversation: Hashable, Sendable {
    public let ancestors: [DummyItem]
    public let post: DummyItem
    public let descendants: [DummyThreadEntry]

    public var inOrder: [DummyItem] {
        ancestors + [post] + descendants.map(\.item)
    }

    public func depth(of id: String) -> Int {
        if let index = ancestors.firstIndex(where: { $0.id == id }) { return index }
        if post.id == id { return ancestors.count }
        if let entry = descendants.first(where: { $0.item.id == id }) {
            return ancestors.count + entry.depth
        }
        return 0
    }
}

public struct DummyThreadEntry: Hashable, Sendable {
    public let item: DummyItem
    public let depth: Int
}
