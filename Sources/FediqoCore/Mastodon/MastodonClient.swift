import Foundation

/// Reads a Mastodon server. Everything here but `home` is a public, unauthenticated endpoint
/// — #4's "a public timeline is readable before signing in to anything" — read as whoever is
/// signed in where there is somebody; and where a server declines, that is reported rather
/// than substituted for. `home` is the one endpoint that cannot be asked without a credential,
/// and it is never stood in for by one that can.
public struct MastodonClient: SourceClient {
    // `internal` rather than `private`: the writes live in a file of their own — see
    // MastodonWrites.swift — and an extension in another file cannot reach a private one.
    let session: URLSession
    /// What every request from this client is counted against. Injected rather than reached
    /// for, so a caller wanting its own count — a test, above all — is not touched by anybody
    /// else's requests.
    let ledger: APILedger

    public init(session: URLSession = .shared, ledger: APILedger = .shared) {
        self.session = session
        self.ledger = ledger
    }

    /// The decoder every Mastodon payload goes through, including in tests: date handling is
    /// part of reading a status, so a test that builds its own decoder is not testing this one.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = MastodonClient.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unparsable date: \(raw)"))
            }
            return date
        }
        return decoder
    }()

    // Statuses carry fractional seconds and trends sometimes do not, so both are kept, and
    // both are built once: the strategy above runs per status, and these are stateless.
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from raw: String) -> Date? {
        fractional.date(from: raw) ?? whole.date(from: raw)
    }

    // MARK: - SourceClient

    public func instance(host rawHost: String) async throws -> InstanceInfo {
        let host = try Server.validated(rawHost)

        // v2 is the current shape and v1 the old one. A server that cannot be reached at all
        // says nothing about which, so a transport failure stops here rather than spending a
        // second timeout learning the same thing twice.
        for path in ["/api/v2/instance", "/api/v1/instance"] {
            do {
                let data = try await get(host: host, path: path, query: [])
                if let instance = try? Self.decoder.decode(MastodonDTO.Instance.self, from: data) {
                    return InstanceInfo(
                        host: host,
                        title: instance.title ?? host,
                        summary: HTMLText.plain(instance.description ?? instance.shortDescription ?? ""),
                        thumbnailURL: instance.thumbnail?.url.flatMap(URL.init(string:)),
                        languages: instance.languages ?? [],
                        activeMonthlyUsers: instance.usage?.users?.activeMonth,
                        totalUsers: instance.stats?.userCount,
                        posts: instance.stats?.statusCount,
                        version: instance.version,
                        registrationsOpen: instance.registrations?.enabled,
                        rules: (instance.rules ?? []).compactMap { rule in
                            let text = HTMLText.plain(rule.text ?? "")
                            guard !text.isEmpty else { return nil }
                            let hint = HTMLText.plain(rule.hint ?? "")
                            return InstanceRule(text: text, detail: hint.isEmpty ? nil : hint)
                        },
                        // v2 first, then the older name some forks still answer with. Nothing
                        // of ours if neither said: a composer that does not know says nothing
                        // rather than guessing at somebody else's rule.
                        maxCharacters: instance.configuration?.statuses?.maxCharacters
                            ?? instance.maxTootChars
                    )
                }
            } catch SourceFailure.transport(let reason) {
                throw SourceFailure.transport(reason)
            } catch {
                continue
            }
        }
        throw SourceFailure.notThatKind(.mastodon, host)
    }

    public func timeline(host: String, limit: Int, before: Post?, after: Post? = nil,
                         token: String?) async throws -> [Post] {
        try await posts(host: host, path: "/api/v1/timelines/public", limit: limit,
                        before: before, after: after, token: token)
    }

    public func home(host: String, limit: Int, before: Post?, after: Post? = nil,
                     token: String) async throws -> [Post] {
        try await posts(host: host, path: "/api/v1/timelines/home", limit: limit,
                        before: before, after: after, token: token)
    }

    public func trending(host: String, limit: Int, token: String?) async throws -> [Post] {
        try await posts(host: host, path: "/api/v1/trends/statuses", limit: limit, before: nil, token: token)
    }

    /// `GET /api/v1/statuses/:id/context`, asked of the server the post's own address names.
    ///
    /// Mastodon answers with `ancestors` and `descendants` already in reading order, and this
    /// keeps that order rather than re-sorting: the ancestors are a chain and the descendants
    /// are a conversation, and neither is the timeline's newest-first line.
    ///
    /// A post this server has no number for is `notItsPost`, thrown rather than answered with
    /// an empty conversation — "not ours to talk about" and "nobody replied" are different
    /// answers and a reader is shown different things for them.
    public func context(of post: Post, host rawHost: String, token: String?) async throws -> Conversation {
        let host = Server.normalise(rawHost)
        let id = try Self.canonicalStatusId(of: post, on: host)
        let data = try await get(host: host, path: "/api/v1/statuses/\(id)/context", query: [], token: token)
        let context = try Self.decoder.decode(MastodonDTO.Context.self, from: data)
        return Conversation(ancestors: context.ancestors.map { $0.asPost(from: host) },
                            post: post,
                            descendants: context.descendants.map { $0.asPost(from: host) })
    }

    /// `GET /api/v1/statuses/:id`, asked of the server the post's own address names.
    ///
    /// 404 and 410 are read as the same answer, and that is the measurement rather than a
    /// convenience: mastodon.social answers **404** for a status it will not give, so a
    /// client that only listened for 410 would hear nothing at all. Neither says why, and
    /// the protocol's contract is that `false` does not claim to know why — see `stillHas`.
    ///
    /// Every other status is thrown. A 401 or 403 in particular is a server refusing to
    /// discuss the post, not a server saying it is gone, and reading one as `false` would
    /// turn every private post into a deleted one.
    public func stillHas(_ post: Post, host rawHost: String, token: String?) async throws -> Bool {
        let host = Server.normalise(rawHost)
        let id = try Self.canonicalStatusId(of: post, on: host)
        do {
            _ = try await get(host: host, path: "/api/v1/statuses/\(id)", query: [], token: token)
            return true
        } catch let failure as SourceFailure {
            guard case .http(let status, _) = failure, status == 404 || status == 410 else { throw failure }
            return false
        }
    }

    // MARK: - Transport

    /// `extra` is whatever one endpoint wants and the others do not — `exclude_replies` on an
    /// account's own posts, and nothing anywhere else. Internal rather than private because the
    /// people this app can open live in their own file and page exactly the way a timeline does.
    func posts(host rawHost: String, path: String, limit: Int, before: Post?, after: Post? = nil,
               token: String?, query extra: [URLQueryItem] = []) async throws -> [Post] {
        let host = Server.normalise(rawHost)
        var query = [URLQueryItem(name: "limit", value: String(limit))] + extra
        // `max_id` is Mastodon's word for "older than", and it is spoken here and nowhere
        // else. A cursor this server cannot be asked about stops the request rather than
        // quietly dropping the parameter, which would fetch the newest page all over again.
        if let before {
            query.append(URLQueryItem(name: "max_id", value: try Self.statusId(of: before, on: host)))
        }
        // And `min_id` is its other end: "newer than". The two together are a **stretch**, which
        // is the question #92 says this app could not ask — it had the word already, in
        // `notices`, and no way to put it to a timeline.
        //
        // Refused the same way and for the same reason: a number another server gave a post is
        // not a number this one can be asked about, and sending it asks for a page nobody wanted.
        if let after {
            query.append(URLQueryItem(name: "min_id", value: try Self.statusId(of: after, on: host)))
        }
        let data = try await get(host: host, path: path, query: query, token: token)
        return try Self.decoder.decode([MastodonDTO.Status].self, from: data).map { $0.asPost(from: host) }
    }

    /// The server's own number for a post, read back out of the address it handed over.
    ///
    /// `asPost` writes every row's `uri` as `https://<host>/api/v1/statuses/<id>` — a boost
    /// included, which carries the reblog wrapper's own id and so pages like any other row —
    /// so the number is already there and is not stored a second time to fall out of step.
    ///
    /// Anything else is not this server's status: a post that arrived by another protocol,
    /// or one handed over by a different Mastodon server, whose numbers mean nothing here.
    /// Either is refused, because a `max_id` from elsewhere is a page nobody asked for.
    static func statusId(of post: Post, on host: String) throws -> String {
        let parts = try Self.pathOn(host, of: post.uri)
        guard parts.count == 5, parts[1] == "api", parts[2] == "v1", parts[3] == "statuses"
        else { throw SourceFailure.notItsPost(post.uri) }
        return parts[4]
    }

    /// The path of an address, where the address is one on `host` at all — and `notItsPost`
    /// where it is not, which is the whole of what "this server has no number for that post"
    /// means here.
    ///
    /// The two readers around it expect two different shapes and must go on doing so. What
    /// they must not differ about is this: what counts as an address on this server, and what
    /// a URL that is not one throws. Kept here so that hardening it — a port, a trailing
    /// slash, an escaped path — cannot reach one of them and miss the other.
    private static func pathOn(_ host: String, of uri: String?) throws -> [String] {
        guard let uri, let url = URL(string: uri), url.host() == host
        else { throw SourceFailure.notItsPost(uri ?? "") }
        return url.pathComponents
    }

    /// The number the server that wrote a post gave it, read out of the post's own canonical
    /// address rather than out of whatever a relay called it.
    ///
    /// Mastodon spells that address `https://<host>/users/<name>/statuses/<id>`, so the
    /// number is the last part of it. `statusId(of:on:)` above reads a different address for
    /// a different purpose — the local number of the row *this* server handed over, which is
    /// what it can be asked to page from — and the two are deliberately not one function: a
    /// paging cursor must be refused unless it is the server's own row, and mixing the
    /// canonical address into that check would weaken it.
    ///
    /// Anything not of that shape is refused. Another ActivityPub server names its objects
    /// however it likes, and its addresses carry no number this endpoint could be asked
    /// about; guessing one would ask for a status that was never there and read the answer
    /// as a post withdrawn — the one mistake this must never make.
    static func canonicalStatusId(of post: Post, on host: String) throws -> String {
        let parts = try Self.pathOn(host, of: post.originURI)
        guard parts.count == 5, parts[1] == "users", parts[3] == "statuses"
        else { throw SourceFailure.notItsPost(post.originURI ?? post.uri) }
        return parts[4]
    }

    /// The acting server's own number for a post, where the acting server is one of the two
    /// that already named it — and `nil` where it is neither, which is the only case that has
    /// to be looked up.
    ///
    /// Two addresses, two ways of a post being this server's. `originURI` is the post's
    /// canonical name and its host is the server that wrote it; `uri` is the row we were
    /// handed and its host is the server that handed it over. Either one being `host` means
    /// the number inside that address is a number `host` can be asked about, which is the
    /// whole of what a write needs — so nothing is sent to find out what we were already told.
    ///
    /// The canonical name is tried first, because it is the post itself. `uri` comes second
    /// and is a boost's own wrapper where the row is a boost; that is still the right id to
    /// send, because a favourite, a boost or a bookmark aimed at a reblog is carried through
    /// to the status it reblogged — the reader's star lands on the post, not on the boost.
    static func ownId(of post: Post, on host: String) -> String? {
        (try? canonicalStatusId(of: post, on: host)) ?? (try? statusId(of: post, on: host))
    }

    /// The one door to the network here. A token becomes the bearer header and nothing else
    /// changes: the same URL, the same endpoint, asked for as somebody rather than as anybody.
    ///
    /// `internal` rather than `private`, for the reason `session` and `ledger` are: the reads
    /// that cannot be made as a stranger live in a file of their own — see
    /// MastodonNotices.swift — and an extension in another file cannot reach a private one.
    func get(host: String, path: String, query: [URLQueryItem], token: String? = nil) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw SourceFailure.badHost(host) }
        return try await JSONTransport.get(url, on: session, bearer: token, ledger: ledger)
    }
}

/// One request, one status check. Shared so that everything asking a server for JSON tells
/// refusal apart from breakage the same way.
enum JSONTransport {
    /// `bearer` is the access token itself, not a header value: the one place that knows how
    /// an OAuth token is spelled into a request is here.
    static func get(_ url: URL, on session: URLSession, bearer: String? = nil, timeout: TimeInterval = 15,
                    ledger: APILedger = .shared) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        return try await counted(url, in: ledger) {
            let (data, status) = try await perform(request, on: session)
            switch status {
            case 200..<300:
                return data
            case 401, 403, 422:
                // The endpoint is there and is refusing, which is a different thing from the
                // server being broken. Who was refused depends on what was sent: an outright no
                // to a request that carried a credential is that credential being turned down,
                // and the account has to act; anything else is a stranger being told to sign in.
                // 422 stays a refusal of the request, not a verdict on who asked.
                let host = url.host() ?? url.absoluteString
                if bearer != nil, status != 422 { throw SourceFailure.tokenRejected(host) }
                throw SourceFailure.needsSignIn(host)
            default:
                throw SourceFailure.http(status, data)
            }
        }
    }

    /// A form-encoded POST, as the OAuth endpoints expect. Neutral like `get`, minus the
    /// `needsSignIn` reading — mid-handshake there is no signed-out stranger — so what a
    /// refusal means is the caller's to say, and the body travels with the status for it.
    static func postForm(_ url: URL, fields: [String: String], on session: URLSession, timeout: TimeInterval = 15,
                         ledger: APILedger = .shared) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(fields)

        return try await counted(url, in: ledger) {
            let (data, status) = try await perform(request, on: session)
            guard (200..<300).contains(status) else { throw SourceFailure.http(status, data) }
            return data
        }
    }

    /// A write, sent as somebody. Beside `postForm` rather than under it, and deliberately:
    /// the handshake above must go on reading a refusal as nothing but a refusal, because
    /// mid-handshake there is no signed-out stranger and no credential to have stopped
    /// working. A write has both — so it takes a method, since a domain block goes up with a
    /// `POST` and comes down with a `DELETE`, and it takes a bearer, which brings back the
    /// `get` reading: a write turned down while carrying a credential is that credential
    /// having expired, and that is the one thing the reader has to act on.
    static func send(_ method: String, _ url: URL, fields: [String: String] = [:],
                     on session: URLSession, bearer: String? = nil,
                     idempotency: String? = nil, timeout: TimeInterval = 15,
                     ledger: APILedger = .shared) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        // The header for a request that was received and whose answer never got back. A second
        // send carrying the same key is answered with what the first one made, rather than
        // making a second post — which is the one failure a composer must not have.
        if let idempotency {
            request.setValue(idempotency, forHTTPHeaderField: "Idempotency-Key")
        }
        if !fields.isEmpty {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = formEncode(fields)
        }

        return try await counted(url, in: ledger) {
            let (data, status) = try await perform(request, on: session)
            switch status {
            case 200..<300:
                return data
            case 401, 403:
                let host = url.host() ?? url.absoluteString
                throw bearer == nil ? SourceFailure.needsSignIn(host) : SourceFailure.tokenRejected(host)
            default:
                throw SourceFailure.http(status, data)
            }
        }
    }

    /// Every request this app makes passes through `get` or `postForm`, so this is where one
    /// is counted: one call against the server it was asked of, and a failure wherever
    /// nothing usable came back. A refusal counts as much as a broken connection — we asked
    /// either way — and a request that throws counts before the throw carries on.
    private static func counted(_ url: URL, in ledger: APILedger,
                                _ send: () async throws -> Data) async throws -> Data {
        let endpoint = Server.endpoint(of: url)
        do {
            let data = try await send()
            ledger.record(endpoint: endpoint, failed: false)
            return data
        } catch {
            ledger.record(endpoint: endpoint, failed: true)
            throw error
        }
    }

    /// Sorted so the same fields make the same bytes, and escaped by hand: URLComponents
    /// leaves `+` alone, which a form reader would take for a space.
    static func formEncode(_ fields: [String: String]) -> Data {
        let body = fields.sorted { $0.key < $1.key }
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static let formAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func formEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }

    private static func perform(_ request: URLRequest, on session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (data, 200) }
            return (data, http.statusCode)
        } catch {
            throw SourceFailure.of(error)
        }
    }
}
