import Foundation
import Testing
@testable import FediqoCore

/// #383: what Fediqo believes a Mastodon says of the servers and addresses it refuses or allows,
/// held against the real one this checkout brings up (`make servers`, Mastodon 4.6.6) — read and
/// changed through this app's own reader, `MastodonAdminFederation`.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`), and **every change a check
/// makes it takes back**: a server it blocks is unblocked, one it allows is no longer, a mail
/// domain or a range it refuses is taken off — and the seed takes off whatever a check that
/// stopped half way left, on its next run. A mailbox refused however written (#417) is taken off
/// by its own check, before it begins as after it ends: the seed has none to put back.
@Suite("What a Mastodon says of the servers and addresses it refuses", .enabled(if: LocalServers.requested), .serialized)
struct MastodonAdminFederationSaysTests {
    private static let host = LocalServers.mastodon
    private static let trial = "fediqo383.example"

    private static func token(_ who: String) throws -> String {
        let data = try Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/mastodon-tokens.json"))
        let all = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tending = try #require(all["tending"] as? [String: Any], "seeded before tending was: run `make servers` again")
        try #require(tending["servers"] != nil, "seeded before #383: run `make servers` again")
        return try #require((tending[who] as? [String: Any])?["token"] as? String)
    }

    private static func reader(_ who: String) throws -> MastodonAdminFederation {
        let token = MastodonToken(host: host, accessToken: try token(who), clientID: "x", clientSecret: "x")
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return MastodonAdminFederation(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    @Test("The Admin reads the four lists as seeded; the Moderator, whose role answers for neither, is refused each")
    func whatIsRefused() async throws {
        try await LocalServers.requireHealthy()
        let admin = try Self.reader("admin")
        let blocks = try await admin.blocks().items
        #expect(blocks.first { $0.domain == "suspended.example" }?.severity == .suspend)
        #expect(blocks.first { $0.domain == "limited.example" }.map { $0.severity == .limit && $0.rejectMedia } == true)
        #expect(try await admin.allows().items.contains { $0.domain == "allowed.example" })
        #expect(try await admin.mailDomains().items.contains { $0.domain == "spam.example" })
        #expect(try await admin.addresses().items.contains { $0.ip == "192.0.2.0/24" && $0.severity == .signUp })
        let mod = try Self.reader("mod")
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await mod.blocks() }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await mod.allows() }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await mod.mailDomains() }
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await mod.addresses() }
    }

    @Test("A server is suspended, changed to limited with its media refused, and taken off — each as the list then shows it; a server already suspended, blocked again, is refused in the server's words")
    func aServerBlocked() async throws {
        try await LocalServers.requireHealthy()
        let admin = try Self.reader("admin")
        let added = try await admin.addBlock(ServerBlockDraft(domain: Self.trial, severity: .suspend, publicWords: "fediqo383 check"))
        #expect(try await admin.blocks().items.first { $0.id == added.id }?.severity == .suspend)
        var draft = added.draft
        draft.severity = .limit
        draft.rejectMedia = true
        let changed = try await admin.changeBlock(added.id, to: draft)
        #expect(changed.severity == .limit && changed.rejectMedia)
        try await admin.removeBlock(added.id)
        #expect(try await !admin.blocks().items.contains { $0.domain == Self.trial })
        // In the server's words — in the language it speaks to the Admin, so held to naming the server.
        do {
            _ = try await admin.addBlock(ServerBlockDraft(domain: "suspended.example", severity: .suspend))
            Issue.record("a server already suspended was blocked again")
        } catch MastodonAdminError.refused(let sentence) {
            #expect(sentence.contains("suspended.example"))
        }
    }

    @Test("A server allowed, a mail domain refused and a range refused are each added and taken off, as the lists then show them")
    func allowsAndAddresses() async throws {
        try await LocalServers.requireHealthy()
        let admin = try Self.reader("admin")
        let allow = try await admin.addAllow(Self.trial)
        #expect(try await admin.allows().items.contains { $0.id == allow.id })
        try await admin.removeAllow(allow.id)
        #expect(try await !admin.allows().items.contains { $0.domain == Self.trial })

        let mail = try await admin.addMailDomain(Self.trial)
        #expect(try await admin.mailDomains().items.contains { $0.id == mail.id })
        try await admin.removeMailDomain(mail.id)
        #expect(try await !admin.mailDomains().items.contains { $0.domain == Self.trial })

        let range = try await admin.addAddress("198.51.100.0/24", severity: .approval, words: "fediqo383 check")
        #expect(try await admin.addresses().items.contains { $0.id == range.id && $0.severity == .approval })
        try await admin.removeAddress(range.id)
        #expect(try await !admin.addresses().items.contains { $0.ip == "198.51.100.0/24" })
    }

    @Test("A mailbox refused is refused in any spelling the server counts as the same: tried, it is found; added again, refused in the server's words; taken off, it is tried and found in none — and the Moderator, whose role does not answer for it, is refused the list")
    func aMailboxRefused() async throws {
        try await LocalServers.requireHealthy()
        let admin = try Self.reader("admin")
        let plain = "fediqo417@example.com"
        for left in try await admin.tryMailbox(plain) { try await admin.removeMailbox(left.id) }
        #expect(try await admin.tryMailbox(plain).isEmpty)

        let added = try await admin.addMailbox("Fediqo.417+tag@Example.com")
        #expect(try await admin.tryMailbox(plain).map(\.id) == [added.id])
        #expect(try await admin.mailboxes().items.contains(added))
        do {
            _ = try await admin.addMailbox(plain)
            Issue.record("the same mailbox, written another way, was added again")
        } catch MastodonAdminError.refused(let sentence) {
            #expect(!sentence.isEmpty)
        }
        try await admin.removeMailbox(added.id)
        #expect(try await admin.tryMailbox("fediqo.417+tag@example.com").isEmpty)
        #expect(try await !admin.mailboxes().items.contains(added))

        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await Self.reader("mod").mailboxes() }
    }
}
