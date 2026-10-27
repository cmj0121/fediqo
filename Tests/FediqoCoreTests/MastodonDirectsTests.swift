import Foundation
import Testing
@testable import FediqoCore

/// #326, in the half Core holds: a page of conversations, marking one read, and removing one
/// from the list.
///
/// **The shape and the ids are the published docs** (methods, updated May 2026), not a capture
/// of a live server. That sample leaves a status's body as a comment, so the fixture fills
/// `display_name` and `content` and keeps the documented ids.
@Suite("Posts written to named people, read as conversations")
struct MastodonDirectsTests {
    private static let host = "m.example"
    private static let origin = "https://\(host)"
    private static let reading = "read:statuses read:lists read:accounts"
    private static let writing = "write:conversations"
    private static let page = "/api/v1/conversations?limit=20"

    private static func token(_ scopes: String) -> MastodonToken {
        MastodonToken(host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret", scopes: scopes)
    }

    private func door(_ scopes: String, _ routes: [String: FormServer.Answer]) throws -> (MastodonAuthorized, FormServer) {
        let server = FormServer(routes)
        let tokens = MemoryMastodonTokens()
        let token = Self.token(scopes)
        try tokens.save(token)
        return (MastodonAuthorized(token: token, sender: server, store: tokens), server)
    }

    /// One account as the docs spell it, with the display name the decoder requires.
    private static func account(_ name: String, _ acct: String, id: String) -> String {
        #"{"id":"\#(id)","username":"\#(acct.split(separator: "@").first ?? "")","acct":"\#(acct)","display_name":"\#(name)"}"#
    }

    /// One status as the docs spell it, with the content and display name the decoder requires.
    private static func status(_ id: String, acct: String, name: String, content: String, at: String) -> String {
        #"{"id":"\#(id)","created_at":"\#(at)","content":"\#(content)","visibility":"direct","account":\#(account(name, acct, id: "1"))}"#
    }

    private static func conversation(_ id: String, unread: Bool, accounts: String, status: String) -> String {
        #"{"id":"\#(id)","unread":\#(unread),"accounts":[\#(accounts)],"last_status":\#(status)}"#
    }

    /// The two documented conversations. The first's latest post is filled in; the second sends none.
    private static var documented: String {
        let amic = status(
            "103196583826321184", acct: "amic@nulled.red", name: "Amic",
            content: "<p>written to you</p>", at: "2019-11-25T04:08:24.000Z"
        )
        let first = conversation("418450", unread: true, accounts: account("Amic", "amic@nulled.red", id: "482403"), status: amic)
        let second = conversation("418374", unread: false, accounts: account("Freon", "freon@letsalllovela.in", id: "482401"), status: "null")
        return "[\(first),\(second)]"
    }

    private static let next = #"<https://m.example/api/v1/conversations?limit=20&max_id=418374>; rel="next""#

    @Test("A page is the documented conversations: the latest post is a note of that category alone, direct, listed by the conversation, and a missing latest post is a line that cannot be opened")
    func aPage() async throws {
        let (door, server) = try door(Self.reading, ["GET \(Self.page)": .init(body: Self.documented, link: Self.next)])
        let read = try await MastodonDirects(door: door).page(after: nil)
        #expect(read.next == "418374")
        #expect(read.lines.map(\.id) == ["418450", "418374"])
        let open = try #require(read.lines.first)
        #expect(open.unread && open.names == ["Amic"] && open.handles == ["@amic@nulled.red"])
        #expect(open.words == "written to you" && open.statusRow != nil)
        let quiet = read.lines[1]
        #expect(!quiet.unread && quiet.names == ["Freon"] && quiet.words.isEmpty && quiet.statusRow == nil)
        let note = try #require(read.notes["418450"])
        #expect(note.categories == [.conversations] && !note.categories.contains(.public))
        #expect(note.audience == .mentioned && note.listed[.conversations] == "418450")
        #expect(note.mentions == ["@amic@nulled.red"] && read.notes["418374"] == nil)
        #expect(await server.asked.map(\.address) == ["\(Self.origin)\(Self.page)"])
        let source = Source(host: Self.host, kind: .mastodon, lists: [ListSubscription(id: "7", name: "Friends")])
        #expect(source.kind.offers.categories(of: source, signedIn: true, directs: true) == [
            .public, .trends, .home, .conversations, .list(id: "7"),
        ])
        #expect(ProtocolKind.allCases.filter(\.offers.conversations) == [.mastodon])
    }

    @Test("The next page is asked with the id the link named, and a link that hands the same id back is not a page")
    func paging() async throws {
        let onward = "\(Self.page)&max_id=418374"
        let (door, server) = try door(Self.reading, [
            "GET \(Self.page)": .init(body: Self.documented, link: Self.next),
            "GET \(onward)": .init(body: "[]", link: Self.next),
        ])
        let directs = MastodonDirects(door: door)
        #expect(try await directs.page(after: nil).next == "418374")
        await #expect(throws: PagingError.notPaging) { try await directs.page(after: "418374") }
        #expect(await server.asked.map(\.address) == ["\(Self.origin)\(Self.page)", "\(Self.origin)\(onward)"])
    }

    @Test("A repeated conversation is kept once, the first time; a body that is no list, and a next that names no id, are unreadable")
    func unreadable() async throws {
        let twice = Self.conversation(
            "418450", unread: true, accounts: Self.account("Amic", "amic@nulled.red", id: "482403"),
            status: Self.status("103196583826321184", acct: "amic@nulled.red", name: "Amic", content: "<p>first</p>", at: "2019-11-25T04:08:24.000Z")
        )
        let again = Self.conversation(
            "418450", unread: false, accounts: Self.account("Other", "other@m.example", id: "2"),
            status: Self.status("1", acct: "other@m.example", name: "Other", content: "<p>second</p>", at: "2019-11-25T04:08:24.000Z")
        )
        let (held, _) = try door(Self.reading, ["GET \(Self.page)": .init(body: "[\(twice),\(again)]")])
        let read = try await MastodonDirects(door: held).page(after: nil)
        #expect(read.lines.map(\.id) == ["418450"] && read.lines[0].words == "first" && read.lines[0].unread)

        let (bad, _) = try door(Self.reading, ["GET \(Self.page)": .init(body: "not a list")])
        await #expect(throws: MastodonDirectsError.unreadable) { try await MastodonDirects(door: bad).page(after: nil) }
        let nameless = #"<https://m.example/api/v1/conversations?limit=20>; rel="next""#
        let (linked, _) = try door(Self.reading, ["GET \(Self.page)": .init(body: "[]", link: nameless)])
        await #expect(throws: MastodonDirectsError.unreadable) { try await MastodonDirects(door: linked).page(after: nil) }
    }

    @Test("An answer keeps the people it was meant for, drops anybody else, and goes only to named people")
    func theAnswer() {
        let prepared = DirectAnswer.prepared("hello @stranger @ada@m.example", to: ["@ada@m.example", "", "@Ada@m.example"])
        #expect(prepared.text == "@ada@m.example hello" && prepared.audience == .mentioned)
        let stopped = DirectAnswer.prepared("see @ada@m.example.", to: ["@ada@m.example"])
        #expect(stopped.text == "@ada@m.example see")
    }

    @Test("Reading without the reading part, and changing without write:conversations, ask nothing; the coarse word write is not that part")
    func unasked() async throws {
        let none = try door(Self.writing, [:])
        await #expect(throws: MastodonDirectsError.unasked) { try await MastodonDirects(door: none.0).page(after: nil) }
        #expect(await none.1.asked.isEmpty)
        let reads = try door(Self.reading, [:])
        await #expect(throws: MastodonDirectsError.unasked) { try await MastodonDirects(door: reads.0).markRead("418450") }
        await #expect(throws: MastodonDirectsError.unasked) { try await MastodonDirects(door: reads.0).remove("418450") }
        let coarse = try door("\(Self.reading) write", [:])
        await #expect(throws: MastodonDirectsError.unasked) { try await MastodonDirects(door: coarse.0).markRead("418450") }
        let readsAsked = await reads.1.asked
        let coarseAsked = await coarse.1.asked
        #expect(readsAsked.isEmpty && coarseAsked.isEmpty)
    }

    @Test("Marking one read and removing one are one write each, and an id that cannot stand in a path asks nothing")
    func changing() async throws {
        let scopes = "\(Self.reading) \(Self.writing)"
        let (door, server) = try door(scopes, [
            "POST /api/v1/conversations/418450/read": .init(body: #"{"id":"418450","unread":false,"accounts":[],"last_status":null}"#),
            "DELETE /api/v1/conversations/418450": .init(body: "{}"),
        ])
        let directs = MastodonDirects(door: door)
        try await directs.markRead("418450")
        try await directs.remove("418450")
        #expect(await server.asked.map { "\($0.method) \($0.address) [\($0.form)]" } == [
            "POST \(Self.origin)/api/v1/conversations/418450/read []",
            "DELETE \(Self.origin)/api/v1/conversations/418450 []",
        ])
        for id in ["", "a/b", "../x"] {
            await #expect(throws: MastodonRequestError.invalidURL) { try await directs.markRead(id) }
            await #expect(throws: MastodonRequestError.invalidURL) { try await directs.remove(id) }
        }
        #expect(await server.asked.count == 2)
    }
}
