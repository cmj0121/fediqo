import Foundation

// A post sent later (#333, Decision 2): given a time, held by its source until then and
// published by the source's own worker — and what waits so, read, moved, changed and let go.
// Each as Mastodon 4.6.6 answered it (`MastodonLaterCaptures`).
//
// **Nothing waiting is held on this device.** A waiting post is its source's; what is asked here
// is read and handed back, and the store is never written — but for a post the source published
// at once instead, which is a post like any other, and which is said as a failure (`sentNow`).

/// A post its source holds to send at a time (`ScheduledStatus`): what it will say, and when.
public struct WaitingPost: Equatable, Sendable, Identifiable {
    /// Its id among the waiting posts at its source: not a post's id, which it has none of yet.
    public let id: String
    /// When its source will send it.
    public let at: Date
    public let text: String
    /// The cover line; empty where there is none.
    public let spoiler: String
    public let sensitive: Bool
    public let language: String?
    /// Who may read it, where the source said in a word this build knows.
    public let audience: Audience?
    /// The post it answers, by its source's id, where it answers one.
    public let answering: String?
    /// The files it carries, each by its id with its description.
    public let media: [PostSource.Media]
    public let poll: NewPoll?
    /// The post it quotes, by its source's id, where it quotes one (#330): what its change keeps.
    public let quoting: String?
    /// Who may quote it once it is up, as its source keeps it.
    public let quotePolicy: QuotePolicy?

    public init(
        id: String, at: Date, text: String, spoiler: String = "", sensitive: Bool = false, language: String? = nil,
        audience: Audience? = nil, answering: String? = nil, media: [PostSource.Media] = [], poll: NewPoll? = nil,
        quoting: String? = nil, quotePolicy: QuotePolicy? = nil
    ) {
        self.id = id
        self.at = at
        self.text = text
        self.spoiler = spoiler
        self.sensitive = sensitive
        self.language = language
        self.audience = audience
        self.answering = answering
        self.media = media
        self.poll = poll
        self.quoting = quoting
        self.quotePolicy = quotePolicy
    }
}

/// One stretch of the waiting posts, newest made first as the source lists them, and the id the
/// next is read on from — nothing at the end.
public struct WaitingStretch: Equatable, Sendable {
    public let posts: [WaitingPost]
    public let next: String?
}

/// A waiting post changed (Decision 2): the new one is made first, and the old one let go after —
/// **only once the new one is known to wait**. `new` is nothing where its making could not be
/// confirmed and it was not found among what waits: it may have been made, or not. `oldStays`
/// where the old one was not let go — both may wait, and both would be sent.
///
/// **A file the old one carried is the new one's from the moment the new one is made** (asked of
/// 4.6.6): the source moves it, so an old one left waiting beside it waits without its files.
public struct WaitingChange: Equatable, Sendable {
    public let new: WaitingPost?
    public let old: WaitingPost
    public let oldStays: Bool
    /// Whether the old one, still waiting, has lost its files to the new one: the new one was
    /// made — or may have been — with any of them, and the old was not let go.
    public let oldLostMedia: Bool

    public init(new: WaitingPost?, old: WaitingPost, oldStays: Bool, oldLostMedia: Bool = false) {
        self.new = new
        self.old = old
        self.oldStays = oldStays
        self.oldLostMedia = oldStays && oldLostMedia
    }
}

public enum MastodonLaterError: Error, Equatable, Sendable {
    /// The time is nearer than the source takes by its own clock: refused here, before anything
    /// was asked, with the first moment it would take (`MastodonLater.earliest`).
    case tooSoon(earliest: Date)
    /// Given a time, and published at once instead — the source's clock had passed it. **Not a
    /// success**: the person asked for later, and is told it went now. The post is held as any
    /// post written is.
    case sentNow(Note)
    /// Asked again under a key already used, and answered "no such record": the first ask may
    /// have made it, or not. **Not "not made"** — whoever asked looks among what waits, and
    /// never asks again under a fresh key, which could make it twice.
    case mayHaveBeenMade
}

/// The rules of a time to send, read off what Mastodon 4.6.6 answered.
public enum MastodonLater {
    /// The least a source takes a post ahead by: five minutes, by its own clock as the post
    /// arrives. Nearer is refused — "Scheduled at date must be in the future"; a time it has
    /// already passed is published at once.
    public static let least: TimeInterval = 5 * 60
    /// Room beside `least` for the ask to reach the source.
    public static let margin: TimeInterval = 60
    /// How many posts one day may hold waiting, at a Mastodon that says nothing else: its own 25.
    public static let perDay = 25
    /// How many may wait at all: its own 300 (*doc — not asked: 300 waiting posts are not made
    /// to see the 301st refused*).
    public static let total = 300
    /// How many a stretch of the list asks for: the most a source gives.
    public static let stretch = 40
    /// How many stretches a look for one waiting post reads at most: every one that may wait.
    static let looks = (total + stretch - 1) / stretch

    /// The first moment a post may be given when the source's clock says `now`: `least` and
    /// `margin` ahead, up to the next whole minute.
    public static func earliest(now: Date = Date()) -> Date {
        let moment = now.addingTimeInterval(least + margin).timeIntervalSince1970
        return Date(timeIntervalSince1970: (moment / 60).rounded(.up) * 60)
    }

    /// `at`, where it is not nearer than `earliest` by the source's clock (`now`); otherwise
    /// `earliest`, and that it was moved. What the outbox sends a time that came too near while
    /// the sheet was open (X0 §2).
    public static func sendable(_ at: Date, now: Date = Date()) -> (at: Date, moved: Bool) {
        let first = earliest(now: now)
        return at < first ? (first, true) : (at, false)
    }

    /// Whether `at` is far enough ahead of the source's `now` to be asked at all.
    static func takes(_ at: Date, now: Date) -> Bool {
        at >= now.addingTimeInterval(least + margin / 2)
    }

    /// How a time is written to a source: whole seconds, in UTC.
    static func written(_ at: Date) -> String {
        writer.string(from: at)
    }

    /// One formatter for every time written: made once, read only after.
    nonisolated(unsafe) private static let writer: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Whether `error` leaves it unknown whether the source made what was asked: the answer was
    /// lost on the way, could not be read, was a fault past the door, or said "no such record" to
    /// a key already used. A refusal of the source's own, or one made here, is known not to.
    static func unknown(_ error: any Error) -> Bool {
        switch error {
        case MastodonLaterError.mayHaveBeenMade, MastodonWriteError.unreadable: true
        case MastodonAuthError.http(let status): status >= 500 || status == 408 || status == 429
        case let error as URLError:
            ![.badURL, .unsupportedURL, .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost]
                .contains(error.code)
        default: false
        }
    }
}

extension MastodonWrite {
    /// What this source's clock says now: the device's, set by how far the source's `Date`
    /// header was from it on a cheap ask of what waits — read when it is needed, since a device
    /// set wrong moves no less than a source does. The device's own where the source sent none.
    public func sourceNow(device now: Date = Date()) async throws -> Date {
        let asked = Date()
        let (_, said) = try await door.getDated(path: "/api/v1/scheduled_statuses", query: [URLQueryItem(name: "limit", value: "1")])
        guard let said else { return now }
        // The header is whole seconds, read as the answer arrived: half the round trip apart.
        let answered = Date()
        let midway = asked.addingTimeInterval(answered.timeIntervalSince(asked) / 2)
        return now.addingTimeInterval(said.addingTimeInterval(0.5).timeIntervalSince(midway))
    }

    /// The source's clock: the one handed in, or asked (`sourceNow`).
    private func clock(_ given: Date?) async throws -> Date {
        if let given { return given }
        return try await sourceNow()
    }

    /// Gives a post to this source to send at `at`, under `key` (`Idempotency-Key`: the same post
    /// asked again under it makes no second).
    ///
    /// **Judged by the source's clock** (`sourceNow`, or `sourceNow` handed in): a time nearer than
    /// it takes throws `MastodonLaterError.tooSoon` before anything is asked — a time it has
    /// already passed it would publish at once. Where it published the post at once all the
    /// same, that throws `sentNow`, never a success. A repeat under a used key answered "no such
    /// record" throws `mayHaveBeenMade` — a quote's too (`again`: a try before under `key` may have
    /// made it), where a first try's 404 is the quote not allowed. A refusal of the source's own — a day already holding as
    /// many as it takes — throws `MastodonUnprocessable` with its words.
    ///
    /// `answering` is the id at this source of the post it answers, where it answers one;
    /// `quoting` the id of the post it quotes (`quotedID(of:)`, or a waiting quote's own).
    public func postLater(
        _ text: String, visibility: Audience, at: Date, key: UUID? = nil, answering: String? = nil,
        spoiler: String? = nil, language: String? = nil, sensitive: Bool? = nil, mediaIDs: [String] = [],
        poll: NewPoll? = nil, pollLimits: MastodonPollLimits? = nil, sourceNow: Date? = nil,
        quoting: String? = nil, quotePolicy: QuotePolicy? = nil, again: Bool = false
    ) async throws -> WaitingPost {
        // A quote sent later carries its quote (#330), as one sent now does, and nothing it may not.
        let quote = try Self.quoting(id: quoting, mediaIDs: mediaIDs, poll: poll)
        try Self.pollRefusal(mediaIDs: mediaIDs, poll: poll, limits: pollLimits)
        guard let source = await store.sources().first(where: { $0.host == host }) else { throw MastodonWriteError.noSource }
        if let answering, !ListSubscription.isPathSegment(answering) { throw MastodonWriteError.unfindable }
        let now = try await clock(sourceNow)
        guard MastodonLater.takes(at, now: now) else { throw MastodonLaterError.tooSoon(earliest: MastodonLater.earliest(now: now)) }
        let form = Self.postForm(
            text, visibility: visibility, answering: answering, spoiler: spoiler, language: language,
            sensitive: sensitive, mediaIDs: mediaIDs, poll: poll
        ) + Self.quoteForm(quote, policy: quotePolicy) + [("scheduled_at", MastodonLater.written(at))]
        let sent = ReadMoment.now()
        let data: Data
        do {
            data = try await door.postRefusable(
                path: "/api/v1/statuses", form: form, headers: key.map { [Self.idempotencyKey: $0.uuidString] } ?? [:]
            )
        } catch MastodonAuthError.http(404) where !quote.isEmpty && !(again && key != nil) {
            // What a real one answers a quote it does not allow (`MastodonWrite.post`), on a first try.
            throw MastodonQuoteError.notAllowed
        } catch MastodonAuthError.http(404) where key != nil {
            // A repeat under a used key, or any post's first under one: it may wait there.
            throw MastodonLaterError.mayHaveBeenMade
        }
        if let waiting = WaitingDTO.one(from: data) {
            return waiting
        }
        guard let note = try? MastodonJSON.decoder.decode(StatusDTO.self, from: data)
            .asNote(source: source, categories: Self.categories(for: visibility), sent: sent)
        else {
            throw MastodonWriteError.unreadable
        }
        await store.ingest([note], ifSourceHere: host)
        throw MastodonLaterError.sentNow(note)
    }

    /// One stretch of what waits at this source for this sign-in (`GET /scheduled_statuses`),
    /// read on from `after` — the id the stretch before named. Each entry that cannot be read is
    /// passed over and costs no other.
    public func waiting(after: String? = nil, limit: Int = MastodonLater.stretch) async throws -> WaitingStretch {
        // A cursor that names no path segment is refused as this source's own word for it.
        if let after, !ListSubscription.isPathSegment(after) { throw MastodonWriteError.unfindable }
        let query = [URLQueryItem(name: "limit", value: String(limit))] + (try MastodonPage.older(than: after))
        let (data, link) = try await door.getLinked(path: "/api/v1/scheduled_statuses", query: query)
        guard let entries = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<WaitingDTO>].self, from: data) else {
            throw MastodonWriteError.unreadable
        }
        let onward = try MastodonLink.next(in: link)
        guard onward == nil || onward != after else { throw PagingError.notPaging }
        let quotes = WaitingDTO.quotes(in: data)
        return WaitingStretch(posts: entries.compactMap { $0.value?.waiting(quotes) }, next: onward)
    }

    /// The waiting post that is the one asked for — its words, its time to the second, who may
    /// read it, what it answers and what it quotes, its cover and whether it is covered, its poll and its files —
    /// among everything that waits but `old`, or nothing where none is: a near twin is not it.
    /// For whoever made it under a key whose answer could not be had
    /// (`MastodonLaterError.mayHaveBeenMade`): found, it waits.
    public func find(
        _ text: String, at: Date, visibility: Audience, answering: String?, spoiler: String?, sensitive: Bool?,
        mediaIDs: [String], poll: NewPoll?, quoting: String?, except old: String = ""
    ) async throws -> WaitingPost? {
        let cover = spoiler?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let files = mediaIDs.filter { !$0.isEmpty }
        let asked = poll.map { NewPoll(choices: $0.said, multiple: $0.multiple, runs: $0.runs, hidesTotals: $0.hidesTotals) }
        var after: String?
        for _ in 0..<MastodonLater.looks {
            let stretch = try await waiting(after: after)
            if let found = stretch.posts.first(where: { post in
                post.id != old && post.text == text && abs(post.at.timeIntervalSince(at)) < 1
                    && post.audience == visibility && post.answering == answering
                    && post.spoiler == cover && post.sensitive == (sensitive ?? false)
                    && post.media.map(\.id) == files && post.poll == asked && post.quoting == quoting
            }) {
                return found
            }
            guard let next = stretch.next else { return nil }
            after = next
        }
        return nil
    }

    /// Moves a waiting post to `at`, its time and nothing else (`PUT /scheduled_statuses/:id`):
    /// the source takes no other change of one. What comes back is the post at the time the
    /// source says. Refused here where `at` is too near by the source's clock, as `postLater` is;
    /// the source's own refusal throws `MastodonUnprocessable` with its words.
    public func move(_ waiting: WaitingPost, to at: Date, sourceNow: Date? = nil) async throws -> WaitingPost {
        guard ListSubscription.isPathSegment(waiting.id) else { throw MastodonWriteError.unfindable }
        let now = try await clock(sourceNow)
        guard MastodonLater.takes(at, now: now) else { throw MastodonLaterError.tooSoon(earliest: MastodonLater.earliest(now: now)) }
        let data = try await door.put(
            path: "/api/v1/scheduled_statuses/\(waiting.id)", form: [("scheduled_at", MastodonLater.written(at))]
        )
        guard let moved = WaitingDTO.one(from: data), moved.id == waiting.id else {
            throw MastodonWriteError.unreadable
        }
        return moved
    }

    /// Lets a waiting post go: it is not sent (`DELETE /scheduled_statuses/:id`). One its source no
    /// longer holds — sent, or let go elsewhere — is gone as asked.
    public func withdraw(_ waiting: WaitingPost) async throws {
        guard ListSubscription.isPathSegment(waiting.id) else { throw MastodonWriteError.unfindable }
        do {
            _ = try await door.delete(path: "/api/v1/scheduled_statuses/\(waiting.id)")
        } catch MastodonAuthError.http(404) {}
    }

    /// Changes a waiting post (Decision 2): the source changes only a waiting post's time, so
    /// **the new one is made first** — under `key`, one is made if none is given — **and the old
    /// let go only once the new one is known to wait.**
    ///
    /// - The new one's answer lost, unreadable, or a fault past the door: asked once more under
    ///   **the same key**. Where that too leaves it unknown — "no such record" to the used key
    ///   among it — the new one is looked for among what waits.
    /// - Found, or made: the old is let go; where that fails, both wait (`oldStays`).
    /// - Not found: nothing is let go, and the pair is said with `new` nothing — it may wait.
    /// - Refused by the source, or here: thrown, and the old is not touched.
    ///
    /// **What it quotes is the old one's** (#330): carried by id, never dropped — a change of a
    /// waiting quote stays a quote. **Who may quote it may change** (Decision 8 §7.1): `quotePolicy`
    /// as the caller sends it (`PostDraft.quotePolicySent`), nothing the account's own.
    public func change(
        _ old: WaitingPost, to text: String, visibility: Audience, at: Date, key: UUID = UUID(),
        spoiler: String? = nil, language: String? = nil, sensitive: Bool? = nil, mediaIDs: [String] = [],
        poll: NewPoll? = nil, pollLimits: MastodonPollLimits? = nil, sourceNow: Date? = nil,
        quotePolicy: QuotePolicy? = nil
    ) async throws -> WaitingChange {
        let now = try await clock(sourceNow)
        func make(again: Bool) async throws -> WaitingPost {
            try await postLater(
                text, visibility: visibility, at: at, key: key, answering: old.answering, spoiler: spoiler,
                language: language, sensitive: sensitive, mediaIDs: mediaIDs, poll: poll, pollLimits: pollLimits,
                sourceNow: now, quoting: old.quoting, quotePolicy: quotePolicy, again: again
            )
        }
        var new: WaitingPost?
        do {
            new = try await make(again: false)
        } catch where MastodonLater.unknown(error) {
            do {
                new = try await make(again: true)
            } catch where MastodonLater.unknown(error) {
                new = try? await find(
                    text, at: at, visibility: visibility, answering: old.answering, spoiler: spoiler, sensitive: sensitive,
                    mediaIDs: mediaIDs, poll: poll, quoting: old.quoting, except: old.id
                )
            }
        }
        let takesFiles = !Set(mediaIDs).isDisjoint(with: old.media.map(\.id))
        guard let new else { return WaitingChange(new: nil, old: old, oldStays: true, oldLostMedia: takesFiles) }
        do {
            try await withdraw(old)
            return WaitingChange(new: new, old: old, oldStays: false)
        } catch {
            return WaitingChange(new: new, old: old, oldStays: true, oldLostMedia: takesFiles)
        }
    }
}

/// `ScheduledStatus` as a source writes it. **Read leniently, field by field**: its `params` are
/// what the post was sent with, as the source kept them — a boolean as `"true"`, a number as a
/// string, an id as a bare number too large for a double — and one it spells otherwise is no
/// word, never the end of the entry.
struct WaitingDTO: Decodable, Sendable {
    let id: String
    let scheduledAt: StatusDTO.LenientMoment?
    let params: Params?
    let mediaAttachments: [StatusDTO.Lenient<StatusDTO.MediaAttachment>]?

    struct Params: Decodable, Sendable {
        let text: StatusDTO.Lenient<String>?
        let spoilerText: StatusDTO.Lenient<String>?
        let sensitive: Loose?
        let language: StatusDTO.Lenient<String>?
        let visibility: StatusDTO.Lenient<String>?
        let inReplyToId: Loose?
        let poll: StatusDTO.Lenient<PollParams>?
    }

    struct PollParams: Decodable, Sendable {
        let options: [String]?
        let expiresIn: Loose?
        let multiple: Loose?
        let hideTotals: Loose?
    }

    /// A value a source may write as a string, a number or a boolean, read as the text it says.
    struct Loose: Decodable, Sendable {
        let text: String?

        init(from decoder: any Decoder) throws {
            let one = try? decoder.singleValueContainer()
            if let string = try? one?.decode(String.self) {
                text = string
            } else if let whole = try? one?.decode(Int64.self) {
                text = String(whole)
            } else if let whole = try? one?.decode(UInt64.self) {
                text = String(whole)
            } else if let number = try? one?.decode(Decimal.self), number.isWhole {
                // A whole number past every integer type: its digits, every one.
                text = "\(number)"
            } else if let yes = try? one?.decode(Bool.self) {
                text = yes ? "true" : "false"
            } else {
                text = nil
            }
        }

        var yes: Bool? { text.map { ["true", "1"].contains($0.lowercased()) } }
        var whole: Int? { text.flatMap(Int.init) }
    }

    /// One waiting post as `data` says it, its quote read from the last of what it says.
    static func one(from data: Data) -> WaitingPost? {
        (try? MastodonJSON.decoder.decode(WaitingDTO.self, from: data))?.waiting(quotes(in: data))
    }

    /// What each waiting post in `data` — one, or a list — quotes and who may quote it, by its id.
    ///
    /// **The last of each key its `params` names** (asked of 4.6.6, `MastodonLaterCaptures`): it
    /// names `quoted_status_id` twice — a bare number too large for a double, then the id as a
    /// string — and `quote_approval_policy` twice — a number, then the word it was sent as. The
    /// decoder keeps the first of a key named twice, so these two are read here.
    static func quotes(in data: Data) -> [String: WaitingQuote] {
        var reader = LastSaid(Array(data))
        guard let root = reader.value() else { return [:] }
        let entries: [LastSaid.Value]
        switch root {
        case .array(let all): entries = all
        case .object: entries = [root]
        case .scalar: return [:]
        }
        var said: [String: WaitingQuote] = [:]
        for entry in entries {
            guard let id = entry.last("id")?.text, let params = entry.last("params"), case .object = params else { continue }
            said[id] = WaitingQuote(
                quoting: params.last("quoted_status_id")?.text.flatMap { MastodonWrite.isDigits($0) ? $0 : nil },
                policy: params.last("quote_approval_policy")?.text.flatMap(QuotePolicy.init(rawValue:))
            )
        }
        return said
    }

    /// The waiting post this says, or nothing without an id and a time; what it quotes is the
    /// one `quotes` read for its id.
    func waiting(_ quotes: [String: WaitingQuote]) -> WaitingPost? {
        guard !id.isEmpty, let at = scheduledAt?.value else { return nil }
        let quote = quotes[id]
        let poll = params?.poll?.value.flatMap { said -> NewPoll? in
            guard let options = said.options, options.count >= MastodonPollLimits.leastChoices,
                  let runs = said.expiresIn?.whole
            else { return nil }
            return NewPoll(
                choices: Array(options.prefix(Poll.mostChoices)), multiple: said.multiple?.yes ?? false, runs: runs,
                hidesTotals: said.hideTotals?.yes ?? false
            )
        }
        let answering = params?.inReplyToId?.text.flatMap { ListSubscription.isPathSegment($0) ? $0 : nil }
        return WaitingPost(
            id: id, at: at, text: params?.text?.value ?? "", spoiler: params?.spoilerText?.value ?? "",
            sensitive: params?.sensitive?.yes ?? false, language: SourceField.languageTag(params?.language?.value),
            audience: params?.visibility?.value.flatMap(Audience.init(mastodon:)), answering: answering,
            media: (mediaAttachments ?? []).compactMap { $0.value?.asSourceMedia }, poll: poll,
            quoting: quote?.quoting, quotePolicy: quote?.policy
        )
    }
}

/// What a waiting post quotes, by its source's id, and who may quote it — as `WaitingDTO.quotes`
/// read them.
struct WaitingQuote: Equatable, Sendable {
    let quoting: String?
    let policy: QuotePolicy?
}

/// A JSON reader that keeps every key an object names, in order, **twice where it is named
/// twice** — what `JSONDecoder` does not. Scalars are their text: a string unescaped, a number
/// its digits as written, a boolean its word, `null` nothing. Malformed input reads as nothing.
struct LastSaid {
    indirect enum Value: Equatable {
        case object([(String, Value)])
        case array([Value])
        case scalar(String?)

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            case let (.array(a), .array(b)): a == b
            case let (.scalar(a), .scalar(b)): a == b
            default: false
            }
        }

        /// The last value an object gives `key`; nothing for anything else.
        func last(_ key: String) -> Value? {
            guard case .object(let pairs) = self else { return nil }
            return pairs.last { $0.0 == key }?.1
        }

        /// A scalar's text; nothing for `null`, an object or a list.
        var text: String? {
            guard case .scalar(let text) = self else { return nil }
            return text
        }
    }

    private let bytes: [UInt8]
    private var at = 0
    /// How deep a value may nest before the reading stops: no answer of a source's goes near it.
    private static let deepest = 64

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// The whole input as one value, or nothing where it is not one.
    mutating func value() -> Value? {
        guard let value = read(depth: 0) else { return nil }
        skipSpace()
        return at == bytes.count ? value : nil
    }

    private mutating func skipSpace() {
        while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
    }

    private mutating func read(depth: Int) -> Value? {
        guard depth < Self.deepest else { return nil }
        skipSpace()
        guard at < bytes.count else { return nil }
        switch bytes[at] {
        case UInt8(ascii: "{"):
            at += 1
            var pairs: [(String, Value)] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard let key = string() else { return nil }
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                at += 1
                guard let value = read(depth: depth + 1) else { return nil }
                pairs.append((key, value))
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(pairs) }
                return nil
            }
        case UInt8(ascii: "["):
            at += 1
            var items: [Value] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
            while true {
                guard let item = read(depth: depth + 1) else { return nil }
                items.append(item)
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                return nil
            }
        case UInt8(ascii: "\""):
            return string().map { .scalar($0) }
        default:
            let start = at
            while at < bytes.count, !",}] \t\n\r".utf8.contains(bytes[at]) { at += 1 }
            guard start < at, let word = String(bytes: bytes[start..<at], encoding: .utf8) else { return nil }
            if word == "null" { return .scalar(nil) }
            if word == "true" || word == "false" { return .scalar(word) }
            guard word.allSatisfy({ "0123456789+-.eE".contains($0) }) else { return nil }
            return .scalar(word)
        }
    }

    /// A string at `at`, unescaped, or nothing where there is none.
    private mutating func string() -> String? {
        guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { return nil }
        at += 1
        var out: [UInt8] = []
        while at < bytes.count {
            let byte = bytes[at]
            at += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(bytes: out, encoding: .utf8)
            case UInt8(ascii: "\\"):
                guard at < bytes.count else { return nil }
                let escaped = bytes[at]
                at += 1
                switch escaped {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    guard at + 4 <= bytes.count, let hex = String(bytes: bytes[at..<at + 4], encoding: .ascii),
                          let unit = UInt16(hex, radix: 16)
                    else { return nil }
                    at += 4
                    // A surrogate pair's halves are read as one; a lone half as the replacement.
                    var scalar = Unicode.Scalar(unit)
                    if (0xD800..<0xDC00).contains(unit), at + 6 <= bytes.count, bytes[at] == UInt8(ascii: "\\"),
                       bytes[at + 1] == UInt8(ascii: "u"),
                       let low = String(bytes: bytes[at + 2..<at + 6], encoding: .ascii).flatMap({ UInt16($0, radix: 16) }),
                       (0xDC00..<0xE000).contains(low) {
                        at += 6
                        scalar = Unicode.Scalar(0x10000 + (UInt32(unit) - 0xD800) << 10 + (UInt32(low) - 0xDC00))
                    }
                    out.append(contentsOf: Array(String(Character(scalar ?? "\u{FFFD}")).utf8))
                default: out.append(escaped)
                }
            default:
                out.append(byte)
            }
        }
        return nil
    }
}

private extension Decimal {
    /// Whether this is a whole number, with nothing after the point.
    var isWhole: Bool {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return rounded == self && !isNaN
    }
}
