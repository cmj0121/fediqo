import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #326, the page: a conversation is read, opened as its thread, answered to the same people,
/// marked read, and removed from inside `…` after a yes. A sign-in without the part is dim with
/// the part's own sentence, and a refusal leaves the list this device drew as it was.
///
/// Every wait here is the ask itself returning. The fixture is the published docs (May 2026),
/// with the status body that sample leaves out filled in.
@MainActor
@Suite("Conversations at a source", .serialized, .watched)
struct DirectsTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reading = "read:statuses read:lists read:accounts"
    private static let acting = "write:statuses write:favourites"
    private static let part = "write:conversations"
    private static let held = "\(reading) \(acting) \(part)"
    private static let reads = "\(reading) \(acting)"
    private static let list = "/api/v1/conversations?limit=20"
    private static let read = "/api/v1/conversations/418450/read"
    private static let drop = "/api/v1/conversations/418450"

    init() { L10n.language = .english }

    private static func account(_ name: String, _ acct: String) -> String {
        #"{"display_name":"\#(name)","acct":"\#(acct)","username":"\#(acct.split(separator: "@").first ?? "")"}"#
    }

    private static var page: String {
        let status = #"{"id":"103196583826321184","created_at":"2019-11-25T04:08:24.000Z","content":"<p>written to you</p>","visibility":"direct","account":\#(account("Amic", "amic@nulled.red"))}"#
        let amic = #"{"id":"418450","unread":true,"accounts":[\#(account("Amic", "amic@nulled.red")),\#(account("Me", "me"))],"last_status":\#(status)}"#
        let quiet = #"{"id":"418374","unread":false,"accounts":[\#(account("Freon", "freon@letsalllovela.in"))],"last_status":null}"#
        return "[\(amic),\(quiet)]"
    }

    private func session(_ routes: [String: PageServer.Answer], scopes: String = DirectsTests.held) async throws -> (ShellSession, PageServer) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s",
            scopes: scopes, asked: scopes, accountID: "7", handle: "@me@m.example"
        ))
        session.mastodon.refresh()
        return (session, server)
    }

    private func line(_ session: ShellSession, _ id: String = "418450") throws -> DirectLine {
        try #require(session.directs.said(at: Self.host, in: session)?.lines.first { $0.id == id })
    }

    @Test("Opening a conversation marks it read, keeps the post out of the public timeline, and opens its thread; the reader is not who an answer names")
    func opening() async throws {
        let (session, server) = try await session([Self.list: .init(body: Self.page), Self.read: .init(body: "{}")])
        await session.directs.show(Self.host, in: session)
        let said = try #require(session.directs.said(at: Self.host, in: session))
        #expect(said.secrecy(language: .english) == "The server can read these posts. They are not a secret.")
        let open = try line(session)
        #expect(open.unread && open.words == "written to you")
        let quiet = try line(session, "418374")
        #expect(quiet.statusRow == nil && quiet.words.isEmpty)
        var opened: [String] = []
        await session.directs.open(quiet.id, at: Self.host, in: session) { opened.append($0) }
        #expect(opened.isEmpty, "no post to open")
        await session.directs.show(Self.host, in: session)
        await session.directs.open(open.id, at: Self.host, in: session) { opened.append($0) }
        let row = try #require(open.statusRow)
        #expect(opened == [row])
        #expect(await server.sent.contains { $0.ask == Self.read && $0.method == "POST" })
        #expect(try line(session).unread == false)
        let note = try #require(session.heldNote(row))
        #expect(note.categories == [.conversations] && note.audience == .mentioned)
        #expect(session.directs.people[row] == ["@amic@nulled.red"])
        #expect(note.mentions == ["@amic@nulled.red"])
    }

    @Test("Answering from the thread stays with the same people, and a mention of anybody else is dropped")
    func answering() async throws {
        let (session, _) = try await session([Self.list: .init(body: Self.page)])
        await session.directs.show(Self.host, in: session)
        let row = try #require(try line(session).statusRow)
        let item = DummyItem(try #require(session.heldNote(row)))
        #expect(session.openAnswer(to: item, in: item))
        let target = try #require(session.answering)
        #expect(target.directs == ["@amic@nulled.red"] && target.start == .mentioned)
        session.answerDrafts[item.id] = "@amic@nulled.red hello @stranger@x.example"
        #expect(session.send(answer: target))
        let sent = try #require(session.outbox.sendings.last)
        #expect(sent.unsent.audience == .mentioned && sent.unsent.text == "@amic@nulled.red hello")
    }

    @Test("Without write:conversations the list is still read, nothing is marked or removed, and the place says why and asks before any page")
    func locked() async throws {
        let (session, server) = try await session([Self.list: .init(body: Self.page), Self.read: .init(body: "{}")], scopes: Self.reads)
        await session.pressDirects(host: Self.host)
        let said = try #require(session.directs.said(at: Self.host, in: session))
        let lock = try #require(said.lock)
        #expect(lock.key == "part.conversations.unasked" && lock.asks)
        let open = try line(session)
        var opened: [String] = []
        await session.directs.open(open.id, at: Self.host, in: session) { opened.append($0) }
        let row = try #require(open.statusRow)
        let still = try line(session)
        #expect(opened == [row] && still.unread)
        #expect(await server.sent.isEmpty)
        var asked = false
        let menu = DirectsMenu.more(open, lock: lock, host: Self.host, onRemove: {}, onAsk: { asked = true }, language: .english)
        #expect(menu.items.map(\.symbol) == [SourceRow.directsSymbol] && menu.items.allSatisfy { !$0.isDanger })
        #expect(menu.items[0].look == .dim(.askAgain))
        #expect(menu.items[0].title(language: .english).contains(String(format: L10n.t(lock.key, language: .english), Self.host)))
        menu.items[0].press { _ in }
        #expect(asked)
        #expect(session.askFor([.conversations], host: Self.host))
        #expect(session.partAsks.open?.ticked == [.conversations])
        let before = await server.asked.count
        await session.directs.remove(open.id, at: Self.host, in: session)
        let stayed = try line(session)
        #expect(await server.asked.count == before && stayed.id == open.id)

        let forum = SourceRow(
            source: Self.forum, profile: .unasked(host: Self.forum.host, kind: Self.forum.kind), signedIn: true
        )
        let dim = SourceRow.directsMark(forum, actsLive: true, reads: true, place: nil, language: .english)
        #expect(dim.symbol == SourceRow.directsSymbol && dim.look == .dim(.never))
        #expect(dim.name == "Conversations at forum.example")
    }

    @Test("Without reading, the row's item is the reading lock and its press asks; it does not open the list")
    func unreadLocked() async throws {
        let (session, server) = try await session([:], scopes: "\(Self.acting) \(Self.part)")
        let place = try #require(session.directsLock(host: Self.host))
        let row = SourceRow(
            source: Self.source, profile: .unasked(host: Self.host, kind: Self.source.kind), signedIn: true
        )
        let mark = SourceRow.directsMark(row, actsLive: true, reads: false, place: place, language: .english)
        #expect(mark.symbol == SourceRow.directsSymbol && mark.look == .dim(.askAgain))
        #expect(mark.name == String(format: L10n.t(place.key, language: .english), Self.host))
        await session.pressDirects(host: Self.host)
        #expect(session.directs.shown == nil && session.partAsks.open?.ticked == [.reading])
        #expect(await server.asked.isEmpty)
    }

    @Test("Remove is inside …, asks first, and only its yes takes the line off and the category with it; a later read does not bring it back")
    func removing() async throws {
        let (session, server) = try await session([
            Self.list: .init(body: Self.page), Self.drop: .init(body: "{}"),
        ])
        await session.directs.show(Self.host, in: session)
        let open = try line(session)
        var removed = false
        let menu = DirectsMenu.more(open, lock: nil, host: Self.host, onRemove: { removed = true }, onAsk: {}, language: .english)
        #expect(menu.dangers.map(\.symbol) == [SourceRow.directsSymbol])
        var put: [ShellMoreAsk] = []
        menu.items[0].press { put.append($0) }
        #expect(!removed && put.count == 1)
        put[0].answered("cancel")
        #expect(!removed)
        put[0].answered(ShellQuestion.yes)
        #expect(removed)
        let row = try #require(open.statusRow)
        await session.directs.remove(open.id, at: Self.host, in: session)
        #expect(await server.asked.contains(Self.drop))
        #expect(session.directs.said(at: Self.host, in: session)?.lines.contains { $0.id == open.id } == false)
        #expect(session.heldNote(row)?.categories.contains(.conversations) == false)
        await session.directs.again(Self.host, in: session)
        #expect(session.directs.said(at: Self.host, in: session)?.lines.contains { $0.id == open.id } == false)
    }

    @Test("A source that refuses a removal or a fresh read changes nothing on this device; a mark that fails still opens the thread")
    func refused() async throws {
        let (session, server) = try await session([
            Self.list: .init(body: Self.page),
            Self.read: .init(body: #"{"error":"no"}"#, status: 500),
            Self.drop: .init(body: #"{"error":"Record not found"}"#, status: 404),
        ])
        await session.directs.show(Self.host, in: session)
        let open = try line(session)
        var opened: [String] = []
        await session.directs.open(open.id, at: Self.host, in: session) { opened.append($0) }
        let row = try #require(open.statusRow)
        let still = try line(session)
        #expect(opened == [row] && still.unread)
        #expect(session.toast?.text == L10n.t("conversations.markFailed", language: .english))
        await session.directs.remove(open.id, at: Self.host, in: session)
        let said = try #require(session.directs.said(at: Self.host, in: session))
        #expect(said.removeFailed == [open.id] && said.lines.contains { $0.id == open.id })
        #expect(session.heldNote(row)?.categories.contains(.conversations) == true)
        await server.answer(Self.list, PageServer.Answer(body: "no", status: 500))
        await session.directs.again(Self.host, in: session)
        let kept = try #require(session.directs.said(at: Self.host, in: session))
        #expect(kept.failedBanner && kept.lines.map(\.id) == ["418450", "418374"])
    }
}
