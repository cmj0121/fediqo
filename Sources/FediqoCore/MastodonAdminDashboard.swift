import Foundation

// How a server is doing beyond the few figures of its own page (#418): who stays, month by month
// after they joined, and what it holds broken down by language, by server, by software and its
// version, by where people signed up from, and by the space it takes. Asked of a real one first
// (`MastodonAdminDashboardCaptures`); nothing here writes anywhere.
//
// **A breakdown the server does not give is not given, never none.** The server leaves out
// every key it does not know; such a key is absent here (`ServerBreakdowns.breakdown` is nil),
// while one it gives with nothing in it is given, and empty.
//
// **Who stays is read by month.** The server counts those who joined by day or by month — not
// by week — and, by month, a year back at most. Each month's cohort says, for it and every month
// after, how many of those who joined in it were seen then or later, and what share they are.
//
// **The span is the figures'** (`MastodonAdminServer.span`): whole days of the server's calendar
// (UTC), the last the day `now` falls on.

/// One breakdown of what the server holds over a span.
public struct ServerBreakdown: Sendable, Equatable, Identifiable {
    public enum Key: String, CaseIterable, Sendable {
        /// The languages of those who were active.
        case languages
        /// The servers posts came from.
        case servers
        /// The software the server runs, and each one's version.
        case software = "software_versions"
        /// Where those who signed up did it from: the server's own pages, or an app.
        case sources
        /// The space each of the server's stores takes.
        case space = "space_usage"
    }

    /// One line of it, in the server's order.
    public struct Row: Sendable, Equatable, Identifiable {
        /// The server's own word for it.
        public let id: String
        /// Its name, as the server says it to a person.
        public let name: String
        /// What the server counts of it, as it sent it: a number, or a version.
        public let value: String
        /// The same as a number, where it is one.
        public let figure: Int?
        /// The server's own way of saying it, where it gave one (`15.5 MB`, `4.0.5p0`).
        public let shown: String?
        /// What it is counted in, where the server says (`bytes`).
        public let unit: String?

        public init(id: String, name: String, value: String, figure: Int? = nil, shown: String? = nil, unit: String? = nil) {
            self.id = id
            self.name = name
            self.value = value
            self.figure = figure
            self.shown = shown
            self.unit = unit
        }
    }

    public let key: Key
    public let rows: [Row]

    public var id: Key { key }

    public init(key: Key, rows: [Row]) {
        self.key = key
        self.rows = rows
    }
}

/// The breakdowns the server gave over the last `days` days, as it said them `asOf`.
public struct ServerBreakdowns: Sendable, Equatable {
    public let days: Int
    public let asOf: Date
    /// What was asked, in its order.
    public let asked: [ServerBreakdown.Key]
    /// What was given of it, in the same order.
    public let given: [ServerBreakdown]

    public init(days: Int, asOf: Date, asked: [ServerBreakdown.Key], given: [ServerBreakdown]) {
        self.days = days
        self.asOf = asOf
        self.asked = asked
        self.given = given
    }

    /// `key`'s breakdown, or nothing where the server did not give it.
    public func breakdown(_ key: ServerBreakdown.Key) -> ServerBreakdown? {
        given.first { $0.key == key }
    }

    /// What was asked and not given.
    public var notGiven: [ServerBreakdown.Key] {
        asked.filter { breakdown($0) == nil }
    }
}

/// Those who joined in one month, and how many of them stayed in each month after.
public struct RetentionCohort: Sendable, Equatable, Identifiable {
    /// One month on from joining.
    public struct Point: Sendable, Equatable {
        /// The month, at its first day (UTC).
        public let month: Date
        /// How many of those who joined were seen in it or later.
        public let count: Int
        /// The share of those who joined they are, from 0 to 1.
        public let rate: Double

        public init(month: Date, count: Int, rate: Double) {
            self.month = month
            self.count = count
            self.rate = rate
        }
    }

    /// The month they joined in, at its first day (UTC).
    public let month: Date
    /// That month and each after it, in order.
    public let points: [Point]

    public var id: Date { month }

    public init(month: Date, points: [Point]) {
        self.month = month
        self.points = points
    }
}

/// Who stayed, over the last `months` months, as the server said it `asOf`.
public struct ServerRetention: Sendable, Equatable {
    public let months: Int
    public let asOf: Date
    public let cohorts: [RetentionCohort]

    public init(months: Int, asOf: Date, cohorts: [RetentionCohort]) {
        self.months = months
        self.asOf = asOf
        self.cohorts = cohorts
    }
}

/// How a Mastodon is doing, broken down and by who stays, read by those who answer for it
/// (#418). **Only ever as the reader**, through the signed-in door.
public struct MastodonAdminDashboard: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let dimensionsPath = "/api/v1/admin/dimensions"
    static let retentionPath = "/api/v1/admin/retention"
    /// How many lines of each breakdown are asked for.
    public static let rows = 10
    /// The most months back the server counts who stays.
    public static let mostMonths = 12

    /// `keys`, broken down over the last `days` days, said as of `now`: each given as the
    /// server gave it, a line of one this build cannot read not listed, and one the server
    /// left out not given.
    public func breakdowns(_ keys: [ServerBreakdown.Key] = ServerBreakdown.Key.allCases, days: Int, now: Date = Date()) async throws
        -> ServerBreakdowns
    {
        guard !keys.isEmpty, let span = MastodonAdminServer.span(days: days, now: now) else { throw MastodonAdminError.invalid }
        var asked: [ServerBreakdown.Key] = []
        for key in keys where !asked.contains(key) { asked.append(key) }
        let form = asked.map { ("keys[]", $0.rawValue) }
            + [("start_at", span.start), ("end_at", span.end), ("limit", String(Self.rows))]
        let body = try await ask(Self.dimensionsPath, form: form)
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<DimensionDTO>].self, from: body) else {
            throw MastodonAdminError.unreadable
        }
        let said = read.compactMap { $0.value?.breakdown }
        return ServerBreakdowns(
            days: days, asOf: now, asked: asked, given: asked.compactMap { key in said.first { $0.key == key } }
        )
    }

    /// Who stayed of those who joined in each of the last `months` months — the month `now`
    /// falls on by the server's calendar (UTC) the last of them — said as of `now`.
    public func retention(months: Int, now: Date = Date()) async throws -> ServerRetention {
        guard (1...Self.mostMonths).contains(months) else { throw MastodonAdminError.invalid }
        let calendar = MastodonAdminServer.calendar
        let parts = calendar.dateComponents([.year, .month], from: now)
        guard let thisMonth = calendar.date(from: parts),
              let first = calendar.date(byAdding: .month, value: -(months - 1), to: thisMonth)
        else { throw MastodonAdminError.invalid }
        let form = [
            ("start_at", MastodonAdminServer.day(first)), ("end_at", MastodonAdminServer.day(calendar.startOfDay(for: now))),
            ("frequency", "month"),
        ]
        let body = try await ask(Self.retentionPath, form: form)
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<CohortDTO>].self, from: body) else {
            throw MastodonAdminError.unreadable
        }
        let cohorts = read.compactMap { $0.value?.cohort }.filter { $0.month >= first && $0.month <= thisMonth }
        return ServerRetention(months: months, asOf: now, cohorts: cohorts.sorted { $0.month < $1.month })
    }

    // MARK: - The wire

    private func ask(_ path: String, form: [(String, String)]) async throws -> Data {
        do {
            return try await door.actAtAddress(path: path, method: "POST", form: form)
        } catch MastodonAuthError.http(403) {
            throw MastodonAdminError.notAllowed
        } catch MastodonHostMoreError.noSuchAddress {
            throw MastodonAuthError.http(404)
        }
    }

    struct DimensionDTO: Decodable, Sendable {
        let key: String
        let data: [StatusDTO.Lenient<RowDTO>]

        var breakdown: ServerBreakdown? {
            ServerBreakdown.Key(rawValue: key).map { ServerBreakdown(key: $0, rows: data.compactMap { $0.value?.row }) }
        }
    }

    struct RowDTO: Decodable, Sendable {
        let key: String
        let humanKey: StatusDTO.Lenient<String>?
        /// A number written as text, a version — or now and then a number as a number.
        let value: String?
        let humanValue: StatusDTO.Lenient<String>?
        let unit: StatusDTO.Lenient<String>?

        private enum Keys: String, CodingKey { case key, humanKey, value, humanValue, unit }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            key = try container.decode(String.self, forKey: .key)
            humanKey = try? container.decode(StatusDTO.Lenient<String>.self, forKey: .humanKey)
            humanValue = try? container.decode(StatusDTO.Lenient<String>.self, forKey: .humanValue)
            unit = try? container.decode(StatusDTO.Lenient<String>.self, forKey: .unit)
            value = (try? container.decode(String.self, forKey: .value)) ?? (try? container.decode(Int.self, forKey: .value)).map(String.init)
        }

        var row: ServerBreakdown.Row? {
            guard let value, !key.isEmpty else { return nil }
            let line = { (text: String?) in text.map { LineText.oneLine($0, limit: 200) }.flatMap { $0.isEmpty ? nil : $0 } }
            let id = LineText.oneLine(key, limit: 200)
            return ServerBreakdown.Row(
                id: id, name: line(humanKey?.value) ?? id, value: LineText.oneLine(value, limit: 200),
                figure: MastodonFigure.read(value), shown: line(humanValue?.value), unit: line(unit?.value)
            )
        }
    }

    struct CohortDTO: Decodable, Sendable {
        let period: StatusDTO.LenientMoment
        let data: [StatusDTO.Lenient<PointDTO>]

        var cohort: RetentionCohort? {
            period.value.map { RetentionCohort(month: $0, points: data.compactMap { $0.value?.point }) }
        }
    }

    struct PointDTO: Decodable, Sendable {
        let date: StatusDTO.LenientMoment
        let rate: Double
        let value: MastodonFigure

        var point: RetentionCohort.Point? {
            guard let month = date.value, let count = value.value, rate.isFinite, (0...1).contains(rate) else { return nil }
            return RetentionCohort.Point(month: month, count: count, rate: rate)
        }
    }
}
