import FediqoCore
import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// #248: the person picks a span of days and a source, presses, is asked first, and what goes is
/// in no timeline, no search and no count afterwards — nor after a relaunch.
@Suite("Letting go by dates")
@MainActor
struct SpanTests {
    private static let alpha = Source(host: "alpha.test", kind: .mastodon)
    private static let beta = Source(host: "beta.test", kind: .mastodon)
    private static let calendar = Calendar.current
    private static let today = calendar.startOfDay(for: Date())

    private static func day(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: today)!
    }

    /// Posted at noon `daysAgo` days ago, so a day's edge never decides what a test says.
    private static func note(_ id: String, daysAgo: Int, from source: Source, holding: Holding = .arrived) -> Note {
        Note(id: id, source: source, author: "Ada", handle: "@ada", body: "hello \(id)",
             postedAt: day(daysAgo).addingTimeInterval(12 * 3_600), categories: [.public], holding: holding)
    }

    /// Alpha: three, five and nine days ago, the five-days one a search's find; beta: five days ago.
    private static func held() -> ItemStore {
        ItemStore(sources: [alpha, beta], notes: [
            note("a3", daysAgo: 3, from: alpha), note("a5", daysAgo: 5, from: alpha, holding: .aside),
            note("a9", daysAgo: 9, from: alpha), note("b5", daysAgo: 5, from: beta),
        ])
    }

    @Test("The span is whole days, both ends inside, in this device's calendar")
    func spanIsWholeDays() {
        let span = SpanSection.span(from: Self.day(6), to: Self.day(4))
        #expect(span.lowerBound == Self.day(6))
        #expect(span.upperBound == Self.day(3), "the day after the last, not inside")
        #expect(span.contains(Self.day(4).addingTimeInterval(86_399)), "the last day's last second")
        let one = SpanSection.span(from: Self.day(4), to: Self.day(4))
        #expect(one.lowerBound == Self.day(4) && one.upperBound == Self.day(3), "one day is one day")
    }

    @Test("A span from one source goes from All, the search, the count and the store, and the rest stays")
    func spanFromOneSourceGoes() async {
        let store = Self.held()
        let session = ShellSession(http: FixtureHTTP(), store: store)
        let saves = Counter()
        session.persist = { await saves.bump() }
        let measures = Counter()
        session.measureStore = { await measures.bump() }
        await session.reloadFromStore()
        #expect(session.holdings.posts == 4 && session.aside.map(\.id) == ["a5"])

        let span = SpanSection.span(from: Self.day(6), to: Self.day(4))
        #expect(await session.spanHeld(span, host: Self.alpha.host) == 1, "the count the pickers show")
        #expect(await session.letGo(span: span, host: Self.alpha.host) == 1)

        #expect(session.notes.map(\.id).sorted() == ["a3", "a9", "b5"], "All no longer shows it")
        #expect(session.aside.isEmpty, "the search no longer finds it")
        #expect(session.holdings.posts == 3 && session.holdings.aside == 0)
        #expect(session.holdings.posts(host: Self.alpha.host) == 2)
        #expect(session.holdings.posts(host: Self.beta.host) == 1, "another source is untouched")
        let snapshot = await store.snapshot()
        #expect(snapshot.notes.count == session.holdings.posts, "the count and the store agree")
        #expect(await saves.value == 1, "written once, so it holds after a relaunch")
        #expect(await measures.value == 1, "and the disk figure read again")
        #expect(session.storeBytes == 1)
    }

    @Test("Every source, and every host with a post held is offered — a removed source's too")
    func everySourceAndRemovedHosts() async {
        let store = ItemStore(sources: [Self.alpha], notes: [
            Self.note("a5", daysAgo: 5, from: Self.alpha), Self.note("b5", daysAgo: 5, from: Self.beta),
            Self.note("b1", daysAgo: 1, from: Self.beta),
        ])
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        #expect(SpanSection.hosts(session.holdings) == ["alpha.test", "beta.test"], "beta is no source, but is held")
        let span = SpanSection.span(from: Self.day(5), to: Self.day(5))
        #expect(await session.letGo(span: span, host: nil) == 2)
        #expect(session.notes.map(\.id) == ["b1"])
        #expect(SpanSection.hosts(session.holdings) == ["beta.test"], "a host with nothing left is not offered")
    }

    @Test("Nothing inside the span is a press that changes nothing and writes nothing")
    func nothingToLetGo() async {
        let session = ShellSession(http: FixtureHTTP(), store: Self.held())
        let saves = Counter()
        session.persist = { await saves.bump() }
        await session.reloadFromStore()
        let span = SpanSection.span(from: Self.day(1), to: Self.day(0))
        #expect(await session.spanHeld(span, host: nil) == 0)
        #expect(await session.letGo(span: span, host: nil) == 0)
        #expect(await saves.value == 0)
        #expect(session.holdings.posts == 4)
    }

    @Test("What went is gone after a relaunch from the file the press wrote")
    func relaunchKeepsThemGone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.held()
        let session = ShellSession(http: FixtureHTTP(), store: store)
        session.persist = {
            let snapshot = await store.snapshot()
            try? await StoreFile(at: dir).save(sources: snapshot.sources, notes: snapshot.notes)
        }
        await session.reloadFromStore()
        await session.letGo(span: SpanSection.span(from: Self.day(9), to: Self.day(5)), host: nil)
        let reopened = StoreFile.open(at: dir)
        #expect(reopened.notes.map(\.id) == ["a3"])
        #expect(reopened.sources.map(\.host) == ["alpha.test", "beta.test"])
    }

    @Test("The question names the count, the days and where, in both languages, and does not come back",
          arguments: [DummyLanguage.english, .taiwanese])
    func questionNamesCountAndSpan(_ language: DummyLanguage) {
        let from = Self.day(6), to = Self.day(4)
        let ask = SpanSection.Ask(posts: 3, from: from, to: to, host: nil)
        let question = ShellQuestion.letGo(ask, language: language)
        #expect(question.title == L10n.count("prefs.span.ask", 3, language: language))
        #expect(question.title.contains("3"))
        #expect(question.line.contains(SpanSection.spanLabel(from: from, to: to, language: language)))
        #expect(question.line.contains(L10n.t("usage.span.every", language: language)))
        #expect(question.help == L10n.t("prefs.span.ask.detail", language: language))
        #expect(question.choices.map(\.role) == [.destructive] && question.cancel != nil)

        let one = ShellQuestion.letGo(SpanSection.Ask(posts: 1, from: from, to: from, host: "alpha.test"), language: language)
        #expect(one.line.contains("alpha.test"))
        #expect(one.line.contains(from.formatted(.dateTime.year().month(.abbreviated).day().locale(L10n.locale(language)))))
        #expect(!one.line.contains(L10n.t("usage.span.between", language: language).prefix(4)), "one day is named once")

        for key in ["prefs.span", "usage.span.line", "prefs.span.footer", "usage.span.from", "usage.span.to",
                    "usage.span.source", "usage.span.every", "usage.span.none", "usage.span.now", "usage.span.now.help"] {
            #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
        }
        #expect(SpanSection.countLine(0, language: language) == L10n.t("usage.span.none", language: language))
        #expect(SpanSection.countLine(4, language: language).contains("4"))
        #expect(SpanSection.wentLine(2, language: language).contains("2"))
        #expect(SpanSection.wentLine(1, language: language).contains("1"))
    }
}

/// Counts calls, off the main actor, so a test can say a save or a measure happened once.
private actor Counter {
    private(set) var value = 0

    @discardableResult
    func bump() -> Int {
        value += 1
        return value
    }
}
