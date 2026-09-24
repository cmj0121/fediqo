import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Removing a source does with its posts what the person decided (#250).
///
/// What a test can reach: the choice, kept on this device and off by default; that Remove keeps
/// the rows when told to and takes them when not, with the source gone either way; that kept rows
/// are still what All draws and a search finds; that the row knows which of its sources are no
/// longer here; and that every word is in all three languages. What it cannot: the mark drawn on
/// the meta line, and the Preferences row itself — those live in view bodies.
@MainActor
@Suite("A removed source's posts stay or go as chosen")
struct RemovedPostsTests {
    private static let alpha = Source(host: "alpha.test", kind: .mastodon)
    private static let beta = Source(host: "beta.test", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "x")])
    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)

    private static func note(_ id: String, from source: Source, body: String = "hello there") -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@\(source.host)", body: body,
            postedAt: posted, categories: [.public]
        )
    }

    /// A session holding `notes` on both sources, read back from its store as a launch reads
    /// one; `http` answers whatever a read asks, and `pictures` is the session's own cache.
    private static func shell(
        _ notes: [Note], http: FixtureHTTP = FixtureHTTP(), pictures: ShellPictures? = nil
    ) async -> ShellSession {
        let session = ShellSession(http: http, pictures: pictures ?? ShellPictures(http: FixtureHTTP()))
        await session.store.add(alpha)
        await session.store.add(beta)
        await session.store.ingest(notes)
        await session.reloadFromStore()
        return session
    }

    private static func address(_ name: String) -> URL { URL(string: "https://cdn.example/\(name)")! }
    private static func key(_ name: String) -> ShellPictures.Key {
        ShellPictures.Key(url: address(name), scale: 2, tier: .deck)
    }

    @Test("The choice is off by default, and holds after a relaunch")
    func choiceIsKept() throws {
        let name = "fediqo.test.removed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Constructing prefs sets the shell's language from what is kept; English, as every
        // other suite here sets it, so a run in parallel is not moved.
        defaults.set("en", forKey: "fediqo.dummy.language")

        #expect(!DummyPrefs(defaults: defaults).removedPostsStay)
        DummyPrefs(defaults: defaults).removedPostsStay = true
        #expect(DummyPrefs(defaults: defaults).removedPostsStay)
        DummyPrefs(defaults: defaults).removedPostsStay = false
        #expect(!DummyPrefs(defaults: defaults).removedPostsStay)
    }

    @Test("Told to keep, Remove leaves the posts in All and in a search, and takes the source")
    func keptPostsStayReadable() async {
        let kept = Self.note("1", from: Self.beta)
        let session = await Self.shell([kept, Self.note("2", from: Self.alpha)])

        await session.remove(host: "Beta.Test", keepingPosts: true)

        #expect(session.sources == [Self.alpha])
        #expect(Set(session.notes.map(\.id)) == ["1", "2"], "a kept post left All")
        #expect(session.queries.map(\.id) == ["all", "trends"], "the board's tab outlived the board")
        let search = NoteSearch("hello", sources: session.sources)
        #expect(search?.found(session.notes, SearchIndex(session.notes)).map(\.id).sorted() == ["1", "2"])
        #expect(await session.store.sources() == [Self.alpha])
    }

    @Test("Told to let go, Remove takes the posts with the source, as it always did")
    func letGoPostsGo() async {
        let session = await Self.shell([Self.note("1", from: Self.beta), Self.note("2", from: Self.alpha)])
        await session.remove(host: Self.beta.host, keepingPosts: false)
        #expect(session.notes.map(\.id) == ["2"])
    }

    @Test("A row is marked when its source is no longer here, and never when nobody said what is")
    func rowKnowsItsSourceLeft() {
        let item = DummyItem(Self.note("1", from: Self.beta))
        #expect(DummyItemRow.sourceLeft(item, here: [Self.alpha.host]))
        #expect(!DummyItemRow.sourceLeft(item, here: [Self.alpha.host, Self.beta.host]))
        #expect(!DummyItemRow.sourceLeft(item, here: nil))
    }

    /// A post two sources carried, the removed one's copy having arrived first.
    private static func shared() -> [Note] {
        let uri = "https://origin.example/users/ada/statuses/1"
        return [Self.note(uri, from: Self.beta), Self.note(uri, from: Self.alpha)]
    }

    @Test("A post another source still carries is drawn as that copy, and is not marked")
    func mergedRowLeadsWithASourceHere() {
        let here: Set<String> = [Self.alpha.host]
        let row = DummyItem.merged(Self.shared(), here: here)
        #expect(row.count == 1)
        #expect(row.first?.source.host == Self.alpha.host, "drawn as the copy whose source is here")
        #expect(row.first?.sources.map(\.host) == [Self.alpha.host, Self.beta.host])
        #expect(!DummyItemRow.sourceLeft(row[0], here: here))
        // Both gone, or nothing said: the order the copies arrived in, as before.
        #expect(DummyItem.merged(Self.shared(), here: []).first?.source.host == Self.beta.host)
        #expect(DummyItem.merged(Self.shared()).first?.source.host == Self.beta.host)
        #expect(DummyItemRow.sourceLeft(DummyItem.merged(Self.shared(), here: [])[0], here: []))
    }

    @Test("The stream draws a shared post as the copy still here once the other source is removed")
    func streamRedrawsAfterRemoval() async {
        let session = await Self.shell(Self.shared())
        #expect(session.timelineItems(latest: nil).first?.source.host == Self.beta.host)
        let before = session.timelineEvaluations
        await session.remove(host: Self.beta.host, keepingPosts: true)
        #expect(session.timelineItems(latest: nil).first?.source.host == Self.alpha.host)
        #expect(session.timelineItems(latest: nil).first?.sources.count == 2, "the kept copy is still under it")
        #expect(session.timelineEvaluations == before + 1, "the stream was drawn again more than once, or not at all")
    }

    @Test("A source added again re-fires the asks its kept rows had stopped: the identity changes with it")
    func readdingRefiresTheAsks() async {
        let session = await Self.shell([Self.note("1", from: Self.beta)])
        await session.remove(host: Self.beta.host, keepingPosts: true)
        let gone: Set<String> = Set(session.sources.map(\.host))
        #expect(!RemoteImage.isHere(Self.beta.host, among: gone))
        await session.store.add(Self.beta)
        await session.reloadFromStore()
        let back: Set<String> = Set(session.sources.map(\.host))
        #expect(RemoteImage.isHere(Self.beta.host, among: back))
        let wanted = { (here: Bool) in
            RemoteImage.Wanted(url: Self.address("a.png"), scale: 2, tier: .deck, have: false, generation: 0,
                               host: Self.beta.host, active: true, here: here)
        }
        #expect(wanted(false) != wanted(true), "a source added again is no change of identity")
        #expect(UsageSourceList.removed(session).isEmpty)
    }

    @Test("Told to keep, Remove lets the pictures go without telling a row to ask again, and nothing is asked")
    func keptRowsAskForNoPictures() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let work = SourceWork()
        pictures.work = work
        let session = await Self.shell([Self.note("1", from: Self.beta)], pictures: pictures)
        session.work = work
        pictures.keep(Image(systemName: "photo"), cost: 4096, for: Self.key("a.png"), startedAt: 0, hosts: [Self.beta.host])
        pictures.note(.refused, for: Self.key("b.png"), hosts: [Self.beta.host])
        let generation = pictures.generation

        await session.remove(host: Self.beta.host, keepingPosts: true)

        #expect(pictures.holding(host: Self.beta.host).count == 0)
        #expect(!pictures.isMissing(Self.address("b.png"), scale: 2, tier: .deck), "a refusal outlived its source")
        #expect(pictures.missingSources.values.allSatisfy { !$0.contains(Self.beta.host) })
        #expect(pictures.generation == generation, "the rows were told to ask a host nothing may ask")
        #expect(work.record.allSatisfy { $0.source != Self.beta.host }, "Remove itself reached the host")
        // What a kept row draws where its picture was: nothing — no wait, no failure, no retry.
        #expect(RemoteImage.fill(have: false, url: Self.address("a.png"), missing: false, here: false) == .absent)
        #expect(RemoteImage.fill(have: false, url: Self.address("b.png"), missing: true, here: false) == .absent)
        #expect(RemoteImage.fill(have: true, url: Self.address("a.png"), missing: false, here: false) == .held)
        #expect(!RemoteImage.isHere("Beta.Test", among: [Self.alpha.host]))
        #expect(RemoteImage.isHere(Self.beta.host, among: nil))
    }

    @Test("A kept forum row draws what it read and nothing where it did not, and asks the forum nothing")
    func keptForumRowIsSettled() {
        #expect(ForumPostBand.settled(.coming, here: false) == .silent)
        #expect(ForumPostBand.settled(.absent(.unreachable), here: false) == .silent)
        #expect(ForumPostBand.settled(.words("said"), here: false) == .words("said"))
        #expect(ForumPostBand.settled(.withheld, here: false) == .withheld)
        #expect(ForumPostBand.settled(.coming, here: true) == .coming)
    }

    @Test("A kept post's thread is settled as nobody under it, and its source is never asked")
    func keptThreadAsksNothing() async {
        let http = FixtureHTTP([:])
        let kept = Note(
            id: "https://beta.test/users/ada/statuses/9", source: Source(host: Self.beta.host, kind: .mastodon),
            author: "Ada", handle: "@ada@beta.test", body: "hello", postedAt: Self.posted,
            categories: [.public], statusID: "9"
        )
        let session = await Self.shell([kept], http: http)
        let item = DummyItem(kept)
        await session.remove(host: Self.beta.host, keepingPosts: true)

        await session.conversations.open(item, in: session)
        #expect(session.conversations.standing(of: item.id) == ShellConversationStanding.none)
        await session.conversations.renew(item, in: session)
        await session.conversations.again(item, in: session)
        #expect(await http.paths.isEmpty, "the removed source was asked")
    }

    @Test("Usage lists a removed source that still has posts here, after the sources, with its count")
    func usageListsRemovedSources() async {
        let session = await Self.shell([Self.note("1", from: Self.beta), Self.note("2", from: Self.beta), Self.note("3", from: Self.alpha)])
        #expect(UsageSourceList.removed(session).isEmpty)
        await session.remove(host: Self.beta.host, keepingPosts: true)
        #expect(UsageSourceList.removed(session) == [Source(host: Self.beta.host, kind: .discuz)])
        #expect(session.holdings.posts(host: Self.beta.host) == 2)
        #expect(session.holdings.posts == 3, "the rows no longer sum to the total")
        #expect(UsageSourceList.source(Self.beta.host, in: session)?.kind == .discuz)
        session.usagePurpose = .source
        session.usageOpened = Self.beta.host
        #expect(session.usageDetailShown, "the removed source's detail cannot be opened")
        session.usageOpened = "nowhere.test"
        #expect(!session.usageDetailShown)
    }

    @Test("The question's line says which will happen, in both languages")
    func questionSaysWhich() {
        for language in [DummyLanguage.english, .taiwanese] {
            let stay = ShellQuestion.remove(host: "a", boards: 0, postsStay: true, language: language)
            let go = ShellQuestion.remove(host: "a", boards: 0, postsStay: false, language: language)
            #expect(stay.line != go.line)
            #expect(stay.line == L10n.t("account.remove.line.stay", language: language))
            #expect(stay.help == L10n.t("account.remove.detail.stay", language: language))
            let boards = ShellQuestion.remove(host: "a", boards: 3, postsStay: true, language: language)
            #expect(boards.line == String(format: L10n.t("account.remove.line.stay.boards", language: language), 3))
            #expect(boards.help == String(format: L10n.t("account.remove.detail.stay.boards", language: language), 3))
        }
        #expect(ShellQuestion.remove(host: "a", boards: 0, postsStay: true, language: .english).line.contains("stay"))
        #expect(ShellQuestion.remove(host: "a", boards: 3, postsStay: true, language: .english).line.contains("3 boards"))
    }

    @Test("The mark and the preference are worded in every language, and differ between them")
    func stringsInEveryLanguage() throws {
        let keys = [
            "item.left", "item.left.detail", "prefs.removed.head", "prefs.removed.brief", "prefs.removed.footer",
            "prefs.removed", "prefs.removed.go", "prefs.removed.stay", "thread.source.left", "usage.removed.line",
            "usage.removed.help",
        ]
        for key in keys {
            #expect(L10n.t(key, language: .english) != L10n.t(key, language: .taiwanese), "\(key)")
        }
        #expect(DummyItemRow.leftWord(language: .english) == "Source removed")
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in keys {
                #expect(strings.contains("\"\(key)\" = "), "\(key) is missing in \(lproj)")
            }
        }
    }
}
