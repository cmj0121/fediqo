import Foundation
import Testing
@testable import FediqoCore

/// #418, in the half of it Core holds: how a server is doing broken down by language, server,
/// software and its version, where people signed up from and the space it takes, over a span;
/// and who stays, month by month — from what a real 4.6.6 answered (`MastodonAdminDashboardCaptures`).
@Suite("Tending a server: how it is doing, broken down and by who stays")
struct MastodonAdminDashboardTests {
    private typealias Captures = MastodonAdminDashboardCaptures

    private static let token = MastodonToken(host: Captures.host, accessToken: "tok-418", clientID: "cid", clientSecret: "secret")
    private static let now = ISO8601DateFormatter().date(from: "2026-10-29T13:30:00Z")!

    private func reader(_ routes: [String: PeopleServer.Answer]) throws -> (MastodonAdminDashboard, PeopleServer) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonAdminDashboard(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    @Test("Each breakdown is the server's, line by line in its order, a count as a number, a version as written, a size with its unit and the server's own way of saying it — asked over whole days ending the day after the last, and said as of when it was read")
    func breakdowns() async throws {
        let (reader, server) = try reader([MastodonAdminDashboard.dimensionsPath: .json(Captures.dimensions)])
        let said = try await reader.breakdowns(days: 7, now: Self.now)
        #expect(said.asOf == Self.now && said.days == 7 && said.notGiven.isEmpty)
        #expect(said.given.map(\.key) == ServerBreakdown.Key.allCases)
        let servers = try #require(said.breakdown(.servers))
        #expect(servers.rows.map(\.id) == ["mastodon.localhost", "elsewhere.example"] && servers.rows.map(\.figure) == [85, 3])
        let software = try #require(said.breakdown(.software))
        #expect(software.rows.first.map { $0.name == "Mastodon" && $0.value == "4.6.6" && $0.figure == nil } == true)
        #expect(software.rows[1].shown == "4.0.5p0")
        #expect(said.breakdown(.sources)?.rows.first.map { $0.name == "Website" && $0.figure == 37 } == true)
        let space = try #require(said.breakdown(.space)?.rows.first)
        #expect(space.figure == 16_415_767 && space.unit == "bytes" && space.shown == "15.7 MB")

        let body = try #require(await server.sent.last?.body)
        #expect(body.contains("start_at=2026-10-23") && body.contains("end_at=2026-10-30") && body.contains("limit=10"))
        for key in ServerBreakdown.Key.allCases {
            #expect(body.contains("keys%5B%5D=\(key.rawValue)") || body.contains("keys[]=\(key.rawValue)"), "\(key)")
        }
    }

    @Test("A breakdown the server gives with nothing in it is given, and empty; one it leaves out is not given — never read as none")
    func notGiven() async throws {
        let (reader, _) = try reader([MastodonAdminDashboard.dimensionsPath: .json(Captures.languagesOnly)])
        let said = try await reader.breakdowns([.languages, .software, .languages], days: 30, now: Self.now)
        #expect(said.asked == [.languages, .software])
        #expect(said.breakdown(.languages)?.rows == [])
        #expect(said.breakdown(.software) == nil && said.notGiven == [.software])
    }

    @Test("Who stays is asked by month, from the first day of the first month to the day it is read, a cohort a month in order, each with how many of those who joined then were seen in it or after, and their share")
    func retention() async throws {
        let (reader, server) = try reader([MastodonAdminDashboard.retentionPath: .json(Captures.retention)])
        let said = try await reader.retention(months: 3, now: Self.now)
        #expect(said.asOf == Self.now && said.months == 3)
        let month = { (text: String) in ISO8601DateFormatter().date(from: text)! }
        #expect(said.cohorts.map(\.month) == [month("2026-08-01T00:00:00Z"), month("2026-09-01T00:00:00Z"), month("2026-10-01T00:00:00Z")])
        #expect(said.cohorts.map(\.points.count) == [3, 2, 1])
        let october = try #require(said.cohorts.last?.points.first)
        #expect(october.count == 3 && abs(october.rate - 0.081) < 0.001 && october.month == month("2026-10-01T00:00:00Z"))
        let body = try #require(await server.sent.last?.body)
        #expect(body.contains("start_at=2026-08-01") && body.contains("end_at=2026-10-29") && body.contains("frequency=month"))
    }

    @Test("Without the standing it is not allowed; a body that is none is unreadable; a span of no days, of more than a year or of no breakdowns, or more months than the server counts, is asked nothing")
    func refusals() async throws {
        let (reader, server) = try reader([
            MastodonAdminDashboard.retentionPath: .json(Captures.writerRetention, status: 403),
            MastodonAdminDashboard.dimensionsPath: .json("{}"),
        ])
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await reader.retention(months: 6) }
        await #expect(throws: MastodonAdminError.unreadable) { _ = try await reader.breakdowns(days: 7) }
        let before = await server.asked.count
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.breakdowns(days: 0) }
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.breakdowns(days: 367) }
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.breakdowns([], days: 7) }
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.retention(months: 0) }
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.retention(months: 13) }
        #expect(await server.asked.count == before)
    }
}
