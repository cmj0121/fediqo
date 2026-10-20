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
        discoverable: String = "true", hide: String = "false", asking: String = "2"
    ) -> String {
        #"{"id":"1","username":"ada","acct":"ada","display_name":"\#(name)","locked":\#(locked),"discoverable":\#(discoverable),"hide_collections":\#(hide),"note":"<p>\#(note)</p>","fields":[],"source":{"privacy":"public","note":"\#(note)","fields":\#(fields),"follow_requests_count":\#(asking),"discoverable":\#(discoverable),"hide_collections":\#(hide)}}"#
    }

    private static let verified = Date(timeIntervalSince1970: 1_790_812_800)

    private static let before = OwnAccount(
        name: "Ada", words: "hello",
        fields: [.init(name: "site", value: "https://a.example", verifiedAt: Self.verified), .init(name: "pronouns", value: "she/her")],
        followWithoutAsking: true, findable: true, listsShown: true
    )

    // MARK: - The part

    @Test("The account part is its one word and nothing else's: it rides on no question, stands without acting, comes immediately before media, and is no reason to call a sign-in one that acts")
    func theEntry() {
        let part = MastodonPart.account
        #expect(part.words == ["write:accounts"])
        #expect(part.wordsBesideActing.isEmpty)
        #expect(!part.rider)
        #expect(!part.needsActing)
        #expect(MastodonPart.allCases.dropLast(2).last == .account)
        #expect(MastodonPart.allCases.dropLast().last == .media)
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
        #expect(MastodonParts.everything == "\(r) \(s) \(w) \(b) \(n) \(d) \(f) \(a) write:media read:bookmarks read:favourites")
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
                #expect(!MastodonOAuth.scopes(writing: writing, notices: notices).contains("write:media"))
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
        #expect(MastodonRegistration.superset() == "\(before) \(a) write:media read:bookmarks read:favourites")
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
        #expect(account == OwnAccount(
            name: "", words: MastodonPartsCaptures.note, fields: [], followWithoutAsking: true, findable: nil, listsShown: nil,
            picture: URL(string: "https://mastodon.localhost/system/accounts/avatars/117/419/563/845/369/311/original/e956f8d85d609ba7.png")
        ))
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
        #expect(read == OwnAccount(name: "Ada", words: "hi", followWithoutAsking: false, findable: false, listsShown: nil))
        for body in ["{}", "[]", "", #"{"display_name":"Ada","note":"<p>hi</p>"}"#, #"{"source":null}"#] {
            #expect(throws: OwnAccountError.unreadable) { try MastodonOwnAccount.account(from: Data(body.utf8)) }
        }
    }

    @Test("A limit is one the host states — a real Mastodon's document states five — and a host that states none, or a value of nothing, has none")
    func limits() {
        let mastodon = MastodonOwnAccount.limits(from: Data(MastodonHostCaptures.document.utf8))
        #expect(mastodon == OwnLimits(name: 40, words: 500, fields: 4, fieldName: 255, fieldValue: 255, picture: 16_777_216))
        #expect(MastodonOwnAccount.limits(from: Data(#"{"configuration":{"statuses":{"max_characters":5000}}}"#.utf8)) == .none)
        #expect(MastodonOwnAccount.limits(from: Data(#"{"configuration":{"accounts":{"max_note_length":0,"max_profile_fields":"4"}}}"#.utf8)) == .none)
        #expect(MastodonOwnAccount.limits(from: Data("<html>".utf8)) == .none)
    }

    // MARK: - Changing

    @Test("A change sends only what changed — the name, the words, each switch — in that order, as a PATCH of a form, and hands back the source's answer, not what was sent: the account as its owner sees it, the person it is from the same body, and how many ask to follow it")
    func onlyWhatChanged() async throws {
        let answered = Self.answer(name: "Ada L", note: "said by the source", locked: "true", asking: "3")
        let (reader, server, _) = try Self.reader([Self.change: .json(answered)])
        var after = Self.before
        after.name = "Ada L"
        after.followWithoutAsking = false
        let back = try #require(try await reader.change(from: Self.before, to: after))
        #expect(back.account.words == "said by the source" && back.account.name == "Ada L" && back.account.followWithoutAsking == false)
        #expect(back.person.name == "Ada L" && back.person.accountID == "1" && back.person.source.host == MastodonFixture.host)
        #expect(back.asking == 3)
        let sent = try #require(await server.requests.first)
        #expect(sent.httpMethod == "PATCH" && sent.url?.path == Self.change)
        #expect(Self.form(sent) == [["display_name", "Ada L"], ["locked", "true"]])

        #expect(MastodonOwnAccount.form(from: Self.before, to: { var a = Self.before; a.words = "a & b = c\n"; a.findable = false; a.listsShown = false; return a }()).map { [$0.0, $0.1] }
            == [["note", "a & b = c\n"], ["discoverable", "false"], ["hide_collections", "true"]])
    }

    @Test("The answer a real server gave is read whole: the person from the same body and a count of none asking; a count that is no figure or below nothing is not said; and a body that is no person is unreadable")
    func theAnswer() throws {
        let real = try MastodonOwnAccount.answer(from: Data(MastodonPartsCaptures.taken.utf8), host: "mastodon.localhost")
        #expect(real.account.words == MastodonPartsCaptures.note)
        #expect(real.person.accountID == "117419563845369311" && real.person.handle == "@fediqo_other@mastodon.localhost")
        #expect(real.asking == 0)
        for (figure, said) in [("-1", nil), (#""2""#, nil), ("null", nil), ("7", 7)] as [(String, Int?)] {
            let body = Self.answer(asking: figure)
            #expect(try MastodonOwnAccount.answer(from: Data(body.utf8), host: MastodonFixture.host).asking == said, "\(figure)")
        }
        #expect(throws: OwnAccountError.unreadable) {
            try MastodonOwnAccount.answer(from: Data(#"{"source":{"note":"hi"}}"#.utf8), host: MastodonFixture.host)
        }
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
        #expect(form { $0.fields[0].verifiedAt = nil } == [])
        #expect(form { $0.fields.removeLast() } == [["fields_attributes[0][name]", "site"], ["fields_attributes[0][value]", "https://a.example"]])
        #expect(form { $0.fields = [] } == [["fields_attributes[0][name]", ""], ["fields_attributes[0][value]", ""]])
    }

    @Test("A switch the source did not say is sent only when the person sets it, and one left unsaid is never sent; nothing changed asks nothing and hands nothing back")
    func unsaidSwitches() async throws {
        let unsaid = OwnAccount(name: "Ada", words: "hi", followWithoutAsking: true, findable: nil, listsShown: nil)
        var set = unsaid
        set.listsShown = true
        #expect(MastodonOwnAccount.form(from: unsaid, to: set).map { [$0.0, $0.1] } == [["hide_collections", "false"]])
        #expect(MastodonOwnAccount.form(from: Self.before, to: { var a = Self.before; a.listsShown = nil; return a }()).isEmpty)

        let (reader, server, _) = try Self.reader([:])
        #expect(try await reader.change(from: Self.before, to: Self.before) == nil)
        #expect(await server.requests.isEmpty)
    }

    @Test("A refusal (422) says what was refused, by row, each with the source's first word about it, and the source's sentence — all fit for a line, a real Mastodon's among them — and the sign-in goes on")
    func refusal() async throws {
        let said = #"{"error":"Validation failed: Note is too long\nreally","details":{"note":[{"error":"ERR_TOO_LONG","description":"is too long\n(500)"},{"error":"ERR_OTHER","description":"second"}],"fields":[{"error":"ERR_TOO_MANY"}],"display_name":[],"avatar":[{"description":"bad"}]}}"#
        let (reader, _, tokens) = try Self.reader([Self.change: .json(said, status: 422)])
        var after = Self.before
        after.words = String(repeating: "x", count: 600)
        await #expect(throws: OwnAccountError.refused(sentence: "Validation failed: Note is too long really", rows: [.words: "is too long (500)", .fields: "", .name: "", .picture: "bad"])) {
            try await reader.change(from: Self.before, to: after)
        }
        #expect(try tokens.token(host: MastodonFixture.host) != nil)

        #expect(MastodonOwnAccount.refusal(from: Data(MastodonPartsCaptures.noPicture.utf8))
            == .refused(sentence: "Validation failed: Avatar has contents that are not what they are reported to be", rows: [.picture: "has contents that are not what they are reported to be"]))
        #expect(MastodonOwnAccount.refusal(from: Data(#"{"details":{"header":[{"description":"too big"}]}}"#.utf8)) == .refused(sentence: "", rows: [.header: "too big"]))
        #expect(MastodonOwnAccount.refusal(from: Data(#"{"error":"Unprocessable Entity"}"#.utf8)) == .refused(sentence: "Unprocessable Entity", rows: [:]))
        #expect(MastodonOwnAccount.refusal(from: Data(#"{"details":{"fields":[{"description":7}],"fields_attributes":[{"description":"too many"}]}}"#.utf8))
            == .refused(sentence: "", rows: [.fields: "too many"]))
        #expect(MastodonOwnAccount.refusal(from: Data("<html>".utf8)) == .refused(sentence: "", rows: [:]))
        let long = #"{"error":"\#(String(repeating: "y", count: 100_000))"}"#
        #expect(MastodonOwnAccount.refusal(from: Data(long.utf8)) == .refused(sentence: "", rows: [:]))
    }

    @Test("The lock is read from the held words, never from a 403's text: a 403 to a sign-in without the part is its lock, and to one holding it the source forbidding it — whatever the 403 says")
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
            await #expect(throws: OwnAccountError.forbidden) { try await holding.change(from: Self.before, to: after) }
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

    // MARK: - The picture and the header

    private static let pixel = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
    private static let avatar = "/api/v1/profile/avatar"
    private static let header = "/api/v1/profile/header"
    private static let face = "https://files.example/accounts/avatars/1/original/face.png"
    private static let band = "https://files.example/accounts/headers/1/original/band.jpg"

    /// `answer` with the account's picture and header said.
    private static func answer(avatar: String, header: String, name: String = "Ada") -> String {
        Self.answer(name: name).replacingOccurrences(of: #""id":"1","#, with: #""id":"1","avatar":"\#(avatar)","header":"\#(header)","#)
    }

    /// Whether a request carried exactly `parts`, made under the request's own boundary.
    private static func sent(_ request: URLRequest, as parts: [MultipartPart]) throws -> Bool {
        let said = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        guard said.hasPrefix(prefix) else { return false }
        let boundary = String(said.dropFirst(prefix.count))
        return try request.httpBody == MultipartBody(parts, limit: MultipartBody.byteLimit) { boundary }.data
    }

    @Test("The picture's limit is the host's: what a real Mastodon states of any picture, read alone where nothing else is stated; none where it states none, or nothing")
    func pictureLimit() {
        #expect(MastodonOwnAccount.limits(from: Data(MastodonHostCaptures.document.utf8)).picture == 16_777_216)
        #expect(MastodonOwnAccount.limits(from: Data(#"{"configuration":{"media_attachments":{"image_size_limit":10485760}}}"#.utf8)) == OwnLimits(picture: 10_485_760))
        #expect(MastodonOwnAccount.limits(from: Data(#"{"configuration":{"media_attachments":{"image_size_limit":0}}}"#.utf8)) == .none)
        #expect(MastodonOwnAccount.limits(from: Data(#"{"configuration":{"media_attachments":{"video_size_limit":10485760}}}"#.utf8)) == .none)
        #expect(MastodonOwnAccount.limits(from: Data(#"{"configuration":{"accounts":{"max_profile_fields":6}}}"#.utf8)) == OwnLimits(fields: 6))
    }

    @Test("The picture and the header are read where the account holds them; the host's stand-in for none — a real Mastodon's and a GoToSocial's among them — is none, and so is an address that is no web address, one in the clear (http), or nothing said")
    func picturesRead() throws {
        let real = try MastodonOwnAccount.account(from: Data(MastodonPartsCaptures.taken.utf8))
        #expect(real.picture == URL(string: "https://mastodon.localhost/system/accounts/avatars/117/419/563/845/369/311/original/e956f8d85d609ba7.png"))
        #expect(real.header == nil, "/headers/original/missing.png is the host's own")

        let held = try MastodonOwnAccount.account(from: Data(Self.answer(avatar: Self.face, header: Self.band).utf8))
        #expect(held.picture == URL(string: Self.face) && held.header == URL(string: Self.band))
        let none = try MastodonOwnAccount.account(from: Data(Self.answer(avatar: "https://social.example/avatars/original/missing.png", header: "javascript:alert(1)").utf8))
        #expect(none.picture == nil && none.header == nil)
        #expect(try MastodonOwnAccount.account(from: Data(Self.answer().utf8)).picture == nil)
        // Fetched as every other picture is: an address in the clear is none.
        let clear = try MastodonOwnAccount.account(from: Data(Self.answer(
            avatar: "http://social.example/avatars/a.png", header: "http://social.example/headers/b.png"
        ).utf8))
        #expect(clear.picture == nil && clear.header == nil)

        // A GoToSocial 0.22.2 draws one of its own for none: as it answered with none held.
        let drawn = try MastodonOwnAccount.account(from: Data(Self.answer(
            avatar: "https://gotosocial.localhost/assets/default_avatars/GoToSocial_icon4.webp",
            header: "https://gotosocial.localhost/assets/default_header.webp"
        ).utf8))
        #expect(drawn.picture == nil && drawn.header == nil)
        let own = try MastodonOwnAccount.account(from: Data(Self.answer(
            avatar: "https://gotosocial.localhost/fileserver/01PX/attachment/original/01M4.png",
            header: "https://gotosocial.localhost/fileserver/01PX/attachment/original/01M5.png"
        ).utf8))
        #expect(own.picture != nil && own.header != nil, "a picture of the person's own")
    }

    @Test("Pictures chosen go with the changed rows as one PATCH of several parts — the rows, then the picture, then the header, of a file's name the last piece alone — to the sign-in's own host with its token; and what is handed back is the source's answer")
    func picturesSent() async throws {
        let answered = Self.answer(avatar: Self.face, header: Self.band, name: "Ada said")
        let (reader, server, _) = try Self.reader([Self.change: .json(answered)])
        var after = Self.before
        after.name = "Ada L"
        let back = try #require(try await reader.change(from: Self.before, to: after, pictures: [
            .header: .chosen(Self.pixel, type: "image/jpeg", name: "/Users/ada/Pictures/band.jpg"),
            .picture: .chosen(Self.pixel, type: "image/png", name: "/Users/ada/Pictures/頭像 1.png"),
        ], limit: 1024))
        #expect(back.account.name == "Ada said" && back.account.picture == URL(string: Self.face) && back.person.accountID == "1")

        let requests = await server.requests
        #expect(requests.count == 1)
        let sent = try #require(requests.first)
        #expect(sent.url?.absoluteString == "https://\(MastodonFixture.host)\(Self.change)")
        #expect(sent.httpMethod == "PATCH")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(MastodonFixture.token.accessToken)")
        #expect(try Self.sent(sent, as: [
            .field("display_name", "Ada L"),
            .file("avatar", named: "頭像 1.png", type: "image/png", Self.pixel),
            .file("header", named: "band.jpg", type: "image/jpeg", Self.pixel),
        ]))
        #expect(!String(decoding: try #require(sent.httpBody), as: UTF8.self).contains("Pictures"))

        let (alone, quiet, _) = try Self.reader([Self.change: .json(answered)])
        _ = try await alone.change(from: Self.before, to: Self.before, pictures: [.header: .chosen(Self.pixel, type: "image/png", name: "b.png")])
        #expect(try Self.sent(try #require(await quiet.requests.first), as: [.file("header", named: "b.png", type: "image/png", Self.pixel)]))
    }

    @Test("A picture over the host's limit is refused naming it as the host's, and nothing at all is asked; a host that states more than this app sends, or nothing, is this app's bound, named as this app's; a picture and a header each at that bound go, whatever the body comes to")
    func pictureTooLarge() async throws {
        let (reader, server, _) = try Self.reader([Self.change: .json(Self.answer()), Self.avatar: .json(Self.answer())])
        var after = Self.before
        after.name = "Ada L"
        await #expect(throws: OwnPictureTooLarge(limit: 9, stated: true)) {
            try await reader.change(from: Self.before, to: after, pictures: [.header: .chosen(Self.pixel, type: "image/png", name: "b.png"), .picture: .removed], limit: 9)
        }
        #expect(await server.requests.isEmpty)
        _ = try await reader.change(from: Self.before, to: Self.before, pictures: [.picture: .chosen(Self.pixel, type: "image/png", name: "a.png")], limit: Self.pixel.count)
        #expect(await server.requests.count == 1)

        let over = Data(count: OwnPicture.byteLimit + 1)
        for limit in [nil, OwnPicture.byteLimit * 2] as [Int?] {
            await #expect(throws: OwnPictureTooLarge(limit: OwnPicture.byteLimit, stated: false)) {
                try await reader.change(from: Self.before, to: Self.before, pictures: [.picture: .chosen(over, type: "image/png", name: "a.png")], limit: limit)
            }
        }
        #expect(await server.requests.count == 1)

        let most = Data(count: OwnPicture.byteLimit)
        _ = try await reader.change(from: Self.before, to: after, pictures: [
            .picture: .chosen(most, type: "image/png", name: "a.png"), .header: .chosen(most, type: "image/png", name: "b.png"),
        ])
        #expect(await server.requests.count == 2)
    }

    @Test("Each removal is a DELETE of its own address on the sign-in's own host, carrying nothing, after the PATCH where there is one and in the picture's order; the answer is the source's last word")
    func removed() async throws {
        let (reader, server, _) = try Self.reader([
            Self.avatar: .json(Self.answer(name: "after the picture")), Self.header: .json(Self.answer(name: "after the header")),
            Self.change: .json(Self.answer(name: "after the change")),
        ])
        let back = try #require(try await reader.change(from: Self.before, to: Self.before, pictures: [.header: .removed, .picture: .removed]))
        #expect(back.account.name == "after the header")
        var requests = await server.requests
        #expect(requests.map { [$0.httpMethod ?? "", $0.url?.absoluteString ?? ""] } == [
            ["DELETE", "https://\(MastodonFixture.host)\(Self.avatar)"], ["DELETE", "https://\(MastodonFixture.host)\(Self.header)"],
        ])
        #expect(requests.allSatisfy { $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(MastodonFixture.token.accessToken)" })

        var after = Self.before
        after.words = "new"
        _ = try await reader.change(from: Self.before, to: after, pictures: [.picture: .removed, .header: .chosen(Self.pixel, type: "image/png", name: "b.png")])
        requests = await server.requests
        #expect(requests.dropFirst(2).map { [$0.httpMethod ?? "", $0.url?.path ?? ""] } == [["PATCH", Self.change], ["DELETE", Self.avatar]])
        #expect(try Self.sent(requests[2], as: [.field("note", "new"), .file("header", named: "b.png", type: "image/png", Self.pixel)]))
    }

    @Test("A removal that fails once something was taken is a change made in part, with the source's answer and what was not taken away; one that fails before anything was taken is the failure itself, and nothing more is asked")
    func partly() async throws {
        let (reader, server, _) = try Self.reader([
            Self.change: .json(Self.answer(name: "taken")), Self.avatar: .json("{}", status: 500), Self.header: .json("{}", status: 500),
        ])
        var after = Self.before
        after.name = "taken"
        let taken = try MastodonOwnAccount.answer(from: Data(Self.answer(name: "taken").utf8), host: MastodonFixture.host)
        let both = try await #require(throws: OwnChangedInPart.self) {
            try await reader.change(from: Self.before, to: after, pictures: [.picture: .removed, .header: .removed])
        }
        #expect(both.answer == taken)
        #expect(Set(both.failed.keys) == [.picture, .header])
        #expect(both.failed.values.allSatisfy { ($0 as? MastodonAuthError) == .http(500) }, "each with what it threw")
        #expect(await server.paths == [Self.change, Self.avatar, Self.header])

        let (first, asked, _) = try Self.reader([Self.avatar: .json("{}", status: 500), Self.header: .json(Self.answer())])
        await #expect(throws: MastodonAuthError.http(500)) {
            try await first.change(from: Self.before, to: Self.before, pictures: [.picture: .removed, .header: .removed])
        }
        #expect(await asked.paths == [Self.avatar])

        let (second, _, _) = try Self.reader([Self.avatar: .json(Self.answer(name: "picture gone")), Self.header: .json("", status: 403)])
        let gone = try MastodonOwnAccount.answer(from: Data(Self.answer(name: "picture gone").utf8), host: MastodonFixture.host)
        let header = try await #require(throws: OwnChangedInPart.self) {
            try await second.change(from: Self.before, to: Self.before, pictures: [.picture: .removed, .header: .removed])
        }
        #expect(header.answer == gone)
        #expect(Array(header.failed.keys) == [.header])
        #expect((header.failed[.header] as? OwnAccountError) == .forbidden, "said as the source's refusal")

        let token = MastodonFixture.token(scopes: "\(Self.r) \(Self.a)")
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        let walked = MastodonOwnAccount(door: MastodonAuthorized(token: token, sender: WalksAwayAtTheDelete(), store: tokens))
        await #expect(throws: CancellationError.self) {
            try await walked.change(from: Self.before, to: after, pictures: [.picture: .removed])
        }
    }

    /// Answers a change with an account, and a removal as a reader walking away.
    private struct WalksAwayAtTheDelete: HTTPSender {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard request.httpMethod != "DELETE", let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            else { throw CancellationError() }
            return (Data(MastodonOwnAccountTests.answer().utf8), response)
        }
    }

    @Test("A limit of nothing or less passed in is none stated: this app's bound stands, named as this app's", arguments: [0, -1])
    func limitOfNothing(limit: Int) async throws {
        let (reader, server, _) = try Self.reader([Self.change: .json(Self.answer())])
        _ = try await reader.change(from: Self.before, to: Self.before, pictures: [.picture: .chosen(Self.pixel, type: "image/png", name: "a.png")], limit: limit)
        #expect(await server.requests.count == 1)
        await #expect(throws: OwnPictureTooLarge(limit: OwnPicture.byteLimit, stated: false)) {
            try await reader.change(from: Self.before, to: Self.before, pictures: [.picture: .chosen(Data(count: OwnPicture.byteLimit + 1), type: "image/png", name: "a.png")], limit: limit)
        }
        #expect(await server.requests.count == 1)
    }

    @Test("A picture the source will not take (422) is its refusal on the picture's row, a real Mastodon's words; a 403 is the lock without the part and the source forbidding it with it, to a picture sent and one taken away alike")
    func pictureRefusals() async throws {
        let (refusing, _, tokens) = try Self.reader([Self.change: .json(MastodonPartsCaptures.noPicture, status: 422)])
        await #expect(throws: OwnAccountError.refused(sentence: "Validation failed: Avatar has contents that are not what they are reported to be", rows: [.picture: "has contents that are not what they are reported to be"])) {
            try await refusing.change(from: Self.before, to: Self.before, pictures: [.picture: .chosen(Self.pixel, type: "image/png", name: "a.png")])
        }
        #expect(try tokens.token(host: MastodonFixture.host) != nil)

        let forbidden = [Self.change: FixtureSender.Outcome.json(#"{"error":"Forbidden"}"#, status: 403), Self.avatar: .json("", status: 403), Self.header: .json("", status: 403)]
        for (scopes, error) in [(Self.r, OwnAccountError.locked), ("\(Self.r) \(Self.a)", .forbidden)] {
            let (reader, _, _) = try Self.reader(forbidden, scopes: scopes)
            await #expect(throws: error) {
                try await reader.change(from: Self.before, to: Self.before, pictures: [.header: .chosen(Self.pixel, type: "image/png", name: "b.png")])
            }
            await #expect(throws: error) { try await reader.change(from: Self.before, to: Self.before, pictures: [.picture: .removed]) }
        }

        let (odd, _, _) = try Self.reader([Self.change: .json("[]")])
        await #expect(throws: OwnAccountError.unreadable) {
            try await odd.change(from: Self.before, to: Self.before, pictures: [.picture: .chosen(Self.pixel, type: "image/png", name: "a.png")])
        }
    }
}
