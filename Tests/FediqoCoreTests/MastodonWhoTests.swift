import Foundation
import Testing
@testable import FediqoCore

/// #347: who a sign-in is, as its own account check says — the id the source gives the
/// account, and a handle taken only where it is a name of that very source.
///
/// What the check answers a real server is kept in `MastodonSignInCaptures`: 200 with `id` a
/// string and `acct` the name with no host for a token holding the reading words, and 403
/// for one without `read:accounts`.
@Suite("Who a sign-in's own check says it is")
struct MastodonWhoTests {
    private static let host = MastodonFixture.host

    private func said(_ body: String) -> MastodonWho {
        MastodonWho.said(Data(body.utf8), at: Self.host)
    }

    @Test("The check's answer names the account by its id, and by a handle of the sign-in's own source: a name with no host, or with that host and no other")
    func theAnswerNamesTheAccount() {
        #expect(said(#"{"id":"1","acct":"reader"}"#) == MastodonWho(id: "1", handle: "@reader@social.example"))
        #expect(said(#"{"id":"1","acct":"Reader_9"}"#).handle == "@Reader_9@social.example", "spelt as the source spells it")
        #expect(said(#"{"id":"1","acct":"reader@Social.Example"}"#).handle == "@reader@social.example")
        #expect(said(#"{"acct":"reader"}"#) == MastodonWho(id: nil, handle: "@reader@social.example"))
        #expect(said(#"{"id":"1"}"#) == MastodonWho(id: "1", handle: nil))
        for nothing in ["{}", "[]", "", "<html>"] {
            #expect(said(nothing) == MastodonWho(id: nil, handle: nil))
        }
    }

    @Test("A handle that is another server's, or no name a line of ours can hold as it was sent, is not taken — and the id beside it still stands", arguments: [
        "eve@other.example", "eve@social.example@other.example", "@reader", "reader@", "", " ", "rea der",
        "rea\u{202E}der", "rea\u{0007}der", "rea\nder", "rea\u{200B}der", String(repeating: "a", count: LineText.nameLength + 1),
        // Not what a name at a server is spelled in: a letter that only looks like one, a
        // joiner nobody sees, a mark of some other address.
        "re\u{0430}der", "r\u{00E9}ader", "\u{FF52}eader", "rea\u{200D}der", "rea/der", "rea:der", "rea+der",
    ])
    func aHandleNotItsSourcesOwnIsNotTaken(acct: String) throws {
        let body = try JSONSerialization.data(withJSONObject: ["id": "1", "acct": acct])
        #expect(MastodonWho.said(body, at: Self.host) == MastodonWho(id: "1", handle: nil))
    }

    @Test("A name is taken with the three marks a name may carry, as a typed one is")
    func theMarksANameMayCarry() {
        #expect(said(#"{"id":"1","acct":"rea.der-9_x"}"#).handle == "@rea.der-9_x@social.example")
    }

    @Test("A note of who a sign-in is carries its own handle: an id written with no handle takes the handle held away, and a note that names nobody — a refusal — leaves who it is as held")
    func aNoteOfWhoItIsUnwritesTheHandle() throws {
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token.named(accountID: "1", handle: "@reader@social.example"))
        let bare = MastodonToken(
            host: Self.host, accessToken: MastodonFixture.token.accessToken, clientID: "cid", clientSecret: "csecret"
        )
        #expect(try store.update(bare.recorded(refused: "write:bookmarks")))
        #expect(try store.token(host: Self.host)?.handle == "@reader@social.example")
        #expect(try store.token(host: Self.host)?.accountID == "1")

        #expect(try store.update(bare.named(accountID: "1", handle: nil)))
        let kept = try #require(try store.token(host: Self.host))
        #expect(kept.accountID == "1")
        #expect(kept.handle == nil)
        #expect(kept.refused == "write:bookmarks")
    }

    @Test("A handle read back from beside a sign-in is taken by the rule a check's answer is: this source's own name, marked, or none", arguments: [
        ("@reader@social.example", "@reader@social.example"), ("@Reader_9@Social.Example", "@Reader_9@social.example"),
        ("@eve@other.example", nil), ("reader@social.example", nil), ("@re\u{0430}der@social.example", nil), ("", nil),
    ] as [(String, String?)])
    func aHandleReadBack(written: String, taken: String?) {
        #expect(MastodonWho.kept(written, at: Self.host) == taken)
    }

    @Test("A name as long as a name may run is taken whole; an id that is nothing, or longer than an id may run, is none — and the handle beside it still stands")
    func theBounds() {
        let longest = String(repeating: "a", count: LineText.nameLength)
        #expect(said(#"{"id":"1","acct":"\#(longest)"}"#).handle == "@\(longest)@social.example")
        #expect(said(#"{"id":"","acct":"reader"}"#) == MastodonWho(id: nil, handle: "@reader@social.example"))
        let long = String(repeating: "9", count: MastodonOAuth.clientBytes + 1)
        #expect(said(#"{"id":"\#(long)","acct":"reader"}"#) == MastodonWho(id: nil, handle: "@reader@social.example"))
    }

    @Test("A sign-in hands back who its own check said it is, id and handle off the one answer — for a sign-in to read as for one to act — and asks the source nothing more for it")
    func aSignInHandsBackWhoItIs() async throws {
        for words in [MastodonOAuth.scopes(writing: false), MastodonOAuth.scopes(writing: true)] {
            let server = MastodonFixture.server()
            let app = MastodonApp(host: Self.host, clientID: "cid", clientSecret: "csecret", scopes: words)
            let signed = try await MastodonOAuth(host: Self.host, sender: server)
                .signIn(as: app, through: await FixtureBrowser.approving())
            #expect(signed.failed == nil)
            #expect(signed.accountID == "1")
            #expect(signed.handle == "@reader@social.example")
            #expect(await server.paths == ["/oauth/token", "/api/v1/accounts/verify_credentials"])
        }
    }

    @Test("A sign-in whose check is refused — a token without the word that reads the account — is handed back as failed, naming nobody")
    func aRefusedCheckNamesNobody() async throws {
        let refused = FixtureSender.Outcome.json(#"{"error":"This action is outside the authorized scopes"}"#, status: 403)
        let signed = try await MastodonOAuth(host: Self.host, sender: MastodonFixture.server(verify: refused))
            .signIn(as: MastodonFixture.app, through: await FixtureBrowser.approving())
        #expect(signed.failed == .http(403))
        #expect(signed.accountID == nil)
        #expect(signed.handle == nil)
    }

    @Test("The door's own check reads the same answer the same way: another server's name is no handle, and the id stands")
    func theDoorReadsItTheSameWay() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        func who(_ body: String) async throws -> MastodonWho {
            let sender = FixtureSender(["/api/v1/accounts/verify_credentials": .json(body)])
            return try await MastodonAuthorized(token: MastodonFixture.token, sender: sender, store: tokens).who()
        }
        #expect(try await who(#"{"id":"1","acct":"reader"}"#) == MastodonWho(id: "1", handle: "@reader@social.example"))
        #expect(try await who(#"{"id":"1","acct":"eve@other.example"}"#) == MastodonWho(id: "1", handle: nil))
        #expect(try await who("{}") == MastodonWho(id: nil, handle: nil))
        await #expect(throws: MastodonWriteError.unreadable) { _ = try await who("[]") }
    }

    @Test("Who a sign-in is, is written beside it by its id alone where the source gave no handle of its own, in place and only over the string it was said through")
    func theIdIsKeptWithoutAHandle() throws {
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token)
        let named = MastodonFixture.token.named(accountID: "1", handle: nil)
        // An add would be refused: a note of who it is makes none.
        store.refuse(.adding)
        #expect(try store.update(named))
        let kept = try #require(try store.token(host: Self.host))
        #expect(kept.accountID == "1")
        #expect(kept.handle == nil)

        let other = MastodonToken(host: Self.host, accessToken: "another", clientID: "cid", clientSecret: "csecret")
        #expect(try !store.update(other.named(accountID: "2", handle: "@eve@social.example")))
        #expect(try store.token(host: Self.host)?.accountID == "1")
    }

    @Test("A sign-in filed again from outside with nothing said of whose it is — what a package read back does — is kept as nobody's, the very same string included, until this device's own check says")
    func filedAgainFromOutsideItIsNobodys() throws {
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token.named(accountID: "1", handle: "@reader@social.example"))
        try store.save(MastodonFixture.token)
        let kept = try #require(try store.token(host: Self.host))
        #expect(kept.accountID == nil)
        #expect(kept.handle == nil)
    }
}
