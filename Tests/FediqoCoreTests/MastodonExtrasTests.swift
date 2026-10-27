import Foundation
import Testing
@testable import FediqoCore

@Suite("What else a Mastodon keeps for the person: a year, collections, a thread still gathered")
struct MastodonExtrasTests {
    private let host = MastodonFixture.host

    private func door(_ server: FixtureSender) throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        return MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
    }

    @Test("The source's word on what it still gathers reads as when to ask again and how much it found; no word, or no wait, is nothing")
    func gathering() {
        let said = MastodonGathering(header: MastodonExtrasCaptures.gathering)
        #expect(said == MastodonGathering(retry: 3, found: 0))
        #expect(MastodonGathering(header: nil) == nil)
        #expect(MastodonGathering(header: "") == nil)
        #expect(MastodonGathering(header: #"id="x""#) == nil)
        #expect(MastodonGathering(header: "retry=0")?.retry == 1)
        #expect(MastodonGathering(header: "retry=86400")?.retry == MastodonGathering.longest)
    }

    @Test("A thread read as the reader says what its source still gathers; one that says nothing gathers nothing")
    func threadGathering() async throws {
        let context = #"{"ancestors":[],"descendants":[]}"#
        let gathering = FixtureSender(["/api/v1/statuses/7/context": .json(context)], headers: [MastodonGathering.header: MastodonExtrasCaptures.gathering])
        let thread = try await MastodonPost(door: try door(gathering)).conversation(id: "7", source: Source(host: host, kind: .mastodon))
        #expect(thread.gathering?.retry == 3)
        let quiet = FixtureSender(["/api/v1/statuses/7/context": .json(context)])
        #expect(try await MastodonPost(door: try door(quiet)).conversation(id: "7", source: Source(host: host, kind: .mastodon)).gathering == nil)
    }

    @Test("A year looked back on reads whole: the kind of poster, each month, and where the source shows it")
    func years() async throws {
        let server = FixtureSender(["/api/v1/annual_reports": .json(MastodonExtrasCaptures.years)])
        let years = try await MastodonYears(door: try door(server)).years(source: Source(host: host, kind: .mastodon))
        let year = try #require(years.first)
        #expect(year.year == 2025 && year.archetype == "lurker")
        #expect(year.months == [.init(month: 12, posts: 0, followers: 0)])
        #expect(year.tags.isEmpty && year.mostBoosted == nil)
        #expect(year.shared?.host() == "mastodon.localhost")
    }

    @Test("A host with no such address says so, and none made is no year")
    func noYears() async throws {
        let older = FixtureSender(["/api/v1/annual_reports": .json("<html>The page you were looking for doesn't exist</html>", status: 404)])
        await #expect(throws: MastodonHostMoreError.noSuchAddress) {
            _ = try await MastodonYears(door: try door(older)).years(source: Source(host: host, kind: .mastodon))
        }
        let none = FixtureSender(["/api/v1/annual_reports": .json(#"{"annual_reports":[],"accounts":[],"statuses":[]}"#)])
        #expect(try await MastodonYears(door: try door(none)).years(source: Source(host: host, kind: .mastodon)).isEmpty)
    }

    @Test("Somebody's collections are read with no token, and the people in one are those in it, in its order, and not who made it")
    func collections() async throws {
        let source = Source(host: "mastodon.localhost", kind: .mastodon)
        let http = FixtureHTTP([
            "https://mastodon.localhost/api/v1/accounts/117510774478826484/collections": .text(MastodonExtrasCaptures.collections),
            "https://mastodon.localhost/api/v1/collections/117510778888932060": .text(MastodonExtrasCaptures.collection),
        ])
        let reader = MastodonCollections(http: http, host: source.host)
        let collections = try await reader.of("117510774478826484", source: source)
        #expect(collections == [PersonCollection(id: "117510778888932060", name: "Friends of the fixture", words: "People worth reading", count: 2)])
        let people = try await reader.people(in: "117510778888932060", source: source)
        #expect(people.map(\.accountID) == ["117510774514744569", "117510774521396949"])
        #expect(await http.requested.allSatisfy { $0.host() == "mastodon.localhost" })
    }
}
