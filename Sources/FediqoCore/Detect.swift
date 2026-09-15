import Foundation

public enum HostError: Error, Equatable, Sendable {
    case invalidHost
}

public enum DetectError: Error, Equatable, Sendable {
    case invalidHost
    case unreachable
}

/// A hostname this device can fetch. No scheme, no path, lowercase. IPv6 stays bracketed.
public enum Host {
    public static func parse(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HostError.invalidHost }
        if trimmed.contains("@") { throw HostError.invalidHost }

        let host: String
        if let schemeEnd = trimmed.range(of: "://") {
            let scheme = trimmed[..<schemeEnd.lowerBound]
            guard scheme.lowercased() == "https" else { throw HostError.invalidHost }
            guard let components = URLComponents(string: trimmed),
                  let parsed = components.host, !parsed.isEmpty
            else {
                throw HostError.invalidHost
            }
            host = bracketIPv6(parsed.lowercased())
        } else {
            if trimmed.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0.isWhitespace }) {
                throw HostError.invalidHost
            }
            host = bracketIPv6(trimmed.lowercased())
        }

        guard httpsURL(host: host, path: "/") != nil else {
            throw HostError.invalidHost
        }
        return host
    }

    // URLComponents.host may omit IPv6 brackets; without them it cannot form a URL.
    static func bracketIPv6(_ host: String) -> String {
        if host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]")) {
            return "[\(host)]"
        }
        return host
    }

    /// Whether this device will fetch that address at all: `https`, and a host to reach.
    ///
    /// **The one definition.** `URLSessionClient` fetches under it and `fetchableURL` admits
    /// addresses under it, so the rule that decides what may be asked for and the rule that
    /// decides what may be kept cannot drift apart.
    ///
    /// The host clause is not belt and braces. `https:`, `https://`, `https:///p` and
    /// `https://:8443/p` all parse and all have no host to reach: `URLSession` can only fail
    /// them, but a kept one is an `Attachment` that is not `isEmpty`, so it fills a slot and
    /// starts a fetch that can never finish. `Host.parse` has always insisted on a non-empty
    /// host; this agrees with it.
    static func isFetchable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host()?.isEmpty == false
    }

    /// An address handed over by a remote instance, or nothing where this device will not go
    /// there.
    ///
    /// A post's pictures belong to whatever host wrote it, and that host's JSON is not ours:
    /// `file:///`, `data:` and `javascript:` are all things `URL(string:)` will happily build
    /// out of it, and a picture cache or an `AVPlayer` handed one of those would do as it was
    /// told. The rule this package fetches under, applied where the data stops being ours.
    static func fetchableURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), isFetchable(url) else { return nil }
        return url
    }

    static func httpsURL(host: String, path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }
}

/// What the front page said, when it named a protocol.
public enum HTMLKind: Equatable, Sendable {
    case named(ProtocolKind)
    case unknown

    public static func classify(_ html: String) -> HTMLKind {
        let generator = meta(html, name: "generator")
        let appName = meta(html, name: "application-name")
        let labeled = "\(generator ?? "") \(appName ?? "")"

        if matches(labeled, "akkoma") { return .named(.akkoma) }
        if matches(labeled, "pleroma") { return .named(.pleroma) }
        if html.contains("__misskey_boot__") || matches(labeled, "misskey") {
            return .named(.misskey)
        }
        if matches(labeled, "pixelfed") { return .named(.pixelfed) }
        if matches(labeled, "lemmy") { return .named(.lemmy) }
        if matches(labeled, "peertube") { return .named(.peertube) }
        if matches(labeled, "friendica") { return .named(.friendica) }
        if matches(labeled, "gotosocial") { return .named(.gotosocial) }
        // Discourse names itself in the generator tag on every server-rendered page, and the tag
        // is in the HTML rather than built by script, so it survives a reader with no JavaScript
        // and a fetch that never runs any.
        if matches(labeled, "discourse") { return .named(.discourse) }
        if matches(labeled, "mastodon") { return .named(.mastodon) }
        if hasID(html, "mastodon") { return .named(.mastodon) }
        if html.range(of: "joinmastodon.org", options: .caseInsensitive) != nil {
            return .named(.mastodon)
        }
        return .unknown
    }

    private static func matches(_ text: String, _ software: String) -> Bool {
        text.range(of: software, options: .caseInsensitive) != nil
    }

    private static func hasID(_ html: String, _ id: String) -> Bool {
        let pattern = "id\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: id))[\"']"
        return html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func meta(_ html: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "<meta(?=[^>]*name\\s*=\\s*[\"']\(escaped)[\"'])[^>]*content\\s*=\\s*[\"']([^\"']+)[\"']",
            "<meta(?=[^>]*content\\s*=\\s*[\"']([^\"']+)[\"'])[^>]*name\\s*=\\s*[\"']\(escaped)[\"']",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges > 1,
                  let contentRange = Range(match.range(at: 1), in: html)
            else { continue }
            return String(html[contentRange])
        }
        return nil
    }
}

/// Name the protocol a host speaks: HTML first, then a well-known probe.
public struct Detector: Sendable {
    private let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public func detect(_ raw: String) async throws -> ProtocolKind {
        let host: String
        do {
            host = try Host.parse(raw)
        } catch is HostError {
            throw DetectError.invalidHost
        }

        guard let root = Host.httpsURL(host: host, path: "/"),
              let instance = Host.httpsURL(host: host, path: "/api/v2/instance")
        else {
            throw DetectError.invalidHost
        }

        var htmlTalked = false
        do {
            let (data, _) = try await http.data(from: root)
            htmlTalked = true
            if let html = String(data: data, encoding: .utf8),
               case .named(let kind) = HTMLKind.classify(html)
            {
                return kind
            }
        } catch {
            if error is CancellationError { throw error }
        }

        var probeTalked = false
        do {
            let (data, _) = try await http.data(from: instance)
            probeTalked = true
            return Probe.kind(from: data)
        } catch {
            if error is CancellationError { throw error }
        }

        if !htmlTalked && !probeTalked { throw DetectError.unreachable }
        return .unknown
    }
}

enum Probe {
    struct Body: Decodable {
        var version: String?
        var title: String?
        var domain: String?
    }

    static func kind(from data: Data) -> ProtocolKind {
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              let version = body.version
        else {
            return .unknown
        }
        let lowered = version.lowercased()
        if lowered.contains("akkoma") { return .akkoma }
        if lowered.contains("pleroma") { return .pleroma }
        if lowered.contains("gotosocial") { return .gotosocial }
        if lowered.contains("misskey") { return .misskey }
        if lowered.contains("pixelfed") { return .pixelfed }
        if body.title != nil || body.domain != nil { return .mastodon }
        return .unknown
    }
}
