import Foundation
import Testing
@testable import FediqoCore

@Suite("A latest date")
struct LatestDateTests {
    private static let one = Source(host: "one.example", kind: .mastodon)

    private static func note(_ id: String, _ iso: String) -> Note {
        Note(id: id, source: one, author: "Ada", handle: "@ada@one.example", body: "hello",
             postedAt: at(iso), categories: [.public])
    }

    private static func at(_ iso: String) -> Date {
        try! Date(iso, strategy: .iso8601)
    }

    private static func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

    private func shown(_ day: String, _ notes: [Note], in zone: String) throws -> [String] {
        try #require(LatestDate(day)).shown(notes, in: Self.zone(zone)).map(\.id)
    }

    @Test("23:59:59 of the day is shown, one second later is not, in this device's time zone")
    func inclusiveToTheSecond() throws {
        let notes = [
            Self.note("last", "2026-09-01T23:59:59+08:00"),
            Self.note("next", "2026-09-02T00:00:00+08:00"),
            Self.note("older", "2026-08-01T12:00:00+08:00"),
        ]
        #expect(try shown("2026-09-01", notes, in: "Asia/Taipei") == ["last", "older"])
        // The same posts read in another zone: the day is that zone's day.
        #expect(try shown("2026-09-01", notes, in: "UTC") == ["last", "next", "older"])
        #expect(try shown("2026-08-31", notes, in: "UTC") == ["older"])
    }

    @Test("A day the clocks change on ends at its own midnight, not 86 400 s after it began")
    func daylightSavingDays() throws {
        // New York springs forward on 8 March 2026 (a 23-hour day) and falls back on
        // 1 November 2026 (a 25-hour day).
        let spring = [Self.note("in", "2026-03-08T23:59:59-04:00"), Self.note("out", "2026-03-09T00:00:00-04:00")]
        #expect(try shown("2026-03-08", spring, in: "America/New_York") == ["in"])
        let fall = [Self.note("in", "2026-11-01T23:59:59-05:00"), Self.note("out", "2026-11-02T00:00:00-05:00")]
        #expect(try shown("2026-11-01", fall, in: "America/New_York") == ["in"])
        // São Paulo skipped midnight on 4 November 2018: 3 November ended at 01:00 on the 4th.
        let skipped = try #require(LatestDate("2018-11-03")).end(in: Self.zone("America/Sao_Paulo"))
        #expect(skipped == Self.at("2018-11-04T03:00:00Z"))
    }

    @Test("It is kept as yyyy-MM-dd and refuses what is not a day")
    func text() {
        #expect(LatestDate("2026-09-01")?.text == "2026-09-01")
        #expect(LatestDate(year: 2024, month: 2, day: 29)?.text == "2024-02-29")
        for bad in ["", "2026-9", "2026-02-30", "2026-13-01", "soon", "2026-09-01-01"] {
            #expect(LatestDate(bad) == nil, "\(bad)")
        }
    }

    @Test("A picked date is the day it falls on here, and draws back as that day's start")
    func picked() {
        let taipei = Self.zone("Asia/Taipei")
        let picked = LatestDate(Self.at("2026-08-31T20:00:00Z"), in: taipei)
        #expect(picked.text == "2026-09-01")
        #expect(picked.start(in: taipei) == Self.at("2026-09-01T00:00:00+08:00"))
        #expect(LatestDate(picked.start(in: taipei), in: taipei) == picked)
    }
}
