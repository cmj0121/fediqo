import Foundation

/// A Mastodon asked for somebody it knows (#310): who they are, by the id it gives them
/// (`/api/v1/accounts/:id`) or by their handle (`/api/v1/accounts/lookup`), their posts, a
/// stretch at a time (`/api/v1/accounts/:id/statuses`), and the posts they pinned, which are
/// asked for at that same address by one word more.
///
/// **As the reader where signed in, unsigned otherwise**, as a hashtag is read (`MastodonTag`):
/// a source gives all of them to anyone. Whoever reads unsigned hands in a client that is watched
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
        return try await statuses(of: accountID, asking: length, after: next).stretch(source: source)
    }

    /// The word a stretch of posts is narrowed by to the ones they pinned.
    static let pinnedWord = "pinned"

    /// The posts the account `accountID` names has pinned, as the source lists them, or with
    /// `next` the stretch after the one that handed it back. **The same notes as their posts
    /// are** (`posts`), read by the same reader, so whatever draws or holds a post does both
    /// to these.
    ///
    /// **None pinned is a stretch with nothing in it; nothing at all is a source that has no
    /// such thing.** Asked of two real servers (`MastodonPinnedCaptures`): somebody who pinned
    /// nothing answers an empty list, and so does a suspended account and somebody who blocks
    /// the reader. A source that does not know the word answers with their ordinary newest
    /// posts, and those are never handed back as pinned — `isThePinned` says how they are
    /// told. Somebody the source has not heard of is `PersonReadError.unheardOf`, as for their
    /// posts; whatever else is refused or fails is thrown as it is there.
    ///
    /// **In the source's order, which is not newest first.** A Mastodon lists the post pinned
    /// last first; another server the one pinned first. Whoever keeps them keeps that order
    /// (`PostsRead` does).
    ///
    /// **No length is asked for**, so that a source hands over all it has at once: a Mastodon
    /// then names no next, holding fewer pinned posts to an account than a stretch is long.
    /// Where a source names one all the same it is followed under the rules `posts` has — but
    /// a Mastodon cut short names the last post's id, in a list that is not in the order of
    /// its ids, so the stretch after it repeats some and may pass others over. Whoever reads on
    /// keeps a `PostsRead`, which lists nothing twice and stops a source that does not page.
    public func pinned(of accountID: String, source: Source, after next: String? = nil) async throws -> PostStretch? {
        guard source.host == door.host, ListSubscription.isPathSegment(accountID) else {
            throw MastodonRequestError.invalidURL
        }
        let asked = [URLQueryItem(name: Self.pinnedWord, value: "true")]
        let answered = try await statuses(of: accountID, asking: asked, after: next)
        return Self.isThePinned(answered) ? answered.stretch(source: source) : nil
    }

    /// Whether an answer to the word is the posts they pinned, and not their ordinary posts
    /// from a source that passed the word over. Asked of two real servers, nothing on a post
    /// says so to anyone but its author — a Mastodon sends `pinned` to the author alone, and
    /// another server sends `false` to everybody else on a post that is pinned — so no post's
    /// own word is read. What tells them:
    ///
    /// - **A boost is never pinned**: both servers refuse to pin one. An answer listing one is
    ///   their ordinary posts.
    /// - **The addresses the answer names for more.** A Mastodon repeats the word in each, as
    ///   it was sent, and repeats no word it does not know; the other server names none on a
    ///   pinned answer and says `pinned=false` in each on an ordinary one. So an address
    ///   without the word, or with it as anything but a yes, is an answer to another question.
    ///
    /// An answer with nothing in it tells nothing either way, and is nobody having pinned
    /// anything. **A source that passes the word over, names no address and lists no boost
    /// cannot be told**, and is believed.
    private static func isThePinned(_ answered: Answered) -> Bool {
        guard !answered.read.contains(where: { $0.reblog != nil }) else { return false }
        return MastodonLink.said(pinnedWord, in: answered.link).allSatisfy { ["true", "1"].contains($0?.lowercased()) }
    }

    /// One answer of the address somebody's posts are at: the posts that could be read, the
    /// header that came with them, where it says the next stretch begins, and when it was asked.
    private struct Answered {
        let read: [StatusDTO]
        let link: String?
        let next: String?
        let sent: ReadMoment

        func stretch(source: Source) -> PostStretch {
            let arrived = read.map { $0.arrival(source: source, categories: [], sent: sent) }
            return PostStretch(posts: arrived.map(\.item), carried: arrived.compactMap(\.reblogged), next: next)
        }
    }

    /// The address somebody's posts are at, asked with `asking` and from `next` on.
    private func statuses(of accountID: String, asking: [URLQueryItem], after next: String?) async throws -> Answered {
        let sent = ReadMoment.now()
        let (body, link): (Data, String?)
        do {
            (body, link) = try await door.get(
                path: "/api/v1/accounts/\(accountID)/statuses", query: asking + (try MastodonPage.older(than: next))
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
        return Answered(read: read.compactMap(\.value), link: link, next: onward, sent: sent)
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
