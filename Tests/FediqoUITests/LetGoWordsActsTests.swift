import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence
@testable import FediqoUI

/// After each act that lets posts go, the tokens the words index kept of them are gone from the
/// store's folder too (#360, K9, C27): a span, a source removed, the months limit, the room
/// limit, what is marked gone. A session over a real index with its words index built, saved
/// and compacted as the app's is, and every file in the folder read whole, as #292's tests do.
@MainActor
@Suite("The words of what an act lets go leave the words index", .serialized, .enabled(if: StoreFile.wordsCapable), .watched)
struct LetGoWordsActsTests {
    private static let origin = LimitRoom.origin
    private static let alpha = LimitRoom.alpha
    private static let beta = LimitRoom.beta

    /// How often each closure the app hands in rewrote the words index, or compacted.
    final class Runs: @unchecked Sendable {
        var wordsRewrites = 0
        var compactions = 0
    }

    /// `count` posts of `beta` saying distinctive words, months before the origin, the oldest
    /// first; and sixty of `alpha` from the last days, saying ordinary ones.
    private static func notes(_ kind: LetGoGrams.Kind, going count: Int = 150) -> (going: [Note], staying: [Note]) {
        let going = (0..<count).map { n in
            Note(
                id: "g\(n)", source: beta, author: "Ada", handle: "@ada", body: LetGoGrams.words(n, kind),
                postedAt: origin.addingTimeInterval(-Double(400 - n) * 86_400), categories: [.public]
            )
        }
        let staying = (0..<60).map { n in
            Note(
                id: "s\(n)", source: alpha, author: "Ada", handle: "@ada", body: LetGoGrams.ordinary(n),
                postedAt: origin.addingTimeInterval(-Double(n) * 3_600), categories: [.public]
            )
        }
        return (going, staying)
    }

    /// A session over the file in `dir`, holding `notes` with the words index built, written by
    /// a saver as the app's is, its rewrite and compaction where a save would run.
    private func session(at dir: URL, notes: [Note]) async throws -> (ShellSession, ItemStore, StoreFile, Runs) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.alpha, Self.beta], notes: notes)
            try await file.buildWords(chunk: 250, capable: true)
        }
        let opened = StoreFile.open(at: dir, rows: false)
        let file = try #require(opened.file)
        let store = ItemStore(sources: opened.sources, said: opened.said, rows: file)
        let http = FixtureHTTP()
        let session = ShellSession(
            http: http, store: store,
            pictures: ShellPictures(http: FixtureHTTP()),
            emojis: EmojiCache(http: FixtureHTTP()),
            forums: ForumSessions(credentials: MemoryCredentials()),
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: Offline()),
            posts: ForumPosts(http: http)
        )
        session.jar = SystemJar(
            cookies: HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "fediqo.tests.\(UUID())"), credentials: .shared
        )
        session.readPage = { query, ask, limit in try await file.page(query, ask, limit: limit) }
        let saver = StoreSaver(store: store, file: file)
        let runs = Runs()
        session.persist = { (try? await saver.save()) != nil }
        session.measureStore = { file.bytesOnDisk() }
        session.weighStore = { file.bytesHeld() }
        session.compactStore = {
            try await saver.exclusively { try await file.compact() }
            runs.compactions += 1
        }
        session.letWordsGo = {
            if try await saver.exclusively({ try await file.letWordsGo() }) { runs.wordsRewrites += 1 }
        }
        session.limitStore = try LimitAccountFile(directory: dir)
        await session.loadLimitAccount()
        await session.reloadFromStore()
        return (session, store, file, runs)
    }

    /// The tokens of the posts of `all` the file no longer holds that none it holds has, and
    /// how many posts went.
    private static func goneNeedles(_ all: [Note], _ file: StoreFile) async throws -> (needles: Set<String>, went: Int) {
        let held = Set(try await file.db.read { db in try String.fetchAll(db, sql: "SELECT id FROM note") })
        let went = all.filter { !held.contains($0.id) }
        return (LetGoGrams.needles(went, besides: all.filter { held.contains($0.id) }), went.count)
    }

    /// Runs `act` over a store holding distinctive posts, and checks that some of their tokens
    /// were in the file before it and none of what went is after it.
    private func check(
        _ kind: LetGoGrams.Kind, _ what: String,
        act: (ShellSession, ItemStore, [Note]) async -> Void
    ) async throws -> Runs {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(kind)
        let (session, store, file, runs) = try await session(at: dir, notes: going + staying)
        #expect(!(try LetGoGrams.found(LetGoGrams.needles(going, besides: staying), in: dir)).isEmpty, "the premise: their tokens are in the file")

        await act(session, store, going)
        await session.saved()

        let (needles, went) = try await Self.goneNeedles(going + staying, file)
        #expect(went > 0, "the premise: \(what) let posts go")
        #expect(!needles.isEmpty)
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty, "\(what): a token of a post let go is still in the file")
        #expect(try !file.wordsLetGoOwed())
        #expect(try file.rowCount() == going.count + staying.count - went)
        return runs
    }

    @Test("A span let go", arguments: LetGoGrams.Kind.allCases)
    func span(kind: LetGoGrams.Kind) async throws {
        let runs = try await check(kind, "a span") { session, _, _ in
            let went = await session.letGo(span: Self.origin.addingTimeInterval(-500 * 86_400)..<Self.origin.addingTimeInterval(-100 * 86_400), host: nil)
            #expect(went == 150)
        }
        #expect(runs.wordsRewrites == 1)
        #expect(runs.compactions == 0, "a span compacts nothing")
    }

    @Test("A source removed", arguments: LetGoGrams.Kind.allCases)
    func sourceRemoved(kind: LetGoGrams.Kind) async throws {
        let runs = try await check(kind, "a source removed") { session, _, _ in
            await session.remove(host: Self.beta.host)
        }
        #expect(runs.wordsRewrites == 1)
    }

    @Test("The months limit: its steps each saved, and the index rewritten once at the end", arguments: LetGoGrams.Kind.allCases)
    func monthsLimit(kind: LetGoGrams.Kind) async throws {
        let runs = try await check(kind, "the months limit") { session, _, _ in
            #expect(await session.keep(months: 3, from: Self.origin, step: 40) == 150)
        }
        #expect(runs.compactions == 1, "once at the end of the run, not a step at a time")
        #expect(runs.wordsRewrites == 0, "the compaction rewrites the index first")
    }

    @Test("The room limit", arguments: LetGoGrams.Kind.allCases)
    func roomLimit(kind: LetGoGrams.Kind) async throws {
        let runs = try await check(kind, "the room limit") { session, _, _ in
            guard let weigh = session.weighStore else { return }
            session.roomBytes = await weigh() * 6 / 10
            let act = await session.keepWithinRoom(at: Self.origin)
            #expect((act?.posts ?? 0) > 0)
        }
        #expect(runs.compactions == 1, "once for the check, whatever its rounds")
    }

    @Test("What is marked gone, let go on its wait", arguments: LetGoGrams.Kind.allCases)
    func markedGone(kind: LetGoGrams.Kind) async throws {
        let runs = try await check(kind, "what is marked gone") { session, store, going in
            for note in going { await store.markGone(note.key, at: Self.origin.addingTimeInterval(-10 * 86_400)) }
            await session.write()
            let went = await session.letGoneGo(waitingDays: 1, keepingMonths: nil, from: Self.origin)
            #expect(went.posts == going.count)
        }
        #expect(runs.wordsRewrites == 1)
    }

    @Test("Acts one after another, each saved, rewrite the index once the last has landed")
    func actsInARow() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (going, staying) = Self.notes(.cjk)
        let (session, _, file, runs) = try await session(at: dir, notes: going + staying)
        // Each act's rewrite is chained behind the saves asked before it, and is not waited for.
        let day = 86_400.0
        let first = await session.letGo(span: Self.origin.addingTimeInterval(-500 * day)..<Self.origin.addingTimeInterval(-330 * day), host: nil)
        let second = await session.letGo(span: Self.origin.addingTimeInterval(-330 * day)..<Self.origin.addingTimeInterval(-100 * day), host: nil)
        #expect(first > 0 && second > 0)
        await session.saved()
        // One where the first act's rewrite ran after the second's save, two where before it.
        #expect((1...2).contains(runs.wordsRewrites))
        let (needles, went) = try await Self.goneNeedles(going + staying, file)
        #expect(went == going.count)
        #expect(try LetGoGrams.found(needles, in: dir).isEmpty)
        // Nothing let go since: asked again, it rewrites nothing.
        let before = runs.wordsRewrites
        await session.wordsLetGo()
        #expect(runs.wordsRewrites == before)
    }
}

/// Distinctive words, and the tokens of them the words index keeps (`WordGrams`), searched for
/// in a folder's bytes — as `LetGoWordsTests` has them.
enum LetGoGrams {
    enum Kind: String, CaseIterable, Sendable {
        case ascii, cjk
    }

    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Post `n`'s words: runs of letters and digits no ordinary post says, or of CJK characters.
    static func words(_ n: Int, _ kind: Kind) -> String {
        var random = Seeded(state: UInt64(n) &* 7_919 &+ (kind == .cjk ? 1 : 0))
        let letters = Array("qxzjkv0123456789")
        return (0..<15).map { _ -> String in
            String((0..<10).map { _ -> Character in
                switch kind {
                case .ascii: letters.randomElement(using: &random)!
                case .cjk: Character(Unicode.Scalar(UInt32.random(in: 0x4E00...0x9FA5, using: &random))!)
                }
            })
        }.joined(separator: " ")
    }

    /// Words every staying post says, and a number.
    static func ordinary(_ n: Int) -> String {
        "ordinary words about the day \(n)"
    }

    /// The tokens of a body's three-codepoint runs, as the index keeps them.
    static func trigrams(_ body: String) -> Set<String> {
        let doc = WordGrams.doc(body: body, handle: "", author: "", boosterHandle: nil, boostedBy: nil, host: "")
        return Set(doc.split(separator: " ").map(String.init).filter { $0.utf8.count == 13 && $0.hasPrefix("b") })
    }

    /// The tokens of `going`'s bodies no post of `staying` has.
    static func needles(_ going: [Note], besides staying: [Note]) -> Set<String> {
        let stays = staying.reduce(into: Set<String>()) { $0.formUnion(trigrams($1.body)) }
        return going.reduce(into: Set<String>()) { $0.formUnion(trigrams($1.body)) }.subtracting(stays)
    }

    /// Which of `needles` are whole somewhere in a file under `folder`, read byte by byte.
    static func found(_ needles: Set<String>, in folder: URL) throws -> Set<String> {
        let wanted = Set(needles.map { Array($0.utf8) })
        guard let width = wanted.first?.count else { return [] }
        var found = Set<String>()
        for name in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            let bytes = [UInt8](try Data(contentsOf: url))
            guard bytes.count >= width else { continue }
            for start in 0...(bytes.count - width) where bytes[start] == 0x62 {
                let window = Array(bytes[start..<(start + width)])
                if wanted.contains(window) { found.insert(String(decoding: window, as: UTF8.self)) }
            }
        }
        return found
    }
}

/// A sender that reaches nothing: no write leaves a test.
private struct Offline: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
