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
        let inner = URLSessionClient(session: session, sameOriginOnly: true)
        let client = LoopbackClient(inner: inner)
        boxed = client
        return client
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
