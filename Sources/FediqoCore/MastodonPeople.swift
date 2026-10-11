import Foundation

/// A Mastodon read this device could not make people of.
public enum MastodonPeopleError: Error, Equatable, Sendable {
    /// The server answered, and not with what was asked for: a body that is not an account, a
    /// list of them or a list of posts, or a way on that names no place to go on from.
    case unreadable
}

/// A Mastodon asked for a list of people (#311), a stretch at a time: `/api/v1/accounts/:id/followers`
/// and `/following`.
///
/// **As the reader where signed in, unsigned otherwise**, as a hashtag is read (`MastodonTag`):
/// a source gives these lists to anyone, and the signed-in door is the one a server that keeps
/// them for its members still answers.
///
/// **Read on by the source's own word and no other.** These lists are in the order somebody
/// followed, under ids of the follows and not of the people, so nothing in a stretch says where
/// the next begins: only the answer's `Link` header does. What is taken from it is the one
/// value it pages by, checked as an id is; the address is never followed as sent, so the next
/// ask goes where this one went and nowhere a header names.
///
/// **A list its owner hides arrives as an empty one**, with no word of why. What says "hidden"
/// is the person (`Person.hidesLists`), and whoever draws the list asks them.
///
/// **Nothing here writes anywhere on this device.** A read lands in what it returns; one that
/// is refused or fails throws what the door threw and changes nothing.
///
/// **Whoever reads unsigned hands in a client that is watched and admitted** — in the app, one
/// made by `SourceReach.wire(…within:)`, never a bare `URLSessionClient()`: an ask made here
/// is an ask of a source like any other, and the run's record names it.
///
/// **Whoever reads on keeps a `PeopleRead`**, which is what stops a source that names a next it
/// has named before, or goes on for ever with nobody new; one stretch cannot know.
public struct MastodonPeople: Sendable {
    /// A list of people a Mastodon keeps, by the id it gives the account the list is of.
    public enum List: Hashable, Sendable {
        /// Who follows them.
        case followers(of: String)
        /// Whom they follow.
        case following(of: String)

        /// Where the list is asked. Nothing for an id that could not stand in a path as one
        /// segment: it came out of a stranger's answer.
        var path: String? {
            switch self {
            case .followers(let id) where ListSubscription.isPathSegment(id): "/api/v1/accounts/\(id)/followers"
            case .following(let id) where ListSubscription.isPathSegment(id): "/api/v1/accounts/\(id)/following"
            default: nil
            }
        }
    }

    private let door: MastodonReading

    /// Unsigned, as the public timeline is read.
    public init(http: any HTTPClient, host: String) {
        door = MastodonReading(http: http, host: host)
    }

    /// As the reader, through the one signed-in door.
    public init(door: MastodonAuthorized) {
        self.door = MastodonReading(door: door)
    }

    /// The first stretch of `list`, or with `next` the stretch after the one that handed it
    /// back. How long a stretch is is left to the server unless `limit` asks for a length,
    /// which the server holds to its own bound — and never for less than one: a Mastodon
    /// answers a length of none with a failure of its own (500).
    ///
    /// **Entry by entry**: an account this build cannot read is that one person not listed, and
    /// never the stretch.
    ///
    /// **Only of the source this reads**: the people are stamped with `source`, so one that is
    /// another's asks nothing — two sources number their accounts apart.
    public func stretch(
        _ list: List, source: Source, after next: String? = nil, limit: Int? = nil
    ) async throws -> PeopleStretch {
        guard source.host == door.host, let path = list.path else { throw MastodonRequestError.invalidURL }
        let length = limit.map { [URLQueryItem(name: "limit", value: String(max(1, $0)))] } ?? []
        let (body, link) = try await door.get(path: path, query: length + (try MastodonPage.older(than: next)))
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<AccountDTO>].self, from: body) else {
            throw MastodonPeopleError.unreadable
        }
        let onward = try MastodonLink.next(in: link)
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        return PeopleStretch(people: read.compactMap { $0.value?.asPerson(source: source) }, next: onward)
    }

    /// One account's answer as the person it says, or `unreadable` where it is not one.
    static func person(from body: Data, source: Source) throws -> Person {
        guard let person = (try? MastodonJSON.decoder.decode(AccountDTO.self, from: body))?.asPerson(source: source)
        else { throw MastodonPeopleError.unreadable }
        return person
    }

}

/// The way a read that anyone is given goes out: as the reader through the one signed-in door,
/// or unsigned — one host either way, and the answer's `Link` header handed back beside its
/// body, since that is where a Mastodon says where a list goes on.
struct MastodonReading: Sendable {
    private enum Door: Sendable {
        case unsigned(any HTTPClient)
        case signedIn(MastodonAuthorized)
    }

    private let door: Door
    /// The host every ask goes to, folded as a source's own is so the two compare in one
    /// spelling.
    let host: String

    init(http: any HTTPClient, host: String) {
        door = .unsigned(http)
        self.host = host.lowercased()
    }

    init(door: MastodonAuthorized) {
        self.door = .signedIn(door)
        // Folded already: a sign-in keeps its host in lower case (`MastodonToken.init`).
        host = door.token.host
    }

    /// Throws what the door threw: `MastodonAuthError` signed in, `MastodonRequestError.http`
    /// unsigned.
    func get(path: String, query: [URLQueryItem] = []) async throws -> (body: Data, link: String?) {
        switch door {
        case .signedIn(let door):
            return try await door.getLinked(path: path, query: query)
        case .unsigned(let http):
            guard let url = Host.httpsURL(host: host, path: path, query: query) else {
                throw MastodonRequestError.invalidURL
            }
            let (body, response) = try await http.data(from: url)
            guard (200..<300).contains(response.statusCode) else {
                throw MastodonRequestError.http(response.statusCode)
            }
            return (body, response.value(forHTTPHeaderField: "Link"))
        }
    }

    /// Whether `error` is this door's "nothing of that name": a 404 by either way out.
    static func notFound(_ error: any Error) -> Bool {
        (error as? MastodonAuthError) == .http(404) || (error as? MastodonRequestError) == .http(404)
    }
}

/// A Mastodon's `Link` header, in the one thing read from it: where the next stretch begins.
enum MastodonLink {
    /// The `max_id` of the address marked `rel="next"`, or nothing where the header names no
    /// next — the end of the list.
    ///
    /// **A next that cannot be read is not the end.** One that names no `max_id`, or one that
    /// could not stand in a query as an id, throws: reading it as "no more" would end a list
    /// short and say it was whole.
    static func next(in header: String?) throws -> String? {
        guard let header else { return nil }
        // Each `<address>` and what follows it up to the next one: an address may hold a comma.
        for entry in header.split(separator: "<", omittingEmptySubsequences: false).dropFirst() {
            guard let close = entry.firstIndex(of: ">") else { continue }
            // Its marks, each `name=value`; `rel` may name several relations in one value.
            let relations = entry[entry.index(after: close)...].split(separator: ";").flatMap { mark -> [Substring] in
                let sides = mark.split(separator: "=", maxSplits: 1)
                guard sides.count == 2, sides[0].trimmingCharacters(in: .whitespaces).lowercased() == "rel" else { return [] }
                return sides[1].split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "," })
            }
            guard relations.contains(where: { $0.lowercased() == "next" }) else { continue }
            let items = URLComponents(string: String(entry[..<close]))?.queryItems ?? []
            guard let id = items.first(where: { $0.name == "max_id" })?.value, ListSubscription.isPathSegment(id) else {
                throw MastodonPeopleError.unreadable
            }
            return id
        }
        return nil
    }
}

/// One account as a Mastodon hands it over, in the fields a person is made of.
///
/// **Only who they are is required** — the id and the `acct`. Everything else is read where it
/// can be and is nothing where it cannot: a stranger's server and a fork's server send a field
/// of another shape, or none, and that must not cost the person.
struct AccountDTO: Decodable, Sendable {
    typealias Lenient = StatusDTO.Lenient

    let id: String
    let acct: String
    let username: Lenient<String>?
    let displayName: Lenient<String>?
    /// The address of the page their own server keeps for them.
    let url: Lenient<String>?
    let note: Lenient<String>?
    let avatar: Lenient<String>?
    let header: Lenient<String>?
    let locked: Lenient<Bool>?
    let bot: Lenient<Bool>?
    let group: Lenient<Bool>?
    let suspended: Lenient<Bool>?
    let limited: Lenient<Bool>?
    let hideCollections: Lenient<Bool>?
    let followersCount: Lenient<Int>?
    let followingCount: Lenient<Int>?
    let statusesCount: Lenient<Int>?
    let emojis: Lenient<[Lenient<StatusDTO.Emoji>]>?
    let fields: Lenient<[Lenient<Field>]>?
    let moved: Lenient<Moved>?

    /// How much of their words, and of one field, is read before the markup is taken out: a
    /// few times what is kept, since markup is most of a link. Cut first — taking markup out
    /// costs more than its length.
    static let noteLength = Person.wordsLength * 4
    static let valueLength = Person.fieldLength * 8

    struct Field: Decodable, Sendable {
        let name: String
        let value: String
        let verifiedAt: StatusDTO.LenientMoment?
    }

    /// The account somebody moved to, in the two things kept of it.
    struct Moved: Decodable, Sendable {
        let id: String
        let acct: String
    }

    /// Nothing for an account whose id could not stand in a path as one segment: their posts
    /// and their lists are asked by it.
    func asPerson(source: Source) -> Person? {
        guard ListSubscription.isPathSegment(id), !acct.isEmpty else { return nil }
        let named = displayName?.value ?? ""
        return Person(
            source: source, accountID: id, handle: StatusDTO.handle(acct, host: source.host),
            name: named.isEmpty ? (username?.value ?? acct) : named,
            avatarURL: Host.fetchableURL(avatar?.value), headerURL: Self.picture(header?.value),
            words: HTMLText.plain(Self.cut(note?.value ?? "", to: Self.noteLength)),
            fields: (fields?.value ?? []).lazy.compactMap(\.value).prefix(Person.fieldCount).map {
                Person.Field(
                    name: $0.name, value: HTMLText.plain(Self.cut($0.value, to: Self.valueLength)),
                    verifiedAt: $0.verifiedAt?.value
                )
            },
            emojis: CustomEmoji.folded((emojis?.value ?? []).compactMap { $0.value?.asEmoji }),
            tally: Person.Tally(
                posts: Self.count(statusesCount), following: Self.count(followingCount),
                followers: Self.count(followersCount)
            ),
            hidesLists: hideCollections?.value ?? false, locked: locked?.value ?? false,
            sort: group?.value == true ? .group : bot?.value == true ? .automated : .person,
            // Somebody said to have moved to themself has moved nowhere.
            moved: (moved?.value).flatMap { there in
                there.id != id && ListSubscription.isPathSegment(there.id) && !there.acct.isEmpty
                    ? Person.Moved(accountID: there.id, handle: StatusDTO.handle(there.acct, host: source.host)) : nil
            },
            suspended: suspended?.value ?? false, limited: limited?.value ?? false
        )
    }

    /// A picture somebody set, or nothing where the address is the one a Mastodon serves for
    /// "none set" — `…/missing.png`, a plain plate, which is not a picture of theirs.
    private static func picture(_ address: String?) -> URL? {
        Host.fetchableURL(address).flatMap { $0.lastPathComponent == "missing.png" ? nil : $0 }
    }

    /// The first `length` scalars of marked-up `text`, **ending where a tag or an entity ends**:
    /// one cut through its middle would leave the half of it — `<a href="…` — standing in their
    /// words as words. What is dropped for that is the unfinished tail and no more.
    static func cut(_ text: String, to length: Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > length else { return text }
        var kept = Substring(String(String.UnicodeScalarView(scalars.prefix(length))))
        if let open = kept.lastIndex(of: "<"), kept[open...].firstIndex(of: ">") == nil { kept = kept[..<open] }
        if let amp = kept.lastIndex(of: "&"), kept[amp...].count <= 10, kept[amp...].firstIndex(of: ";") == nil {
            kept = kept[..<amp]
        }
        return String(kept)
    }

    /// A count as the source said it, or nothing where it said none — and where it said less
    /// than none, which is how a server says "I will not say".
    private static func count(_ said: Lenient<Int>?) -> Int? {
        said?.value.flatMap { $0 >= 0 ? $0 : nil }
    }
}
