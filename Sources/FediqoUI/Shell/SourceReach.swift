import FediqoCore
import Foundation

/// The one place a source is reached from (#299): wherever the app speaks to a source, the
/// client it speaks through is built here, wired as that kind of ask is wired — which transport,
/// bounded by which deadline, listed under which purpose and name in the requests of this run,
/// and through whose sign-in.
///
/// **It gathers the wiring, and decides nothing.** A caller says what it is asking for and for
/// how long; whether somebody is signed in, and what follows from that, stays the caller's rule
/// to keep, as it was. What comes back is the same concrete client the caller built for itself
/// before — there is no one way of asking every source here (#289), only one place they are
/// all made.
///
/// **A value made where it is needed**, from what its holder already has: the plain client, the
/// run's list of requests, and the forums' sign-ins where there are any. It keeps nothing, so
/// it cannot go stale.
@MainActor
struct SourceReach {
    /// The plain client: no token, no cookie.
    let http: any HTTPClient
    /// Where each request is listed while it runs.
    let work: SourceWork
    /// The forums' sign-ins, where its holder has them.
    var forums: ForumSessions?

    // MARK: - The wire

    /// `base` — the plain client where none is given — listed as `purpose` under `name` while
    /// each request runs, and ended within `limit` where there is one. **The one way an
    /// unsigned ask is wired**; a signed one is wired the same way by the door it goes through
    /// (`MastodonSessions.authorized`).
    // `unsignedPerson` and `unsignedPeople` hand in a base with a small body ceiling (`small`); the other
    // unsigned readers go out on the plain client, which has no size ceiling but its last line.
    func wire(
        _ base: (any HTTPClient)? = nil, for purpose: SourceWork.Purpose, name: SourceWork.Name? = nil,
        within limit: Duration?
    ) -> any HTTPClient {
        let watched = WatchedHTTP(base ?? http, for: purpose, name: name, in: work) as any HTTPClient
        return limit.map { Deadline(watched, within: $0) } ?? watched
    }

    /// What a read of `host` goes through before it is listed or bounded: that forum's own
    /// browser where the reader is signed in to it, and the plain client for everything else.
    /// **Asked by the host being read, always** — a forum's sign-in goes to that forum.
    func base(for host: String) -> any HTTPClient {
        forums?.readTransport(host: host, else: http) ?? http
    }

    // MARK: - A Mastodon

    /// A Mastodon read with no token: its public timeline, what is rising, what it says of
    /// itself.
    func mastodon(
        _ host: String, for purpose: SourceWork.Purpose, name: SourceWork.Name? = nil, within limit: Duration?
    ) -> MastodonClient {
        MastodonClient(http: wire(for: purpose, name: name, within: limit), host: host)
    }

    /// A Mastodon read over a transport its caller was handed already wired: a join, a check
    /// of what a host speaks, its emoji.
    static func mastodon(_ host: String, over http: any HTTPClient) -> MastodonClient {
        MastodonClient(http: http, host: host)
    }

    /// What a signed-in reader reads as themselves — Home, their lists — through `door`, and
    /// landed in `store` by the account itself. `reading` gives each timeline a door of its own
    /// where its caller made them, so each is listed under its own name.
    func account(
        _ door: MastodonAuthorized, landingIn store: ItemStore,
        reading: (@Sendable (FediqoCore.Category) -> MastodonAuthorized)? = nil
    ) -> MastodonAccount {
        MastodonAccount(door: door, store: store, reading: reading)
    }

    /// One post and what is around it, as the reader, through `door`.
    func post(_ door: MastodonAuthorized) -> MastodonPost {
        MastodonPost(door: door)
    }

    /// One post and what is around it with no token, listed as `purpose` and ended within
    /// `limit`. **Only for a caller whose own rule says an unsigned read is right here.**
    func unsignedPost(_ host: String, for purpose: SourceWork.Purpose, within limit: Duration) -> MastodonPost {
        MastodonPost(http: wire(for: purpose, within: limit), host: host)
    }

    /// Somebody a source knows and their posts, as the reader, through `door`.
    func person(_ door: MastodonAuthorized) -> MastodonPerson {
        MastodonPerson(door: door)
    }

    /// Somebody a source knows and their posts with no token, listed as `purpose` and ended
    /// within `limit`.
    ///
    /// **Under the ceiling a signed-in read has**: a person and a stretch of their posts are
    /// small, and a stranger's server is not trusted to keep them so.
    func unsignedPerson(_ host: String, for purpose: SourceWork.Purpose, within limit: Duration) -> MastodonPerson {
        MastodonPerson(http: wire(small(), for: purpose, within: limit), host: host)
    }

    /// A list of people a source keeps, as the reader, through `door`.
    func people(_ door: MastodonAuthorized) -> MastodonPeople {
        MastodonPeople(door: door)
    }

    /// A list of people a source keeps with no token, listed as `purpose`, ended within
    /// `limit`, and under the ceiling a signed-in read has: a stretch of people is small.
    func unsignedPeople(_ host: String, for purpose: SourceWork.Purpose, within limit: Duration) -> MastodonPeople {
        MastodonPeople(http: wire(small(), for: purpose, within: limit), host: host)
    }

    /// How much body an ask known to be small may bring: what the signed-in door takes.
    static let smallBody = 1 << 20

    /// The plain client under `smallBody`. The live client is held to it as it transfers; any
    /// other — a test's — has what it brought refused past it.
    func small() -> any HTTPClient {
        Self.small(http)
    }

    /// `http` under `smallBody`: held to it as it transfers where it is the live client, and
    /// refused what it brought past it where it is any other — a test's.
    ///
    /// **Handed the plain client, before it is wired** (`wire(small(…), …)`): a client already
    /// listed or bounded is no longer the live one to look at, and capping it would let the
    /// whole body be transferred and held before it is refused.
    static func small(_ http: any HTTPClient) -> any HTTPClient {
        (http as? URLSessionClient)?.capped(to: Self.smallBody) ?? SmallBody(http, limit: Self.smallBody)
    }

    /// `http` under `smallBody` and kept to the host it is asked at: `small`, and every redirect
    /// off that origin refused — for an ask that is of one source and of nowhere it points to.
    /// A test's client, which follows nothing, is `small` and no more.
    static func smallAtItsHost(_ http: any HTTPClient) -> any HTTPClient {
        atItsHost(http, under: Self.smallBody)
    }

    /// `http` taking no body over `limit` and kept to the host it is asked at.
    static func atItsHost(_ http: any HTTPClient, under limit: Int) -> any HTTPClient {
        (http as? URLSessionClient)?.capped(to: limit).stayingOnOrigin() ?? SmallBody(http, limit: limit)
    }

    /// How much body the list of servers a host knows may bring: a large host names tens of
    /// thousands, which is past what a small ask may bring and still a list of names.
    static let serversBody = 8 << 20

    /// The servers a host knows (#321), with no token, asked at their line's press: as
    /// `unsignedHost`, under `serversBody` — held to it as the body arrives, on the plain
    /// client before it is listed and bounded — and of that host alone.
    func unsignedHostServers(_ host: String, for purpose: SourceWork.Purpose, within limit: Duration) -> MastodonHostMore {
        MastodonHostMore(http: wire(Self.atItsHost(http, under: Self.serversBody), for: purpose, within: limit), host: host)
    }

    /// What a host says of itself beyond its document (#321) — its longer account, the servers
    /// it knows, how busy it has been — with no token: anyone is given them. Listed as
    /// `purpose`, ended within `limit`, under the small body's ceiling, and of that host alone.
    func unsignedHost(_ host: String, for purpose: SourceWork.Purpose, within limit: Duration) -> MastodonHostMore {
        MastodonHostMore(http: wire(Self.smallAtItsHost(http), for: purpose, within: limit), host: host)
    }

    /// The hashtags and the links rising on a host (#320), with no token: anyone is given
    /// them. Listed as `purpose`, ended within `limit`, under the small body's ceiling, and of
    /// that host alone.
    func unsignedRising(_ host: String, for purpose: SourceWork.Purpose, within limit: Duration) -> MastodonRising {
        MastodonRising(http: wire(Self.smallAtItsHost(http), for: purpose, within: limit), host: host)
    }

    /// What is under a tag, as the reader, through `door`.
    func tag(_ door: MastodonAuthorized) -> MastodonTag {
        MastodonTag(door: door)
    }

    /// What is under a tag with no token.
    func unsignedTag(
        _ host: String, name: SourceWork.Name?, within limit: Duration
    ) -> MastodonTag {
        MastodonTag(http: wire(for: .timeline, name: name, within: limit), host: host)
    }

    /// A search, which a Mastodon answers only to somebody signed in.
    func search(_ door: MastodonAuthorized) -> MastodonSearch {
        MastodonSearch(door: door)
    }

    /// What happened to the reader (#323), which is only ever asked as them.
    func notices(_ door: MastodonAuthorized) -> MastodonNotices {
        MastodonNotices(door: door)
    }

    /// An act, a post or a taking back, through `door`; its answer lands in `store`.
    func write(_ door: MastodonAuthorized, landingIn store: ItemStore) -> MastodonWrite {
        MastodonWrite(door: door, store: store)
    }

    // MARK: - A forum

    /// A Discuz! read, through that forum's own browser where the reader is signed in to it.
    func discuz(
        _ host: String, for purpose: SourceWork.Purpose, name: SourceWork.Name? = nil, within limit: Duration?
    ) -> DiscuzClient {
        DiscuzClient(http: wire(base(for: host), for: purpose, name: name, within: limit), host: host)
    }

    /// A Discuz! read over a transport its caller chose already (`base(for:)`), for a caller
    /// that makes several reads of one forum and means them all to go the one way: a reload,
    /// whose boards and ranking lists are read through the transport it began with.
    func discuz(
        _ host: String, over base: any HTTPClient, for purpose: SourceWork.Purpose, name: SourceWork.Name? = nil,
        within limit: Duration?
    ) -> DiscuzClient {
        DiscuzClient(http: wire(base, for: purpose, name: name, within: limit), host: host)
    }

    /// A Discourse read, through the same door a forum's is.
    func discourse(
        _ host: String, for purpose: SourceWork.Purpose, name: SourceWork.Name? = nil, within limit: Duration?
    ) -> DiscourseClient {
        DiscourseClient(http: wire(base(for: host), for: purpose, name: name, within: limit), host: host)
    }
}

extension ShellSession {
    /// Where this session reaches its sources from. See `SourceReach`.
    var reach: SourceReach {
        SourceReach(http: http, work: work, forums: forums)
    }
}

/// A client whose answers are refused past `limit` bytes, as `URLSessionClient` refuses its own.
private struct SmallBody: HTTPClient {
    private let inner: any HTTPClient
    private let limit: Int

    init(_ inner: any HTTPClient, limit: Int) {
        self.inner = inner
        self.limit = limit
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        let answer = try await inner.data(from: url)
        guard answer.0.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return answer
    }
}
