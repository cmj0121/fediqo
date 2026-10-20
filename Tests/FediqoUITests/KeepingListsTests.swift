import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #314, the three lists: whom the reader mutes, whom they block, and the servers they block —
/// reached from their own page, read a stretch at a time by the source's own next, and any entry
/// taken back from its row; and what stands there where the sign-in holds less.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made the ask; every deadline is on a clock nobody turns.
@MainActor
@Suite("Whom the reader mutes and blocks, and the servers they block, read and undone", .serialized, .watched)
struct KeepingListsTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let follows = "\(reads) read:follows write:follows"
    private static let blocking = "\(follows) read:mutes write:mutes read:blocks write:blocks"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let ownLookup = "/api/v1/accounts/lookup?acct=me"
    private static let mutes = "/api/v1/mutes?limit=80"
    private static let mutesOn = "/api/v1/mutes?limit=80&max_id=3"
    private static let blocks = "/api/v1/blocks?limit=80"
    private static let servers = "/api/v1/domain_blocks?limit=80"
    private static let serversOn = "/api/v1/domain_blocks?limit=80&max_id=3"
    private static let serverBlocks = "/api/v1/domain_blocks"

    private static let me = DummyPerson(handle: "@me@m.example", host: host)!
    private static let muted = PeopleList(.muted, at: host)
    private static let blocked = PeopleList(.blocked, at: host)

    private static func account(_ id: String, _ acct: String) -> String {
        #"{"id":"\#(id)","username":"\#(acct)","acct":"\#(acct)","display_name":"","locked":false,"bot":false,"group":false,"note":"","url":"https://m.example/@\#(acct)","avatar":"https://m.example/avatars/original/missing.png","header":"https://m.example/headers/original/missing.png","followers_count":0,"following_count":1,"statuses_count":0,"emojis":[],"fields":[]}"#
    }

    private static func standing(_ id: String, muting: Bool = false, blocking: Bool = false) -> String {
        #"{"id":"\#(id)","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":\#(blocking),"blocked_by":false,"muting":\#(muting),"muting_notifications":\#(muting),"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#
    }

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let base: [String: PageServer.Answer] = [
            Self.who: PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#),
            Self.ownLookup: PageServer.Answer(body: #"{"id":"7","acct":"me","display_name":"Me"}"#),
        ]
        let server = PageServer(routes.merging(base) { mine, _ in mine })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    private func signIn(_ session: ShellSession, holding scopes: String = KeepingListsTests.blocking) async throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
    }

    private func asked(_ server: PageServer) async -> [String] {
        await server.asked.filter { $0 != Self.who }
    }

    // MARK: - The ways to them

    @Test("The reader's own page has a line for each of the three under what is theirs there — never somebody else's page, and never at a kind of source where nobody is muted; where the sign-in does not see them, one line in their place that says how it stands, whose press asks")
    func theWays() async throws {
        let (session, _, _) = await session([:])
        try await signIn(session)
        let pages = ShellPersonPages()
        await pages.opened(Self.me, in: session)
        let entries = pages.keepingEntries(of: Self.me, in: session)
        #expect(entries.map(\.which) == [.muted, .blocked, .servers] && entries.allSatisfy { $0.locked == nil })
        #expect(entries.map { $0.words(language: .english) } == ["People you mute", "People you block", "Servers you block"])
        #expect(entries.map { $0.words(language: .taiwanese) } == ["你靜音的人", "你封鎖的人", "你封鎖的站台"])
        #expect(entries.compactMap(\.list) == [Self.muted, Self.blocked] && entries.last?.list == nil)
        let about = try #require(pages.about(of: Self.me, in: session))
        #expect(about.blocks.suffix(3) == [.muted, .blocked, .servers] || about.blocks.contains(.muted))
        #expect(about.walked.contains("about.muted") && about.walked.contains("about.servers"))

        let ada = try #require(DummyPerson(handle: "@ada@m.example", host: Self.host))
        #expect(pages.keepingEntries(of: ada, in: session).isEmpty, "never on somebody else's page")

        try await signIn(session, holding: Self.follows)
        await pages.opened(Self.me, in: session)
        let locked = pages.keepingEntries(of: Self.me, in: session)
        #expect(locked.count == 1 && locked.first?.locked?.asks == true && locked.first?.words(language: .english) == L10n.t("part.blocks.unasked", language: .english))
    }

    // MARK: - People

    @Test("Whom the reader mutes is asked as them and read on by the source's own next; a row offers Unmute, which is one post to their own address, takes the row off at the press and for good once the source answered — and shows again what this device hid of them")
    func theMuted() async throws {
        let (session, server, _) = await session([
            Self.mutes: PageServer.Answer(
                body: "[\(Self.account("1", "ada")),\(Self.account("2", "bea"))]",
                link: #"<https://m.example/api/v1/mutes?limit=80&max_id=3>; rel="next""#
            ),
            Self.mutesOn: PageServer.Answer(body: "[\(Self.account("3", "cy"))]"),
            "/api/v1/accounts/relationships?id%5B%5D=1&id%5B%5D=2": PageServer.Answer(body: "[\(Self.standing("1", muting: true)),\(Self.standing("2", muting: true))]"),
            "/api/v1/accounts/relationships?id%5B%5D=3": PageServer.Answer(body: "[\(Self.standing("3", muting: true))]"),
            "/api/v1/accounts/1/unmute": PageServer.Answer(body: Self.standing("1")),
            "/api/v1/accounts/2/unmute": PageServer.Answer(body: "<html>", status: 500),
        ])
        try await signIn(session)
        session.hides.hide("@ada@m.example", at: Self.host, .muted)
        let lists = ShellPersonPages().lists
        await lists.opened(Self.muted, in: session)
        #expect(await asked(server).first == Self.mutes)
        var said = try #require(lists.said(of: Self.muted, in: session))
        #expect(said.people.map(\.accountID) == ["1", "2"] && said.foot == .more && said.acts == [.unmute] && said.lock == nil)
        #expect(said.title(language: .english) == "Who you mute at m.example")
        #expect(PersonRow.standing(said.stands["1"], language: .english) == ["Muted"])
        await lists.readOn(Self.muted, in: session)
        said = try #require(lists.said(of: Self.muted, in: session))
        #expect(said.people.map(\.accountID) == ["1", "2", "3"] && said.foot == .end)

        let ada = try #require(said.people.first)
        await lists.press(.unmute, on: ada, of: Self.muted, in: session)
        #expect(await asked(server).contains("/api/v1/accounts/1/unmute"))
        said = try #require(lists.said(of: Self.muted, in: session))
        #expect(said.people.map(\.accountID) == ["2", "3"] && session.hides.hides.isEmpty)

        let bea = try #require(said.people.first)
        await lists.press(.unmute, on: bea, of: Self.muted, in: session)
        said = try #require(lists.said(of: Self.muted, in: session))
        #expect(said.people.map(\.accountID) == ["2", "3"], "the row whose press did not arrive comes back")
        #expect(said.missed["2"] == "Could not unmute @bea@m.example at m.example.")
    }

    @Test("Whom the reader blocks is asked as them, and a row offers Unblock; nobody signed in, nobody is asked and there is no such list; a sign-in that sees and may not change is shown the rows and offered nothing, under the lock that says so")
    func theBlocked() async throws {
        let (session, server, _) = await session([
            Self.blocks: PageServer.Answer(body: "[\(Self.account("4", "dee"))]"),
            "/api/v1/accounts/relationships?id%5B%5D=4": PageServer.Answer(body: "[\(Self.standing("4", blocking: true))]"),
            "/api/v1/accounts/4/unblock": PageServer.Answer(body: Self.standing("4")),
        ])
        let lists = ShellPersonPages().lists
        await lists.opened(Self.blocked, in: session)
        #expect(await asked(server).isEmpty && lists.said(of: Self.blocked, in: session) == nil, "nobody signed in")

        try await signIn(session, holding: "\(Self.follows) read:mutes read:blocks")
        await lists.opened(Self.blocked, in: session)
        var said = try #require(lists.said(of: Self.blocked, in: session))
        #expect(said.people.map(\.accountID) == ["4"] && said.acts.isEmpty)
        #expect(said.lock?.key == "part.blocks.partly.changing")
        await lists.press(.unblock, on: try #require(said.people.first), of: Self.blocked, in: session)
        #expect(!(await asked(server)).contains("/api/v1/accounts/4/unblock"), "nothing is sent")

        try await signIn(session)
        await lists.opened(Self.blocked, in: session)
        said = try #require(lists.said(of: Self.blocked, in: session))
        #expect(said.acts == [.unblock] && said.lock == nil)
        await lists.press(.unblock, on: try #require(said.people.first), of: Self.blocked, in: session)
        #expect(await asked(server).contains("/api/v1/accounts/4/unblock"))
        #expect(lists.said(of: Self.blocked, in: session)?.people.isEmpty == true)
    }

    // MARK: - Servers

    @Test("The servers the reader blocks are asked as them on the sheet's opening, read on by the source's own next to the end; Unblock is one delete naming the server, which leaves the row and shows again what this device hid of everybody there; one that did not arrive comes back saying so")
    func theServers() async throws {
        let (session, server, work) = await session([
            Self.servers: PageServer.Answer(
                body: #"["spam.example","third.example"]"#,
                link: #"<https://m.example/api/v1/domain_blocks?limit=80&max_id=3>; rel="next""#
            ),
            Self.serversOn: PageServer.Answer(body: #"["far.example"]"#),
            Self.serverBlocks: PageServer.Answer(body: "{}"),
        ])
        try await signIn(session)
        session.hides.hide(server: "spam.example", at: Self.host)
        let pages = ShellPersonPages()
        await pages.servers.show(Self.host, in: session)
        #expect(pages.servers.open == Self.host)
        var said = try #require(pages.servers.said(at: Self.host, in: session))
        #expect(said.servers == ["spam.example", "third.example"] && said.foot == .more && said.unblocks && said.lock == nil)
        #expect(said.title(language: .english) == "Servers you block at m.example")
        await pages.servers.readOn(Self.host, in: session)
        said = try #require(pages.servers.said(at: Self.host, in: session))
        #expect(said.servers == ["spam.example", "third.example", "far.example"] && said.foot == .end)
        #expect(said.footWords(language: .english) == "That is every server m.example says you block.")

        #expect(await pages.servers.unblock("spam.example", at: Self.host, in: session))
        #expect(await server.sent.last.map { "\($0.method) \($0.ask) \($0.body)" } == "DELETE /api/v1/domain_blocks domain=spam.example")
        said = try #require(pages.servers.said(at: Self.host, in: session))
        #expect(said.servers == ["third.example", "far.example"] && session.hides.hides.isEmpty)
        #expect(!(await pages.servers.unblock("spam.example", at: Self.host, in: session)), "a server not listed is sent nothing")

        // A read from the top already on its way when the answer came does not bring it back.
        await server.answer(Self.serverBlocks, PageServer.Answer(body: "{}"))
        await server.hold(Self.servers)
        defer { Task { await server.release(Self.servers) } }
        let serversGuard = watching("the ask of \(Self.servers), held at its server") { await server.release(Self.servers) }
        defer { serversGuard.cancel() }
        await server.answer(Self.servers, PageServer.Answer(body: #"["third.example","far.example"]"#))
        let reading = Task { await pages.servers.again(Self.host, in: session) }
        await server.arrival(of: Self.servers, times: 2, by: reading)
        #expect(await pages.servers.unblock("third.example", at: Self.host, in: session))
        await server.release(Self.servers)
        await reading.value
        said = try #require(pages.servers.said(at: Self.host, in: session))
        #expect(said.servers == ["far.example"], "the read set out before the answer: it does not bring the row back")

        await server.answer(Self.serverBlocks, PageServer.Answer(body: "<html>", status: 500))
        #expect(!(await pages.servers.unblock("far.example", at: Self.host, in: session)))
        said = try #require(pages.servers.said(at: Self.host, in: session))
        #expect(said.servers == ["far.example"] && said.missed == ["far.example"])
        #expect(said.missedWords("far.example", language: .english) == "Could not unblock far.example at m.example.")
        #expect(work.record.contains { $0.reached == Self.host })
    }

    @Test("A server's block taken back at the source shows what was hidden of everybody there, though the sheet was let go while it was out")
    func unblockedThoughLetGo() async throws {
        let (session, server, _) = await session([
            Self.servers: PageServer.Answer(body: #"["spam.example"]"#), Self.serverBlocks: PageServer.Answer(body: "{}"),
        ])
        try await signIn(session)
        session.hides.hide(server: "spam.example", at: Self.host)
        let pages = ShellPersonPages()
        await pages.servers.show(Self.host, in: session)
        await server.hold(Self.serverBlocks)
        defer { Task { await server.release(Self.serverBlocks) } }
        let blocksGuard = watching("the ask of \(Self.serverBlocks), held at its server") { await server.release(Self.serverBlocks) }
        defer { blocksGuard.cancel() }
        let pressed = Task { await pages.servers.unblock("spam.example", at: Self.host, in: session) }
        await server.arrival(of: Self.serverBlocks, by: pressed)
        pages.servers.letGo(at: Self.host)
        await server.release(Self.serverBlocks)
        #expect(!(await pressed.value))
        #expect(session.hides.hides.isEmpty)
    }

    @Test("Where the source gives the whole list of servers blocked in one stretch, a server hidden here that is not on it was taken back elsewhere, and hides nothing more")
    func serverTakenBackElsewhere() async throws {
        let (session, _, _) = await session([Self.servers: PageServer.Answer(body: #"["third.example"]"#)])
        try await signIn(session)
        session.hides.hide(server: "spam.example", at: Self.host)
        session.hides.hide(server: "third.example", at: Self.host)
        await ShellPersonPages().servers.show(Self.host, in: session)
        #expect(session.hides.hides.compactMap(\.server) == ["third.example"])
    }

    @Test("Signed in for less than reading the servers blocked, the sheet asks the source nothing and says how the sign-in stands, offering to ask; seeing and not changing, it lists them and offers no Unblock")
    func theServersSignedInForLess() async throws {
        let (session, server, _) = await session([Self.servers: PageServer.Answer(body: #"["spam.example"]"#)])
        try await signIn(session, holding: Self.follows)
        let pages = ShellPersonPages()
        await pages.servers.show(Self.host, in: session)
        #expect(!(await asked(server)).contains(Self.servers))
        let said = try #require(pages.servers.said(at: Self.host, in: session))
        #expect(said.lock?.asks == true && !said.unblocks && said.servers.isEmpty)
        #expect(said.lockWords(language: .english) == L10n.t("part.blocks.unasked", language: .english))

        try await signIn(session, holding: "\(Self.follows) read:mutes read:blocks")
        await pages.servers.show(Self.host, in: session)
        let seeing = try #require(pages.servers.said(at: Self.host, in: session))
        #expect(seeing.servers == ["spam.example"] && !seeing.unblocks && seeing.lock?.key == "part.blocks.partly.changing")
        #expect(!(await pages.servers.unblock("spam.example", at: Self.host, in: session)))
    }
}
