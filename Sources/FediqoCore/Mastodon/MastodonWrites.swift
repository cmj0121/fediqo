import Foundation

/// Everything this app can ask a Mastodon server to *do*, as opposed to hand over.
///
/// All of it goes to the reader's own server and none of it to the server the post came from,
/// for the plainest of reasons: a favourite is an account's act, and this app reads a great
/// many servers nobody here has an account on. Where the reader does have one on the post's
/// own server, the caller passes that as the acting account — and then there is nothing to
/// look up at all, because that server's own number for the post is already in the address
/// this app stored.
extension MastodonClient {
    /// The status's id on the acting server, and whether that server had to go and get it.
    ///
    /// The first question is whether there is anything to look up at all. Where the acting
    /// server is the one that wrote the post, or the one that handed it over, its own number
    /// for the post is already inside the address this app stored — see `ownId` — and the
    /// answer is free. That is the reader's own timeline, which is most of what a star is ever
    /// pressed on, and it used to be the case that failed: the lookup below was sent for it
    /// and came back empty, so favouriting a post on your own server was refused as a post
    /// that server had never heard of.
    ///
    /// Everything else is somebody else's post, and Mastodon has one way to ask about one by
    /// address: `/api/v2/search`. That search reads a query as an address **only** when
    /// `resolve=true`; with `resolve=false` the same query falls through to the full-text
    /// index, which answers about no statuses at all on a server with no Elasticsearch behind
    /// it and would not match a URI if there were. So there is no asking a Mastodon server
    /// "do you already hold this one" without also asking it to go and fetch it — and a
    /// reader who has not agreed to that is refused here rather than sent a question whose
    /// only possible answer is no.
    public func localId(of post: Post, as account: ActingAccount,
                        fetching: Bool) async throws -> Located {
        if let id = Self.ownId(of: post, on: account.host) {
            return Located(id: id, reach: .alreadyThere)
        }
        // The address the post's own server gave it. A relay's copy is not what we search for:
        // the canonical URI is the one every other server keys the post by.
        let uri = post.originURI ?? post.uri
        guard fetching else { throw SourceFailure.notItsPost(uri) }
        guard let status = try await searchStatus(uri, as: account) else {
            throw SourceFailure.notItsPost(uri)
        }
        return Located(id: status.id, reach: .fetched, marks: status.marks)
    }

    /// Mastodon answers a write with the whole status, so the numbers come back with the act
    /// that changed them and are read off it rather than guessed at. A boost answers about the
    /// reblog it just made and carries the original underneath, which is where the numbers
    /// that moved are — so that is the one this reads.
    ///
    /// An answer this cannot make sense of is not an error: the write went through, which is
    /// what was asked for. What comes back is `nil` counts — nobody told us — and the screen
    /// goes on showing the number the post arrived with rather than one made up here.
    @discardableResult
    public func setMark(_ action: PostAction, on id: String, as account: ActingAccount,
                        done: Bool) async throws -> Marked {
        let verb: String
        switch action {
        case .favourite: verb = done ? "favourite" : "unfavourite"
        case .reblog: verb = done ? "reblog" : "unreblog"
        case .bookmark: verb = done ? "bookmark" : "unbookmark"
        }
        let data = try await write("POST", "/api/v1/statuses/\(id)/\(verb)", as: account)
        return Self.marked(from: data)
    }

    /// The three marks and the three numbers, out of a status the server just handed back.
    static func marked(from data: Data) -> Marked {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Marked() }
        // `reblog` is the status a boost wraps. The counts that moved are the original's, and
        // so is every mark: Mastodon carries an act aimed at a reblog through to what it
        // reblogged, and the answer says so in the same place.
        let status = (body["reblog"] as? [String: Any]) ?? body
        let counts = Counts(replies: status["replies_count"] as? Int,
                            reblogs: status["reblogs_count"] as? Int,
                            favourites: status["favourites_count"] as? Int)
        return Marked(marks: PostMarks(favourited: status["favourited"] as? Bool,
                                       reblogged: status["reblogged"] as? Bool,
                                       bookmarked: status["bookmarked"] as? Bool),
                      counts: counts.areKnown ? counts : nil)
    }

    /// `POST /api/v1/statuses` — the one thing here that makes a post rather than marking one.
    ///
    /// What comes back is the status the server made, decoded the way every other status this
    /// app reads is decoded, so the reader's own timeline has it without waiting for a refresh
    /// and it arrives already agreeing with the rows beside it.
    ///
    /// `Idempotency-Key` is the header Mastodon offers for exactly the failure that matters
    /// here: a request that was received and whose answer never got back. A second send of the
    /// same draft carries the same key and the server hands back the post it already made
    /// rather than making a second one. The key is the draft's own content, so two different
    /// drafts are never confused for one and the same draft sent twice on purpose -- a reader
    /// posting the same words again -- would need a different key, which is why it carries the
    /// account and a time as well.
    public func publish(_ draft: Draft, as account: ActingAccount) async throws -> Post {
        var fields = [
            "status": draft.text,
            "visibility": draft.audience.rawValue,
        ]
        // Only when there is one. A server told `spoiler_text=""` has been told there is a
        // warning and it is empty, which is not the same as not being told.
        if let warning = draft.warning { fields["spoiler_text"] = warning }

        // What it answers, by this server's own number for it (#87).
        //
        // The same finding every mark on a post goes through, and `fetching: false` on purpose:
        // a reply to a post this server has never heard of is not something to fetch a stranger
        // for. Where it cannot be found, the reply is refused rather than sent as a new post of
        // its own — a post that was meant as an answer and arrives as an announcement is worse
        // than one that did not arrive.
        if let parent = draft.answering {
            fields["in_reply_to_id"] = try await localId(of: parent, as: account, fetching: false).id
        }

        let data = try await write("POST", "/api/v1/statuses", fields: fields, as: account,
                                   idempotency: Self.key(for: draft, as: account))
        let status = try Self.decoder.decode(MastodonDTO.Status.self, from: data)
        return status.asPost(from: account.host)
    }

    /// One draft, one account, one key. Stable for as long as the draft is, and different the
    /// moment either changes.
    static func key(for draft: Draft, as account: ActingAccount) -> String {
        var hasher = Hasher()
        hasher.combine(draft)
        hasher.combine(account.authorId)
        return String(hasher.finalize(), radix: 16)
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
    private func searchStatus(_ uri: String, as account: ActingAccount) async throws -> (id: String, marks: PostMarks)? {
        let found = try await search(uri, type: "statuses", as: account)
        guard let status = (found["statuses"] as? [[String: Any]])?.first,
              let id = status["id"] as? String else { return nil }
        return (id, PostMarks(favourited: status["favourited"] as? Bool,
                              reblogged: status["reblogged"] as? Bool,
                              bookmarked: status["bookmarked"] as? Bool))
    }

    /// Internal rather than private: following somebody needs the same resolution, for the same
    /// reason and at the same cost, and a second copy of it would be a second place for the
    /// question "may this reach out" to be answered differently.
    func searchAccount(_ authorId: String, as account: ActingAccount) async throws -> String? {
        // An actor URI is always resolvable by a server that already holds the post, and the
        // post is what got us here — so this never reaches further than the status did.
        let found = try await search(authorId, type: "accounts", as: account)
        return (found["accounts"] as? [[String: Any]])?.first?["id"] as? String
    }

    /// `/api/v2/search`, always resolving.
    ///
    /// Not a choice made here but the endpoint's shape: it reads a query as an address only
    /// when `resolve` is set, and both callers above are asking about an address. Sending
    /// `false` would not be a cheaper version of the same question — it is a different
    /// question, one this app never wants to ask, and one that on a stock server answers
    /// nothing at all. Whether a fetch may happen is settled before this is reached.
    private func search(_ query: String, type: String,
                        as account: ActingAccount) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = account.host
        components.path = "/api/v2/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "resolve", value: "true"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else { throw SourceFailure.badHost(account.host) }
        let data = try await JSONTransport.get(url, on: session, bearer: account.token, ledger: ledger)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Every request this app makes that asks a server to *do* something, so that the header,
    /// the credential and the body are written once. Internal for the reason `searchAccount` is:
    /// following is one of those requests and lives in its own file.
    func write(_ method: String, _ path: String, fields: [String: String] = [:],
               as account: ActingAccount, idempotency: String? = nil) async throws -> Data {
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
                                            on: session, bearer: account.token,
                                            idempotency: idempotency, ledger: ledger)
    }
}
