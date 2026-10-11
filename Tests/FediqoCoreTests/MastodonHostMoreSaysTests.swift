import Foundation
import Testing
@testable import FediqoCore

/// #321: what Fediqo believes a Mastodon says of itself beyond its document, held against the
/// real one this checkout brings up (`make servers`, Mastodon 4.6.6) — read through this app's
/// own reader, `MastodonHostMore`, and beside it asked plainly for the part of each answer the
/// reader rests on (`MastodonHostMoreCaptures`).
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Nothing here writes, and nothing is switched.** What the three answer once an
/// administrator has written a longer account, or switched two of them off, can be asked only
/// from inside the server; it was, and is in the captures' table.
///
/// **Asked gently.** A run makes a dozen requests and no registration.
@Suite("What a Mastodon says of itself beyond its document", .enabled(if: LocalServers.requested), .serialized)
struct MastodonHostMoreSaysTests {
    private static let host = LocalServers.mastodon

    private func plain(_ path: String, as token: String? = nil) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return (response.statusCode, body)
    }

    @Test("Its longer account, never written, is present and empty — to anyone, the same bytes — and is read as an account with no paragraphs")
    func theLongerAccount() async throws {
        try await LocalServers.requireHealthy()
        let said = try await MastodonHostMore(http: try LocalHTTP.client(), host: Self.host).longerAccount()
        #expect(said == HostAccount(paragraphs: []))
        let nobody = try await plain(MastodonHostMore.accountPath)
        let writer = try await plain(MastodonHostMore.accountPath, as: try LocalServers.writerToken())
        #expect(nobody.status == 200 && nobody.body == Data(MastodonHostMoreCaptures.unwritten.utf8) && writer.body == nobody.body)
    }

    @Test("The servers it knows are bare names in a list and nothing else, given to anyone: the one the seed made it know, read as a name and counted")
    func theServersItKnows() async throws {
        try await LocalServers.requireHealthy()
        let said = try await MastodonHostMore(http: try LocalHTTP.client(), host: Self.host).knownServers()
        #expect(said == HostServers(counted: 1, names: ["elsewhere.example"]))
        let nobody = try await plain(MastodonHostMore.serversPath)
        let writer = try await plain(MastodonHostMore.serversPath, as: try LocalServers.writerToken())
        #expect(nobody.status == 200 && nobody.body == Data(MastodonHostMoreCaptures.servers.utf8) && writer.body == nobody.body)
    }

    @Test("How busy it has been is twelve weeks, newest first, every figure a string and the week a moment in seconds: read as twelve weeks of counts, the newest holding what the seed made happen")
    func howBusyItHasBeen() async throws {
        try await LocalServers.requireHealthy()
        let said = try await MastodonHostMore(http: try LocalHTTP.client(), host: Self.host).activity()
        #expect(said.count == 12 && said == said.sorted { $0.week > $1.week })
        let newest = try #require(said.first)
        #expect((newest.posts ?? 0) > 0 && (newest.signIns ?? 0) > 0 && (newest.newPeople ?? 0) > 0)
        #expect(abs(newest.week.timeIntervalSinceNow) < 8 * 86_400, "the newest week is this one")
        #expect(said.dropFirst().allSatisfy { $0.posts == 0 && $0.signIns == 0 && $0.newPeople == 0 })

        let nobody = try await plain(MastodonHostMore.activityPath)
        let weeks = try #require(try JSONSerialization.jsonObject(with: nobody.body) as? [[String: Any]])
        #expect(nobody.status == 200 && weeks.count == 12)
        for week in weeks {
            #expect(Set(week.keys) == ["week", "statuses", "logins", "registrations"] && week.values.allSatisfy { $0 is String })
        }
        #expect(weeks.first?["statuses"] as? String == newest.posts.map(String.init))
    }

    @Test("None of the three answers that its address is not there on a new server, and an address beside them that the server does not serve does")
    func eachAddressIsServed() async throws {
        try await LocalServers.requireHealthy()
        for path in [MastodonHostMore.accountPath, MastodonHostMore.serversPath, MastodonHostMore.activityPath] {
            let answer = try await plain(path)
            #expect(answer.status == 200 && !MastodonHostNotFound.isOfTheAddress(status: answer.status, body: answer.body), "\(path)")
        }
        let none = try await plain("/api/v1/instance/fediqo_no_such")
        #expect(MastodonHostNotFound.isOfTheAddress(status: none.status, body: none.body))
    }
}
