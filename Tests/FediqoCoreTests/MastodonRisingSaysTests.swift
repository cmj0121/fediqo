import Foundation
import Testing
@testable import FediqoCore

/// #320: what Fediqo believes a Mastodon says is rising on it beside posts, held against the
/// real one this checkout brings up (`make servers`, Mastodon 4.6.6) — read through this app's
/// own reader, `MastodonRising`, and beside it asked plainly for the part of each answer the
/// reader rests on (`MastodonRisingCaptures`).
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb` makes one hashtag and one
/// link rise, as it makes a post), and nothing here writes or switches anything: what the two
/// answer once an administrator has switched what is rising off can be asked only from inside
/// the server; it was, and is in the captures' table.
///
/// **Asked gently.** A run makes some ten requests and no registration.
@Suite("What a Mastodon says is rising beside posts", .enabled(if: LocalServers.requested), .serialized)
struct MastodonRisingSaysTests {
    private static let host = LocalServers.mastodon

    private func plain(_ path: String, as token: String? = nil) async throws -> (status: Int, list: [[String: Any]]) {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return (response.statusCode, (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] ?? [])
    }

    private func days(_ entry: [String: Any]) throws -> [[String: Any]] {
        try #require(entry["history"] as? [[String: Any]])
    }

    @Test("The hashtag the seed made rise is given to anyone, by the name it was written with, with seven days of use each figure a string: read as that hashtag, its posts and people those of the two newest days added")
    func theHashtagsRising() async throws {
        try await LocalServers.requireHealthy()
        let said = try await MastodonRising(http: try LocalHTTP.client(), host: Self.host).tags()
        let rising = try #require(said.first { $0.tag.text == "#FediqoRising" })
        #expect(said.count == 1)

        let nobody = try await plain(MastodonRising.tagsPath), writer = try await plain(MastodonRising.tagsPath, as: try LocalServers.writerToken())
        let entry = try #require(nobody.list.first)
        #expect(nobody.status == 200 && entry["name"] as? String == "FediqoRising")
        #expect((entry["url"] as? String)?.hasSuffix("/tags/fediqorising") == true, "its address is folded, its name is not")
        let history = try days(entry)
        #expect(history.count == 7 && history.allSatisfy { Set($0.keys) == ["day", "accounts", "uses"] && $0.values.allSatisfy { $0 is String } })
        let moments = history.compactMap { ($0["day"] as? String).flatMap(Int.init) }
        #expect(moments == moments.sorted(by: >) && moments.allSatisfy { $0 % 86_400 == 0 }, "newest first, a day at its midnight")
        func sum(_ key: String) -> Int { history.prefix(2).compactMap { ($0[key] as? String).flatMap(Int.init) }.reduce(0, +) }
        #expect(rising.use == RisingUse(posts: sum("uses"), people: sum("accounts"), days: 2))
        // Signed in, the same hashtag, and whether the reader follows it.
        #expect(writer.list.first?["name"] as? String == "FediqoRising" && writer.list.first?["following"] is Bool)
        #expect(entry["following"] == nil)
    }

    @Test("The link the seed made rise is given to anyone, with what the server holds of the page as plain words — a title with marks in it as written — and the same seven days: read as an address this device would follow, the host it leads to, and those words")
    func theLinksRising() async throws {
        try await LocalServers.requireHealthy()
        let said = try await MastodonRising(http: try LocalHTTP.client(), host: Self.host).links()
        let rising = try #require(said.first)
        #expect(said.count == 1 && rising.link.url.absoluteString == "https://elsewhere.example/stories/rising")
        #expect(rising.link.host == "elsewhere.example" && rising.title == "A story <b>rising</b> & more")
        #expect(rising.words == "What the page says of itself." && rising.use.days == 2 && (rising.use.people ?? 0) > 0)

        let nobody = try await plain(MastodonRising.linksPath)
        let entry = try #require(nobody.list.first)
        #expect(entry["title"] as? String == rising.title && entry["url"] as? String == rising.link.text)
        #expect(entry["image"] is NSNull && entry["type"] as? String == "link" && entry["provider_name"] as? String == "Elsewhere")
        #expect(try days(entry).count == 7)
    }

    @Test("Neither address answers that it is not there, and asking for a stretch of twenty is taken")
    func eachAddressIsServed() async throws {
        try await LocalServers.requireHealthy()
        for path in [MastodonRising.tagsPath, MastodonRising.linksPath] {
            let asked = try await plain(path + "?limit=\(MastodonRising.stretch)")
            #expect(asked.status == 200 && asked.list.count == 1, "\(path)")
        }
    }
}
