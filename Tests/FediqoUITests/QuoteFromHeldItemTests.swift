import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #293: a quoting post keeps only its reference to the post it quotes, and every row that
/// draws the quote draws it from that post's own item — in a timeline, in an opened thread, on
/// a reblog's row and on a person's page — and says so where the item is no longer held.
@MainActor
@Suite("A quote is drawn from the quoted post's own item")
struct QuoteFromHeldItemTests {
    private static let host = "social.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private static func name(_ id: String) -> String { "https://\(host)/users/x/statuses/\(id)" }

    private static let quoted = QuotedPost(
        id: name("7"), statusID: "7", author: "Cyd", handle: "@cyd@\(host)", body: "the quoted words",
        postedAt: origin, attachments: [Attachment(kind: .image, url: URL(string: "https://\(host)/cat.png"), alt: "a cat")],
        sensitive: true, spoiler: "a cover"
    )

    /// Ada's post quoting Cyd's, as a status that quotes one arrives: the quoted post beside it.
    private static func quoting(_ id: String = "9", answering parent: String? = nil) -> Note {
        Note(
            id: name(id), source: source, author: "Ada", handle: "@ada@\(host)", body: "look at this",
            postedAt: origin.addingTimeInterval(60), categories: [.public],
            reply: parent.map { Reply(inReplyToId: $0) }, statusID: id, quote: Quote(state: .accepted, post: quoted)
        )
    }

    private static func shell(_ notes: [Note]) async -> ShellSession {
        let store = ItemStore(sources: [source], notes: [])
        let session = ShellSession(http: FixtureHTTP(), store: store, posts: ForumPosts(http: FixtureHTTP()))
        await store.ingest(notes, ifSourceHere: host)
        await session.reloadFromStore()
        return session
    }

    private static func rowID(_ id: String) -> String { NoteKey(host: host, id: name(id)).rowID }

    @Test("The quoting row holds nothing of the quoted post, which is an item of its own; a timeline's row draws the quote from that item, with everything a quote shows of one, and opens it")
    func drawnFromTheItem() async throws {
        let session = await Self.shell([Self.quoting()])
        let held = try #require(session.heldNote(Self.rowID("9")))
        #expect(held.brought.isEmpty && held.quote == Quote(state: .accepted, statusID: "7"))
        #expect(held.refs == [.quotes(.accepted, id: Self.name("7"), statusID: "7")])
        #expect(session.heldNote(Self.rowID("7"))?.body == "the quoted words", "in All, a post like any other")

        let row = try #require(session.timelineItems(latest: nil).first { $0.id == Self.rowID("9") })
        #expect(row.quote?.post == Self.quoted, "its words, its author, its cover and its picture")
        #expect(row.quotedRowID == Self.rowID("7") && session.quotedRow(of: row) == Self.rowID("7"))
        #expect(QuoteBand.Loading(row) == nil)
        #expect(session.held(Self.rowID("9"))?.quote?.post == Self.quoted, "and the row looked up by itself")
        #expect(DummyPerson.held(of: try #require(DummyPerson(making: held)), in: session.notes).first?.quote?.post == Self.quoted, "and on its author's page")
        // Only a post of the row's own source is what it quotes, whatever a name spells.
        let elsewhere = Note(
            id: Self.name("7"), source: Source(host: "other.example", kind: .mastodon), author: "Mal", handle: "@mal@other.example",
            body: "not what was quoted", postedAt: Self.origin, categories: []
        )
        #expect(DummyItem(held).quoting(elsewhere).quote?.post == nil)
        #expect(DummyItem(held).quoting(nil).quote?.post == nil)
        // A row made of the note alone has no item to draw from, and draws none of it.
        #expect(DummyItem(held).quote == Quote(state: .accepted, statusID: "7"))
    }

    @Test("The quoted post changed at its source since: the quote shows what it says now, since there is one copy of it")
    func whatItSaysNow() async throws {
        let session = await Self.shell([Self.quoting()])
        var edited = Self.quoted.note(through: Self.source)
        edited = Note(
            id: edited.id, source: Self.source, author: "Cyd", handle: edited.handle, body: "the quoted words, corrected",
            postedAt: edited.postedAt, categories: [], statusID: "7", editedAt: Self.origin.addingTimeInterval(600)
        ).readNow()
        _ = await session.store.refresh([edited], ifSourceHere: Self.host)
        await session.reloadFromStore()
        #expect(session.held(Self.rowID("9"))?.quote?.post?.body == "the quoted words, corrected")
    }

    @Test("In an opened thread, on a reblog's row, and on the post a reblog shows, the quote is drawn the same way")
    func everywhereARowIsDrawn() async throws {
        let reblog = Note(
            id: "https://\(Self.host)/users/bob/statuses/900/activity", source: Self.source, author: "Bob",
            handle: "@bob@\(Self.host)", body: "", postedAt: Self.origin.addingTimeInterval(900), categories: [.public],
            statusID: "900", refs: [Reference(kind: .reblogs, id: Self.name("9"), statusID: "9")]
        )
        let parent = Note(
            id: Self.name("5"), source: Self.source, author: "Dee", handle: "@dee@\(Self.host)", body: "a question",
            postedAt: Self.origin, categories: [.public], statusID: "5"
        )
        let session = await Self.shell([parent, Self.quoting("9", answering: "5"), reblog])
        let reblogRow = try #require(session.held(reblog.key.rowID))
        #expect(reblogRow.isReblog && reblogRow.quote?.post == Self.quoted)
        #expect(reblogRow.reblogged.first?.quote?.post == Self.quoted)

        // The thread around the post it answers: the quoting post is an answer drawn there.
        let root = try #require(session.held(Self.rowID("5")))
        await session.reload.opened(root, in: session)
        let answer = try #require(session.conversations.conversation(around: root).descendants.first?.item)
        #expect(answer.id == Self.rowID("9") && answer.quote?.post == Self.quoted)
    }

    @Test("The quoted post let go: the quoting row stays, names it still, draws nothing of it and says it is no longer held; the same post arriving again is drawn again")
    func noLongerHeld() async throws {
        let session = await Self.shell([Self.quoting()])
        await session.store.forget(NoteKey(host: Self.host, id: Self.name("7")))
        await session.reloadFromStore()
        let row = try #require(session.held(Self.rowID("9")))
        #expect(row.quote == Quote(state: .accepted, statusID: "7"), "which post, and nothing of it")
        #expect(QuoteBand.Loading(row) == .unheld)
        #expect(QuoteBand.decorator(try #require(row.quote), loading: .unheld, language: .english) == "quoted post no longer held")
        #expect(session.quotedRow(of: row) == nil, "and it opens nowhere")
        #expect(!session.notes.contains { $0.body.contains("the quoted words") }, "its words are nowhere on this device")

        await session.store.ingest([Self.quoted.note(through: Self.source)], ifSourceHere: Self.host)
        await session.reloadFromStore()
        #expect(session.held(Self.rowID("9"))?.quote?.post == Self.quoted)
    }

    @Test("A quote that may not be shown names no post and draws none, whatever its source sent beside the state", arguments: [Quote.State.pending, .rejected, .revoked, .deleted, .unauthorized, .blockedAccount, .unknown])
    func mayNotBeShown(state: Quote.State) async throws {
        let reference = Reference(kind: .quotes, id: Self.name("7"), statusID: "7", state: state)
        #expect(reference.id == nil && reference.statusID == nil)
        let hidden = Note(
            id: Self.name("9"), source: Self.source, author: "Ada", handle: "@ada@\(Self.host)", body: "look",
            postedAt: Self.origin, categories: [.public], statusID: "9", refs: [reference]
        )
        let session = await Self.shell([hidden, Self.quoted.note(through: Self.source)])
        let row = try #require(session.held(Self.rowID("9")))
        #expect(row.quote == Quote(state: state) && row.quotedRowID == nil)
        #expect(QuoteBand.Loading(row) == nil)
    }
}
