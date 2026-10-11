import Foundation

/// A Mastodon asked for somebody it knows (#310): who they are, by the id it gives them
/// (`/api/v1/accounts/:id`) or by their handle (`/api/v1/accounts/lookup`), and their posts, a
/// stretch at a time (`/api/v1/accounts/:id/statuses`).
///
/// **As the reader where signed in, unsigned otherwise**, as a hashtag is read (`MastodonTag`):
/// a source gives all three to anyone. Whoever reads unsigned hands in a client that is watched
/// and admitted — in the app, `SourceReach.unsignedPerson`, never a bare `URLSessionClient()`.
///
/// **Only somebody the source knows.** A handle is found where they live on the source, or
/// where it has already heard of them; of anybody else it says "not found" and asks no other
/// server. That is `PersonReadError.unheardOf`, and it is the whole answer: nothing here looks
/// further, by a search through the source or by asking their own server.
///
/// **A dead sign-in is not noticed here, and a live one is not shown by an answer.** A Mastodon
/// answers these reads to a token it no longer honours exactly as it answers nobody (200). So
/// nothing here concludes that the reader was signed out — a 401, which this source does not
/// send for these, is the door's own to confirm as for any read — and what comes back signed in
/// is not thereby the reader's view: a post that says nothing of what the reader did to it is a
/// source that did not say, as on any unsigned read.
///
/// **Nothing here writes anywhere on this device** (`PostStretch`): a read lands in what it
/// returns, and one that is refused or fails throws and changes nothing.
public struct MastodonPerson: Sendable {
    private let door: MastodonReading

    /// Unsigned, as the public timeline is read.
    public init(http: any HTTPClient, host: String) {
        door = MastodonReading(http: http, host: host)
    }

    /// As the reader, through the one signed-in door.
    public init(door: MastodonAuthorized) {
        self.door = MastodonReading(door: door)
    }

    static let lookupPath = "/api/v1/accounts/lookup"

    /// Somebody by the id this source gives them — the one a row or a mention of theirs carried.
    public func person(id: String, source: Source) async throws -> Person {
        guard source.host == door.host, ListSubscription.isPathSegment(id) else { throw MastodonRequestError.invalidURL }
        let person = try await person(source: source) { try await door.get(path: "/api/v1/accounts/\(id)") }
        // Asked for by number, the answer is theirs or it is no answer: the number is what
        // their posts and their lists are asked by next.
        guard person.accountID == id else { throw PersonReadError.unreadable }
        return person
    }

    /// Somebody by their handle, `@user@host` or `user@host`: asked as the source names its own
    /// people where the handle names the source, and as it names a stranger otherwise.
    public func person(handle: String, source: Source) async throws -> Person {
        guard source.host == door.host, let acct = Self.acct(of: handle, at: source.host) else {
            throw MastodonRequestError.invalidURL
        }
        return try await person(source: source) {
            try await door.get(path: Self.lookupPath, query: [URLQueryItem(name: "acct", value: acct)])
        }
    }

    /// The newest stretch of the posts of the account `accountID` names, or with `next` the
    /// stretch older than the one that handed it back. How long a stretch is is left to the
    /// server unless `limit` asks for a length, as a list of people's is (`MastodonPeople`).
    ///
    /// **What this reader may see, and no word of the rest.** Posts for their followers, or for
    /// the people they named, are not given to a reader who may not see them, and nothing in
    /// the answer says any were left out. A suspended account, and somebody who blocks the
    /// reader, answer with no posts and no next — as somebody who wrote nothing does.
    ///
    /// **Entry by entry**: a post this build cannot read is that one post not listed, and never
    /// the stretch — the way on is the source's own, and does not lean on any post in it.
    public func posts(
        of accountID: String, source: Source, after next: String? = nil, limit: Int? = nil
    ) async throws -> PostStretch {
        guard source.host == door.host, ListSubscription.isPathSegment(accountID) else {
            throw MastodonRequestError.invalidURL
        }
        let length = limit.map { [URLQueryItem(name: "limit", value: String(max(1, $0)))] } ?? []
        let sent = ReadMoment.now()
        let (body, link): (Data, String?)
        do {
            (body, link) = try await door.get(
                path: "/api/v1/accounts/\(accountID)/statuses", query: length + (try MastodonPage.older(than: next))
            )
        } catch where MastodonReading.notFound(error) {
            throw PersonReadError.unheardOf
        }
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<StatusDTO>].self, from: body) else {
            throw PersonReadError.unreadable
        }
        let onward: String?
        do {
            onward = try MastodonLink.next(in: link)
        } catch {
            throw PersonReadError.unreadable
        }
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        let arrived = read.compactMap { $0.value?.arrival(source: source, categories: [], sent: sent) }
        return PostStretch(posts: arrived.map(\.item), carried: arrived.compactMap(\.reblogged), next: onward)
    }

    /// One account's answer as a person: `unheardOf` where the source knows nobody of that name
    /// or number, `PersonReadError.unreadable` where what it sent is no account.
    private func person(source: Source, _ ask: () async throws -> (body: Data, link: String?)) async throws -> Person {
        let body: Data
        do {
            body = try await ask().body
        } catch where MastodonReading.notFound(error) {
            throw PersonReadError.unheardOf
        }
        guard let person = try? MastodonPeople.person(from: body, source: source) else { throw PersonReadError.unreadable }
        return person
    }

    /// How long a handle may be to be asked for: a name and a host's name, with room to spare.
    public static let handleLength = 320

    /// What a handle is asked for as: the name alone where it names `host`, `name@theirs`
    /// otherwise. Nothing — and so nothing asked — for a handle with no name, with more than a
    /// name and a host in it, longer than a handle is, or with anything unseen in it.
    static func acct(of handle: String, at host: String) -> String? {
        let bare = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        let parts = bare.split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }),
              bare.unicodeScalars.count <= handleLength, bare.unicodeScalars.allSatisfy(Self.written)
        else { return nil }
        return parts.count == 2 && parts[1].lowercased() == host.lowercased() ? String(parts[0]) : bare
    }

    private static func written(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: false
        default: true
        }
    }
}
