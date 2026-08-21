import Foundation
import Testing
@testable import FediqoCore

/// The directory has a built-in fallback, which means a decoding mistake looks exactly like
/// being offline. This decodes the real shape of `api.joinmastodon.org/servers` so it cannot
/// go wrong quietly again.
@Suite("The suggested-server list decodes the shape the directory actually sends")
struct ServerDirectoryTests {
    private let json = """
    [
      {
        "domain": "mastodon.social",
        "version": "4.7.0",
        "description": "The original server of Mastodon.\\r\\n\\r\\n",
        "languages": ["en"],
        "region": "",
        "categories": ["general"],
        "total_users": 921100,
        "approval_required": false
      },
      {
        "domain": "g0v.social",
        "description": "<p>Taiwanese civic tech &amp; more</p>",
        "languages": ["zh"],
        "region": "asia",
        "total_users": 4200
      }
    ]
    """

    @Test("total_users is a number, not a string")
    func numericUserCount() throws {
        let entries = try ServerDirectory.decoder.decode([ServerDirectory.Entry].self, from: Data(json.utf8))
        #expect(entries.map(\.asSuggestion.totalUsers) == [921_100, 4_200])
    }

    @Test("A reachable directory is used, biggest first, and says it was the directory")
    func liveDirectory() async {
        stubRoutes.on("api.joinmastodon.org", "/servers", status: 200, body: json)
        let result = await ServerDirectory(session: stubbedSession()).suggested(limit: 5)

        #expect(result.origin == .joinMastodon)
        #expect(result.servers.map(\.host) == ["mastodon.social", "g0v.social"])
    }

    @Test("An unreachable directory falls back to the list built in here, and says so")
    func offlineDirectory() async {
        // api.joinmastodon.org answers 404 for anything not registered above; this suite
        // registers /servers only in the test that wants it, and Swift Testing may run them
        // in either order, so this one asks for a path that is never registered.
        let result = await ServerDirectory(session: stubbedSession(), endpoint: URL(string: "https://directory.test/down")!)
            .suggested(limit: 3)

        #expect(result.origin == .builtIn)
        #expect(result.servers.count == 3)
        #expect(result.servers.allSatisfy { !$0.host.isEmpty })
    }

    @Test("An empty region is no region, and descriptions arrive as plain text")
    func tidying() throws {
        let suggestions = try ServerDirectory.decoder.decode([ServerDirectory.Entry].self, from: Data(json.utf8)).map(\.asSuggestion)
        #expect(suggestions[0].region == nil)
        #expect(suggestions[1].region == "asia")
        #expect(suggestions[0].summary == "The original server of Mastodon.")
        #expect(suggestions[1].summary == "Taiwanese civic tech & more")
    }
}
