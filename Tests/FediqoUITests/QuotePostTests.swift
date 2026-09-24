import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #214: a post that quotes another draws it inside, opens it, and says why where it cannot.
@MainActor
@Suite("A post that quotes another", .serialized)
struct QuotePostTests {
    private static let host = "one.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private static func quoted(
        _ id: String, body: String = "The first post, by Ada", spoiler: String? = nil,
        quoting: NestedQuote? = nil
    ) -> QuotedPost {
        QuotedPost(
            id: "https://\(host)/users/ada/statuses/\(id)", statusID: id, author: "Ada",
            handle: "@ada@\(host)", body: body, postedAt: origin,
            sensitive: spoiler == nil ? false : true, spoiler: spoiler ?? "",
            audience: .everyone, quoting: quoting
        )
    }

    private static func quoting(_ id: String, quote: Quote?) -> Note {
        Note(
            id: "https://\(host)/users/bob/statuses/\(id)", source: source, author: "Bob",
            handle: "@bob@\(host)", body: "Bob says this is worth reading",
            postedAt: origin.addingTimeInterval(60), categories: [.public], statusID: id, quote: quote
        )
    }

    /// A session over a store holding `notes` and nothing on the network: every read fails.
    private func shell(_ notes: [Note]) async -> ShellSession {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest(notes)
        let http = FixtureHTTP([:])
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: QuoteNoSender()),
            posts: ForumPosts(http: http)
        )
        await session.reloadFromStore()
        return session
    }

    // MARK: - Held, and shown with the network off

    @Test("With nothing on the network, the quoted post is held aside, opens, and All does not grow")
    func offlineAndAside() async throws {
        let note = Self.quoting("2", quote: Quote(state: .accepted, post: Self.quoted("1")))
        let session = await shell([note])
        #expect(session.notes.map(\.key) == [note.key], "All is the quoting post alone")
        let item = try #require(session.held(note.key.rowID))
        #expect(item.quote?.post?.body == "The first post, by Ada")
        let target = try #require(session.quotedRow(of: item))
        #expect(target == item.quotedRowID)
        let opened = try #require(session.held(target))
        #expect(opened.body == "The first post, by Ada")
        #expect(opened.author == "Ada")
    }

    @Test("A quote of a quote shows one level, and the next opens where this device holds it")
    func nestedOpensTheNextLevel() async throws {
        let first = Self.quoting("1", quote: nil)
        // Bob's post "3" quotes Ada's "2", which in turn quotes "1" — an id alone, a level down.
        let middle = Self.quoted("2", quoting: NestedQuote(state: .accepted, statusID: "1"))
        let outer = Self.quoting("3", quote: Quote(state: .accepted, post: middle))
        let session = await shell([first, outer])
        let item = try #require(session.held(outer.key.rowID))
        #expect(QuoteBand.spoken(try #require(item.quote?.post), lifted: false, language: .english)
            .hasSuffix(L10n.t("quote.nested", language: .english)))
        let middleRow = try #require(session.quotedRow(of: item))
        let middleItem = try #require(session.held(middleRow))
        #expect(middleItem.quote?.post == nil, "one level: the next is an id")
        #expect(session.quotedRow(of: middleItem) == first.key.rowID, "and it opens where it is held")
        let quotes = ShellQuotes()
        quotes.target = { session.quotedRow(of: $0) }
        #expect(quotes.leads(from: middleItem))
    }

    // MARK: - Opening, and leaving

    @Test("Opening the quote walks to the quoted post, and leaving gives the quoting post back")
    func openAndLeave() async throws {
        let note = Self.quoting("2", quote: Quote(state: .accepted, post: Self.quoted("1")))
        let session = await shell([note])
        let item = try #require(session.held(note.key.rowID))
        var walk = ShellWalk()
        let lamp = FediqoRootView.walkToQuote(from: item, quoted: session.quotedRow(of: item), on: &walk)
        #expect(lamp == item.quotedRowID)
        #expect(walk.openedThread == item.quotedRowID)
        #expect(FediqoRootView.walkToQuote(from: item, quoted: lamp, on: &walk) == nil, "not a second step")
        let stepped = walk.back()
        let back = try #require(stepped)
        #expect(back.lamp == item.id, "the quoting post, lit again")
        #expect(walk.isEmpty)
        #expect(DummyCommand.from("o") == .openQuote)
        #expect(DummyShortcut.all.contains { $0.commands == [.openQuote] && $0.keys == ["o"] })
    }

    @Test("A quote opens only where its post is held: no press, key or action is offered for nothing")
    func leadsOnlyWhereHeld() async throws {
        let note = Self.quoting("2", quote: Quote(state: .accepted, post: Self.quoted("1")))
        let session = await shell([note])
        let item = try #require(session.held(note.key.rowID))
        let quotes = ShellQuotes()
        #expect(!quotes.leads(from: item), "no walk to answer: nothing to offer")
        quotes.target = { _ in nil }
        #expect(!quotes.leads(from: item), "the quoted post is not held — cut by the keep window, say")
        quotes.target = { session.quotedRow(of: $0) }
        #expect(quotes.leads(from: item))
    }

    @Test("A quote that may not be shown opens nothing")
    func hiddenOpensNothing() async throws {
        let note = Self.quoting("2", quote: Quote(state: .revoked))
        let session = await shell([note])
        let item = try #require(session.held(note.key.rowID))
        #expect(item.quotedRowID == nil)
        #expect(session.quotedRow(of: item) == nil)
        var walk = ShellWalk()
        #expect(FediqoRootView.walkToQuote(from: item, quoted: session.quotedRow(of: item), on: &walk) == nil)
        #expect(!ShellQuotes().leads(from: item))
    }

    // MARK: - What it says

    @Test("Each state that cannot be shown has its own sentence, in each language, and names nothing of the post")
    func sentences() {
        let hidden = Quote.State.allCases.filter { $0 != .accepted }
        for language in [DummyLanguage.english, .taiwanese] {
            let said = hidden.map { QuoteBand.sentence(Quote(state: $0), language: language) }
            #expect(Set(said).count == hidden.count, "one sentence per state")
            #expect(said.allSatisfy { !$0.isEmpty && !$0.hasPrefix("quote.") })
            #expect(said.allSatisfy { !$0.contains("Ada") })
        }
        #expect(QuoteBand.sentence(Quote(state: .deleted), language: .taiwanese).contains("來源"))
    }

    @Test("VoiceOver hears `Quoting <author>: <words>`")
    func spoken() {
        let post = Self.quoted("1")
        #expect(QuoteBand.spoken(post, lifted: false, language: .english) == "Quoting Ada: The first post, by Ada")
        #expect(QuoteBand.spoken(post, lifted: false, language: .taiwanese) == "引用 Ada：The first post, by Ada")
    }

    @Test("The row's decorator says who is quoted, or in a few words why not, and is heard in full")
    func decorator() {
        let shown = Quote(state: .accepted, post: Self.quoted("1"))
        #expect(QuoteBand.decorator(shown, language: .english) == "quoting @ada@one.example")
        #expect(QuoteBand.decorator(shown, language: .taiwanese) == "引用 @ada@one.example")
        #expect(QuoteBand.spokenMark(shown, lifted: false, language: .english) == "Quoting Ada: The first post, by Ada")
        let hidden = Quote.State.allCases.filter { $0 != .accepted }
        for language in [DummyLanguage.english, .taiwanese] {
            let short = hidden.map { QuoteBand.decorator(Quote(state: $0), language: language) }
            #expect(Set(short).count == hidden.count, "one phrase per state")
            #expect(short.allSatisfy { !$0.isEmpty && !$0.hasPrefix("quote.") })
        }
        let revoked = Quote(state: .revoked)
        #expect(QuoteBand.spokenMark(revoked, lifted: false, language: .english)
            == QuoteBand.sentence(revoked, language: .english), "a listener hears the whole sentence")
        #expect(QuoteBand.decorator(Quote(state: .accepted, statusID: "9"), language: .english) == "quoting another post")
    }

    @Test("A covered quoting post covers its quote too: the decorator says who, and nothing of the words")
    func coveredQuotingPost() {
        let quote = Quote(state: .accepted, post: Self.quoted("1", body: "the quoted words"))
        let heard = QuoteBand.spokenMark(quote, lifted: false, covered: true, language: .english)
        #expect(heard == "quoting @ada@one.example")
        #expect(!heard.contains("the quoted words"))
        #expect(QuoteBand.spokenMark(quote, lifted: false, covered: false, language: .english)
            .contains("the quoted words"), "lifted, the quote is heard in full")
    }

    @Test("A covered quote stays covered until lifted: its words are neither drawn nor said")
    func coveredStaysCovered() async throws {
        let post = Self.quoted("1", body: "the thing under it", spoiler: "A spoiler")
        let covered = QuoteBand.spoken(post, lifted: false, language: .english)
        #expect(covered.contains("A spoiler"))
        #expect(!covered.contains("the thing under it"))
        #expect(!QuoteBand.decorator(Quote(state: .accepted, post: post), language: .english)
            .contains("the thing under it"), "the decorator names who, never the words")
        #expect(QuoteBand.spoken(post, lifted: true, language: .english).contains("the thing under it"))

        let note = Self.quoting("2", quote: Quote(state: .accepted, post: post))
        let session = await shell([note])
        let item = try #require(session.held(note.key.rowID))
        var decks = ShellDecks()
        #expect(!decks.isQuoteLifted(of: item), "covered until the reader lifts it")
        decks.toggleQuoteCover(of: item)
        #expect(decks.isQuoteLifted(of: item))
        let opened = try #require(item.quotedRowID)
        #expect(decks.isLifted(opened), "the quoted post lifted where it opens, too")
    }

    #if os(macOS)
    // MARK: - The row is still one height

    private static func height(_ item: DummyItem, inFull: Bool = false) -> CGFloat {
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                               marks: .constant(DummyMarks()), inFull: inFull, onToast: { _ in })
            .frame(width: 720)
        let host = NSHostingView(rootView: row)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The same quoting post, boosted by somebody.
    private static func boosted(_ quote: Quote?) -> Note {
        let note = quoting("2", quote: quote)
        return Note(
            id: note.id, source: note.source, author: note.author, handle: note.handle, body: note.body,
            postedAt: note.postedAt, categories: note.categories, boostedBy: "Cyd",
            boosterHandle: "@cyd@\(host)", statusID: note.statusID, quote: quote
        )
    }

    @Test("A quoting row in a list is a boosted row's height, whatever the quoted post wrote, whichever state, boosted or not")
    func oneHeightInTheList() throws {
        let long = String(repeating: "words ", count: 100)
        let quotes = [
            Quote(state: .accepted, post: Self.quoted("1", body: "short")),
            Quote(state: .accepted, post: Self.quoted("1", body: long)),
            Quote(state: .accepted, post: Self.quoted("1", body: long, spoiler: long)),
            Quote(state: .pending),
        ]
        let heights = quotes.map { Self.height(DummyItem(Self.quoting("2", quote: $0))) }
            + quotes.map { Self.height(DummyItem(Self.boosted($0))) }
        let boost = Self.height(DummyItem(Self.boosted(nil)))
        #expect(Set(heights + [boost]).count == 1, "\(heights) against a boost's \(boost)")
        let plain = Self.height(DummyItem(Self.quoting("2", quote: nil)))
        #expect(plain < boost, "a post that quotes nothing keeps the height it had")
        // The pane draws the quoted post whole, so a long one there is far taller than the row.
        let whole = DummyItem(Self.quoting("2", quote: quotes[1]))
        #expect(Self.height(whole, inFull: true) > heights[1] + 40)
        // Close under the words: no empty slot holds a short post's card a square's height away.
        let near = Self.height(DummyItem(Self.quoting("2", quote: quotes[0])), inFull: true)
        let alone = Self.height(DummyItem(Self.quoting("2", quote: nil)), inFull: true)
        #expect(near < alone + 40, "the card sat under an empty slot: \(near) vs \(alone)")
        // And a quote that cannot be shown draws no card there: the decorator says it.
        let hidden = DummyItem(Self.quoting("2", quote: Quote(state: .pending)))
        let pane = Self.height(DummyItem(Self.boosted(nil)), inFull: true)
        #expect(Self.height(hidden, inFull: true) == pane)
        // A covered quoting post draws no card while it is covered: the card is under its cover.
        let covered = { (quote: Quote?) in
            let note = Self.quoting("2", quote: quote)
            return DummyItem(Note(
                id: note.id, source: note.source, author: note.author, handle: note.handle, body: note.body,
                postedAt: note.postedAt, categories: note.categories, boostedBy: "Cyd",
                sensitive: true, spoiler: "Careful", statusID: note.statusID, quote: quote
            ))
        }
        #expect(Self.height(covered(quotes[1]), inFull: true) == Self.height(covered(nil), inFull: true))
    }
    #endif
}

/// A signed-in door nobody holds a token for: never reached.
private struct QuoteNoSender: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw FixtureHTTPError.unmapped
    }
}
