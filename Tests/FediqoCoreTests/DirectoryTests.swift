import Foundation
import Testing
@testable import FediqoCore

@Suite("The joinmastodon catalog")
struct DirectoryTests {
    @Test("Directory maps first.example and second.example")
    func mapsTwoEntries() async throws {
        let http = FixtureHTTP([
            "https://api.joinmastodon.org/servers": .body(Fixtures.json("servers")),
        ])
        let servers = try await ServerDirectory(http: http).servers()
        #expect(servers.map(\.domain) == ["first.example", "second.example"])
        #expect(servers[0].summary == "The flagship server")
        #expect(servers[0].language == "en")
        #expect(servers[0].region == "europe")
        #expect(servers[0].category == "general")
        #expect(servers[0].users == 1_000_000)
        #expect(servers[0].approvalRequired == false)
        #expect(servers[0].thumbnail == URL(string: "https://proxy.example/mastodon.png"))
        #expect(servers[0].id == "first.example")
        #expect(servers[1].approvalRequired == true)
        #expect(servers[1].thumbnail == nil)
        #expect(servers[1].users == 40_000)
        #expect(await http.requested.count == 1)
        #expect(await http.requested.first?.host == "api.joinmastodon.org")
    }
}
