import Foundation

// One Mastodon post and its thread, read again (#29): `/api/v1/statuses/:id` and its `/context`,
// from the host the post came through — as the reader where signed in, unsigned otherwise.
//
// The id is the one that server gave the post (`Note.statusID`). A row stored before that was
// kept has none; only the signed-in door may look it up, by its URI through search, and a
// signed-out reader is told it cannot be read again rather than handed a guess.

/// Reads one post, and the posts around it, from the host it came through.
public struct MastodonPost: Sendable {
    private enum Door: Sendable {
        case unsigned(any HTTPClient)
        case signedIn(MastodonAuthorized)
    }

    private let door: Door
    private let host: String

    /// Unsigned, as the public timeline is read.
    public init(http: any HTTPClient, host: String) {
        door = .unsigned(http)
        self.host = host
    }

    /// As the reader, through the one signed-in door.
    public init(door: MastodonAuthorized) {
        self.door = .signedIn(door)
        host = door.token.host
    }

    /// The server's id for `note`: the one held, or where there is none and the reader is signed
    /// in, the one search resolves its URI to — and only where what search found **is** that post,
    /// by its URI. Nothing where it cannot be known.
    ///
    /// Throws `MastodonAuthError.http(403)` where the token cannot search: one issued before
    /// `read:search` was asked for.
    public func id(of note: Note) async throws -> String? {
        if let held = note.statusID { return held }
        guard case .signedIn = door else { return nil }
        let data = try await get("/api/v2/search", query: [
            URLQueryItem(name: "q", value: note.id),
            URLQueryItem(name: "resolve", value: "true"),
            URLQueryItem(name: "type", value: "statuses"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        return try MastodonJSON.decoder.decode(SearchDTO.self, from: data).statuses
            .first { $0.uri == note.id }?.id
    }

    /// The post with this id, stamped with `source` and arriving through no category: a thread
    /// is not a timeline.
    public func post(id: String, source: Source) async throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: try await get(Self.path(id)))
            .asNote(source: source, categories: [])
    }

    /// The posts before and after it in its thread. Asked after the post, and separately: on a
    /// busy thread this is the large answer, and the post must not wait on it or fail with it.
    public func context(id: String, source: Source) async throws -> [Note] {
        let thread = try await conversation(id: id, source: source)
        return thread.ancestors + thread.descendants
    }

    /// The same read, with the two halves still told apart — which is what drawing a thread
    /// needs and what `context(id:source:)` throws away.
    ///
    /// **Two halves and not one list, because the server's own answer is two lists and the
    /// difference is not recoverable afterwards.** What a post answers stands above it and what
    /// answered it stands below, and a reader handed one flat list cannot tell which is which:
    /// `in_reply_to_id` chains an ancestor to the post as surely as it chains an answer to it,
    /// so rebuilding the split from the ids alone would need the post's own parent, which is the
    /// one thing a post held before 0.4.0 does not carry. The server already said it. This keeps
    /// what it said.
    ///
    /// Each half is left **in the order the server wrote it** — ancestors oldest first, up to the
    /// post's own parent; answers in the order that instance walks its tree. Nothing is sorted
    /// here: the order a thread reads in is the source's fact about the thread, and a second
    /// opinion about it belongs to whatever draws it, if anywhere.
    public func conversation(id: String, source: Source) async throws -> MastodonThread {
        let context = try MastodonJSON.decoder.decode(
            ContextDTO.self, from: try await get(Self.path(id) + "/context")
        )
        return MastodonThread(
            ancestors: context.ancestors.map { $0.asNote(source: source, categories: []) },
            descendants: context.descendants.map { $0.asNote(source: source, categories: []) }
        )
    }

    /// What `error`, from reading `note` itself — the post, or its thread — says about whether its
    /// server still has the post (#179).
    ///
    /// **410 always; a 404 only where no one could be being kept from it.** A server answers 404
    /// for a post it will not show this reader as surely as for one it deleted: a followers-only or
    /// direct post after an unfollow, or any post whose author blocks the reader or their server.
    /// So a 404 on a post written for fewer than everyone is never taken as gone, and a 404 on a
    /// public or unlisted post asked as the reader is only a question — `confirmsGone(_:id:)`,
    /// asked with no token, is what answers it. Asked with no token already, it is the answer.
    ///
    /// A lookup that found nothing is not this: search not finding a post is search, and says
    /// nothing about the post. Callers ask this only of the read by id.
    public static func saysGone(_ error: any Error, about note: Note, signedIn: Bool) -> GoneAnswer {
        let status: Int
        if case .http(let code)? = error as? MastodonAuthError {
            status = code
        } else if case .http(let code)? = error as? MastodonRequestError {
            status = code
        } else {
            return .no
        }
        if status == 410 { return .gone }
        guard status == 404, note.audience == .everyone || note.audience == .unlisted else { return .no }
        return signedIn ? .ask : .gone
    }

    /// Whether a post this server would not show the reader is gone for everyone: the same id
    /// asked again **with no token**, on a reader built with `init(http:host:)`. Gone only where
    /// that answers 404 or 410 too; a post it hands over, a refusal, or no answer is not gone.
    public func confirmsGone(_ note: Note, id: String) async -> Bool {
        do {
            _ = try await get(Self.path(id))
            return false
        } catch {
            return Self.saysGone(error, about: note, signedIn: false) == .gone
        }
    }

    /// Checked as a list id is: this came out of a stranger's JSON or the store.
    private static func path(_ id: String) throws -> String {
        guard ListSubscription.isPathSegment(id) else { throw MastodonRequestError.invalidURL }
        return "/api/v1/statuses/\(id)"
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        switch door {
        case .signedIn(let door):
            return try await door.get(path: path, query: query)
        case .unsigned(let http):
            guard let url = Host.httpsURL(host: host, path: path, query: query) else {
                throw MastodonRequestError.invalidURL
            }
            let (data, response) = try await http.data(from: url)
            guard (200..<300).contains(response.statusCode) else {
                throw MastodonRequestError.http(response.statusCode)
            }
            return data
        }
    }
}

/// One post's thread: what it answers, and what answered it. Neither half includes the post.
public struct MastodonThread: Hashable, Sendable {
    /// Oldest first, up to the post's own parent.
    public let ancestors: [Note]
    /// In the order the server walked them, deepest chains kept beside their parents.
    public let descendants: [Note]

    public init(ancestors: [Note], descendants: [Note]) {
        self.ancestors = ancestors
        self.descendants = descendants
    }

    /// Whether the post is alone in its thread. Both halves, because a post that answers
    /// something nobody else answered is no more alone than one nobody answered at all.
    public var isAlone: Bool { ancestors.isEmpty && descendants.isEmpty }
}

/// `/api/v1/statuses/:id/context`.
struct ContextDTO: Decodable, Sendable {
    let ancestors: [StatusDTO]
    let descendants: [StatusDTO]
}

/// `/api/v2/search`, in the one field a lookup needs.
struct SearchDTO: Decodable, Sendable {
    let statuses: [StatusDTO]
}

/// What a failed read of one post says about whether its server still has it (#179).
public enum GoneAnswer: Sendable, Equatable {
    /// It does not: the post is gone from its source.
    case gone
    /// Only that this reader may not see it. Asked again with no token, the answer is the answer.
    case ask
    /// Nothing about the post: a failure, a refusal, or a post that may only be hidden.
    case no
}
