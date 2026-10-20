import Foundation

/// A Mastodon read this device could not make a list of blocked servers of (#314).
public enum MastodonBlocksError: Error, Equatable, Sendable {
    /// The server answered, and not with a list of names: a body that is no list, or a way on
    /// that names no place to go on from.
    case unreadable
}

/// One stretch of the servers the reader blocks, as one source handed it over.
public struct ServersStretch: Hashable, Sendable {
    /// Each a host, in the source's own order: the newest block first.
    public let servers: [String]
    /// What the next stretch is asked by: the source's own word for where this one stopped.
    /// Nothing where it named no next.
    public let next: String?

    public init(servers: [String], next: String?) {
        self.servers = servers
        self.next = next
    }
}

/// A Mastodon asked which whole servers the reader blocks, and to block one or stop (#314):
/// `/api/v1/domain_blocks`, read a stretch at a time, posted to and deleted from.
///
/// **Asked of a real one first** (`MastodonBlocksCaptures`). The list is the reader's own, so
/// everything here goes **through the one signed-in door**, which sends the token to its own host
/// and nowhere else.
///
/// **A server is named by its host, and by nothing else.** Going out, a name that is no host —
/// an address, a path, a space — is refused before anything is asked: the source would take a
/// name it cannot read as no block at all, or refuse it. Coming back, an entry that is no host is
/// that one entry not listed, never the stretch.
///
/// **Read on by the source's own word and no other**, as a list of people is (`MastodonLink`):
/// the stretch is in the order the blocks were made, under ids of the blocks, and only the
/// answer's `Link` header says where the next begins.
///
/// **Blocking twice and taking back a block that is not there each answer as done**, with an
/// empty object (asked of a real one), so the answer says nothing of how it stands: whoever
/// asks reads the list, or how the reader stands to somebody there, to know.
///
/// **Nothing here writes anywhere on this device.** An ask that is refused or fails throws what
/// the door threw and changes nothing.
public struct MastodonServerBlocks: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/domain_blocks"
    /// The word a server is named by, going out.
    static let word = "domain"

    /// The first stretch of the servers the reader blocks, or with `next` the stretch after the
    /// one that handed it back. How long a stretch is is left to the server unless `limit` asks
    /// for a length — never less than one.
    public func stretch(after next: String? = nil, limit: Int? = nil) async throws -> ServersStretch {
        let length = limit.map { [URLQueryItem(name: "limit", value: String(max(1, $0)))] } ?? []
        let (body, link) = try await door.getLinked(path: Self.path, query: length + (try MastodonPage.older(than: next)))
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<String>].self, from: body) else {
            throw MastodonBlocksError.unreadable
        }
        let onward: String?
        do {
            onward = try MastodonLink.next(in: link)
        } catch {
            throw MastodonBlocksError.unreadable
        }
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        var seen = Set<String>()
        let servers = read.compactMap { $0.value.flatMap(Self.server) }.filter { seen.insert($0).inserted }
        return ServersStretch(servers: servers, next: onward)
    }

    /// Blocks the whole server `host` (#314): nobody there reaches the reader at this source,
    /// whoever the reader followed there is followed no longer, and nobody there follows the
    /// reader any longer. Asked twice it answers the same.
    public func block(_ host: String) async throws {
        guard let server = Self.server(host) else { throw MastodonRequestError.invalidURL }
        _ = try await door.post(path: Self.path, form: [(Self.word, server)])
    }

    /// Blocks the server `host` no longer. Of a server not blocked it changes nothing, and is
    /// answered the same.
    public func unblock(_ host: String) async throws {
        guard let server = Self.server(host) else { throw MastodonRequestError.invalidURL }
        _ = try await door.delete(path: Self.path, form: [(Self.word, server)])
    }

    /// `name` as a server is named here: a host, in lower case and the one spelling a name that is
    /// not ASCII has — or nothing where it is no host (`Person.host(named:)`).
    public static func server(_ name: String) -> String? {
        guard !name.contains("@") else { return nil }
        return Person.host(named: "@_@" + name)
    }
}
