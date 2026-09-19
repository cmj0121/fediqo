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
        let context = try MastodonJSON.decoder.decode(
            ContextDTO.self, from: try await get(Self.path(id) + "/context")
        )
        return (context.ancestors + context.descendants).map { $0.asNote(source: source, categories: []) }
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

/// `/api/v1/statuses/:id/context`.
struct ContextDTO: Decodable, Sendable {
    let ancestors: [StatusDTO]
    let descendants: [StatusDTO]
}

/// `/api/v2/search`, in the one field a lookup needs.
struct SearchDTO: Decodable, Sendable {
    let statuses: [StatusDTO]
}
