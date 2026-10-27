import Foundation
import os

// What a signed-in Mastodon tells on the reader's own line, as it happens (#325).
//
// **One line a source: the reader's own** (`/api/v1/streaming/user`). Mastodon tells on it every
// post that lands in Home, every one of them changed, and every one deleted — and, to a sign-in
// that reads notices, each notice (`MastodonLineCaptures`), which #324 may hear on the same line.
// Lists and the public timeline each want a line of their own, and are read as they always were.
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

    /// Opens the line and returns once the source has answered — which is when it is open, and
    /// from when what it tells is heard. Throws `MastodonLineRefused` where the answer was no 2xx,
    /// and whatever the network threw where none came.
    ///
    /// **A refusal signs nobody out**, a 401 included: a sign-in is ended where a read's answer and
    /// the account check both say so (`MastodonAuthorized`), and a line is not a read.
    public func open() async throws -> AsyncThrowingStream<LineEvent, any Error> {
        guard let url = Host.httpsURL(host: token.host, path: Self.userPath) else { throw URLError(.badURL) }
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

    /// `event` landed as a read of Home would land it, while `source` is still here.
    public static func land(_ event: LineEvent, of source: Source, in store: ItemStore) async -> MastodonLineLanded {
        let host = source.host
        let stamp = Source(host: host, kind: source.kind)
        switch event.name {
        case "update":
            guard let status = decode(event.data) else { return .unreadable }
            let listed = status.listed(source: stamp, category: .home, sent: ReadMoment.now())
            let fresh = await store.note(listed.note.key) == nil
            await store.ingest([listed.note] + listed.carried, ifSourceHere: host)
            return .arrived(listed.note.key, fresh: fresh)
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

    private static func decode(_ data: String) -> StatusDTO? {
        do {
            return try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(data.utf8))
        } catch {
            NetLog.network.error("\(NetLog.line("line event", host: "", error: error), privacy: .public)")
            return nil
        }
    }
}
