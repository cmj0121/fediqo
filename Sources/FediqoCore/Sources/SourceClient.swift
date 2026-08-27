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
    /// The post handed over as "what came before this" is not one of this server's — its
    /// address is not a status on it. Nothing was sent: a server cannot be asked for what
    /// came before a post it never had, and asking without the cursor would hand back the
    /// newest page and repeat what has just been read.
    case notItsPost(String)
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
        case .badHost, .notThatKind, .unsupported, .needsSignIn, .signInFailed, .notItsPost, .http, .transport: false
        }
    }

    /// Whatever went wrong, as one of these: a `SourceFailure` is already the answer, and
    /// anything else — a URLSession error, a decoding failure — is the connection not working,
    /// which is what `.transport` is. Every read funnels through here so that what counts as
    /// silence, and therefore what a backoff is decided on, is settled in one place.
    static func of(_ error: any Error) -> SourceFailure {
        error as? SourceFailure ?? .transport(error.localizedDescription)
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
        case .notItsPost(let uri): "\(uri) is not a status on this server, so there is nothing to read back from."
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
    ///
    /// `before` is a post this server already handed over, and what comes back is the page
    /// before it; `nil` asks for the newest page, which is all anyone asked for until now.
    ///
    /// It is a `Post` and not any server's paging token because a timeline is a line through
    /// time, and "older than this one" is the one thing every protocol can say — each in its
    /// own words, which stay inside its own client: Mastodon reads its number back out of the
    /// address it handed over, and where Nostr arrives it will read `until` off the timestamp.
    /// Nothing above this line ever learns those words. It is also the cursor the store reads
    /// a page back from, so what came from the network and what came from disk are asked for
    /// with the one thing, and cannot disagree about where the page ended.
    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post]

    /// What the server shows the account signed in to it, paged like `timeline`.
    ///
    /// `token` is not optional, and that is the difference between this and the two beside
    /// it: there is no such thing as somebody's home timeline read as nobody. A server with
    /// no account on it is not asked at all, and is never quietly handed its public timeline
    /// instead — the same rule #4 set for a server that publishes no public timeline.
    func home(host: String, limit: Int, before: Post?, token: String) async throws -> [Post]

    /// What the server says is trending. A separate thing, asked for separately.
    ///
    /// It takes no cursor, and that is deliberate rather than missing. A timeline is a thread
    /// of time and "what came before" is a place on it; a trending list is a snapshot the
    /// server curated, and asking for what came before it means nothing — the list is what the
    /// server thinks is rising now, not the front of a queue with more of itself behind it.
    /// A server may well hand out a second page of one, and there is still nothing there a
    /// reader was reading towards. Do not add one back because `timeline` has it.
    func trending(host: String, limit: Int, token: String?) async throws -> [Post]

    /// The conversation around one post: what it answers, and what answered it.
    ///
    /// Asked of one server about one post, the way `stillHas` is, and for the same reason —
    /// this is a question about a post rather than about a stretch of time, so it goes to the
    /// server whose word on that post is final rather than to whoever relayed it.
    ///
    /// It takes no cursor and pages nowhere: a conversation is a shape, not a queue. What
    /// comes back is what that server holds of it now.
    func context(of post: Post, host: String, token: String?) async throws -> Conversation

    /// Whether this server will still hand over one post, asked for on its own.
    ///
    /// The post is the whole of the question, the way it is for `before:`: which of its
    /// addresses names a number on this server, and how that number is spelled into a
    /// request, stays inside the client that speaks the protocol. Nothing above this line
    /// learns those words.
    ///
    /// **`false` is not "the author deleted it", and must never be read as one.** Measured
    /// against mastodon.social on 2026-08-25: a status it will not give answers 404, not
    /// 410 — and a 404 to a request nobody is signed in for covers a post whose visibility
    /// has since narrowed, or an account that has blocked us, exactly as well as one that
    /// was taken down. What is true of all three, and what the reader sees either way, is
    /// that **this server will not hand the post over any more**. That is what `false` says,
    /// and it is why a client must read both statuses the same way.
    ///
    /// Anything that is not an answer — offline, a 5xx, a timeout — is thrown rather than
    /// folded into `false`, because silence decides nothing: a server that cannot be reached
    /// has said no more about a post than a server nobody asked. A post this server has no
    /// number for is `notItsPost`, thrown for the same reason.
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool

    // MARK: - Writing
    //
    // Declared here rather than only in the extension below, and that is not a style choice.
    // A method that exists only in a protocol extension is not a witness: a call through
    // `any SourceClient` binds to the extension at compile time and a conforming type's own
    // version is never reached, however correct it looks. Written here, they dispatch; the
    // extension below still supplies the default, which is the refusal a protocol this build
    // cannot write to deserves.

    /// The post on the acting server: its id there, whether that server had to go and get it,
    /// and what it says this account has already done to it.
    func localId(of post: Post, as account: ActingAccount, fetching: Bool) async throws -> Located

    /// Favourite, boost or bookmark one post, or take it back.
    func setMark(_ action: PostAction, on id: String, as account: ActingAccount, done: Bool) async throws

    /// Mute an author or a whole host on the acting server, or take the mute down.
    func setMute(_ kind: Mute.Kind, _ value: String, as account: ActingAccount, muted: Bool) async throws

    /// Report a post to the acting server. There is no local half of this: a report that goes
    /// nowhere is not a report.
    func report(_ post: Post, id: String, as account: ActingAccount, comment: String) async throws
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

// MARK: - Writing

/// Who an action is sent as, and therefore which server learns of the post.
///
/// It is a value and not a `Server` because the two are different questions. A `Server` in
/// this app is somewhere posts are read from, including servers nobody here has joined; this
/// is the one place the reader has an account, and it is the only place a favourite or a mute
/// can come from.
public struct ActingAccount: Sendable, Hashable {
    /// The reader's own server, bare.
    public let host: String
    /// That account's actor URI, which is how the store keys what it did.
    public let authorId: String
    public let token: String

    public init(host: String, authorId: String, token: String) {
        self.host = host
        self.authorId = authorId
        self.token = token
    }
}

/// What a server had to be told before an action could be sent to it.
///
/// A post the acting server has never seen has no id there, so asking it to favourite the
/// post means asking it to fetch the post first. That is a real consequence — the reader's
/// own server learns that the post exists, and by extension that somebody asked about it —
/// and it is reported rather than done quietly, because this app's whole promise is that
/// nobody is told what you read.
public enum Reach: Sendable, Hashable {
    /// The acting server already held the post. Nothing new was fetched.
    case alreadyThere
    /// The acting server was asked to go and get it. Somebody now knows.
    case fetched
}

/// A post found on the acting server: its id there, what it cost to find, and what that
/// server says this account has already done to it.
///
/// The marks ride along because they are free. Finding the post is a search, and a search
/// answers with the whole status — including whether this account favourited it, boosted it or
/// bookmarked it. Asking again afterwards would be a second request for something already in
/// our hands, and it is the only moment in this app where those answers are had at all: every
/// timeline read is done as a stranger, and a stranger is told none of them.
public struct Located: Sendable, Hashable {
    public let id: String
    public let reach: Reach
    public let marks: PostMarks

    public init(id: String, reach: Reach, marks: PostMarks = .unknown) {
        self.id = id
        self.reach = reach
        self.marks = marks
    }
}

public extension SourceClient {
    /// The post on the acting server: its id there, whether that server had to go and get it,
    /// and what it says this account has already done to it.
    ///
    /// Every write below needs the id: Mastodon's action endpoints take one local to the
    /// server being asked, and the address a post arrived under is somebody else's. Default:
    /// this build cannot write over that protocol.
    func localId(of post: Post, as account: ActingAccount, fetching: Bool) async throws -> Located {
        throw SourceFailure.unsupported(post.socialProtocol)
    }

    /// Favourite, boost or bookmark one post, or take it back.
    func setMark(_ action: PostAction, on id: String, as account: ActingAccount,
                 done: Bool) async throws {
        throw SourceFailure.unsupported(.mastodon)
    }

    /// Mute an author or a whole host on the acting server, or take the mute down.
    func setMute(_ kind: Mute.Kind, _ value: String, as account: ActingAccount,
                 muted: Bool) async throws {
        throw SourceFailure.unsupported(.mastodon)
    }

    /// Report a post to the acting server. There is no local half of this: a report that goes
    /// nowhere is not a report.
    func report(_ post: Post, id: String, as account: ActingAccount,
                comment: String) async throws {
        throw SourceFailure.unsupported(post.socialProtocol)
    }
}
