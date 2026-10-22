import Foundation

// The posts a Mastodon says share a link rising on it (#379): `timelines/link`, a stretch at a
// time, read on by the source's own word for what is next.
//
// **Asked of a real one first** (`MastodonLinkPostsCaptures`). The address came with the API
// version the host's document names (`MastodonHostThing.linkPosts`); a host older than that
// answers the address with a page of its own, which is the host having no such address. A host
// that has it lists a link's posts only while the link is rising there: of any other address —
// one never rising, one no longer, none at all — it answers a not-found of the record, and that
// is this link not listed, never the host lacking the address.
//
// **Newest first, and only what it shows anyone.** A source lists the public posts that carry
// the link, of people who chose to be found, newest first; nothing in the answer says what it
// left out.
//
// **Nothing here writes anywhere on this device** (`PostStretch`): a read lands in what it
// returns, and one that is refused or fails throws and changes nothing.

/// Why the posts sharing a link could not be read at a source that has the address.
public enum LinkPostsError: Error, Equatable, Sendable {
    /// The source lists no posts of this link: it is not, or no longer, one rising there.
    case notListed
    /// The source answered, and not with posts: a body that is no list of them, or a way on
    /// that names no place to go on from.
    case unreadable
}

/// A Mastodon asked for the posts that share one link rising on it.
///
/// **As the reader where signed in, unsigned otherwise**, as a hashtag is read (`MastodonTag`):
/// a source gives them to anyone. Whoever reads unsigned hands in a client that is watched and
/// admitted — in the app, `SourceReach.unsignedLinkPosts`, never a bare `URLSessionClient()`.
public struct MastodonLinkPosts: Sendable {
    private let door: MastodonReading

    /// Unsigned, as the public timeline is read.
    public init(http: any HTTPClient, host: String) {
        door = MastodonReading(http: http, host: host)
    }

    /// As the reader, through the one signed-in door.
    public init(door: MastodonAuthorized) {
        self.door = MastodonReading(door: door)
    }

    static let path = "/api/v1/timelines/link"
    /// How many are asked for at a time: the most a Mastodon gives.
    public static let stretch = 40

    /// The newest stretch of the posts `source` says share `link`, or with `next` the stretch
    /// older than the one that handed it back.
    ///
    /// **Asked by the address as the source wrote it** — the link as its list of what is rising
    /// gave it — since it finds the link by that and by nothing else.
    ///
    /// Throws `MastodonHostMoreError.noSuchAddress` where the host has no such address,
    /// `LinkPostsError.notListed` where it lists no posts of this link (a not-found of the record;
    /// a refusal, 422 among them, is the door's and says nothing of the link), `PagingError.notPaging`
    /// where the way on names the place just read, and what the door throws for anything else.
    /// **Entry by entry**: a post this build cannot read is that one post not listed, and never
    /// the stretch.
    public func posts(sharing link: PostLink, source: Source, after next: String? = nil) async throws -> PostStretch {
        guard source.host.lowercased() == door.host else { throw MastodonRequestError.invalidURL }
        let query = [URLQueryItem(name: "url", value: link.text), URLQueryItem(name: "limit", value: String(Self.stretch))]
            + (try MastodonPage.older(than: next))
        let sent = ReadMoment.now()
        let (body, header): (Data, String?)
        do {
            (body, header) = try await door.getAtAddress(path: Self.path, query: query)
        } catch where Self.isNotListed(error) {
            throw LinkPostsError.notListed
        }
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<StatusDTO>].self, from: body) else {
            throw LinkPostsError.unreadable
        }
        let onward: String?
        do {
            onward = try MastodonLink.next(in: header)
        } catch {
            throw LinkPostsError.unreadable
        }
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        let arrived = read.compactMap(\.value).map { $0.arrival(source: source, categories: [], sent: sent) }
        return PostStretch(posts: arrived.map(\.item), carried: arrived.compactMap(\.reblogged), next: onward)
    }

    /// Whether `error` is the source saying it lists no posts of the link asked by: a not-found
    /// of the record, by either way out.
    private static func isNotListed(_ error: any Error) -> Bool {
        MastodonReading.notFound(error)
    }
}
