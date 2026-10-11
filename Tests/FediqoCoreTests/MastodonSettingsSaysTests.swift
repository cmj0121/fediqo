import Foundation
import Testing
@testable import FediqoCore

/// #321: what Fediqo believes a Mastodon says somebody set there for the posts they write,
/// held against the real one this checkout brings up (`make servers`, Mastodon 4.6.6) — read
/// through this app's own reader, `MastodonSettings`, and beside it asked plainly for the part
/// of each answer the reader rests on (`MastodonSettingsCaptures`).
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`): the writer, who set nothing;
/// somebody who set all three; and a sign-in of the writer's that lacks the one word this
/// wants. **Nothing here writes.**
///
/// **Every plain ask names English**: this server answers its refusals, and the language of
/// somebody who set none, in the language it is asked in.
///
/// **Asked gently.** A run makes eight requests and no registration.
@Suite("What a Mastodon says somebody set there", .enabled(if: LocalServers.requested), .serialized)
struct MastodonSettingsSaysTests {
    private static let host = LocalServers.mastodon

    private static func seeded() throws -> LocalServers.Seeded {
        let seeded = try LocalServers.seeded()
        _ = try #require(seeded.people?.narrow, "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again")
        return seeded
    }

    private func plain(_ path: String, as token: String? = nil) async throws -> (status: Int, body: Data, response: HTTPURLResponse) {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        // Named, since this server answers in the language it is asked in — its refusals, and
        // the language it puts where somebody set none.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return (response.statusCode, body, response)
    }

    private func reader(_ accessToken: String) throws -> (MastodonSettings, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return (MastodonSettings(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens)), tokens)
    }

    @Test("Somebody who set nothing is said to write for everyone, uncovered, and in a language all the same — asked in English, English — to this app's reading sign-in as to one that may do everything, the same bytes")
    func whoSetNothing() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let reading = try #require(seeded.notices).reading.token
        // The language is not pinned: where somebody set none the server puts one of its own
        // choosing, which was not the same from every asker.
        let said = try await reader(reading).0.postingDefaults()
        #expect(said.reach == .known(.everyone) && said.coversMedia == false && said.language != nil)
        let asReader = try await plain(MastodonSettings.path, as: reading), asWriter = try await plain(MastodonSettings.path, as: seeded.writer)
        #expect(asReader.status == 200 && asReader.body == asWriter.body && asReader.body == Data(MastodonSettingsCaptures.untouched.utf8))
    }

    @Test("Somebody who set all three is said as they set them: a reach by the server's own word for it, the language a tag with its region, and media covered")
    func whoSetAllThree() async throws {
        try await LocalServers.requireHealthy()
        let hidden = try #require(try Self.seeded().people).hidden.token
        #expect(try await reader(hidden).0.postingDefaults() == PostingDefaults(reach: .known(.unlisted), language: "zh-TW", coversMedia: true))
        #expect(try await plain(MastodonSettings.path, as: hidden).body == Data(MastodonSettingsCaptures.unlistedCovered.utf8))
    }

    @Test("With no sign-in, or a token that is none, it is refused as a token that is not valid; a sign-in without the word for reading the person's own account is refused it with a 403 that names what is missing — and goes on being honoured for what it holds")
    func refused() async throws {
        try await LocalServers.requireHealthy()
        let narrow = try #require(try Self.seeded().people?.narrow).token
        for token in [nil, "not-a-token"] {
            let answer = try await plain(MastodonSettings.path, as: token)
            #expect(answer.status == 401 && answer.body == Data(MastodonSettingsCaptures.noSignIn.utf8))
        }
        let refused = try await plain(MastodonSettings.path, as: narrow)
        #expect(refused.status == 403 && refused.body == Data(MastodonSettingsCaptures.notGiven.utf8))
        #expect(refused.response.value(forHTTPHeaderField: "WWW-Authenticate")?.contains("insufficient_scope") == true)

        let (reader, tokens) = try reader(narrow)
        await #expect(throws: MastodonAuthError.http(403)) { try await reader.postingDefaults() }
        let held = try tokens.token(host: Self.host)
        #expect(held != nil, "refused, and not signed out")
        #expect(try await plain("/api/v1/timelines/home?limit=1", as: narrow).status == 200)
    }
}
