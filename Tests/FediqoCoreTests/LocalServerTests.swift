import Foundation
import Testing
@testable import FediqoCore

/// Against the protocol servers this checkout can bring up. The recorded FixtureHTTP
/// cases stay; these are the ones that need a real server of that protocol.
@Suite("Local servers")
struct LocalServerTests {
    @Test("A request that would leave this machine is refused before it is sent")
    func staysOnThisMachine() throws {
        let remote = URL(string: "https://example.com/")!
        #expect(throws: LocalHTTPError.leftTheMachine("example.com")) {
            try LocalHTTP.admit(remote)
        }
        #expect(throws: LocalHTTPError.invalidURL) {
            try LocalHTTP.admit(URL(string: "http://mastodon.localhost/")!)
        }
    }

    /// Env unset → this suite is skipped. Env set and a host silent → `requireHealthy` fails.
    @Suite("Against the servers", .enabled(if: LocalServers.requested), .serialized)
    struct Live {
        private func client() throws -> some HTTPClient & HTTPSender {
            try LocalHTTP.client()
        }

        @Test("Detect names the Mastodon server as Mastodon")
        func mastodonIsMastodon() async throws {
            try await LocalServers.requireHealthy()
            let kind = try await Detector(http: client()).detect(LocalServers.mastodon)
            #expect(kind == .mastodon)
        }

        @Test("A Mastodon host joins and its public notes land in the store")
        func mastodonJoins() async throws {
            try await LocalServers.requireHealthy()
            let store = ItemStore()
            try await SourceJoin(
                http: client(), store: store, catalogues: EmojiCatalogueStore()
            ).join(host: LocalServers.mastodon)
            let sources = await store.sources()
            #expect(sources.map(\.host) == [LocalServers.mastodon])
            #expect(sources.map(\.kind) == [.mastodon])
            #expect(!(await store.all()).isEmpty)
        }

        @Test("A public note written to the Mastodon server is what a join then reads")
        func mastodonWriteThenRead() async throws {
            try await LocalServers.requireHealthy()
            let http = try client()
            let token = try LocalServers.writerToken()
            let marker = "fediqo-55-\(UUID().uuidString.prefix(8))"
            guard let url = Host.httpsURL(host: LocalServers.mastodon, path: "/api/v1/statuses")
            else { throw LocalHTTPError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Data("status=\(marker)&visibility=public".utf8)
            let (_, response) = try await http.send(request)
            #expect((200 ..< 300).contains(response.statusCode))

            let store = ItemStore()
            try await SourceJoin(
                http: http, store: store, catalogues: EmojiCatalogueStore()
            ).join(host: LocalServers.mastodon)
            let bodies = await store.all().map(\.body)
            #expect(bodies.contains { $0.contains(marker) })
        }

        @Test("Registering this app on the Mastodon server is answered with a client id")
        func mastodonRegisters() async throws {
            try await LocalServers.requireHealthy()
            let app = try await MastodonOAuth(host: LocalServers.mastodon, sender: client())
                .register(scopes: MastodonOAuth.scopes(writing: true))
            #expect(!app.clientID.isEmpty)
            #expect(app.host == LocalServers.mastodon)
        }

        @Test("A Discourse host is detected, joined, and has topics in the store")
        func discourseJoins() async throws {
            try await LocalServers.requireHealthy()
            let http = try client()
            #expect(try await Detector(http: http).detect(LocalServers.discourse) == .discourse)
            let store = ItemStore()
            try await SourceJoin(
                http: http, store: store, catalogues: EmojiCatalogueStore()
            ).join(host: LocalServers.discourse)
            let sources = await store.sources()
            #expect(sources.map(\.kind) == [.discourse])
            #expect(!(await store.all()).isEmpty)
        }

        @Test("A Discuz! host is detected and its boards are offered")
        func discuzJoins() async throws {
            try await LocalServers.requireHealthy()
            let http = try client()
            #expect(try await Detector(http: http).detect(LocalServers.discuz) == .discuz)
            let store = ItemStore()
            let join = SourceJoin(
                http: http, store: store, catalogues: EmojiCatalogueStore()
            )
            // look then begin(preview) is the product path: the index is read once and
            // carried, so the forum is not asked twice for one errand.
            let preview = try await join.look(host: LocalServers.discuz)
            #expect(preview.kind == .discuz)
            let step = try await join.begin(preview)
            guard case .chooseBoards(let offer) = step else {
                Issue.record("expected boards, got \(step)")
                return
            }
            #expect(!offer.boards.isEmpty)
        }
    }
}
