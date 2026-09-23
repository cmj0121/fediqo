import Foundation
import Testing
@testable import FediqoCore

/// A post its source deleted stays, marked, until a wait or a press lets it go (#179).
@Suite("A post gone from its source")
struct GoneTests {
    private let source = Source(host: "first.example", kind: .mastodon)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func note(_ id: String, audience: Audience? = .everyone, holding: Holding = .arrived) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@first.example", body: "hello",
            postedAt: origin, categories: [.public], audience: audience, statusID: id, holding: holding
        )
    }

    // MARK: - The mark

    @Test("A marked post stays in All, carries the moment it was heard, and moves what is drawn")
    func markedStays() async {
        let store = ItemStore(sources: [source], notes: [note("1"), note("2")])
        let before = (await store.revision, await store.drawn)
        #expect(await store.markGone(note("1").key, at: origin))
        #expect(await store.all().map(\.id) == ["1", "2"], "nothing went")
        #expect(await store.note(note("1").key)?.goneSince == origin)
        #expect(await store.note(note("2").key)?.goneSince == nil, "nothing else moved")
        #expect(await store.revision == before.0 + 1)
        #expect(await store.drawn == before.1 + 1, "a mark on a shown row is a change to what is shown")
    }

    @Test("A second mark keeps the first moment, and changes nothing")
    func markedOnce() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.markGone(note("1").key, at: origin)
        let revision = await store.revision
        #expect(await !store.markGone(note("1").key, at: origin.addingTimeInterval(60)))
        #expect(await store.note(note("1").key)?.goneSince == origin)
        #expect(await store.revision == revision)
    }

    @Test("A post not held, or whose source is gone, is not marked into being")
    func notHeldNotMarked() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        #expect(await !store.markGone(note("9").key))
        #expect(await store.note(note("9").key) == nil)
        await store.remove(host: source.host)
        #expect(await !store.markGone(note("1").key))
    }

    @Test("A post held aside is marked without moving what All draws")
    func asideMarkedQuietly() async {
        let store = ItemStore(sources: [source], notes: [note("1", holding: .aside)])
        let drawn = await store.drawn
        #expect(await store.markGone(note("1").key))
        #expect(await store.drawn == drawn)
    }

    @Test("A post missing from a listing is never marked: a landing without it leaves it as it was")
    func notArrivedNotMarked() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.ingest([note("2")], ifSourceHere: source.host)
        #expect(await store.note(note("1").key)?.goneSince == nil)
        #expect(await store.letGoneGo() == 0, "and no press reaches it")
        #expect(await store.all().count == 2)
    }

    @Test("A read that finds the post again takes the mark off")
    func foundAgainUnmarked() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.markGone(note("1").key, at: origin)
        #expect(await store.refresh([note("1")], ifSourceHere: source.host))
        #expect(await store.note(note("1").key)?.goneSince == nil)
    }

    @Test("A post the reader took back goes, and is not marked")
    func takenBackGoes() async {
        let store = ItemStore(sources: [source], notes: [note("1"), note("2")])
        await store.forget(note("1").key)
        #expect(await store.note(note("1").key) == nil)
        #expect(await store.all().allSatisfy { $0.goneSince == nil })
    }

    // MARK: - Letting go

    @Test("The press lets every marked post go, says how many, and leaves the rest as they were")
    func pressLetsGo() async {
        let store = ItemStore(sources: [source], notes: [note("1"), note("2"), note("3", holding: .aside)])
        await store.markGone(note("1").key, at: origin)
        await store.markGone(note("3").key, at: origin)
        let kept = await store.note(note("2").key)
        #expect(await store.letGoneGo() == 2)
        #expect(await store.all().map(\.id) == ["2"])
        #expect(await store.note(note("2").key) == kept)
        #expect(await store.snapshot().notes.map(\.id) == ["2"], "gone from what a save writes too")
        #expect(await store.letGoneGo() == 0)
    }

    @Test("A wait lets go only what was marked at or before its moment")
    func waitLetsGoTheOld() async {
        let store = ItemStore(sources: [source], notes: [note("1"), note("2")])
        await store.markGone(note("1").key, at: origin)
        await store.markGone(note("2").key, at: origin.addingTimeInterval(86_400 * 10))
        #expect(await store.letGoneGo(markedBy: origin.addingTimeInterval(86_400)) == 1)
        #expect(await store.all().map(\.id) == ["2"])
    }

    // MARK: - The wait, and the keep-for window beside it

    @Test("Never and forever keep them all; a wait alone counts back its days")
    func waitAlone() {
        let now = origin
        #expect(GoneWait.cutoff(days: nil, keepingMonths: nil, from: now, calendar: utc).cutoff == nil)
        let week = GoneWait.cutoff(days: 7, keepingMonths: nil, from: now, calendar: utc)
        #expect(week.cutoff == now.addingTimeInterval(-7 * 86_400))
        #expect(!week.keepWins)
    }

    @Test("Where the keep-for window is the shorter, it wins and says so; where the wait is, the wait does")
    func shorterWins() {
        let now = origin
        let keep = GoneWait.cutoff(days: 90, keepingMonths: 1, from: now, calendar: utc)
        #expect(keep.keepWins)
        #expect(keep.cutoff == utc.date(byAdding: .month, value: -1, to: now))
        let never = GoneWait.cutoff(days: nil, keepingMonths: 3, from: now, calendar: utc)
        #expect(never.keepWins, "never is longer than any window")
        let wait = GoneWait.cutoff(days: 7, keepingMonths: 3, from: now, calendar: utc)
        #expect(!wait.keepWins)
        #expect(wait.cutoff == now.addingTimeInterval(-7 * 86_400))
    }

    // MARK: - What a source saying so looks like

    @Test("410 is gone; a public 404 is gone signed out and a question signed in; a 404 for fewer is never gone")
    func whatSaysGone() {
        let open = note("1")
        let unlisted = note("3", audience: .unlisted)
        let followers = note("2", audience: .followers)
        let direct = note("4", audience: .mentioned)
        #expect(MastodonPost.saysGone(MastodonRequestError.http(410), about: followers, signedIn: false) == .gone)
        #expect(MastodonPost.saysGone(MastodonAuthError.http(410), about: direct, signedIn: true) == .gone)
        #expect(MastodonPost.saysGone(MastodonRequestError.http(404), about: open, signedIn: false) == .gone)
        #expect(MastodonPost.saysGone(MastodonAuthError.http(404), about: open, signedIn: true) == .ask)
        #expect(MastodonPost.saysGone(MastodonAuthError.http(404), about: unlisted, signedIn: true) == .ask)
        #expect(MastodonPost.saysGone(MastodonAuthError.http(404), about: followers, signedIn: true) == .no,
                "an unfollow, or a block, hides it from this reader alone")
        #expect(MastodonPost.saysGone(MastodonRequestError.http(404), about: followers, signedIn: false) == .no)
        #expect(MastodonPost.saysGone(MastodonAuthError.http(404), about: direct, signedIn: true) == .no)
        #expect(MastodonPost.saysGone(MastodonRequestError.http(500), about: open, signedIn: true) == .no)
        #expect(MastodonPost.saysGone(MastodonAuthError.http(403), about: open, signedIn: true) == .no)
        #expect(MastodonPost.saysGone(URLError(.timedOut), about: open, signedIn: true) == .no)
    }

    @Test("Asked again with no token, only a 404 or a 410 confirms it gone")
    func confirmsGone() async {
        let open = note("1")
        for (status, gone) in [(404, true), (410, true), (200, false), (401, false), (403, false), (500, false)] {
            let body = status == 200 ? #"{"id":"1","uri":"u","created_at":"2024-01-01T00:00:00.000Z","content":"","account":{"username":"a","acct":"a"}}"# : ""
            let http = FixtureHTTP(["/api/v1/statuses/1": .text(body, status: status)])
            let unsigned = MastodonPost(http: http, host: source.host)
            #expect(await unsigned.confirmsGone(open, id: "1") == gone, "\(status)")
        }
    }

    @Test("A marked post its source hands over again in a listing comes back unmarked, and redraws")
    func listedAgainUnmarks() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.markGone(note("1").key, at: origin)
        let drawn = await store.drawn
        await store.ingest([note("1")], ifSourceHere: source.host)
        #expect(await store.note(note("1").key)?.goneSince == nil)
        #expect(await store.drawn == drawn + 1)
    }

    @Test("What the press would let go is counted, held aside or not")
    func counted() async {
        let store = ItemStore(sources: [source], notes: [note("1"), note("2"), note("3", holding: .aside)])
        #expect(await store.goneCount() == 0)
        await store.markGone(note("1").key)
        await store.markGone(note("3").key)
        #expect(await store.goneCount() == 2)
    }

    @Test("A post gone from its source offers nothing that would reach it, whatever the source allows")
    func goneOffersNothing() {
        for writing in [SourceWriting.writes, .reads, .refused, .never] {
            #expect(PostActs.on(writing, nameable: true, mine: true, gone: true) == .none)
        }
        #expect(PostActs.on(.writes, nameable: true).offers(.answer), "and a post still there offers them")
    }
}
