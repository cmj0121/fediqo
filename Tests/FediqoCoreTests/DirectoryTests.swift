import Foundation
import Testing
@testable import FediqoCore

@Suite("The joinmastodon catalog")
struct DirectoryTests {
    @Test("Directory maps two entries")
    func mapsTwoEntries() async throws {
        // `api.joinmastodon.org` is the real address this app asks, in live code, and the point
        // of the last two expectations. Everything it answers with here is written by this test.
        let servers = """
        [
          {
            "domain": "first.example",
            "description": "The first server",
            "language": "en",
            "region": "europe",
            "category": "general",
            "total_users": 1000000,
            "last_week_users": 50000,
            "approval_required": false,
            "proxied_thumbnail": "https://proxy.example/first.png"
          },
          {
            "domain": "second.example",
            "description": "A server that asks first",
            "language": "en",
            "region": "north_america",
            "category": "tech",
            "total_users": 40000,
            "last_week_users": 2000,
            "approval_required": true,
            "proxied_thumbnail": null
          }
        ]
        """
        let http = FixtureHTTP([
            "https://api.joinmastodon.org/servers": .body(Data(servers.utf8)),
        ])
        let directory = try await ServerDirectory(http: http).servers()
        #expect(directory.map(\.domain) == ["first.example", "second.example"])
        #expect(directory[0].summary == "The first server")
        #expect(directory[0].language == "en")
        #expect(directory[0].region == "europe")
        #expect(directory[0].category == "general")
        #expect(directory[0].users == 1_000_000)
        #expect(directory[0].weekUsers == 50_000)
        #expect(directory[0].approvalRequired == false)
        #expect(directory[0].thumbnail == URL(string: "https://proxy.example/first.png"))
        #expect(directory[0].id == "first.example")
        #expect(directory[1].approvalRequired == true)
        #expect(directory[1].thumbnail == nil)
        #expect(directory[1].users == 40_000)
        #expect(directory[1].weekUsers == 2_000)
        #expect(await http.requested.count == 1)
        #expect(await http.requested.first?.host == "api.joinmastodon.org")
    }
}
