import Foundation
import os

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
    /// The door one timeline — Home, or one list — is read through. `door` unless the caller
    /// asked for its own per timeline: the app names each one while it is on the wire, and only
    /// the caller knows the names (#170). Every one of them is the same token to the same host.
    private let reading: @Sendable (Category) -> MastodonAuthorized

    public init(
        door: MastodonAuthorized, store: ItemStore,
        reading: (@Sendable (Category) -> MastodonAuthorized)? = nil
    ) {
        self.door = door
        self.store = store
        self.reading = reading ?? { _ in door }
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
        if try await attempt({
            try await readOn("/api/v1/timelines/home", source: source, category: .home)
        }) == nil {
            complete = false
        }
        let all = try await readOn(lists, source: source)
        return complete && all
    }

    /// Only what a reload asks for (#29): Home where `home`, and those lists in `lists` this source
    /// still reads. A list no longer chosen asks nothing, and nothing is relabelled.
    ///
    /// Returns whether every read came back. Throws only `.signedOut` and cancellation.
    public func read(home: Bool, lists ids: Set<String>) async throws -> Bool {
        guard let source = await source() else { return true }
        var complete = true
        if home, try await attempt({
            try await readOn("/api/v1/timelines/home", source: source, category: .home)
        }) == nil {
            complete = false
        }
        let all = try await readOn(source.lists.filter { ids.contains($0.id) }, source: source)
        return complete && all
    }

    /// Makes `picks` the lists this source reads, and reads the ones that were not chosen before.
    ///
    /// Returns whether every read came back. Throws only `.signedOut` and cancellation.
    public func choose(_ picks: [ListSubscription]) async throws -> Bool {
        guard let source = await source() else { return true }
        let before = Set(source.lists.map(\.id))
        await store.subscribe(host: host, toLists: picks)
        return try await readOn(picks.filter { !before.contains($0.id) }, source: source)
    }

    /// The stretch of Home, or of one list this source reads, older than the post `maxID` names —
    /// the next of a listing read toward its end (#87). Into the store, and handed back as the page
    /// carried it so the caller can tell a stretch that brought nothing from one that did.
    ///
    /// Throws what the read threw: this is one read, and a caller asked for exactly it.
    public func older(_ category: Category, than maxID: String) async throws -> [Note] {
        guard let source = await source(), let path = Self.path(of: category, in: source) else { return [] }
        let notes = try await statuses(path, source: source, category: category, olderThan: maxID)
        try await ingest(notes)
        return notes
    }

    /// Home, or one list this source reads, read down from the place below `key` where posts may
    /// be missing (#204), and landed with what it says of that place. Nothing where `key` carries
    /// no such mark in it. `me` is who the reader is there, where known (`ItemStore.missing`).
    ///
    /// Throws what the read threw — a stretch after the first once what came before it has landed.
    public func readDown(
        _ category: Category, below key: NoteKey, writtenBy me: String? = nil, at moment: Date = Date()
    ) async throws {
        guard let source = await source(), let path = Self.path(of: category, in: source),
              let place = await store.missing(below: key, in: category, writtenBy: me)
        else { return }
        let down = try await MastodonReadOn.readDown(from: place) { maxID in
            try await listed(path, source: source, category: category, query: try MastodonPage.older(than: maxID))
        }
        try Task.checkCancellation()
        await store.land(down, below: key, of: category, at: moment, ifSourceHere: host)
        if let stopped = down.stopped { throw stopped }
    }

    /// Where Home, or a list this source still reads, is asked. Nothing for anything else.
    private static func path(of category: Category, in source: Source) -> String? {
        switch category {
        case .home: "/api/v1/timelines/home"
        case .list(let id) where source.lists.contains(where: { $0.id == id }) && ListSubscription.isPathSegment(id):
            "/api/v1/timelines/list/\(id)"
        default: nil
        }
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

    /// Each of `lists` read on and landed, one after another. Whether every one came back.
    private func readOn(_ lists: [ListSubscription], source: Source) async throws -> Bool {
        var all = true
        // Checked again here, not only when the server named it: these ids come back out of the
        // store, and a tampered one must not reach the signed-in path.
        for list in lists where ListSubscription.isPathSegment(list.id) {
            if try await attempt({
                try await readOn(
                    "/api/v1/timelines/list/\(list.id)", source: source, category: .list(id: list.id)
                )
            }) == nil {
                all = false
            }
        }
        return all
    }

    /// One timeline read on from the newest post held of it (#201), and landed as it answers, so
    /// one that fails after it holds back none of what it brought.
    ///
    /// A stretch that failed after the first lands what came before it, then fails the read.
    private func readOn(_ path: String, source: Source, category: Category) async throws {
        let anchor = await store.newestListedID(host: host, category: category)
        let held = anchor == nil ? await store.held(host: host, category: category) : []
        let read = try await MastodonReadOn.read(from: anchor, holding: held) { minID in
            try await listed(path, source: source, category: category, query: try MastodonPage.newer(than: minID))
        } older: { maxID in
            try await listed(path, source: source, category: category, query: try MastodonPage.older(than: maxID))
        }
        try Task.checkCancellation()
        await store.land(read, of: category, ifSourceHere: host)
        if let stopped = read.stopped { throw stopped }
    }

    private func statuses(
        _ path: String, source: Source, category: Category, olderThan maxID: String? = nil
    ) async throws -> [Note] {
        try await listed(path, source: source, category: category, query: try MastodonPage.older(than: maxID))
            .map(\.note)
    }

    /// One page, each post with the id the timeline lists it under — a boost's own.
    private func listed(
        _ path: String, source: Source, category: Category, query: [URLQueryItem]
    ) async throws -> [Listed] {
        let data = try await reading(category).get(
            path: path, query: [URLQueryItem(name: "limit", value: String(MastodonReadOn.limit))] + query
        )
        return try MastodonJSON.decoder.decode([StatusDTO].self, from: data).map {
            $0.listed(source: source, category: category)
        }
    }

    /// One read, or nothing where it failed. A sign-out by the server and a reader walking away
    /// end the whole errand instead.
    private func attempt<T>(_ read: () async throws -> T) async throws -> T? {
        do {
            return try await read()
        } catch MastodonAuthError.signedOut {
            NetLog.auth.notice(
                "\(NetLog.line("read as you", host: host, error: MastodonAuthError.signedOut), privacy: .public)"
            )
            throw MastodonAuthError.signedOut
        } catch let error where Cancellation.happened(error) {
            throw CancellationError()
        } catch {
            NetLog.auth.error("\(NetLog.line("read as you", host: host, error: error), privacy: .public)")
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
