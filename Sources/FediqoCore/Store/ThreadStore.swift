import Foundation
import GRDB

/// One post with the conversation around it: what it answers, and what answered it.
///
/// Three lists rather than a tree, because that is what a screen draws — the way up in order,
/// the post, and everything under it in the timeline's own order. Whose reply answers whose is
/// still in each post's `inReplyToURI` for anything that wants to indent them.
public struct Conversation: Sendable, Hashable {
    /// From the furthest ancestor down to the post's own parent.
    public let ancestors: [Post]
    public let post: Post
    /// Everything below it, oldest first, which is the order a conversation is read in.
    public let descendants: [Post]

    public init(ancestors: [Post] = [], post: Post, descendants: [Post] = []) {
        self.ancestors = ancestors
        self.post = post
        self.descendants = descendants
    }

    public var isAlone: Bool { ancestors.isEmpty && descendants.isEmpty }

    /// One reply, and where it sits in the conversation.
    public struct Reply: Sendable, Hashable, Identifiable {
        public let post: Post
        /// How far under the opened post it is: 1 answers the post, 2 answers one of those.
        public let depth: Int
        /// Whom it is answering, where that is not the post itself. A reply to the post needs
        /// no such line — the post is what the page already is.
        public let answering: String?

        public var id: String { post.mergeKey }
    }

    /// The replies in the order they were written, each with how deep under the post it sits
    /// and whom it answers.
    ///
    /// Depth is walked up from each reply rather than down from the post, because a reply can
    /// arrive before what it answers and can answer something nobody handed us. A reply whose
    /// parent is missing is drawn one step under the post: it is in this conversation, and
    /// pretending to know where would be inventing a shape the server never sent.
    ///
    /// The walk is bounded by the number of replies there are — a server can write a cycle,
    /// and a page that hangs on one is a page a stranger can take down.
    public func laidOut() -> [Reply] {
        let byURI = Dictionary(descendants.map { ($0.uri, $0) }, uniquingKeysWith: { first, _ in first })
        return descendants.map { reply in
            var depth = 1
            var parent = reply.inReplyToURI
            var seen: Set<String> = [reply.uri]
            while let uri = parent, uri != post.uri, let above = byURI[uri], seen.insert(uri).inserted,
                  depth <= descendants.count {
                depth += 1
                parent = above.inReplyToURI
            }
            let answers = reply.inReplyToURI.flatMap { $0 == post.uri ? nil : byURI[$0] }
            return Reply(post: reply, depth: depth, answering: answers?.authorHandle)
        }
    }

    /// The same conversation with `other`'s posts folded in — what the store had, and then
    /// what a server said, without either being thrown away.
    ///
    /// The post itself is `other`'s where it has one: a page fetched for this conversation is
    /// newer than the row we held. Everything else collapses on `mergeKey` the way two servers
    /// carrying one post always have.
    public func merged(with other: Conversation) -> Conversation {
        Conversation(ancestors: (ancestors + other.ancestors).merged(),
                     post: other.post,
                     descendants: (descendants + other.descendants).merged(oldestFirst: true))
    }
}

extension LocalStore {
    /// The conversation around a post, out of what is already here — no network, and therefore
    /// only as much of it as the timeline happened to carry past us.
    ///
    /// A thread is a join at read time on `posts.uri`, which is that server's own address for a
    /// post: `in_reply_to_uri` holds an address rather than a reference, because a reply
    /// routinely arrives before what it answers and a foreign key would refuse it. So this
    /// walks addresses, and a parent nobody handed us is simply absent rather than an error.
    ///
    /// Both walks are bounded. A conversation is a chain somebody else's server made, and
    /// nothing here should let it turn into a query that walks the whole store — a cycle in
    /// the addresses (two posts answering each other, which a hostile server can write) would
    /// otherwise never end.
    public func thread(around post: Post, depth: Int = 40) async throws -> Conversation {
        let uri = post.uri
        let parent = post.inReplyToURI
        return try await read { db in
            let up = try Self.walkUp(db, from: parent, depth: depth)
            let down = try Self.walkDown(db, from: uri, depth: depth)
            // The walk is by generation, because that is the cheap way to find them. What is
            // read is by time, because that is the order the conversation happened in — and
            // the two are not the same the moment somebody answers an old reply. Sorted here
            // so the store alone answers in the same order the server's copy will.
            return Conversation(ancestors: up, post: post, descendants: down.merged(oldestFirst: true))
        }
    }

    /// The chain above a post, furthest ancestor first. Each step is one row by `uri`.
    private static func walkUp(_ db: Database, from parent: String?, depth: Int) throws -> [Post] {
        var chain: [Post] = []
        var next = parent
        var seen: Set<String> = []
        while let uri = next, chain.count < depth, seen.insert(uri).inserted {
            let rows = try Row.fetchAll(db, sql: "\(postSelect) WHERE p.uri = ? LIMIT 1", arguments: [uri])
            guard let found = try posts(from: rows, db).first else { break }
            chain.append(found)
            next = found.inReplyToURI
        }
        return chain.reversed()
    }

    /// Everything under a post, oldest first — one round per generation, so a conversation
    /// twenty deep is twenty small queries rather than one that walks the table.
    private static func walkDown(_ db: Database, from uri: String, depth: Int) throws -> [Post] {
        var found: [Post] = []
        var frontier = [uri]
        var seen: Set<String> = [uri]
        var generations = 0
        while !frontier.isEmpty, generations < depth, found.count < depth {
            generations += 1
            let placeholders = Array(repeating: "?", count: frontier.count).joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                \(postSelect)
                WHERE p.in_reply_to_uri IN (\(placeholders)) AND p.deleted_at IS NULL
                ORDER BY \(TimelineOrder.oldestFirst)
                """, arguments: StatementArguments(frontier))
            let replies = try posts(from: rows, db).filter { seen.insert($0.uri).inserted }
            guard !replies.isEmpty else { break }
            found += replies
            frontier = replies.map(\.uri)
        }
        return Array(found.prefix(depth))
    }
}

public extension Array where Element == Post {
    /// The same fold `merged()` is, in the other order — a conversation is read from the top
    /// down, and the timeline's order is newest first.
    func merged(oldestFirst: Bool) -> [Post] {
        oldestFirst ? merged(orderedBy: { TimelineOrder.isOlder($0, than: $1) }) : merged()
    }
}
