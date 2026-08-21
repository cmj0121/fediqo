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
        let host = Server.normalise(rawHost)
        guard Server.looksLikeHost(host) else { throw SourceFailure.badHost(rawHost) }

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

    public func timeline(host: String, limit: Int) async throws -> [Post] {
        try await posts(host: host, path: "/api/v1/timelines/public", limit: limit)
    }

    public func trending(host: String, limit: Int) async throws -> [Post] {
        try await posts(host: host, path: "/api/v1/trends/statuses", limit: limit)
    }

    // MARK: - Transport

    private func posts(host rawHost: String, path: String, limit: Int) async throws -> [Post] {
        let host = Server.normalise(rawHost)
        let data = try await get(host: host, path: path, query: [
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return try Self.decoder.decode([MastodonDTO.Status].self, from: data).map { $0.asPost(from: host) }
    }

    private func get(host: String, path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw SourceFailure.badHost(host) }
        return try await JSONTransport.get(url, on: session)
    }
}

/// One request, one status check. Shared so that everything asking a server for JSON tells
/// refusal apart from breakage the same way.
enum JSONTransport {
    static func get(_ url: URL, on session: URLSession, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401, 403, 422:
                // The endpoint is there and is refusing a stranger, which is a different
                // thing from the server being broken and is worth saying differently.
                throw SourceFailure.needsSignIn(url.host() ?? url.absoluteString)
            default:
                throw SourceFailure.http(http.statusCode)
            }
        } catch let failure as SourceFailure {
            throw failure
        } catch {
            throw SourceFailure.transport(error.localizedDescription)
        }
    }
}
