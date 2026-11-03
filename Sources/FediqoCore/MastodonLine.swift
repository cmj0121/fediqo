import Foundation
import os

// What a signed-in Mastodon tells on the reader's own line, as it happens (#325).
//
// **One line a source: the reader's own** (`/api/v1/streaming/user`). Mastodon tells on it every
// post that lands in Home, every one of them changed, and every one deleted — and, to a sign-in
// that reads notices, each notice (`MastodonLineCaptures`), which #324 may hear on the same line.
// Lists and the public timeline each want a line of their own, and are read as they always were.
//
// **Direct posts have a line of their own too** (#427): the reader's own line never says
// `conversation`, only the direct line does (`/api/v1/streaming/direct`, `MastodonLiveCaptures`).
// **What an announcement does is said on the reader's own line. A filter changing is said on
// neither** at the Mastodon this was asked of: `filters_changed` has no payload, and its streaming
// service sends nothing without one. What a post caught is on each post that arrives (`filtered`).
//
// **Only to the token's own host.** The line is asked of the source at the address every other ask
// of it goes to, through the source's proxy, as the fixture's Caddy and the usual one in front of a
// Mastodon route it. Where the instance names another host for it (`configuration.urls.streaming`)
// the token is not sent there: a source with no line at its own address answers no 2xx, and is read
// as it always was.
//
// **What arrives lands as a read of Home lands it.** A post is the item Home lists, under the id
// Home lists it by (`StatusDTO.listed`), taken in by `ItemStore.ingest` — one row with what any
// read brought of it, never a second. A post changed lands over the row held, and only a row held:
// the line says nothing of where a post that is not held belongs. A post deleted is marked gone as a
// read that heard its source say so marks it (`ItemStore.markGone`). And nothing the line says
// moves where a timeline is said not to be whole: a post told on a line was not read on to.

/// A line refused by its source: its answer, which was no 2xx. Nothing is changed for it.
public struct MastodonLineRefused: Error, Equatable, Sendable {
    public let status: Int

    public init(status: Int) {
        self.status = status
    }
}

/// The reader's own line at one signed-in Mastodon.
public struct MastodonLine: Sendable {
    public let token: MastodonToken
    private let opener: any LineOpener

    public init(token: MastodonToken, opener: any LineOpener) {
        self.token = token
        self.opener = opener
    }

    static let userPath = "/api/v1/streaming/user"
    static let directPath = "/api/v1/streaming/direct"

    /// Opens the line and returns once the source has answered — which is when it is open, and
    /// from when what it tells is heard. Throws `MastodonLineRefused` where the answer was no 2xx,
    /// and whatever the network threw where none came.
    ///
    /// **A refusal signs nobody out**, a 401 included: a sign-in is ended where a read's answer and
    /// the account check both say so (`MastodonAuthorized`), and a line is not a read.
    public func open() async throws -> AsyncThrowingStream<LineEvent, any Error> {
        try await open(path: Self.userPath)
    }

    /// The direct line (#427), opened and refused as the reader's own is. It tells `conversation`.
    public func openDirect() async throws -> AsyncThrowingStream<LineEvent, any Error> {
        try await open(path: Self.directPath)
    }

    func open(path: String, query: [URLQueryItem] = []) async throws -> AsyncThrowingStream<LineEvent, any Error> {
        guard let base = Host.httpsURL(host: token.host, path: path),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url, url.host() == base.host(), url.path() == base.path() else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let line = try await opener.open(request)
        guard (200..<300).contains(line.response.statusCode) else {
            NetLog.network.notice(
                "\(NetLog.line("line", host: token.host, status: line.response.statusCode), privacy: .public)"
            )
            throw MastodonLineRefused(status: line.response.statusCode)
        }
        return line.events
    }
}

/// What one event of the reader's own line did to what this device holds.
public enum MastodonLineLanded: Equatable, Sendable {
    /// A post landed in Home: `fresh` where it is new here, and otherwise the row held taking
    /// what it now says.
    case arrived(NoteKey, fresh: Bool)
    /// A post held changed at its source, and the row says so.
    case changed(NoteKey)
    /// What the source deleted, marked gone: the rows of it held.
    case gone([NoteKey])
    /// An event of a kind Home does not take — a notice, an announcement — or of a post not held.
    case passed
    /// An event whose words would not read. Nothing changed.
    case unreadable
}

extension MastodonLine {
    /// The events this source tells that land in Home.
    public static let homeEvents: Set<String> = ["update", "status.update", "delete"]
    /// The events that say an announcement came, changed, was reacted to or went. Each carries
    /// less than the source's own read does (`me` is always false on a reaction).
    public static let announcementEvents: Set<String> = ["announcement", "announcement.reaction", "announcement.delete"]
    /// The event that would say the person's filters changed elsewhere.
    public static let filtersEvent = "filters_changed"
    /// The event of the direct line that says a conversation has something new.
    public static let conversationEvent = "conversation"

    /// `event` landed as a read of Home would land it — or of `category`, a list or the public
    /// timeline (#460), or of no category as a hashtag's page lands a post (#124) — while `source`
    /// is still here.
    public static func land(
        _ event: LineEvent, of source: Source, as category: Category? = .home, in store: ItemStore
    ) async -> MastodonLineLanded {
        await land([event], of: source, as: category, in: store)[0]
    }

    /// An event that is no new post, landed: a change, a deletion, or nothing.
    private static func landOther(_ event: LineEvent, of stamp: Source, in store: ItemStore) async -> MastodonLineLanded {
        let host = stamp.host
        switch event.name {
        case "status.update":
            guard let status = decode(event.data) else { return .unreadable }
            let item = status.arrival(source: stamp, categories: [], sent: ReadMoment.now()).item
            guard await store.note(item.key) != nil else { return .passed }
            await store.ingest([item], ifSourceHere: host)
            return .changed(item.key)
        case "delete":
            let id = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return .unreadable }
            return .gone(await store.markGone(host: host, statusID: id))
        default:
            return .passed
        }
    }

    /// `events`, each landed as `land(_:of:in:)` lands it and in the order told — but **posts that
    /// arrive one after another go in together** (#458): one landing, so one change of the store and
    /// one redraw for a burst, where each alone would be one each. A change or a deletion between
    /// them lands in its place, after the posts told before it. One result an event, in order.
    public static func land(
        _ events: [LineEvent], of source: Source, as category: Category? = .home, in store: ItemStore
    ) async -> [MastodonLineLanded] {
        let host = source.host
        let stamp = Source(host: host, kind: source.kind)
        var landed = [MastodonLineLanded](repeating: .passed, count: events.count)
        // The posts waiting to go in together: where each one's result goes, and what it brings.
        var gathered: [(at: Int, key: NoteKey, notes: [Note])] = []
        func putIn() async {
            guard !gathered.isEmpty else { return }
            let held = await store.notes(gathered.map(\.key))
            var seen: Set<NoteKey> = []
            for post in gathered {
                landed[post.at] = .arrived(post.key, fresh: seen.insert(post.key).inserted && held[post.key] == nil)
            }
            await store.ingest(gathered.flatMap(\.notes), ifSourceHere: host)
            gathered = []
        }
        for (at, event) in events.enumerated() {
            guard event.name == "update" else {
                await putIn()
                landed[at] = await landOther(event, of: stamp, in: store)
                continue
            }
            guard let status = decode(event.data) else {
                landed[at] = .unreadable
                continue
            }
            let (key, notes) = arrived(status, of: stamp, as: category)
            gathered.append((at, key, notes))
        }
        await putIn()
        return landed
    }

    /// A post told as arriving through `category`: listed there under the id the timeline lists it
    /// by, with what it reblogs beside it — or, through none, the post itself as a tag's page holds
    /// it (`MastodonTag.posts`).
    private static func arrived(_ status: StatusDTO, of source: Source, as category: Category?) -> (NoteKey, [Note]) {
        guard let category else {
            let note = status.asNote(source: source, categories: [], sent: ReadMoment.now())
            return (note.key, [note])
        }
        let listed = status.listed(source: source, category: category, sent: ReadMoment.now())
        return (listed.note.key, [listed.note] + listed.carried)
    }

    private static func decode(_ data: String) -> StatusDTO? {
        do {
            return try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(data.utf8))
        } catch {
            NetLog.network.error("\(NetLog.line("line event", host: "", error: error), privacy: .public)")
            return nil
        }
    }
}
