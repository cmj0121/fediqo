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

    /// Who favourited or boosted a post — `/api/v1/statuses/:id/favourited_by` and
    /// `.../reblogged_by` (#126).
    ///
    /// Asked of the server whose word on the post is final, which is the one that keeps the
    /// list; another server's copy of the post knows only what reached it.
    public func people(_ which: People.AboutAPost, of post: Post, host rawHost: String,
                       limit: Int, token: String?) async throws -> [Profile] {
        let host = Server.normalise(rawHost)
        let id = try Self.canonicalStatusId(of: post, on: host)
        let data = try await get(host: host, path: "/api/v1/statuses/\(id)/\(which.path)",
                                 query: [URLQueryItem(name: "limit", value: String(limit))],
                                 token: token)
        return try Self.decoder.decode([MastodonDTO.Account].self, from: data)
            .map { $0.asProfile(on: host) }
    }

    /// What somebody asked you to read first — `?pinned=true` (#112).
    ///
    /// A separate ask, because it is a separate answer: `exclude_replies` and a cursor mean
    /// nothing here. Mastodon ignores paging on this endpoint, so none is sent — a pinned set is
    /// somebody's choice rather than a stretch of time, and there is no page before it.
    ///
    /// Asked of the server the page is asked of and no other. Which posts somebody pinned is a
    /// thing their own server knows; another server's copy of them is whatever it happened to
    /// see.
    public func pinned(by id: String, host rawHost: String, token: String?) async throws -> [Post] {
        try await posts(host: Server.normalise(rawHost), path: "/api/v1/accounts/\(id)/statuses",
                        limit: 20, before: nil, token: token,
                        query: [URLQueryItem(name: "pinned", value: "true")])
    }

    /// Who somebody follows, or who follows them, as one server holds it (#90).
    ///
    /// **A hidden list and an empty one come back the same**, and that is the endpoint's doing:
    /// somebody who has asked their server not to publish their network gets an empty array and a
    /// 200, exactly as somebody who follows nobody does. Nothing in the profile says which it is
    /// either.
    ///
    /// So this hands back what it was given and says nothing about why. Telling the two apart is
    /// done where both facts are in hand — a `Profile` carries the count the server publishes, and
    /// **a count above zero beside an empty list is somebody who has chosen not to publish it**.
    /// That is an inference and it is drawn once, in `People.reason`, rather than guessed at by
    /// whoever draws a screen.
    ///
    /// `before` is the last row of the page before, and its id is that server's own — the same
    /// cursor rule every page in this app follows.
    public func people(_ kind: People.Kind, of id: String, host rawHost: String, limit: Int,
                       before: Profile?, token: String?) async throws -> [Profile] {
        let host = Server.normalise(rawHost)
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "max_id", value: before.id)) }
        let data = try await get(host: host, path: "/api/v1/accounts/\(id)/\(kind.path)",
                                 query: query, token: token)
        return try Self.decoder.decode([MastodonDTO.Account].self, from: data)
            .map { $0.asProfile(on: host) }
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

extension MastodonClient {
    /// Who a part-typed handle could be, asked of the server the draft will be posted from (#98).
    ///
    /// **`resolve=false`, and that is the whole difference between this and every other search in
    /// this app.** The other two ask a server to go and *fetch* somebody, because they are asking
    /// about an address a reader has already given. This is asked on a keystroke, and a server
    /// sent out to the rest of the network on every letter somebody types is a cost nobody asked
    /// it to pay. So it answers from what it already knows — which is who the reader follows and
    /// who they have talked to, and that is who a reader is nearly always typing.
    ///
    /// The reader's own server and no other: an account is offered so it can be written into a
    /// post that server will send, and one it has never heard of is one it cannot address.
    public func searchPeople(matching query: String, limit: Int,
                             as account: ActingAccount) async throws -> [Profile] {
        let data = try await get(host: account.host, path: "/api/v1/accounts/search",
                                 query: [URLQueryItem(name: "q", value: query),
                                         URLQueryItem(name: "limit", value: String(limit)),
                                         URLQueryItem(name: "resolve", value: "false")],
                                 token: account.token)
        return try Self.decoder.decode([MastodonDTO.Account].self, from: data)
            .map { $0.asProfile(on: account.host) }
    }

    /// What a part-typed hashtag could be — `/api/v2/search?type=hashtags` (#108).
    ///
    /// The same rules the handles above are asked by, for the same reasons. **`resolve=false`**:
    /// resolving would have the reader's server go and fetch whatever the letters look like they
    /// name, which is a third party told what somebody is part-way through typing. The reader's
    /// own server and no other, because a tag is offered so it can go into a post that server
    /// will send.
    ///
    /// The names come back without the `#`, which is how the store keeps them and how a timeline
    /// of one is asked for.
    public func searchTags(matching query: String, limit: Int,
                           as account: ActingAccount) async throws -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data = try await get(host: account.host, path: "/api/v2/search",
                                 query: [URLQueryItem(name: "q", value: trimmed),
                                         URLQueryItem(name: "type", value: "hashtags"),
                                         URLQueryItem(name: "limit", value: String(limit)),
                                         URLQueryItem(name: "resolve", value: "false")],
                                 token: account.token)
        return try Self.decoder.decode(MastodonDTO.TagResults.self, from: data)
            .hashtags.compactMap { Post.normalisedTags([$0.name]).first }
    }
}
