import Foundation
@testable import FediqoCore

/// A transport that answers from a table instead of the network.
///
/// Routes are keyed by host, and every suite using this picks hostnames of its own, so the
/// suites stay independent without having to run one at a time.
final class StubRoutes: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (status: Int, body: Data)] = [:]
    /// What an endpoint answers a request that carries a credential, where that differs.
    private var authorizedRoutes: [String: (status: Int, body: Data)] = [:]
    /// Every request in the order it arrived — the one log both views below read from.
    private var log: [(key: String, request: CapturedRequest)] = []

    func on(_ host: String, _ path: String, status: Int, body: String = "[]") {
        lock.withLock { routes["\(host)|\(path)"] = (status, Data(body.utf8)) }
    }

    /// What this endpoint answers a request bearing a credential — a server with a stale
    /// token, in practice, which turns the token down and still publishes to strangers.
    func onAuthorized(_ host: String, _ path: String, status: Int, body: String = "[]") {
        lock.withLock { authorizedRoutes["\(host)|\(path)"] = (status, Data(body.utf8)) }
    }

    func answer(for url: URL, method: String, body: Data, authorization: String?) -> (status: Int, body: Data) {
        let key = "\(url.host() ?? "")|\(url.path())"
        return lock.withLock {
            log.append((key, CapturedRequest(method: method, query: Self.query(of: url),
                                             body: String(decoding: body, as: UTF8.self),
                                             authorization: authorization)))
            if authorization != nil, let authorized = authorizedRoutes[key] { return authorized }
            return routes[key] ?? (404, Data("{}".utf8))
        }
    }

    /// A request's query as a dictionary — what a GET actually asked for, which is where a
    /// page's cursor is spelled.
    private static func query(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                          uniquingKeysWith: { _, last in last })
    }

    /// The paths asked of one host, in the order they were asked.
    func paths(for host: String) -> [String] {
        lock.withLock {
            log.map(\.key).filter { $0.hasPrefix("\(host)|") }.map { String($0.dropFirst(host.count + 1)) }
        }
    }

    /// What was actually sent to one endpoint, in the order it was sent.
    func requests(for host: String, _ path: String) -> [CapturedRequest] {
        lock.withLock { log.filter { $0.key == "\(host)|\(path)" }.map(\.request) }
    }
}

/// One request as the stub saw it, body and all.
struct CapturedRequest: Sendable {
    let method: String
    /// What the URL asked for, by name — `limit`, and `max_id` where a page was asked for.
    let query: [String: String]
    let body: String
    let authorization: String?

    /// The form body read back into fields, for asserting on what a POST said.
    var fields: [String: String] {
        Dictionary(uniqueKeysWithValues: body.split(separator: "&").compactMap { pair in
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2,
                  let name = halves[0].removingPercentEncoding,
                  let value = halves[1].removingPercentEncoding else { return nil }
            return (name, value)
        })
    }
}

let stubRoutes = StubRoutes()

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer = stubRoutes.answer(
            for: url,
            method: request.httpMethod ?? "GET",
            body: requestBody(),
            authorization: request.value(forHTTPHeaderField: "Authorization")
        )
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a POST's body to a protocol as a stream, not as `httpBody`.
    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// A `SourceClient` written for one question, with sensible nothings for the other three.
///
/// The doubles in these suites each exist to watch one thing — what cursor was sent, what a
/// held request does to the next reach, which host got which list — and each was carrying three
/// identical stubbed methods to get there. This is that boilerplate, once.
///
/// A **marker**: the defaults are on this and never on `SourceClient` itself. Put there they
/// would reach `MastodonClient` too, and a real client that lost a method would quietly compile
/// against a stub that answers "" and `[]` and `true` instead of failing to build — which is
/// the one thing a protocol with four requirements is there to prevent. A double opts in by
/// name; anything that wants its own answer just writes one, and it wins.
protocol StubClient: SourceClient {}

extension StubClient {
    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "")
    }

    /// These suites read the public timeline. A double that answered somebody's home timeline
    /// would put reading on a screen no test asked for it on — and would hide the one thing
    /// worth watching, which is that a home read is only ever sent where there is a credential.
    func home(host: String, limit: Int, before: Post?, token: String) async throws -> [Post] { [] }

    /// These suites read timelines. A double that invented a trending list would put posts on
    /// a screen no test asked for them on.
    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }

    /// Nothing in these suites opens a post, so a double that invented a conversation would be
    /// answering a question none of them asked.
    func context(of post: Post, host: String, token: String?) async throws -> Conversation {
        Conversation(post: post)
    }

    /// Nothing in these suites reconciles, and a double that answered "gone" would mark posts
    /// no test asked it to. Still there is the answer that decides nothing.
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }
}

/// A Mastodon server the stub answers for.
func makeServer(_ host: String) -> Server {
    Server(host: host, socialProtocol: .mastodon, title: host)
}

/// A loader that only speaks Mastodon, through the stub. `secrets` is in-memory by default so
/// no test ever reaches the real Keychain, whatever a loader is handed a store.
func stubbedLoader(limit: Int = 40, store: LocalStore? = nil, secrets: any SecretStore = InMemorySecretStore(),
                   tokens: TokenSource? = nil) -> TimelineLoader {
    TimelineLoader(registry: SourceRegistry(clients: [.mastodon: MastodonClient(session: stubbedSession())]),
                   limit: limit, store: store, secrets: secrets, tokens: tokens)
}

/// One account signed in to `server`, written the way `SignInCoordinator` writes it: the
/// token in the secret store, the fact in `owned_accounts`, and the rows it depends on.
/// Nothing here goes near the network, so a suite can start from signed-in without a
/// handshake it is not testing.
func signInRows(_ token: String, to server: Server,
                store: LocalStore, secrets: any SecretStore) async throws {
    let authorId = "\(server.endpoint)/@ada"
    try secrets.setToken(OAuthToken(accessToken: token, scope: "read", createdAt: Date()), for: authorId)
    let serverRow = LocalStore.serverRow(server)
    let accountRow = LocalStore.AccountRow(id: authorId, proto: serverRow.proto, serverURL: serverRow.url,
                                           handle: "@ada@\(server.host)", displayName: "Ada", avatarURL: nil)
    let ms = LocalStore.milliseconds(Date())
    try await store.write { db in
        try LocalStore.upsertServer(db, serverRow, now: ms)
        try LocalStore.upsertAccount(db, accountRow, now: ms)
        try db.execute(sql: "INSERT INTO owned_accounts (author_id, server_url, created_at) VALUES (?, ?, ?)",
                       arguments: [authorId, serverRow.url, ms])
    }
}

/// The browser, boiled down: reads the `state` off the consent URL and comes straight back
/// approved. What the real one does through ASWebAuthenticationSession, minus the person.
@Sendable func approving(_ consent: URL, _ scheme: String) async throws -> URL {
    let query = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let state = query.first { $0.name == "state" }?.value ?? ""
    return URL(string: "\(scheme)://oauth?code=c0de&state=\(state)")!
}

/// Everything a sign-in test stands on, built fresh per test: the store, the scripted server,
/// and the coordinator between them. The secret store is in-memory, so no test using this
/// goes near the real Keychain.
struct Harness {
    let store: LocalStore
    let secrets = InMemorySecretStore()
    let auth: ScriptedAuthClient
    let coordinator: SignInCoordinator

    init(answering account: SignedInAccount) throws {
        store = try LocalStore.inMemory()
        auth = ScriptedAuthClient(account: account)
        coordinator = SignInCoordinator(store: store, secrets: secrets)
    }

    /// Signed in for real through the coordinator, so the rows and the token are exactly what
    /// the app would have left behind.
    @discardableResult
    func signIn(to server: Server,
                authenticate: @Sendable (URL, String) async throws -> URL = approving) async throws -> SignedInAccount {
        try await coordinator.signIn(server: server, using: auth, authenticate: authenticate)
    }

    func signOut(_ authorId: String) async {
        await coordinator.signOut(authorId: authorId, using: auth)
    }

    /// What the launch check makes of the accounts signed in here. One scripted client
    /// answers for every protocol — it is the only server these tests have.
    func rejected(among servers: [Server]) async -> Set<String> {
        await coordinator.rejectedEndpoints(among: servers) { _ in auth }
    }

    func ownedRows() async throws -> [String] {
        try await store.read { db in
            try String.fetchAll(db, sql: "SELECT author_id FROM owned_accounts ORDER BY author_id")
        }
    }
}

/// A page of statuses as `host` would hand it over, `ids` in the order given. One spelling of
/// the Mastodon status shape for every suite, so a change to what the decoder reads breaks all
/// of them at once rather than one of them quietly.
///
/// `authority` is the server each status's canonical `uri` names — `host` itself by default,
/// which is what a post written there looks like. Naming another is what a post this server is
/// only carrying looks like, and it is what `posts.authority_url` is read out of, so it is how
/// a test arranges for the relay and the authority to be two different machines.
///
/// `at` gives each id its own instant, in the order of `ids`, for a test that needs the page to
/// cover a stretch of time rather than to sit on one. Without it every status shares one
/// instant, which is all a test about anything else needs.
func statusesJSON(_ ids: [String], from host: String, authority: String? = nil,
                  at seconds: [TimeInterval] = []) -> String {
    let origin = authority ?? host
    let statuses = ids.enumerated().map { index, id in
        let postedAt = index < seconds.count ? isoDate(seconds[index]) : "2026-08-21T10:00:00.000Z"
        return """
        {
          "id": "\(id)",
          "uri": "https://\(origin)/users/a/statuses/\(id)",
          "url": "https://\(host)/@a/\(id)",
          "created_at": "\(postedAt)",
          "content": "<p>hello</p>",
          "account": { "id": "10", "url": "https://\(host)/@a", "username": "a", "acct": "a",
                       "display_name": "Ada", "avatar": null },
          "media_attachments": [],
          "tags": []
        }
        """
    }
    return "[\(statuses.joined(separator: ","))]"
}

/// An instant as a server spells one, so a page's `created_at` and a stored post's `at:` can be
/// asked to mean the same moment.
func isoDate(_ seconds: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: Date(timeIntervalSince1970: seconds))
}

/// One status, enough to prove a list came back.
let oneStatusJSON = statusesJSON(["1"], from: "example")

/// A post as `host` would have handed it over — the address `MastodonDTO.asPost` writes, and
/// so the only shape a cursor for `host` can take.
///
/// `authority` is the server whose canonical address the post carries, spelled the way
/// Mastodon spells one. Without it the post has no canonical address at all, which is what a
/// paging cursor needs and all any cursor test ever wanted; with it the post is one that can
/// also be asked about by name, which is what reconciling needs.
func handedOver(_ id: String, from host: String, authority: String? = nil,
                at seconds: TimeInterval = 100) -> Post {
    makePost(uri: "https://\(host)/api/v1/statuses/\(id)",
             originURI: authority.map { "https://\($0)/users/a/statuses/\(id)" },
             at: seconds, from: host)
}

/// The readings these suites ask for, named once.
///
/// Nearly every suite here reads the public timeline with no rules on it, which is what the
/// app read before a timeline was something a reader could make. Naming them keeps that fact
/// visible: a test asking for `.publicPosts` is a test about paging or backoff or tokens,
/// not about rules.
extension TimelineQuery {
    static let publicPosts = TimelineQuery(source: .public)
    static let home = TimelineQuery(source: .home)
    static let trending = TimelineQuery(source: .trend)
}
