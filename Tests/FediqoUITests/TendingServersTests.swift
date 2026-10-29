import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #383, #416, the page: the Federation and Blocks tabs of a host's page — the servers it refuses
/// or allows, and the mail domains and addresses it refuses, each tab its own flag's; each added,
/// changed or taken off by the rules #381's acts keep; what cuts the server off asks first; and
/// all of it let go with the page or the role.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`); every deadline is on a
/// clock nobody turns.
@MainActor
@Suite("A host's Federation and Blocks tabs: the servers and addresses it refuses", .serialized, .watched)
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
    private static let mailboxes = "/api/v1/admin/canonical_email_blocks"
    private static let hash = "775b10bf7772d11d49e38f382b2cab84ee93161169491aaf49bdaeb1a20b33e0"
    /// The seed's Admin: every flag but the administrator's.
    private static let admin = "2097148"
    private static let moderator = "1115420"
    private static let federationOnly = "32"
    private static let blocksOnly = "128"
    private static let federation = Tending(host: host, tab: .federation)
    private static let blocking = Tending(host: host, tab: .blocks)
    /// The tab a list stands on.
    private static func page(_ list: FediqoUI.ServerList) -> Tending { Tending(host: host, tab: list.tab) }

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

    private static func mailbox(_ id: String, _ hash: String = hash) -> String {
        #"{"id":"\#(id)","canonical_email_hash":"\#(hash)"}"#
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
            mailboxes: list([mailbox("1")], at: mailboxes),
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

    @Test("Each tab is its flag's and reads only its own lists: Federation the servers refused and allowed, Blocks the mail domains and the ranges; a role holding one flag has the one tab and never asks the other's lists; a role with neither has no trace of either, and asks nothing")
    func eachTabIsItsFlags() async throws {
        let (session, server, servers) = try await session(Self.seeded())
        #expect(ShellTending.tabs(at: Self.host, in: session) == AdminTab.allCases)
        await servers.opened(Self.federation, in: session)
        let fedOnly = servers.said(of: Self.federation, in: session)
        #expect(fedOnly.blocks?.items.count == 2 && fedOnly.allows?.items.count == 1 && fedOnly.mail == nil && fedOnly.addresses == nil)
        let mailBefore = await server.arrivals(of: Self.mail)
        let addressesBefore = await server.arrivals(of: Self.addresses)
        #expect(mailBefore == 0 && addressesBefore == 0, "Federation asks nothing of Blocks' lists")
        await servers.opened(Self.blocking, in: session)
        let blocksOnly = servers.said(of: Self.blocking, in: session)
        #expect(blocksOnly.blocks == nil && blocksOnly.allows == nil && blocksOnly.mail?.items.count == 1 && blocksOnly.addresses?.items.count == 1)
        #expect(await server.arrivals(of: Self.blocks) == 1, "Blocks asks nothing of Federation's")

        let (federation, fedServer, fed) = try await self.session(Self.seeded(), permissions: Self.federationOnly)
        #expect(ShellTending.tabs(at: Self.host, in: federation) == [.federation])
        await fed.opened(Self.federation, in: federation)
        await fed.opened(Self.blocking, in: federation)
        let askedMail = await fedServer.arrivals(of: Self.mail)
        let askedAddresses = await fedServer.arrivals(of: Self.addresses)
        let askedMailboxes = await fedServer.arrivals(of: Self.mailboxes)
        #expect(askedMail == 0 && askedAddresses == 0 && askedMailboxes == 0, "nothing asked of a tab the role does not answer for")
        #expect(fed.said(of: Self.blocking, in: federation).mail == nil && fed.said(of: Self.blocking, in: federation).mailboxes == nil)
        fed.open(.mailbox, at: Self.host, in: federation)
        #expect(fed.asking == nil, "no trace of the mailboxes without the flag for blocks")
        fed.open(.mail, at: Self.host, in: federation)
        #expect(fed.asking == nil)

        let (blocking, blkServer, blk) = try await self.session(Self.seeded(), permissions: Self.blocksOnly)
        #expect(ShellTending.tabs(at: Self.host, in: blocking) == [.blocks])
        await blk.opened(Self.federation, in: blocking)
        await blk.opened(Self.blocking, in: blocking)
        let askedBlocks = await blkServer.arrivals(of: Self.blocks)
        let askedAllows = await blkServer.arrivals(of: Self.allows)
        #expect(askedBlocks == 0 && askedAllows == 0, "nothing asked of a tab the role does not answer for")
        let blkSaid = blk.said(of: Self.blocking, in: blocking)
        #expect(blkSaid.blocks == nil && blkSaid.allows == nil && blkSaid.mail != nil && blkSaid.addresses != nil)
        #expect(blkSaid.mailboxes?.items.map(\.id) == ["1"])

        let (moderated, modServer, mod) = try await self.session(Self.seeded(), permissions: Self.moderator)
        let modTabs = ShellTending.tabs(at: Self.host, in: moderated)
        #expect(!modTabs.contains(.federation) && !modTabs.contains(.blocks) && !ShellTending.drawn(Self.federation, in: moderated))
        await mod.opened(Self.federation, in: moderated)
        let modSaid = mod.said(of: Self.federation, in: moderated)
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
        await servers.opened(Self.federation, in: session)
        await servers.opened(Self.blocking, in: session)
        var said = servers.said(of: Self.federation, in: session, language: .english)
        let refusing = servers.said(of: Self.blocking, in: session, language: .english)
        let limited = try #require(said.blocks?.items.first)
        #expect(TendingServersSaid.lines(of: limited, language: .english) == [
            "Limited · Its pictures and films refused", "Said to all: Too loud", "Kept among staff: kept",
        ])
        #expect(TendingServersSaid.lines(of: try #require(refusing.addresses?.items.first), language: .english) == ["No sign-ups", "range"])
        #expect(refusing.mail?.quiet == "It refuses no mail domain." && refusing.mail?.items.isEmpty == true)
        #expect(said.allows?.more == true && said.blocks?.more == false)
        await servers.readOn(.allows, of: Self.federation, in: session)
        said = servers.said(of: Self.federation, in: session)
        #expect(said.allows?.items.map(\.domain) == ["b.example", "a.example"] && said.allows?.more == false)
        #expect(await server.arrivals(of: "\(Self.allows)?max_id=2") == 1)
        #expect(servers.walked(Self.federation, in: session).first == TendingServersSaid.rowID(.blocks, "2"))
        #expect(servers.walked(Self.federation, in: session).count == 4)
        #expect(servers.walked(Self.blocking, in: session) == [TendingServersSaid.rowID(.mailboxes, "1"), TendingServersSaid.rowID(.addresses, "1")])

        let (refused, _, others) = try await self.session([
            Self.blocks: PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
            Self.allows: PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
            Self.mail: PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
            Self.addresses: PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403),
        ])
        await others.opened(Self.federation, in: refused)
        #expect(others.said(of: Self.federation, in: refused, language: .english).blocks?.quiet == "m.example did not allow this for your standing there.")
    }

    // MARK: - Writes

    @Test("Suspending a server asks first, in one line, and sends nothing before its yes; sent, the row is the server's answer, at the top, and the sheet closes; limiting one asks nothing")
    func suspendingAsksFirst() async throws {
        let (session, server, servers) = try await session(Self.seeded())
        await servers.opened(Self.federation, in: session)
        servers.open(.block(nil), at: Self.host, in: session)
        servers.asking?.draft.domain = "new.example"
        servers.asking?.draft.severity = .suspend
        #expect(servers.asking?.cutsOff == true)
        await servers.send(on: Self.federation, in: session, confirmed: true)
        #expect(servers.asking?.stage == .asking, "a yes not from the question puts the question")
        #expect(await server.sent.isEmpty)
        let ask = try #require(servers.asking)
        #expect(FederationAskSheet.cutsOffLine(ask, language: .english) == "Suspending new.example cuts m.example off from it: nothing goes to it or comes from it.")
        await server.answer(Self.blocks, PageServer.Answer(body: Self.block("3", "new.example")))
        await servers.send(on: Self.federation, in: session, confirmed: true)
        #expect(servers.asking == nil)
        let sent = try #require(await server.sent.first)
        #expect(sent.method == "POST" && sent.body.contains("domain=new.example") && sent.body.contains("severity=suspend"))
        #expect(servers.said(of: Self.federation, in: session).blocks?.items.first?.id == "3")

        // Changed to limited: nothing cut off, so nothing asked.
        let held = try #require(servers.said(of: Self.federation, in: session).blocks?.items.first)
        servers.open(.block(held), at: Self.host, in: session)
        servers.asking?.draft.severity = .limit
        #expect(servers.asking?.cutsOff == false)
        await server.answer("\(Self.blocks)/3", PageServer.Answer(body: Self.block("3", "new.example", "silence")))
        await servers.send(on: Self.federation, in: session)
        let method = await server.sent.last?.method
        #expect(servers.asking == nil && method == "PUT")
        #expect(servers.said(of: Self.federation, in: session).blocks?.items.first?.severity == .limit)
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
        await servers.opened(Self.federation, in: session)
        await servers.opened(Self.blocking, in: session)
        let question = TendingServersSaid.removeQuestion(.allows, name: "allowed.example", host: Self.host, language: .english)
        #expect(question.line == "This cuts m.example off from allowed.example: nothing goes to it or comes from it.")
        #expect(question.choices.map(\.role) == [.destructive])
        let said = servers.said(of: Self.federation, in: session, language: .english)
        let more = TendingServersSaid.more(.allows, id: "1", name: "allowed.example", said: said, actions: TendingServersActs(), language: .english)
        #expect(more.items.map(\.isDanger) == [true] && more.items.first?.question?.line == question.line)
        let blockMore = TendingServersSaid.more(try #require(said.blocks?.items.first), said: said, actions: TendingServersActs(), language: .english)
        #expect(blockMore.items.map(\.name) == ["Change…", "Take off"])

        await servers.remove(.allows, id: "1", on: Self.federation, in: session)
        #expect(servers.said(of: Self.federation, in: session).allows?.items.isEmpty == true)
        await servers.remove(.addresses, id: "1", on: Self.blocking, in: session)
        #expect(servers.said(of: Self.blocking, in: session).addresses?.items.isEmpty == true)

        await server.answer(Self.mail, PageServer.Answer(body: Self.named("2", "junk.example")))
        servers.open(.mail, at: Self.host, in: session)
        servers.asking?.domain = "junk.example"
        // As the sheet sends it: on the page of the tab its list stands on.
        await servers.send(on: Self.page(.mail), in: session)
        #expect(servers.asking == nil && servers.said(of: Self.blocking, in: session).mail?.items.map(\.domain) == ["junk.example", "spam.example"])

        await server.answer(Self.addresses, PageServer.Answer(body: #"{"error":"Validation failed: Ip can't be blank"}"#, status: 422))
        servers.open(.address, at: Self.host, in: session)
        servers.asking?.ip = "10.0.0.1"
        await servers.send(on: Self.blocking, in: session)
        #expect(servers.asking?.stage == .failed(String(format: L10n.t("tend.act.refused"), Self.host, "Validation failed: Ip can't be blank")))
        #expect(servers.said(of: Self.blocking, in: session).addresses?.items.isEmpty == true, "nothing changed here")
        servers.close()
        #expect(servers.asking == nil)

        await server.answer("\(Self.blocks)/1", PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403))
        await servers.remove(.blocks, id: "1", on: Self.federation, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.act.notAllowed"), Self.host))
        #expect(servers.said(of: Self.federation, in: session).blocks?.items.count == 2)
    }

    @Test("A server taken off while a read of its list is on its way stays gone when the read lands; one added stays")
    func writesKeepTheirRows() async throws {
        let removing = "\(Self.allows)/1"
        let (session, server, servers) = try await session(Self.seeded([removing: PageServer.Answer(body: "{}")]))
        await servers.opened(Self.federation, in: session)
        await servers.opened(Self.blocking, in: session)
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
        let writing = Task { await servers.remove(.allows, id: "1", on: Self.federation, in: session) }
        await server.arrival(of: removing, by: writing)
        let reading = Task { await servers.again(Self.federation, in: session) }
        await server.arrival(of: Self.allows, times: 2, by: reading)
        await server.release(removing)
        await writing.value
        await server.release(Self.allows)
        await reading.value
        #expect(servers.said(of: Self.federation, in: session).allows?.items.isEmpty == true, "the one taken off came back")
    }

    @Test("Without the word that changes, every list is read but nothing is offered: tending's lock stands in each act's place, and no sheet opens")
    func theLock() async throws {
        let (session, _, servers) = try await session(Self.seeded(), holding: "\(Self.reads) admin:read")
        await servers.opened(Self.federation, in: session)
        let said = servers.said(of: Self.federation, in: session, language: .english)
        #expect(!said.acts && said.lock != nil && said.blocks?.items.count == 2)
        servers.open(.block(nil), at: Self.host, in: session)
        #expect(servers.asking == nil)
        let more = TendingServersSaid.more(.allows, id: "1", name: "allowed.example", said: said, actions: TendingServersActs(), language: .english)
        #expect(more.items.allSatisfy { !$0.isDanger })
    }

    @Test("An address refused all access, or a range wider than a /8, asks first in one red line; one that names nothing — the whole of a family among them — says why Send is dim; a name pasted is trimmed and sent in its ASCII spelling")
    func addressesAndNamesAsWritten() async throws {
        let (session, server, servers) = try await session(Self.seeded())
        await servers.opened(Self.federation, in: session)
        servers.open(.address, at: Self.host, in: session)
        servers.asking?.ip = "198.51.100.0/24"
        #expect(servers.asking?.cutsOff == false && servers.asking?.whyNot == nil)
        servers.asking?.ip = "10.0.0.0/7"
        #expect(servers.asking?.cutsOff == true, "a range wider than a /8")
        servers.asking?.ip = "198.51.100.0/24"
        servers.asking?.addressSeverity = .noAccess
        #expect(servers.asking?.cutsOff == true)
        await servers.send(on: Self.federation, in: session)
        let nothingSent = await server.sent.isEmpty
        #expect(servers.asking?.stage == .asking && nothingSent)
        let ask = try #require(servers.asking)
        #expect(FederationAskSheet.cutsOffLine(ask, language: .english) == "Refusing 198.51.100.0/24 shuts it out of m.example: whole networks may no longer reach it.")
        #expect(FederationAskSheet.cutsOffYes(ask, language: .english) == "Refuse")
        servers.asking?.ip = "::ffff:0.0.0.0/96"
        servers.asking?.addressSeverity = .signUp
        #expect(servers.asking?.cutsOff == true, "IPv4 carried in IPv6, as wide as all of IPv4")
        for wrong in ["0.0.0.0/0", "::/0", "1.2.3.4/99", "::::"] {
            servers.asking?.ip = wrong
            #expect(servers.asking?.sendable == false && servers.asking?.whyNot == L10n.t("tend.servers.notAddress"), "\(wrong)")
        }
        servers.close()

        await server.answer(Self.allows, PageServer.Answer(body: Self.named("2", "xn--bcher-kva.example")))
        servers.open(.allow, at: Self.host, in: session)
        servers.asking?.domain = "not a name"
        #expect(servers.asking?.whyNot == L10n.t("tend.servers.notDomain") && servers.asking?.sendable == false)
        servers.asking?.domain = "allowed.example"
        #expect(servers.asking?.sentAs == nil, "sent as written: nothing more said")
        servers.asking?.domain = "  Bücher.Example \n"
        #expect(servers.asking?.sendable == true && servers.asking?.whyNot == nil)
        #expect(servers.asking?.sentAs == "xn--bcher-kva.example")
        await servers.send(on: Self.federation, in: session)
        let body = await server.sent.last?.body
        #expect(servers.asking == nil && body == "domain=xn--bcher-kva.example")

        // A look-alike — its first letter Cyrillic — is suspended only once the question has
        // said what is truly sent.
        servers.open(.block(nil), at: Self.host, in: session)
        servers.asking?.draft.domain = "\u{0430}pple.com"
        servers.asking?.draft.severity = .suspend
        let wire = try #require(servers.asking?.sentAs)
        #expect(wire.hasPrefix("xn--") && wire.hasSuffix(".com"))
        let lookAlike = try #require(servers.asking)
        #expect(FederationAskSheet.cutsOffLine(lookAlike, language: .english).hasSuffix("Sent as \(wire)."))
    }

    @Test("A send that cannot go says why and leaves the sheet up — a change already on its way to the row — and a sheet the role no longer allows closes with nothing sent, and says why")
    func nothingSentIsNeverDone() async throws {
        let removing = "\(Self.blocks)/1"
        let (session, server, servers) = try await session(Self.seeded([removing: PageServer.Answer(body: "{}")]))
        await servers.opened(Self.federation, in: session)
        await servers.opened(Self.blocking, in: session)
        await server.hold(removing)
        defer { Task { await server.release(removing) } }
        let held = watching("the taking off, held at its server") { await server.release(removing) }
        defer { held.cancel() }
        let writing = Task { await servers.remove(.blocks, id: "1", on: Self.federation, in: session) }
        await server.arrival(of: removing, by: writing)
        let block = try #require(servers.said(of: Self.federation, in: session).blocks?.items.first { $0.id == "1" })
        servers.open(.block(block), at: Self.host, in: session)
        servers.asking?.draft.severity = .limit
        await servers.send(on: Self.federation, in: session)
        #expect(servers.asking?.stage == .failed(String(format: L10n.t("tend.servers.busy"), Self.host)))
        await server.release(removing)
        await writing.value
        servers.close()

        servers.open(.mail, at: Self.host, in: session)
        servers.asking?.domain = "junk.example"
        await server.answer(Self.who, Self.check(permissions: Self.federationOnly))
        await session.mastodon.learnWho(host: Self.host)
        await servers.send(on: Self.federation, in: session)
        #expect(servers.asking == nil && servers.gone == String(format: L10n.t("tend.servers.gone"), Self.host))
        #expect(await server.arrivals(of: Self.mail) == 1, "only the first read: nothing sent")
    }

    // MARK: - Mailboxes, however written (#417)

    @Test("A mailbox refused however written reads as a refused address and the first letters of its fingerprint, on screen and to a listener; the list reads on by its own press; taking one off asks first, in its own `…`, and the row goes as the server answers")
    func mailboxesRead() async throws {
        let (session, server, servers) = try await session(Self.seeded([
            Self.mailboxes: Self.list([Self.mailbox("2", String(repeating: "ab", count: 32))], at: Self.mailboxes, next: "2"),
            "\(Self.mailboxes)?max_id=2": Self.list([Self.mailbox("1")], at: Self.mailboxes),
            "\(Self.mailboxes)/1": PageServer.Answer(body: "{}"),
        ]))
        await servers.opened(Self.blocking, in: session)
        var said = servers.said(of: Self.blocking, in: session, language: .english)
        let first = try #require(said.mailboxes?.items.first)
        #expect(TendingServersSaid.lines(of: first, language: .english) == ["Fingerprint abababababab"])
        #expect(L10n.t("tend.servers.mailbox.row", language: .english) == "A refused address")
        #expect(said.mailboxes?.more == true)
        await servers.readOn(.mailboxes, of: Self.blocking, in: session)
        said = servers.said(of: Self.blocking, in: session, language: .english)
        #expect(said.mailboxes?.items.map(\.id) == ["2", "1"] && said.mailboxes?.more == false)
        #expect(await server.arrivals(of: "\(Self.mailboxes)?max_id=2") == 1)

        let held = try #require(said.mailboxes?.items.last)
        let short = TendingServersSaid.shortHash(held)
        #expect(short == "775b10bf7772")
        let more = TendingServersSaid.more(.mailboxes, id: held.id, name: short, said: said, actions: TendingServersActs(), language: .english)
        #expect(more.items.map(\.isDanger) == [true])
        #expect(more.items.first?.question?.line == "The address whose fingerprint begins 775b10bf7772 can ask to join m.example again, however it is written.")
        await servers.remove(.mailboxes, id: "1", on: Self.blocking, in: session)
        #expect(servers.said(of: Self.blocking, in: session).mailboxes?.items.map(\.id) == ["2"])
        #expect(await server.arrivals(of: "\(Self.mailboxes)/1") == 1)
    }

    @Test("Trying an address says whether the server would refuse it — for the address as written, said again once it is written otherwise — and adds nothing; adding it puts the server's row at the top; one that is no address says why and is asked nothing")
    func mailboxesTriedAndAdded() async throws {
        let tried = "\(Self.mailboxes)/test"
        let (session, server, servers) = try await session(Self.seeded([
            tried: PageServer.Answer(body: "[" + Self.mailbox("1") + "]"),
        ]))
        await servers.opened(Self.blocking, in: session)
        servers.open(.mailbox, at: Self.host, in: session)
        servers.asking?.mailbox = "not an address"
        #expect(servers.asking?.sendable == false && servers.asking?.whyNot == L10n.t("tend.servers.notMailbox"))
        await servers.tryMailbox(on: Self.blocking, in: session)
        #expect(await server.arrivals(of: tried) == 0, "no address is asked nothing")

        servers.asking?.mailbox = " Ada.Lovelace+join@Example.COM "
        let ask = try #require(servers.asking)
        await servers.tryMailbox(on: ask.page, in: session)
        #expect(servers.asking?.triedNow == true)
        #expect(TendingServersSaid.triedLine(try #require(servers.asking), language: .english) == "m.example would refuse Ada.Lovelace+join@Example.COM.")
        #expect(await server.sent.last?.body == "email=Ada.Lovelace%2Bjoin%40example.com")
        #expect(servers.said(of: Self.blocking, in: session).mailboxes?.items.map(\.id) == ["1"], "trying added nothing")
        #expect(await server.sent.filter { $0.ask == Self.mailboxes }.isEmpty)

        servers.asking?.mailbox = "grace@example.com"
        #expect(servers.asking?.triedNow == nil, "written otherwise, the try says nothing of it")
        await server.answer(tried, PageServer.Answer(body: "[]"))
        await servers.tryMailbox(on: Self.blocking, in: session)
        #expect(servers.asking?.triedNow == false)
        #expect(TendingServersSaid.triedLine(try #require(servers.asking), language: .english) == "m.example would let grace@example.com ask to join.")

        await server.answer(Self.mailboxes, PageServer.Answer(body: Self.mailbox("5", String(repeating: "cd", count: 32))))
        await servers.send(on: Self.blocking, in: session)
        #expect(servers.asking == nil)
        #expect(servers.said(of: Self.blocking, in: session).mailboxes?.items.map(\.id) == ["5", "1"])
        let added = try #require(await server.sent.last)
        #expect(added.method == "POST" && added.ask == Self.mailboxes && added.body == "email=grace%40example.com")
    }

    @Test("A mailbox the server refuses to add, a try it fails, or one the standing does not allow says so on the sheet and changes nothing here; without the word that changes, nothing is offered")
    func mailboxesRefused() async throws {
        let tried = "\(Self.mailboxes)/test"
        let (session, server, servers) = try await session(Self.seeded([tried: PageServer.Answer(body: "", status: 503)]))
        await servers.opened(Self.blocking, in: session)
        await server.answer(Self.mailboxes, PageServer.Answer(body: #"{"error":"Validation failed: Canonical email hash has already been taken"}"#, status: 422))
        servers.open(.mailbox, at: Self.host, in: session)
        servers.asking?.mailbox = "ada@example.com"
        await servers.tryMailbox(on: Self.blocking, in: session)
        #expect(servers.asking?.stage == .failed(String(format: L10n.t("tend.act.failed"), Self.host)) && servers.asking?.triedNow == nil)
        await servers.send(on: Self.blocking, in: session)
        #expect(servers.asking?.stage == .failed(String(format: L10n.t("tend.act.refused"), Self.host, "Validation failed: Canonical email hash has already been taken")))
        #expect(servers.said(of: Self.blocking, in: session).mailboxes?.items.map(\.id) == ["1"], "nothing changed here")
        servers.close()

        await server.answer("\(Self.mailboxes)/1", PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403))
        await servers.remove(.mailboxes, id: "1", on: Self.blocking, in: session)
        #expect(session.toast?.text == String(format: L10n.t("tend.act.notAllowed"), Self.host))
        #expect(servers.said(of: Self.blocking, in: session).mailboxes?.items.map(\.id) == ["1"])

        let (reading, _, readOnly) = try await self.session(Self.seeded(), holding: "\(Self.reads) admin:read")
        await readOnly.opened(Self.blocking, in: reading)
        #expect(readOnly.said(of: Self.blocking, in: reading).mailboxes?.items.count == 1)
        readOnly.open(.mailbox, at: Self.host, in: reading)
        #expect(readOnly.asking == nil)
    }

    @Test("A sheet's write lands on the state of the tab its list stands on, as the sheet sends it, and leaves the other tab's as it was")
    func aSheetWritesOnItsOwnTab() async throws {
        let (session, server, servers) = try await session(Self.seeded())
        await servers.opened(Self.federation, in: session)
        await servers.opened(Self.blocking, in: session)
        let federationBefore = servers.said(of: Self.federation, in: session)
        await server.answer(Self.mail, PageServer.Answer(body: Self.named("2", "junk.example")))
        servers.open(.mail, at: Self.host, in: session)
        servers.asking?.domain = "junk.example"
        let ask = try #require(servers.asking)
        #expect(ask.page == Self.blocking)
        await servers.send(on: ask.page, in: session)
        #expect(servers.asking == nil)
        #expect(servers.said(of: Self.blocking, in: session).mail?.items.map(\.domain) == ["junk.example", "spam.example"])
        #expect(servers.said(of: Self.federation, in: session) == federationBefore, "the other tab's state is untouched")

        await server.answer(Self.allows, PageServer.Answer(body: Self.named("2", "friend.example")))
        servers.open(.allow, at: Self.host, in: session)
        servers.asking?.domain = "friend.example"
        let allow = try #require(servers.asking)
        #expect(allow.page == Self.federation)
        let blockingBefore = servers.said(of: Self.blocking, in: session)
        await servers.send(on: allow.page, in: session)
        #expect(servers.said(of: Self.federation, in: session).allows?.items.map(\.domain) == ["friend.example", "allowed.example"])
        #expect(servers.said(of: Self.blocking, in: session) == blockingBefore)
    }

    // MARK: - Let go

    @Test("A tab whose flag the role loses is let go on its own, while the tab it still answers for is kept")
    func eachListLetGoWithItsFlag() async throws {
        let (session, server, servers) = try await session(Self.seeded())
        await servers.opened(Self.federation, in: session)
        await servers.opened(Self.blocking, in: session)
        await server.answer(Self.who, Self.check(permissions: Self.federationOnly))
        await session.mastodon.learnWho(host: Self.host)
        await servers.opened(Self.federation, in: session)
        await server.answer(Self.who, Self.check(permissions: Self.admin))
        await session.mastodon.learnWho(host: Self.host)
        let refused = servers.said(of: Self.blocking, in: session)
        #expect(refused.mail?.items.isEmpty == true && refused.addresses?.items.isEmpty == true, "let go with their flag")
        let said = servers.said(of: Self.federation, in: session)
        #expect(said.blocks?.items.count == 2 && said.allows?.items.count == 1, "kept with theirs")
    }

    @Test("What the lists said is let go when the page leaves, and when the role no longer answers for them: nothing of it is handed back after")
    func letGo() async throws {
        let (session, server, _) = try await session(Self.seeded())
        // The pages held here, as the root holds them: the session's hold is weak.
        let pages = ShellPersonPages()
        session.personPages = pages
        let servers = pages.tending.servers
        await servers.opened(Self.federation, in: session)
        servers.open(.allow, at: Self.host, in: session)
        #expect(servers.asking != nil)
        pages.tending.letGo(at: Self.host)
        #expect(servers.said(of: Self.federation, in: session).blocks?.items.isEmpty == true && servers.asking == nil)

        await servers.opened(Self.federation, in: session)
        #expect(servers.said(of: Self.federation, in: session).blocks?.items.count == 2)
        await server.answer(Self.who, Self.check(permissions: Self.moderator))
        await session.mastodon.learnWho(host: Self.host)
        await servers.opened(Self.federation, in: session)
        await server.answer(Self.who, Self.check(permissions: Self.admin))
        await session.mastodon.learnWho(host: Self.host)
        #expect(servers.said(of: Self.federation, in: session).blocks?.items.isEmpty == true, "let go with the role")
    }

    @Test("Every word of the two tabs and the sheet is in each language the app speaks")
    func wordsInEveryLanguage() {
        var keys = [
            "tend.tab.federation", "tend.tab.blocks", "tend.servers.asking", "tend.servers.reading", "tend.servers.add", "tend.servers.change",
            "tend.servers.change.title", "tend.servers.rejectMedia", "tend.servers.rejectReports", "tend.servers.obfuscate",
            "tend.servers.public", "tend.servers.private", "tend.servers.until", "tend.servers.remove", "tend.servers.domain",
            "tend.servers.mailDomain", "tend.servers.ip", "tend.servers.publicWords", "tend.servers.privateWords",
            "tend.servers.addressWords", "tend.servers.tooLong", "tend.servers.send", "tend.servers.suspend", "tend.servers.suspend.ask",
            "tend.servers.notDomain", "tend.servers.notAddress", "tend.servers.gone", "tend.servers.busy", "tend.servers.address.ask",
            "tend.servers.refuse", "tend.servers.sentAs", "tend.servers.mailbox", "tend.servers.mailbox.line",
            "tend.servers.mailbox.row", "tend.servers.mailbox.hash", "tend.servers.mailbox.try", "tend.servers.mailbox.trying",
            "tend.servers.mailbox.refused", "tend.servers.mailbox.free", "tend.servers.notMailbox",
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
