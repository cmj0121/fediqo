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
        await first.session.saved()
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

    @Test("Lines that are there and will not be read are not taken for none: nothing is written over them, and they are read when they can be")
    func linesThatWillNotBeRead() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = [LimitAct(limit: .room, at: origin, posts: 2, copies: 3, sources: [beta.host])]
        let file = try LimitAccountFile(directory: dir)
        try file.write(earlier)
        // As a locked device refuses it: the file is there, and reading it is not allowed.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [], notes: []))
        session.limitStore = file
        let line = LimitAct(limit: .months, at: origin.addingTimeInterval(60), posts: 1, sources: [alpha.host])
        await session.record(line)
        #expect(session.limitAccount == [line], "kept for the run")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        #expect(try file.read() == earlier, "a write in place would have replaced the earlier lines with this one")
        // The next line reads the account first, now that it can, and both are written.
        let next = LimitAct(limit: .months, at: origin.addingTimeInterval(120), posts: 4, sources: [alpha.host])
        await session.record(next)
        #expect(session.limitAccount == [next, line] + earlier)
        #expect(try file.read() == [next, line] + earlier)
    }

    @Test("A clear asked while the lines could not be read is owed, and done when they can be: they do not come back")
    func aClearThatCouldNotBeWritten() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = [LimitAct(limit: .room, at: origin, posts: 2, copies: 3, sources: [beta.host])]
        let file = try LimitAccountFile(directory: dir)
        try file.write(earlier)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [], notes: []))
        session.limitStore = file
        await session.clearLimitAccount()
        #expect(session.limitAccount.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        #expect(try file.read() == earlier, "nothing was written over what could not be read")
        let line = LimitAct(limit: .months, at: origin.addingTimeInterval(60), posts: 1, sources: [alpha.host])
        await session.record(line)
        #expect(session.limitAccount == [line], "the cleared lines did not come back")
        #expect(try file.read() == [line])
    }

    @Test("A clear the device would not keep is said on the strip, once — the lines are gone from the page and still in the file — and the line comes down when the account is written; a clear that is kept says nothing")
    func aClearNotKeptIsSaid() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = [LimitAct(limit: .room, at: origin, posts: 2, copies: 3, sources: [beta.host])]
        let file = try LimitAccountFile(directory: dir)
        try file.write(earlier)
        let kept = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [], notes: []))
        kept.limitStore = file
        await kept.clearLimitAccount()
        #expect(kept.said.lines.isEmpty)
        #expect(try file.read().isEmpty)
        try file.write(earlier)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [], notes: []))
        session.limitStore = file
        await session.clearLimitAccount()
        #expect(session.limitAccount.isEmpty)
        #expect(session.said.lines.map(\.what) == [.unkept(.limits)])
        await session.clearLimitAccount()
        #expect(session.said.lines.map(\.what) == [.unkept(.limits)], "said once")
        let words = try #require(session.said.lines.first).words(language: .english)
        #expect(words == L10n.t("said.unkept.limits", language: .english) && words.hasSuffix("."))
        // It can be read again: the next thing that asks for the account clears what was
        // owed, writes it, and the line comes down.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        let line = LimitAct(limit: .months, at: origin.addingTimeInterval(60), posts: 1, sources: [alpha.host])
        await session.record(line)
        #expect(try file.read() == [line])
        #expect(session.said.lines.isEmpty)
    }

    @Test("After a read back the package's lines are the account, and this device's old lines are not written over them")
    func readBackReplacesTheLines() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held())
        await room.session.record(LimitAct(limit: .months, at: origin.addingTimeInterval(-99), posts: 5, sources: [alpha.host]))
        #expect(room.session.limitAccount.count == 1)
        // What a read back installs beside the index (#247), as the packager's commit does.
        let theirs = [LimitAct(limit: .room, at: origin, posts: 2, copies: 3, sources: [beta.host])]
        try LimitAccountFile(directory: dir).write(theirs)

        await room.session.replaceLimitAccount()

        #expect(room.session.limitAccount == theirs)
        #expect(try LimitAccountFile(directory: dir).read() == theirs, "the old lines were written over the package's")
        await room.session.record(LimitAct(limit: .months, at: origin.addingTimeInterval(60), posts: 1, sources: [beta.host]))
        #expect(room.session.limitAccount.map(\.limit) == [.months, .room], "a months line lands ahead of the package's")
    }

    @Test("A line this build cannot read costs that line and no other, on disk and in a package")
    func lenientLines() throws {
        let good = LimitAct(limit: .room, at: origin, posts: 1, sources: [])
        let text = "[" + String(decoding: try LimitAccount.data([good]), as: UTF8.self).dropFirst().dropLast() + ",{\"limit\":\"weeks\",\"at\":\"never\"},7]"
        #expect(LimitAccount.lines(from: Data(text.utf8)) == [good])
        #expect(LimitAccount.lines(from: Data("{}".utf8)).isEmpty)
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
            "prefs.limits.both", "prefs.limits.brief.from", "prefs.limits.clear",
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

    @Test("Clearing the account is not drawn as a loss, has a way out, and has the one yes a … item needs")
    func clearIsNotALoss() {
        let clear = ShellQuestion.clearAccount(language: .english)
        #expect(clear.choices.map(\.role) == [.keyed])
        #expect(!clear.warns)
        #expect(clear.chorded?.id == ShellQuestion.yes)
        #expect(clear.cancel != nil)
        #expect(clear.title == "Clear the account?")
    }

    @Test("Clear is the one item of the list's …, under the eraser, asking first; dim with no line")
    func clearIsBehindTheDots() async {
        var cleared = 0
        let more = LimitAccountSection.more(lines: 2, language: .english) { cleared += 1 }
        #expect(more.items.map(\.symbol) == ["eraser"])
        #expect(more.dangers.count == 1)
        #expect(more.label(language: .english) == "More: Clear the account")
        var put: [ShellMoreAsk] = []
        more.items[0].press { put.append($0) }
        #expect(put.first?.question == ShellQuestion.clearAccount(language: .english))
        #expect(cleared == 0)
        put.first?.answered("not the yes")
        #expect(cleared == 0)
        put.first?.answered(ShellQuestion.yes)
        #expect(cleared == 1)

        #expect(more.head.isEmpty)
        // With no line the reason is the truth — no limit has acted — and not "not right now".
        for language in [DummyLanguage.english, .taiwanese] {
            let empty = LimitAccountSection.more(lines: 0, language: language) {}
            #expect(empty.head == [L10n.t("prefs.limits.none", language: language)])
            #expect(empty.items[0].title(language: language) == L10n.t("prefs.limits.clear", language: language))
        }
        let none = LimitAccountSection.more(lines: 0, language: .english) { cleared += 1 }.items[0]
        #expect(none.look == .dim(.notNow) && !none.answers)
        none.press { put.append($0) }
        #expect(put.count == 1 && cleared == 1)
    }
}
