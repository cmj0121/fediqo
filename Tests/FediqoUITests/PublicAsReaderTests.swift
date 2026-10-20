import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A signed-in source's public timeline is read with its sign-in (#283).
///
/// g0v.social and mastodon.social keep their public timelines for signed-in readers: an ask
/// without a token is answered 422, "This method requires an authenticated user", every round.
///
/// What a test can reach: which door each read of the public timeline goes through — a reload's
/// read on, an ask for more — with the token or without; and that a source that asks a sign-in
/// of a reader who has none is not taken for one that answered. What it cannot: the line in
/// Console, which `NetLog` writes and nothing here reads.
@MainActor
@Suite("A signed-in source's public timeline is read with its sign-in", .watched)
struct PublicAsReaderTests {
    private static let one = "one.example"
    private static let source = Source(host: one, kind: .mastodon)

    private static func status(_ id: String) -> String {
        """
        {"id":"\(id)","uri":"https://\(one)/users/ada/statuses/\(id)",
         "created_at":"2024-01-0\(id)T00:00:00.000Z","content":"<p>\(id)</p>",
         "visibility":"public","account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static let newest = "https://\(one)/api/v1/timelines/public?limit=40"

    /// A session over `one.example`, holding post 5 of its public timeline where `holding`,
    /// signed in there where `signedIn`.
    private func shell(
        http: FixtureHTTP, server: ActServer, signedIn: Bool, holding: Bool = false
    ) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
        }
        let store = ItemStore()
        await store.add(Self.source)
        if holding {
            await store.ingest([Note(
                id: "https://\(Self.one)/users/ada/statuses/5", source: Self.source, author: "Ada", handle: "@ada",
                body: "5", postedAt: Date(timeIntervalSince1970: 1_800_000_000), categories: [.public],
                statusID: "5"
            )])
        }
        let session = ShellSession(http: http, store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        session.mastodon.refresh()
        session.deadlinesUnturned()
        await session.reloadFromStore()
        return session
    }

    private func publicAsks(_ server: ActServer) async -> [URLRequest] {
        await server.requests.filter { $0.url?.path == "/api/v1/timelines/public" }
    }

    @Test("Signed in, a reload reads the public timeline with the sign-in, and nothing of it without")
    func reloadCarriesTheSignIn() async throws {
        let http = FixtureHTTP()
        let server = ActServer([
            "/api/v1/timelines/public": .json("[" + Self.status("2") + "]"),
            "/api/v1/timelines/home": .json("[]"),
        ])
        let session = try await shell(http: http, server: server, signedIn: true)

        await session.reload.timeline(.all, in: session)

        let asked = await publicAsks(server)
        #expect(asked.count == 1)
        #expect(asked.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(asked.first?.url?.host() == Self.one, "to the token's own host")
        let unsigned = await http.requested.filter { $0.path == "/api/v1/timelines/public" }
        #expect(unsigned.isEmpty, "never asked without the sign-in as well")
        #expect(session.notes.contains { $0.statusID == "2" && $0.categories.contains(.public) })
    }

    @Test("Signed in, asking for more of the public timeline asks with the sign-in")
    func moreCarriesTheSignIn() async throws {
        let http = FixtureHTTP()
        let server = ActServer(["/api/v1/timelines/public": .json("[" + Self.status("3") + "]")])
        let session = try await shell(http: http, server: server, signedIn: true, holding: true)

        await session.reload.more(.all, in: session)

        let asked = await publicAsks(server)
        #expect(asked.count == 1)
        #expect(asked.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(asked.first?.url?.query?.contains("max_id=5") == true)
        #expect(session.notes.contains { $0.statusID == "3" })
    }

    @Test("Not signed in, the public timeline is asked without a sign-in, as it always was")
    func anonymousAsksBare() async throws {
        let http = FixtureHTTP([Self.newest: .text("[" + Self.status("2") + "]")])
        let server = ActServer([:])
        let session = try await shell(http: http, server: server, signedIn: false)

        await session.reload.timeline(.all, in: session)

        #expect(await server.requests.isEmpty, "nothing goes through a door")
        #expect(await http.requested.map(\.absoluteString).contains(Self.newest))
        #expect(session.notes.contains { $0.statusID == "2" })
    }

    @Test("A source that reads its public timeline only to a signed-in reader is a read that did not come")
    func anonymousRefusedForASignIn() async throws {
        let refusal = #"{"error":"This method requires an authenticated user"}"#
        let http = FixtureHTTP([Self.newest: .text(refusal, status: 422)])
        let session = try await shell(http: http, server: ActServer([:]), signedIn: false)
        let client = session.reach.mastodon(Self.one, for: .timeline, within: nil)

        let read = await session.reload.readOnPublic(client, stamp: Self.source, in: session)

        #expect(!read, "a refusal is no read, whatever Trends brings beside it")
        #expect(session.notes.isEmpty)
    }
}
