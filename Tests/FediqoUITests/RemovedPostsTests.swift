import Foundation
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

    /// The store filled and the session brought level with it, as `RemoveTests.seed` does.
    private static func shell(_ notes: [Note]) async -> ShellSession {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        await session.store.add(alpha)
        await session.store.add(beta)
        await session.store.ingest(notes)
        await session.reloadFromStore()
        return session
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
            "prefs.removed", "prefs.removed.go", "prefs.removed.stay",
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
