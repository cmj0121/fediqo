import Foundation

/// A conversation read this device could not make a list of (#326).
public enum MastodonDirectsError: Error, Equatable, Sendable {
    /// The sign-in does not hold what the ask needs. Nothing was asked.
    case unasked
    /// The server answered, and not with a list of conversations: a body that is no list, or a
    /// way on that names no place to go on from.
    case unreadable
}

/// One line of posts written to named people (#326): who is in it, and its latest words.
///
/// **The post is not on the line.** Opening it is the note the read brought, held under
/// `statusRow`. A line whose latest post the source did not send still names who is in it, and
/// cannot be opened.
public struct DirectLine: Equatable, Sendable, Identifiable {
    public let id: String
    /// Whether the source says it has not been read.
    public var unread: Bool
    /// Who else is in it, as the source names them. The reader is not among them.
    public let names: [String]
    /// The same people, each a whole handle, in that order. The reader may still be among them:
    /// whoever holds the sign-in takes them out before anything is kept.
    public let handles: [String]
    /// The latest post's words, or empty where the source sent no latest post.
    public let words: String
    /// The row of that post, or nothing where there is no post to open.
    public let statusRow: String?

    public init(id: String, unread: Bool, names: [String], handles: [String], words: String, statusRow: String?) {
        self.id = id
        self.unread = unread
        self.names = names
        self.handles = handles
        self.words = words
        self.statusRow = statusRow
    }
}

/// An answer written from inside a conversation (#326): it stays with the people named, and it
/// names those people and nobody else.
public enum DirectAnswer {
    /// `text` as it goes to `wanted`, and only to them. Every mention token is taken out of the
    /// words, the people asked for are written once at the front in the spelling handed in, and
    /// a mention of anybody else is dropped. What is not a mention stays, in order.
    ///
    /// A mention token is `@name` or `@name@host`, of letters, digits, `_`, `.` and `-`. A
    /// trailing `. , ! ? ; :` is not part of the handle. Compared without regard to case, so a
    /// person asked for is not written twice. `wanted` is already bounded by whoever called.
    public static func prepared(_ text: String, to wanted: [String]) -> (text: String, audience: Audience) {
        var seen = Set<String>()
        var head: [String] = []
        for raw in wanted {
            let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !handle.isEmpty, seen.insert(handle.lowercased()).inserted else { continue }
            head.append(handle)
        }
        let rest = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !Self.mention($0) }
        return ((head + rest).joined(separator: " "), .mentioned)
    }

    /// Whether `token` names somebody, once a trailing stop has been set aside.
    private static func mention(_ token: String) -> Bool {
        var word = Substring(token)
        while let last = word.last, last.unicodeScalars.allSatisfy({ ".,!?;:".unicodeScalars.contains($0) }) {
            word = word.dropLast()
        }
        guard word.first == "@" else { return false }
        let body = word.dropFirst()
        let pieces = body.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { return false }
        return pieces.allSatisfy { piece in
            !piece.isEmpty && piece.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
        }
    }
}

/// A Mastodon asked for the posts written to named people (#326): `/api/v1/conversations`, read
/// a page at a time, marked read, and removed from that list.
///
/// **The shape is the one the published docs give** (methods, updated May 2026), not a capture
/// of a live server. The sample there leaves a status's body as a comment; a status this decoder
/// accepts has to carry `content` and an account's `display_name`, so a fixture fills those and
/// keeps the documented ids.
///
/// **Read with what reads timelines, changed with its own word.** A page is asked only where the
/// sign-in holds reading (`read:statuses`, or the source's one word for every read). Marking one
/// read and removing one are asked only where it holds `write:conversations`. The coarse word
/// `write` is not that. Either lack throws `unasked` and asks nothing.
///
/// **Nothing here writes the store.** An ask that is refused or fails throws, and the list this
/// device drew stays as it was.
public struct MastodonDirects: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/conversations"
    /// How many lines one page asks for. The source's own default, and under its maximum.
    static let limit = 20

    /// One page of conversations, the newest first, or with `cursor` the page after the one that
    /// handed that id back. Each line's latest post is a note whose only category is
    /// conversations — never the public timeline — keyed by the conversation's id.
    public func page(after cursor: String?) async throws -> (lines: [DirectLine], notes: [String: Note], next: String?) {
        try reading()
        let query = [URLQueryItem(name: "limit", value: String(Self.limit))] + (try MastodonPage.older(than: cursor))
        let (body, link) = try await door.getLinked(path: Self.path, query: query)
        guard let read = try? MastodonJSON.decoder.decode([ConversationDTO].self, from: body) else {
            throw MastodonDirectsError.unreadable
        }
        let onward: String?
        do {
            onward = try MastodonLink.next(in: link)
        } catch {
            throw MastodonDirectsError.unreadable
        }
        guard onward == nil || onward != cursor else { throw PagingError.notPaging }
        let source = Source(host: door.token.host, kind: .mastodon)
        let sent = ReadMoment.now()
        var seen = Set<String>()
        var lines: [DirectLine] = []
        var notes: [String: Note] = [:]
        for conversation in read where seen.insert(conversation.id).inserted {
            let line = Self.line(conversation, source: source, sent: sent)
            lines.append(line.line)
            if let note = line.note { notes[conversation.id] = note }
        }
        return (lines, notes, onward)
    }

    /// Marks conversation `id` read. The posts stay. An id that cannot stand in a path asks
    /// nothing.
    public func markRead(_ id: String) async throws {
        try writing()
        guard ListSubscription.isPathSegment(id) else { throw MastodonRequestError.invalidURL }
        _ = try await door.post(path: "\(Self.path)/\(id)/read", form: [])
    }

    /// Removes conversation `id` from the list. The posts stay on the server. An id that cannot
    /// stand in a path asks nothing.
    public func remove(_ id: String) async throws {
        try writing()
        guard ListSubscription.isPathSegment(id) else { throw MastodonRequestError.invalidURL }
        _ = try await door.delete(path: "\(Self.path)/\(id)")
    }

    private func reading() throws {
        let scopes = door.token.scopes
        guard MastodonParts.holds(.reading, in: scopes) || MastodonParts.holdsEveryRead(in: scopes) else {
            throw MastodonDirectsError.unasked
        }
    }

    private func writing() throws {
        guard MastodonParts.holds(.conversations, in: door.token.scopes) else {
            throw MastodonDirectsError.unasked
        }
    }

    /// One conversation as a line, and the note of its latest post where it sent one.
    private static func line(
        _ conversation: ConversationDTO, source: Source, sent: ReadMoment
    ) -> (line: DirectLine, note: Note?) {
        var names: [String] = []
        var handles: [String] = []
        var seen = Set<String>()
        func keep(_ handle: String, name: String?) {
            guard seen.insert(handle.lowercased()).inserted else { return }
            handles.append(handle)
            if let name { names.append(name) }
        }
        for account in conversation.accounts {
            keep(StatusDTO.handle(account.acct, host: source.host), name: shown(account))
        }
        guard let status = conversation.lastStatus else {
            return (DirectLine(id: conversation.id, unread: conversation.unread, names: names, handles: handles, words: "", statusRow: nil), nil)
        }
        let subject = status.reblog?.value ?? status
        keep(StatusDTO.handle(subject.account.acct, host: source.host), name: nil)
        var note = status.asNote(source: source, categories: [.conversations], sent: sent)
        note.listed[.conversations] = conversation.id
        note.mentions = handles
        let line = DirectLine(
            id: conversation.id, unread: conversation.unread, names: names, handles: handles,
            words: HTMLText.plain(subject.content), statusRow: note.key.rowID
        )
        return (line, note)
    }

    /// The name an account is drawn under: what it shows of itself, or its name on the server.
    private static func shown(_ account: StatusDTO.Account) -> String {
        let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return (account.username ?? account.acct).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One conversation as the published docs spell it. A status's truncated fields are whatever the
/// decoder already treats as optional.
private struct ConversationDTO: Decodable {
    let id: String
    let unread: Bool
    let accounts: [StatusDTO.Account]
    let lastStatus: StatusDTO?
}
