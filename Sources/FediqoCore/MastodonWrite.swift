import Foundation

// A post written as the reader (#56): `POST /api/v1/statuses`, then the returned status into
// the store the way a fetch already does, so the row appears without asking the timeline again.

/// Why a write did not produce a note this device can hold.
public enum MastodonWriteError: Error, Equatable, Sendable {
    /// This device no longer holds the source the token is for.
    case noSource
    /// The server answered a status this device could not read.
    case unreadable
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
}
