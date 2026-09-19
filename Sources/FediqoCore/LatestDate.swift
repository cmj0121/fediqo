import Foundation

/// The last day a person wants any timeline to show (#22): one cut-off, applied after a
/// timeline's rules, to every timeline and to anything else that lists held posts.
///
/// **A calendar day, not an instant.** The day is read in whatever time zone the device is in
/// when a list is drawn, so "1 September" still means the whole of 1 September after the
/// device moves. Newer posts stay held; they are only not shown.
public struct LatestDate: Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day], from: date) == parts else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `timeZone` — what a date picker's answer means.
    public init(_ date: Date, in timeZone: TimeZone = .current) {
        let parts = Self.calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)!
    }

    /// `yyyy-MM-dd`, the form it is kept in.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2] else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public var text: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// The first instant of the next day in `timeZone`; everything before it is shown. From the
    /// calendar and not start plus 86 400 s, because a day a clock changes on is 23 or 25 hours.
    public func end(in timeZone: TimeZone = .current) -> Date {
        let calendar = Self.calendar(timeZone)
        let start = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        return calendar.dateInterval(of: .day, for: start)!.end
    }

    /// The date shown in a date picker for this day: its start in `timeZone`.
    public func start(in timeZone: TimeZone = .current) -> Date {
        Self.calendar(timeZone).date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The notes posted on or before this day, in the order given.
    public func shown(_ notes: [Note], in timeZone: TimeZone = .current) -> [Note] {
        let end = end(in: timeZone)
        return notes.filter { $0.postedAt < end }
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
