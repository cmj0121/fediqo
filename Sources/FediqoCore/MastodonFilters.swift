import Foundation

// The person's filters at a signed-in Mastodon (#338), read and tended as the person, as
// `MastodonFilterCaptures` records Mastodon 4.6.6 answering.
//
// **Read and changed only through the filters part** (`read:filters`, `write:filters`). What a
// post says of them (`Status.filtered`) needs no part: a sign-in that only reads posts is told it.
//
// **A change names each keyword by its place** (`keywords_attributes[0][…]`): a list of them
// written as `[]` folds a new keyword into the one before it whenever that one is being removed,
// and the new one is removed with it (`MastodonFilterCaptures`).

/// One entry of `Status.filtered`: the filter, and what of the post it matched.
struct FilterResultDTO: Decodable, Sendable {
    let filter: FilterDTO

    var hit: ServerFilterHit? {
        guard !filter.id.isEmpty else { return nil }
        return ServerFilterHit(
            filterID: filter.id, title: filter.title, action: ServerFilterAction(word: filter.filterAction ?? "warn"),
            context: Set(filter.context ?? []), expiresAt: filter.expiresAt?.value
        )
    }
}

/// A filter, as `/api/v2/filters` and `Status.filtered` both send it — the second without its
/// keywords and posts.
struct FilterDTO: Decodable, Sendable {
    struct KeywordDTO: Decodable, Sendable {
        let id: String
        let keyword: String
        let wholeWord: Bool?
    }

    struct PostDTO: Decodable, Sendable {
        let id: String
    }

    let id: String
    let title: String
    let context: [String]?
    let expiresAt: StatusDTO.LenientMoment?
    let filterAction: String?
    let keywords: [KeywordDTO]?
    let statuses: [PostDTO]?

    var filter: ServerFilter {
        ServerFilter(
            id: id, title: title, context: Set(context ?? []), action: ServerFilterAction(word: filterAction ?? "warn"),
            expiresAt: expiresAt?.value,
            keywords: (keywords ?? []).map { .init(id: $0.id, keyword: $0.keyword, wholeWord: $0.wholeWord ?? true) },
            statuses: statuses?.count ?? 0
        )
    }
}

/// What a source answered that refused a filter as made or changed: its own sentence.
public struct MastodonFilterRefused: Error, Equatable, Sendable {
    public let said: String?
}

/// The person's filters at one signed-in Mastodon.
public struct MastodonFilters: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v2/filters"

    /// Every filter kept for the person, as the source lists them.
    public func list() async throws -> [ServerFilter] {
        let data = try await door.get(path: Self.path)
        return try MastodonJSON.decoder.decode([FilterDTO].self, from: data).map(\.filter)
    }

    /// `draft` made, and the filter as the source now keeps it.
    public func make(_ draft: ServerFilterDraft) async throws -> ServerFilter {
        try await answer { try await door.post(path: Self.path, form: Self.form(draft, was: nil)) }
    }

    /// `was` changed to `draft`: its words, places, action and lasting as set, each keyword kept,
    /// changed, added or removed by its place in the list.
    public func change(_ was: ServerFilter, to draft: ServerFilterDraft) async throws -> ServerFilter {
        guard ListSubscription.isPathSegment(was.id) else { throw URLError(.badURL) }
        return try await answer { try await door.put(path: "\(Self.path)/\(was.id)", form: Self.form(draft, was: was)) }
    }

    /// Removes the filter. **A 404 is a filter already gone**, which is what was asked.
    public func remove(_ filter: ServerFilter) async throws {
        guard ListSubscription.isPathSegment(filter.id) else { throw URLError(.badURL) }
        do {
            _ = try await door.delete(path: "\(Self.path)/\(filter.id)")
        } catch MastodonAuthError.http(404) {
            return
        }
    }

    private func answer(_ send: () async throws -> Data) async throws -> ServerFilter {
        let data: Data
        do {
            data = try await send()
        } catch MastodonAuthError.http(422) {
            throw MastodonFilterRefused(said: nil)
        } catch is MastodonUnprocessable {
            // How a change is refused (`MastodonFilterCaptures`): the source's words, in its own
            // language, which the page does not repeat.
            throw MastodonFilterRefused(said: nil)
        }
        return try MastodonJSON.decoder.decode(FilterDTO.self, from: data).filter
    }

    /// The form a filter is made or changed by. Each keyword by its place; one of `was` the draft
    /// no longer holds is named and removed; a lasting of nothing is said as nothing, which is for
    /// good.
    static func form(_ draft: ServerFilterDraft, was: ServerFilter?) -> [(String, String)] {
        var form: [(String, String)] = [("title", draft.title)]
        for place in ServerFilter.places where draft.context.contains(place) { form.append(("context[]", place)) }
        form.append(("filter_action", draft.action.word))
        if draft.lasts != ServerFilterDraft.unchanged {
            form.append(("expires_in", draft.lasts.map(String.init) ?? ""))
        }
        var at = 0
        for keyword in draft.keywords {
            if let id = keyword.id { form.append(("keywords_attributes[\(at)][id]", id)) }
            form.append(("keywords_attributes[\(at)][keyword]", keyword.keyword))
            form.append(("keywords_attributes[\(at)][whole_word]", keyword.wholeWord ? "true" : "false"))
            at += 1
        }
        let kept = Set(draft.keywords.compactMap(\.id))
        for gone in was?.keywords ?? [] {
            guard let id = gone.id, !kept.contains(id) else { continue }
            form.append(("keywords_attributes[\(at)][id]", id))
            form.append(("keywords_attributes[\(at)][_destroy]", "true"))
            at += 1
        }
        return form
    }
}
