import Foundation

/// Everything this app can ask a Mastodon server to *do*, as opposed to hand over.
///
/// All of it goes to the reader's own server and none of it to the server the post came from,
/// for the plainest of reasons: a favourite is an account's act, and this app reads a great
/// many servers nobody here has an account on. Where the reader does have one on the post's
/// own server, the caller passes that as the acting account and the first request below is
/// free — `search` finds the status already there and nothing is fetched.
extension MastodonClient {
    /// The status's id on the acting server, and whether that server had to go and get it.
    ///
    /// Two steps, and the first is often the last. `resolve=false` asks the server what it
    /// already holds; only when that comes back empty is `resolve=true` sent, and that is the
    /// request that makes the server fetch the post from wherever it lives. `fetching: false`
    /// stops before it, which is how a reader who has not agreed to that gets an honest
    /// refusal rather than a quiet federation request in their name.
    public func localId(of post: Post, as account: ActingAccount,
                        fetching: Bool) async throws -> Located {
        // The address the post's own server gave it. A relay's copy is not what we search for:
        // the canonical URI is the one every other server keys the post by.
        let uri = post.originURI ?? post.uri
        if let status = try await searchStatus(uri, as: account, resolving: false) {
            return Located(id: status.id, reach: .alreadyThere, marks: status.marks)
        }
        guard fetching else { throw SourceFailure.notItsPost(uri) }
        guard let status = try await searchStatus(uri, as: account, resolving: true) else {
            throw SourceFailure.notItsPost(uri)
        }
        return Located(id: status.id, reach: .fetched, marks: status.marks)
    }

    public func setMark(_ action: PostAction, on id: String, as account: ActingAccount,
                        done: Bool) async throws {
        let verb: String
        switch action {
        case .favourite: verb = done ? "favourite" : "unfavourite"
        case .reblog: verb = done ? "reblog" : "unreblog"
        case .bookmark: verb = done ? "bookmark" : "unbookmark"
        }
        _ = try await write("POST", "/api/v1/statuses/\(id)/\(verb)", as: account)
    }

    /// An author is muted by account id; a host is blocked by name.
    ///
    /// Two endpoints and two shapes, because Mastodon has two ideas here and they are not the
    /// same idea: muting an account hides it from you, and blocking a domain severs your
    /// server's relationship with it. Both are what a reader means by "mute", so both are
    /// offered under that word — and both take a `DELETE` to undo, which is why the transport
    /// below takes a method at all.
    public func setMute(_ kind: Mute.Kind, _ value: String, as account: ActingAccount,
                        muted: Bool) async throws {
        switch kind {
        case .author:
            guard let id = try await searchAccount(value, as: account) else {
                throw SourceFailure.notItsPost(value)
            }
            _ = try await write("POST", "/api/v1/accounts/\(id)/\(muted ? "mute" : "unmute")", as: account)
        case .host:
            _ = try await write(muted ? "POST" : "DELETE", "/api/v1/domain_blocks",
                                fields: ["domain": value], as: account)
        }
    }

    /// A report names the author, the post, and what the reader wants to say about it.
    ///
    /// The account is looked up rather than sent as a URI: `/api/v1/reports` wants the id on
    /// the server being told, which is the same id the mute above needs and is found the same
    /// way. A report with no account behind it is refused rather than sent half-formed.
    public func report(_ post: Post, id: String, as account: ActingAccount,
                       comment: String) async throws {
        guard let reported = try await searchAccount(post.authorId, as: account) else {
            throw SourceFailure.notItsPost(post.authorId)
        }
        _ = try await write("POST", "/api/v1/reports", fields: [
            "account_id": reported,
            "status_ids[]": id,
            "comment": String(comment.prefix(1000)),
        ], as: account)
    }

    // MARK: - Finding the thing on your own server

    /// The status as the acting server holds it: its id there and the three answers only a
    /// read carrying a credential is ever given.
    ///
    /// A key that is absent is left as `nil` — never told — while a key that is present and
    /// `false` is the server saying so. The two are different facts and the schema keeps them
    /// apart, so the decoding has to as well.
    private func searchStatus(_ uri: String, as account: ActingAccount,
                              resolving: Bool) async throws -> (id: String, marks: PostMarks)? {
        let found = try await search(uri, type: "statuses", as: account, resolving: resolving)
        guard let status = (found["statuses"] as? [[String: Any]])?.first,
              let id = status["id"] as? String else { return nil }
        return (id, PostMarks(favourited: status["favourited"] as? Bool,
                              reblogged: status["reblogged"] as? Bool,
                              bookmarked: status["bookmarked"] as? Bool))
    }

    private func searchAccount(_ authorId: String, as account: ActingAccount) async throws -> String? {
        // An actor URI is always resolvable by a server that already holds the post, and the
        // post is what got us here — so this never reaches further than the status did.
        let found = try await search(authorId, type: "accounts", as: account, resolving: true)
        return (found["accounts"] as? [[String: Any]])?.first?["id"] as? String
    }

    private func search(_ query: String, type: String, as account: ActingAccount,
                        resolving: Bool) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = account.host
        components.path = "/api/v2/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "resolve", value: resolving ? "true" : "false"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else { throw SourceFailure.badHost(account.host) }
        let data = try await JSONTransport.get(url, on: session, bearer: account.token, ledger: ledger)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func write(_ method: String, _ path: String, fields: [String: String] = [:],
                       as account: ActingAccount) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = account.host
        components.path = path
        // A DELETE carries its argument in the query, which is how Mastodon takes a domain
        // block down; a POST carries the same argument in the body.
        if method == "DELETE", !fields.isEmpty {
            components.queryItems = fields.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw SourceFailure.badHost(account.host) }
        return try await JSONTransport.send(method, url, fields: method == "DELETE" ? [:] : fields,
                                            on: session, bearer: account.token, ledger: ledger)
    }
}
