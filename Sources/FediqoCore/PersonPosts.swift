import Foundation

// Somebody's posts as their source hands them over (#310): a stretch at a time, read on by the
// source's own word for what is next.
//
// **For a page, and held nowhere by this.** What is read here lands in what is returned and in
// no store: a post read for somebody's page becomes an item only once the person opens it — or
// presses a mark on it, which is choosing it — or where this device already holds it. Whoever
// draws the page decides that; nothing here writes.

/// Why somebody could not be read at a source.
public enum PersonReadError: Error, Equatable, Sendable {
    /// The source knows nobody of that name or number. **It has not heard of them** — which,
    /// for somebody of another server, is all it says: it asks no other server, and nothing
    /// here does either.
    case unheardOf
    /// The source answered, and not with what was asked for: a body that is no person or no
    /// list of posts, somebody other than the one asked for by number, or a way on that names
    /// no place to go on from.
    case unreadable
}

/// One stretch of somebody's posts, as one source handed it over.
public struct PostStretch: Hashable, Sendable {
    /// Newest first. A boost they made is the boost — an item of its own, under its own id, at
    /// the time they boosted — and not the post it boosts.
    public let posts: [Note]
    /// The posts those boosts boost, which came in the same answer and were not listed.
    public let carried: [Note]
    /// What the next, older stretch is asked by. Nothing where the source named no next.
    public let next: String?

    public init(posts: [Note], carried: [Note] = [], next: String?) {
        self.posts = posts
        self.carried = carried
        self.next = next
    }
}

/// Somebody's posts as far as they have been read: what a page of them draws.
///
/// It remembers every place the source sent it, as `PeopleRead` does and for the same reason:
/// a source that names a next it named before, or goes on for ever with nothing new, is stopped.
public struct PostsRead: Hashable, Sendable {
    /// How many stretches in a row may bring nothing new and still name a next.
    public static let barren = PeopleRead.barren

    /// Newest first, nothing twice.
    public private(set) var posts: [Note] = []
    /// What the boosts among them boost, nothing twice.
    public private(set) var carried: [Note] = []
    /// What the next, older stretch is asked by. Nothing before the first stretch, and at the end.
    public private(set) var next: String?
    /// Whether a stretch has been read and the source named no next: it has sent all it has,
    /// or all it will show this reader.
    public private(set) var ended = false
    private var paging = PagingGuard()

    public init() {}

    /// These posts with an older `stretch` read on to. Throws `PagingError.notPaging`, changing
    /// nothing, where the stretch names a next already named, or is one too many in a row to
    /// bring nothing new and name a next all the same.
    public func readingOn(_ stretch: PostStretch) throws -> PostsRead {
        var read = self
        read.posts = Self.joined(posts, stretch.posts)
        read.carried = Self.joined(carried, stretch.carried)
        read.next = stretch.next
        read.ended = stretch.next == nil
        try read.paging.step(to: stretch.next, addingNothing: read.posts.count == posts.count)
        return read
    }

    /// These posts with the source's newest stretch read again. Where it reaches what is held —
    /// one post of it is here already — what is newer stands above, each post held is as the
    /// source now says it, and how far down was read stands. Where it reaches nothing held —
    /// more was written than one stretch holds, or nothing was held — the posts start again
    /// from the newest, rather than stand as a list with a hole nothing marks.
    public func renewed(by newest: PostStretch) -> PostsRead {
        let fresh = Dictionary(newest.posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard posts.contains(where: { fresh[$0.id] != nil }) else {
            var begun = PostsRead()
            begun.posts = Self.joined([], newest.posts)
            begun.carried = Self.joined([], newest.carried)
            begun.next = newest.next
            begun.ended = newest.next == nil
            // The first place named, in a guard with nothing in it: it cannot be refused.
            try? begun.paging.step(to: newest.next, addingNothing: false)
            return begun
        }
        var read = self
        let held = Set(posts.map(\.id))
        read.posts = Self.joined(newest.posts.filter { !held.contains($0.id) }, posts.map { fresh[$0.id] ?? $0 })
        read.carried = Self.joined(newest.carried, carried)
        return read
    }

    /// `first` and then whatever of `second` it does not already name.
    private static func joined(_ first: [Note], _ second: [Note]) -> [Note] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0.id).inserted }
    }
}
