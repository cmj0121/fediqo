import Foundation

/// Reads a Mastodon server without signing in to it. Everything here is a public,
/// unauthenticated endpoint — #4's "a public timeline is readable before signing in to
/// anything" — and where a server declines, that is reported rather than substituted for.
public struct MastodonClient: SourceClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
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
                        summary: HTMLText.plain(instance.description ?? instance.shortDescription ?? "")
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

    public func timeline(host: String, limit: Int, token: String?) async throws -> [Post] {
        try await posts(host: host, path: "/api/v1/timelines/public", limit: limit, token: token)
    }

    public func trending(host: String, limit: Int, token: String?) async throws -> [Post] {
        try await posts(host: host, path: "/api/v1/trends/statuses", limit: limit, token: token)
    }

    // MARK: - Transport

    private func posts(host rawHost: String, path: String, limit: Int, token: String?) async throws -> [Post] {
        let host = Server.normalise(rawHost)
        let data = try await get(host: host, path: path, query: [
            URLQueryItem(name: "limit", value: String(limit)),
        ], token: token)
        return try Self.decoder.decode([MastodonDTO.Status].self, from: data).map { $0.asPost(from: host) }
    }

    /// The one door to the network here. A token becomes the bearer header and nothing else
    /// changes: the same URL, the same endpoint, asked for as somebody rather than as anybody.
    private func get(host: String, path: String, query: [URLQueryItem], token: String? = nil) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw SourceFailure.badHost(host) }
        return try await JSONTransport.get(url, on: session, bearer: token)
    }
}

/// One request, one status check. Shared so that everything asking a server for JSON tells
/// refusal apart from breakage the same way.
enum JSONTransport {
    /// `bearer` is the access token itself, not a header value: the one place that knows how
    /// an OAuth token is spelled into a request is here.
    static func get(_ url: URL, on session: URLSession, bearer: String? = nil, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

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

    /// A form-encoded POST, as the OAuth endpoints expect. Neutral like `get`, minus the
    /// `needsSignIn` reading — mid-handshake there is no signed-out stranger — so what a
    /// refusal means is the caller's to say, and the body travels with the status for it.
    static func postForm(_ url: URL, fields: [String: String], on session: URLSession, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(fields)

        let (data, status) = try await perform(request, on: session)
        guard (200..<300).contains(status) else { throw SourceFailure.http(status, data) }
        return data
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
        } catch let failure as SourceFailure {
            throw failure
        } catch {
            throw SourceFailure.transport(error.localizedDescription)
        }
    }
}
