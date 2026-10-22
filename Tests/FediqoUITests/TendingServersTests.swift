import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #383, the page: the Servers tab of tending a server — the servers it refuses or allows and the
/// addresses it refuses, each list the role's own; each added, changed or taken off by the rules
/// #381's acts keep; what cuts the server off asks first; and all of it let go with the page or
/// the role.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`); every deadline is on a
/// clock nobody turns.
@MainActor
@Suite("Tending a server: the servers and addresses it refuses", .serialized, .watched)
struct TendingServersTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let tending = "\(reads) admin:read admin:write"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let blocks = "/api/v1/admin/domain_blocks"
    private static let allows = "/api/v1/admin/domain_allows"
    private static let mail = "/api/v1/admin/email_domain_blocks"
    private static let addresses = "/api/v1/admin/ip_blocks"
    /// The seed's Admin: every flag but the administrator's.
    private static let admin = "2097148"
    private static let moderator = "1115420"
    private static let federationOnly = "32"
    private static let blocksOnly = "128"
    private static let page = Tending(host: host, tab: .servers)

    private static func check(permissions: String?) -> PageServer.Answer {
        let role = permissions.map { #","role":{"id":"1","name":"Admin","permissions":"\#($0)"}"# } ?? ""
        return PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"\#(role)}"#)
    }

    private static func block(_ id: String, _ domain: String, _ severity: String = "suspend", media: Bool = false, said: String = "") -> String {
        #"""
        {"id":"\#(id)","domain":"\#(domain)","digest":"x","created_at":"2026-10-22T02:00:00.000Z","severity":"\#(severity)",
         "reject_media":\#(media),"reject_reports":false,"private_comment":"kept","public_comment":"\#(said)","obfuscate":false}
        """#
    }

    private static func named(_ id: String, _ domain: String) -> String {
        #"{"id":"\#(id)","domain":"\#(domain)","created_at":"2026-10-22T02:00:00.000Z"}"#
    }

    private static func address(_ id: String, _ ip: String, _ severity: String = "sign_up_block") -> String {
        #"{"id":"\#(id)","ip":"\#(ip)","severity":"\#(severity)","comment":"range","created_at":"2026-10-22T02:00:00.000Z","expires_at":null}"#
    }

    private static func list(_ items: [String], at path: String, next: String? = nil) -> PageServer.Answer {
        PageServer.Answer(
            body: "[" + items.joined(separator: ",") + "]",
            link: next.map { #"<https://m.example\#(path)?max_id=\#($0)>; rel="next""# }
        )
    }

    private static func seeded(_ more: [String: PageServer.Answer] = [:]) -> [String: PageServer.Answer] {
        [
            blocks: list([block("2", "limited.example", "silence", media: true, said: "Too loud"), block("1", "suspended.example")], at: blocks),
            allows: list([named("1", "allowed.example")], at: allows),
            mail: list([named("1", "spam.example")], at: mail),
            addresses: list([address("1", "192.0.2.0/24")], at: addresses),
        ].merging(more) { $1 }
    }

    private func session(
        _ routes: [String: PageServer.Answer], permissions: String? = admin, holding scopes: String = tending
    ) async throws -> (ShellSession, PageServer, ShellTendingServers) {
        let server = PageServer(routes.merging([Self.who: Self.check(permissions: permissions)]) { mine, _ in mine })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        let pages = ShellPersonPages()
        session.personPages = pages
        return (session, server, pages.tending.servers)
    }

    // MARK: - The tab

    @Test("The tab and each list are the role's: the servers' lists need the flag for federation, the mail domains and the ranges the flag for blocks; a role with neither has no trace of the tab, and asks nothing")
    func theTabIsTheRoles() async throws {
        let (session, _, servers) = try await session(Self.seeded())
        #expect(ShellTending.tabs(at: Self.host, in: session) == [.reports, .people, .servers])
        #expect(TendingTab.allowed(by: MastodonStaff(rawValue: 1)) == [.reports, .people, .servers], "the administrator is allowed every tab")
        await servers.opened(Self.page, in: session)
        let said = servers.said(of: Self.page, in: session)
        #expect(said.blocks?.items.count == 2 && said.allows?.items.count == 1 && said.mail?.items.count == 1 && said.addresses?.items.count == 1)

        let (federation, fedServer, fed) = try await self.session(Self.seeded(), permissions: Self.federationOnly)
        #expect(ShellTending.tabs(at: Self.host, in: federation) == [.servers])
        await fed.opened(Self.page, in: federation)
        let fedSaid = fed.said(of: Self.page, in: federation)
        #expect(fedSaid.blocks != nil && fedSaid.allows != nil && fedSaid.mail == nil && fedSaid.addresses == nil)
        let askedMail = await fedServer.arrivals(of: Self.mail)
        let askedAddresses = await fedServer.arrivals(of: Self.addresses)
        #expect(askedMail == 0 && askedAddresses == 0, "nothing asked of a list the role does not answer for")
        fed.open(.mail, at: Self.host, in: federation)
        #expect(fed.asking == nil)

        let (blocking, _, blk) = try await self.session(Self.seeded(), permissions: Self.blocksOnly)
        await blk.opened(Self.page, in: blocking)
        let blkSaid = blk.said(of: Self.page, in: blocking)
        #expect(blkSaid.blocks == nil && blkSaid.allows == nil && blkSaid.mail != nil && blkSaid.addresses != nil)

        let (moderated, modServer, mod) = try await self.session(Self.seeded(), permissions: Self.moderator)
        #expect(!ShellTending.tabs(at: Self.host, in: moderated).contains(.servers) && !ShellTending.drawn(Self.page, in: moderated))
        await mod.opened(Self.page, in: moderated)
        let modSaid = mod.said(of: Self.page, in: moderated)
        #expect(modSaid.blocks == nil && modSaid.allows == nil && modSaid.mail == nil && modSaid.addresses == nil)
        #expect(await modServer.arrivals(of: Self.blocks) == 0)
    }

    @Test("Each list is read as the server sends it — each server with how hard it is refused, what besides and why; each range with how hard and why — and reads on by its own foot, by the server's next; an empty list says so; a list the server refuses says that")
    func theListsRead() async throws {
        let (session, server, servers) = try await session(Self.seeded([
            Self.allows: Self.list([Self.named("2", "b.example")], at: Self.allows, next: "2"),
            "\(Self.allows)?max_id=2": Self.list([Self.named("1", "a.example")], at: Self.allows),
            Self.mail: Self.list([], at: Self.mail),
        ]))
        await servers.opened(Self.page, in: session)
        var said = servers.said(of: Self.page, in: session, language: .english)
        let limited = try #require(said.blocks?.items.first)
        #expect(TendingServersSaid.lines(of: limited, language: .english) == [
            "Limited · Its pictures and films refused", "Said to all: Too loud", "Kept among staff: kept",
        ])
        #expect(TendingServersSaid.lines(of: try #require(said.addresses?.items.first), language: .english) == ["No sign-ups", "range"])
        #expect(said.mail?.quiet == "It refuses no mail domain." && said.mail?.items.isEmpty == true)
        #expect(said.allows?.more == true && said.blocks?.more == false)
        await servers.readOn(.allows, of: Self.page, in: session)
        said = servers.said(of: Self.page, in: session)
        #expect(said.allows?.items.map(\.domain) == ["b.example", "a.example"] && said.allows?.more == false)
        #expect(await server.arrivals(of: "\(Self.allows)?max_id=2") == 1)
        #expect(servers.walked(Self.page, in: session).first == TendingServersSaid.rowID(.blocks, "2"))
        #expect(servers.walked(Self.page, in: session).count == 5)

        let (refused, _, others) = try await self.session([
            Self.blocks: PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
            Self.allows: PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
            Self.mail: PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
            Self.addresses: PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
        ])
        await others.opened(Self.page, in: refused)
        #expect(others.said(of: Self.page, in: refused, language: .english).blocks?.quiet == "m.example did not allow this for your standing there.")
    }

    // MARK: - Writes

    @Test("Suspending a server asks first, in one line, and sends nothing before its yes; sent, the row is the server's answer, at the top, and the sheet closes; limiting one asks nothing")
    func suspendingAsksFirst() async throws {
        let (session, server, servers) = try await session(Self.seeded())
        await servers.opened(Self.page, in: session)
        servers.open(.block(nil), at: Self.host, in: session)
        servers.asking?.draft.domain = "new.example"
        servers.asking?.draft.severity = .suspend
        #expect(servers.asking?.cutsOff == true)
        await servers.send(on: Self.page, in: session, confirmed: true)
        #expect(servers.asking?.stage == .asking, "a yes not from the question puts the question")
        #expect(await server.sent.isEmpty)
        let ask = try #require(servers.asking)
        #expect(FederationAskSheet.cutsOffLine(ask, language: .english) == "Suspending new.example cuts m.example off from it: nothing goes to it or comes from it.")
        await server.answer(Self.blocks, PageServer.Answer(body: Self.block("3", "new.example")))
        await servers.send(on: Self.page, in: session, confirmed: true)
        #expect(servers.asking == nil)
        let sent = try #require(await server.sent.first)
        #expect(sent.method == "POST" && sent.body.contains("domain=new.example") && sent.body.contains("severity=suspend"))
        #expect(servers.said(of: Self.page, in: session).blocks?.items.first?.id == "3")

        // Changed to limited: nothing cut off, so nothing asked.
        let held = try #require(servers.said(of: Self.page, in: session).blocks?.items.first)
        servers.open(.block(held), at: Self.host, in: session)
        servers.asking?.draft.severity = .limit
        #expect(servers.asking?.cutsOff == false)
        await server.answer("\(Self.blocks)/3", PageServer.Answer(body: Self.block("3", "new.example", "silence")))
        await servers.send(on: Self.page, in: session)
        let method = await server.sent.last?.method
        #expect(servers.asking == nil && method == "PUT")
        #expect(servers.said(of: Self.page, in: session).blocks?.items.first?.severity == .limit)
        // A server held, changed: its name is not, and a sheet that names another is not sent.
        servers.open(.block(held), at: Self.host, in: session)
        servers.asking?.draft.domain = "other.example"
        #expect(servers.asking?.sendable == false)
    }

    @Test("Taking a server off those allowed asks first, saying in one line that it cuts the server off; each kind is added and taken off as the server answers; a refusal stays on the sheet in the server's words and changes nothing")
    func addedAndTakenOff() async throws {
        let (session, server, servers) = try await session(Self.seeded([
            "\(Self.allows)/1": PageServer.Answer(body: "{}"),
            "\(Self.addresses)/1": PageServer.Answer(body: "{}"),
        ]))
        await servers.opened(Self.page, in: session)
        let question = TendingServersSaid.removeQuestion(.allows, name: "allowed.example", host: Self.host, language: .english)
        #expect(question.line == "This cuts m.example off from allowed.example: nothing goes to it or comes from it.")
        #expect(question.choices.map(\.role) == [.destructive])
        let said = servers.said(of: Self.page, in: session, language: .english)
        let more = TendingServersSaid.more(.allows, id: "1", name: "allowed.example", said: said, actions: TendingServersActs(), language: .english)
        #expect(more.items.map(\.isDanger) == [true] && more.items.first?.question?.line == question.line)
        let blockMore = TendingServersSaid.more(try #require(said.blocks?.items.first), said: said, actions: TendingServersActs(), language: .english)
        #expect(blockMore.items.map(\.name) == ["Change…", "Take off"])

        await servers.remove(.allows, id: "1", on: Self.page, in: session)
        #expect(servers.said(of: Self.page, in: session).allows?.items.isEmpty == true)
        await servers.remove(.addresses, id: "1", on: Self.page, in: session)
        #expect(servers.said(of: Self.page, in: session).addresses?.items.isEmpty == true)

        await server.answer(Self.mail, PageServer.Answer(body: Self.named("2", "junk.example")))
        servers.open(.mail, at: Self.host, in: session)
        servers.asking?.domain = "junk.example"
        await servers.send(on: Self.page, in: session)
        #expect(servers.asking == nil && servers.said(of: Self.page, in: session).mail?.items.map(\.domain) == ["junk.example", "spam.example"])

        await server.answer(Self.addresses, PageServer.Answer(body: #"{"error":"Validation failed: Ip can't be blank"}"#, status: 422))
        servers.open(.address, at: Self.host, in: session)
        servers.asking?.ip = "10.0.0.1"
        await servers.send(on: Self.page, in: session)
        #expect(servers.asking?.stage == .failed(String(format: L10n.t("tend.act.refused"), Self.host, "Validation failed: Ip can't be blank")))
        #expect(servers.said(of: Self.page, in: session).addresses?.items.isEmpty == true, "nothing changed here")
        servers.close()
        #expect(servers.asking == nil)

        await server.answer("\(Self.blocks)/1", PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403))
        await servers.remove(.blocks, id: "1", on: Self.page, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.act.notAllowed"), Self.host))
        #expect(servers.said(of: Self.page, in: session).blocks?.items.count == 2)
    }

    @Test("A server taken off while a read of its list is on its way stays gone when the read lands; one added stays")
    func writesKeepTheirRows() async throws {
        let removing = "\(Self.allows)/1"
        let (session, server, servers) = try await session(Self.seeded([removing: PageServer.Answer(body: "{}")]))
        await servers.opened(Self.page, in: session)
        await server.hold(removing)
        await server.hold(Self.allows)
        defer {
            Task {
                await server.release(removing)
                await server.release(Self.allows)
            }
        }
        let held = watching("the taking off and the read, held at their server") {
            await server.release(removing)
            await server.release(Self.allows)
        }
        defer { held.cancel() }
        let writing = Task { await servers.remove(.allows, id: "1", on: Self.page, in: session) }
        await server.arrival(of: removing, by: writing)
        let reading = Task { await servers.again(Self.page, in: session) }
        await server.arrival(of: Self.allows, times: 2, by: reading)
        await server.release(removing)
        await writing.value
        await server.release(Self.allows)
        await reading.value
        #expect(servers.said(of: Self.page, in: session).allows?.items.isEmpty == true, "the one taken off came back")
    }

    @Test("Without the word that changes, every list is read but nothing is offered: tending's lock stands in each act's place, and no sheet opens")
    func theLock() async throws {
        let (session, _, servers) = try await session(Self.seeded(), holding: "\(Self.reads) admin:read")
        await servers.opened(Self.page, in: session)
        let said = servers.said(of: Self.page, in: session, language: .english)
        #expect(!said.acts && said.lock != nil && said.blocks?.items.count == 2)
        servers.open(.block(nil), at: Self.host, in: session)
        #expect(servers.asking == nil)
        let more = TendingServersSaid.more(.allows, id: "1", name: "allowed.example", said: said, actions: TendingServersActs(), language: .english)
        #expect(more.items.allSatisfy { !$0.isDanger })
    }

    @Test("An address refused all access, or a range wider than a /8, asks first in one red line; one that names nothing — the whole of a family among them — says why Send is dim; a name pasted is trimmed and sent in its ASCII spelling")
    func addressesAndNamesAsWritten() async throws {
        let (session, server, servers) = try await session(Self.seeded())
        await servers.opened(Self.page, in: session)
        servers.open(.address, at: Self.host, in: session)
        servers.asking?.ip = "198.51.100.0/24"
        #expect(servers.asking?.cutsOff == false && servers.asking?.whyNot == nil)
        servers.asking?.ip = "10.0.0.0/7"
        #expect(servers.asking?.cutsOff == true, "a range wider than a /8")
        servers.asking?.ip = "198.51.100.0/24"
        servers.asking?.addressSeverity = .noAccess
        #expect(servers.asking?.cutsOff == true)
        await servers.send(on: Self.page, in: session)
        let nothingSent = await server.sent.isEmpty
        #expect(servers.asking?.stage == .asking && nothingSent)
        let ask = try #require(servers.asking)
        #expect(FederationAskSheet.cutsOffLine(ask, language: .english) == "Refusing 198.51.100.0/24 shuts it out of m.example: whole networks may no longer reach it.")
        #expect(FederationAskSheet.cutsOffYes(ask, language: .english) == "Refuse")
        for wrong in ["0.0.0.0/0", "::/0", "1.2.3.4/99", "::::"] {
            servers.asking?.ip = wrong
            #expect(servers.asking?.sendable == false && servers.asking?.whyNot == L10n.t("tend.servers.notAddress"), "\(wrong)")
        }
        servers.close()

        await server.answer(Self.allows, PageServer.Answer(body: Self.named("2", "xn--bcher-kva.example")))
        servers.open(.allow, at: Self.host, in: session)
        servers.asking?.domain = "not a name"
        #expect(servers.asking?.whyNot == L10n.t("tend.servers.notDomain") && servers.asking?.sendable == false)
        servers.asking?.domain = "  Bücher.Example \n"
        #expect(servers.asking?.sendable == true && servers.asking?.whyNot == nil)
        await servers.send(on: Self.page, in: session)
        let body = await server.sent.last?.body
        #expect(servers.asking == nil && body == "domain=xn--bcher-kva.example")
    }

    @Test("A send that cannot go says why and leaves the sheet up — a change already on its way to the row — and a sheet the role no longer allows closes with nothing sent, and says why")
    func nothingSentIsNeverDone() async throws {
        let removing = "\(Self.blocks)/1"
        let (session, server, servers) = try await session(Self.seeded([removing: PageServer.Answer(body: "{}")]))
        await servers.opened(Self.page, in: session)
        await server.hold(removing)
        defer { Task { await server.release(removing) } }
        let held = watching("the taking off, held at its server") { await server.release(removing) }
        defer { held.cancel() }
        let writing = Task { await servers.remove(.blocks, id: "1", on: Self.page, in: session) }
        await server.arrival(of: removing, by: writing)
        let block = try #require(servers.said(of: Self.page, in: session).blocks?.items.first { $0.id == "1" })
        servers.open(.block(block), at: Self.host, in: session)
        servers.asking?.draft.severity = .limit
        await servers.send(on: Self.page, in: session)
        #expect(servers.asking?.stage == .failed(String(format: L10n.t("tend.servers.busy"), Self.host)))
        await server.release(removing)
        await writing.value
        servers.close()

        servers.open(.mail, at: Self.host, in: session)
        servers.asking?.domain = "junk.example"
        await server.answer(Self.who, Self.check(permissions: Self.federationOnly))
        await session.mastodon.learnWho(host: Self.host)
        await servers.send(on: Self.page, in: session)
        #expect(servers.asking == nil && servers.gone == String(format: L10n.t("tend.servers.gone"), Self.host))
        #expect(await server.arrivals(of: Self.mail) == 1, "only the first read: nothing sent")
    }

    // MARK: - Let go

    @Test("A list whose flag the role loses is let go on its own, while the lists it still answers for are kept")
    func eachListLetGoWithItsFlag() async throws {
        let (session, server, servers) = try await session(Self.seeded())
        await servers.opened(Self.page, in: session)
        await server.answer(Self.who, Self.check(permissions: Self.federationOnly))
        await session.mastodon.learnWho(host: Self.host)
        await servers.opened(Self.page, in: session)
        await server.answer(Self.who, Self.check(permissions: Self.admin))
        await session.mastodon.learnWho(host: Self.host)
        let said = servers.said(of: Self.page, in: session)
        #expect(said.mail?.items.isEmpty == true && said.addresses?.items.isEmpty == true, "let go with their flag")
        #expect(said.blocks?.items.count == 2 && said.allows?.items.count == 1, "kept with theirs")
    }

    @Test("What the lists said is let go when the page leaves, and when the role no longer answers for them: nothing of it is handed back after")
    func letGo() async throws {
        let (session, server, _) = try await session(Self.seeded())
        // The pages held here, as the root holds them: the session's hold is weak.
        let pages = ShellPersonPages()
        session.personPages = pages
        let servers = pages.tending.servers
        await servers.opened(Self.page, in: session)
        servers.open(.allow, at: Self.host, in: session)
        #expect(servers.asking != nil)
        pages.tending.letGo(at: Self.host)
        #expect(servers.said(of: Self.page, in: session).blocks?.items.isEmpty == true && servers.asking == nil)

        await servers.opened(Self.page, in: session)
        #expect(servers.said(of: Self.page, in: session).blocks?.items.count == 2)
        await server.answer(Self.who, Self.check(permissions: Self.moderator))
        await session.mastodon.learnWho(host: Self.host)
        await servers.opened(Self.page, in: session)
        await server.answer(Self.who, Self.check(permissions: Self.admin))
        await session.mastodon.learnWho(host: Self.host)
        #expect(servers.said(of: Self.page, in: session).blocks?.items.isEmpty == true, "let go with the role")
    }

    @Test("Every word of the tab and the sheet is in each language the app speaks")
    func wordsInEveryLanguage() {
        var keys = [
            "tend.tab.servers", "tend.servers.asking", "tend.servers.reading", "tend.servers.add", "tend.servers.change",
            "tend.servers.change.title", "tend.servers.rejectMedia", "tend.servers.rejectReports", "tend.servers.obfuscate",
            "tend.servers.public", "tend.servers.private", "tend.servers.until", "tend.servers.remove", "tend.servers.domain",
            "tend.servers.mailDomain", "tend.servers.ip", "tend.servers.publicWords", "tend.servers.privateWords",
            "tend.servers.addressWords", "tend.servers.tooLong", "tend.servers.send", "tend.servers.suspend", "tend.servers.suspend.ask",
            "tend.servers.notDomain", "tend.servers.notAddress", "tend.servers.gone", "tend.servers.busy", "tend.servers.address.ask",
            "tend.servers.refuse",
        ]
        for list in ServerList.allCases {
            let name = list.rawValue
            keys += [
                "tend.servers.none.\(name)", "tend.servers.list.\(name)", "tend.servers.add.\(name)", "tend.servers.add.title.\(name)",
                "tend.servers.remove.title.\(name)", "tend.servers.remove.line.\(name)",
            ]
        }
        for severity in ServerSeverity.allCases {
            keys += ["tend.servers.severity.\(severity)", "tend.servers.severity.line.\(severity)"]
        }
        keys += AddressSeverity.allCases.map { "tend.servers.address.\($0)" }
        for language in DummyLanguage.allCases {
            for key in keys { #expect(L10n.t(key, language: language) != key, "\(key) in \(language)") }
        }
    }
}
