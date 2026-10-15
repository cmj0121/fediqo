import Foundation
import Testing
@testable import FediqoCore

/// #312 — the account part, and the reader's own account read and changed through the one
/// signed-in door: what is sent is only what changed, the fields whole where any did; what is
/// handed back is the source's answer; a refusal says what; and the lock is the held words'.
///
/// Every expected string is written out here and not read off the table it is held against.
@Suite("The reader's own account at a Mastodon, and the part that changes it")
struct MastodonOwnAccountTests {
    private static let r = "read:statuses read:lists read:accounts"
    private static let s = "read:search"
    private static let w = "write:statuses write:favourites"
    private static let b = "write:bookmarks"
    private static let n = "read:notifications"
    private static let d = "write:notifications"
    private static let f = "read:follows write:follows"
    private static let a = "write:accounts"
    private static let check = "/api/v1/accounts/verify_credentials"
    private static let change = "/api/v1/accounts/update_credentials"

    private static func reader(
        _ routes: [String: FixtureSender.Outcome], scopes: String? = "\(r) \(a)"
    ) throws -> (MastodonOwnAccount, FixtureSender, MemoryMastodonTokens) {
        let token = MastodonFixture.token(scopes: scopes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        let server = FixtureSender(routes)
        return (MastodonOwnAccount(door: MastodonAuthorized(token: token, sender: server, store: tokens)), server, tokens)
    }

    /// The form a request carried, every name and value decoded, in the order sent.
    private static func form(_ request: URLRequest?) -> [[String]] {
        guard let body = request?.httpBody, let text = String(data: body, encoding: .utf8), !text.isEmpty else { return [] }
        return text.split(separator: "&").map { pair in
            pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? "" }
        }
    }

    /// An account as a source answers it, built from what a test changes.
    private static func answer(
        name: String = "Ada", note: String = "hello", fields: String = "[]", locked: String = "false",
        discoverable: String = "true", hide: String = "false"
    ) -> String {
        #"{"id":"1","username":"ada","acct":"ada","display_name":"\#(name)","locked":\#(locked),"discoverable":\#(discoverable),"hide_collections":\#(hide),"note":"<p>\#(note)</p>","fields":[],"source":{"privacy":"public","note":"\#(note)","fields":\#(fields),"discoverable":\#(discoverable),"hide_collections":\#(hide)}}"#
    }

    private static let before = OwnAccount(
        name: "Ada", words: "hello",
        fields: [.init(name: "site", value: "https://a.example", verified: true), .init(name: "pronouns", value: "she/her")],
        locked: false, discoverable: true, hidesLists: false
    )

    // MARK: - The part

    @Test("The account part is its one word and nothing else's: it rides on no question, stands without acting, comes last in the table, and is no reason to call a sign-in one that acts")
    func theEntry() {
        let part = MastodonPart.account
        #expect(part.words == ["write:accounts"])
        #expect(part.wordsBesideActing.isEmpty)
        #expect(!part.rider)
        #expect(!part.needsActing)
        #expect(MastodonPart.allCases.last == .account)
        #expect(MastodonGrant.of(scopes: "\(Self.r) \(Self.a)") == .reading)
        #expect(!MastodonOAuth.writes("\(Self.r) \(Self.s) \(Self.a)"))
    }

    @Test("The page that asks for the account part carries what is held and write:accounts, in the table's order, whatever is held — and nothing else")
    func thePageForEachHeldState() {
        let (r, s, w, b, n, d, f, a) = (Self.r, Self.s, Self.w, Self.b, Self.n, Self.d, Self.f, Self.a)
        let pages: [(held: String?, page: String)] = [
            (r, "\(r) \(a)"),
            ("\(r) \(s)", "\(r) \(s) \(a)"),
            ("\(r) \(s) \(w) \(b) \(n) \(d)", "\(r) \(s) \(w) \(b) \(n) \(d) \(a)"),
            ("\(r) \(f)", "\(r) \(f) \(a)"),
            ("\(a) \(f) \(r)", "\(r) \(f) \(a)"),
            ("\(r) push", "\(r) \(a)"),
            ("read write", a),
            (nil, a),
        ]
        for (held, page) in pages {
            #expect(MastodonParts.page(held: held, ticked: [.account]) == page, "\(held ?? "nothing")")
        }
        #expect(MastodonParts.page(held: nil, ticked: [.follows, .account]) == "\(f) \(a)")
        #expect(MastodonParts.page(held: "\(r) \(a)", ticked: [.reading, .search], readOnly: true) == "\(r) \(s)")
        #expect(MastodonParts.everything == "\(r) \(s) \(w) \(b) \(n) \(d) \(f) \(a)")
    }

    @Test("Today's four sign-in choices ask exactly the strings they asked, byte for byte, and none of them asks for the account part")
    func todaysChoicesAreUnchanged() {
        let (r, s, w, b, n, d) = (Self.r, Self.s, Self.w, Self.b, Self.n, Self.d)
        #expect(MastodonOAuth.scopes(writing: false) == "\(r) \(s)")
        #expect(MastodonOAuth.scopes(writing: false, notices: true) == "\(r) \(s) \(n)")
        #expect(MastodonOAuth.scopes(writing: true) == "\(r) \(s) \(w) \(b)")
        #expect(MastodonOAuth.scopes(writing: true, notices: true) == "\(r) \(s) \(w) \(b) \(n) \(d)")
        for writing in [false, true] {
            for notices in [false, true] {
                #expect(!MastodonOAuth.scopes(writing: writing, notices: notices).contains("accounts:"))
                #expect(!MastodonOAuth.scopes(writing: writing, notices: notices).contains("write:accounts"))
            }
        }
    }

    @Test("A sign-in stands to the account part as to any: never asked by every sign-in made before it, held by its word, refused where the page was, and asked and not given otherwise")
    func standings() {
        let (r, a) = (Self.r, Self.a)
        func held(_ scopes: String?, asked: String? = nil, refused: String? = nil) -> MastodonHeld {
            MastodonHeld(scopes: scopes, asked: asked, refused: refused)
        }
        #expect(MastodonParts.standing(.account, of: held(r, asked: r)) == .unasked)
        #expect(MastodonParts.standing(.account, of: held("\(r) \(a)", asked: "\(r) \(a)")) == .held)
        #expect(MastodonParts.standing(.account, of: held(r, asked: "\(r) \(a)", refused: a)) == .refused)
        #expect(MastodonParts.standing(.account, of: held(r, asked: "\(r) \(a)")) == .notGiven)
        #expect(MastodonParts.holdings(in: "\(r) \(a)") == MastodonHoldings(entries: [.whole(.reading), .whole(.account)], other: []))
    }

    @Test("The registration gains write:accounts after every word it had; one kept from before holds every page it held and no page that asks for the account part, so it is made again at that press alone")
    func theRegistrationWidens() {
        let (r, s, w, b, n, d, f, a) = (Self.r, Self.s, Self.w, Self.b, Self.n, Self.d, Self.f, Self.a)
        let before = "\(r) \(s) \(w) \(b) \(n) \(d) \(f)"
        #expect(MastodonRegistration.superset() == "\(before) \(a)")
        #expect(MastodonRegistration.superset(listed: Set(before.split(separator: " ").map(String.init))) == before)
        let asked = "\(r) \(s) \(a)"
        #expect(!MastodonRegistration.holds(asked, on: before))
        #expect(MastodonRegistration.page(asked, on: before) == nil)
        #expect(MastodonRegistration.holds(asked, on: MastodonRegistration.superset()))
        for page in ["\(r) \(s)", "\(r) \(s) \(w) \(b) \(n) \(d)", "\(r) \(s) \(f)"] {
            #expect(MastodonRegistration.holds(page, on: before), "\(page)")
        }
    }

    // MARK: - Reading

    @Test("What a real server answered is read as its owner sees it: the owner's own words, not the HTML; and a switch it answers null is not said, never no")
    func whatARealServerSent() throws {
        let account = try MastodonOwnAccount.account(from: Data(MastodonPartsCaptures.taken.utf8))
        #expect(account == OwnAccount(name: "", words: MastodonPartsCaptures.note, fields: [], locked: false, discoverable: nil, hidesLists: nil))
    }

    @Test("Read once, as the person, at the account check of the host the sign-in is of: name, words, fields with their verified mark, and the three switches")
    func readThroughTheDoor() async throws {
        let fields = #"[{"name":"site","value":"https://a.example","verified_at":"2026-10-01T00:00:00.000Z"},{"name":"pronouns","value":"she/her","verified_at":null}]"#
        let (reader, server, _) = try Self.reader([Self.check: .json(Self.answer(fields: fields))], scopes: Self.r)
        #expect(try await reader.read() == Self.before)
        let requests = await server.requests
        #expect(requests.count == 1 && requests.first?.httpMethod == "GET")
        #expect(requests.first?.url?.absoluteString == "https://\(MastodonFixture.host)\(Self.check)")
    }

    @Test("A GoToSocial, which never sends whether an account hides its lists, reads that as not said; an account with no owner's words is unreadable")
    func notSaidAndUnreadable() throws {
        let goToSocial = #"{"id":"01K","username":"ada","acct":"ada","display_name":"Ada","locked":true,"discoverable":false,"note":"<p>hi</p>","fields":[],"source":{"privacy":"unlisted","note":"hi","fields":[],"status_content_type":"text/plain","web_visibility":"unlisted"}}"#
        let read = try MastodonOwnAccount.account(from: Data(goToSocial.utf8))
        #expect(read == OwnAccount(name: "Ada", words: "hi", locked: true, discoverable: false, hidesLists: nil))
        for body in ["{}", "[]", "", #"{"display_name":"Ada","note":"<p>hi</p>"}"#, #"{"source":null}"#] {
            #expect(throws: OwnAccountError.unreadable) { try MastodonOwnAccount.account(from: Data(body.utf8)) }
        }
    }

    @Test("A limit is one the host states — a real Mastodon's document states five — and a host that states none, or a value of nothing, has none")
    func limits() {
        let mastodon = MastodonOwnAccount.limits(from: Data(MastodonHostCaptures.document.utf8))
        #expect(mastodon == OwnAccountLimits(name: 40, words: 500, fields: 4, fieldName: 255, fieldValue: 255))
        #expect(MastodonOwnAccount.limits(from: Data(#"{"configuration":{"statuses":{"max_characters":5000}}}"#.utf8)) == .none)
        #expect(MastodonOwnAccount.limits(from: Data(#"{"configuration":{"accounts":{"max_note_length":0,"max_profile_fields":"4"}}}"#.utf8)) == .none)
        #expect(MastodonOwnAccount.limits(from: Data("<html>".utf8)) == .none)
    }

    // MARK: - Changing

    @Test("A change sends only what changed — the name, the words, each switch — in that order, as a PATCH of a form, and hands back the source's answer, not what was sent")
    func onlyWhatChanged() async throws {
        let answered = Self.answer(name: "Ada L", note: "said by the source", locked: "true")
        let (reader, server, _) = try Self.reader([Self.change: .json(answered)])
        var after = Self.before
        after.name = "Ada L"
        after.locked = true
        let back = try await reader.change(from: Self.before, to: after)
        #expect(back.words == "said by the source" && back.name == "Ada L" && back.locked == true)
        let sent = try #require(await server.requests.first)
        #expect(sent.httpMethod == "PATCH" && sent.url?.path == Self.change)
        #expect(Self.form(sent) == [["display_name", "Ada L"], ["locked", "true"]])

        #expect(MastodonOwnAccount.form(from: Self.before, to: { var a = Self.before; a.words = "a & b = c\n"; a.discoverable = false; a.hidesLists = true; return a }()).map { [$0.0, $0.1] }
            == [["note", "a & b = c\n"], ["discoverable", "false"], ["hide_collections", "true"]])
    }

    @Test("Where any field changed every field is sent, in order, since the source replaces the set; a verified mark alone is no change; and fields all taken away are sent as one empty field")
    func fieldsWhole() {
        func form(_ change: (inout OwnAccount) -> Void) -> [[String]] {
            var after = Self.before
            change(&after)
            return MastodonOwnAccount.form(from: Self.before, to: after).map { [$0.0, $0.1] }
        }
        let whole = [
            ["fields_attributes[0][name]", "site"], ["fields_attributes[0][value]", "https://a.example"],
            ["fields_attributes[1][name]", "pronouns"], ["fields_attributes[1][value]", "they/them"],
        ]
        #expect(form { $0.fields[1].value = "they/them" } == whole)
        #expect(form { $0.fields[0].verified = false } == [])
        #expect(form { $0.fields.removeLast() } == [["fields_attributes[0][name]", "site"], ["fields_attributes[0][value]", "https://a.example"]])
        #expect(form { $0.fields = [] } == [["fields_attributes[0][name]", ""], ["fields_attributes[0][value]", ""]])
    }

    @Test("A switch the source did not say is sent only when the person sets it, and one left unsaid is never sent; nothing changed asks nothing and hands back what was")
    func unsaidSwitches() async throws {
        let unsaid = OwnAccount(name: "Ada", words: "hi", locked: false, discoverable: nil, hidesLists: nil)
        var set = unsaid
        set.hidesLists = false
        #expect(MastodonOwnAccount.form(from: unsaid, to: set).map { [$0.0, $0.1] } == [["hide_collections", "false"]])
        #expect(MastodonOwnAccount.form(from: Self.before, to: { var a = Self.before; a.hidesLists = nil; return a }()).isEmpty)

        let (reader, server, _) = try Self.reader([:])
        #expect(try await reader.change(from: Self.before, to: Self.before) == Self.before)
        #expect(await server.requests.isEmpty)
    }

    @Test("A refusal (422) says what was refused, by what it was sent as, and the source's sentence fit for a line — a real Mastodon's among them — and the sign-in goes on")
    func refusal() async throws {
        let said = #"{"error":"Validation failed: Note is too long\nreally","details":{"note":[{"error":"ERR_TOO_LONG"}],"fields":[{"error":"ERR_TOO_MANY"}],"display_name":[],"avatar":[]}}"#
        let (reader, _, tokens) = try Self.reader([Self.change: .json(said, status: 422)])
        var after = Self.before
        after.words = String(repeating: "x", count: 600)
        await #expect(throws: OwnAccountError.refused(OwnAccountRefusal(what: [.name, .words, .fields], said: "Validation failed: Note is too long really"))) {
            try await reader.change(from: Self.before, to: after)
        }
        #expect(try tokens.token(host: MastodonFixture.host) != nil)

        #expect(MastodonOwnAccount.refusal(from: Data(MastodonPartsCaptures.noPicture.utf8))
            == OwnAccountRefusal(what: [], said: "Validation failed: Avatar has contents that are not what they are reported to be"))
        #expect(MastodonOwnAccount.refusal(from: Data(#"{"error":"Unprocessable Entity"}"#.utf8)) == OwnAccountRefusal(said: "Unprocessable Entity"))
        #expect(MastodonOwnAccount.refusal(from: Data("<html>".utf8)) == OwnAccountRefusal())
        let long = #"{"error":"\#(String(repeating: "y", count: 100_000))"}"#
        #expect(MastodonOwnAccount.refusal(from: Data(long.utf8)) == OwnAccountRefusal())
    }

    @Test("The lock is read from the held words, never from a 403's text: a 403 to a sign-in without the part is its lock, and to one holding it a refusal — whatever the 403 says")
    func theLock() async throws {
        let bodies = [
            #"{"error":"This action is outside the authorized scopes"}"#,
            #"{"error":"Forbidden"}"#,
            "",
        ]
        var after = Self.before
        after.name = "Ada L"
        for body in bodies {
            let (without, _, _) = try Self.reader([Self.change: .json(body, status: 403)], scopes: Self.r)
            await #expect(throws: OwnAccountError.locked) { try await without.change(from: Self.before, to: after) }
            let (unsaid, _, _) = try Self.reader([Self.change: .json(body, status: 403)], scopes: nil)
            await #expect(throws: OwnAccountError.locked) { try await unsaid.change(from: Self.before, to: after) }
            let (holding, _, _) = try Self.reader([Self.change: .json(body, status: 403)])
            await #expect(throws: OwnAccountError.refused(OwnAccountRefusal())) { try await holding.change(from: Self.before, to: after) }
        }
    }

    @Test("A failure is the door's: nothing answering, a server's failure, and an answer that is no account each throw, and the sign-in is held as it was")
    func failures() async throws {
        var after = Self.before
        after.name = "Ada L"
        let (down, _, tokens) = try Self.reader([Self.change: .fail])
        await #expect(throws: URLError.self) { try await down.change(from: Self.before, to: after) }
        let (failing, _, _) = try Self.reader([Self.change: .json("{}", status: 500)])
        await #expect(throws: MastodonAuthError.http(500)) { try await failing.change(from: Self.before, to: after) }
        let (odd, _, _) = try Self.reader([Self.change: .json("[]")])
        await #expect(throws: OwnAccountError.unreadable) { try await odd.change(from: Self.before, to: after) }
        #expect(try tokens.token(host: MastodonFixture.host) != nil)
    }
}
