import Foundation

public enum HostError: Error, Equatable, Sendable {
    case invalidHost
}

public enum DetectError: Error, Equatable, Sendable {
    case invalidHost
    case unreachable
    /// Something in front of the host answered instead of the host: a filter's interactive
    /// challenge, where a person in a browser is what it is waiting for.
    ///
    /// **Its own case because `.unknown` is a lie here.** A challenge page names no software, so
    /// every marker `HTMLKind.classify` looks for is absent and the detector used to fall through
    /// and report "unknown protocol" — which tells the reader to check their spelling, for a host
    /// whose spelling is fine. It also strands them: the sign-in that *would* get past this is
    /// only ever offered on a refusal, so reporting it as an unknown protocol closes the one door
    /// that opens.
    case challenged
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

    /// A query value percent-encoded, `+`, `&` and `=` included.
    private static func queryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func httpsURL(host: String, path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty {
            // `URLComponents` leaves `+` bare in a value, and a server reading the query as a form
            // takes it for a space — a post address with `+` in it would search for another (#29).
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.name, value: $0.value.map(Self.queryValue))
            }
        }
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
        // Discuz! names itself the same way — `<meta name="generator" content="Discuz! X3.4" />`,
        // confirmed live on four installs across X3.4, X3.5 and X5.0 — and the tag is in the
        // markup rather than written by script, so it survives a fetch that runs none.
        //
        // **Beside `discourse` rather than anywhere in particular, and that is checked.** The two
        // names share four letters and neither contains the other, so no ordering between them can
        // go wrong; the same is true of every other name in this list. `DetectTests` asserts that
        // for the whole list rather than for this pair, because the hazard is the name added
        // *next* — the list is only safe while it stays mutually exclusive, and a comment saying
        // so is not a check.
        if matches(labeled, "discuz") { return .named(.discuz) }
        if matches(labeled, "mastodon") { return .named(.mastodon) }
        // **A second look for Discuz!, for the installs that strip the meta tag.** The tag is a
        // template's to remove and plenty of administrators do; what a Discuz! cannot remove and
        // keep working are its own addresses. `forum.php?mod=forumdisplay` and `mod=viewthread`
        // are that program's URLs and nobody else's, and the footer line is the one most themes
        // leave alone. Both are checked **after** every other software above, so a host that
        // names itself is still taken at its word and this can only rescue a page that named
        // nothing.
        if matches(labeled, "discuz") == false, isDiscuzByItsOwnAddresses(html) {
            return .named(.discuz)
        }
        if hasID(html, "mastodon") { return .named(.mastodon) }
        if html.range(of: "joinmastodon.org", options: .caseInsensitive) != nil {
            return .named(.mastodon)
        }
        return .unknown
    }

    /// Discuz! recognised by what it serves rather than by what it says about itself.
    ///
    /// Each of these is something no other forum writes: `mod=forumdisplay` and `mod=viewthread`
    /// are Discuz!'s own query strings, and the footer credit carries the product's name with its
    /// exclamation mark. One is enough — a front page need not link a thread, and an index need
    /// not carry the footer — but each is specific enough on its own that "one of these" does not
    /// widen into a guess.
    private static func isDiscuzByItsOwnAddresses(_ html: String) -> Bool {
        let marks = [
            "forum.php?mod=forumdisplay",
            "forum.php?mod=viewthread",
            "mod=forumdisplay&amp;fid=",
            "Powered by Discuz",
        ]
        return marks.contains { html.range(of: $0, options: .caseInsensitive) != nil }
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
            // **Decoded lossily, and that is the correct decode for this one job.** The strict
            // `String(data:encoding:.utf8)` that stood here returns `nil` for the *entire* page
            // if a single byte in it is not UTF-8 — not a mangled string somebody might notice,
            // but nothing at all, after which detection falls through to the probe and reports a
            // running forum as an unknown protocol.
            //
            // That is not a hypothetical. `install-a.example` is a live Discuz! X3.4 whose front
            // page declares UTF-8 and is UTF-8, apart from a handful of leftover GBK bytes in one
            // JavaScript comment — and it detected as `.unknown` until this line changed. A
            // wholly GBK install, which a great many Discuz! still are, fails the same way for a
            // better reason.
            //
            // Lossy is *sufficient* here rather than merely better, and the reason is worth
            // stating because it is what makes this safe for every protocol and not just the
            // new one: **every marker `HTMLKind.classify` looks for is ASCII** — the software
            // names, `joinmastodon.org`, `__misskey_boot__`, the `meta` and `id` patterns — and
            // UTF-8 decoding never substitutes a replacement character for a byte below 0x80. So
            // the bytes that matter arrive unchanged, and only the parts nobody reads are
            // damaged. Guessing an encoding would be the wrong tool: a guess can be wrong, and
            // this cannot.
            let html = String(decoding: data, as: UTF8.self)
            if case .named(let kind) = HTMLKind.classify(html) {
                return try await byItsOwnAccount(kind, host: host)
            }
            // Judged after the software markers and before anything else, and that order is
            // deliberate: a forum that merely *sits behind* a filter still serves its own front
            // page most of the time, and naming itself is a better answer than naming its filter.
            // This is only reached when the page named nothing — which is exactly what a
            // challenge page does.
            if DiscuzPage.isChallenge(html) { throw DetectError.challenged }
        } catch {
            // **Through `Cancellation.happened`, and it is this line the rest of the block was
            // always about.** It used to read `if error is CancellationError`, which against a
            // real `URLSession` never fires: a cancelled transfer arrives as
            // `URLError(.cancelled)`, falls through this swallow to the probe, and the detector
            // then answers a question nobody is waiting for — with a fact about somebody's
            // server, read off a reader's leaving.
            if Cancellation.happened(error) { throw CancellationError() }
            // **Rethrown, where every other failure here is swallowed on purpose.** This block
            // treats a failed front page as "no answer yet" and falls through to the probe,
            // which is right for a timeout or a 404. A challenge is the opposite: the host
            // answered, and what answered was a filter saying no. Falling through would spend a
            // second request on a probe that cannot succeed either, and then report `.unknown` —
            // the sentence that sends the reader to check a spelling that is fine.
            if let refusal = error as? DetectError, refusal == .challenged { throw refusal }
        }

        var probeTalked = false
        do {
            let (data, _) = try await http.data(from: instance)
            probeTalked = true
            return try await byItsOwnAccount(Probe.kind(from: data), host: host)
        } catch {
            // **The guard the comment above the fall-through has always relied on, finally
            // firing.** Written `if error is CancellationError` it never did, so a reader who
            // closed the app mid-probe fell to `return .unknown` below — which `SourceJoin` turns
            // into `unsupportedKind(.unknown)`, which is the sentence telling them to check an
            // address that is perfectly fine. That is the exact outcome the block above says it
            // is here to prevent, and the code did not honour it.
            if Cancellation.happened(error) { throw CancellationError() }
        }

        if !htmlTalked && !probeTalked { throw DetectError.unreachable }
        return .unknown
    }

    /// A host the page or the probe took for a Mastodon, asked what it calls itself.
    ///
    /// **Because neither of those two is the server naming itself.** A link to `joinmastodon.org`
    /// is something any server may write to a visitor, and a `title` beside a bare `version` is
    /// the shape of an answer, not a name. Asked 2026-10-13: a GoToSocial 0.22.2 has both — no
    /// `generator` tag, that link in its own help text, a `version` that is a number — and was
    /// joined as a Mastodon with nothing in it, the refusal written for its kind never reached.
    ///
    /// **Only an answer of Mastodon is asked about, and only one word changes it.** Every other
    /// kind was named by the server already. And whatever is heard here that is not that word —
    /// no answer, an answer nobody can read, a name this app has never met — leaves the host a
    /// Mastodon as it was. Whatever a server calls itself, only that one word changes the answer:
    /// a word not known must never be a server refused.
    ///
    /// Cancellation is the one thing thrown, for the reason the two reads above give.
    private func byItsOwnAccount(_ kind: ProtocolKind, host: String) async throws -> ProtocolKind {
        guard kind == .mastodon else { return kind }
        return try await NodeInfo(http: http).software(of: host) == "gotosocial" ? .gotosocial : kind
    }
}

/// What a server calls itself, in the one document where it says so by name.
///
/// **Node information, and not the instance document.** Both were asked of both servers on
/// 2026-10-13: the instance document of a GoToSocial 0.22.2 names no software anywhere — its
/// `version` is a number and its `source_url` is one more link — while its node information says
/// `"software":{"name":"gotosocial"}` and a Mastodon 4.6.6's says `"name":"mastodon"`.
///
/// Two asks, as the document is published: `/.well-known/nodeinfo` lists where it is, and the
/// address listed is read. Mastodon lists one (schema 2.0); GoToSocial lists two (2.0 and 2.1),
/// and either carries the name.
struct NodeInfo: Sendable {
    struct Listing: Decodable {
        struct Link: Decodable {
            var rel: String?
            var href: String?
        }

        var links: [Link]?
    }

    struct Body: Decodable {
        struct Software: Decodable {
            var name: String?
        }

        var software: Software?
    }

    private static let schema = "http://nodeinfo.diaspora.software/ns/schema/2."

    let http: any HTTPClient

    /// The name, lowercased, or nothing where it could not be read — for whatever reason.
    func software(of host: String) async throws -> String? {
        guard let listing = Host.httpsURL(host: host, path: "/.well-known/nodeinfo"),
              let listed = try await read(Listing.self, from: listing),
              let document = Self.document(listed, host: listing.host()),
              let body = try await read(Body.self, from: document)
        else {
            return nil
        }
        return body.software?.name?.lowercased()
    }

    /// The first address listed that this device may ask: **of the host that was asked** — a
    /// listing is a stranger's JSON, and it does not get to send this app to a server nobody
    /// typed.
    static func document(_ listing: Listing, host: String?) -> URL? {
        for link in listing.links ?? [] where link.rel?.hasPrefix(schema) == true {
            if let url = Host.fetchableURL(link.href), isOf(url, host: host) { return url }
        }
        return nil
    }

    /// Whether `url` is the host that was asked and nothing beside it: `https` on its own port,
    /// that name, and nobody's name or password in front of it.
    static func isOf(_ url: URL?, host: String?) -> Bool {
        guard let url, let host, Host.isFetchable(url) else { return false }
        return url.host()?.lowercased() == host.lowercased()
            && (url.port ?? 443) == 443
            && url.user() == nil && url.password() == nil
    }

    /// How much either answer may bring. The two servers asked sent a few hundred bytes.
    static let ceiling = 1 << 20

    /// One of the two asks, or nothing where it was not an answer of this host's, of this size,
    /// in this shape.
    ///
    /// **Kept to the host twice over, because the client handed in is not always the live one.**
    /// The live client follows a redirect to any `https` host and takes 128 MiB, so where it is
    /// the one in hand it is told to stay on its origin and under the ceiling as it transfers.
    /// A client wrapped by something that records or gates it cannot be told, so whatever comes
    /// back is judged again: an answer that ended at another address, or over the ceiling, is
    /// not this host's account of itself.
    private func read<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T? {
        let kept: any HTTPClient = (http as? URLSessionClient)?.capped(to: Self.ceiling).stayingOnOrigin() ?? http
        do {
            let (data, response) = try await kept.data(from: url)
            guard (200 ..< 300).contains(response.statusCode),
                  Self.isOf(response.url, host: url.host()),
                  data.count <= Self.ceiling
            else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        } catch {
            if Cancellation.happened(error) { throw CancellationError() }
            return nil
        }
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
