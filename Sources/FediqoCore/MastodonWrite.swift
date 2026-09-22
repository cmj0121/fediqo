import Foundation

// A post written as the reader (#56): `POST /api/v1/statuses`, then the returned status into
// the store the way a fetch already does, so the row appears without asking the timeline again.

/// Why a write did not produce a note this device can hold.
public enum MastodonWriteError: Error, Equatable, Sendable {
    /// This device no longer holds the source the token is for.
    case noSource
    /// The server answered a status this device could not read.
    case unreadable
    /// This device cannot name the post on its own server, so there is nothing to act on: a row
    /// stored before `Note.statusID` was kept, or a forum post that never had one.
    ///
    /// **Not `noSource`.** The source is here and the sign-in is good; it is this one row that
    /// cannot be pointed at, and a reader told to sign in again would be sent to fix the wrong
    /// thing. `ShellConversations.Absence.unfindable` draws the same distinction for the same
    /// reason one layer up.
    case unfindable
}

/// One signed-in Mastodon source, written to.
public struct MastodonWrite: Sendable {
    /// What a Mastodon that did not advertise a ceiling will take.
    public static let defaultLimit = 500

    private let door: MastodonAuthorized
    private let store: ItemStore

    public init(door: MastodonAuthorized, store: ItemStore) {
        self.door = door
        self.store = store
    }

    private var host: String { door.token.host }

    /// A positive advertised ceiling, or 500. Zero and below are not a real limit.
    public static func limit(advertised: Int?) -> Int {
        guard let advertised, advertised > 0 else { return defaultLimit }
        return advertised
    }

    /// Categories a fetch of this post would have stamped: Home, because it was written as the
    /// reader, and public where the post is public. Direct is neither.
    public static func categories(for audience: Audience) -> Set<Category> {
        switch audience {
        case .everyone: [.home, .public]
        case .unlisted, .followers: [.home]
        case .mentioned: []
        }
    }

    /// Posts `text` as the reader and takes the returned status into the store, only while the
    /// source is still here.
    @discardableResult
    public func post(_ text: String, visibility: Audience) async throws -> Note {
        guard let source = await store.sources().first(where: { $0.host == host }) else {
            throw MastodonWriteError.noSource
        }
        let data = try await door.post(path: "/api/v1/statuses", form: [
            ("status", text),
            ("visibility", visibility.mastodon),
        ])
        guard let note = try? MastodonJSON.decoder.decode(StatusDTO.self, from: data)
            .asNote(source: source, categories: Self.categories(for: visibility))
        else {
            throw MastodonWriteError.unreadable
        }
        try Task.checkCancellation()
        await store.ingest([note], ifSourceHere: host)
        return note
    }

    /// Boosts `note` to this source, or takes the boost back (#106).
    ///
    /// **One function for both directions**, because they are one act under one rule: the same
    /// press, the same refusals, the same sentence when it does not arrive. Two functions would
    /// be two places for the rule about what comes back to drift apart, and the reader is doing
    /// the same thing either way.
    @discardableResult
    public func boost(_ note: Note, on: Bool) async throws -> Note {
        try await act(on: note, path: on ? "reblog" : "unreblog")
    }

    /// One act on one status, and what the server says the post looks like afterwards.
    ///
    /// **The answer goes through `refresh` and never `ingest`.** The reader is acting on a post
    /// they are already looking at, so what comes back is a row this device holds and should be
    /// replaced with what the server now says — including `boosted`, which is the whole point of
    /// the press. `ingest` would keep the first copy and change nothing, which is a press that
    /// lands on the server and does nothing on the screen; and a post the store no longer holds
    /// is not quietly admitted, which is `refresh`'s own contract.
    ///
    /// **The store's copy is the one returned**, not the one decoded. `Note.refreshed(over:)` is
    /// what keeps the categories this copy arrived through and its booster, and a caller handed
    /// the bare decode would be holding a row that disagrees with the store about both.
    private func act(on note: Note, path: String) async throws -> Note {
        guard await store.sources().contains(where: { $0.host == host }) else {
            throw MastodonWriteError.noSource
        }
        guard let id = note.statusID, ListSubscription.isPathSegment(id) else {
            throw MastodonWriteError.unfindable
        }
        let data = try await door.post(path: "/api/v1/statuses/\(id)/\(path)", form: [])
        guard let answered = try? MastodonJSON.decoder.decode(StatusDTO.self, from: data)
            .asNote(source: note.source, categories: note.categories)
        else {
            throw MastodonWriteError.unreadable
        }
        try Task.checkCancellation()
        await store.refresh([answered], ifSourceHere: host)
        return await store.note(answered.key) ?? answered
    }
}
