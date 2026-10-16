import FediqoCore
import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// #357, C11: over a store held in part, the counts that confirm a letting go are of what this
/// run has read, and say "at least" — the question before a source is removed, the one before
/// posts stop being kept, and Usage's figures. Held whole, they say what they always said.
@Suite("Counts over a store held in part say at least")
@MainActor
struct AtLeastCountsTests {
    private static let source = Source(host: "one.example", kind: .mastodon)

    @Test("Removing a source: the kept that stay are at least so many, in either language; held whole, as before")
    func removeQuestion() {
        let part = ShellQuestion.remove(host: "one.example", boards: 0, kept: 3, atLeast: true, language: .english)
        #expect(part.line.contains("at least 3"))
        let boards = ShellQuestion.remove(host: "one.example", boards: 2, kept: 3, atLeast: true, language: .english)
        #expect(boards.line.contains("at least 3") && boards.line.contains("2 boards"))
        let zh = ShellQuestion.remove(host: "one.example", boards: 0, kept: 3, atLeast: true, language: .taiwanese)
        #expect(zh.line.contains("至少 3"))
        let whole = ShellQuestion.remove(host: "one.example", boards: 0, kept: 3, language: .english)
        #expect(whole.line.contains("the 3 you keep") && !whole.line.contains("at least"))
    }

    @Test("Stopping keeping: the posts and those kept elsewhere are at least so many; held whole, as before")
    func stopKeepingQuestion() {
        let part = ShellQuestion.stopKeeping(KeptAsk(host: "one.example", posts: 2, elsewhere: 1, atLeast: true), language: .english)
        #expect(part.title == "Stop keeping at least 2 posts?")
        #expect(part.line.contains("At least 1 stays kept") || part.help?.contains("At least 1 stays kept") == true)
        let zh = ShellQuestion.stopKeeping(KeptAsk(host: nil, posts: 2, atLeast: true), language: .taiwanese)
        #expect(zh.title.contains("至少 2"))
        let whole = ShellQuestion.stopKeeping(KeptAsk(host: nil, posts: 2), language: .english)
        #expect(whole.title == "Stop keeping 2 posts?")
    }

    @Test("Usage's figures: at least so many posts, none read yet rather than none held, at least so many kept")
    func usageFigures() async {
        #expect(UsagePane.postsLine(5, atLeast: true, language: .english) == "At least 5 posts")
        #expect(UsagePane.postsLine(0, atLeast: true, language: .english) == "None read yet")
        #expect(UsagePane.postsLine(5, language: .english) == "5 posts")
        #expect(UsagePane.postsLine(0, language: .english) == "No posts held")
        #expect(UsagePane.postsLine(5, atLeast: true, language: .taiwanese).contains("至少 5"))
        let kept = Note(
            id: "k", source: Self.source, author: "A", handle: "a@one.example", body: "b",
            postedAt: Date(timeIntervalSince1970: 1_790_000_000), categories: [.home], kept: true
        )
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [Self.source], notes: [kept]))
        await session.reloadFromStore()
        #expect(KeptSection.figure(session.holdings.kept, atLeast: true, language: .english).hasPrefix("At least 1 kept"))
        #expect(KeptSection.figure(session.holdings.kept, language: .english).hasPrefix("1 kept"))
    }

    @Test("Usage never says nothing is kept while the file's kept rows are unread; read, they are counted; unreadable, none is read yet")
    func keptReadBeforeSaid() async throws {
        #expect(KeptSection.noneLine(read: nil, heldInPart: true) == nil, "said nothing while being read")
        #expect(KeptSection.noneLine(read: false, heldInPart: true, language: .english) == "None read yet")
        #expect(KeptSection.noneLine(read: true, heldInPart: true, language: .english) == L10n.t("usage.kept.none", language: .english))
        #expect(KeptSection.noneLine(read: nil, heldInPart: false, language: .english) == L10n.t("usage.kept.none", language: .english))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = Note(
            id: "k", source: Self.source, author: "A", handle: "a@one.example", body: "b",
            postedAt: Date(timeIntervalSince1970: 1_790_000_000), categories: [.home], kept: true
        )
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.source], notes: [kept])
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [Self.source], rows: file))
        await session.reloadFromStore()
        #expect(session.holdings.kept.posts == 0 && session.keptRowsRead == nil, "the premise: kept in the file, not read")
        await session.readKeptRows()
        #expect(session.keptRowsRead == true)
        #expect(session.holdings.kept.posts == 1)
    }

    @Test("The session asks with at least where its store is over a file, and as before where it is whole")
    func sessionAsks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = Note(
            id: "k", source: Self.source, author: "A", handle: "a@one.example", body: "b",
            postedAt: Date(timeIntervalSince1970: 1_790_000_000), categories: [.home], kept: true
        )
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.source], notes: [kept])
        let pool = ItemStore(sources: [Self.source], rows: file)
        _ = await pool.note(kept.key)
        let part = ShellSession(http: FixtureHTTP(), store: pool)
        await part.reloadFromStore()
        #expect(part.removeQuestion(host: Self.source.host, postsStay: false, language: .english).line.contains("at least 1"))
        let whole = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [Self.source], notes: [kept]))
        await whole.reloadFromStore()
        #expect(!whole.removeQuestion(host: Self.source.host, postsStay: false, language: .english).line.contains("at least"))
    }
}
