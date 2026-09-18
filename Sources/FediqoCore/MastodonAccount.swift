import Foundation

// What a signed-in Mastodon source reads as you (#25): Home, and the lists the reader chose.
//
// Every request goes through `MastodonAuthorized`, the one door #24 built. A 401 there has
// already taken the token off this device and arrives here as `MastodonAuthError.signedOut`,
// which ends the whole read: nothing after it could be asked as you. Any other failure costs
// only the read it happened on. Public and trends stay unauthenticated in `MastodonClient`.

/// Home and the chosen lists of one signed-in Mastodon source, read into the store.
public struct MastodonAccount: Sendable {
    private let door: MastodonAuthorized
    private let store: ItemStore

    public init(door: MastodonAuthorized, store: ItemStore) {
        self.door = door
        self.store = store
    }

    private var host: String { door.token.host }

    /// Every list this account has, as the server names them now.
    public func lists() async throws -> [ListSubscription] {
        let data = try await door.get(path: "/api/v1/lists")
        return try MastodonJSON.decoder.decode([ListDTO].self, from: data).compactMap(\.asList)
    }

    /// Home, and every list this source reads. The chosen lists are relabelled first with the
    /// names the server gives them now — a renamed list stays one category, only its label moves.
    ///
    /// Returns whether every read came back. Throws only `.signedOut` and cancellation.
    public func read() async throws -> Bool {
        guard let source = await source() else { return true }
        var complete = true
        let lists = source.lists
        if !lists.isEmpty {
            if let named = try await attempt({ try await self.lists() }) {
                // Relabels what is chosen when the answer lands, not what was chosen when this
                // read began, so a picker's Done in between is kept.
                await store.relabel(
                    host: host,
                    lists: Dictionary(named.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                )
            } else {
                complete = false
            }
        }
        var notes: [Note] = []
        if let home = try await attempt({
            try await statuses("/api/v1/timelines/home", source: source, category: .home)
        }) {
            notes += home
        } else {
            complete = false
        }
        let (read, all) = try await statuses(of: lists, source: source)
        try await ingest(notes + read)
        return complete && all
    }

    /// Makes `picks` the lists this source reads, and reads the ones that were not chosen before.
    ///
    /// Returns whether every read came back. Throws only `.signedOut` and cancellation.
    public func choose(_ picks: [ListSubscription]) async throws -> Bool {
        guard let source = await source() else { return true }
        let before = Set(source.lists.map(\.id))
        await store.subscribe(host: host, toLists: picks)
        let (read, all) = try await statuses(
            of: picks.filter { !before.contains($0.id) }, source: source
        )
        try await ingest(read)
        return all
    }

    private func source() async -> Source? {
        await store.sources().first { $0.host == host }
    }

    /// Only into a source still here, in one step: a source removed while its reads were on the
    /// wire must not get its posts back. Nor does a read stopped meanwhile — a sign-out or a Clear.
    private func ingest(_ notes: [Note]) async throws {
        try Task.checkCancellation()
        await store.ingest(notes, ifSourceHere: host)
    }

    private func statuses(
        of lists: [ListSubscription], source: Source
    ) async throws -> (notes: [Note], all: Bool) {
        var notes: [Note] = []
        var all = true
        // Checked again here, not only when the server named it: these ids come back out of the
        // store, and a tampered one must not reach the signed-in path.
        for list in lists where ListSubscription.isPathSegment(list.id) {
            if let read = try await attempt({
                try await statuses(
                    "/api/v1/timelines/list/\(list.id)", source: source, category: .list(id: list.id)
                )
            }) {
                notes += read
            } else {
                all = false
            }
        }
        return (notes, all)
    }

    private func statuses(_ path: String, source: Source, category: Category) async throws -> [Note] {
        let data = try await door.get(path: path, query: [URLQueryItem(name: "limit", value: "40")])
        return try MastodonJSON.decoder.decode([StatusDTO].self, from: data).map {
            $0.asNote(source: source, category: category)
        }
    }

    /// One read, or nothing where it failed. A sign-out by the server and a reader walking away
    /// end the whole errand instead.
    private func attempt<T>(_ read: () async throws -> T) async throws -> T? {
        do {
            return try await read()
        } catch MastodonAuthError.signedOut {
            throw MastodonAuthError.signedOut
        } catch let error where Cancellation.happened(error) {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}

/// `/api/v1/lists`, in the two fields a choice needs.
struct ListDTO: Decodable, Sendable {
    let id: String
    let title: String

    /// Nothing for an id that could not stand in a path as one segment.
    var asList: ListSubscription? {
        guard ListSubscription.isPathSegment(id) else { return nil }
        return ListSubscription(id: id, name: title)
    }
}

extension ListSubscription {
    /// Whether `id` can stand in a signed-in path as one segment. Mastodon's are digits; a
    /// stranger's server, and a store on disk, are held to that shape rather than trusted with
    /// the path.
    public static func isPathSegment(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
