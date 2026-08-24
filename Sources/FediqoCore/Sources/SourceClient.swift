import Foundation

/// Why a source gave nothing.
///
/// Carried as a case rather than a sentence so a screen can say it in the reader's language,
/// and named for what happened rather than for who it happened to — a server declining a
/// stranger is the same fact whatever protocol it speaks.
public enum SourceFailure: Error, Sendable, Equatable, LocalizedError {
    case badHost(String)
    /// The host answered, but not as the kind of server it was taken for.
    case notThatKind(SocialProtocol, String)
    /// This build has no client for that protocol yet.
    case unsupported(SocialProtocol)
    /// The endpoint is there and is refusing a stranger. Most servers are this one.
    case needsSignIn(String)
    /// The sign-in handshake itself was refused — a spent code, a revoked app. A different
    /// fact from `needsSignIn`, which is a stranger being turned away.
    case signInFailed(String)
    /// A read was sent as somebody and the server turned that somebody down — an expired or
    /// revoked token. Three refusals, three facts: `needsSignIn` is a stranger turned away,
    /// `signInFailed` is a handshake refused, and this is a credential that stopped working.
    /// The read is tried again as a stranger, so this reported alongside posts from the same
    /// host means the anonymous read did arrive — the account is what needs attention, not
    /// the column.
    case tokenRejected(String)
    /// The server answered outside 2xx; the body rides along for whoever can read a
    /// reason out of it.
    case http(Int, Data)
    case transport(String)
    /// The posts arrived and are on the screen, but the local store would not keep them.
    case store(String)

    /// Whether the server answered at all, in spite of this.
    ///
    /// Two of these ride alongside posts that did arrive. `.tokenRejected` is a server
    /// saying *no* to a credential — it answered, and the read went out again as a stranger.
    /// `.store` is our own database refusing to keep what arrived, which is not their
    /// machine's doing at all. Everything else is silence.
    ///
    /// This is what a backoff is decided on, and the switch is exhaustive on purpose: a new
    /// case has to say which kind it is rather than falling into the quiet one.
    public var arrivedAnyway: Bool {
        switch self {
        case .tokenRejected, .store: true
        case .badHost, .notThatKind, .unsupported, .needsSignIn, .signInFailed, .http, .transport: false
        }
    }

    /// The last resort, for anywhere that is not a screen. Screens localise the case instead.
    public var errorDescription: String? {
        switch self {
        case .badHost(let host): "\(host) is not a hostname."
        case .notThatKind(let socialProtocol, let host): "\(host) did not answer as a \(socialProtocol.rawValue) server."
        case .unsupported(let socialProtocol): "\(socialProtocol.rawValue) is not spoken yet."
        case .needsSignIn(let host): "\(host) does not hand this over without signing in."
        case .signInFailed(let reason): "Signing in failed: \(reason)"
        case .tokenRejected(let host): "\(host) no longer accepts the account signed in to it."
        case .http(let code, _): "The server answered \(code)."
        case .transport(let reason): reason
        case .store(let reason): "The local store could not keep what arrived: \(reason)"
        }
    }
}

/// Everything the timeline needs from a server, whatever protocol it speaks.
///
/// The timeline's job — read every source, merge, order by time — is the same for all of
/// them, so it is written once against this and never against a particular protocol.
public protocol SourceClient: Sendable {
    /// Confirms a hostname is the kind of server it is taken for, before it is written down.
    /// Tokenless on purpose: a server is asked this before anyone owns an account on it.
    func instance(host: String) async throws -> InstanceInfo

    /// What the server publishes to anyone — asked for as `token`'s owner where there is one,
    /// which is still the public timeline and never substituted for by anything else.
    func timeline(host: String, limit: Int, token: String?) async throws -> [Post]

    /// What the server says is trending. A separate thing, asked for separately.
    func trending(host: String, limit: Int, token: String?) async throws -> [Post]
}

public struct InstanceInfo: Sendable, Hashable {
    public let host: String
    public let title: String
    public let summary: String

    public init(host: String, title: String, summary: String) {
        self.host = host
        self.title = title
        self.summary = summary
    }
}

/// Which protocols this build can actually read, and what reads them.
///
/// Adding a protocol is registering a client here. Nothing above this line — not the loader,
/// not a screen — learns the name of a new one.
public struct SourceRegistry: Sendable {
    private let clients: [SocialProtocol: any SourceClient]
    private let authClients: [SocialProtocol: any AuthClient]

    public init(clients: [SocialProtocol: any SourceClient], authClients: [SocialProtocol: any AuthClient] = [:]) {
        self.clients = clients
        self.authClients = authClients
    }

    /// `ledger` reaches every client this builds, so what the app asks of other people's
    /// servers is counted whoever assembled the registry.
    public static func standard(session: URLSession = .shared, ledger: APILedger = .shared) -> SourceRegistry {
        SourceRegistry(
            clients: [.mastodon: MastodonClient(session: session, ledger: ledger)],
            authClients: [.mastodon: MastodonAuthClient(session: session, ledger: ledger)]
        )
    }

    /// The protocols a standard registry can read. What the picker greys out follows from
    /// this rather than from a list kept in step with it by hand.
    public static let implemented: Set<SocialProtocol> = [.mastodon]

    public func client(for socialProtocol: SocialProtocol) -> (any SourceClient)? {
        clients[socialProtocol]
    }

    /// Reading a protocol and signing in to it are separate abilities: a client can exist
    /// without an auth client, and a screen greys out Sign in from this, not from a list.
    public func authClient(for socialProtocol: SocialProtocol) -> (any AuthClient)? {
        authClients[socialProtocol]
    }
}
