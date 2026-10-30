import Foundation
import Testing
@testable import FediqoCore

/// #383, in the half of it Core holds: the servers a server refuses or allows and the addresses it
/// refuses, read and changed — from what a real 4.6.6 answered (`MastodonAdminFederationCaptures`).
@Suite("Tending a server: the servers and addresses it refuses")
struct MastodonAdminFederationTests {
    private typealias Captures = MastodonAdminFederationCaptures

    private static let token = MastodonToken(host: Captures.host, accessToken: "tok-383", clientID: "cid", clientSecret: "secret")

    private func reader(_ routes: [String: PeopleServer.Answer]) throws -> (MastodonAdminFederation, PeopleServer) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonAdminFederation(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    @Test("The four lists a real server keeps are read, newest first: each server refused with how hard, what besides and why; each allowed; each mail domain; each range with how hard and why")
    func theLists() async throws {
        let (reader, _) = try reader([
            MastodonAdminFederation.blocksPath: .json(Captures.blocks, link: Captures.blocksLink),
            MastodonAdminFederation.allowsPath: .json(Captures.allows, link: Captures.allowsLink),
            MastodonAdminFederation.mailPath: .json(Captures.mail, link: Captures.mailLink),
            MastodonAdminFederation.addressesPath: .json(Captures.ips, link: Captures.ipsLink),
        ])
        let blocks = try await reader.blocks()
        #expect(blocks.items.map(\.domain) == ["limited.example", "suspended.example"] && blocks.next == nil)
        let limited = blocks.items[0], suspended = blocks.items[1]
        #expect(limited.severity == .limit && limited.rejectMedia && limited.publicWords == "Too loud")
        #expect(suspended.severity == .suspend && suspended.privateWords == "fediqo383seed spam" && suspended.publicWords == "Spam")
        #expect(try await reader.allows().items.map(\.domain) == ["allowed.example"])
        #expect(try await reader.mailDomains().items.map(\.domain) == ["spam.example"])
        let address = try #require(try await reader.addresses().items.first)
        #expect(address.ip == "192.0.2.0/24" && address.severity == .signUp && address.words == "fediqo383seed range" && address.until == nil)
    }

    @Test("Each is added, changed or taken off at the server's own address with its own words, each answered with what the server now holds — or with nothing, for one taken off")
    func theWrites() async throws {
        let blocks = MastodonAdminFederation.blocksPath, allows = MastodonAdminFederation.allowsPath
        let mail = MastodonAdminFederation.mailPath, addresses = MastodonAdminFederation.addressesPath
        let (reader, server) = try reader([
            blocks: .json(Captures.blockAdded), "\(blocks)/3": .json(Captures.blockChanged),
            allows: .json(Captures.allowAdded), "\(allows)/2": .json(Captures.allowRemoved),
            mail: .json(Captures.mailAdded), "\(mail)/2": .json(Captures.mailRemoved),
            addresses: .json(Captures.ipAdded), "\(addresses)/2": .json(Captures.ipRemoved),
        ])
        let added = try await reader.addBlock(ServerBlockDraft(domain: "fediqo383.example", severity: .suspend, publicWords: "Spam"))
        #expect(added.id == "3" && added.severity == .suspend)
        let sent = try #require(await server.sent.first)
        #expect(sent.method == "POST" && sent.body.contains("domain=fediqo383.example") && sent.body.contains("severity=suspend"))
        var changed = added.draft
        changed.severity = .limit
        changed.rejectMedia = true
        let after = try await reader.changeBlock("3", to: changed)
        #expect(after.severity == .limit && after.rejectMedia)
        #expect(await server.sent.last?.method == "PUT")
        #expect(try await reader.addAllow("fediqo383.example").id == "2")
        try await reader.removeAllow("2")
        #expect(await server.asked.last == "\(allows)/2")
        #expect(try await reader.addMailDomain("fediqo383.example").id == "2")
        try await reader.removeMailDomain("2")
        let range = try await reader.addAddress("198.51.100.0/24", severity: .approval, words: "fediqo383 check")
        #expect(range.severity == .approval && range.words == "fediqo383 check")
        try await reader.removeAddress("2")
    }

    @Test("What the server refuses is said in its words; without the standing every read is not allowed; a name or an address that is none, or an id that cannot stand in a path, is asked nothing")
    func refusals() async throws {
        let (reader, server) = try reader([
            MastodonAdminFederation.blocksPath: .json(Captures.blockTwice, status: 422),
            MastodonAdminFederation.allowsPath: .json(Captures.modBlocks, status: 403),
            MastodonAdminFederation.addressesPath: .json(Captures.ipBad, status: 422),
        ])
        await #expect(throws: MastodonAdminError.refused(sentence: "You have already imposed stricter limits on suspended.example.")) {
            _ = try await reader.addBlock(ServerBlockDraft(domain: "suspended.example", severity: .suspend))
        }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await reader.allows() }
        await #expect(throws: MastodonAdminError.refused(sentence: "Validation failed: Ip can't be blank")) {
            _ = try await reader.addAddress("10.0.0.1", severity: .noAccess, words: "")
        }
        let before = await server.asked.count
        for domain in ["", "nodot", "a..b", "-x.example", "x y.example", "ex/ample.com", String(repeating: "a", count: 64) + ".example"] {
            #expect(!MastodonAdminFederation.isDomain(domain), "\(domain)")
            await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.addAllow(domain) }
        }
        #expect(MastodonAdminFederation.isDomain("xn--bcher-kva.example") && MastodonAdminFederation.isAddress("2001:db8::/32"))
        for ip in ["", "not an address", "1.2.3.4?x", String(repeating: "1", count: 70)] {
            await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.addAddress(ip, severity: .signUp, words: "") }
        }
        await #expect(throws: MastodonAdminError.invalid) { try await reader.removeBlock("../1") }
        await #expect(throws: MastodonAdminError.invalid) {
            _ = try await reader.addBlock(ServerBlockDraft(domain: "x.example", publicWords: String(repeating: "w", count: 1_001)))
        }
        #expect(await server.asked.count == before)
    }

    @Test("An address is read as its family reads it, with a prefix of whole digits no wider than its family's and never the whole of it; a range wider than a /8 or a /16 is wide; what is pasted is trimmed")
    func addresses() async throws {
        for ip in [
            "0.0.0.0/0", "::/0", "1.2.3.4/0", "1.2.3.4/99", "2001:db8::/129", "::::", "1.2.3/24", "1.2.3.4/", "1.2.3.4/+8",
            "1.2.3.4/8/8", "1.2.3.4/ 8", "256.1.1.1", "1.2.3.4.5", "1.2.3.4/0x8", "fe80::1%en0", ":::1",
        ] {
            #expect(MastodonAdminFederation.range(ip) == nil, "\(ip)")
        }
        let one = try #require(MastodonAdminFederation.range(" 192.0.2.0/24\n"))
        #expect(one.wire == "192.0.2.0/24" && !one.isV6 && one.prefix == 24 && !one.isWide)
        #expect(MastodonAdminFederation.range("10.0.0.1")?.prefix == 32)
        #expect(MastodonAdminFederation.range("2001:db8::")?.prefix == 128)
        #expect(MastodonAdminFederation.range("10.0.0.0/7")?.isWide == true && MastodonAdminFederation.range("10.0.0.0/8")?.isWide == false)
        #expect(MastodonAdminFederation.range("2001::/15")?.isWide == true && MastodonAdminFederation.range("2001:db8::/16")?.isWide == false)
        // IPv4 carried in IPv6 is judged as IPv4: the 96 bits before it name nothing.
        for wide in ["::ffff:0.0.0.0/96", "::ffff:10.0.0.0/103", "::ffff:0:0/96", "::0.0.0.0/96", "::ffff:10.0.0.0/64"] {
            #expect(MastodonAdminFederation.range(wide)?.isWide == true, "\(wide)")
        }
        #expect(MastodonAdminFederation.range("::ffff:10.0.0.0/104")?.isWide == false)
        #expect(MastodonAdminFederation.range("::ffff:192.0.2.1")?.carriesV4 == true)
        #expect(MastodonAdminFederation.range("2001:db8::1")?.carriesV4 == false)

        let (reader, server) = try reader([MastodonAdminFederation.addressesPath: .json(Captures.ipAdded)])
        _ = try await reader.addAddress("  198.51.100.0/24 ", severity: .approval, words: "")
        let sent = try #require(await server.sent.first)
        #expect(sent.body.contains("ip=198.51.100.0%2F24&") || sent.body.contains("ip=198.51.100.0/24&"))
    }

    @Test("A server's name pasted with spaces, in capitals or in letters beyond ASCII is sent in its wire form; one that is none is asked nothing")
    func names() async throws {
        #expect(MastodonAdminFederation.wireDomain("  Bücher.Example \n") == "xn--bcher-kva.example")
        #expect(MastodonAdminFederation.wireDomain("例え.テスト") == "xn--r8jz45g.xn--zckzah")
        #expect(MastodonAdminFederation.wireDomain("a b.example") == nil && MastodonAdminFederation.wireDomain("   ") == nil)
        let (reader, server) = try reader([MastodonAdminFederation.allowsPath: .json(Captures.allowAdded)])
        _ = try await reader.addAllow(" Fediqo383.Example ")
        #expect(await server.sent.first?.body == "domain=fediqo383.example")
    }

    @Test("What the server holds of a block is kept as it holds it, lines and all, and a block changed sends it back so")
    func wordsKeptWhole() async throws {
        let held = #"""
        {"id":"3","domain":"x.example","severity":"silence","reject_media":false,"reject_reports":false,"private_comment":"first\nsecond","public_comment":"one\r\ntwo","obfuscate":false}
        """#
        let path = MastodonAdminFederation.blocksPath
        let (reader, server) = try reader([path: .json("[\(held)]"), "\(path)/3": .json(held)])
        let block = try #require(try await reader.blocks().items.first)
        #expect(block.privateWords == "first\nsecond" && block.publicWords == "one\r\ntwo")
        _ = try await reader.changeBlock("3", to: block.draft)
        let body = try #require(await server.sent.last?.body)
        #expect(body.contains("private_comment=first%0Asecond") && body.contains("public_comment=one%0D%0Atwo"))
    }

    @Test("The mailboxes refused however written are read a stretch at a time, newest first, each only the server's fingerprint of it, and read on from where the server says the next begins")
    func mailboxes() async throws {
        let path = MastodonAdminFederation.mailboxesPath
        let (reader, server) = try reader([
            path: .json(Captures.mailboxes, link: Captures.mailboxesLink),
            "\(path)?max_id=2": .json(Captures.mailboxesRest, link: Captures.mailboxesRestLink),
        ])
        let all = try await reader.mailboxes()
        #expect(all.items.map(\.id) == ["2", "1"] && all.next == nil)
        #expect(all.items[1].hash == "775b10bf7772d11d49e38f382b2cab84ee93161169491aaf49bdaeb1a20b33e0")
        let rest = try await reader.mailboxes(after: "2")
        #expect(rest.items.map(\.id) == ["1"] && rest.next == nil)
        #expect(await server.asked.last == "\(path)?max_id=2")

        let (first, _) = try self.reader([path: .json(Captures.mailboxesFirst, link: Captures.mailboxesFirstLink)])
        #expect(try await first.mailboxes().next == "2")
    }

    @Test("A mailbox is tried, added and taken off by its address, as written and trimmed, its domain only lower case and never in its ASCII spelling: trying answers with those it already is, in any spelling, and sends nothing to keep")
    func mailboxWrites() async throws {
        let path = MastodonAdminFederation.mailboxesPath
        let (reader, server) = try reader([
            "\(path)/test": .json(Captures.mailboxTried), path: .json(Captures.mailboxAdded),
            "\(path)/1": .json(Captures.mailboxRemoved),
        ])
        let tried = try await reader.tryMailbox(" fediqo417@Example.COM\n")
        #expect(tried.map(\.id) == ["1"])
        let sent = try #require(await server.sent.first)
        #expect(sent.method == "POST" && sent.body == "email=fediqo417%40example.com")
        #expect(await server.asked.first == "\(path)/test")
        let added = try await reader.addMailbox("Fediqo.417+tag@Bücher.Example")
        #expect(added.id == "1" && added.hash.hasPrefix("775b10bf"))
        #expect(await server.sent.last?.body == "email=Fediqo.417%2Btag%40b%C3%BCcher.example")
        try await reader.removeMailbox("1")
        #expect(await server.asked.last == "\(path)/1")

        let (none, _) = try self.reader(["\(path)/test": .json(Captures.mailboxTriedNone)])
        #expect(try await none.tryMailbox("other@example.com").isEmpty)
    }

    @Test("A mailbox already refused, added again, is refused in the server's words; one there is none of is not found; without the standing it is not allowed; an address that is none is asked nothing")
    func mailboxRefusals() async throws {
        let path = MastodonAdminFederation.mailboxesPath
        let (reader, server) = try reader([
            path: .json(Captures.mailboxTwice, status: 422),
            "\(path)/999": .json(Captures.noMailbox, status: 404),
            "\(path)?max_id=1": .json(Captures.modBlocks, status: 403),
            "\(path)/test": .json("{}"),
        ])
        await #expect(throws: MastodonAdminError.refused(sentence: "Validation failed: Canonical email hash has already been taken")) {
            _ = try await reader.addMailbox("refused417@example.com")
        }
        await #expect(throws: MastodonAuthError.http(404)) { try await reader.removeMailbox("999") }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await reader.mailboxes(after: "1") }
        await #expect(throws: MastodonAdminError.unreadable) { _ = try await reader.tryMailbox("x@example.com") }
        let before = await server.asked.count
        for address in ["", "  ", "nobody", "@example.com", "a b@example.com", "a@", "a@nodot", "a@x y.example", "a\t@example.com",
                        String(repeating: "a", count: 65) + "@example.com"] {
            #expect(MastodonAdminFederation.wireMailbox(address) == nil, "\(address)")
            await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.tryMailbox(address) }
            await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.addMailbox(address) }
        }
        await #expect(throws: MastodonAdminError.invalid) { try await reader.removeMailbox("../1") }
        #expect(await server.asked.count == before)
        #expect(MastodonAdminFederation.wireMailbox("\"odd@name\"@example.com") == "\"odd@name\"@example.com")
    }
}
