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
        Conversation(ancestors: Self.chain(above: other.post, among: ancestors + other.ancestors),
                     post: other.post,
                     descendants: (descendants + other.descendants).merged(oldestFirst: true))
    }

    /// The way up, rebuilt from the addresses rather than sorted by anything.
    ///
    /// **Time is the wrong idea here, not merely the wrong direction.** A conversation going down
    /// is a stretch of time and sorts by it; a conversation going up is a *chain*, and which post
    /// is above which is written in `in_reply_to_uri` and nowhere else. Two ancestors can share a
    /// millisecond, a server's clock can run ahead of the one it is answering, and an old post
    /// answered a year later is above the answer whatever the timestamps say.
    ///
    /// It used to fold the two lists with `[Post].merged()`, which is newest-first because that
    /// is what a timeline wants — so opening a reply to a reply drew the way up backwards the
    /// moment the server's copy arrived, and the reader watched it turn over. The line below it
    /// had already passed `oldestFirst:` for the way down; this one was left on the default.
    ///
    /// Rebuilding also takes whichever side knows more. The store may hold `X → Y` while the
    /// server hands back `W → X → Y`; walking the union from the post upwards finds all three,
    /// where any sort of two lists could only ever return what was already in them.
    ///
    /// Bounded like every other walk here: a post cannot be its own ancestor, and a server that
    /// says otherwise gets one pass and no more.
    static func chain(above post: Post, among posts: [Post]) -> [Post] {
        let known = posts.merged(oldestFirst: true)
        let byURI = Dictionary(known.map { ($0.uri, $0) }, uniquingKeysWith: { first, _ in first })

        var chain: [Post] = []
        var next = post.inReplyToURI
        var seen: Set<String> = [post.uri]
        while let uri = next, chain.count < known.count, seen.insert(uri).inserted,
              let above = byURI[uri] {
            chain.append(above)
            next = above.inReplyToURI
        }
        return chain.reversed()
    }

    /// How far from the left edge the opened post itself is drawn, once the way up is drawn as
    /// the shape it is: one step per ancestor.
    public var depthOfPost: Int { ancestors.count }

    /// The way up, as `Reply` — the same shape `laidOut()` gives the way down, so a screen draws
    /// both with one rule instead of drawing one and listing the other.
    ///
    /// **`depth` is counted from the furthest ancestor here**, where `laidOut()` counts from the
    /// post: these are the two halves of one page and the numbers meet at `depthOfPost`. The
    /// chain is already in order, so the depth is the position — there is nothing to work out.
    ///
    /// The furthest one answers nobody as far as this page knows. That is not the same as
    /// answering nothing, and it is drawn as silence rather than as a claim: what it replied to
    /// is a post neither the store nor the server handed over.
    public func climbed() -> [Reply] {
        ancestors.enumerated().map { step, above in
            Reply(post: above, depth: step,
                  answering: step == 0 ? nil : ancestors[step - 1].authorHandle)
        }
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
