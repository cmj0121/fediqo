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
