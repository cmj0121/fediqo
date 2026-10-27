import Foundation

/// Where a reader last was in Home, as one source said it (#316): the id of that post, kept
/// whole, and the version and moment the source named where it named them.
public struct HomePlace: Hashable, Sendable {
    /// The post, as the source names it: an opaque string, digits or not, never cut down.
    public let lastReadID: String
    /// The source's own count of how this place has moved, or nothing where it named none.
    public let version: Int?
    /// When the source says this place was written, or nothing where it named none.
    public let updatedAt: Date?

    public init(lastReadID: String, version: Int? = nil, updatedAt: Date? = nil) {
        self.lastReadID = lastReadID
        self.version = version
        self.updatedAt = updatedAt
    }
}

/// Why a Home place could not be read (#316).
public enum MastodonHomePlaceError: Error, Equatable, Sendable {
    /// Refused before anything was asked: an id that is empty, or that holds whitespace.
    case refused
    /// The server answered, and not with a Home place: a body that is no such object, or a
    /// `home` that names no `last_read_id`.
    case unreadable
}

/// A Mastodon asked where the reader last was in Home, and told (#316): `GET` and `POST`
/// `/api/v1/markers`, through the one signed-in door.
///
/// **The id is the source's own word, and nothing else.** It is kept as the string the source
/// sent — a GoToSocial id is not digits, and cutting one down to a number would name another
/// post, or none. Going out, an id that is empty or holds whitespace is refused before
/// anything is asked.
///
/// **No marker is no place.** An empty object is a Home the source has not been told. A body
/// that is not that object, or a `home` with no `last_read_id`, is not read: it throws and
/// nothing on this device changes. `version` and `updated_at` may be absent; the place still
/// counts. `updated_at`, where the source sent it, is its ISO-8601 timestamp.
///
/// **Nothing here writes anywhere on this device, and nothing here looks at a scope.** An ask
/// that is refused or fails throws what the door threw. There is no `MastodonPart` for this.
public struct MastodonHomePlace: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/markers"
    /// `timeline[]=home`. The brackets are already encoded: a query item the door sends is
    /// percent-encoded, and a bare `[` is not one.
    static let asked = URLQueryItem(name: "timeline%5B%5D", value: "home")
    /// The form field a place is told by: `home[last_read_id]`.
    static let field = "home[last_read_id]"

    /// Where the source says the reader last was in Home, or nothing where it has not been told.
    public func read() async throws -> HomePlace? {
        try Self.place(in: try await door.get(path: Self.path, query: [Self.asked]))
    }

    /// Tells the source the reader is at `lastReadID` in Home, and returns the place it answered
    /// with.
    public func tell(lastReadID: String) async throws -> HomePlace {
        guard !lastReadID.isEmpty, !lastReadID.contains(where: \.isWhitespace) else {
            throw MastodonHomePlaceError.refused
        }
        guard let place = try Self.place(in: try await door.post(path: Self.path, form: [(Self.field, lastReadID)])) else {
            throw MastodonHomePlaceError.unreadable
        }
        return place
    }

    /// The Home in `body`, nothing where that object names none, or a throw where it is not one.
    private static func place(in body: Data) throws -> HomePlace? {
        guard let read = try? MastodonJSON.decoder.decode(Markers.self, from: body) else {
            throw MastodonHomePlaceError.unreadable
        }
        return read.home.map {
            HomePlace(lastReadID: $0.lastReadId, version: $0.version, updatedAt: $0.updatedAt)
        }
    }

    private struct Markers: Decodable {
        /// `last_read_id` under `MastodonJSON.decoder`'s snake-case strategy, which writes `id`
        /// as `Id`.
        struct Place: Decodable {
            let lastReadId: String
            let version: Int?
            let updatedAt: Date?
        }

        let home: Place?
    }
}
