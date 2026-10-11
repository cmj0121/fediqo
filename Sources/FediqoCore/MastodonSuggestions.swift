import Foundation

// The people a Mastodon suggests to whoever is signed in (#315), read a stretch at a time.
//
// **Asked of a real one first** (`MastodonSuggestionsCaptures`). Nobody is suggested anything
// unsigned: it is asked as the reader, and wants one word of reading that every sign-in of
// this app holds. Each entry is an account beside the server's reasons for suggesting it, and
// only the account is read. Asked as the reader, a source has already left out whoever they
// follow, block or mute, whoever blocks them, and whoever it suspended or limited or who moved.
// **It names no next**: no `Link` header, nothing in the body; a stretch begins at a count of
// people passed over. **A stretch shorter than was asked for is taken for the end, and nothing
// is asked after it**: a real server gives as many as it was asked for while it has them, so a
// shorter one is all it had. Asked on from exactly how many it has it answers with nobody; only
// further past that — where what it suggests grew shorter meanwhile — does it answer with a
// failure of its own, which is not met this way. **The known limit**: a host that gives fewer
// in a stretch than it was asked for is cut short there, and that is called the end. Its order
// is drawn by lot for each reader and drawn again whenever what it suggests them changes, so
// read on across such a change somebody may arrive twice — whoever reads on keeps a
// `PeopleRead`, which lists nobody twice — and somebody may be passed over, which nothing here
// can know.
//
// **Telling the source not to suggest somebody is not here.** A real server takes that only
// from a sign-in holding a word that belongs to changing the reader's own account, which no
// sign-in of this app is asked for yet.
//
// **A stranger's word, bounded where it enters.** The body arrives under the signed-in door's
// ceiling; each account is read by the one reader an account has (`AccountDTO.asPerson`), which
// cuts and cleans it; a stretch is held to the length asked for, however many a host sends.

/// A Mastodon asked for the people it suggests the reader: `/api/v2/suggestions`, through the
/// one signed-in door, to the host the sign-in is of.
///
/// **Nothing here writes anywhere on this device**, and nothing is remembered: what a not-found
/// means for the rest of the run is its caller's to keep (`MastodonHostsKnown`).
public struct MastodonSuggestions: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v2/suggestions"
    /// The most people one stretch is asked for, and the most that are read of one: what a
    /// Mastodon's other lists of people give at most.
    public static let longest = 80
    /// The furthest into its suggestions a stretch is asked for: five stretches. A stranger's
    /// list read on by a count is read on by a count of ours, and neither it nor what one page
    /// holds is let grow without end. Reached, a stretch names no next — and whoever draws it
    /// says the reading stopped there, not that the source has no more.
    public static let furthest = 400

    /// The stretch of suggestions that begins after `passed` people — the first where that is
    /// none.
    ///
    /// **What it names as its next is how many have now been passed**, and only where it was
    /// given as many as it asked for: a shorter stretch is the end. Throws
    /// `MastodonHostMoreError.noSuchAddress` where the host says it has no such address.
    ///
    /// **Entry by entry**: an entry this build cannot read is that one person not listed — and
    /// still one passed over, since the host counted them.
    public func stretch(
        source: Source, after passed: Int = 0, limit: Int = MastodonSuggestions.longest
    ) async throws -> PeopleStretch {
        guard source.host == door.token.host, (0...Self.furthest).contains(passed) else { throw MastodonRequestError.invalidURL }
        let length = min(max(1, limit), Self.longest)
        var query = [URLQueryItem(name: "limit", value: String(length))]
        if passed > 0 { query.append(URLQueryItem(name: "offset", value: String(passed))) }
        let body = try await door.getAtAddress(path: Self.path, query: query)
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<Entry>].self, from: body) else {
            throw MastodonPeopleError.unreadable
        }
        let given = read.prefix(max(0, length))
        let reached = passed + given.count
        return PeopleStretch(
            people: given.compactMap { $0.value?.account?.value?.asPerson(source: source) },
            next: given.count < length || reached >= Self.furthest ? nil : String(reached)
        )
    }

    /// One suggestion as the server sends it. Why it is suggested stands beside the account,
    /// and is not read.
    private struct Entry: Decodable, Sendable {
        let account: StatusDTO.Lenient<AccountDTO>?
    }

    /// How many people a next names as passed over, or nothing where it is not such a count:
    /// what `stretch` handed back, read again.
    public static func passed(_ next: String) -> Int? {
        guard !next.isEmpty, next.utf8.count <= 3, next.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(next).flatMap { (1...furthest).contains($0) ? $0 : nil }
    }
}
