import Foundation

// A Mastodon's directory of people (#315): the people there who chose to be listed, read a
// stretch at a time.
//
// **Asked of a real one first** (`MastodonDirectoryCaptures`). It is given to anyone; asked as
// somebody signed in, it leaves out the people they block or mute and whoever blocks them — so
// it is asked as the reader where there is one, and with no sign-in otherwise. It takes two orders — whoever posted most lately first, which is also
// what it gives unasked, and whoever came most lately first — and any other word for an order
// is answered with a failure of the server's own, so only those two are ever sent. It can be
// held to the people who live there. **It names no next**: no `Link` header, nothing in the
// body; a stretch begins at a count of people passed over, and that count is the only way on.
// Switched off by whoever runs the host it answers a not-found of its own address, which is
// how it is known absent (`MastodonHostNotFound`) — and an empty list is a directory nobody
// chose to be in, never one switched off.
//
// **A stranger's word, bounded where it enters.** Each account is read by the one reader an
// account has (`AccountDTO.asPerson`), which cuts and cleans it; a stretch is held to the
// length asked for, however many a host sends.

/// The order a Mastodon's directory is asked in: the two it takes, by its own words for them.
public enum DirectoryOrder: String, Sendable, Hashable, CaseIterable {
    /// Whoever posted most lately first — what a Mastodon gives where no order is asked.
    case active
    /// Whoever came most lately first.
    case new
}

/// A Mastodon asked for its directory of people: `/api/v1/directory`, as the reader through the
/// one signed-in door, or with no sign-in.
///
/// **Whoever reads unsigned hands in a client that is watched, admitted, small and kept to its
/// host** — in the app, one made by `SourceReach.unsignedDirectory`, never a bare
/// `URLSessionClient()`.
///
/// **Read on by how many were passed over**, which is the source's own way and the only one it
/// has. People who join or leave between two asks move where a stretch begins, so somebody may
/// arrive twice — whoever reads on keeps a `PeopleRead`, which lists nobody twice — and
/// somebody may be passed over, which nothing here can know.
///
/// **Nothing here writes anywhere on this device**, and nothing is remembered: what a not-found
/// means for the rest of the run is its caller's to keep (`MastodonHostsKnown`).
public struct MastodonDirectory: Sendable {
    private enum Door: Sendable {
        case unsigned(any HTTPClient)
        case signedIn(MastodonAuthorized)
    }

    private let door: Door
    private let host: String

    /// Unsigned, as anyone is given it.
    public init(http: any HTTPClient, host: String) {
        door = .unsigned(http)
        self.host = host.lowercased()
    }

    /// As the reader, through the one signed-in door, to the host the sign-in is of.
    public init(door: MastodonAuthorized) {
        self.door = .signedIn(door)
        host = door.token.host
    }

    static let path = "/api/v1/directory"
    /// The most people one stretch is asked for, and the most that are read of one: what a
    /// Mastodon gives at most.
    public static let longest = 80
    /// The furthest into a directory a stretch is asked for: fifty stretches. A stranger's list
    /// read on by a count is read on by a count of ours, and neither it nor what one page
    /// holds is let grow without end. Reached, a stretch names no next — and whoever draws it
    /// says the reading stopped there, not that the source has no more.
    public static let furthest = 4_000

    /// The stretch of the directory that begins after `passed` people — the first where that
    /// is none — in `order`, of everybody the host knows or, with `localOnly`, of the people
    /// who live there.
    ///
    /// **What it names as its next is how many have now been passed**, or nothing where it gave
    /// nobody: a host holds a stretch to a length of its own, so a short stretch is not known
    /// to be the last, and only an empty one is the end. Throws `MastodonHostMoreError.noSuchAddress`
    /// where the host says it has no such address.
    ///
    /// **Entry by entry**: an account this build cannot read is that one person not listed —
    /// and still one passed over, since the host counted them.
    public func stretch(
        source: Source, order: DirectoryOrder = .active, localOnly: Bool = false, after passed: Int = 0,
        limit: Int = MastodonDirectory.longest
    ) async throws -> PeopleStretch {
        guard source.host == host, (0...Self.furthest).contains(passed) else { throw MastodonRequestError.invalidURL }
        let length = min(max(1, limit), Self.longest)
        var query = [
            URLQueryItem(name: "order", value: order.rawValue),
            URLQueryItem(name: "limit", value: String(length)),
        ]
        // Sent only where it is wanted: a Mastodon takes any word but a plain no for a yes.
        if localOnly { query.append(URLQueryItem(name: "local", value: "true")) }
        if passed > 0 { query.append(URLQueryItem(name: "offset", value: String(passed))) }
        let body = try await get(query)
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<AccountDTO>].self, from: body) else {
            throw MastodonPeopleError.unreadable
        }
        let given = read.prefix(length)
        let reached = passed + given.count
        return PeopleStretch(
            people: given.compactMap { $0.value?.asPerson(source: source) },
            next: given.isEmpty || reached >= Self.furthest ? nil : String(reached)
        )
    }

    /// The answer's body: `noSuchAddress` where the host says the address is not there, by
    /// either door, and what that door throws for any other refusal.
    private func get(_ query: [URLQueryItem]) async throws -> Data {
        switch door {
        case .signedIn(let door):
            return try await door.getAtAddress(path: Self.path, query: query)
        case .unsigned(let http):
            guard let url = Host.httpsURL(host: host, path: Self.path, query: query) else {
                throw MastodonRequestError.invalidURL
            }
            let (body, response) = try await http.data(from: url)
            if MastodonHostNotFound.isOfTheAddress(status: response.statusCode, body: body) {
                throw MastodonHostMoreError.noSuchAddress
            }
            guard (200..<300).contains(response.statusCode) else { throw MastodonRequestError.http(response.statusCode) }
            return body
        }
    }

    /// How many people a next names as passed over, or nothing where it is not such a count:
    /// what `stretch` handed back, read again.
    public static func passed(_ next: String) -> Int? {
        guard !next.isEmpty, next.utf8.count <= 4, next.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(next).flatMap { (1...furthest).contains($0) ? $0 : nil }
    }
}
