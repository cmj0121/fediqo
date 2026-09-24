import Foundation

/// A Mastodon asked for the posts it knows under one hashtag (#124): `/api/v1/timelines/tag/:name`.
///
/// **As the reader where signed in, unsigned otherwise**, as the public timeline is read: a tag's
/// timeline is public on a server whose timelines are, and the signed-in door is the one a server
/// that keeps them for its members still answers.
///
/// What comes back arrives through no category — a tag is not one of the source's timelines — and
/// is for the store to hold aside, so no timeline grows by it.
public struct MastodonTag: Sendable {
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

    /// The newest posts this server knows under `tag`, stamped with `source`.
    ///
    /// The name goes into the path as a path segment, percent-encoded where it is not ASCII — a
    /// tag written in any script is a tag (`PostTag`) — and never with its `#`.
    public func posts(under tag: PostTag, source: Source) async throws -> [Note] {
        let path = try Self.path(under: tag, host: host)
        let query = [URLQueryItem(name: "limit", value: "40")]
        let data: Data
        switch door {
        case .signedIn(let door):
            data = try await door.get(path: path, query: query)
        case .unsigned(let http):
            guard let url = Host.httpsURL(host: host, path: path, query: query) else {
                throw MastodonRequestError.invalidURL
            }
            let (body, response) = try await http.data(from: url)
            guard (200..<300).contains(response.statusCode) else {
                throw MastodonRequestError.http(response.statusCode)
            }
            data = body
        }
        return try MastodonJSON.decoder.decode([StatusDTO].self, from: data)
            .map { $0.asNote(source: source, categories: []) }
    }

    /// The tag's timeline, as a path whose last segment is the name and nothing else (#124).
    ///
    /// **Refused rather than trusted.** `PostTag` admits no `/`, `?`, `#` or `%` into a name, and
    /// this does not lean on that alone: the path is built as the request will build it, and is
    /// refused unless it is exactly the five segments before the name and the name itself — so a
    /// name that would add a segment, climb one or end the path early never reaches a server with
    /// the reader's token beside it.
    static func path(under tag: PostTag, host: String) throws -> String {
        let name = tag.name
        let path = "/api/v1/timelines/tag/" + name
        guard !name.contains(where: { "/?#%\\".contains($0) }),
              let url = Host.httpsURL(host: host, path: path),
              url.pathComponents == ["/", "api", "v1", "timelines", "tag", name]
        else { throw MastodonRequestError.invalidURL }
        return path
    }
}
