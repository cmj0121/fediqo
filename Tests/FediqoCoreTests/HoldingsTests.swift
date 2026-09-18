import Foundation
import Testing
@testable import FediqoCore

@Suite("What this device holds, counted")
struct HoldingsTests {
    private let first = Source(host: "first.example", kind: .mastodon)
    private let second = Source(host: "second.example", kind: .discuz)

    /// A fixed calendar, so a week and a month start where the test says they do on any machine.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func note(_ id: String, _ postedAt: Date, from source: Source) -> Note {
        Note(id: id, source: source, author: "Ada", handle: "@ada", body: "hello",
             postedAt: postedAt, origins: [.publicTimeline])
    }

    private var notes: [Note] {
        [
            note("1", day(2026, 9, 14), from: first),
            note("2", day(2026, 9, 16), from: first),
            note("3", day(2026, 9, 2), from: second),
            note("4", day(2026, 7, 30), from: first),
        ]
    }

    @Test("Totals and by source come from the same notes")
    func totalsAndBySource() {
        let held = Holdings(notes: notes, per: .month, calendar: calendar)
        #expect(held.posts == 4)
        #expect(held.bySource == ["first.example": 3, "second.example": 1])
        #expect(held.posts(host: "FIRST.example") == 3)
        #expect(held.posts(host: "never.example") == 0)
    }

    @Test("By month: newest first, only months that hold a post")
    func byMonth() {
        let held = Holdings(notes: notes, per: .month, calendar: calendar)
        #expect(held.byPeriod == [
            Holdings.Bucket(start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!, posts: 3),
            Holdings.Bucket(start: calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!, posts: 1),
        ])
    }

    @Test("By week: the same notes, cut finer")
    func byWeek() {
        let held = Holdings(notes: notes, per: .week, calendar: calendar)
        #expect(held.byPeriod.map(\.posts) == [2, 1, 1])
        #expect(held.byPeriod.first?.start == calendar.date(from: DateComponents(year: 2026, month: 9, day: 14)))
        #expect(held.byPeriod.map(\.posts).reduce(0, +) == held.posts)
    }

    @Test("Nothing held is zero everywhere")
    func empty() {
        let held = Holdings(notes: [], per: .week)
        #expect(held.posts == 0)
        #expect(held.bySource.isEmpty)
        #expect(held.byPeriod.isEmpty)
    }

    @Test("Keeping forever, or a count that is not positive, has no cutoff", arguments: [nil, 0, -1, -12] as [Int?])
    func foreverHasNoCutoff(months: Int?) {
        #expect(KeepPolicy.cutoff(keepingMonths: months, from: day(2026, 9, 18), calendar: calendar) == nil)
    }

    @Test("Keeping the latest months cuts that many months back")
    func cutoff() {
        #expect(KeepPolicy.cutoff(keepingMonths: 3, from: day(2026, 9, 18), calendar: calendar) == day(2026, 6, 18))
    }

    @Test("Only a narrower window shortens; a wider one or forever drops nothing")
    func shortens() {
        #expect(KeepPolicy.shortens(from: nil, to: 12))
        #expect(KeepPolicy.shortens(from: 6, to: 3))
        #expect(!KeepPolicy.shortens(from: 3, to: 6))
        #expect(!KeepPolicy.shortens(from: 3, to: 3))
        #expect(!KeepPolicy.shortens(from: 3, to: nil))
        #expect(!KeepPolicy.shortens(from: nil, to: nil))
    }
}
