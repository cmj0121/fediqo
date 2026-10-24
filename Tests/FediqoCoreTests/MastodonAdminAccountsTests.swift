import Foundation
import Testing
@testable import FediqoCore

/// #382, in the half of it Core holds: the server's accounts read by state and by name, read on,
/// let in or turned away, acted on with the words the server sends, and each act taken back —
/// from what a real 4.6.6 answered (`MastodonAdminAccountsCaptures`).
@Suite("Tending a server: its accounts")
struct MastodonAdminAccountsTests {
    private typealias Captures = MastodonAdminAccountsCaptures

    private static let token = MastodonToken(host: Captures.host, accessToken: "tok-382", clientID: "cid", clientSecret: "secret")
    private static let list = MastodonAdminAccounts.listPath
    private static let one = MastodonAdminAccounts.path
    private static let acted = "117482969882048354"
    private static let away = "117482969876489169", letIn = "117482969869627831", stays = "117482969852808890"

    private func reader(_ routes: [String: PeopleServer.Answer]) throws -> (MastodonAdminAccounts, PeopleServer) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonAdminAccounts(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    @Test("The sign-ups a real server keeps waiting are read newest first, each a person of this server not yet let in, with what they wrote and their address; and read on by the server's own next")
    func theWaiting() async throws {
        let (reader, server) = try reader([
            "\(Self.list)?status=pending": .json(Captures.pending, link: Captures.pendingLink),
            "\(Self.list)?status=pending&max_id=\(Self.away)": .json("[]"),
        ])
        let stretch = try await reader.stretch(AdminAccountFilter())
        #expect(stretch.accounts.map(\.id) == [Self.away, Self.letIn, Self.stays] && stretch.next == nil)
        let first = stretch.accounts[0]
        #expect(first.waiting && first.local && !first.approved && first.reason == "Buy cheap watches.")
        #expect(first.email == "asks_382_away@example.com" && first.person?.handle == "@asks_382_away@mastodon.localhost")
        #expect(await server.asked == ["\(Self.list)?status=pending"])

        let (paging, _) = try self.reader(["\(Self.list)?status=pending": .json(Captures.pendingOne, link: Captures.pendingOneLink)])
        #expect(try await paging.stretch(AdminAccountFilter()).next == Self.away)
    }

    @Test("Found by a state and a name, the name asked as the server matches a username — and `name@server` with the server it names; what is asked by is held to its length")
    func foundByNameAndState() async throws {
        let (reader, server) = try reader(["\(Self.list)?status=active&username=acted_382": .json(Captures.byName, link: Captures.byNameLink)])
        let found = try await reader.stretch(AdminAccountFilter(state: .active, words: " @acted_382 "))
        #expect(found.accounts.map(\.id) == [Self.acted] && !found.accounts[0].waiting)
        #expect(await server.asked == ["\(Self.list)?status=active&username=acted_382"])
        let far = AdminAccountFilter(state: .suspended, words: "far@elsewhere.example").query
        #expect(far.map(\.name) == ["status", "username", "by_domain"] && far.last?.value == "elsewhere.example")
        let long = AdminAccountFilter(words: String(repeating: "x", count: 500)).query
        #expect(long.last?.value?.count == AdminAccountFilter.wordsLength)
    }

    @Test("An act is the server's own address for it, with its type, the words the server sends and whether it tells them by mail; the account read after holds it, and taking it back answers with the account as it stands; a warning cannot be taken back, and is sent with nothing to take back")
    func actsAndUndo() async throws {
        let (reader, server) = try reader([
            "\(Self.one)/\(Self.acted)/action": .json(Captures.silence),
            "\(Self.one)/\(Self.acted)": .json(Captures.silenced),
            "\(Self.one)/\(Self.acted)/unsilence": .json(Captures.unsilence),
        ])
        try await reader.act(.limit, on: Self.acted, words: "Please keep it kind.", tell: false, report: "1")
        let sent = try #require(await server.sent.first)
        #expect(sent.method == "POST" && sent.body.contains("type=silence") && sent.body.contains("send_email_notification=false"))
        #expect(sent.body.contains("report_id=1") && sent.body.contains("text=Please"))
        let held = try await reader.account(Self.acted)
        #expect(held.silenced && held.holds(.limit) && !held.holds(.suspend))
        let back = try await reader.undo(.limit, on: Self.acted)
        #expect(!back.silenced)
        #expect(!AccountAct.warn.undoes && AccountAct.allCases.filter(\.undoes) == [.sensitive, .freeze, .limit, .suspend])
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.undo(.warn, on: Self.acted) }
        #expect(AccountAct.allCases.map(\.rawValue) == ["none", "sensitive", "disable", "silence", "suspend"])
    }

    @Test("A sign-up let in answers with the account approved; one turned away answers with nothing")
    func letInOrTurnedAway() async throws {
        let (reader, server) = try reader([
            "\(Self.one)/\(Self.letIn)/approve": .json(Captures.approve),
            "\(Self.one)/\(Self.away)/reject": .json(Captures.reject),
        ])
        let approved = try await reader.approve(Self.letIn)
        #expect(approved.approved && !approved.waiting)
        try await reader.reject(Self.away)
        #expect(await server.asked == ["\(Self.one)/\(Self.letIn)/approve", "\(Self.one)/\(Self.away)/reject"])
    }

    @Test("Without the standing every read and act is refused as not allowed; what the server refuses is said in its words; an id that cannot stand in a path, or words past the server's length, are asked nothing")
    func refusals() async throws {
        let (reader, server) = try reader([
            "\(Self.list)?status=pending": .json(Captures.writerList, status: 403),
            "\(Self.one)/\(Self.acted)/action": .json(Captures.badType, status: 422),
            "\(Self.one)/\(Self.away)": .json(Captures.actedOn),
        ])
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await reader.stretch(AdminAccountFilter()) }
        await #expect(throws: MastodonAdminError.refused(sentence: "Validation failed: Type is not included in the list")) {
            try await reader.act(.warn, on: Self.acted, words: "", tell: true)
        }
        await #expect(throws: MastodonAdminError.unreadable) { _ = try await reader.account(Self.away) }
        let before = await server.asked.count
        await #expect(throws: MastodonAdminError.invalid) { try await reader.act(.suspend, on: "../1", words: "", tell: false) }
        await #expect(throws: MastodonAdminError.invalid) {
            try await reader.act(.warn, on: Self.acted, words: String(repeating: "w", count: MastodonReports.wordsLength + 1), tell: false)
        }
        #expect(await server.asked.count == before)
    }
}
