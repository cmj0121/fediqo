import Foundation
import Testing
@testable import FediqoCore

/// #316, in the half of it Core holds: where a reader last was in Home, read and told, against a
/// stub that answers by method and address (`FormServer`). Nothing here is a capture.
@Suite("Where a reader last was in Home, asked of a Mastodon and told")
struct MastodonHomePlaceTests {
    private static let host = "mastodon.localhost"
    private static let origin = "https://\(host)"
    private static let path = "/api/v1/markers"
    /// `timeline[]=home`, as the door's already-encoded query leaves it.
    private static let get = "GET \(path)?timeline%5B%5D=home"
    private static let post = "POST \(path)"
    private static let token = MastodonToken(
        host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let numeric = "103206304799668000"
    private static let notNumeric = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private static let toldAt = "2019-11-24T11:11:38.762Z"

    private func door(_ routes: [String: FormServer.Answer]) throws -> (MastodonAuthorized, FormServer, MemoryMastodonTokens) {
        let server = FormServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonAuthorized(token: Self.token, sender: server, store: tokens), server, tokens)
    }

    private static func moment(_ raw: String) throws -> Date {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(format.date(from: raw))
    }

    @Test("An empty object is a Home the source has not been told, and the ask is the one for Home")
    func anEmptyObjectIsNoPlace() async throws {
        let (door, server, tokens) = try door([Self.get: .init(body: "{}")])
        let place = try await MastodonHomePlace(door: door).read()
        #expect(place == nil)
        #expect(await server.asked == [
            .init(method: "GET", address: "\(Self.origin)\(Self.path)?timeline%5B%5D=home", form: "", bearer: "Bearer tok-123"),
        ])
        #expect(try tokens.token(host: Self.host) == Self.token)
    }

    @Test("A numeric id is kept as that string, with the version and the moment the source named")
    func aNumericId() async throws {
        let body = """
        {"home":{"last_read_id":"\(Self.numeric)","version":462,"updated_at":"\(Self.toldAt)"}}
        """
        let (door, server, _) = try door([Self.get: .init(body: body)])
        let place = try await MastodonHomePlace(door: door).read()
        #expect(place == HomePlace(lastReadID: Self.numeric, version: 462, updatedAt: try Self.moment(Self.toldAt)))
        #expect(await server.asked.map(\.method) == ["GET"])
    }

    @Test("An id that is not numeric is kept whole, and a place with no version and no moment still counts")
    func anIdThatIsNotNumeric() async throws {
        let (door, _, _) = try door([Self.get: .init(body: #"{"home":{"last_read_id":"\#(Self.notNumeric)"}}"#)])
        let place = try await MastodonHomePlace(door: door).read()
        #expect(place == HomePlace(lastReadID: Self.notNumeric, version: nil, updatedAt: nil))
    }

    @Test("A home that names no last read id is not a place: it throws, and the sign-in stays")
    func aHomeMissingItsId() async throws {
        let body = #"{"home":{"version":462,"updated_at":"\#(Self.toldAt)"}}"#
        let (door, server, tokens) = try door([Self.get: .init(body: body)])
        await #expect(throws: MastodonHomePlaceError.unreadable) {
            _ = try await MastodonHomePlace(door: door).read()
        }
        #expect(await server.asked.map(\.method) == ["GET"])
        #expect(try tokens.token(host: Self.host) == Self.token)
    }

    @Test("An empty id, or one with whitespace, is refused before anything is asked")
    func refusedBeforeAsking() async throws {
        let (door, server, tokens) = try door([Self.post: .init(body: "{}")])
        let places = MastodonHomePlace(door: door)
        for id in ["", " ", "12 3", "12\n3", "\t1", "1 "] {
            await #expect(throws: MastodonHomePlaceError.refused, "\(id)") {
                _ = try await places.tell(lastReadID: id)
            }
        }
        #expect(await server.asked.isEmpty)
        #expect(try tokens.token(host: Self.host) == Self.token)
    }

    @Test("Telling posts the Home field and returns the place the source answered with, id kept whole")
    func tellingPostsTheForm() async throws {
        let body = """
        {"home":{"last_read_id":"\(Self.notNumeric)","version":7,"updated_at":"\(Self.toldAt)"}}
        """
        let (door, server, _) = try door([Self.post: .init(body: body)])
        let place = try await MastodonHomePlace(door: door).tell(lastReadID: Self.notNumeric)
        #expect(place == HomePlace(lastReadID: Self.notNumeric, version: 7, updatedAt: try Self.moment(Self.toldAt)))
        #expect(await server.asked == [
            .init(
                method: "POST", address: "\(Self.origin)\(Self.path)",
                form: "home%5Blast_read_id%5D=\(Self.notNumeric)", bearer: "Bearer tok-123"
            ),
        ])
    }

    @Test("A body that is not that object throws, and so does an answer to tell that names no place; the sign-in stays")
    func anUnreadableBody() async throws {
        let (door, server, tokens) = try door([Self.get: .init(body: "[]")])
        await #expect(throws: MastodonHomePlaceError.unreadable) {
            _ = try await MastodonHomePlace(door: door).read()
        }
        #expect(await server.asked.map(\.method) == ["GET"])
        #expect(try tokens.token(host: Self.host) == Self.token)

        let (telling, told, kept) = try self.door([Self.post: .init(body: "{}")])
        await #expect(throws: MastodonHomePlaceError.unreadable) {
            _ = try await MastodonHomePlace(door: telling).tell(lastReadID: Self.numeric)
        }
        #expect(await told.asked.map(\.method) == ["POST"])
        #expect(try kept.token(host: Self.host) == Self.token)
    }

    @Test("A 401, and any other refusal, is thrown as the door threw it")
    func aDoorRefusal() async throws {
        let (denied, _, deniedTokens) = try door([Self.get: .init(body: #"{"error":"The access token is invalid"}"#, status: 401)])
        await #expect(throws: MastodonAuthError.http(401)) {
            _ = try await MastodonHomePlace(door: denied).read()
        }
        #expect(try deniedTokens.token(host: Self.host) == Self.token)

        let (forbidden, _, kept) = try door([Self.post: .init(body: #"{"error":"This action is outside the authorized scopes"}"#, status: 403)])
        await #expect(throws: MastodonAuthError.http(403)) {
            _ = try await MastodonHomePlace(door: forbidden).tell(lastReadID: Self.numeric)
        }
        #expect(try kept.token(host: Self.host) == Self.token)
    }
}
