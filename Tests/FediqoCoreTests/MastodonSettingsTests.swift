import Foundation
import Testing
@testable import FediqoCore

/// #321, the reading: what somebody set at a Mastodon for the posts they write there, read out
/// of what a real server sent (`MastodonSettingsCaptures`) — through the one signed-in door,
/// setting by setting, each value known or kept as the source wrote it, cleaned and bounded.
@Suite("What somebody set at a Mastodon for the posts they write")
struct MastodonSettingsTests {
    private static let path = MastodonSettings.path
    private static let check = "/api/v1/accounts/verify_credentials"

    private static func reader(_ routes: [String: FixtureSender.Outcome]) throws -> (MastodonSettings, FixtureSender, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let server = FixtureSender(routes)
        return (MastodonSettings(door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)), server, tokens)
    }

    private static func read(_ body: String) throws -> PostingDefaults {
        try MastodonSettings.postingDefaults(from: Data(body.utf8))
    }

    @Test("What a real server sent is read: who a new post is for, its language as the tag the server gave, and whether its media is covered — asked once, at its own address, of the host the sign-in is of, as the person")
    func whatARealServerSent() async throws {
        let (reader, server, _) = try Self.reader([Self.path: .json(MastodonSettingsCaptures.untouched)])
        #expect(try await reader.postingDefaults() == PostingDefaults(reach: .known(.everyone), language: "en", coversMedia: false))
        let requests = await server.requests
        #expect(requests.count == 1 && requests.first?.url?.absoluteString == "https://\(MastodonFixture.host)/api/v1/preferences")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(MastodonFixture.token.accessToken)")
        #expect(requests.first?.httpMethod == "GET")

        #expect(try Self.read(MastodonSettingsCaptures.unlistedCovered) == PostingDefaults(reach: .known(.unlisted), language: "zh-TW", coversMedia: true))
        #expect(try Self.read(MastodonSettingsCaptures.followersOnly) == PostingDefaults(reach: .known(.followers), language: "zh", coversMedia: false))
        #expect(try Self.read(#"{"posting:default:visibility":"direct"}"#).reach == .known(.mentioned))
    }

    @Test("Setting by setting: one that is missing, null or of another shape is that one not said and never the others; a reach this build does not know is kept as the source wrote it; and an answer that is no list of settings is unreadable")
    func settingBySetting() throws {
        #expect(try Self.read("{}") == PostingDefaults())
        let partly = try Self.read(#"{"posting:default:visibility":7,"posting:default:sensitive":"yes","posting:default:language":null,"reading:expand:media":{"a":[1]}}"#)
        #expect(partly == PostingDefaults())
        let some = try Self.read(#"{"posting:default:visibility":["public"],"posting:default:sensitive":true,"posting:default:language":"fr"}"#)
        #expect(some == PostingDefaults(reach: nil, language: "fr", coversMedia: true))
        #expect(try Self.read(#"{"posting:default:visibility":"local","posting:default:language":""}"#) == PostingDefaults(reach: .other("local")))
        #expect(try Self.read(#"{"posting:default:visibility":"   "}"#).reach == nil)
        // The server's names are read as it wrote them, and a name like one of them is not one.
        #expect(try Self.read(#"{"posting:default:Visibility":"private","posting_default_sensitive":true}"#) == PostingDefaults())
        for body in ["[]", "", "null", "<html>", #""public""#, MastodonSettingsCaptures.untouched + "x"] {
            #expect(throws: MastodonSettingsError.unreadable) { try Self.read(body) }
        }
        // An error's sentence, answered 200, is a list of no settings: it says nothing.
        #expect(try Self.read(MastodonSettingsCaptures.notGiven) == PostingDefaults())
    }

    @Test("What the source wrote is a stranger's word: a reach it does not know and a language are made fit for a line and kept short, whatever was sent")
    func aStrangersWord() throws {
        let long = String(repeating: "x", count: 100_000)
        let said = try Self.read(#"{"posting:default:visibility":"pub‮lic\nonly \#(long)","posting:default:language":"z​h‮-TW\r\n\#(long)"}"#)
        guard case .other(let reach) = said.reach else {
            Issue.record("a word that is not a reach was taken for one")
            return
        }
        #expect(reach.hasPrefix("public only x") && reach.count <= PostingDefaults.wordLength + 1)
        let language = try #require(said.language)
        #expect(language.hasPrefix("zh-TW x") && language.count <= PostingDefaults.wordLength + 1)
        for word in [reach, language] {
            #expect(word.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format })
        }
        #expect(PostingDefaults(language: "\u{202e}\n").language == nil && PostingDefaults(language: " en ").language == "en")
    }

    @Test("A sign-in that was not given this is refused, and the refusal is what the door throws — not the end of the sign-in; with no sign-in the door asks the source whether the sign-in is over before it says so; a failure and nothing answering are each a failure of that ask")
    func refusedAndFailed() async throws {
        let (refused, server, tokens) = try Self.reader([Self.path: .json(MastodonSettingsCaptures.notGiven, status: 403)])
        await #expect(throws: MastodonAuthError.http(403)) { try await refused.postingDefaults() }
        let stillHeld = try tokens.token(host: MastodonFixture.host)
        #expect(await server.paths == [Self.path])
        #expect(stillHeld != nil)

        let (over, gone, forgotten) = try Self.reader([
            Self.path: .json(MastodonSettingsCaptures.noSignIn, status: 401), Self.check: .json(MastodonSettingsCaptures.noSignIn, status: 401),
        ])
        await #expect(throws: MastodonAuthError.signedOut) { try await over.postingDefaults() }
        let after = try forgotten.token(host: MastodonFixture.host)
        #expect(await gone.paths == [Self.path, Self.check])
        #expect(after == nil)

        let (odd, _, kept) = try Self.reader([Self.path: .json(MastodonSettingsCaptures.noSignIn, status: 401), Self.check: .json(MastodonFixture.me)])
        await #expect(throws: MastodonAuthError.http(401)) { try await odd.postingDefaults() }
        let keptOne = try kept.token(host: MastodonFixture.host)
        #expect(keptOne != nil, "one address refusing is not the sign-in ending")

        for status in [404, 422, 429, 500, 503] {
            let (failing, _, _) = try Self.reader([Self.path: .json(MastodonSettingsCaptures.untouched, status: status)])
            await #expect(throws: MastodonAuthError.http(status)) { try await failing.postingDefaults() }
        }
        await #expect(throws: URLError.self) { try await Self.reader([Self.path: .fail]).0.postingDefaults() }
        let (unreadable, _, _) = try Self.reader([Self.path: .json("[]")])
        await #expect(throws: MastodonSettingsError.unreadable) { try await unreadable.postingDefaults() }
    }
}
