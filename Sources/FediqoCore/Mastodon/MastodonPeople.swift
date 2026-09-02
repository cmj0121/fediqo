import Foundation

/// Somebody, and what the reader is to them — the two halves of #88, which are two questions to
/// two different servers.
///
/// **Who they are and what they wrote** is asked of a server that has already handed one of their
/// posts over. That server is one the reader added and already reads, so opening a person costs
/// nobody a new correspondent. Their own server would answer more completely and is not asked:
/// *not a place your reading is sent* has to mean something at the moment it is inconvenient.
///
/// **What the reader is to them** can only be asked of the reader's own server. A relationship is
/// a fact about an account, and this app reads a great many servers nobody here has an account on.
extension MastodonClient {
    /// Somebody as one server holds them, or nothing where that server has never heard of them.
    ///
    /// `/api/v1/accounts/lookup` and never `/api/v2/search`. Lookup answers about accounts the
    /// server already has and 404s about everybody else, which is exactly the question worth
    /// asking: search answers the same question by going and *fetching* the person first, and a
    /// reader who has only opened somebody has not asked their server to go and introduce itself.
    /// #46 drew the same line about statuses and it is the same line.
    ///
    /// Nothing is thrown for a 404. "This server does not know them" is an answer rather than a
    /// failure — it is the ordinary state of a stranger on the reader's own server, and the page
    /// says so rather than showing an error.
    public func profile(handle: String, host rawHost: String, token: String?) async throws -> Profile? {
        let host = Server.normalise(rawHost)
        // `@somebody@their.server` is how a row spells a handle; the endpoint wants it bare.
        let acct = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        do {
            let data = try await get(host: host, path: "/api/v1/accounts/lookup",
                                     query: [URLQueryItem(name: "acct", value: acct)], token: token)
            return try Self.decoder.decode(MastodonDTO.Account.self, from: data).asProfile(on: host)
        } catch let failure as SourceFailure {
            // A 404 is the answer rather than a failure: "this server has never heard of them"
            // is the ordinary state of a stranger on the reader's own server, and the page says
            // so. Anything else is a server having trouble and is passed on.
            if case .http(404, _) = failure { return nil }
            throw failure
        }
    }

    /// What one person has written, as one server holds it.
    ///
    /// The same paging every other stretch of posts uses, so a page of somebody's posts merges,
    /// stores and rotates the way a page of a timeline does — `before` is that server's own
    /// cursor and nothing here invents one.
    ///
    /// Boosts are asked for and replies are not. A profile is what somebody chose to put their
    /// name to, and Mastodon's own `exclude_replies` is how a server is told the difference; a
    /// reader who wants the replies has the conversation the post came from.
    public func posts(by id: String, host rawHost: String, limit: Int,
                      before: Post?, token: String?) async throws -> [Post] {
        try await posts(host: Server.normalise(rawHost), path: "/api/v1/accounts/\(id)/statuses",
                        limit: limit, before: before, token: token,
                        query: [URLQueryItem(name: "exclude_replies", value: "true")])
    }

    /// What the reader is to somebody, asked of the reader's own server and of nothing else.
    ///
    /// Two requests and both of them local: the lookup above, which does not fetch, and then
    /// `/api/v1/accounts/relationships`. Where the acting server has never heard of them the
    /// answer is `nil` — not "you do not follow them", which is the same shape and a different
    /// fact. A page that drew the second for the first would be answering a question its server
    /// was never asked.
    public func relationship(with handle: String, as account: ActingAccount) async throws -> Relationship? {
        guard let profile = try await profile(handle: handle, host: account.host, token: account.token)
        else { return nil }
        return try await relationship(withId: profile.id, as: account)
    }

    /// The same question once the id on the acting server is already known — after a follow, say,
    /// which had to resolve them to send it.
    public func relationship(withId id: String, as account: ActingAccount) async throws -> Relationship? {
        let data = try await get(host: account.host, path: "/api/v1/accounts/relationships",
                                 query: [URLQueryItem(name: "id[]", value: id)], token: account.token)
        guard let first = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]])?.first
        else { return nil }
        return Self.relationship(from: first)
    }

    /// Follow somebody, or stop.
    ///
    /// **This is the request that is allowed to reach further than the reader has looked**, and it
    /// is the only one on this page that is: a server cannot follow on your behalf somebody it has
    /// never heard of, so the first follow of a stranger resolves them, which is a fetch. That is
    /// the reader pressing a button that says what it does, rather than something their server did
    /// because they glanced at a row.
    ///
    /// What comes back is the relationship as it now stands, read off the server's own answer
    /// rather than assumed from what was asked — a locked account answers `requested`, not
    /// `following`, and a control that guessed would claim an approval nobody has given.
    public func setFollow(_ following: Bool, with handle: String,
                          as account: ActingAccount) async throws -> Relationship {
        let id: String
        if let known = try await profile(handle: handle, host: account.host, token: account.token) {
            id = known.id
        } else if following {
            guard let found = try await searchAccount(handle, as: account) else {
                throw SourceFailure.notItsPost(handle)
            }
            id = found
        } else {
            // Nothing to stop doing. A server that has never heard of them is not following
            // them, and asking it to unfollow would be asking it to fetch a stranger in order
            // to not follow them.
            return Relationship()
        }
        let data = try await write("POST", "/api/v1/accounts/\(id)/\(following ? "follow" : "unfollow")",
                                   as: account)
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Relationship(following: following) }
        return Self.relationship(from: body)
    }

    /// A relationship out of the object Mastodon answers every one of these with.
    ///
    /// A key that is absent reads as `false` rather than as unknown, and here that is right: the
    /// endpoint answers about every one of them at once, so a relationship it did not mention is
    /// one it says is not there. `PostMarks` keeps absent and false apart for the opposite reason
    /// — a status read without a credential is told about none of them.
    static func relationship(from body: [String: Any]) -> Relationship {
        Relationship(following: body["following"] as? Bool ?? false,
                     followedBy: body["followed_by"] as? Bool ?? false,
                     requested: body["requested"] as? Bool ?? false,
                     muting: body["muting"] as? Bool ?? false,
                     blocking: body["blocking"] as? Bool ?? false)
    }
}

extension MastodonDTO.Account {
    /// The account as a profile, keyed the way the store keys people.
    ///
    /// The same decoder reads this and the copy of an account that rides on every status, so
    /// everything a status leaves out is optional here and stays optional in `Profile`: a count
    /// nobody sent is not a zero.
    func asProfile(on host: String) -> Profile {
        Profile(id: id,
                authorId: authorId(on: host),
                name: name,
                handle: handle(on: host),
                avatarURL: avatar.flatMap(URL.init(string:)),
                note: HTMLText.plain(note ?? ""),
                emojis: (emojis ?? []).compactMap(\.asEmoji),
                posts: statusesCount,
                followers: followersCount,
                following: followingCount,
                joined: createdAt,
                locked: locked ?? false)
    }
}
