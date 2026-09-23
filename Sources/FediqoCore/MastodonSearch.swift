import Foundation

/// A Mastodon asked for the posts that match some words (#176): `/api/v2/search`, statuses only.
///
/// **Signed in, or not at all.** A Mastodon answers a full-text search of its posts only to an
/// account it knows, and a signed-out ask comes back empty — which a search would then report as
/// a server with nothing to say. So there is no unsigned door here: a source this device is not
/// signed in to cannot be searched, and the search says so rather than asking.
public struct MastodonSearch: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    /// The posts matching `words`, stamped with `source` and arriving through no category: a
    /// search is not a timeline. Unresolved, so only what the server already knows is asked for
    /// and nothing is fetched from a third server on this device's behalf.
    ///
    /// Throws `MastodonAuthError.http(403)` where the token cannot search: one issued before
    /// `read:search` was asked for.
    public func statuses(matching words: String, source: Source) async throws -> [Note] {
        let data = try await door.get(path: "/api/v2/search", query: [
            URLQueryItem(name: "q", value: words),
            URLQueryItem(name: "type", value: "statuses"),
            URLQueryItem(name: "resolve", value: "false"),
            URLQueryItem(name: "limit", value: "40"),
        ])
        return try MastodonJSON.decoder.decode(SearchDTO.self, from: data).statuses
            .map { $0.asNote(source: source, categories: []) }
    }

    /// What a search pattern (#32) sends a server: its words, with `*` and `?` let go — a server
    /// has its own idea of matching, and what comes back is matched against the pattern here
    /// anyway. Nil where nothing but wildcards and spaces is left.
    ///
    /// **A wildcard in any width.** The pattern is matched folded (`Fold.key`), so `＊` and `？`
    /// are wildcards there too, and sending one to a server would ask it for a full-width star.
    public static func words(of pattern: String) -> String? {
        let words = String(pattern.map { isWildcard($0) ? " " : $0 })
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    private static func isWildcard(_ character: Character) -> Bool {
        let folded = String(character).folding(options: .widthInsensitive, locale: nil)
        return folded == "*" || folded == "?"
    }
}
