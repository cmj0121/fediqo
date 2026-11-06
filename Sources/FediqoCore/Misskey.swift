import Foundation

/// A Misskey, read as a guest: its local timeline, and what it says about itself.
///
/// **Every request is a POST**, and that is Misskey's shape rather than a choice made here. Its
/// API is one endpoint per verb with the arguments in a JSON body, and a GET of `/api/meta` was
/// answered 405 by two of the three hosts tried, so this client holds a sender and never a
/// plain `HTTPClient` — a read that only the GET wire could carry would be a read most Misskeys
/// refuse.
///
/// **What is read, and what is not.** The local timeline, newest first, and `/api/meta` for a
/// preview. No global or hybrid timeline, no reactions, polls or custom emoji, and MFM is left
/// as the author typed it: what a row draws is the words, and the rest can come once a row has
/// somewhere to put it.
public struct MisskeyClient: Sendable {
    private let sender: any HTTPSender
    private let host: String

    /// How many notes one ask brings: the stretch a Mastodon timeline reads, so a Misskey's
    /// page is no longer or shorter than its neighbours'. Misskey allows up to 100.
    public static let limit = 40

    public init(sender: any HTTPSender, host: String) {
        self.sender = sender
        self.host = host
    }

    /// The local timeline, newest first — past `untilID` where one is given, which is how a
    /// read goes on below the last note it holds.
    ///
    /// A pure renote comes back as two notes, the renote and the note it carries, in that order:
    /// the shape a Mastodon reblog has had since #290, so the store has one idea of a reblog and
    /// not one per protocol.
    public func localTimeline(source: Source, untilID: String? = nil) async throws -> [Note] {
        let data = try await post("/api/notes/local-timeline", body: TimelineAsk(limit: Self.limit, untilId: untilID))
        return try MisskeyJSON.decoder.decode([MisskeyNoteDTO].self, from: data).flatMap {
            $0.listed(source: source, host: host)
        }
    }

    /// What this Misskey says about itself: `POST /api/meta` with an empty body.
    ///
    /// **Through `ProfileError`, not `MisskeyRequestError`**, as `DiscourseClient.profile` is: a
    /// preview has one vocabulary for a server that said no, whatever the server speaks.
    public func profile() async throws -> SourceProfile {
        guard let request = request("/api/meta", body: Data("{}".utf8)) else {
            // Nothing was asked, so nothing answered badly — `DiscourseClient.profile`'s reason.
            throw ProfileError.unreachable
        }
        let (data, response) = try await sender.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProfileError.of(status: response.statusCode)
        }
        return try MisskeyJSON.decoder.decode(MisskeyMetaDTO.self, from: data).asProfile(host: host)
    }

    private func post(_ path: String, body: some Encodable) async throws -> Data {
        guard let request = request(path, body: try JSONEncoder().encode(body)) else {
            throw MisskeyRequestError.invalidURL
        }
        let (data, response) = try await sender.send(request)
        try Self.check(response.statusCode, body: data)
        return data
    }

    private func request(_ path: String, body: Data) -> URLRequest? {
        guard let url = Host.httpsURL(host: host, path: path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    /// Turns a failed answer into the one distinction that changes what a reader is told.
    ///
    /// **Keyed on Misskey's own words, not on the status.** A Misskey that keeps its local
    /// timeline from guests answers 400 `LTL_DISABLED` or 401 `CREDENTIAL_REQUIRED`, and the
    /// same 400 is what it answers a request it could not parse. The first two are a door the
    /// owner closed; the last is a fault on this side, and telling a reader they were turned away
    /// for it would send them looking for a setting that is not there.
    static func check(_ status: Int, body: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let code = (try? MisskeyJSON.decoder.decode(MisskeyErrorDTO.self, from: body))?.error?.code
        switch code {
        case "LTL_DISABLED", "CREDENTIAL_REQUIRED": throw MisskeyRequestError.refused(status)
        default: throw MisskeyRequestError.http(status)
        }
    }

    /// The local timeline's arguments. A nil `untilId` is left out of the body, which is what
    /// Misskey reads as "the newest".
    private struct TimelineAsk: Encodable {
        let limit: Int
        let untilId: String?
    }
}

public enum MisskeyRequestError: Error, Equatable, Sendable {
    case invalidURL
    /// The Misskey keeps this from a guest, in its own words. See `MisskeyClient.check`.
    case refused(Int)
    case http(Int)
}

enum MisskeyJSON {
    /// Misskey's keys are already camel case. Its dates are the ISO 8601 Mastodon sends,
    /// fractional seconds and all, so they are read by the parsing that is already tested.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = MastodonJSON.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unparsable date: \(raw)")
                )
            }
            return date
        }
        return decoder
    }()
}

/// `{"error":{"code":…}}` — how a Misskey says why it said no.
struct MisskeyErrorDTO: Decodable, Sendable {
    let error: Detail?

    struct Detail: Decodable, Sendable {
        let code: String?
    }
}

/// One note as `/api/notes/local-timeline` lists it.
struct MisskeyNoteDTO: Decodable, Sendable {
    let id: String
    let createdAt: Date
    let user: User
    let text: String?
    let cw: String?
    let files: [File]?
    let renoteId: String?
    let renote: RenoteBox?
    /// Read for whether there is one and nothing else: a renote with a poll is a quote.
    let poll: Poll?
    let repliesCount: Int?
    let renoteCount: Int?
    let url: String?
    let uri: String?

    /// Nothing of a poll is read: only that there is one.
    struct Poll: Decodable, Sendable {}

    struct User: Decodable, Sendable {
        let username: String
        let name: String?
        /// Where the person lives, or nothing where they live on this host.
        let host: String?
        let avatarUrl: String?
    }

    struct File: Decodable, Sendable {
        let url: String?
        let thumbnailUrl: String?
        /// A media type — `image/png`, `video/mp4` — and not Mastodon's one word.
        let type: String?
        let isSensitive: Bool?
        let comment: String?
        let properties: Properties?

        struct Properties: Decodable, Sendable {
            let width: Int?
            let height: Int?
        }

        var asAttachment: Attachment {
            Attachment(
                kind: Self.kind(of: type),
                url: Host.fetchableURL(url),
                previewURL: Host.fetchableURL(thumbnailUrl),
                alt: comment ?? "",
                width: properties?.width,
                height: properties?.height
            )
        }

        /// Read off the media type's first half. Anything else is `unknown`, which is a true
        /// answer and not a failure — one strange file must never cost the reader the page.
        private static func kind(of type: String?) -> Attachment.Kind {
            switch type?.split(separator: "/").first {
            case "image": .image
            case "video": .video
            case "audio": .audio
            default: .unknown
            }
        }
    }

    /// The note a renote carries, cut off below the first: a renote of a renote names the inner
    /// one and brings nothing, as `Box` does for a Mastodon reblog, so what lies under a second
    /// `renote` is never decoded.
    final class RenoteBox: Decodable, Sendable {
        let value: MisskeyNoteDTO?

        init(from decoder: any Decoder) throws {
            let depth = decoder.codingPath.filter { $0.stringValue == "renote" }.count
            value = depth > 1 ? nil : try MisskeyNoteDTO(from: decoder)
        }
    }

    /// Misskey's own test for a renote with nothing of its own: no words, no warning, no files,
    /// no poll. One with any of them is a quote, and is read as a note in its own right.
    private var isPureRenote: Bool {
        (renote != nil || renoteId != nil) && text == nil && cw == nil && (files ?? []).isEmpty && poll == nil
    }

    /// This note as the timeline listed it: the note, and — where it is a pure renote — the note
    /// it carries beside it, at its own time and **through no category**, because it came in the
    /// payload and not through the timeline (`StatusDTO.arrival`'s rule).
    ///
    /// Only the listed note carries `listed[.public]`: it is the id the next read goes on below
    /// (`untilId`), and without it the store records no place and read-on is never due.
    func listed(source: Source, host: String) -> [Note] {
        let inner = renote?.value
        guard isPureRenote, let innerID = inner?.id ?? renoteId else {
            var note = asNote(source: source, host: host, categories: [.public])
            note.listed = [.public: id]
            return [note]
        }
        let reference = Reference(kind: .reblogs, id: Self.noteID(host: host, innerID), statusID: innerID)
        var item = Note(
            id: Self.noteID(host: host, id), source: source, author: user.name ?? user.username,
            handle: user.handle, body: "", postedAt: createdAt, categories: [.public],
            avatarURL: Host.fetchableURL(user.avatarUrl), url: address(host: host),
            statusID: id, refs: [reference]
        )
        item.listed = [.public: id]
        // The renote is listed whatever it carries — it is the place the next read goes on below —
        // and the note it renotes comes beside it only where the payload brought one.
        guard let inner, !inner.isPureRenote else { return [item] }
        return [item, inner.asNote(source: source, host: host, categories: [])]
    }

    func asNote(source: Source, host: String, categories: Set<Category>) -> Note {
        let attachments = (files ?? []).map(\.asAttachment)
        return Note(
            id: Self.noteID(host: host, id),
            source: source,
            author: user.name ?? user.username,
            handle: user.handle,
            body: text ?? "",
            postedAt: createdAt,
            categories: categories,
            avatarURL: Host.fetchableURL(user.avatarUrl),
            attachments: attachments,
            sensitive: (files ?? []).contains { $0.isSensitive == true },
            spoiler: cw,
            url: address(host: host),
            counts: Counts(replies: repliesCount, reblogs: renoteCount),
            statusID: id
        )
    }

    /// Prefixed, as a Discourse topic's is, because one store holds every protocol's notes and
    /// a Misskey id is a plausible id on somebody else's server too.
    static func noteID(host: String, _ id: String) -> String {
        "misskey:\(host):\(id)"
    }

    /// Where the note is read on the web: its own page where it said one, the address it was
    /// federated under where it did not, and this host's page for a note of this host's.
    private func address(host: String) -> URL? {
        Host.fetchableURL(url) ?? Host.fetchableURL(uri) ?? Host.httpsURL(host: host, path: "/notes/\(id)")
    }
}

extension MisskeyNoteDTO.User {
    /// `@username`, and `@host` after it for a person who lives elsewhere — Misskey says no host
    /// for one of its own.
    var handle: String {
        host.map { "@\(username)@\($0)" } ?? "@\(username)"
    }
}

/// `/api/meta`, in the fields a preview draws.
struct MisskeyMetaDTO: Decodable, Sendable {
    let name: String?
    let description: String?
    let iconUrl: String?
    let bannerUrl: String?
    let disableRegistration: Bool?

    func asProfile(host: String) -> SourceProfile {
        SourceProfile(
            host: host,
            kind: .misskey,
            title: name,
            summary: description,
            thumbnail: Host.fetchableURL(bannerUrl) ?? Host.fetchableURL(iconUrl),
            registration: disableRegistration.map { $0 ? .closed : .open }
        )
    }
}
