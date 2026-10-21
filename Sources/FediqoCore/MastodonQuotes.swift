import Foundation

// A quote written, who may quote a post, and the quotes of one's own post (#330), as a real
// Mastodon answers them (4.6.6, API 11 — `MastodonQuoteWriteCaptures`).
//
// **What may be quoted is the quoted post's word**, `quote_approval`: who quoting it is let
// through without asking (`automatic`), who is asked first (`manual`), and what that means for
// whoever read it (`current_user`) — `unknown` read as `denied`, and an unsigned read is always
// told `denied`. **A post only its followers may read is quoted by nobody but its author** (asked
// of a real one: its policy stays "nobody" whatever it is set to), and the author's own quote of
// it is made followers-only by the server.
//
// **A quote carries no media and no poll** (D3): refused here, before anything is sent — the real
// server answers a quote with a poll with a failure of its own (500).
//
// **Not every host has quotes**, and the host says which in its own account of itself:
// `api_versions.mastodon` of 7 or more (`MastodonHostThing.quotes`).

/// Who may quote a post, as it is asked for when the post is written and changed after.
public enum QuotePolicy: String, Hashable, Sendable, CaseIterable {
    /// Anyone, without asking.
    case anyone = "public"
    /// The author's followers, without asking.
    case followers
    /// Nobody but the author.
    case nobody
}

/// Who may quote a post (#330), as its source says: the post's own facts. Whether the reader may
/// is the reader's (`Note.mayQuote`), and kept apart.
public struct QuoteApproval: Hashable, Sendable {
    /// What the source says the reader who read it may do.
    public enum Reader: String, Hashable, Sendable {
        /// Quote it, without asking.
        case automatic
        /// Quote it, the author asked first: the quote waits until they answer.
        case manual
        /// Not quote it — and what an `unknown`, or a word this build does not know, is read as.
        case denied
    }

    /// Who is let through without asking, and who is asked first, as the source spells them.
    public let automatic: [String]
    public let manual: [String]

    public init(automatic: [String] = [], manual: [String] = []) {
        self.automatic = automatic
        self.manual = manual
    }

    /// The policy these say, as the composer and the post's `…` offer it: anyone where the
    /// public is let through, the followers where only they are, nobody where nobody is.
    public var policy: QuotePolicy {
        if automatic.contains("public") || manual.contains("public") { return .anyone }
        if automatic.contains("followers") || manual.contains("followers") { return .followers }
        return .nobody
    }

    /// How many words of each list are kept, each a short word.
    static let listed = 8
    static let wordLength = 32

    /// A list as it is kept, whoever wrote it — the wire or a store: no empty word, none longer
    /// than a word is, and no more of them than are kept.
    public static func kept(_ words: [String]) -> [String] {
        Array(words.filter { !$0.isEmpty && $0.utf8.count <= wordLength }.prefix(listed))
    }
}

extension StatusDTO {
    /// Mastodon's `QuoteApproval`, read leniently: a list or a word of another shape costs it.
    struct QuoteApprovalDTO: Decodable, Sendable {
        let automatic: Lenient<[Lenient<String>]>?
        let manual: Lenient<[Lenient<String>]>?
        let currentUser: Lenient<String>?

        var approval: QuoteApproval {
            func words(_ list: Lenient<[Lenient<String>]>?) -> [String] {
                QuoteApproval.kept((list?.value ?? []).compactMap { $0.value })
            }
            return QuoteApproval(automatic: words(automatic), manual: words(manual))
        }

        /// What it says to whoever read it: `unknown`, and any word this build does not know, as denied.
        var reader: QuoteApproval.Reader {
            currentUser?.value.flatMap(QuoteApproval.Reader.init(rawValue:)) ?? .denied
        }
    }
}

/// Why a quote, a policy or a revoke was not made.
public enum MastodonQuoteError: Error, Equatable, Sendable {
    /// A quote with media or a poll (D3), refused before anything was sent.
    case carries
    /// The post to quote, or to change, or the quote to revoke, cannot be named on this source.
    case unfindable
    /// The source would not let the reader quote the post (its own words: the post "does not
    /// appear to exist" — what a real one answers a quote it does not allow).
    case notAllowed
    /// The source answered, and not with a post.
    case unreadable
}

/// The quotes of one's own post (#330), read on a stretch at a time by the source's own next.
///
/// **As the reader, and only so**: a real Mastodon answers an unsigned ask with 401.
public struct MastodonQuotes: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    /// The first stretch of the posts quoting `note`, or with `next` the stretch after.
    public func quotes(of note: Note, after next: String? = nil, limit: Int? = nil) async throws -> PostStretch {
        guard let id = MastodonWrite.pathID(of: note, at: door.token.host) else { throw MastodonQuoteError.unfindable }
        let length = limit.map { [URLQueryItem(name: "limit", value: String(max(1, $0)))] } ?? []
        let sent = ReadMoment.now()
        let (body, link) = try await door.getLinked(
            path: "/api/v1/statuses/\(id)/quotes", query: length + (try MastodonPage.older(than: next))
        )
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<StatusDTO>].self, from: body) else {
            throw MastodonQuoteError.unreadable
        }
        let onward = try MastodonLink.next(in: link)
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        let arrived = read.compactMap(\.value).map { $0.arrival(source: note.source, categories: [], sent: sent) }
        return PostStretch(posts: arrived.map(\.item), carried: arrived.compactMap(\.reblogged), next: onward)
    }
}

extension MastodonWrite {
    /// A quote by the id its source gave the post it quotes (a waiting quote's, #333): the form it
    /// adds to a post. **Refused where it carries media or a poll** (D3), and where the id names
    /// no post a Mastodon would.
    static func quoting(id: String?, mediaIDs: [String], poll: NewPoll?) throws -> [(String, String)] {
        guard let id else { return [] }
        if poll != nil || mediaIDs.contains(where: { !$0.isEmpty }) { throw MastodonQuoteError.carries }
        guard isDigits(id) else { throw MastodonQuoteError.unfindable }
        return [("quoted_status_id", id)]
    }

    /// The form a quote adds to a post: the quoted post by its own id, at the same source.
    /// **Refused where it carries media or a poll** (D3), and where the quoted post cannot be
    /// named there.
    static func quoting(_ quoted: Note?, host: String, mediaIDs: [String], poll: NewPoll?) throws -> [(String, String)] {
        guard let quoted else { return [] }
        if poll != nil || mediaIDs.contains(where: { !$0.isEmpty }) { throw MastodonQuoteError.carries }
        guard let id = pathID(of: quoted, at: host) else { throw MastodonQuoteError.unfindable }
        return [("quoted_status_id", id)]
    }

    /// The id a quote of `quoted` sends it by, at this source (`postLater`'s `quoting`), or
    /// `MastodonQuoteError.unfindable` where it cannot be named here.
    public func quotedID(of quoted: Note) throws -> String {
        guard let id = Self.pathID(of: quoted, at: host) else { throw MastodonQuoteError.unfindable }
        return id
    }

    /// Who may quote the reader's own `note` from now on (#330), and the post as the source answers
    /// — laid over the row as a read of it is. Quotes made already stay.
    @discardableResult
    public func quotePolicy(of note: Note, to policy: QuotePolicy) async throws -> Note {
        let id = try await ownID(of: note, unfindable: MastodonQuoteError.unfindable)
        let sent = ReadMoment.now()
        let data = try await door.put(path: "/api/v1/statuses/\(id)/interaction_policy", form: [("quote_approval_policy", policy.rawValue)])
        return await settle(try landed(data, on: note, sent: sent, unreadable: MastodonQuoteError.unreadable), on: note, acted: .quotePolicy)
    }

    /// Takes back `quoting`'s permission to quote the reader's own `quoted` (#330): the quoting
    /// post, as the source answers it — its quote now `revoked` — laid over the row where one is
    /// held. Taken back again, it is answered the same.
    @discardableResult
    public func withdrawQuote(_ quoting: Note, of quoted: Note) async throws -> Note {
        let id = try await ownID(of: quoted, unfindable: MastodonQuoteError.unfindable)
        guard let quotingID = Self.pathID(of: quoting, at: host) else { throw MastodonQuoteError.unfindable }
        let sent = ReadMoment.now()
        let data = try await door.post(path: "/api/v1/statuses/\(id)/quotes/\(quotingID)/revoke", form: [])
        return await settle(try landed(data, on: quoting, sent: sent, unreadable: MastodonQuoteError.unreadable), on: quoting, acted: .quoteState)
    }
}
