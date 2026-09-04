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
    /// The server was asked for one server's own writers, or for everything but them, and
    /// answered with the whole public timeline anyway (#113).
    ///
    /// Mastodon ignores a query it does not know rather than refusing it, so this is caught by
    /// reading the answer rather than by a status code: a page cut to `here` whose posts were
    /// not written here was not cut. Said out loud, because the quiet alternative is a reader
    /// looking at the federated timeline believing it is the room.
    case wouldNotCut(String, Writers)
    /// The server was asked for a hashtag's timeline and has no such thing (#104). Distinct
    /// from a tag nobody has used, which is an empty answer rather than a refusal.
    case noTagTimeline(String)
    /// The server was asked to search and has no such thing (#106). Distinct from a search that
    /// matched nothing, which is an empty answer rather than a refusal.
    case cannotSearch(String)
    /// The server answered outside 2xx; the body rides along for whoever can read a
    /// reason out of it.
    case http(Int, Data)
    case transport(String)
    /// The posts arrived and are on the screen, but the local store would not keep them.
    case store(String)
    /// More pictures than that server takes, and how many it does. Refused before the first of
    /// them goes up: a reader who has waited for three photographs to upload and is then told
    /// the server takes two has spent their connection on being refused.
    case tooManyPictures(String, Int)
    /// A picture bigger than that server takes, named, with the limit in bytes. Same reason.
    case pictureTooLarge(String, String, Int)
    /// A kind of file that server does not take, named, with what it does take.
    case pictureNotTaken(String, String, [String])
    /// A draft with nothing in it. Refused here rather than sent for a server to refuse:
    /// whitespace is not a post, and the round trip would only be a slower way of saying so.
    case emptyDraft
    /// Longer than that server will take, and known before a word of it was sent. The number is
    /// the server's own — this app has none of its own to offer.
    case tooLong(String, Int)

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
        case .badHost, .notThatKind, .unsupported, .needsSignIn, .signInFailed, .notItsPost,
             .http, .transport, .emptyDraft, .tooLong, .wouldNotCut, .noTagTimeline, .cannotSearch,
             .tooManyPictures, .pictureTooLarge, .pictureNotTaken: false
        }
    }

    /// Whatever went wrong, as one of these: a `SourceFailure` is already the answer, and
    /// anything else — a URLSession error, a decoding failure — is the connection not working,
    /// which is what `.transport` is. Every read funnels through here so that what counts as
    /// silence, and therefore what a backoff is decided on, is settled in one place.
    public static func of(_ error: any Error) -> SourceFailure {
        error as? SourceFailure ?? .transport(error.localizedDescription)
    }

    /// The last resort, for anywhere that is not a screen. Screens localise the case instead.
    public var errorDescription: String? {
        switch self {
        case .wouldNotCut(let host, let writers):
            "\(host) answered with its whole public timeline rather than \(writers.rawValue)."
        case .noTagTimeline(let host): "\(host) has no timeline for a hashtag."
        case .cannotSearch(let host): "\(host) cannot be searched."
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
        case .emptyDraft: "There is nothing written to send."
        case .tooLong(let host, let limit): "\(host) takes \(limit) characters, and this is longer."
        case .tooManyPictures(let host, let most): "\(host) takes \(most) pictures on a post."
        case .pictureTooLarge(let host, let name, let limit):
            "\(name) is larger than the \(limit) bytes \(host) takes."
        case .pictureNotTaken(let host, let name, let kinds):
            "\(host) does not take \(name)'s kind of file. It takes: \(kinds.joined(separator: ", "))."
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
    /// `after` is the other end of a stretch — everything newer than that post as well as older
    /// than `before`. Both together are how a reader's timeline asks about a stretch it already
    /// holds, which is what #92 says it could not: refreshing covers the top, paging walks away
    /// from it, and nothing returned to the middle.
    func timeline(host: String, limit: Int, before: Post?, after: Post?,
                  token: String?) async throws -> [Post]

    /// The same, cut to which writers the reader asked for (#113).
    ///
    /// Separate from the one above rather than a parameter on it, and that is not tidiness: a
    /// protocol that cannot cut must be able to *say so* instead of quietly answering the whole
    /// timeline, and the default below is where it says it. A reader who asked for one server's
    /// own writers and was handed the federated timeline has been told something false about
    /// which room they are in.
    func timeline(host: String, limit: Int, before: Post?, after: Post?,
                  writers: Writers, token: String?) async throws -> [Post]

    /// What the server shows the account signed in to it, paged like `timeline`.
    ///
    /// `token` is not optional, and that is the difference between this and the two beside
    /// it: there is no such thing as somebody's home timeline read as nobody. A server with
    /// no account on it is not asked at all, and is never quietly handed its public timeline
    /// instead — the same rule #4 set for a server that publishes no public timeline.
    func home(host: String, limit: Int, before: Post?, after: Post?,
              token: String) async throws -> [Post]

    /// Posts carrying a hashtag, asked for by it (#104).
    ///
    /// **Asked for, not sieved.** A tag rule over the public timeline shows the posts carrying
    /// that tag which the public timeline happened to hand over — on a busy server, almost none
    /// of them, and a reader is left thinking the tag is quiet.
    ///
    /// The tag arrives normalised the way the store keeps one: NFC, lowercased, no `#`. Paged
    /// like `timeline`, by the same cursor and for the same reason.
    func tag(_ tag: String, host: String, limit: Int, before: Post?, after: Post?,
             token: String?) async throws -> [Post]

    /// Posts a server has that match these words — `/api/v2/search?type=statuses` (#106).
    ///
    /// **The one read in this app that is a question about the reader.** Every other is a
    /// question about a timeline; this one sends what somebody typed to whoever runs the server.
    /// That is not a reason to refuse it, it is a reason it is never sent without being asked
    /// for — and the asking is the caller's, which is why nothing here checks.
    ///
    /// Asked of servers the reader has added and of nowhere else. A search is not a reason to go
    /// somewhere new.
    func search(_ words: String, host: String, limit: Int,
                token: String?) async throws -> [Post]

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

    // MARK: - Notices

    /// The events one server says were aimed at the account signed in to it.
    ///
    /// `token` is not optional, for `home`'s reason: there is no such thing as somebody
    /// else's inbox read as a stranger, and a server with no account on it is not asked at
    /// all rather than quietly handed something public instead.
    ///
    /// `after` is the newest event this device already knows about, in the server's own
    /// numbering, and what comes back is what happened since. `nil` asks for the newest page,
    /// which is what a device that has never read this inbox wants. It is the server's own id
    /// and not a `Notice`, unlike `timeline`'s cursor: an inbox is not a stretch of time
    /// anybody pages through, so there is no reader's place in it to name.
    ///
    /// `owner` is the actor URI of the account being read as. The client knows the token and
    /// not whose it is; the caller knows both, and a notice has to say which inbox it landed
    /// in — a reader signed in to three servers has three, and they are not one.
    func notices(host: String, owner: String, after: String?, limit: Int,
                 token: String) async throws -> [Notice]

    /// Who a part-typed handle could be, asked of the server a draft will be posted from (#98).
    ///
    /// A requirement and not only a default, because a default in an extension is dispatched
    /// where it is written rather than where it is called: a client that answered this would
    /// be walked straight past.
    func searchPeople(matching query: String, limit: Int,
                      as account: ActingAccount) async throws -> [Profile]

    /// What a part-typed hashtag could be, asked of the server a draft will be posted from
    /// (#108). A requirement and not only a default, for the reason above it.
    func searchTags(matching query: String, limit: Int,
                    as account: ActingAccount) async throws -> [String]

    /// The conversations this account is in (#109).
    ///
    /// Theirs and nobody else's, and not fanned out: a conversation belongs to one account on
    /// one server, and two servers' conversations are two conversations even where the same
    /// people are in both.
    func conversations(as account: ActingAccount) async throws -> [Talk]

    /// The posts this account has written and not sent yet (#110).
    ///
    /// Theirs and nobody else's: there is no reading of somebody else's unsent posts, and the
    /// account is what the question is asked as rather than about.
    func scheduled(as account: ActingAccount) async throws -> [ScheduledPost]

    /// Call one of them off. What can be done to a post that has not happened.
    func cancelScheduled(_ id: String, as account: ActingAccount) async throws

    /// What somebody asked you to read first — the posts they pinned (#112).
    ///
    /// A separate ask from what they wrote, and the answer is small: a handful at most, usually
    /// none. It is the one place on the fediverse where somebody says *start here*.
    ///
    /// Not paged. Pinned posts are a set somebody chose, not a stretch of time, and there is no
    /// second page of them to walk to.
    func pinned(by id: String, host: String, token: String?) async throws -> [Post]

    /// The same events as they happen, over one connection held open for as long as the
    /// sequence is iterated.
    ///
    /// Not polling, which is the whole point of #9: nothing is asked for on a timer while the
    /// app is in front. The sequence ends when the connection does, and what to do about that
    /// — wait, back off, try again — belongs to the caller rather than here, so that a client
    /// stays a way of speaking to one server and never becomes a policy about them.
    func noticeStream(host: String, owner: String, token: String) -> AsyncThrowingStream<Notice, any Error>

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
    func setMark(_ action: PostAction, on id: String, as account: ActingAccount,
                 done: Bool) async throws -> Marked

    /// Sends a draft, and hands back the post the server made of it.
    func publish(_ draft: Draft, as account: ActingAccount) async throws -> Post

    /// Mute an author or a whole host on the acting server, or take the mute down.
    func setMute(_ kind: Mute.Kind, _ value: String, as account: ActingAccount, muted: Bool) async throws

    /// Report a post to the acting server. There is no local half of this: a report that goes
    /// nowhere is not a report.
    func report(_ post: Post, id: String, as account: ActingAccount, comment: String) async throws

    /// Somebody as one server holds them, or nothing where it has never heard of them.
    ///
    /// Asked of a server that already handed one of their posts over, never of their own: that
    /// is a server the reader added, and opening a person is not a reason to introduce their
    /// home server to a new visitor (#88).
    ///
    /// Nothing is thrown where the server does not know them. That is an answer — it is what the
    /// reader's own server says about every stranger — and a page shows it rather than an error.
    func profile(handle: String, host: String, token: String?) async throws -> Profile?

    /// What one person has written, as one server holds it, paged the way every other stretch
    /// of posts is paged.
    func posts(by id: String, host: String, limit: Int, before: Post?, token: String?) async throws -> [Post]

    /// Who somebody follows, or who follows them, one page at a time (#90).
    ///
    /// Asked of the same server the profile was, and of no other. A hidden list and an empty one
    /// come back the same — see `People.reason(forEmpty:on:)`, which is where the two are told
    /// apart and the only place they are.
    func people(_ kind: People.Kind, of id: String, host: String, limit: Int,
                before: Profile?, token: String?) async throws -> [Profile]

    /// What the reader is to somebody, asked of the reader's own server, which is the only place
    /// a relationship exists. Nothing where that server has never heard of them — which is not
    /// the same fact as "you do not follow them", and is not to be drawn as though it were.
    func relationship(with handle: String, as account: ActingAccount) async throws -> Relationship?

    /// Follow somebody, or stop, and hand back the relationship as it now stands.
    ///
    /// The answer is read off the server rather than assumed from what was asked: a locked
    /// account answers `requested` and not `following`, and claiming the second would be this
    /// app announcing an approval nobody has given.
    func setFollow(_ following: Bool, with handle: String, as account: ActingAccount) async throws -> Relationship
}

/// What a client that cannot cut the public timeline does about it.
public extension SourceClient {
    /// Refuse, rather than answer the whole thing.
    ///
    /// A reader who asked for one server's own writers and was handed the federated timeline
    /// has been told something false about which room they are in — so the honest answer for a
    /// protocol with no word for the cut is that it has none (#113). `everyone` is not a cut and
    /// falls through to the ordinary reading, which is why every client already satisfies this.
    func timeline(host: String, limit: Int, before: Post?, after: Post?,
                  writers: Writers, token: String?) async throws -> [Post] {
        guard writers != .everyone else {
            return try await timeline(host: host, limit: limit, before: before, after: after,
                                      token: token)
        }
        throw SourceFailure.wouldNotCut(host, writers)
    }

    /// A protocol with no hashtag timeline says so rather than answering nothing.
    ///
    /// Empty would be indistinguishable from a tag nobody has used, and the two are different
    /// answers a reader is shown different things for — the same reason a server that publishes
    /// no public timeline is never quietly handed something else (#4).
    func tag(_ tag: String, host: String, limit: Int, before: Post?, after: Post?,
             token: String?) async throws -> [Post] {
        throw SourceFailure.noTagTimeline(host)
    }

    /// A protocol with no search says so rather than answering nothing, for the reason above it:
    /// empty is what "nobody wrote that" looks like, and the two are different answers.
    func search(_ words: String, host: String, limit: Int,
                token: String?) async throws -> [Post] {
        throw SourceFailure.cannotSearch(host)
    }
}


/// What a server says about itself, to somebody who has not joined it. Everything here came
/// from that server and nowhere else, which is what makes it safe to show before a reader has
/// decided anything.
public struct InstanceInfo: Sendable, Hashable {
    public let host: String
    public let title: String
    public let summary: String
    /// The picture the server puts on its own front page.
    public let thumbnailURL: URL?
    /// The languages it says it is in, spelled the way it spells them.
    public let languages: [String]
    /// How many people posted from here in the last month. A month is the shortest window
    /// Mastodon publishes -- there is no daily figure to ask for.
    public let activeMonthlyUsers: Int?
    /// Everybody registered, which is a different question and is all the older API answers.
    public let totalUsers: Int?
    public let posts: Int?
    /// What the server is running, as it names itself.
    public let version: String?
    /// Whether it is taking new accounts. Nil where it did not say.
    public let registrationsOpen: Bool?
    /// Its house rules, in the order it lists them.
    public let rules: [InstanceRule]
    /// How long a post may be here, as the server says. `nil` where it did not — an older
    /// server, or one that keeps it somewhere this build does not read — and `nil` is never
    /// drawn as a limit of zero or replaced by a number of ours. A composer that does not know
    /// says nothing rather than guessing at somebody else's rule.
    public let maxCharacters: Int?

    /// What this server will take a picture as, how big, and how many — its own rules, asked of
    /// it rather than written here (#89).
    ///
    /// Every one of them is optional and for the reason `maxCharacters` is: **a server that did
    /// not say has not said zero.** A composer that refused a picture because it had not been
    /// told a limit would be enforcing a rule nobody made, and one that invented a list of kinds
    /// would refuse a file the server would have taken.
    public let mediaKinds: [String]?
    public let mediaSizeLimit: Int?
    public let maxAttachments: Int?

    public init(
        host: String,
        title: String,
        summary: String,
        thumbnailURL: URL? = nil,
        languages: [String] = [],
        activeMonthlyUsers: Int? = nil,
        totalUsers: Int? = nil,
        posts: Int? = nil,
        version: String? = nil,
        registrationsOpen: Bool? = nil,
        rules: [InstanceRule] = [],
        maxCharacters: Int? = nil,
        mediaKinds: [String]? = nil,
        mediaSizeLimit: Int? = nil,
        maxAttachments: Int? = nil
    ) {
        self.mediaKinds = mediaKinds
        self.mediaSizeLimit = mediaSizeLimit
        self.maxAttachments = maxAttachments
        self.host = host
        self.title = title
        self.summary = summary
        self.thumbnailURL = thumbnailURL
        self.languages = languages
        self.activeMonthlyUsers = activeMonthlyUsers
        self.totalUsers = totalUsers
        self.posts = posts
        self.version = version
        self.registrationsOpen = registrationsOpen
        self.rules = rules
        self.maxCharacters = maxCharacters
    }
}

/// One of a server's house rules. The hint is the longer form some servers write underneath.
public struct InstanceRule: Sendable, Hashable {
    public let text: String
    public let detail: String?

    public init(text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
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

/// A post somebody has written and not yet sent.
///
/// What a composer holds, and what every network is handed. It is the words and who they are
/// for, and no more than that: a draft is the reader's, and a server's own ideas about it —
/// what it will take, how long it may be — are the server's to say when it is asked.
///
/// No attachments. #61 leaves them out on purpose rather than by omission: media is a second
/// API with an upload and a wait in it, and a composer that cannot attach a picture should say
/// so by not offering one, never by failing after the reader has chosen it.
public struct Draft: Sendable, Hashable {
    public let text: String
    /// Who it is for. The same four `Audience` a post arrives with, so what a reader chooses
    /// here and what a row shows there are one idea rather than two.
    public let audience: Audience
    /// The line to put in front of the words, or nothing. `""` and `nil` are one thing here —
    /// there is no such thing as a warning that says nothing.
    public let warning: String?
    /// The post this answers, where it answers one.
    ///
    /// The whole post and not its address, because everything the sending needs is on it: which
    /// server wrote it, that server's own number for it, and the audience this reply may not be
    /// wider than. A draft carrying only an id would have to be handed the post again at every
    /// step that asked one of those.
    ///
    /// **A reply goes to one account.** Every other draft may go to several — that is what "post
    /// once" is — but a reply is an answer to somebody in one conversation, and sending it from
    /// three accounts would be three people answering.
    public let answering: Post?
    /// The pictures going with it (#89), in the order they were put on.
    ///
    /// The bytes and not an id: a draft is a thing a reader is still writing, and a picture is
    /// part of it until it is sent. Uploading is what publishing does with them, so a draft that
    /// is never sent has cost nobody's server anything and a picture taken off before sending
    /// was never anywhere but here.
    public let pictures: [Picture]

    public init(text: String, audience: Audience = .everyone, warning: String? = nil,
                answering: Post? = nil, pictures: [Picture] = []) {
        self.pictures = pictures
        self.text = text
        self.warning = { let trimmed = ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                         return trimmed.isEmpty ? nil : trimmed }(warning)
        self.answering = answering
        // Never wider than what it answers. A reply to a post only the people mentioned in it
        // can read is not a post for everybody, whatever the composer was last set to — and a
        // reader who widened it by accident would have handed somebody's private words to a
        // timeline. Narrower is theirs to choose; wider is not.
        self.audience = answering.flatMap { Audience.narrower(of: audience, $0.audience) } ?? audience
    }

    /// Whether there is anything to send. Whitespace is not a post.
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether there is anything to send. A picture with no words is a post.
    public var carries: Bool { !isEmpty || !pictures.isEmpty }

    /// A picture on its way into a post, as the reader put it there.
    ///
    /// The description is beside the bytes and not optional-by-omission: **this app says out loud
    /// when a server sent a picture with no description**, so it would be a poor thing for it to
    /// send one. Empty is allowed — a reader may decline — and what is not allowed is the question
    /// never being asked.
    public struct Picture: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let bytes: Data
        /// What the file was called, which is what a server is told and what a reader recognises the
        /// row by while they are writing.
        public let filename: String
        public let mime: String
        /// What its author wrote for somebody who cannot see it.
        public var description: String

        public init(id: UUID = UUID(), bytes: Data, filename: String, mime: String,
                    description: String = "") {
            self.id = id
            self.bytes = bytes
            self.filename = filename
            self.mime = mime
            self.description = description
        }

        /// How many bytes it is, which is what a server's own size limit is measured against.
        public var size: Int { bytes.count }
    }

    /// What a server's limit is counted against. Written once so the number the composer counts
    /// down and the number the check compares cannot come to disagree — the warning counts,
    /// because Mastodon counts it.
    public var length: Int { text.count + (warning?.count ?? 0) }
}

/// What the server said about a post once it had done what it was asked.
///
/// A write's answer is a whole status, and two facts in it are ones nothing else here can
/// learn. The marks are what this account has now done to the post. The counts are the numbers
/// **with that counted in** — which is the only honest way this app's numbers move on a press.
/// Adding one to what the post arrived with would be inventing a number: never-told is not
/// "no", so a reader who had already favourited something on another client would be counted
/// twice by an app that guessed.
///
/// Reading them costs nothing. The request was made anyway; this is its answer, kept instead
/// of thrown away.
public struct Marked: Sendable, Hashable {
    public let marks: PostMarks
    /// What the server said the numbers are now, or nothing where it said nothing.
    public let counts: Counts?

    public init(marks: PostMarks = .unknown, counts: Counts? = nil) {
        self.marks = marks
        self.counts = counts
    }
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
    /// The events one server says were aimed at the account signed in to it. Default: this
    /// build cannot read an inbox over that protocol.
    func notices(host: String, owner: String, after: String?, limit: Int,
                 token: String) async throws -> [Notice] {
        throw SourceFailure.unsupported(.mastodon)
    }

    /// Who a part-typed handle could be (#98). Default: this build cannot ask that over this
    /// protocol, and an offer of nobody is what a composer draws when nobody can be asked.
    func searchPeople(matching query: String, limit: Int,
                      as account: ActingAccount) async throws -> [Profile] {
        throw SourceFailure.unsupported(.mastodon)
    }

    /// What a part-typed hashtag could be (#108). Default: this build cannot ask that over this
    /// protocol, and an offer of nothing is what a composer draws when nobody can be asked —
    /// which is the right answer here, because a tag nobody has used is still typeable.
    func searchTags(matching query: String, limit: Int,
                    as account: ActingAccount) async throws -> [String] {
        throw SourceFailure.unsupported(.mastodon)
    }

    /// Default: a protocol with no private conversations has none to list, and an empty answer
    /// is the true one rather than a refusal — unlike the unsent posts below, where nobody
    /// having looked and nothing being queued are different facts a reader is shown differently.
    func conversations(as account: ActingAccount) async throws -> [Talk] { [] }

    /// Default: a protocol that cannot be asked about one post says so rather than handing back
    /// the post it was given, which would look exactly like a server saying nothing had changed
    /// (#125).
    func status(of post: Post, host: String, token: String?) async throws -> Post {
        throw SourceFailure.unsupported(post.socialProtocol)
    }

    /// Default: a protocol that keeps no such list has none to hand over, and empty is the true
    /// answer — which the page tells apart from *hidden* the way #90's lists already do, by the
    /// count on the post disagreeing with it (#126).
    func people(_ which: People.AboutAPost, of post: Post, host: String,
                limit: Int, token: String?) async throws -> [Profile] { [] }

    /// Default: this build cannot ask that over this protocol, which is different from an
    /// account that has scheduled nothing — so it throws and the page leaves the part absent
    /// rather than saying the reader has nothing waiting (#110).
    func scheduled(as account: ActingAccount) async throws -> [ScheduledPost] {
        throw SourceFailure.unsupported(.mastodon)
    }

    func cancelScheduled(_ id: String, as account: ActingAccount) async throws {
        throw SourceFailure.unsupported(.mastodon)
    }

    /// What somebody pinned (#112). Default: nothing, and that is the same answer a server gives
    /// for somebody who pinned nothing — which is right here, because a protocol with no pinning
    /// has no *start here* to miss, and the page draws nothing either way.
    func pinned(by id: String, host: String, token: String?) async throws -> [Post] { [] }

    /// Those events as they happen. Default: a sequence that ends at once saying why, rather
    /// than one that stays open forever handing nothing over — a caller waiting on silence
    /// cannot tell "nothing has happened" from "this will never work".
    func noticeStream(host: String, owner: String, token: String) -> AsyncThrowingStream<Notice, any Error> {
        AsyncThrowingStream { $0.finish(throwing: SourceFailure.unsupported(.mastodon)) }
    }

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
                 done: Bool) async throws -> Marked {
        throw SourceFailure.unsupported(.mastodon)
    }

    /// Default: this build cannot read a person over that protocol. `nil` is reserved for the
    /// server that answered and does not know them, so a protocol with no client throws instead
    /// — a page saying "nobody here has heard of them" about a protocol this build cannot speak
    /// would be blaming the wrong thing.
    func profile(handle: String, host: String, token: String?) async throws -> Profile? {
        throw SourceFailure.unsupported(.mastodon)
    }

    func posts(by id: String, host: String, limit: Int, before: Post?,
               token: String?) async throws -> [Post] {
        throw SourceFailure.unsupported(.mastodon)
    }

    func relationship(with handle: String, as account: ActingAccount) async throws -> Relationship? {
        throw SourceFailure.unsupported(.mastodon)
    }

    func people(_ kind: People.Kind, of id: String, host: String, limit: Int,
                before: Profile?, token: String?) async throws -> [Profile] {
        throw SourceFailure.unsupported(.mastodon)
    }

    func setFollow(_ following: Bool, with handle: String,
                   as account: ActingAccount) async throws -> Relationship {
        throw SourceFailure.unsupported(.mastodon)
    }

    /// Sends a draft, and hands back the post the server made of it.
    ///
    /// The post and not a receipt, because what comes back is a post like any other and the
    /// reader's own timeline should have it without waiting for the next refresh. Default: this
    /// build cannot write over that protocol.
    func publish(_ draft: Draft, as account: ActingAccount) async throws -> Post {
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
