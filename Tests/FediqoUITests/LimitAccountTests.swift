import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence
@testable import FediqoUI

/// What a limit let go can be seen (#251): the lines on Usage's Keep tab, what each says,
/// that they outlive a relaunch, and that clearing them lets nothing else go.
@MainActor
@Suite("The account of what the limits let go", .serialized)
struct LimitAccountTests {
    private let origin = LimitRoom.origin
    private let alpha = LimitRoom.alpha
    private let beta = LimitRoom.beta

    @Test("The lines outlive a relaunch, and clearing them lets nothing else go")
    func linesOutliveARelaunch() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await LimitRoom(at: dir, notes: LimitRoom.held() + [LimitRoom.note("old", daysAgo: 400, from: beta)])
        try first.copies(2, of: 50_000, host: alpha.host)
        #expect(await first.session.keep(months: 3, from: origin) == 1)
        first.session.roomBytes = first.index + 60_000
        #expect(await first.session.keepWithinRoom(at: origin)?.copies == 1)
        let written = first.session.limitAccount
        #expect(written.count == 2)

        let opened = StoreFile.open(at: dir)
        let second = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: opened.sources, notes: opened.notes))
        second.limitStore = try LimitAccountFile(directory: dir)
        #expect(second.limitAccount.isEmpty, "nothing before the account is read")
        await second.loadLimitAccount()
        #expect(second.limitAccount == written)

        let index = first.index
        await second.clearLimitAccount()
        #expect(second.limitAccount.isEmpty)
        #expect(try LimitAccountFile(directory: dir).read().isEmpty, "the clear was not written down")
        #expect(try StoreFile.open(at: dir).notes.count == 60, "clearing the account touched the posts")
        #expect(first.index == index)
        #expect(first.cache.count() == 1, "clearing the account touched the copies")
    }

    @Test("A session with nowhere to keep the account keeps it for the run")
    func noStoreKeepsForTheRun() async {
        let session = ShellSession(http: FixtureHTTP())
        await session.record(LimitAct(limit: .months, at: origin, posts: 1, sources: ["alpha.test"]))
        #expect(session.limitAccount.count == 1)
        await session.clearLimitAccount()
        #expect(session.limitAccount.isEmpty)
    }

    @Test("What a line and its detail say, in every language", arguments: [DummyLanguage.english, .taiwanese])
    func words(language: DummyLanguage) throws {
        let keys = [
            "prefs.limits", "prefs.limits.line", "prefs.limits.help", "prefs.limits.none", "prefs.limits.copies",
            "prefs.limits.both", "prefs.limits.brief.from", "prefs.limits.clear", "prefs.limits.clear.help",
            "prefs.limits.clear.title", "prefs.limits.clear.line", "prefs.limits.clear.detail",
            "prefs.limits.clear.confirm", "prefs.limits.detail.time", "prefs.limits.detail.posts",
            "prefs.limits.detail.copies", "prefs.limits.detail.sources", "prefs.limits.detail.sources.none",
        ]
        for key in keys {
            #expect(L10n.t(key, language: language) != key, "\(key) is missing")
        }
        let act = LimitAct(limit: .room, at: origin, posts: 2, copies: 1, sources: ["alpha.test", "beta.test"])
        let brief = LimitAccountSection.brief(act, language: language)
        #expect(brief.contains("alpha.test, beta.test"))
        #expect(brief.contains("2"))
        #expect(brief.contains("1"))
        #expect(LimitAccountSection.title(act, language: language) == L10n.t("prefs.room", language: language))
        #expect(LimitAccountSection.title(LimitAct(limit: .months, at: origin, posts: 1, sources: []), language: language)
            == L10n.t("prefs.keep", language: language))
        let facts = LimitActDetail.facts(act, language: language)
        #expect(facts.count == 4)
        #expect(facts.last?.value == "alpha.test, beta.test")
        #expect(LimitAccountSection.symbol(.months) == "hourglass")
        #expect(LimitAccountSection.symbol(.room) == "internaldrive")
    }

    @Test("The counts read as one or many")
    func countsRead() {
        #expect(LimitAccountSection.counts(LimitAct(limit: .room, at: origin, posts: 0, copies: 1, sources: []), language: .english) == "1 picture copy")
        #expect(LimitAccountSection.counts(LimitAct(limit: .room, at: origin, posts: 3, copies: 0, sources: []), language: .english) == "3 posts")
        #expect(LimitAccountSection.counts(LimitAct(limit: .room, at: origin, posts: 1, copies: 2, sources: []), language: .english) == "1 post and 2 picture copies")
        #expect(LimitAccountSection.counts(LimitAct(limit: .room, at: origin, posts: 1, copies: 2, sources: []), language: .taiwanese) == "1 則貼文 與 2 個圖片副本")
        #expect(LimitAccountSection.brief(LimitAct(limit: .months, at: origin, posts: 3, sources: []), language: .english) == "3 posts")
    }

    @Test("Clearing the account is a plain press with a way out")
    func clearIsPlain() {
        let clear = ShellQuestion.clearAccount(language: .english)
        #expect(clear.choices.map(\.role) == [.plain])
        #expect(clear.cancel != nil)
        #expect(clear.title == "Clear the account?")
    }
}
