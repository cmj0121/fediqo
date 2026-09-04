import Foundation

/// The three that were left: who is waiting on you, and what you subscribed to (#114).
extension MastodonClient {
    /// `GET /api/v1/follow_requests`, as the account and about nobody else.
    ///
    /// A locked account could not answer anybody, which is what made this the sharpest of the
    /// lists left: the rows are not a state the reader is in, they are people waiting.
    public func followRequests(as account: ActingAccount) async throws -> [Profile] {
        let data = try await get(host: account.host, path: "/api/v1/follow_requests",
                                 query: [URLQueryItem(name: "limit", value: "80")],
                                 token: account.token)
        return try Self.decoder.decode([MastodonDTO.Account].self, from: data)
            .map { $0.asProfile(on: account.host) }
    }

    /// `POST /api/v1/follow_requests/:id/{authorize,reject}`.
    ///
    /// **The only thing in this app that changes another person's situation**, and there is no
    /// third answer and no taking it back: they are told either way by what happens next.
    ///
    /// The account is looked up by handle rather than sent as a URI, because the endpoint wants
    /// the id on the server being told — the same lookup a mute needs, and the same reason.
    public func answerFollowRequest(_ who: Profile, accept: Bool,
                                    as account: ActingAccount) async throws {
        guard let id = try await searchAccount(who.handle, as: account) else {
            throw SourceFailure.notItsPost(who.handle)
        }
        _ = try await write("POST",
                            "/api/v1/follow_requests/\(id)/\(accept ? "authorize" : "reject")",
                            as: account)
    }

    /// `GET /api/v1/followed_tags` — the hashtags this account's server is subscribed to.
    ///
    /// Kept the one way this store keeps a tag, so a followed `#Swift` and a timeline made of
    /// `swift` are recognisably the same subject.
    public func followedTags(as account: ActingAccount) async throws -> [String] {
        let data = try await get(host: account.host, path: "/api/v1/followed_tags",
                                 query: [URLQueryItem(name: "limit", value: "80")],
                                 token: account.token)
        return try Self.decoder.decode([MastodonDTO.TagResults.Tag].self, from: data)
            .compactMap { Post.normalisedTags([$0.name]).first }
    }

    /// `POST /api/v1/tags/:name/unfollow`. The name and not an id: a hashtag has no id anywhere.
    public func unfollowTag(_ tag: String, as account: ActingAccount) async throws {
        guard let escaped = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !escaped.isEmpty
        else { throw SourceFailure.notItsPost(tag) }
        _ = try await write("POST", "/api/v1/tags/\(escaped)/unfollow", as: account)
    }

    /// `GET /api/v1/lists` — what this account has made on its own server.
    public func lists(as account: ActingAccount) async throws -> [ServerList] {
        let data = try await get(host: account.host, path: "/api/v1/lists", query: [],
                                 token: account.token)
        return try Self.decoder.decode([MastodonDTO.List].self, from: data)
            .map { ServerList(id: $0.id, title: $0.title, host: account.host) }
    }
}

extension MastodonDTO {
    /// One list, as `/api/v1/lists` gives it. Only the two fields this app can use: reading one
    /// as a timeline is #103's and is not built, so its replies policy is not read.
    struct List: Decodable, Sendable {
        let id: String
        let title: String
    }
}
