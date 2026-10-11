import Foundation
import Testing
@testable import FediqoCore

/// #312: what a Mastodon says to a body of several parts as this app makes one
/// (`MultipartBody`), held against the real one this checkout brings up (`make servers`,
/// Mastodon 4.6.6) — sent through the signed-in door, `MastodonAuthorized.patch`.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of the check.
///
/// **This writes, and puts back what it wrote.** The seeded second person's note and picture
/// are changed and then set as they were — each put back on its own, whatever else failed —
/// and the check ends by holding the account's own answer after against the one before, byte
/// for byte. **An account found with a picture is not touched**: taking a picture away is all
/// this can do to put one back, so the check stops there, as a failure and before it writes.
///
/// **Asked gently.** A run makes seven requests and no registration.
@Suite("What a Mastodon says to a body of several parts", .enabled(if: LocalServers.requested), .serialized)
struct MastodonPartsSaysTests {
    private static let host = LocalServers.mastodon
    private static let path = "/api/v1/accounts/update_credentials"

    /// What of an account's own answer this reads: its note as it wrote it, and its picture.
    private struct Said: Decodable {
        struct Source: Decodable { let note: String }
        let avatar: String
        let source: Source
    }

    private static func said(_ body: Data) throws -> Said {
        try JSONDecoder().decode(Said.self, from: body)
    }

    /// The same body asked plainly, for the words of a refusal, which the door does not hand on.
    private func plain(_ parts: [MultipartPart], as token: String) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: "https://\(Self.host)\(Self.path)") else { throw LocalHTTPError.invalidURL }
        let made = try MultipartBody(parts)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        // Named, since this server answers its refusals in the language it is asked in.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(made.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = made.data
        let (body, response) = try await LocalHTTP.client().send(request)
        return (response.statusCode, body)
    }

    @Test("A note of several scripts and a picture under a name that is not ASCII are taken as sent; bytes that are no picture are refused with a 422 and change nothing; and what was changed is put back")
    func takenAndPutBack() async throws {
        try await LocalServers.requireHealthy()
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(
            host: Self.host, accessToken: try LocalServers.seeded().other, clientID: "x", clientSecret: "x"
        )
        try tokens.save(token)
        let door = MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens)

        let before = try await door.get(path: MastodonAuthorized.accountCheck)
        let was = try Self.said(before)
        try #require(
            was.avatar.hasSuffix("/avatars/original/missing.png"),
            "the seeded account has a picture this check could not put back: nothing was sent"
        )

        // Everything asked before anything is held to account, so a failed belief still leaves
        // the account as it was found.
        let picture = try #require(Data(base64Encoded: MastodonPartsCaptures.pixel))
        let changed = try? await door.patch(path: Self.path, parts: [
            .field("note", MastodonPartsCaptures.note),
            .file("avatar", named: "頭像 \"1\".png", type: "image/png", picture),
        ])
        let refused = try? await plain([
            .file("avatar", named: "not-a-picture.png", type: "image/png", Data("no picture".utf8)),
        ], as: token.accessToken)
        let unchanged = try? await door.get(path: MastodonAuthorized.accountCheck)
        // Each on its own: a note that would not go back must not leave the picture changed.
        let noteBack = try? await door.patch(path: Self.path, parts: [.field("note", was.source.note)])
        let pictureBack = try? await door.delete(path: "/api/v1/profile/avatar")
        let after = try? await door.get(path: MastodonAuthorized.accountCheck)

        let now = try Self.said(try #require(changed, "the body was not taken"))
        #expect(now.source.note == MastodonPartsCaptures.note)
        #expect(now.avatar != was.avatar)
        #expect(refused?.status == 422)
        #expect(refused?.body == Data(MastodonPartsCaptures.noPicture.utf8))
        #expect(unchanged == changed, "a refused picture changed the account")
        #expect(noteBack != nil, "the note was not put back")
        #expect(pictureBack != nil, "the picture was not taken away again")
        #expect(after == before, "the account was not left as it was found")
    }
}
