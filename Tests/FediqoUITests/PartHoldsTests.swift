import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #347 — a source's row and its page say what a sign-in holds, part by part: a part stands
/// by itself, so a sign-in that only reads may hold one that acts, and "reads" or "reads and
/// writes" cannot say that. One reading over the table of parts, read when it is drawn.
@MainActor
@Suite("What a sign-in holds is said part by part")
struct PartHoldsTests {
    private typealias S = PartServer
    private let host = "social.example"
    private let forum = "bbs.example.org"
    private static let reading = "read:statuses read:lists read:accounts"
    private static let reads = reading + " read:search"
    private static let acts = reads + " write:statuses write:favourites"

    private func shell(holding scopes: String?) async throws -> (ShellSession, PartServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        if let scopes {
            try tokens.save(MastodonToken(
                host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: scopes, asked: scopes
            ))
        }
        let server = PartServer(tokens: tokens)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        for source in [Source(host: host, kind: .mastodon), Source(host: forum, kind: .discuz)] {
            await session.store.add(source)
        }
        session.sources = await session.store.sources()
        return (session, server, tokens)
    }

    private static func table(_ language: String) throws -> String {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        return try String(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"), encoding: .utf8)
    }

    private static func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Shell")
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    private func view(_ row: SourceRow, refusal: (host: String, key: String)? = nil, holds: String?) -> SourceRowView {
        SourceRowView(
            row: row, actsLive: true, waiting: nil, refusal: refusal, holds: holds,
            clearAsks: { ShellQuestion.clear(host: row.source.host, detailKey: "account.clear.detail", language: .english) },
            removeAsks: { ShellQuestion.remove(host: row.source.host, boards: 0, language: .english) },
            presses: SourceRow.Presses()
        )
    }

    // MARK: - What is said, for every state a sign-in can be held in

    @Test("Each state a sign-in can be held in is said in one sentence that is true of it: reading alone; reading with a part that acts and no acting; everything; a part held in part; what the source's coarse words and a word nobody here knows are, in a second sentence; and nothing where nothing is written down")
    func theHeldStates() {
        func says(_ scopes: String?) -> String? { PartWords.holds(scopes, language: .english) }
        #expect(says(nil) == nil)
        #expect(says("") == nil)
        #expect(says(Self.reading) == "This sign-in allows reading as you.")
        #expect(says(Self.reads) == "This sign-in allows reading as you, searching as you.")
        #expect(says(Self.reads + " read:notifications") == "This sign-in allows reading as you, searching as you, your notices.")
        // A reading sign-in holding a part that acts, alone: said, though its row calls it "read".
        #expect(says(Self.reads + " write:bookmarks") == "This sign-in allows reading as you, searching as you, bookmarks.")
        #expect(says(Self.acts) == "This sign-in allows reading as you, searching as you, writing as you.")
        #expect(says(Self.acts + " write:bookmarks") == "This sign-in allows reading as you, searching as you, writing as you, bookmarks.")
        // Follows stands by itself too: beside a sign-in that only reads, whole and in part.
        #expect(says(Self.reads + " read:follows write:follows") == "This sign-in allows reading as you, searching as you, who you follow.")
        // A part with a half that sees and a half that changes names the half held.
        #expect(says(Self.reads + " read:follows") == "This sign-in allows reading as you, searching as you, seeing who you follow.")
        #expect(says(Self.reads + " write:follows") == "This sign-in allows reading as you, searching as you, changing who you follow.")
        #expect(PartWords.holds(Self.reads + " read:follows", language: .taiwanese) == "這個登入允許：以你的身分讀取、以你的身分搜尋、查看你追蹤的對象。")
        #expect(PartWords.holds(Self.reads + " write:follows", language: .taiwanese) == "這個登入允許：以你的身分讀取、以你的身分搜尋、更改你追蹤的對象。")
        #expect(says(Self.acts + " read:notifications read:follows write:follows") == "This sign-in allows reading as you, searching as you, writing as you, your notices, who you follow.")
        #expect(PartWords.holds(Self.reads + " read:follows write:follows", language: .taiwanese) == "這個登入允許：以你的身分讀取、以你的身分搜尋、你追蹤的對象。")
        // Spelt out, and not the table's own list of everything: a part added later is none of these.
        let whole = "read:statuses read:lists read:accounts read:search write:statuses write:favourites write:bookmarks read:notifications write:notifications"
        #expect(says(whole) == "This sign-in allows reading as you, searching as you, writing as you, bookmarks, your notices, dismissing your notices.")
        #expect(says("read:statuses read:lists") == "This sign-in allows reading as you (in part).")
        #expect(says(Self.reading + " write:statuses") == "This sign-in allows reading as you, writing as you (in part).")
        #expect(says("read write") == "This sign-in has read, write, which this version of Fediqo does not ask for.")
        #expect(says(Self.reading + " push") == "This sign-in allows reading as you. This sign-in has push, which this version of Fediqo does not ask for.")
        // A source's words are whatever it chose to call them: the first few, each cut short.
        #expect(says("a b c d e") == "This sign-in has a, b, c and 2 more, which this version of Fediqo does not ask for.")
        #expect(PartWords.holds(Self.reads + " write:bookmarks", language: .taiwanese) == "這個登入允許：以你的身分讀取、以你的身分搜尋、書籤。")
        #expect(PartWords.holds("read push", language: .taiwanese) == "這個登入有 read, push，是這個版本的 Fediqo 不會問的。")
        #expect(PartWords.holds("read:statuses", language: .taiwanese) == "這個登入允許：以你的身分讀取（部分）。")
    }

    @Test("The words nobody here knows are the first three on the row and every one on the source's own page, so no held word hides behind a count there; each is cut to 24 characters, and the page stops at 32")
    func theUnknownWordsWhole() async throws {
        func row(_ scopes: String) -> String? { PartWords.holds(scopes, language: .english) }
        func page(_ scopes: String) -> String? { PartWords.holds(scopes, whole: true, language: .english) }
        let coarse = "follow push read write"
        #expect(row(coarse) == "This sign-in has follow, push, read and 1 more, which this version of Fediqo does not ask for.")
        #expect(page(coarse) == "This sign-in has follow, push, read, write, which this version of Fediqo does not ask for.")
        #expect(page(Self.reading) == row(Self.reading))
        let long = String(repeating: "x", count: 25)
        #expect(page(long) == "This sign-in has \(String(repeating: "x", count: 24))…, which this version of Fediqo does not ask for.")
        let many = (1...40).map { "w\($0)" }
        let listed = many.prefix(32).joined(separator: ", ")
        #expect(PartWords.wordsWhole == 32)
        #expect(page(many.joined(separator: " ")) == "This sign-in has \(listed) and 8 more, which this version of Fediqo does not ask for.")

        // Drawn: the page says every one, and the row's `…` keeps the cut.
        let (session, _, _) = try await shell(holding: Self.reading + " " + coarse)
        let whole = "This sign-in allows reading as you. This sign-in has follow, push, read, write, which this version of Fediqo does not ask for."
        #expect(JoinSheet(session: session).standingLines(host, language: .english) == [whole])
        #expect(session.mastodon.holds(host: host, whole: true, language: .english) == whole)
        let cut = session.mastodon.holds(host: host, language: .english)
        #expect(cut == "This sign-in allows reading as you. This sign-in has follow, push, read and 1 more, which this version of Fediqo does not ask for.")
    }

    @Test("A word is shown without what cannot be seen in it — a mark that turns the line round, a control character — and a word with nothing else in it is not shown at all", arguments: [false, true])
    func theUnseenIsNotShown(_ whole: Bool) {
        func says(_ scopes: String) -> String? { PartWords.holds(scopes, whole: whole, language: .english) }
        let plain = "This sign-in has push, which this version of Fediqo does not ask for."
        #expect(says("pu\u{202E}sh") == plain)
        #expect(says("\u{2066}push\u{2069}") == plain)
        #expect(says("p\u{7}u\tsh\u{200F}") == plain)
        #expect(says("\u{202E} push \u{200B}\u{7F}") == plain)
        #expect(says("\u{202E}") == nil)
        // And it is not counted among the ones there was no room for.
        let four = whole ? "a, b, c, d" : "a, b, c and 1 more"
        #expect(says("a \u{202E} b c d") == "This sign-in has \(four), which this version of Fediqo does not ask for.")
        // What can be seen stays as the source spelt it.
        #expect(says("讀取:é") == "This sign-in has 讀取:é, which this version of Fediqo does not ask for.")
    }

    @Test("Every subset of the parts is said by naming exactly those parts, in the table's order, each by its own name")
    func everySubsetOfParts() {
        let parts = MastodonPart.allCases
        for mask in 1..<(1 << parts.count) {
            let chosen = parts.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let names = chosen.map { L10n.t("part.\($0.rawValue).name", language: .english) }
            let said = PartWords.holds(chosen.flatMap(\.words).joined(separator: " "), language: .english)
            #expect(said == "This sign-in allows \(names.joined(separator: ", ")).")
        }
    }

    // MARK: - A part added later is named with no edit

    @Test("Every part of the table has a name in each of the three string tables — the words its own question already asks for it in — and so has the act a part gains beside acting; a part with no name fails here", arguments: MastodonPart.allCases)
    func everyPartHasAName(_ part: MastodonPart) throws {
        let tables = try ["en", "zh-TW", "zh-Hant"].map(Self.table)
        var keys = [PartWords.nameKey(part)]
        #expect(keys == ["part.\(part.rawValue).name"])
        if !part.wordsBesideActing.isEmpty { keys.append(keys[0] + ".beside") }
        for key in keys {
            for table in tables { #expect(table.contains("\n\"\(key)\" = \""), "\(key) is missing from a table") }
            let en = L10n.t(key, language: .english)
            let zh = L10n.t(key, language: .taiwanese)
            #expect(en != key)
            #expect(!en.isEmpty)
            #expect(zh != key)
            #expect(!zh.isEmpty)
            #expect(zh != en)
        }
        // Not a second vocabulary: the name is what the part's own question calls it.
        for language in [DummyLanguage.english, .taiwanese] {
            let name = L10n.t(keys[0], language: language)
            #expect(L10n.t("part.\(part.rawValue).ask.line", language: language).contains(name), "\(name) is not what its question asks for")
            // And the listing says it, with nothing here naming the part.
            let said = try #require(PartWords.holds(part.words.joined(separator: " "), language: language))
            #expect(said.contains(name))
            #expect(!said.contains("part."), "a part was listed by its key: \(said)")
        }
    }

    @Test("The sentences the listing is said in are written in English and in Traditional Chinese with the same arguments, and the third table is the second byte for byte")
    func theWords() throws {
        let english = [
            "part.held.line": "This sign-in allows %@.",
            "part.held.partly": "%@ (in part)",
            "part.held.other": "This sign-in has %@, which this version of Fediqo does not ask for.",
            "part.reading.name": "reading as you",
            "part.search.name": "searching as you",
            "part.acting.name": "writing as you",
            "part.bookmarks.name": "bookmarks",
            "part.notices.name": "your notices",
            "part.notices.name.beside": "dismissing your notices",
        ]
        let chinese = [
            "part.held.line": "這個登入允許：%@。",
            "part.held.partly": "%@（部分）",
            "part.held.other": "這個登入有 %@，是這個版本的 Fediqo 不會問的。",
            "part.reading.name": "以你的身分讀取",
            "part.search.name": "以你的身分搜尋",
            "part.acting.name": "以你的身分寫入",
            "part.bookmarks.name": "書籤",
            "part.notices.name": "你的通知",
            "part.notices.name.beside": "移除通知",
        ]
        let tables = try ["en", "zh-TW", "zh-Hant"].map(Self.table)
        for key in english.keys.sorted() {
            for table in tables { #expect(table.contains("\n\"\(key)\" = \""), "\(key) is missing from a table") }
            let en = L10n.t(key, language: .english)
            let zh = L10n.t(key, language: .taiwanese)
            #expect(en == english[key])
            #expect(zh == chinese[key])
            #expect(en.components(separatedBy: "%@").count == zh.components(separatedBy: "%@").count)
        }
        #expect(tables[1] == tables[2])
    }

    // MARK: - Where it is drawn

    @Test("The row's menu does not say it (#385) — the source's page does — a listener hears it as one sentence after the row's own; it is no warning, and the row draws no sentence of it")
    func theRowSaysIt() async throws {
        let (session, _, _) = try await shell(holding: Self.acts)
        let holds = try #require(session.mastodon.holds(host: host, language: .english))
        #expect(holds == "This sign-in allows reading as you, searching as you, writing as you.")
        #expect(session.mastodon.holds(host: "Social.Example", language: .english) == holds)
        let row = try #require(session.rows.first { $0.source.host == host })
        // Made before bookmarks were asked for: the row owes the question, and says so last.
        #expect(row.owed == .asking)
        #expect(SourceRow.permissionLine(row, language: .english) != nil)
        #expect(SourceRow.heard(row: "the row", said: ["waiting"], holds: holds) == "the row waiting \(holds)")
        #expect(SourceRow.heard(row: "the row", said: []) == "the row")
        let drawn = view(row, holds: session.mastodon.holds(host: host))
        // Inverted (#385): the menu was headed by what the sign-in holds; it holds acts alone.
        #expect(drawn.more.reasons.isEmpty)
        #expect(drawn.more.items.map(\.name) == view(row, holds: nil).more.items.map(\.name))
        // What a sign-in holds is not something that went wrong: `…` stays as it was.
        #expect(drawn.saying == .nothing)
        #expect(drawn.said.isEmpty)
        let refused = view(row, refusal: (host: host, key: "account.bookmarks.failed"), holds: holds)
        #expect(refused.saying == .warns)
        #expect(refused.more.reasons.isEmpty)
    }

    @Test("A listener hears the listing in place of the row's one word for reading or writing — a sign-in that only reads may hold a part that acts, and one word would say otherwise; the word stays where there is no listing, and where a write was refused")
    func theRowIsHeard() async throws {
        func row(_ writing: SourceWriting, signedIn: Bool = true) -> SourceRow {
            SourceRow(source: Source(host: host, kind: .mastodon), profile: .unasked(host: host, kind: .mastodon), signedIn: signedIn, writing: writing)
        }
        func heard(_ row: SourceRow, _ scopes: String?) -> String {
            view(row, holds: PartWords.holds(scopes, language: .english)).heard
        }
        let name = SourceRow.spoken(row(.reads, signedIn: false))
        let word = (read: L10n.t("account.source.writing.read"), write: L10n.t("account.source.writing.write"), refused: L10n.t("account.source.writing.refused"))
        #expect(name.hasSuffix(", \(word.read)"))
        let identity = String(name.dropLast(word.read.count + 2))
        // A reading sign-in; one holding a part that acts; one that acts: the listing says which.
        #expect(heard(row(.reads), Self.reads) == "\(identity) This sign-in allows reading as you, searching as you.")
        #expect(heard(row(.reads), Self.reads + " write:bookmarks") == "\(identity) This sign-in allows reading as you, searching as you, bookmarks.")
        #expect(heard(row(.writes), Self.acts) == "\(identity) This sign-in allows reading as you, searching as you, writing as you.")
        // No sign-in: nothing is listed, and the word is what there is.
        #expect(heard(row(.reads, signedIn: false), nil) == "\(identity), \(word.read)")
        // Refused: the listing does not say it, so the word does, and the listing follows.
        #expect(heard(row(.refused), Self.acts) == "\(identity), \(word.refused) This sign-in allows reading as you, searching as you, writing as you.")
        #expect(SourceRow.spoken(row(.writes)) == "\(identity), \(word.write)")
        #expect(try Self.source("SourceRow.swift").contains(".accessibilityLabel(heard)"))
    }

    @Test("The source's own page says it whole, after whatever else stands about the source; a source with no sign-in, and a forum, say nothing of it and read as they did")
    func thePageSaysIt() async throws {
        let (session, _, _) = try await shell(holding: Self.reads + " write:bookmarks")
        let sheet = JoinSheet(session: session)
        #expect(sheet.standingLines(host, language: .english) == ["This sign-in allows reading as you, searching as you, bookmarks."])
        session.rowRefusal = (host: host, key: "part.ask.stranded")
        #expect(sheet.standingLines(host, language: .english) == [
            "social.example could not be asked for this in this run.",
            "This sign-in allows reading as you, searching as you, bookmarks.",
        ])
        // A forum has no parts: nothing is said, on its page or its row.
        #expect(session.mastodon.holds(host: forum) == nil)
        #expect(sheet.standingLines(forum).isEmpty)
        let board = try #require(session.rows.first { $0.source.host == forum })
        #expect(view(board, holds: session.mastodon.holds(host: forum)).more.items.map(\.name) == view(board, holds: nil).more.items.map(\.name))
        let (out, _, _) = try await shell(holding: nil)
        #expect(out.mastodon.holds(host: host) == nil)
        #expect(JoinSheet(session: out).standingLines(host).isEmpty)
    }

    @Test("Account hands each row what its own sign-in holds, read as the row is drawn; and the listing reads what rides beside a sign-in, never a token")
    func accountHandsItIn() throws {
        let pane = try Self.source("AccountPane.swift")
        #expect(pane.contains("holds: session.mastodon.holds(host: row.source.host),"))
        let listing = try Self.source("PartHolds.swift")
        #expect(listing.contains("heldParts[raw.lowercased()]"))
        #expect(!listing.contains("tokens"))
        #expect(!listing.contains("accessToken"))
        // Nothing in it names a part: a part added to the table is listed by its name alone.
        for part in MastodonPart.allCases { #expect(!listing.contains(".\(part.rawValue)")) }
    }

    // MARK: - Read when drawn

    @Test("What is said is what is held when it is drawn: wider after a part is allowed in place, another sign-in's after one takes its place, and nothing once signed out or removed")
    func readWhenDrawn() async throws {
        let (session, _, tokens) = try await shell(holding: Self.acts)
        func says() -> String? { session.mastodon.holds(host: host, language: .english) }
        #expect(says() == "This sign-in allows reading as you, searching as you, writing as you.")

        await session.allowBookmarks(host: host, through: PartPage())
        #expect(try tokens.token(host: host)?.accessToken == "new-1")
        #expect(says() == "This sign-in allows reading as you, searching as you, writing as you, bookmarks.")

        try tokens.save(MastodonToken(
            host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.reading, asked: Self.reading
        ))
        session.mastodon.refresh()
        #expect(says() == "This sign-in allows reading as you.")

        await session.signOut(host: host)
        #expect(says() == nil)
        #expect(JoinSheet(session: session).standingLines(host).isEmpty)

        let (removed, _, _) = try await shell(holding: Self.acts)
        #expect(removed.mastodon.holds(host: host) != nil)
        await removed.remove(host: host)
        #expect(removed.mastodon.holds(host: host) == nil)
    }
}
