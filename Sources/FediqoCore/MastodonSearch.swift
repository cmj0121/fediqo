import Foundation

/// What one ask of a source's search brought (#319): the posts, the people and the hashtags it
/// found under some words, each kind apart and each in the source's own order.
public struct SearchFinds: Sendable {
    /// The posts, stamped with the source asked and arriving through no category: a search is
    /// not a timeline.
    public let posts: [Note]
    /// The people, each read by the one reader an account has.
    public let people: [Person]
    /// The hashtags, each read by the one reader a list of hashtags has.
    public let tags: [RisingTag]

    public init(posts: [Note] = [], people: [Person] = [], tags: [RisingTag] = []) {
        self.posts = posts
        self.people = people
        self.tags = tags
    }
}

/// Somebody a source found by an address it was asked to look up (#319), and whether they are
/// at the address typed or only of the name it gives.
public struct PersonLookedUp: Hashable, Sendable {
    public let person: Person
    /// False where they were believed by the name alone: found at another server than the
    /// address names, which whoever is shown them is told.
    public let asTyped: Bool

    public init(person: Person, asTyped: Bool = true) {
        self.person = person
        self.asTyped = asTyped
    }
}

/// An address of a person, as somebody typed it (#319): `@name@host`, or the address of the
/// page a server keeps for them.
///
/// **What a source may be asked to look up, and nothing else.** A name with no server is no
/// address: a source finds its own people by a plain search. An address of a post or of a
/// hashtag is none either — only a person is looked up this way. **A page's address is a link
/// a post's words could carry** (`PostLink`: https, a host, nobody's credentials), whose path
/// is the one name a server files a person under and no deeper.
public enum PersonAddress: Hashable, Sendable {
    /// `name@host`, with no mark before it and the host folded to the spelling an address has.
    case handle(String)
    /// The address of somebody's page, and the name it files them under.
    case page(PostLink, name: String)

    /// How long what was typed may be to be read as an address at all, in the bytes it is
    /// written in.
    public static let longest = 1_024

    /// The address `typed` is, with the space around it let go — or nothing where it is not
    /// one of a person.
    public init?(typed: String) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= Self.longest else { return nil }
        if let link = PostLink(text) {
            guard let name = Self.name(filedAt: link.url) else { return nil }
            self = .page(link, name: name)
            return
        }
        let bare = text.hasPrefix("@") ? String(text.dropFirst()) : text
        let parts = bare.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let host = Person.host(named: bare),
              let name = MastodonPerson.acct(of: String(parts[0]), at: ""), Self.isName(name)
        else { return nil }
        self = .handle(name + "@" + host)
    }

    /// The name a page's address files somebody under: `/@name` or `/users/name`, and nothing
    /// under it — a post of theirs is a step deeper, and is no person's address.
    private static func name(filedAt url: URL) -> String? {
        guard url.query() == nil, url.fragment() == nil else { return nil }
        let path = url.pathComponents
        let filed: String
        if path.count == 2, path[0] == "/", path[1].hasPrefix("@") {
            filed = String(path[1].dropFirst())
        } else if path.count == 3, path[0] == "/", path[1] == "users" {
            filed = path[2]
        } else {
            return nil
        }
        // A page may name them with their server after the name: the name is what comes first.
        let name = filed.split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return MastodonPerson.acct(of: name, at: "").flatMap { Self.isName($0) ? $0 : nil }
    }

    /// Whether `name` is spelled as a person's name at a server is: letters, digits, and the
    /// three marks a name may carry. Anything else — a slash, a colon — is part of some other
    /// address, and makes this none.
    private static func isName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" || $0 == "." || $0 == "-"
        }
    }

    /// What a source is asked for: the handle with its mark, or the page's address as typed.
    public var asked: String {
        switch self {
        case .handle(let handle): "@" + handle
        case .page(let link, _): link.text
        }
    }

    /// The address as a line of ours says it.
    public var shown: String { LineText.oneLine(asked, limit: 200) }

    /// The server the address names.
    public var host: String {
        switch self {
        case .handle(let handle): handle.split(separator: "@").last.map(String.init) ?? ""
        case .page(let link, _): link.host.lowercased()
        }
    }

    /// The name the address gives them, without a server.
    var name: String {
        switch self {
        case .handle(let handle): handle.split(separator: "@").first.map(String.init) ?? ""
        case .page(_, let name): name
        }
    }

    /// Whether `person` is who the address names, as far as an address says: **by the name**,
    /// whatever case it was typed in. A server may file somebody under another host's name
    /// than the one their address is at, so the host is not held against them — and whoever
    /// is shown the answer is shown the handle the source gave, not the one typed. Somebody
    /// the address names `exactly` is believed before anybody it names by the name alone.
    public func names(_ person: Person) -> Bool {
        let theirs = person.handle.dropFirst(person.handle.hasPrefix("@") ? 1 : 0)
            .split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return !theirs.isEmpty && theirs.lowercased() == name.lowercased()
    }

    /// How nearly somebody an answer lists is who the address names, the nearest first.
    enum Nearness: Int, Comparable {
        /// At the very address typed: the handle, or the page whose address their server gives.
        case typed
        /// Of the name a page's address gives, at the server that keeps the page.
        case server
        /// Of the name alone.
        case name

        static func < (one: Nearness, other: Nearness) -> Bool { one.rawValue < other.rawValue }
    }

    /// How nearly `person` — whose own server gives `page` as the address of their page — is
    /// who the address names, or nothing where it does not name them at all.
    func nearness(of person: Person, page: String?) -> Nearness? {
        switch self {
        case .handle:
            return exactly(person) ? .typed : names(person) ? .name : nil
        case .page(let link, _):
            if Self.isThePage(link, page) { return .typed }
            guard names(person) else { return nil }
            return person.home == host ? .server : .name
        }
    }

    /// Whether `said` is the address `link` is: the same server whatever case it is written
    /// in, the very path, and nothing after it.
    private static func isThePage(_ link: PostLink, _ said: String?) -> Bool {
        guard let theirs = said.flatMap(PostLink.init)?.url, theirs.query() == nil, theirs.fragment() == nil else { return false }
        return theirs.host()?.lowercased() == link.host.lowercased() && theirs.path() == link.url.path()
    }

    /// Whether `person` is at the very handle typed, name and server both, whatever case it
    /// was typed in. Never so for the address of a page: the server that keeps somebody's page
    /// need not be the one their handle names.
    public func exactly(_ person: Person) -> Bool {
        guard case .handle(let handle) = self else { return false }
        return person.handle.lowercased() == "@" + handle.lowercased()
    }
}

/// A Mastodon asked for what it has under some words (#176, #319): `/api/v2/search`.
///
/// **Asked of a real one first** (`MastodonSearchCaptures`). One ask with no kind named brings
/// the posts, the people and the hashtags together, each up to the length asked for; a kind
/// named brings that kind alone, and only then may a stretch begin further in.
///
/// **Signed in, or not at all.** A Mastodon answers a full-text search of its posts only to an
/// account it knows, and a signed-out ask comes back empty — which a search would then report as
/// a server with nothing to say. So there is no unsigned door here: a source this device is not
/// signed in to cannot be searched, and the search says so rather than asking.
///
/// **Unresolved, but for one ask.** Every ask here says `resolve=false`, so only what the
/// server already knows is asked for and it fetches nothing from a third server on this
/// device's behalf — except `resolved(_:source:)`, which is the person asking that source, by
/// name, to look somebody up. Nothing else here sends that word, and nothing sends it unasked.
/// (A post held without its source's id is found again by its address with that word too —
/// `MastodonPost.id(of:)`, which is not this type's and asks for a post, never a person.)
///
/// **A stranger's word, bounded where it enters.** People through the one reader an account has
/// (`AccountDTO.asPerson`), hashtags through the one reader a list of hashtags has
/// (`MastodonRising.listed`), each held to the length asked for however many a server sends.
public struct MastodonSearch: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v2/search"
    /// The most of one kind a Mastodon gives in one answer, and the most that is asked for.
    public static let longest = 40
    /// How long the words asked for may be: far more than anybody types, and far less than an
    /// address may carry.
    public static let wordsLength = 1_000
    /// The furthest into the people found a stretch is asked for: ten stretches. A stranger's
    /// list read on by a count is read on by a count of ours.
    public static let furthest = 400

    /// What every ask here sends: the words, bounded, as a value the address builder encodes.
    private static func asking(_ words: String, resolve: Bool = false) -> [URLQueryItem] {
        [
            URLQueryItem(name: "q", value: String(String.UnicodeScalarView(words.unicodeScalars.prefix(wordsLength)))),
            URLQueryItem(name: "resolve", value: resolve ? "true" : "false"),
        ]
    }

    private struct Found: Decodable, Sendable {
        typealias Lenient = StatusDTO.Lenient
        let statuses: Lenient<[Lenient<StatusDTO>]>?
        let accounts: Lenient<[Lenient<AccountDTO>]>?
        let hashtags: Lenient<[Lenient<MastodonRising.TagSaid>]>?
    }

    /// The posts, the people and the hashtags matching `words`, in one ask: each kind up to
    /// `longest`, in the source's order. The posts are stamped with `source` and arrive
    /// through no category: a search is not a timeline.
    ///
    /// **Entry by entry, and kind by kind**: a post, an account or a hashtag this build cannot
    /// read is that one not listed, and a kind sent in a shape it cannot read is that kind
    /// found empty — never the others lost with it. A body that is no answer at all throws.
    ///
    /// Throws `MastodonScopeError.outside` where the token cannot search.
    public func everything(matching words: String, source: Source) async throws -> SearchFinds {
        guard source.host == door.token.host else { throw MastodonRequestError.invalidURL }
        let sent = ReadMoment.now()
        let data = try await door.getInScope(
            path: Self.path, query: Self.asking(words) + [URLQueryItem(name: "limit", value: String(Self.longest))]
        )
        let found = try MastodonJSON.decoder.decode(Found.self, from: data)
        guard found.statuses != nil || found.accounts != nil || found.hashtags != nil else { throw MastodonPeopleError.unreadable }
        return SearchFinds(
            posts: (found.statuses?.value ?? []).prefix(Self.longest)
                .compactMap { $0.value?.asNote(source: source, categories: [], sent: sent) },
            people: Self.people(found.accounts?.value ?? [], source: source, most: Self.longest),
            tags: MastodonRising.listed(found.hashtags?.value ?? [], most: Self.longest)
        )
    }

    /// The people an answer listed, `most` at most, nobody twice.
    private static func people(_ said: [StatusDTO.Lenient<AccountDTO>], source: Source, most: Int) -> [Person] {
        var seen: Set<String> = []
        return said.prefix(most).compactMap { $0.value?.asPerson(source: source) }.filter { seen.insert($0.id).inserted }
    }

    /// The stretch of the people matching `words` that begins after `passed` of them — the
    /// first where that is none. **Read on by how many were passed over**, the only way on a
    /// search has: it names no next, so what this names as its next is how many have now been
    /// passed, or nothing where it gave nobody or `furthest` is reached.
    public func people(
        matching words: String, source: Source, after passed: Int = 0, limit: Int = MastodonSearch.longest
    ) async throws -> PeopleStretch {
        guard source.host == door.token.host, (0...Self.furthest).contains(passed) else { throw MastodonRequestError.invalidURL }
        let length = min(max(1, limit), Self.longest)
        var query = Self.asking(words) + [
            URLQueryItem(name: "type", value: "accounts"), URLQueryItem(name: "limit", value: String(length)),
        ]
        if passed > 0 { query.append(URLQueryItem(name: "offset", value: String(passed))) }
        let data = try await door.getInScope(path: Self.path, query: query)
        guard let said = (try? MastodonJSON.decoder.decode(Found.self, from: data))?.accounts?.value else {
            throw MastodonPeopleError.unreadable
        }
        let given = said.prefix(length)
        let reached = passed + given.count
        return PeopleStretch(
            people: Self.people(Array(given), source: source, most: length),
            next: given.isEmpty || reached >= Self.furthest ? nil : String(reached)
        )
    }

    /// How many people a next names as passed over, or nothing where it is not such a count:
    /// what `people(matching:source:after:limit:)` handed back, read again.
    public static func passed(_ next: String) -> Int? {
        guard !next.isEmpty, next.utf8.count <= 3, next.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(next).flatMap { (1...furthest).contains($0) ? $0 : nil }
    }

    /// How many answers a look-up reads for the one it asked for.
    static let lookedAt = 5

    /// **The one ask for a person that says `resolve=true`**: this source asked to look `address` up — of
    /// its own people, of those it has heard of, and, where it has not, of whichever server
    /// the address names, which is the source's own doing and in its own name. Made only
    /// because the person pressed for it, of the source they chose.
    ///
    /// Only a person is asked for, and an answer about anybody the address does not name is
    /// not believed: **whoever is at the very address typed, wherever the answer lists them** —
    /// the handle, or the page whose address their own server gives; then, for a page, whoever
    /// of that name is at the server that keeps it; and only where nobody is, the first of the
    /// name alone, handed back as not at the address typed. Throws
    /// `PersonReadError.unheardOf` where the source found nobody of that address — it does not
    /// say whether it asked their server, or what that said — and `MastodonScopeError.outside`
    /// where the token cannot search.
    public func resolved(_ address: PersonAddress, source: Source) async throws -> PersonLookedUp {
        guard source.host == door.token.host else { throw MastodonRequestError.invalidURL }
        let data = try await door.getInScope(path: Self.path, query: Self.asking(address.asked, resolve: true) + [
            URLQueryItem(name: "type", value: "accounts"), URLQueryItem(name: "limit", value: String(Self.lookedAt)),
        ])
        guard let said = (try? MastodonJSON.decoder.decode(Found.self, from: data))?.accounts?.value else {
            throw PersonReadError.unreadable
        }
        let named = said.prefix(Self.lookedAt).compactMap { entry -> (person: Person, near: PersonAddress.Nearness)? in
            guard let account = entry.value, let person = account.asPerson(source: source),
                  let near = address.nearness(of: person, page: account.url?.value)
            else { return nil }
            return (person, near)
        }
        // The nearest, and of two as near the one the source listed first.
        guard let found = named.min(by: { $0.near < $1.near }) else { throw PersonReadError.unheardOf }
        return PersonLookedUp(person: found.person, asTyped: found.near != .name)
    }

    /// What a search pattern (#32) sends a server: its words, with `*` and `?` let go — a server
    /// has its own idea of matching, and what comes back is matched against the pattern here
    /// anyway. Nil where nothing but wildcards and spaces is left.
    ///
    /// **A wildcard in any width.** The pattern is matched folded (`Fold.key`), so `＊` and `？`
    /// are wildcards there too, and sending one to a server would ask it for a full-width star.
    public static func words(of pattern: String) -> String? {
        let words = String(pattern.map { isWildcard($0) ? " " : $0 })
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    private static func isWildcard(_ character: Character) -> Bool {
        let folded = String(character).folding(options: .widthInsensitive, locale: nil)
        return folded == "*" || folded == "?"
    }
}
