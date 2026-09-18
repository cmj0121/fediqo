import Foundation
import FediqoCore
import Testing
@testable import FediqoUI

/// #22: one latest date, chosen in Preferences, that every timeline stops at.
@Suite("The latest date every timeline stops at")
@MainActor
struct LatestDateShellTests {
    private let one = Source(host: "one.example", kind: .mastodon)
    private let latest = LatestDate("2026-09-01")!

    private func note(_ id: String, _ postedAt: Date, _ categories: Set<FediqoCore.Category>, _ body: String) -> Note {
        Note(id: id, source: one, author: "Ada", handle: "@ada@one.example", body: body,
             postedAt: postedAt, categories: categories)
    }

    /// The last second of the day and the first one after it, in this device's time zone, once
    /// for each thing a timeline might be told apart by.
    private var notes: [Note] {
        let end = latest.end()
        return [
            note("public.after", end, [.public], "swift"),
            note("trend.after", end, [.trends], "swift"),
            note("public.last", end.addingTimeInterval(-1), [.public], "swift"),
            note("trend.last", end.addingTimeInterval(-1), [.trends], "swift"),
            note("other.last", end.addingTimeInterval(-1), [.public], "other"),
        ]
    }

    @Test("All, Trends and a written timeline show 23:59:59 of the day and nothing a second later")
    func everyTimelineStops() throws {
        let swift = try #require(Rule.keyword("swift", in: .every))
        let written = TimelineDefinition(name: "Swift", rules: [swift])
        func ids(_ query: TimelineQuery, _ latest: LatestDate?) -> [String] {
            query.items(from: notes, among: [written], latest: latest).map(\.noteID)
        }
        #expect(ids(.all, latest) == ["public.last", "trend.last", "other.last"])
        #expect(ids(.trends, latest) == ["trend.last"])
        #expect(ids(.written(written.id), latest) == ["public.last", "trend.last"])
        // No date, the default: nothing is cut.
        #expect(ids(.all, nil) == notes.map(\.id))
        #expect(ids(.trends, nil) == ["trend.after", "trend.last"])
        #expect(ids(.written(written.id), nil) == ["public.after", "trend.after", "public.last", "trend.last"])
    }

    @Test("Clearing the date shows the newer posts again without asking any server")
    func clearingNeedsNoRefetch() async {
        L10n.language = .english
        let http = FixtureHTTP([
            "/": .text(#"<html><head><meta name="application-name" content="Mastodon"></head></html>"#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text(#"""
            [
              {"id": "1", "uri": "https://first.example/s/old", "created_at": "2024-01-01T00:00:00.000Z",
               "content": "<p>Old</p>", "visibility": "public",
               "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}},
              {"id": "2", "uri": "https://first.example/s/new", "created_at": "2024-12-01T00:00:00.000Z",
               "content": "<p>New</p>", "visibility": "public",
               "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}
            ]
            """#),
        ])
        let session = ShellSession(http: http)
        session.hostname = "first.example"
        await session.add()
        await session.confirm()
        let asked = await http.requested.count
        let june = LatestDate("2024-06-01")!

        #expect(TimelineQuery.all.items(from: session.notes, latest: june).map(\.noteID) == ["https://first.example/s/old"])
        // Hidden, not dropped: the store still holds the newer post.
        #expect(await session.store.all().count == 2)
        #expect(TimelineQuery.all.items(from: session.notes, latest: nil).map(\.noteID) == [
            "https://first.example/s/new", "https://first.example/s/old",
        ])
        #expect(await http.requested.count == asked)
    }

    @Test("The chosen date holds after a relaunch, and clearing it holds too")
    func survivesRelaunch() throws {
        let name = "fediqo.test.latest.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Constructing prefs sets the shell's language from what is kept; English, as every
        // other suite here sets it, so a run in parallel is not moved.
        defaults.set("en", forKey: "fediqo.dummy.language")

        #expect(DummyPrefs(defaults: defaults).latestDate == nil)
        DummyPrefs(defaults: defaults).latestDate = latest
        #expect(DummyPrefs(defaults: defaults).latestDate == latest)
        DummyPrefs(defaults: defaults).latestDate = nil
        #expect(DummyPrefs(defaults: defaults).latestDate == nil)
        defaults.set("not a day", forKey: "fediqo.dummy.latestDate")
        #expect(DummyPrefs(defaults: defaults).latestDate == nil)
    }

    @Test("The timeline's mark says the date in both languages")
    func markStrings() {
        for language in [DummyLanguage.english, .taiwanese] {
            for key in ["timeline.latest", "timeline.latest.label"] {
                #expect(L10n.t(key, language: language).contains("%@"), "\(key) \(language)")
            }
            for key in ["prefs.latest", "prefs.latest.date", "prefs.latest.footer"] {
                #expect(L10n.t(key, language: language) != key, "\(key) \(language)")
            }
        }
    }
}
