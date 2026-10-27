import Foundation

/// Whose replies a list shows, in the three words a Mastodon takes for `replies_policy`.
public enum ListReplies: String, CaseIterable, Hashable, Sendable {
    /// Replies of people the reader follows.
    case followed
    /// Replies of people on the list.
    case list
    /// No replies.
    case none
}

/// A list the server keeps (#337): its id, the name it has now, whose replies it shows, and
/// whether what is on it is kept off Home. Not written down. A chosen list on this device stays
/// `ListSubscription` — an id and a name — and nothing of these two is added to that.
public struct ServerList: Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var replies: ListReplies
    /// Whether posts on the list are kept off Home. The server's `exclusive`.
    public var exclusive: Bool

    public init(id: String, title: String, replies: ListReplies, exclusive: Bool) {
        self.id = id
        self.title = title
        self.replies = replies
        self.exclusive = exclusive
    }

    /// Whether what is on the list also shows on Home: the server's `exclusive`, the other way.
    public var alsoOnHome: Bool { !exclusive }
}

/// Somebody on a list, as far as a row needs: their id, their handle, and a name.
public struct ListPerson: Hashable, Sendable, Identifiable {
    public let id: String
    public let acct: String
    public let name: String

    public init(id: String, acct: String, name: String) {
        self.id = id
        self.acct = acct
        self.name = name
    }
}

/// A list the server did not take, or answered with what this device could not read.
public enum MastodonListError: Error, Equatable, Sendable {
    /// Refused before anything was asked: a blank name, or an id that could not stand in a path.
    case invalid
    /// The sign-in does not hold `write:lists`. Nothing was asked.
    case locked
    /// The source refused a sign-in that holds the part (403), or said the token was not issued
    /// with the word.
    case forbidden
    /// The source would not do it (422), in its own sentence made fit for a line.
    case refused(sentence: String)
    /// The list, or the person, is not there (404 `Record not found`).
    case gone
    /// The source answered, and not with what was asked for. A next page that cannot be read,
    /// or a list too long to read whole, is this and not an empty list.
    case unreadable
}

/// Lists a signed-in Mastodon keeps (#337): made, renamed, removed, and who is on them,
/// `/api/v1/lists` and `/api/v1/lists/:id/accounts`.
///
/// **Asked of a real one first** (`MastodonListCaptures`). A write goes **through the one
/// signed-in door**, and only where the sign-in holds `write:lists` — checked before anything
/// is sent, so a sign-in that was not asked the word sends nothing. Reading which lists exist,
/// who is on one, and which lists a person is on does not need that word.
///
/// **What the server refuses is said as it says it.** A 422's sentence is carried whole. Nothing
/// here asks first whether the reader follows the person: a person of this server who is not
/// followed was taken, and one of another server was not. A title is sent as given once its
/// edges are not the whole of it; a title of 200 letters was taken, so none is refused here for
/// length.
///
/// **Nothing here writes anywhere on this device.** A refusal or a failure throws, and whoever
/// was told the change is the one who writes it down, only after this returns.
public struct MastodonLists: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/lists"
    /// How many pages of a list's people are read before the rest is called unreadable, rather
    /// than the list being called whole.
    static let memberPages = 50

    /// Every list this account has, as the server says them now.
    public func all() async throws -> [ServerList] {
        try Self.lists(from: try await read(Self.path).body)
    }

    /// Makes a list of `title` alone. The server names whose replies it shows and whether it is
    /// kept off Home; both come back, and neither is sent.
    public func make(title: String) async throws -> ServerList {
        let title = try Self.titled(title)
        let body = try await wrote {
            try await door.actAtAddressInScope(path: Self.path, method: "POST", form: [("title", title)])
        }
        return try Self.one(from: body)
    }

    /// Renames `id` and sets whose replies it shows and whether it is kept off Home, together:
    /// a change is sent as the whole of the list, because the server takes the title with either.
    public func change(
        _ id: String, title: String, replies: ListReplies, exclusive: Bool
    ) async throws -> ServerList {
        let title = try Self.titled(title)
        try Self.segment(id)
        let body = try await wrote {
            try await door.actAtAddressInScope(
                path: "\(Self.path)/\(id)", method: "PUT",
                form: [("title", title), ("replies_policy", replies.rawValue), ("exclusive", exclusive ? "true" : "false")]
            )
        }
        return try Self.one(from: body)
    }

    /// Removes `id`. The server answers `{}`.
    public func remove(_ id: String) async throws {
        try Self.segment(id)
        _ = try await wrote {
            try await door.actAtAddressInScope(path: "\(Self.path)/\(id)", method: "DELETE")
        }
    }

    /// Everyone on `id`, in the server's order, following `Link` until it names no next.
    ///
    /// **A next that cannot be read is not the end**, and neither is a list that still names a
    /// next after `memberPages`: both throw, rather than hand back a list and call it whole.
    /// No length is sent. A length of none is a failure of the server's own, and the length of
    /// a page is the server's.
    public func members(of id: String) async throws -> [ListPerson] {
        try Self.segment(id)
        var people: [ListPerson] = []
        var seen = Set<String>()
        var next: String?
        for page in 1...Self.memberPages {
            let (body, link) = try await read("\(Self.path)/\(id)/accounts", query: try MastodonPage.older(than: next))
            for person in try Self.people(from: body) where seen.insert(person.id).inserted {
                people.append(person)
            }
            let onward: String?
            do { onward = try MastodonLink.next(in: link) } catch { throw MastodonListError.unreadable }
            if onward == nil { return people }
            if onward == next { throw MastodonListError.unreadable }
            if page == Self.memberPages { throw MastodonListError.unreadable }
            next = onward
        }
        throw MastodonListError.unreadable
    }

    /// Puts `accountID` on `id`. The server answers `{}`, or its own sentence where it will not.
    public func add(_ accountID: String, to id: String) async throws {
        try await membership("POST", accountID, of: id)
    }

    /// Takes `accountID` off `id`. The server answers `{}`.
    public func drop(_ accountID: String, from id: String) async throws {
        try await membership("DELETE", accountID, of: id)
    }

    /// The lists `id` is on — not the lists they own.
    public func lists(ofAccount id: String) async throws -> [ServerList] {
        try Self.segment(id)
        return try Self.lists(from: try await read("/api/v1/accounts/\(id)/lists").body)
    }

    private func membership(_ method: String, _ accountID: String, of id: String) async throws {
        try Self.segment(id)
        try Self.segment(accountID)
        _ = try await wrote {
            try await door.actAtAddressInScope(
                path: "\(Self.path)/\(id)/accounts", method: method, form: [("account_ids[]", accountID)]
            )
        }
    }

    /// A write, refused before it is sent where the sign-in does not hold the lists part.
    private func wrote(_ work: () async throws -> Data) async throws -> Data {
        guard MastodonParts.holds(.lists, in: door.token.scopes) else { throw MastodonListError.locked }
        do {
            return try await work()
        } catch let refused as MastodonUnprocessable {
            guard case .refused(let sentence) = AccountPartError.refusal(from: refused.body) else {
                throw MastodonListError.unreadable
            }
            throw MastodonListError.refused(sentence: sentence)
        } catch {
            throw Self.written(error)
        }
    }

    private func read(_ path: String, query: [URLQueryItem] = []) async throws -> (body: Data, link: String?) {
        do {
            return try await door.getLinkedAtAddress(path: path, query: query)
        } catch {
            throw Self.written(error)
        }
    }

    /// A failure of a write or a read, told apart. A sign-out and a walk away are not a list
    /// that failed: they end the ask, and whoever asked is told.
    private static func written(_ error: any Error) -> any Error {
        switch error {
        case is MastodonScopeError:
            return MastodonListError.forbidden
        case MastodonAuthError.http(403):
            return MastodonListError.forbidden
        case MastodonAuthError.http(404):
            return MastodonListError.gone
        case is MastodonHostMoreError:
            return MastodonListError.unreadable
        case MastodonAuthError.signedOut, is CancellationError:
            return error
        case let error as MastodonListError:
            return error
        default:
            return Cancellation.happened(error) ? error : MastodonListError.unreadable
        }
    }

    private static func titled(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MastodonListError.invalid }
        return title
    }

    private static func segment(_ id: String) throws {
        guard ListSubscription.isPathSegment(id) else { throw MastodonListError.invalid }
    }

    private struct Wire: Decodable {
        let id: String
        let title: String
        let repliesPolicy: String
        let exclusive: Bool
    }

    private struct MemberWire: Decodable {
        let id: String
        let acct: String?
        let username: String?
        let displayName: String?
    }

    private static func one(from body: Data) throws -> ServerList {
        guard let wire = try? MastodonJSON.decoder.decode(Wire.self, from: body) else { throw MastodonListError.unreadable }
        return try list(wire)
    }

    private static func lists(from body: Data) throws -> [ServerList] {
        guard let wires = try? MastodonJSON.decoder.decode([Wire].self, from: body) else { throw MastodonListError.unreadable }
        return try wires.map(list)
    }

    private static func list(_ wire: Wire) throws -> ServerList {
        guard let replies = ListReplies(rawValue: wire.repliesPolicy), ListSubscription.isPathSegment(wire.id) else {
            throw MastodonListError.unreadable
        }
        return ServerList(id: wire.id, title: wire.title, replies: replies, exclusive: wire.exclusive)
    }

    private static func people(from body: Data) throws -> [ListPerson] {
        guard let wires = try? MastodonJSON.decoder.decode([MemberWire].self, from: body) else {
            throw MastodonListError.unreadable
        }
        return wires.compactMap { wire in
            guard ListSubscription.isPathSegment(wire.id) else { return nil }
            let named = [wire.displayName, wire.username, wire.acct].compactMap { raw -> String? in
                guard let words = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return nil }
                return words
            }
            guard let name = named.first else { return nil }
            return ListPerson(id: wire.id, acct: wire.acct ?? wire.username ?? "", name: name)
        }
    }
}
