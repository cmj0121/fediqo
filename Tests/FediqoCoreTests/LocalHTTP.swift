import Darwin
import Foundation
@testable import FediqoCore

/// Why a request to a local server did not go out.
enum LocalHTTPError: Error, Equatable {
    case invalidURL
    /// The host is not one of the three this machine is running, so the ask would leave it.
    case leftTheMachine(String)
    case unresolvable(String)
    case missingCA
    case unhealthy(String)
}

/// The three hosts `make servers` publishes on loopback HTTPS, and the client that talks
/// to them the way Fediqo talks to a source: `https` only, this app's agent, and never a
/// name that is not on this machine.
///
/// **The gate is two questions, on purpose.** `.enabled(if:)` can only skip. `FEDIQO_SERVERS`
/// unset must skip; set with a dead healthcheck must **fail**. Putting the healthcheck in
/// `enabled(if:)` would skip both, so the env is the trait and `requireHealthy()` is the
/// first line of every live test.
enum LocalServers {
    static let mastodon = "mastodon.localhost"
    static let discourse = "discourse.localhost"
    static let discuz = "discuz.localhost"

    static let hosts: Set<String> = [mastodon, discourse, discuz]

    static var requested: Bool {
        ProcessInfo.processInfo.environment["FEDIQO_SERVERS"] == "1"
    }

    static func requireHealthy() async throws {
        let http = try LocalHTTP.client()
        for (host, path) in [
            (mastodon, "/health"),
            (discourse, "/srv/status"),
            (discuz, "/forum.php"),
        ] {
            guard let url = Host.httpsURL(host: host, path: path) else {
                throw LocalHTTPError.invalidURL
            }
            let (_, response) = try await http.data(from: url)
            guard (200 ..< 400).contains(response.statusCode) else {
                throw LocalHTTPError.unhealthy(host)
            }
        }
    }

    static func writerToken() throws -> String {
        let url = repoRoot.appending(path: "servers/.run/mastodon-token")
        let raw = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw LocalHTTPError.unhealthy(mastodon) }
        return raw
    }

    /// What `servers-up` wrote beside the writer's first sign-in (#298): a sign-in of the writer
    /// and of a second person that may do everything a person can, the seeded app's id, and the
    /// ids of what the seed put in the writer's home, a list and what is rising — none of which
    /// this server would put there by itself, with no background worker running.
    struct Seeded: Decodable {
        struct Posts: Decodable {
            let list: String
            /// The other person's post, never changed.
            let plain: String
            /// The other person's post, changed once.
            let edited: String
            /// The other person's reblog of the writer's first note, and that note.
            let reblog: String
            let reblogged: String
        }
        /// What the seed made happen to the writer (#323), and the writer's sign-ins as this app
        /// makes them — none of which a check can make for itself: this server tells nobody of
        /// anything until its queued jobs are run, and the seed runs them.
        struct Notices: Decodable {
            /// A sign-in and the scopes it was made with, word for word.
            struct SignIn: Decodable {
                let token: String
                let scopes: String
            }
            /// One person's private mention the server is holding back, and who.
            struct Held: Decodable {
                let by: String
                let post: String
            }
            /// This app as it registers itself to ask for notices on top of reading and acting,
            /// registered by the seed.
            struct App: Decodable {
                let id: String
                let secret: String
                let scopes: String
            }
            /// Made before notices were asked for: one that reads, one that reads and acts.
            let reading: SignIn
            let acting: SignIn
            /// Made since: one that reads notices, one that reads and dismisses them.
            let noticing: SignIn
            let dismissing: SignIn
            let app: App
            /// Somebody the writer does not follow, who favoured, boosted and followed.
            let third: String
            /// The other person's posts: one naming the writer, one answering them, one the
            /// writer boosted that was then changed, one quoting a post of the writer's.
            let mention: String
            let answer: String
            let changed: String
            let quoting: String
            /// The writer's own: a post favoured and boosted by two, a poll that ended, and a
            /// post whose two favourites lie more than a page apart.
            let liked: String
            let poll: String
            let cut: String
            /// The writer's posts whose one favourite is there to be dismissed.
            let spare: [String]
            let held: [Held]
        }
        let writer: String
        let other: String
        let client: String
        let seeded: Posts
        /// Nothing in a file a seed older than #323 wrote, which the checks of posts still read.
        let notices: Notices?
    }

    static func seeded() throws -> Seeded {
        let url = repoRoot.appending(path: "servers/.run/mastodon-tokens.json")
        return try JSONDecoder().decode(Seeded.self, from: Data(contentsOf: url))
    }

    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return url
    }
}

enum LocalHTTP {
    /// Refuses before a socket is opened: not `https`, not one of the three hosts, or a
    /// host that does not resolve to loopback. Called from the live client and from the
    /// test that pins "nothing leaves this machine" without needing the servers up.
    static func admit(_ url: URL) throws {
        guard Host.isFetchable(url), let host = url.host(), !host.isEmpty else {
            throw LocalHTTPError.invalidURL
        }
        let lowered = host.lowercased()
        guard LocalServers.hosts.contains(lowered) else {
            throw LocalHTTPError.leftTheMachine(lowered)
        }
        try LoopbackDNS.assertLoopback(lowered)
    }

    static func client() throws -> some HTTPClient & HTTPSender {
        try Cache.shared.client()
    }

    /// A session that keeps cookies and follows no redirect, for the one thing a sign-in page
    /// needs that a source's API does not: to be signed in to as a person at a browser is, and
    /// to see where the page sends them. Admitted as every other ask here is.
    static func browser() throws -> LocalBrowser {
        try Cache.shared.browser()
    }
}

/// Resolves a name and refuses it unless every address is loopback. A poisoned
/// `*.localhost` that pointed at the public net would otherwise be a test that left
/// this machine while claiming not to.
enum LoopbackDNS {
    static func assertLoopback(_ host: String) throws {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let err = host.withCString { getaddrinfo($0, nil, &hints, &info) }
        guard err == 0, let first = info else {
            throw LocalHTTPError.unresolvable(host)
        }
        defer { freeaddrinfo(first) }

        var node: UnsafeMutablePointer<addrinfo>? = first
        var saw = false
        while let current = node {
            saw = true
            guard let addr = current.pointee.ai_addr,
                  isLoopback(family: Int32(current.pointee.ai_family), addr: addr)
            else {
                throw LocalHTTPError.leftTheMachine(host)
            }
            node = current.pointee.ai_next
        }
        guard saw else { throw LocalHTTPError.unresolvable(host) }
    }

    private static func isLoopback(family: Int32, addr: UnsafePointer<sockaddr>) -> Bool {
        if family == AF_INET {
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                return (UInt32(bigEndian: $0.pointee.sin_addr.s_addr) >> 24) == 127
            }
        }
        if family == AF_INET6 {
            return addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var v6 = $0.pointee.sin6_addr
                return withUnsafeBytes(of: &v6) { raw in
                    let bytes = Array(raw.bindMemory(to: UInt8.self))
                    guard bytes.count >= 16 else { return false }
                    if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
                    if bytes.prefix(10).allSatisfy({ $0 == 0 }),
                       bytes[10] == 0xff, bytes[11] == 0xff,
                       bytes[12] == 127
                    {
                        return true
                    }
                    return false
                }
            }
        }
        return false
    }
}

/// Trusts Caddy's local CA and nothing else, and only for the three hosts.
final class LocalTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let anchors: [SecCertificate]
    let allowed: Set<String>

    init(anchors: [SecCertificate], allowed: Set<String>) {
        self.anchors = anchors
        self.allowed = allowed
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let host = space.host.lowercased()
        guard allowed.contains(host),
              space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// One session, kept so the trust delegate outlives the first request.
private final class Cache: @unchecked Sendable {
    static let shared = Cache()
    private let lock = NSLock()
    private var boxed: LoopbackClient?
    private var trust: LocalTrust?

    func client() throws -> LoopbackClient {
        lock.lock()
        defer { lock.unlock() }
        if let boxed { return boxed }
        let ca = try Self.loadCA()
        let trust = LocalTrust(anchors: [ca], allowed: LocalServers.hosts)
        self.trust = trust
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        let session = URLSession(
            configuration: configuration,
            delegate: trust,
            delegateQueue: nil
        )
        let inner = URLSessionClient(session: session, sameOriginOnly: true, watchedOnly: false)
        let client = LoopbackClient(inner: inner)
        boxed = client
        return client
    }

    func browser() throws -> LocalBrowser {
        let trust = LocalTrust(anchors: [try Self.loadCA()], allowed: LocalServers.hosts)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return LocalBrowser(session: URLSession(configuration: configuration, delegate: trust, delegateQueue: nil))
    }

    private static func loadCA() throws -> SecCertificate {
        let env = ProcessInfo.processInfo.environment["FEDIQO_SERVERS_CA"]
        let url = env.map { URL(fileURLWithPath: $0) }
            ?? LocalServers.repoRoot.appending(path: "servers/.run/root.crt")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalHTTPError.missingCA
        }
        let pem = try Data(contentsOf: url)
        return try certificate(fromPEM: pem)
    }

    private static func certificate(fromPEM pem: Data) throws -> SecCertificate {
        let text = String(decoding: pem, as: UTF8.self)
        let body = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.contains("-----") }
            .joined()
        guard let der = Data(base64Encoded: body),
              let cert = SecCertificateCreateWithData(nil, der as CFData)
        else {
            throw LocalHTTPError.missingCA
        }
        return cert
    }
}

/// See `LocalHTTP.browser()`.
struct LocalBrowser: Sendable {
    let session: URLSession

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw LocalHTTPError.invalidURL }
        try LocalHTTP.admit(url)
        let (data, response) = try await session.data(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse else { throw LocalHTTPError.invalidURL }
        return (data, http)
    }
}

struct LoopbackClient: HTTPClient, HTTPSender {
    let inner: URLSessionClient

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try LocalHTTP.admit(url)
        return try await inner.data(from: url)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw LocalHTTPError.invalidURL }
        try LocalHTTP.admit(url)
        return try await inner.send(request)
    }
}
