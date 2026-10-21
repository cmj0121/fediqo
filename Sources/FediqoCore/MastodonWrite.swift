import Foundation

// A post written as the reader (#56): `POST /api/v1/statuses`, then the returned status into
// the store the way a fetch already does, so the row appears without asking the timeline again.

/// Why a write did not produce a note this device can hold.
/// Why a write was refused on this device, before anything was asked of the source.
public enum MastodonWriteRefusal: Equatable, Sendable {
    /// The file is over the byte ceiling the source stated for that kind.
    case tooLarge(limit: Int)
    /// More attachments than the source takes.
    case tooMany(count: Int)
    /// A kind of file the source listed, and did not list this one.
    case kind
    /// A description longer than the source takes.
    case description(limit: Int)
    /// A poll with fewer choices than two, or more than the source takes (#331).
    case pollChoices(most: Int)
    /// A poll choice longer than the source takes.
    case pollChoiceLength(limit: Int)
    /// The same choice twice in one poll, which the source refuses.
    case pollSameChoice
    /// A poll asked to run shorter or longer than the source takes, in seconds.
    case pollRuns(shortest: Int, longest: Int)
    /// A poll and media on one post, which a Mastodon does not take together.
    case pollWithMedia
    /// A vote this device knows the poll will not take (`PollRefusal`).
    case vote(PollRefusal)
}

public enum MastodonWriteError: Error, Equatable, Sendable {
    /// This device no longer holds the source the token is for.
    case noSource
    /// The server answered a status this device could not read.
    case unreadable
    /// Refused here, before a request left. The words typed are untouched.
    case refusedHere(MastodonWriteRefusal)
    /// This device cannot name the post on its own server, so there is nothing to act on: a row
    /// stored before `Note.statusID` was kept, or a forum post that never had one.
    ///
    /// **Not `noSource`.** The source is here and the sign-in is good; it is this one row that
    /// cannot be pointed at, and a reader told to sign in again would be sent to fix the wrong
    /// thing. `ShellConversations.Absence.unfindable` draws the same distinction for the same
    /// reason one layer up.
    case unfindable
    /// A pin the source would not take because the reader's page already holds as many as it
    /// allows (#334): the limit as the host's own account of itself says it
    /// (`MastodonHostSays.pinLimit`), or nothing where it says none.
    case pinLimit(Int?)
    /// A post no Mastodon pins: a reblog, or one only the people it mentions may read (asked of
    /// a real one, `MastodonPostActsCaptures`). Refused here, before anything is asked.
    case notPinnable
    /// The source would not take the act (422), in its own sentence made fit for a line —
    /// empty where it gave none this device could read.
    case refused(sentence: String)
}

/// One signed-in Mastodon source, written to.
public struct MastodonWrite: Sendable {
    /// What a Mastodon that did not advertise a ceiling will take.
    public static let defaultLimit = 500

    /// How many attachments, and how long a description, a Mastodon takes when its instance
    /// document says nothing of either. Its own numbers, as `defaultLimit` is for a post —
    /// not a ceiling invented for a byte size, which is refused only where the source stated one.
    public static let defaultMediaCount = 4
    public static let defaultDescriptionLimit = 1500

    /// Room beside a file for the multipart wrapper, so a file at the source's exact byte
    /// ceiling is not refused for the lines around it. Not a limit of the source's.
    static let uploadMargin = 65_536

    let door: MastodonAuthorized
    let store: ItemStore

    public init(door: MastodonAuthorized, store: ItemStore) {
        self.door = door
        self.store = store
    }

    var host: String { door.token.host }

    /// The header a post is sent under so that sending it again makes no second post.
    public static let idempotencyKey = "Idempotency-Key"

    /// A positive advertised ceiling, or 500. Zero and below are not a real limit.
    public static func limit(advertised: Int?) -> Int {
        guard let advertised, advertised > 0 else { return defaultLimit }
        return advertised
    }

    /// A byte ceiling named the way a refusal says it: a whole MiB, else a whole KiB, else the
    /// bytes themselves.
    public static func bytesNamed(_ bytes: Int) -> String {
        if bytes > 0, bytes.isMultiple(of: 1_048_576) { return "\(bytes / 1_048_576) MiB" }
        if bytes > 0, bytes.isMultiple(of: 1024) { return "\(bytes / 1024) KiB" }
        return "\(bytes) bytes"
    }

    /// Categories a fetch of this post would have stamped: Home, because it was written as the
    /// reader, and public where the post is public. Direct is neither.
    public static func categories(for audience: Audience) -> Set<Category> {
        switch audience {
        case .everyone: [.home, .public]
        case .unlisted, .followers: [.home]
        case .mentioned: []
        }
    }

    /// Posts `text` as the reader and takes the returned status into the store, only while the
    /// source is still here.
    ///
    /// **An answer is this call pointed at something** (#108): `answering` names the post, by the
    /// id its own server gave it, and nothing else about the write changes — the same door, the
    /// same refusals, the same store. A post that cannot be named on its server is not sent, rather
    /// than sent as a new post that answers nothing, which is the one failure here a reader could
    /// not see from the screen.
    ///
    /// **`key` is the request's `Idempotency-Key`**: the same text sent again under the same key
    /// is answered, by a source that honours it, with the post it already made — which is what
    /// lets a send nobody confirmed be sent again without posting twice.
    @discardableResult
    public func post(
        _ text: String, visibility: Audience, answering: Note? = nil, key: UUID? = nil,
        spoiler: String? = nil, language: String? = nil, sensitive: Bool? = nil,
        mediaIDs: [String] = [], poll: NewPoll? = nil, pollLimits: MastodonPollLimits? = nil
    ) async throws -> Note {
        // A poll is refused here before anything is asked: one beside media, which a Mastodon
        // takes on no post (#331), and one past what the source said it takes — where this run
        // heard what that is. Where it did not, the source is the judge of its own limits.
        if let poll {
            if mediaIDs.contains(where: { !$0.isEmpty }) { throw MastodonWriteError.refusedHere(.pollWithMedia) }
            if let pollLimits, let refusal = poll.refusal(within: pollLimits) {
                throw MastodonWriteError.refusedHere(refusal)
            }
        }
        guard let source = await store.sources().first(where: { $0.host == host }) else {
            throw MastodonWriteError.noSource
        }
        var form = [("status", text), ("visibility", visibility.mastodon)]
        if let answering {
            guard let id = answering.sendableID, answering.source.host == host else {
                throw MastodonWriteError.unfindable
            }
            form.append(("in_reply_to_id", id))
        }
        // A cover and a language are sent only where there is one. Sensitive is sent only
        // where it was chosen: absent is not a no.
        if let spoiler = Self.present(spoiler) { form.append(("spoiler_text", spoiler)) }
        if let language = SourceField.languageTag(language) { form.append(("language", language)) }
        if let sensitive { form.append(("sensitive", sensitive ? "true" : "false")) }
        for id in mediaIDs where !id.isEmpty { form.append(("media_ids[]", id)) }
        // The choices in the order typed, how long it runs, and the two answers said outright.
        if let poll {
            for choice in poll.said { form.append(("poll[options][]", choice)) }
            form.append(("poll[expires_in]", String(poll.runs)))
            form.append(("poll[multiple]", poll.multiple ? "true" : "false"))
            form.append(("poll[hide_totals]", poll.hidesTotals ? "true" : "false"))
        }
        let sent = ReadMoment.now()
        let data = try await door.post(
            path: "/api/v1/statuses", form: form,
            headers: key.map { [Self.idempotencyKey: $0.uuidString] } ?? [:]
        )
        guard let note = try? MastodonJSON.decoder.decode(StatusDTO.self, from: data)
            .asNote(source: source, categories: Self.categories(for: visibility), sent: sent)
        else {
            throw MastodonWriteError.unreadable
        }
        try Task.checkCancellation()
        await store.ingest([note], ifSourceHere: host)
        return note
    }

    /// Uploads one file to this source and returns the id it gave it (`POST /api/v2/media`).
    ///
    /// **No `Idempotency-Key`.** That key is the post's, sent once, on the status. A file the
    /// source already accepted is not sent again: its id is what a later try of the post carries.
    ///
    /// **`byteLimit` is the source's ceiling for this kind of file**, where it stated one.
    /// Nothing, where it stated none — and then the file is not refused here for a size this
    /// device invented. The multipart wrapper is allowed `uploadMargin` past the file, which is
    /// not that ceiling: a file at the source's exact limit still goes.
    ///
    /// A 202 that carries an id is the file accepted. A 422 is the source's refusal, thrown
    /// before this is taken for a post that may have landed.
    public func upload(
        bytes: Data, name: String, type: String, description: String, byteLimit: Int? = nil
    ) async throws -> String {
        if let byteLimit, bytes.count > byteLimit {
            throw MastodonWriteError.refusedHere(.tooLarge(limit: byteLimit))
        }
        let fileName = name.isEmpty ? "file" : name
        let parts = [
            MultipartPart.file("file", named: fileName, type: type, bytes),
            MultipartPart.field("description", description),
        ]
        let data = try await door.post(
            path: "/api/v2/media", parts: parts, limit: bytes.count + Self.uploadMargin
        )
        guard let id = try? MastodonJSON.decoder.decode(UploadedMedia.self, from: data).id, !id.isEmpty else {
            throw MastodonWriteError.unreadable
        }
        return id
    }

    /// A non-empty line, or nothing.
    private static func present(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Boosts `note` to this source, or takes the boost back (#106).
    ///
    /// **One function for both directions**, because they are one act under one rule: the same
    /// press, the same refusals, the same sentence when it does not arrive. Two functions would
    /// be two places for the rule about what comes back to drift apart, and the reader is doing
    /// the same thing either way.
    @discardableResult
    public func boost(_ note: Note, on: Bool) async throws -> Note {
        try await act(.boosted, on: note, path: on ? "reblog" : "unreblog")
    }

    /// Favourites `note` on this source, or takes the favourite back (#107) — `boost`'s shape, one
    /// function for both directions, and a different meaning: a note to the author and to oneself
    /// rather than a carrying-onward.
    @discardableResult
    public func favourite(_ note: Note, on: Bool) async throws -> Note {
        try await act(.favourited, on: note, path: on ? "favourite" : "unfavourite")
    }

    /// Takes back a post the reader wrote (#109), and lets go of the row once the source has.
    ///
    /// **The row goes only after the source says it went.** A refusal or a miss leaves it exactly
    /// where it is, and the same act can be asked again. A 404 is the source saying the post is
    /// not there — taken back elsewhere, or already gone — and that is what the reader asked for,
    /// so the row goes then too rather than standing as a post the source says does not exist.
    ///
    /// **A row the person keeps does not go** (#284): `ItemStore.forget` leaves it, marked as gone
    /// from its source, which it now is.
    ///
    /// Nothing checks here that the post is the reader's own: the source refuses anybody else's,
    /// and the one place that decides whether to offer it is `PostActs.on`.
    public func withdraw(_ note: Note) async throws {
        guard await store.sources().contains(where: { $0.host == host }) else {
            throw MastodonWriteError.noSource
        }
        guard let id = note.sendableID, ListSubscription.isPathSegment(id) else {
            throw MastodonWriteError.unfindable
        }
        do {
            _ = try await door.delete(path: "/api/v1/statuses/\(id)")
        } catch MastodonAuthError.http(404) {}
        try Task.checkCancellation()
        await store.forget(note.key)
    }

    /// Bookmarks `note` at this source, or takes the bookmark off (#285) — `favourite`'s shape,
    /// one function for both directions. The mark is the source's: what comes back is what it
    /// now says, and nothing is written down about the press.
    @discardableResult
    public func bookmark(_ note: Note, on: Bool) async throws -> Note {
        try await act(.bookmarked, on: note, path: on ? "bookmark" : "unbookmark")
    }

    /// Whether a Mastodon pins `note` at all, by what this device holds of it: not a reblog, and
    /// not a post only the people it mentions may read. **Whose it is, is not asked here**, as
    /// `withdraw` does not ask it: the source refuses anybody else's, and what offers the act is
    /// the one place that decides whether the post is the reader's.
    public static func pinnable(_ note: Note) -> Bool {
        !note.isReblog && note.audience != .mentioned
    }

    /// Pins the reader's own `note` to their page at this source, or takes the pin off (#334) —
    /// `bookmark`'s shape, one function for both directions, and the source's answer laid over
    /// the row as the latest word on the pin (`ReaderMark.pinned`).
    ///
    /// **A pin the source turns away (422) is told by the post, read again — never by the
    /// sentence**, which a Mastodon writes in the signed-in account's own language (asked of a
    /// real one, `MastodonPostActsCaptures`). The post says `pinned` to its author alone:
    /// - pinned — a pin already there, from elsewhere since this device last read it — lands as
    ///   the pin's answer;
    /// - not pinned, the reader's own, and one that may be pinned: the page is full, `pinLimit`
    ///   with `limit` — the host's own figure, handed in by whoever heard it;
    /// - anything else — somebody else's post, which says nothing of a pin; one only its
    ///   mentioned may read — is the source's own words (`refused`), and so is a refused unpin.
    @discardableResult
    public func pin(_ note: Note, on: Bool, limit: Int? = nil) async throws -> Note {
        guard Self.pinnable(note) else { throw MastodonWriteError.notPinnable }
        do {
            return try await act(.pinned, on: note, path: on ? "pin" : "unpin", refusable: true)
        } catch let refused as MastodonUnprocessable {
            let sentence = if case .refused(let said) = AccountPartError.refusal(from: refused.body) { said } else { "" }
            guard on, let id = note.sendableID else { throw MastodonWriteError.refused(sentence: sentence) }
            let sent = ReadMoment.now()
            let answered = try landed(try await door.get(path: "/api/v1/statuses/\(id)"), on: note, sent: sent)
            switch answered.pinned {
            case true?: return await settle(answered, on: note, acted: .pinned)
            case false? where Self.pinnable(answered): throw MastodonWriteError.pinLimit(limit)
            default: throw MastodonWriteError.refused(sentence: sentence)
            }
        }
    }

    /// Quiets `note`'s conversation at this source — no more notices of what is answered in it —
    /// or lets it speak again (#334): `bookmark`'s shape, and the source's answer the latest word
    /// on it (`ReaderMark.muted`). **Anybody's post**, the reader's own or not: a Mastodon quiets
    /// any conversation its reader can see (asked of a real one).
    @discardableResult
    public func quiet(_ note: Note, on: Bool) async throws -> Note {
        try await act(.muted, on: note, path: on ? "mute" : "unmute")
    }

    /// Votes in `note`'s poll for `choices`, each by its place (#331), and returns the post as
    /// the store now holds it — with the poll as the source answered the vote.
    ///
    /// **Refused here, before anything is sent, where the poll will not take it**: it has
    /// ended, the reader voted in it already, or what was chosen is not a vote it takes
    /// (`Poll.refusal`). Nothing then changes on this device.
    ///
    /// **The answer is the poll, and it lands as an act's answer does** (`act`): laid over the
    /// row the store holds, told it is the latest word on the reader's vote (`ReaderMark.voted`),
    /// so a read still on its way when the vote landed cannot draw the poll unvoted again. A
    /// refusal or a miss changes nothing here: the store is written only once the source said yes.
    @discardableResult
    public func vote(_ note: Note, choices: [Int]) async throws -> Note {
        guard await store.sources().contains(where: { $0.host == host }) else {
            throw MastodonWriteError.noSource
        }
        guard let poll = note.poll, ListSubscription.isPathSegment(poll.id) else {
            throw MastodonWriteError.unfindable
        }
        if let refusal = poll.refusal(of: choices) { throw MastodonWriteError.refusedHere(.vote(refusal)) }
        let sent = ReadMoment.now()
        let data = try await door.post(
            path: "/api/v1/polls/\(poll.id)/votes", form: choices.sorted().map { ("choices[]", String($0)) }
        )
        guard let answered = (try? MastodonJSON.decoder.decode(PollDTO.self, from: data))?.poll,
              answered.id == poll.id
        else {
            throw MastodonWriteError.unreadable
        }
        try Task.checkCancellation()
        // Over the row as held now, where it is held: nothing but its poll is this answer's word.
        var copy = await store.note(note.key) ?? note
        copy.poll = answered
        copy.asked = sent
        await store.refresh([copy], ifSourceHere: host, acted: .voted)
        return await store.note(copy.key) ?? copy.refreshed(over: note)
    }

    /// One act on one status, and what the server says the post looks like afterwards.
    ///
    /// **The answer goes through `refresh` and never `ingest`.** The reader is acting on a post
    /// they are already looking at, so what comes back is a row this device holds and should be
    /// replaced with what the server now says — including `boosted`, which is the whole point of
    /// the press. `ingest` would keep the first copy and change nothing, which is a press that
    /// lands on the server and does nothing on the screen; and a post the store no longer holds
    /// is not quietly admitted, which is `refresh`'s own contract.
    ///
    /// **The store's copy is the one returned**, not the one decoded. `Note.refreshed(over:)` is
    /// what keeps the categories this copy arrived through and its booster, and a caller handed
    /// the bare decode would be holding a row that disagrees with the store about both. A post the
    /// store does not hold — an answer read in an open conversation, which #90 keeps out of the
    /// store's rows — is laid over the copy the caller handed in by the same rule, so the two
    /// kinds of row come back shaped alike.
    ///
    /// **The store is told which mark the answer is for** (#291). A status says all three, and
    /// only the one this act moved is certainly its latest word: see `ItemStore.refresh`.
    ///
    /// **`refusable`** has a 422 thrown as `MastodonUnprocessable`, with the source's own words,
    /// for an act whose refusals say different things (`pin`).
    private func act(_ mark: ReaderMark, on note: Note, path: String, refusable: Bool = false) async throws -> Note {
        guard await store.sources().contains(where: { $0.host == host }) else {
            throw MastodonWriteError.noSource
        }
        guard let id = note.sendableID, ListSubscription.isPathSegment(id) else {
            throw MastodonWriteError.unfindable
        }
        let sent = ReadMoment.now()
        let address = "/api/v1/statuses/\(id)/\(path)"
        let data = try await refusable ? door.postRefusable(path: address, form: []) : door.post(path: address, form: [])
        return await settle(try landed(data, on: note, sent: sent), on: note, acted: mark)
    }

    /// A status the source answered about `note`, as a note of the same row, or `unreadable`.
    private func landed(_ data: Data, on note: Note, sent: ReadMoment) throws -> Note {
        guard let answered = try? MastodonJSON.decoder.decode(StatusDTO.self, from: data)
            .asNote(source: note.source, categories: note.categories, sent: sent)
        else {
            throw MastodonWriteError.unreadable
        }
        try Task.checkCancellation()
        return answered
    }

    /// `answered` laid over the row as an act's answer is (`act`), and the store's copy back.
    private func settle(_ answered: Note, on note: Note, acted mark: ReaderMark) async -> Note {
        await store.refresh([answered], ifSourceHere: host, acted: mark)
        return await store.note(answered.key) ?? answered.refreshed(over: note)
    }
}

/// The id a media upload was answered with. Anything else about the file is the source's to
/// keep; a post sends the id.
private struct UploadedMedia: Decodable {
    let id: String
}

/// How much media a Mastodon says it takes, read off the instance document beside the profile.
///
/// **Lenient, and never the reason a host could not be read.** A document that is not the
/// shape this looks for, or that says nothing of media, is `unstated`: Mastodon's own count
/// and description length, and no byte ceiling — a size is refused here only where the source
/// stated one. A JSON boolean is not the number 1.
public struct MastodonMediaLimits: Equatable, Sendable {
    /// How many attachments one post may carry.
    public let count: Int
    /// How long a description may be.
    public let descriptionLimit: Int
    /// The image byte ceiling, where the source stated one.
    public let imageBytes: Int?
    /// The video byte ceiling, where the source stated one. Sound is held to the same one.
    public let videoBytes: Int?
    /// The types the source listed, lowercased. Empty means it listed none, which is not a
    /// refusal of every type.
    public let mimeTypes: [String]

    /// What stands where the document says nothing of media.
    public static let unstated = MastodonMediaLimits(
        count: MastodonWrite.defaultMediaCount,
        descriptionLimit: MastodonWrite.defaultDescriptionLimit,
        imageBytes: nil, videoBytes: nil, mimeTypes: []
    )

    public init(count: Int, descriptionLimit: Int, imageBytes: Int?, videoBytes: Int?, mimeTypes: [String]) {
        self.count = count
        self.descriptionLimit = descriptionLimit
        self.imageBytes = imageBytes
        self.videoBytes = videoBytes
        self.mimeTypes = mimeTypes
    }

    /// `document` read for the media ceilings, or `unstated` where it says nothing of them.
    public init(document: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any],
              let configuration = root["configuration"] as? [String: Any]
        else {
            self = .unstated
            return
        }
        let statuses = configuration["statuses"] as? [String: Any]
        let media = configuration["media_attachments"] as? [String: Any]
        self.init(
            count: Self.positive(statuses?["max_media_attachments"]) ?? MastodonWrite.defaultMediaCount,
            descriptionLimit: Self.positive(media?["description_limit"]) ?? MastodonWrite.defaultDescriptionLimit,
            imageBytes: Self.positive(media?["image_size_limit"]),
            videoBytes: Self.positive(media?["video_size_limit"]),
            mimeTypes: Self.types(media?["supported_mime_types"])
        )
    }

    /// The byte ceiling for `mime`, where the source stated one for that kind. Nothing for a
    /// kind it did not, and nothing where it stated no ceiling: not a number this device made up.
    public func byteLimit(for mime: String) -> Int? {
        let kind = mime.lowercased()
        if kind.hasPrefix("image/") { return imageBytes }
        if kind.hasPrefix("video/") || kind.hasPrefix("audio/") { return videoBytes }
        return nil
    }

    /// Whether `mime` is one the source listed. A source that listed none has not refused this.
    public func allows(_ mime: String) -> Bool {
        mimeTypes.isEmpty || mimeTypes.contains(mime.lowercased())
    }

    /// A positive whole number, or nothing. Zero is not a ceiling. A boolean is not a number.
    static func positive(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if value is Bool || CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return nil }
        let whole = number.intValue
        guard whole > 0, number.doubleValue == Double(whole) else { return nil }
        return whole
    }

    /// The types listed, lowercased, empty ones dropped, each kept once, in the order given.
    private static func types(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        var seen: Set<String> = []
        var kept: [String] = []
        for item in list {
            guard let raw = item as? String else { continue }
            let type = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !type.isEmpty, seen.insert(type).inserted else { continue }
            kept.append(type)
        }
        return kept
    }
}
