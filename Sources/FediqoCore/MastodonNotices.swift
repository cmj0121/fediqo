import Foundation

/// A Mastodon read this device could not make a page of notices from.
public enum MastodonNoticeError: Error, Equatable, Sendable {
    /// The server answered, and not with notices: a body that is not the shape either read has.
    case unreadable
    /// The notice or the held-back request is another source's than the one signed in to here.
    /// Two sources number theirs from one, so asked of this one it would name a different
    /// notice, of somebody else's: nothing is asked.
    case elsewhere
}

/// A Mastodon asked what happened to its signed-in reader (#323): `/api/v2/notifications`, where
/// the source gathers, and `/api/v1/notifications`, where it does not.
///
/// **Signed in, or not at all.** A notice is only ever the reader's own, so there is no unsigned
/// door here, as there is none on `MastodonSearch`.
///
/// **Nothing here writes anywhere on this device.** A read lands in what it returns and nowhere
/// else, and an act — dismissing, letting a held-back request through or go — changes the
/// source alone, so one that is refused or fails has nothing to undo: what the door throws is
/// thrown — `MastodonAuthError.signedOut`, `.http(403)` from a token that was never asked for
/// notices or may not act on them, any other `.http` — and a body that is not what was asked
/// for is `MastodonNoticeError.unreadable`. Whoever holds the list takes a line out of it once
/// an act returns, and not before.
public struct MastodonNotices: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let gatheredPath = "/api/v2/notifications"
    static let singlePath = "/api/v1/notifications"

    /// The newest stretch of notices, or with `before` the stretch older than that id — the
    /// `before` the page above handed back. How long a stretch is is left to the server.
    ///
    /// **Whether a source gathers is its own answer, and is asked for by asking.** With
    /// `gathered` nil the gathered read is tried, and where the source says it has none (404)
    /// the single read is made instead; the page says which answered, so whoever reads on hands
    /// that back and one source is read one way for the run. `true` or `false` asks that read
    /// alone. Only a 404 falls back: a refusal or a failure of the gathered read would be the
    /// same refusal or failure of the other, asked twice.
    public func page(source: Source, before: String? = nil, gathered: Bool? = nil) async throws -> NoticePage {
        let sent = ReadMoment.now()
        let query = try MastodonPage.older(than: before)
        if gathered != false {
            do {
                let data = try await door.get(path: Self.gatheredPath, query: query)
                guard let read = try? MastodonJSON.decoder.decode(GatheredDTO.self, from: data) else {
                    throw MastodonNoticeError.unreadable
                }
                return try Self.page(read.notificationGroups, gathered: true, sent: sent, read.reader(source: source, sent: sent))
            } catch MastodonAuthError.http(404) where gathered == nil {
                // No gathered read on this source: it is asked one notice at a time.
            }
        }
        let data = try await door.get(path: Self.singlePath, query: query)
        guard let read = try? MastodonJSON.decoder.decode([Entry<SingleDTO>].self, from: data) else {
            throw MastodonNoticeError.unreadable
        }
        return try Self.page(read, gathered: false, sent: sent) { $0.asNotice(source: source, sent: sent) }
    }

    /// **The next stretch is asked before the lowest id this one named**, for both reads; the
    /// server's own `Link` header says the same and is not read.
    ///
    /// **Named by the source, whether or not the entry that named it could be read.** Only a
    /// stretch with nothing in it is the end: one whose every entry this build cannot read
    /// still says where it stopped, so reading on goes past it rather than stopping there for
    /// good. One that has entries and names no id anywhere is no page of notices at all.
    private static func page<Body>(
        _ entries: [Entry<Body>], gathered: Bool, sent: ReadMoment, _ notice: (Body) -> Notice?
    ) throws -> NoticePage {
        let lowest = entries.compactMap(\.lowest).min { StatusID.later($1, than: $0) }
        guard lowest != nil || entries.isEmpty else { throw MastodonNoticeError.unreadable }
        return NoticePage(
            notices: entries.compactMap { $0.value.flatMap(notice) }, gathered: gathered, before: lowest, sent: sent
        )
    }

    // MARK: - Dismissing

    static let clearPath = "/api/v1/notifications/clear"

    /// Dismisses one line at its source, by the name the read that brought it gave it: a single
    /// notice by its id, a gathered line by its key — every notice the line stands for at once.
    ///
    /// **A single notice's 404 is the notice already gone** — dismissed elsewhere, or a moment
    /// ago — which is what the person asked for, so it returns as a dismissal does. A refusal
    /// (`.http(403)` from a sign-in that may not act) or a failure is thrown, and the line stands.
    ///
    /// **A gathered line's 404 is thrown.** A source answers a gathered line it never had
    /// exactly as one it dismissed, so returning proves the line is gone, not that it was
    /// there — and a 404 there is no line gone but the request itself not known.
    ///
    /// **But for one asked again after an ask that was not confirmed in time**
    /// (`afterUnconfirmed`): the source was sent this dismissal once already and nobody heard
    /// its answer, so a 404 now is that dismissal having landed, and it returns as one does.
    ///
    /// **Only at the notice's own source**: one that is another's is `elsewhere`, unasked.
    public func dismiss(_ notice: Notice, afterUnconfirmed: Bool = false) async throws {
        guard notice.source.host == door.token.host else { throw MastodonNoticeError.elsewhere }
        switch notice.handle {
        case .one(let id):
            guard ListSubscription.isPathSegment(id) else { throw MastodonRequestError.invalidURL }
            do {
                _ = try await door.post(path: "\(Self.singlePath)/\(id)/dismiss", form: [])
            } catch MastodonAuthError.http(404) {}
        case .gathered(let key):
            guard Self.isGroupKey(key) else { throw MastodonRequestError.invalidURL }
            do {
                _ = try await door.post(path: "\(Self.gatheredPath)/\(key)/dismiss", form: [])
            } catch MastodonAuthError.http(404) where afterUnconfirmed {}
        }
    }

    /// Dismisses every notice this source has for the person — **shown or not**: the ones not
    /// read on to yet, and the ones narrowed away, go with the rest. One request.
    public func dismissAll() async throws {
        _ = try await door.post(path: Self.clearPath, form: [])
    }

    /// Whether `key` can stand in a signed-in path as one segment. A source's key is its kind,
    /// a post's id and a stretch of hours — `favourite-117402373970258685-497616`,
    /// `ungrouped-11`, a kind with a dot or an underscore in it — and anything else is not
    /// trusted with the path.
    static func isGroupKey(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    // MARK: - What the source holds back

    static let policyPath = "/api/v2/notifications/policy"
    static let requestsPath = "/api/v1/notifications/requests"

    /// Whether this source is holding notices back, and how many: its policy's own summary.
    /// The policy is only read; nothing here changes what a source holds back.
    ///
    /// **A source with no such thing (404) is `absent`, and is asked nothing more.** Handed
    /// that answer back as `known`, this asks nobody and says `absent` again. Any other answer
    /// is asked afresh, since what a source holds changes while it runs. Only a 404 says so: a
    /// refusal or a failure is thrown, and what was known stands.
    public func held(known: NoticeHolding = .unasked) async throws -> NoticeHolding {
        if known == .absent { return .absent }
        let data: Data
        do {
            data = try await door.get(path: Self.policyPath)
        } catch MastodonAuthError.http(404) {
            return .absent
        }
        guard let policy = try? MastodonJSON.decoder.decode(PolicyDTO.self, from: data) else {
            throw MastodonNoticeError.unreadable
        }
        guard let held = policy.summary.asHeld else { throw MastodonNoticeError.unreadable }
        return .holds(held)
    }

    /// The requests this source is holding: one for each person whose notices it kept out of
    /// the list. Asked only where `held` says there are some.
    ///
    /// **One stretch of them, as long as the source makes it**: this does not read on, so
    /// `held` may count more requests than are returned here.
    public func requests(source: Source) async throws -> [NoticeRequest] {
        let sent = ReadMoment.now()
        let data = try await door.get(path: Self.requestsPath)
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<RequestDTO>].self, from: data) else {
            throw MastodonNoticeError.unreadable
        }
        return read.compactMap { $0.value?.asRequest(source: source, sent: sent) }
    }

    /// Lets a held-back request through: that person's notices join the ordinary list.
    ///
    /// **Not with this answer.** The source says yes and moves them afterwards, in its own
    /// time, so returning means the request is gone and the notices are on their way — a later
    /// read brings them, and nothing here waits for it.
    public func letThrough(_ request: NoticeRequest) async throws {
        try await answer(request, "accept")
    }

    /// Lets a held-back request go: that person's held notices are dismissed with it.
    public func letGo(_ request: NoticeRequest) async throws {
        try await answer(request, "dismiss")
    }

    private func answer(_ request: NoticeRequest, _ act: String) async throws {
        guard request.source.host == door.token.host else { throw MastodonNoticeError.elsewhere }
        guard ListSubscription.isPathSegment(request.requestID) else { throw MastodonRequestError.invalidURL }
        _ = try await door.post(path: "\(Self.requestsPath)/\(request.requestID)/\(act)", form: [])
    }
}

/// `/api/v2/notifications/policy`, in the one part of it read: how much is waiting. The counts
/// are read from a number or a string. One that is neither is none beside one that can be
/// read; with neither readable the answer says nothing of what is held, which is not "nothing".
private struct PolicyDTO: Decodable, Sendable {
    let summary: Summary

    struct Summary: Decodable, Sendable {
        let pendingRequestsCount: StatusDTO.Lenient<WireNumber>?
        let pendingNotificationsCount: StatusDTO.Lenient<WireNumber>?

        var asHeld: NoticesHeld? {
            let requests = pendingRequestsCount?.value?.count.map { max(0, $0) }
            let notices = pendingNotificationsCount?.value?.count.map { max(0, $0) }
            guard requests != nil || notices != nil else { return nil }
            return NoticesHeld(requests: requests ?? 0, notices: notices ?? 0)
        }
    }
}

/// One entry of `/api/v1/notifications/requests`. Its `notifications_count` is a **string**
/// where a line's is a number.
private struct RequestDTO: Decodable, Sendable {
    let id: WireNumber
    let account: PersonDTO
    let notificationsCount: StatusDTO.Lenient<WireNumber>?
    let updatedAt: StatusDTO.LenientMoment?
    let createdAt: StatusDTO.LenientMoment?
    let lastStatus: StatusDTO.Lenient<StatusDTO>?

    /// Placed as a notice is: at its own moment — when it last grew, else when it was made —
    /// at its post's where it names neither, and nothing where there is no moment anywhere.
    func asRequest(source: Source, sent: ReadMoment) -> NoticeRequest? {
        let post = lastStatus?.value?.asNote(source: source, categories: [], sent: sent)
        guard let at = updatedAt?.value ?? createdAt?.value ?? post?.postedAt else { return nil }
        return NoticeRequest(
            requestID: id.text, source: source, person: account.asPerson(host: source.host),
            count: max(1, notificationsCount?.value?.count ?? 1), lastPost: post, at: at
        )
    }
}

/// One entry of either read: what could be made of it, and the lowest notice id it names —
/// read apart, so an entry this build cannot read still says how far down the page it reached.
private struct Entry<Body: Decodable & Sendable>: Decodable, Sendable {
    let value: Body?
    let lowest: String?

    private enum Named: String, CodingKey, CaseIterable {
        case pageMinId, mostRecentNotificationId, id
    }

    init(from decoder: any Decoder) throws {
        value = try? Body(from: decoder)
        let named = try? decoder.container(keyedBy: Named.self)
        lowest = Named.allCases.lazy.compactMap { (try? named?.decode(WireNumber.self, forKey: $0))?.text }.first
    }
}

/// An id or a count as a Mastodon sends it: a string in one field and a number in the next, for
/// the same kind of thing — `most_recent_notification_id` is a number beside `page_min_id`, a
/// string. Read from either, and kept as the text.
private struct WireNumber: Decodable, Sendable {
    let text: String

    /// The text as a count, or nothing where it is not a number.
    var count: Int? { Int(text) }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard !text.isEmpty else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "an empty id")
            }
            self.text = text
        } else {
            text = String(try container.decode(Int64.self))
        }
    }
}

/// Somebody as either read names them: `StatusDTO.Account`, which is how a post's author is
/// read, and the id the gathered read joins them by.
private struct PersonDTO: Decodable, Sendable {
    let id: WireNumber
    let account: StatusDTO.Account

    private enum CodingKeys: String, CodingKey { case id }

    init(from decoder: any Decoder) throws {
        id = try decoder.container(keyedBy: CodingKeys.self).decode(WireNumber.self, forKey: .id)
        account = try StatusDTO.Account(from: decoder)
    }

    func asPerson(host: String) -> NoticePerson {
        NoticePerson(
            handle: StatusDTO.handle(account.acct, host: host), name: account.name,
            avatarURL: Host.fetchableURL(account.avatar),
            emojis: CustomEmoji.folded((account.emojis ?? []).compactMap(\.asEmoji))
        )
    }
}

/// `/api/v2/notifications`: the lines, with the people and the posts they name **beside** them,
/// joined by id.
///
/// **Read entry by entry, and field by field**: a line, a person or a post this build cannot
/// read is that one entry not read, and never the page; a count, a page id, a post's id or one
/// of the people's ids that is not what it should be is that one thing not known, and never
/// the line. A person or a post a line names and the side lists do not hold is simply absent
/// from it.
///
/// **A line is skipped only where there is nothing to call it or place it by**: no key, no
/// type or no id — or no moment anywhere, which is a line that names no latest notice *and* is
/// about no post that says when it was written. One with a post and no moment of its own
/// stands at its post's, the one other time the answer holds: late in the list rather than
/// left out of it.
private struct GatheredDTO: Decodable, Sendable {
    let accounts: [StatusDTO.Lenient<PersonDTO>]?
    let statuses: [StatusDTO.Lenient<StatusDTO>]?
    let notificationGroups: [Entry<Line>]

    struct Line: Decodable, Sendable {
        let groupKey: String
        let type: String
        let notificationsCount: StatusDTO.Lenient<WireNumber>?
        let mostRecentNotificationId: WireNumber
        let pageMinId: StatusDTO.Lenient<WireNumber>?
        /// A gathered line has no `created_at`: this is its moment.
        let latestPageNotificationAt: StatusDTO.LenientMoment?
        let sampleAccountIds: StatusDTO.Lenient<[StatusDTO.Lenient<WireNumber>]>?
        let statusId: StatusDTO.Lenient<WireNumber>?
    }

    /// What makes a notice of one of this answer's lines, with the side lists joined once.
    func reader(source: Source, sent: ReadMoment) -> (Line) -> Notice? {
        let host = source.host
        let people = Dictionary(
            (accounts ?? []).compactMap(\.value).map { ($0.id.text, $0.asPerson(host: host)) },
            uniquingKeysWith: { first, _ in first }
        )
        let posts = Dictionary(
            (statuses ?? []).compactMap(\.value).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return { line in
            let newest = line.mostRecentNotificationId.text
            let post = (line.statusId?.value).flatMap { posts[$0.text] }?
                .asNote(source: source, categories: [], sent: sent)
            guard let at = line.latestPageNotificationAt?.value ?? post?.postedAt else { return nil }
            return Notice(
                source: source, handle: .gathered(key: line.groupKey), kind: Notice.Kind(type: line.type),
                people: (line.sampleAccountIds?.value ?? []).compactMap { ($0.value?.text).flatMap { people[$0] } },
                count: max(1, line.notificationsCount?.value?.count ?? 1),
                post: post, at: at, newestID: newest, oldestID: line.pageMinId?.value?.text ?? newest
            )
        }
    }
}

/// One entry of `/api/v1/notifications`: the person and the post **inside** it. It carries a
/// `group_key` too, which is not read — nothing is gathered on this device.
private struct SingleDTO: Decodable, Sendable {
    let id: WireNumber
    let type: String
    let createdAt: StatusDTO.LenientMoment?
    let account: StatusDTO.Lenient<PersonDTO>?
    let status: StatusDTO.Lenient<StatusDTO>?

    /// A line of one: one person, a count of one, named by its own id. Placed as a gathered
    /// line is: at its own moment, at its post's where it has none, and nothing where it has
    /// neither.
    func asNotice(source: Source, sent: ReadMoment) -> Notice? {
        let post = status?.value?.asNote(source: source, categories: [], sent: sent)
        guard let at = createdAt?.value ?? post?.postedAt else { return nil }
        return Notice(
            source: source, handle: .one(id: id.text), kind: Notice.Kind(type: type),
            people: (account?.value).map { [$0.asPerson(host: source.host)] } ?? [],
            post: post, at: at, newestID: id.text, oldestID: id.text
        )
    }
}
