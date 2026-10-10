import Foundation

// What a Mastodon host says of itself beyond its one document (#321): its longer account of
// itself, the servers it knows, and how busy it has been, week by week.
//
// **Asked of a real one first** (`MastodonHostMoreCaptures`). All three are given to anyone, so
// they are asked with no sign-in. A longer account never written is present and empty; the
// servers it knows are bare names and nothing else; every figure of a week is a string. Two of
// the three can be switched off by whoever runs the host, and then answer a not-found of their
// own address — which is how each is known absent (`MastodonHostNotFound`), and the only way.
//
// **A stranger's word, bounded where it enters.** The longer account is markup an administrator
// wrote: cut to length, then taken out of its markup, then made lines that can stand on a page
// of ours. A server it knows is **a name and never a place to go**: held to the letters a
// host's name is made of, kept as text, never parsed into an address — nothing here, and
// nothing that reads this, asks one of them anything (#282). A figure is a count or it is not
// said: never less than none, never past what a count can be.

/// A figure a host gives of itself, read leniently: a number, or — as a Mastodon sends every
/// figure of a week and of what is rising — a number written as a string. Nothing where it is
/// neither, less than none, or past `most`.
struct MastodonFigure: Decodable, Sendable {
    let value: Int?

    /// The most a figure is believed to be. A stranger's number: past this it is not a count of
    /// anything, and it is not said.
    static let most = 1_000_000_000_000

    init(from decoder: any Decoder) throws {
        let container = try? decoder.singleValueContainer()
        if let number = try? container?.decode(Int.self) {
            value = Self.held(number)
        } else if let written = try? container?.decode(String.self) {
            value = Self.read(written)
        } else {
            value = nil
        }
    }

    /// A figure written as digits and nothing else — no sign, no space, no more digits than a
    /// count has.
    static func read(_ written: String) -> Int? {
        guard !written.isEmpty, written.utf8.count <= 15, written.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return Int(written).flatMap(held)
    }

    private static func held(_ number: Int) -> Int? {
        (0...most).contains(number) ? number : nil
    }
}

/// A host's longer account of itself, as words: what its administrator wrote, out of its markup.
public struct HostAccount: Sendable, Hashable {
    /// Its paragraphs, in order, each fit to stand on a page of ours. None where the host has
    /// written no longer account — which a host answers as readily as one it has.
    public let paragraphs: [String]
    /// Whether what the host sent ran past what is kept, so this is the beginning of it.
    public let cut: Bool
    /// When the host says it was last written, where it says.
    public let updated: Date?

    /// How much of it is kept, in characters as a reader counts them, and in paragraphs.
    public static let length = 12_000
    public static let paragraphCount = 200

    public init(paragraphs: [String], cut: Bool = false, updated: Date? = nil) {
        self.paragraphs = paragraphs
        self.cut = cut
        self.updated = updated
    }

    /// Out of the markup a host sent. **Cut before the markup is taken out** — taking it out
    /// costs more than its length — at a place no tag or entity is cut through; then each line
    /// is cleaned of what turns a line round or hides in it, and bounded.
    init(markup: String, updated: Date? = nil) {
        // A few times what is kept: markup is most of a link.
        let read = AccountDTO.cut(markup, to: Self.length * 4)
        var kept = 0
        var cut = read.unicodeScalars.count < markup.unicodeScalars.count
        var paragraphs: [String] = []
        // A heading, an entry of a list and a row end a line, as a paragraph does.
        let broken = read.replacingOccurrences(
            of: "</(h[1-6]|li|tr|blockquote)>", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        for line in HTMLText.plain(broken).split(whereSeparator: \.isNewline) {
            guard paragraphs.count < Self.paragraphCount, kept < Self.length else {
                cut = true
                break
            }
            let room = Self.length - kept
            let clean = LineText.oneLine(String(line), limit: room)
            guard !clean.isEmpty else { continue }
            if clean.count > room { cut = true }
            kept += clean.count
            paragraphs.append(clean)
        }
        self.init(paragraphs: paragraphs, cut: cut, updated: updated)
    }
}

/// The servers a host says it knows: how many it named, and the first of their names.
///
/// **Names, and nothing to press.** Each is a stranger's word about another host: kept as text
/// in the letters a host's name is made of, and never made an address.
public struct HostServers: Sendable, Hashable {
    /// How many the host named — its figure, entries it gave that are no name among them.
    public let counted: Int
    /// The first `kept` of them that are names, in the order the host gave them.
    public let names: [String]

    /// How many names are held of one host's answer.
    public static let kept = 2_000
    /// How long a host's name may be.
    static let nameLength = 253

    public init(counted: Int, names: [String]) {
        self.counted = max(0, counted)
        self.names = Array(names.prefix(Self.kept))
    }

    /// A name as a host gave it, or nothing where it is not one: folded to lower case, in the
    /// letters, digits, dots and hyphens a name on the wire is written in, beginning with
    /// neither a dot nor a hyphen, and no longer than a name is. A name not in ASCII is its
    /// punycode on the wire; anything else — a port, a path, a space, a letter that only looks
    /// like one — is not kept.
    static func name(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= nameLength else { return nil }
        let folded = raw.lowercased()
        guard let first = folded.utf8.first, first != UInt8(ascii: "."), first != UInt8(ascii: "-"),
              folded.utf8.allSatisfy(Self.written)
        else { return nil }
        return folded
    }

    private static func written(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }
}

/// One week of how busy a host says it has been.
public struct HostWeek: Sendable, Hashable {
    /// The moment the host names the week by.
    public let week: Date
    /// The posts written there that week, the people who signed in, and the people who joined
    /// — each as the host counts it, or nothing where it did not say.
    public let posts: Int?
    public let signIns: Int?
    public let newPeople: Int?

    /// How many weeks are kept of one answer: a Mastodon gives twelve.
    public static let kept = 53

    public init(week: Date, posts: Int? = nil, signIns: Int? = nil, newPeople: Int? = nil) {
        self.week = week
        self.posts = posts
        self.signIns = signIns
        self.newPeople = newPeople
    }
}

/// What a read of these could not make anything of.
public enum MastodonHostMoreError: Error, Equatable, Sendable {
    /// The host answered that it has no such address: the thing is not there to ask for
    /// (`MastodonHostNotFound.isOfTheAddress`). Not a failure — whoever asked remembers it.
    case noSuchAddress
    /// The host answered, and not with what was asked for.
    case unreadable
}

/// A Mastodon asked for what it says of itself beyond its document: `instance/extended_description`,
/// `instance/peers` and `instance/activity`, each with no sign-in.
///
/// **Whoever reads hands in a client that is watched, admitted and small** — in the app, one
/// made by `SourceReach.unsignedHost`, never a bare `URLSessionClient()`.
///
/// **Nothing here writes anywhere on this device**, and nothing here is remembered: a read lands
/// in what it returns, and what a not-found means for the rest of the run is its caller's to
/// keep (`MastodonHostsKnown`).
public struct MastodonHostMore: Sendable {
    private let http: any HTTPClient
    private let host: String

    public init(http: any HTTPClient, host: String) {
        self.http = http
        self.host = host
    }

    static let accountPath = "/api/v1/instance/extended_description"
    static let serversPath = "/api/v1/instance/peers"
    static let activityPath = "/api/v1/instance/activity"

    /// Its longer account of itself. One never written is an account with no paragraphs.
    public func longerAccount() async throws -> HostAccount {
        struct Wire: Decodable {
            let content: StatusDTO.Lenient<String>?
            let updatedAt: StatusDTO.LenientMoment?
        }
        let body = try await get(Self.accountPath)
        guard let wire = try? MastodonJSON.decoder.decode(Wire.self, from: body) else {
            throw MastodonHostMoreError.unreadable
        }
        return HostAccount(markup: wire.content?.value ?? "", updated: wire.updatedAt?.value)
    }

    /// The servers it knows. **Entry by entry**: one that is no name costs that entry, and is
    /// still counted as one the host named.
    public func knownServers() async throws -> HostServers {
        let body = try await get(Self.serversPath)
        guard let wire = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<String>].self, from: body) else {
            throw MastodonHostMoreError.unreadable
        }
        var names: [String] = []
        for entry in wire {
            guard names.count < HostServers.kept else { break }
            if let name = entry.value.flatMap(HostServers.name) { names.append(name) }
        }
        return HostServers(counted: wire.count, names: names)
    }

    /// How busy it has been, newest week first. **Entry by entry**: a week named by no moment
    /// is that week not listed, and a figure that is no count is that figure not said.
    public func activity() async throws -> [HostWeek] {
        struct Wire: Decodable, Sendable {
            let week: MastodonFigure?
            let statuses: MastodonFigure?
            let logins: MastodonFigure?
            let registrations: MastodonFigure?
        }
        let body = try await get(Self.activityPath)
        guard let wire = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<Wire>].self, from: body) else {
            throw MastodonHostMoreError.unreadable
        }
        let weeks = wire.prefix(HostWeek.kept * 4).compactMap { entry -> HostWeek? in
            guard let said = entry.value, let moment = said.week?.value, Self.weekRange.contains(moment) else { return nil }
            return HostWeek(
                week: Date(timeIntervalSince1970: TimeInterval(moment)), posts: said.statuses?.value,
                signIns: said.logins?.value, newPeople: said.registrations?.value
            )
        }
        return Array(weeks.sorted { $0.week > $1.week }.prefix(HostWeek.kept))
    }

    /// The moments a week may be named by, in seconds: this century's.
    static let weekRange = 946_684_800...4_102_444_800

    /// One of the three, fetched: `noSuchAddress` where the host says the address is not there,
    /// and what an unsigned read throws for any other refusal.
    private func get(_ path: String) async throws -> Data {
        guard let url = Host.httpsURL(host: host, path: path) else { throw MastodonRequestError.invalidURL }
        let (body, response) = try await http.data(from: url)
        if MastodonHostNotFound.isOfTheAddress(status: response.statusCode, body: body) {
            throw MastodonHostMoreError.noSuchAddress
        }
        guard (200..<300).contains(response.statusCode) else { throw MastodonRequestError.http(response.statusCode) }
        return body
    }
}
